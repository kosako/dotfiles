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

# agent-tools report-only section. Presence is always reported; running
# status.sh is opt-in via enableAgentToolsStatus. doctor must always
# exit 0 and never write. The fake status.sh records that it ran so the
# opt-in gate can be proven.
agent_dir="$fixture_home/src/agent/agent-tools"
agent_scripts="$agent_dir/scripts"
agent_marker="$agent_dir/ran-marker"
mkdir -p "$agent_scripts"
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
[ "$1" = "--json" ] || exit 1
: > "$(dirname "$0")/../ran-marker"
cat <<'JSON'
{"contract_version":2,"repo":{"present":true,"clean":true},"assets":{"total":1,"manifest_errors":0},"checks":{"manifest_validation":"pass","prompt_injection_static":"pass"},"generated":{"total":1,"stale":0},"register":{"catalog_present":true,"registered":1,"human_review_required":0,"unsupported":0},"sync_targets":[{"tool":"codex","name":"x","state":"conflict"}]}
JSON
SH
chmod +x "$agent_scripts/status.sh"

# A) Default profile (enableAgentToolsStatus=false): present but status.sh
#    must not run.
rm -f "$agent_marker"
if at_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "status read disabled" <<< "$at_out" && [[ ! -e "$agent_marker" ]]; then
    ok "test passed: agent-tools status execution is opt-in (not run by default)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: agent-tools status.sh ran or was not reported as disabled"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 (agent-tools present, opt-in off)"
  status=1
fi

# Throwaway repo copy with the opt-in enabled for every profile, so the
# test does not depend on which profile comes first.
optin_root="$fixture_home/.dotfiles-optin"
mkdir -p "$optin_root/.chezmoidata"
cp -R "$DOTFILES_ROOT/scripts" "$optin_root/scripts"
cp "$DOTFILES_ROOT/.chezmoidata/"*.yaml "$optin_root/.chezmoidata/"
awk '$0 == "      enableAgentToolsStatus: false" { print "      enableAgentToolsStatus: true"; next } { print }' \
  "$optin_root/.chezmoidata/profiles.yaml" > "$optin_root/.chezmoidata/profiles.yaml.tmp"
mv "$optin_root/.chezmoidata/profiles.yaml.tmp" "$optin_root/.chezmoidata/profiles.yaml"

# B) Opt-in enabled: status.sh runs, summary shown, conflict flagged.
rm -f "$agent_marker"
if at_out="$(HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "agent-tools present; status contract v2" <<< "$at_out" \
    && grep -Fq "sync conflicts" <<< "$at_out" && [[ -e "$agent_marker" ]]; then
    ok "test passed: opt-in runs status.sh and summarizes (conflict flagged)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: opt-in summary/conflict/marker missing"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 (opt-in summary)"
  status=1
fi

# C) Opt-in + unknown contract version: not interpreted, still exit 0.
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
[ "$1" = "--json" ] || exit 1
echo '{"contract_version":99}'
SH
chmod +x "$agent_scripts/status.sh"
if at_out="$(HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "expected 2 (not interpreting fields)" <<< "$at_out"; then
    ok "test passed: unknown contract version is not interpreted (exit 0)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: contract version mismatch not handled"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 on contract version mismatch"
  status=1
fi

# D) Opt-in + missing status.sh: warning, still exit 0.
rm -f "$agent_scripts/status.sh"
if at_out="$(HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "status.sh is missing or not executable" <<< "$at_out"; then
    ok "test passed: missing status.sh is a warning (exit 0)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: missing status.sh not reported"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 when status.sh missing"
  status=1
fi

# F) Opt-in + status.sh exits non-zero: warning, still exit 0.
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$agent_scripts/status.sh"
if at_out="$(HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "no usable output" <<< "$at_out"; then
    ok "test passed: status.sh failure is a warning (exit 0)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: status.sh failure not handled"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 when status.sh exits non-zero"
  status=1
fi

# G) Opt-in + malformed status JSON: doctor must not break, exit 0.
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
[ "$1" = "--json" ] || exit 1
echo 'this is not json {{{'
SH
chmod +x "$agent_scripts/status.sh"
if HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal >/dev/null 2>&1; then
  ok "test passed: malformed status JSON keeps doctor at exit 0"
else
  fail "test failed: malformed status JSON must not break doctor"
  status=1
fi

# E) Absent agent-tools: report-only warning, exit 0.
rm -rf "$agent_dir"
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
