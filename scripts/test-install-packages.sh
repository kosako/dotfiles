#!/usr/bin/env bash
set -euo pipefail

# Verify the catalog installer's gate and fail-closed contract (#53 stage 2):
# - source -> capability mapping is correct.
# - profile_installs_source only installs a source where the gating capability
#   is literally true; work / client / agent install nothing; unknown profiles
#   and manual sources install nothing (fail-closed).
# - install-packages.sh refuses when no profile resolves, and for a resolved
#   work profile plans zero installs in dry-run (no side effects).
# The pure capability checks run without chezmoi, so this is stable in CI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

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
minimal_bin="$fixture_bin/minimal"
mkdir -p "$minimal_bin"
for tool in bash dirname; do
  ln -s "$(command -v "$tool")" "$minimal_bin/$tool"
done
rc=0
out="$(PATH="$minimal_bin" "$SCRIPT_DIR/install-packages.sh" 2>&1)" || rc=$?
if [[ "$rc" -eq 1 ]] && grep -Fq '[fail] yq not found; install mikefarah/yq v4' <<< "$out" &&
    ! grep -Fq '[fail] cannot resolve the machine profile from chezmoi config; refusing.' <<< "$out"; then
  pass "installer refuses missing yq with exit 1 before profile resolution"
else
  printf '%s\n' "$out" >&2
  miss "installer must diagnose missing yq and exit 1 before profile resolution (got $rc)"
fi

ln -s "$(command -v yq)" "$minimal_bin/yq"
rc=0
out="$(PATH="$minimal_bin" "$SCRIPT_DIR/install-packages.sh" 2>&1)" || rc=$?
if [[ "$rc" -eq 1 ]] && grep -Fq '[fail] cannot resolve the machine profile from chezmoi config; refusing.' <<< "$out"; then
  pass "installer refuses missing chezmoi with exit 1 and a profile diagnostic"
else
  printf '%s\n' "$out" >&2
  miss "installer must diagnose missing chezmoi and exit 1 (got $rc)"
fi

# 5/6. Fixture chezmoi drives resolve_runtime_profile deterministically; real
#      yq stays resolvable because the fixture dir is only prepended.
fake_chezmoi() {
  # $1 = chezmoi data payload, $2 = exit code
  cat > "$fixture_bin/chezmoi" <<SH
#!/bin/sh
printf '%s\n' '$1'
exit ${2:-0}
SH
  chmod +x "$fixture_bin/chezmoi"
}

# 5a. chezmoi resolves a valid profile but exits non-zero -> refuse. With yq
#     and bash present (only chezmoi fails), this reaches and pins
#     resolve_runtime_profile's fail-closed path; the gate must not trust a
#     masked payload.
fake_chezmoi '{"profile":"personal"}' 3
if ( PATH="$fixture_bin:$PATH" "$SCRIPT_DIR/install-packages.sh" >/dev/null 2>&1 ); then
  miss "installer must refuse when chezmoi exits non-zero (even with a valid profile)"
else
  pass "installer refuses on chezmoi non-zero exit (fail-closed resolve)"
fi

# 5b. A resolved work profile plans zero installs (everything gates out before
#     any probing, so this is deterministic and has no side effects).
fake_chezmoi '{"profile":"work"}' 0
if out="$(PATH="$fixture_bin:$PATH" "$SCRIPT_DIR/install-packages.sh" 2>&1)"; then
  if grep -Fq "dry-run: 0 would be installed" <<< "$out"; then
    pass "work plans zero installs (gated out)"
  else
    printf '%s\n' "$out" >&2
    miss "work should plan zero installs"
  fi
else
  printf '%s\n' "$out" >&2
  miss "installer must exit 0 in dry-run for a resolved work profile"
fi

# 6. An undefined resolved profile is refused (fail-closed).
fake_chezmoi '{"profile":"no-such-profile"}' 0
if ( PATH="$fixture_bin:$PATH" "$SCRIPT_DIR/install-packages.sh" >/dev/null 2>&1 ); then
  miss "installer must refuse an undefined resolved profile"
else
  pass "installer refuses an undefined resolved profile"
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

