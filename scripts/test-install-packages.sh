#!/usr/bin/env bash
set -euo pipefail

# Verify the catalog installer's gate and fail-closed contract (#53 stage 2):
# - source -> capability mapping is correct.
# - profile_installs_source only installs a source where the gating capability
#   is literally true; work / client / agent install nothing; unknown profiles
#   and manual sources install nothing (fail-closed).
# - install-packages.sh refuses when no profile resolves, and for a resolved
#   work profile plans zero installs in dry-run (no side effects).
#   (#332: 未解決 / 未定義の profile は exit 1 と診断文言まで、work は全 entry を
#   not granted で skip して manager を一切呼ばないこと (呼び出しを記録する fake
#   manager を PATH に前置) まで固定する)
# The pure capability checks run without chezmoi, so this is stable in CI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

status=0
pass() { ok "test passed: $*"; }
miss() {
  fail "test failed: $*"
  status=1
}

# 1. source -> install capability mapping.
check_cap() {
  local src="$1" want="$2" got
  if got="$(source_install_capability "$src")" && [[ "$got" == "$want" ]]; then
    pass "$src -> $want"
  else
    miss "$src should map to $want (got '${got:-<none>}')"
  fi
}
check_cap brew_formula installPackages
check_cap npm_global installPackages
check_cap go_install installPackages
check_cap brew_cask installGuiApps
check_cap mas installGuiApps
if source_install_capability manual >/dev/null 2>&1; then
  miss "manual must not map to an install capability"
else
  pass "manual maps to no install capability"
fi

# 2. profile_installs_source: personal installs every installable source;
#    work installs none (installPackages/GuiApps are false).
for src in brew_formula npm_global go_install brew_cask mas; do
  if profile_installs_source personal "$src"; then
    pass "personal installs $src"
  else
    miss "personal should install $src"
  fi
  if profile_installs_source work "$src"; then
    miss "work must not install $src"
  else
    pass "work does not install $src"
  fi
done

# 3. Fail-closed: unknown profile and manual source never install.
if profile_installs_source no-such-profile brew_formula; then
  miss "unknown profile must not install"
else
  pass "unknown profile installs nothing"
fi
if profile_installs_source personal manual; then
  miss "manual source must never install"
else
  pass "manual source installs nothing even for personal"
fi

# 4. Reach the installer with only its startup tools on PATH; missing yq
#    and then missing chezmoi must each produce the intended refusal (exit 1).
#    The yq refusal must stop before profile resolution can also fail with exit 1.
fixture_bin="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-install-test.XXXXXX")"
trap 'rm -rf "$fixture_bin"' EXIT
# installer の run には空の fixture HOME を渡す (実 home の設定を読ませない)。
fixture_home="$fixture_bin/home"
mkdir -p "$fixture_home"
minimal_bin="$fixture_bin/minimal"
mkdir -p "$minimal_bin"
for tool in bash dirname; do
  ln -s "$(command -v "$tool")" "$minimal_bin/$tool"
done
rc=0
out="$(HOME="$fixture_home" PATH="$minimal_bin" "$SCRIPT_DIR/install-packages.sh" 2>&1)" || rc=$?
if [[ "$rc" -eq 1 ]] && grep -Fq '[fail] yq not found; install mikefarah/yq v4' <<< "$out" &&
    ! grep -Fq '[fail] cannot resolve the machine profile from chezmoi config; refusing.' <<< "$out"; then
  pass "installer refuses missing yq with exit 1 before profile resolution"
else
  printf '%s\n' "$out" >&2
  miss "installer must diagnose missing yq and exit 1 before profile resolution (got $rc)"
fi

ln -s "$(command -v yq)" "$minimal_bin/yq"
rc=0
out="$(HOME="$fixture_home" PATH="$minimal_bin" "$SCRIPT_DIR/install-packages.sh" 2>&1)" || rc=$?
if [[ "$rc" -eq 1 ]] && grep -Fq '[fail] cannot resolve the machine profile from chezmoi config; refusing.' <<< "$out"; then
  pass "installer refuses missing chezmoi with exit 1 and a profile diagnostic"
else
  printf '%s\n' "$out" >&2
  miss "installer must diagnose missing chezmoi and exit 1 (got $rc)"
fi

