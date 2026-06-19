#!/usr/bin/env bash
set -euo pipefail

# Verify the private-backup runtime gate (issue #60): backup / restore may
# run only where the host's real profile grants allowSecretsAccess. The
# gate must be fail-closed — an unresolvable or unknown profile, or any
# non-true value, refuses. The pure capability checks run without chezmoi
# so this test is deterministic in CI (the validate job has no chezmoi).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

status=0

pass() { ok "test passed: $*"; }
miss() {
  fail "test failed: $*"
  status=1
}

# 1. profile_allows_secrets_access: only allowSecretsAccess=true profiles
#    pass. personal grants it; work-minimal / work-dev do not.
if profile_allows_secrets_access personal; then
  pass "personal grants secret access"
else
  miss "personal should grant secret access"
fi
for denied in work-minimal work-dev; do
  if profile_allows_secrets_access "$denied"; then
    miss "$denied must not grant secret access"
  else
    pass "$denied denied secret access"
  fi
done

# 2. An unknown profile must not pass (fail-closed, never vacuously true).
if profile_allows_secrets_access no-such-profile; then
  miss "unknown profile must be denied"
else
  pass "unknown profile denied"
fi

# 3. resolve_runtime_profile / require_secrets_access fail closed when
#    chezmoi cannot be found. Run in a subshell with an empty PATH so
#    `command -v chezmoi` resolves to nothing; the gate must refuse before
#    ever assuming a default profile. `fail`/`ok` use shell builtins, so
#    the empty PATH does not break the gate's own output.
# shellcheck disable=SC2123 # emptying PATH is the point: simulate chezmoi absence
if ( PATH=""; resolve_runtime_profile >/dev/null 2>&1 ); then
  miss "resolve_runtime_profile must fail with chezmoi absent"
else
  pass "resolve_runtime_profile fails closed without chezmoi"
fi
# shellcheck disable=SC2123 # emptying PATH is the point: simulate chezmoi absence
if ( PATH=""; require_secrets_access >/dev/null 2>&1 ); then
  miss "require_secrets_access must refuse with chezmoi absent"
else
  pass "require_secrets_access refuses without chezmoi"
fi

# 4. Consistency with the live host, only when chezmoi can resolve a
#    profile (skipped in CI). The gate's verdict must match the pure check
#    for whatever profile the machine actually runs — never more permissive.
if resolved="$(resolve_runtime_profile 2>/dev/null)"; then
  if require_secrets_access >/dev/null 2>&1; then
    if profile_allows_secrets_access "$resolved"; then
      pass "gate agrees with profile '$resolved' (granted)"
    else
      miss "gate granted access but profile '$resolved' should be denied"
    fi
  else
    if profile_allows_secrets_access "$resolved"; then
      miss "gate refused but profile '$resolved' should be granted"
    else
      pass "gate agrees with profile '$resolved' (denied)"
    fi
  fi
else
  item "chezmoi did not resolve a profile; skipping live consistency check"
fi

if [[ "$status" -eq 0 ]]; then
  ok "secrets-gate tests passed"
fi
exit "$status"