# 9. environmentKind limits hold at run time, not only in validate-policy
#    (#357). In a repo copy where work sets installPackages / installGuiApps
#    true (set_capability_all writes every profile; work's row forbids both),
#    the installer must refuse outright — exit 1 and the refusal line, with
#    no manager probed or run — instead of planning installs. The copy's
#    validate-policy rejecting the same data shows the fixture is the
#    forbidden combination, so the case cannot pass on an unflipped copy.
#    The fake managers record every call and live in a directory of this
#    case's own, ahead of the real ones on PATH; HOME is an empty directory.
ek_root="$fixture_bin/ek-repo"
ek_bin="$fixture_bin/ek-bin"
ek_home="$fixture_bin/ek-home"
ek_calls="$fixture_bin/ek-calls"
mkdir -p "$ek_root" "$ek_bin" "$ek_home"
copy_repo_fixture "$ek_root"
set_capability_all "$ek_root" installPackages true
set_capability_all "$ek_root" installGuiApps true
for manager in brew npm go mas; do
  cat > "$ek_bin/$manager" <<SH
#!/bin/sh
printf '%s %s\n' "\${0##*/}" "\$*" >> "$ek_calls"
exit 0
SH
  chmod +x "$ek_bin/$manager"
done
cat > "$ek_bin/chezmoi" <<'SH'
#!/bin/sh
printf '%s\n' '{"profile":"work"}'
SH
chmod +x "$ek_bin/chezmoi"
ek_rc=0
ek_out="$("$ek_root/scripts/validate-policy.sh" work 2>&1)" || ek_rc=$?
if [[ "$ek_rc" -eq 1 ]] && grep -Fxq "[fail] environmentKind work forbids installPackages=true (profile work)" <<< "$ek_out" \
  && grep -Fxq "[fail] environmentKind work forbids installGuiApps=true (profile work)" <<< "$ek_out"; then
  pass "fixture: work with the install capabilities true is rejected by validate-policy"
else
  printf '%s\n' "$ek_out" >&2
  miss "fixture must be the forbidden combination validate-policy rejects (rc=$ek_rc)"
fi
# ek_install ROOT MODE [BIN] — run ROOT's installer (dry-run, or --apply) with
# the recording managers, and BIN's tools ahead of them when given; sets
# ek_rc / ek_out and starts a fresh call record.
ek_install() {
  local ek_path="${3:+$3:}$ek_bin:$PATH"
  rm -f "$ek_calls"
  ek_rc=0
  if [[ "$2" == apply ]]; then
    ek_out="$(HOME="$ek_home" PATH="$ek_path" "$1/scripts/install-packages.sh" --apply 2>&1)" || ek_rc=$?
  else
    ek_out="$(HOME="$ek_home" PATH="$ek_path" "$1/scripts/install-packages.sh" 2>&1)" || ek_rc=$?
  fi
}
ek_refusal="[fail] machine profile 'work' sets installPackages=true, installGuiApps=true, which environmentKind work forbids; refusing. Run: ./scripts/validate-policy.sh work"
for ek_mode in dry-run apply; do
  ek_install "$ek_root" "$ek_mode"
  if [[ "$ek_rc" -eq 1 && ! -e "$ek_calls" ]] && grep -Fxq "$ek_refusal" <<< "$ek_out" \
    && ! grep -Fq "catalog install (profile:" <<< "$ek_out"; then
    pass "installer ($ek_mode) refuses a work profile with forbidden install capabilities before probing any manager"
  else
    printf '%s\n' "$ek_out" >&2
    if [[ -e "$ek_calls" ]]; then cat "$ek_calls" >&2; fi
    miss "installer ($ek_mode) must refuse a profile that breaks its environmentKind (rc=$ek_rc)"
  fi
done
# The permission itself, not only the entry point: profile_installs_source in
# the same copy grants no source to work (and still every source to personal,
# the control that the copy's lib runs at all).
if env FIXTURE_LIB="$ek_root/scripts/lib-policy.sh" bash -c '
  source "$FIXTURE_LIB" || exit 2
  for source in brew_formula npm_global go_install brew_cask mas; do
    profile_installs_source personal "$source" || exit 1
    if profile_installs_source work "$source"; then exit 1; fi
  done
'; then
  pass "profile_installs_source grants no source for a forbidden install capability"
else
  miss "profile_installs_source must deny a capability the environmentKind forbids"
fi
# The same true reached through a YAML alias (work's capabilities are an
# alias of personal's map): the runtime gate reads it as true, so the table
# must too, or the alias would install where validate-policy refuses. The
# premise is checked first (the gate's own read sees true), and the copy's
# validate-policy must list the same line (the static check and the gate
# read the table the same way).
ek_alias="$fixture_bin/ek-alias"
mkdir -p "$ek_alias"
copy_repo_fixture "$ek_alias"
yq -i '.profiles.personal.capabilities anchor = "PC" | .profiles.work.capabilities alias = "PC"' \
  "$ek_alias/.chezmoidata/profiles.yaml"
