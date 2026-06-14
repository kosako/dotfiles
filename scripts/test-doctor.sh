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

# agent-tools report-only section. A fake status.sh emits the contract
# JSON; doctor must summarize it and flag conflict targets, never write,
# and always exit 0.
agent_scripts="$fixture_home/src/agent/agent-tools/scripts"
mkdir -p "$agent_scripts"
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
[ "$1" = "--json" ] || exit 1
cat <<'JSON'
{"contract_version":2,"repo":{"present":true,"clean":true},"assets":{"total":1,"manifest_errors":0},"checks":{"manifest_validation":"pass","prompt_injection_static":"pass"},"generated":{"total":1,"stale":0},"register":{"catalog_present":true,"registered":1,"human_review_required":0,"unsupported":0},"sync_targets":[{"tool":"codex","name":"x","state":"conflict"}]}
JSON
SH
chmod +x "$agent_scripts/status.sh"

if ! at_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 with agent-tools present"
  status=1
fi
if grep -Fq "agent-tools present; status contract v2" <<< "$at_out"; then
  ok "test passed: agent-tools status summarized"
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: agent-tools status not summarized"
  status=1
fi
if grep -Fq "sync conflicts" <<< "$at_out"; then
  ok "test passed: agent-tools conflict target flagged"
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: agent-tools conflict not flagged"
  status=1
fi

# An unknown contract version must not be interpreted.
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
[ "$1" = "--json" ] || exit 1
echo '{"contract_version":99}'
SH
chmod +x "$agent_scripts/status.sh"
at_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1 || true)"
if grep -Fq "expected 2 (not interpreting fields)" <<< "$at_out"; then
  ok "test passed: unknown agent-tools contract version is not interpreted"
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: contract version mismatch not handled"
  status=1
fi

# Absent agent-tools is a report-only warning, not a failure.
rm -rf "$fixture_home/src/agent/agent-tools"
if at_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "agent-tools not present" <<< "$at_out"; then
    ok "test passed: absent agent-tools reported, doctor exit 0"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: absent agent-tools not reported"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 when agent-tools absent"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "doctor tests passed"
fi
exit "$status"
