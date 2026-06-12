#!/usr/bin/env bash
set -euo pipefail

# Verify the doctor orphan detection with a fixture HOME. doctor stays
# report-only: both runs must exit 0; only the warnings differ.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

status=0
fixture_home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-doctor-test.XXXXXX")"
trap 'rm -rf "$fixture_home"' EXIT

# A leftover enforce-mode .npmrc, as after switching personal -> work-minimal.
printf '# Managed by chezmoi from kosako/dotfiles (npmHardeningMode=enforce).\nignore-scripts=true\n' \
  > "$fixture_home/.npmrc"

orphan_marker="orphan from another profile"

# work-minimal does not manage .npmrc (npmHardeningMode=report): orphan.
if ! output="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" work-minimal 2>&1)"; then
  printf '%s\n' "$output" >&2
  fail "test failed: doctor must stay exit 0 for work-minimal"
  status=1
fi
if grep -F "$orphan_marker" <<< "$output" | grep -Fq ".npmrc"; then
  ok "test passed: orphan .npmrc reported for work-minimal"
else
  printf '%s\n' "$output" >&2
  fail "test failed: orphan .npmrc not reported for work-minimal"
  status=1
fi

# personal manages .npmrc (npmHardeningMode=enforce): not an orphan.
if ! output="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  printf '%s\n' "$output" >&2
  fail "test failed: doctor must stay exit 0 for personal"
  status=1
fi
if grep -Fq "$orphan_marker" <<< "$output"; then
  printf '%s\n' "$output" >&2
  fail "test failed: personal must not report the fixture .npmrc as orphan"
  status=1
else
  ok "test passed: no orphan reported for personal"
fi

# A file without the managed-by header is never an orphan.
printf 'registry-noise=1\n' > "$fixture_home/.npmrc"
if HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" work-minimal 2>&1 | grep -Fq "$orphan_marker"; then
  fail "test failed: headerless file must not be reported as orphan"
  status=1
else
  ok "test passed: headerless file ignored"
fi

if [[ "$status" -eq 0 ]]; then
  ok "doctor tests passed"
fi
exit "$status"