ek_vrc=0
ek_vout="$("$ek_alias/scripts/validate-policy.sh" work 2>&1)" || ek_vrc=$?
ek_install "$ek_alias" dry-run
if env FIXTURE_LIB="$ek_alias/scripts/lib-policy.sh" bash -c '
  source "$FIXTURE_LIB" || exit 2
  profile_capability_is_true work installPackages || exit 1
  for source in brew_formula npm_global go_install brew_cask mas; do
    if profile_installs_source work "$source"; then exit 1; fi
  done
' && [[ "$ek_vrc" -eq 1 ]] \
  && grep -Fxq "[fail] environmentKind work forbids installPackages=true (profile work)" <<< "$ek_vout" \
  && [[ "$ek_rc" -eq 1 && ! -e "$ek_calls" ]] \
  && grep -Eq "^\[fail\] machine profile 'work' sets .*installPackages=true.*, which environmentKind work forbids; refusing\. Run: \./scripts/validate-policy\.sh work$" <<< "$ek_out"; then
  pass "an install capability made true through a YAML alias is refused like a literal one"
else
  printf '%s\n' "$ek_out" >&2
  miss "a forbidden install capability reached through an alias must be refused (rc=$ek_rc)"
fi
# sandbox forbids only secret access: personal retagged to sandbox (secret
# access off) still installs every source, so the refusal follows the table's
# row, not "anything but personal". The retag is checked to have taken (the
# kind reads sandbox, and the copy's validate-policy accepts personal as a
# valid sandbox profile), so the case cannot pass on personal's empty row.
set_environment_kind "$ek_root" personal sandbox
set_capability_all "$ek_root" allowSecretsAccess false
ek_rc=0
ek_out="$(env FIXTURE_LIB="$ek_root/scripts/lib-policy.sh" bash -c '
  source "$FIXTURE_LIB" || exit 2
  [[ "$(profile_environment_kind personal)" == sandbox ]] || exit 1
  "$DOTFILES_ROOT/scripts/validate-policy.sh" personal >/dev/null 2>&1 || exit 1
  require_environment_kind_limits personal refusing || exit 1
  for source in brew_formula npm_global go_install brew_cask mas; do
    profile_installs_source personal "$source" || exit 1
  done
' 2>&1)" || ek_rc=$?
if [[ "$ek_rc" -eq 0 && -z "$ek_out" ]]; then
  pass "a sandbox profile with secret access off may still install every source"
else
  printf '%s\n' "$ek_out" >&2
  miss "sandbox must not be refused for install (its row forbids only secret access; rc=$ek_rc)"
fi
# A failed read is not "false" (#357 review): on the same sandbox data (the
# control just above accepts it), a yq that fails only the gate's typed read
# of the forbidden allowSecretsAccess must make the installer refuse — exit 1
# and the unreadable-profile line, with no manager probed or run — and
# validate-policy fail, rather than read "no violation" and install on the
# granted installPackages. The premise is checked first through the same
# stand-in: that read fails, installPackages still reads true, and
# profile_installs_source grants a source, so the install path is open and
# only the refusal can stop it. The stand-in yq and chezmoi (profile
# personal) sit ahead of the recording managers; every other yq call runs
# the real one. While the file ek-shim/empty exists, the stand-in instead
# answers that read with nothing and exit 0 (the last check below).
ek_shim="$fixture_bin/ek-shim"
mkdir -p "$ek_shim"
ek_typed_read='.profiles[strenv(p)].capabilities[strenv(c)] | ((tag == "!!bool") and (. == true))'
{
  printf '%s\n' '#!/bin/sh' \
    "if [ \"\${c-}\" = allowSecretsAccess ] && [ \"\${1-}\" = $(shell_single_quote "$ek_typed_read") ]; then" \
    "  if [ -e $(shell_single_quote "$ek_shim/empty") ]; then exit 0; fi" \
    "  echo 'Error: injected read failure' >&2" \
    '  exit 1' \
    'fi'
  printf 'exec %s "$@"\n' "$(shell_single_quote "$(command -v yq)")"
} > "$ek_shim/yq"
chmod +x "$ek_shim/yq"
cat > "$ek_shim/chezmoi" <<'SH'
#!/bin/sh
printf '%s\n' '{"profile":"personal"}'
SH
chmod +x "$ek_shim/chezmoi"
if env FIXTURE_LIB="$ek_root/scripts/lib-policy.sh" PATH="$ek_shim:$PATH" bash -c '
  source "$FIXTURE_LIB" || exit 2
  if profile_capability_bool personal allowSecretsAccess >/dev/null 2>&1; then exit 1; fi
  [[ "$(profile_capability_bool personal installPackages)" == true ]] || exit 1
  profile_installs_source personal brew_formula || exit 1