# 5/6. Fixture chezmoi drives resolve_runtime_profile deterministically; real
#      yq stays resolvable because the fixture dir is only prepended.
#      fake の brew / npm / go / mas も同じ dir に置く (#332 F04): それぞれ呼び出しを
#      記録して何も答えないので、5a / 5b / 6 の run は実 manager に届かず、gate を
#      素通りした entry は catalog を入れ終えた host でも記録として現れる。
fake_chezmoi() {
  # $1 = chezmoi data payload, $2 = exit code
  cat > "$fixture_bin/chezmoi" <<SH
#!/bin/sh
printf '%s\n' '$1'
exit ${2:-0}
SH
  chmod +x "$fixture_bin/chezmoi"
}
manager_calls="$fixture_bin/manager-calls"
for manager in brew npm go mas; do
  cat > "$fixture_bin/$manager" <<SH
#!/bin/sh
printf '%s %s\n' "\${0##*/}" "\$*" >> "$manager_calls"
exit 0
SH
  chmod +x "$fixture_bin/$manager"
done

# 5a. chezmoi resolves a valid profile but exits non-zero -> refuse. With yq
#     and bash present (only chezmoi fails), this reaches and pins
#     resolve_runtime_profile's fail-closed path; the gate must not trust a
#     masked payload.
#     5a / 6 は exit 1 と拒否の理由 (section 4 と同じ診断文言) まで見る (#332 F52):
#     別の理由の exit 1 (inventory 不明など) を拒否と取り違えない。
fake_chezmoi '{"profile":"personal"}' 3
rc=0
out="$(HOME="$fixture_home" PATH="$fixture_bin:$PATH" "$SCRIPT_DIR/install-packages.sh" 2>&1)" || rc=$?
if [[ "$rc" -eq 1 ]] && grep -Fq '[fail] cannot resolve the machine profile from chezmoi config; refusing.' <<< "$out"; then
  pass "installer refuses on chezmoi non-zero exit (fail-closed resolve)"
else
  printf '%s\n' "$out" >&2
  miss "installer must refuse when chezmoi exits non-zero with exit 1 and the profile diagnostic (got $rc)"
fi

# 5b. A resolved work profile plans zero installs (everything gates out before
#     any probing, so this is deterministic and has no side effects).
#     期待する skip 行と skipped の件数は catalog から組み立てる (#332 F04): gate を
#     素通りした entry は件数と manager の記録の両方で見つかる。track_only の entry は
#     gate の前に track-only として skip されるので、件数にだけ数える。gate を通る entry
#     が 0 件 (catalog が空、または全 entry が track-only) なら何も確かめていないので fail。
fake_chezmoi '{"profile":"work"}' 0
rm -f "$manager_calls"
rows="$(catalog_packages)"
if out="$(HOME="$fixture_home" PATH="$fixture_bin:$PATH" "$SCRIPT_DIR/install-packages.sh" 2>&1)"; then
  gated=1
  catalog_count=0
  gated_count=0
  while IFS='|' read -r name source _ _ track_only; do
    [[ -z "$name$source" ]] && continue
    catalog_count=$((catalog_count + 1))
    [[ "$track_only" == "true" ]] && continue
    cap="$(source_install_capability "$source")" || continue
    gated_count=$((gated_count + 1))
    grep -Fxq "[info] - skip $name: $cap not granted for 'work' ($source)" <<< "$out" || gated=0
  done <<< "$rows"
  if [[ "$gated" -eq 1 && "$gated_count" -gt 0 && ! -e "$manager_calls" ]] &&
      grep -Fxq "[ok] dry-run: 0 would be installed, $catalog_count skipped, 0 failed (pass --apply to perform)" <<< "$out"; then
    pass "work skips every catalog entry as not granted and consults no manager"
  else
    printf '%s\n' "$out" >&2
    if [[ -e "$manager_calls" ]]; then cat "$manager_calls" >&2; fi
    miss "work must skip every catalog entry as not granted, plan zero installs and consult no manager (catalog entries: $catalog_count, gated: $gated_count)"
  fi
else
  printf '%s\n' "$out" >&2
  miss "installer must exit 0 in dry-run for a resolved work profile"
fi

