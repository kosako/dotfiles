#!/usr/bin/env bash
set -euo pipefail

# Behavior tests for the gclone helper in dot_zshrc (#177). The function is
# extracted by its begin/end markers and run under `zsh -f` in a fixture HOME,
# always with -n (resolve-and-print, no clone), so no network or git is
# touched. Contract under test: context resolution order (managed kosako rule
# -> local mapping -> fail-closed abort), URL form parsing, and the
# destination guards.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

if ! command -v zsh >/dev/null 2>&1; then
  fail "zsh not found; gclone tests require it (CI installs it, #150)"
  exit 1
fi

status=0
pass() { ok "test passed: $*"; }
miss() {
  fail "test failed: $*"
  status=1
}

fixture_home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-gclone-test.XXXXXX")"
trap 'rm -rf "$fixture_home"' EXIT

# Extract exactly one marker-delimited function body from the managed source.
# The guards make extraction failures loud instead of vacuous: exactly one
# begin and one end marker must exist, and the extraction must end at the end
# marker (a missing end marker would sweep the rest of the file in).
begin_count="$(grep -c '^# --- gclone begin ---$' "$DOTFILES_ROOT/dot_zshrc")" || true
end_count="$(grep -c '^# --- gclone end ---$' "$DOTFILES_ROOT/dot_zshrc")" || true
if [[ "$begin_count" != "1" || "$end_count" != "1" ]]; then
  fail "expected exactly one gclone marker pair in dot_zshrc (begin=$begin_count end=$end_count)"
  exit 1
fi
fn_file="$fixture_home/gclone.zsh"
awk '/^# --- gclone begin ---$/,/^# --- gclone end ---$/' \
  "$DOTFILES_ROOT/dot_zshrc" > "$fn_file"
if ! grep -q '^gclone()' "$fn_file" || [[ "$(tail -n 1 "$fn_file")" != "# --- gclone end ---" ]]; then
  fail "gclone extraction broke (function or end marker missing)"
  exit 1
fi

# run_gclone <expected_rc> <stdout-or-empty> <args...>
run_gclone() {
  local name="$1" expected_rc="$2" expected_out="$3"
  shift 3
  local out rc=0
  out="$(HOME="$fixture_home" zsh -f -c \
    "source '$fn_file'; gclone \"\$@\"" gclone "$@" </dev/null 2>/dev/null)" || rc=$?
  if [[ "$rc" == "$expected_rc" && "$out" == "$expected_out" ]]; then
    pass "$name"
  else
    miss "$name (rc=$rc want $expected_rc; out=$out)"
  fi
}

# 1. Managed rule: kosako on github.com resolves to personal, all URL forms.
run_gclone "https url -> personal" 0 "$fixture_home/src/personal/foo" \
  -n https://github.com/kosako/foo
run_gclone "scp url (.git) -> personal" 0 "$fixture_home/src/personal/bar" \
  -n git@github.com:kosako/bar.git
run_gclone "ssh:// url -> personal" 0 "$fixture_home/src/personal/baz" \
  -n ssh://git@github.com/kosako/baz
run_gclone "ssh:// url with port -> personal" 0 "$fixture_home/src/personal/qux" \
  -n ssh://git@github.com:22/kosako/qux

# 2. Local mapping resolves other owners (the machine-local seam for
#    company orgs; the org name never enters this repo).
mkdir -p "$fixture_home/.config/dotfiles"
printf '# comment line\nacme work/acme\n' \
  > "$fixture_home/.config/dotfiles/clone-contexts.local"
run_gclone "mapped owner -> mapped context" 0 "$fixture_home/src/work/acme/tool" \
  -n https://github.com/acme/tool
# kosako stays personal even with a mapping file present (managed rule first).
run_gclone "managed rule wins over mapping" 0 "$fixture_home/src/personal/foo" \
  -n https://github.com/kosako/foo

# 3. Fail closed: unmapped owner without a TTY aborts, prints nothing.
run_gclone "unmapped owner aborts (no TTY)" 1 "" \
  -n https://github.com/stranger/tool

# 4. A mapping that escapes ~/src is rejected (no path traversal), and a
#    malformed mapping line (extra fields) never resolves — it falls through
#    to the fail-closed abort instead of cloning into "work/bad extra".
printf 'evil ../../etc\nbad work/bad extra\n' \
  >> "$fixture_home/.config/dotfiles/clone-contexts.local"
run_gclone "traversal context rejected" 2 "" \
  -n https://github.com/evil/tool
run_gclone "malformed mapping line falls through to abort" 1 "" \
  -n https://github.com/bad/tool

# 5. Existing destination aborts (never clobbers).
mkdir -p "$fixture_home/src/personal/exists"
run_gclone "existing destination aborts" 1 "" \
  -n https://github.com/kosako/exists

# 6. Unparseable URLs are usage errors.
run_gclone "garbage url rejected" 2 "" -n "not-a-url"
run_gclone "deep https path rejected" 2 "" -n https://github.com/kosako/foo/tree/main
run_gclone "missing url is usage error" 2 "" -n

if [[ "$status" -eq 0 ]]; then
  ok "gclone tests passed"
fi
exit "$status"