'; then
  pass "fixture: the stand-in yq fails only the typed read of allowSecretsAccess, and the install path is open"
else
  miss "fixture: the stand-in yq must fail only the typed read of allowSecretsAccess on a profile that installs"
fi
ek_unreadable="[fail] machine profile 'personal' has no valid environmentKind in profiles.yaml, or its capabilities could not be read; refusing"
for ek_mode in dry-run apply; do
  ek_install "$ek_root" "$ek_mode" "$ek_shim"
  if [[ "$ek_rc" -eq 1 && ! -e "$ek_calls" ]] && grep -Fxq "$ek_unreadable" <<< "$ek_out" \
    && ! grep -Fq "catalog install (profile:" <<< "$ek_out"; then
    pass "installer ($ek_mode) refuses a profile whose forbidden capability cannot be read, before probing any manager"
  else
    printf '%s\n' "$ek_out" >&2
    if [[ -e "$ek_calls" ]]; then cat "$ek_calls" >&2; fi
    miss "installer ($ek_mode) must refuse when a forbidden capability's typed read fails (rc=$ek_rc)"
  fi
done
ek_vrc=0
ek_vout="$(PATH="$ek_shim:$PATH" "$ek_root/scripts/validate-policy.sh" personal 2>&1)" || ek_vrc=$?
if [[ "$ek_vrc" -eq 1 ]] && grep -Fxq "[fail] could not read the environmentKind constraints of profile personal" <<< "$ek_vout"; then
  pass "validate-policy fails when a forbidden capability's typed read fails"
else
  printf '%s\n' "$ek_vout" >&2
  miss "validate-policy must fail when a forbidden capability's typed read fails (rc=$ek_vrc)"
fi
# A read that exits 0 with neither true nor false is no answer either: the
# typed read fails and the entry refusal holds.
: > "$ek_shim/empty"
ek_rc=0
ek_out="$(env FIXTURE_LIB="$ek_root/scripts/lib-policy.sh" PATH="$ek_shim:$PATH" bash -c '
  source "$FIXTURE_LIB" || exit 2
  if profile_capability_bool personal allowSecretsAccess >/dev/null; then exit 3; fi
  require_environment_kind_limits personal refusing
' 2>&1)" || ek_rc=$?
rm -f "$ek_shim/empty"
if [[ "$ek_rc" -eq 1 ]] && grep -Fxq "$ek_unreadable" <<< "$ek_out"; then
  pass "a typed read that answers neither true nor false is refused like a failed one"
else
  printf '%s\n' "$ek_out" >&2
  miss "a typed read that answers neither true nor false must be refused (rc=$ek_rc)"
fi
# An unknown kind picks no row: refused at the entry point, and no source is
# granted by the permission either (it must not read as unconstrained).
set_environment_kind "$ek_root" personal no-such-kind
ek_rc=0
ek_out="$(env FIXTURE_LIB="$ek_root/scripts/lib-policy.sh" bash -c '
  source "$FIXTURE_LIB" || exit 2
  require_environment_kind_limits personal refusing
' 2>&1)" || ek_rc=$?
if [[ "$ek_rc" -eq 1 ]] \
  && grep -Fxq "[fail] machine profile 'personal' has no valid environmentKind in profiles.yaml, or its capabilities could not be read; refusing" <<< "$ek_out" \
  && env FIXTURE_LIB="$ek_root/scripts/lib-policy.sh" bash -c '
    source "$FIXTURE_LIB" || exit 2
    for source in brew_formula npm_global go_install brew_cask mas; do
      if profile_installs_source personal "$source"; then exit 1; fi
    done
  '; then
  pass "an unknown environmentKind is refused at the entry point and grants no source"
else
  printf '%s\n' "$ek_out" >&2
  miss "an unknown environmentKind must be refused at the entry point and grant no source (rc=$ek_rc)"
fi

"$SCRIPT_DIR/test-inventory.sh" || status=1

if [[ "$status" -eq 0 ]]; then
  ok "install-packages tests passed"
fi
exit "$status"