# 6. An undefined resolved profile is refused (fail-closed).
#    その診断文言と exit 1 まで固定する (#332 F52)。
fake_chezmoi '{"profile":"no-such-profile"}' 0
rc=0
out="$(HOME="$fixture_home" PATH="$fixture_bin:$PATH" "$SCRIPT_DIR/install-packages.sh" 2>&1)" || rc=$?
if [[ "$rc" -eq 1 ]] && grep -Fxq "[fail] machine profile 'no-such-profile' is not defined in profiles.yaml; refusing" <<< "$out"; then
  pass "installer refuses an undefined resolved profile"
else
  printf '%s\n' "$out" >&2
  miss "installer must refuse an undefined resolved profile with exit 1 and its diagnostic (got $rc)"
fi

# 7. build_install_cmd builds the right command per source from the canonical
#    id (pkg, defaulting to name) — pins the npm pkg-less and mas/go fixes
#    without performing installs. Sourcing is safe: the main run is guarded.
# shellcheck source=scripts/install-packages.sh
source "$SCRIPT_DIR/install-packages.sh"
check_cmd() {
  local src="$1" canonical="$2" want="$3" INSTALL_CMD=()
  if build_install_cmd "$src" "$canonical" && [[ "${INSTALL_CMD[*]}" == "$want" ]]; then
    pass "build_install_cmd $src -> $want"
  else
    miss "build_install_cmd $src should be '$want' (got '${INSTALL_CMD[*]:-<none>}')"
  fi
}
check_cmd brew_formula age "brew install age"
check_cmd brew_cask iterm2 "brew install --cask iterm2"
# pkg-less npm entry: canonical falls back to name, never an empty id.
check_cmd npm_global some-tool "npm install -g some-tool"
check_cmd npm_global @scope/pkg "npm install -g @scope/pkg"
check_cmd go_install github.com/x/y/v2 "go install github.com/x/y/v2@latest"
check_cmd mas 497799835 "mas install 497799835"
if build_install_cmd manual whatever 2>/dev/null; then
  miss "build_install_cmd must reject an uninstallable source"
else
  pass "build_install_cmd rejects manual/unknown source"
fi

# 8. is_installed matches against the full inventory capture. Regression for
#    the SIGPIPE false negative (#143): with the old `probe | grep -Fxq`
#    shape, grep exits on the first hit, the still-writing producer takes
#    SIGPIPE, and pipefail turns a found entry into "not installed" whenever
#    the inventory is larger than the pipe buffer. The fakes put the target
#    first and pad far past the buffer (64KiB) to make that deterministic.
pad_lines="$(mktemp "$fixture_bin/pad.XXXXXX")"
for _ in $(seq 1 4000); do
  printf 'padding-entry-000000000000000000000000000000000000\n'
done > "$pad_lines"
# exec makes the fake process itself the pipe writer, so it dies of SIGPIPE
# (141) exactly like the real manager would; a plain `cat` child would take
# the signal while the sh wrapper still runs its final `exit 0`, masking the
# failure the regression is about.
cat > "$fixture_bin/brew" <<SH
#!/bin/sh
case "\$*" in
  "list --cask -1") printf '%s\n' target-cask; exec cat "$pad_lines" ;;
  "list --formula -1") printf '%s\n' target-formula; exec cat "$pad_lines" ;;
esac
exit 0
SH
cat > "$fixture_bin/mas" <<SH
#!/bin/sh
if [ "\$1" = "list" ]; then
  printf '%s\n' '123456 Target App (1.0)'
  exec awk '{print NR+1000000, \$0}' "$pad_lines"
fi
exit 0
SH
chmod +x "$fixture_bin/brew" "$fixture_bin/mas"
check_installed() {
  local src="$1" canonical="$2" label="$3"
  if (PATH="$fixture_bin:$PATH" is_installed "$src" "$canonical" "no-such-bin"); then
    pass "is_installed finds $label in a large inventory (no SIGPIPE false negative)"
  else
    miss "is_installed lost $label to the SIGPIPE false negative"
  fi
}
check_installed brew_cask target-cask "a cask"
check_installed brew_formula target-formula "a formula"
check_installed mas 123456 "a mas app"
if (PATH="$fixture_bin:$PATH" is_installed brew_cask absent-cask no-such-bin); then
  miss "is_installed must not report an absent cask as installed"
else
  pass "is_installed still reports a genuinely absent cask as not installed"
fi

"$SCRIPT_DIR/test-inventory.sh" || status=1

if [[ "$status" -eq 0 ]]; then
  ok "install-packages tests passed"
fi
exit "$status"
