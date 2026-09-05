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

# 4. The installer refuses when none of its tools/profile resolve (empty PATH).
# shellcheck disable=SC2123 # emptying PATH is the point: simulate no tooling
if ( PATH=""; "$SCRIPT_DIR/install-packages.sh" >/dev/null 2>&1 ); then
  miss "installer must refuse with no resolvable tooling/profile"
else
  pass "installer refuses fail-closed with empty PATH"
fi

# 5/6. Fixture chezmoi drives resolve_runtime_profile deterministically; real
#      yq stays resolvable because the fixture dir is only prepended.
fixture_bin="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-install-test.XXXXXX")"
trap 'rm -rf "$fixture_bin"' EXIT
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

"$SCRIPT_DIR/test-inventory.sh" || status=1

if [[ "$status" -eq 0 ]]; then
  ok "install-packages tests passed"
fi
exit "$status"
