#!/usr/bin/env bash
set -euo pipefail

# #566: the judgment of doctor's "CLI checked versions" section on fixed
# inputs (no doctor run, no real CLI), and the data it reads. The wiring
# (command -v, the bounded probe, the report lines) is covered by a few
# full-doctor cases in test-doctor.sh (the #565 split).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

require_yq || exit 1

status=0

# check_state NAME WANT CHECKED FOUND OUTPUT
check_state() {
  local name="$1" want="$2" actual
  actual="$(cli_checked_version_state "$3" "$4" "$5")"
  if [[ "$actual" == "$want" ]]; then
    ok "test passed: $name"
  else
    fail "test failed: $name (got: $actual, want: $want)"
    status=1
  fi
}

section "unit: CLI checked version judgment (#566)"
check_state "claude's --version output that matches" "matches 2.1.329" 2.1.329 1 "2.1.329 (Claude Code)"
check_state "codex's --version output that differs" "differs 0.169.1" 0.162.1 1 "codex-cli 0.169.1"
check_state "a patch release differs" "differs 2.1.330" 2.1.329 1 "2.1.330 (Claude Code)"
check_state "a prefix of the checked version differs" "differs 2.1.32" 2.1.329 1 "2.1.32 (Claude Code)"
check_state "the first dotted word of the line is the version" "matches 1.2.3" 1.2.3 1 "tool 1.2.3 built with 4.5.6"
check_state "a tab separates words" "matches 1.2.3" 1.2.3 1 $'tool\t1.2.3'
check_state "only the first line is read" "unreadable" 1.2.3 1 $'error: no version here\n1.2.3'
check_state "empty output (failed or timed out probe) is unreadable" "unreadable" 1.2.3 1 ""
check_state "output without a version is unreadable" "unreadable" 1.2.3 1 "error: unknown option '--version'"
check_state "a v-prefixed word is not a version" "unreadable" 1.2.3 1 "v1.2.3"
check_state "a plain number is not a version" "unreadable" 1.2.3 1 "12"
check_state "a CLI not on PATH is absent" "absent" 1.2.3 0 ""
check_state "absent does not read the output" "absent" 1.2.3 0 "1.2.3"
check_state "an empty checked version is unrecorded" "unrecorded" "" 1 "1.2.3"
check_state "a non-version checked value is unrecorded" "unrecorded" "latest" 1 "1.2.3"
check_state "a YAML null read as text is unrecorded" "unrecorded" "null" 1 "1.2.3"
check_state "unrecorded comes before absent" "unrecorded" "" 0 ""

# A `*` in the output must stay a word: with pathname expansion it would
# match the file named like the checked version in the current directory.
glob_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-cli-versions-test.XXXXXX")"
trap 'rm -rf "$glob_dir"' EXIT
: > "$glob_dir/1.2.3"
glob_state="$(cd "$glob_dir" && cli_checked_version_state 1.2.3 1 "*")"
if [[ "$glob_state" == unreadable ]]; then
  ok "test passed: a * in the output is not expanded to file names"
else
  fail "test failed: a * in the output was expanded (got: $glob_state)"
  status=1
fi

# The caller's IFS must not change how the line is split.
ifs_state="$(IFS=,; cli_checked_version_state 1.2.3 1 "tool 1.2.3")"
if [[ "$ifs_state" == "matches 1.2.3" ]]; then
  ok "test passed: the caller's IFS does not change the word split"
else
  fail "test failed: the caller's IFS changed the word split (got: $ifs_state)"
  status=1
fi

section "data: .chezmoidata/cli-checked-versions.yaml"
version_re='^[0-9]+(\.[0-9]+)+$'
for key in claudeCode codex; do
  value="$(K="$key" yq '.cliCheckedVersions[strenv(K)] // ""' "$CLI_VERSIONS_FILE")"
  if [[ "$value" =~ $version_re ]]; then
    ok "test passed: cliCheckedVersions.$key is a dotted version"
  else
    fail "test failed: cliCheckedVersions.$key must be a dotted version (got: $(display_safe "$value"))"
    status=1
  fi
done

# The CI's execpolicy check runs the pinned Codex; the recorded version must
# be that pin, or doctor would compare the local codex with a version no
# check ran on.
workflow="$DOTFILES_ROOT/.github/workflows/validate.yml"
ci_codex="$(yq '.env.CODEX_VERSION // ""' "$workflow")"
data_codex="$(yq '.cliCheckedVersions.codex // ""' "$CLI_VERSIONS_FILE")"
if [[ -n "$ci_codex" && "$ci_codex" == "$data_codex" ]]; then
  ok "test passed: cliCheckedVersions.codex equals the CI's CODEX_VERSION ($ci_codex)"
else
  fail "test failed: cliCheckedVersions.codex ($(display_safe "$data_codex")) must equal CODEX_VERSION in .github/workflows/validate.yml ($(display_safe "$ci_codex"))"
  status=1
fi

exit "$status"
