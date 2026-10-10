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
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

status=0

pass() { ok "test passed: $*"; }
miss() {
  fail "test failed: $*"
  status=1
}

# 1. profile_allows_secrets_access: only allowSecretsAccess=true profiles
#    pass. personal grants it; work does not.
if profile_allows_secrets_access personal; then
  pass "personal grants secret access"
else
  miss "personal should grant secret access"
fi
if profile_allows_secrets_access work; then
  miss "work must not grant secret access"
else
  pass "work denied secret access"
fi

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

# 4. Fixture chezmoi on PATH: drive resolve_runtime_profile / the gate
#    deterministically (no real chezmoi needed, so this is stable in CI).
#    A fake `chezmoi` echoes a chosen `chezmoi data` payload and exit code;
#    real yq stays resolvable because the fixture dir is only prepended.
fixture_bin="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-gate-test.XXXXXX")"
trap 'rm -rf "$fixture_bin"' EXIT
fake_chezmoi() {
  # $1 = stdout payload, $2 = exit code
  cat > "$fixture_bin/chezmoi" <<SH
#!/bin/sh
printf '%s\n' '$1'
exit $2
SH
  chmod +x "$fixture_bin/chezmoi"
}
with_fixture() { ( PATH="$fixture_bin:$PATH"; "$@" >/dev/null 2>&1 ); }
# The must case must be exercised with pipefail OFF: this test file runs
# under `set -o pipefail`, which a subshell inherits, and under pipefail a
# `chezmoi(fail) | yq(ok)` pipeline already reports non-zero — so the old
# buggy pipeline would pass this test too. Turning pipefail off makes the
# test fail against the old code and pass only with the exit-status check,
# pinning that the gate does not depend on the caller having pipefail.
with_fixture_no_pipefail() {
  ( set +o pipefail; PATH="$fixture_bin:$PATH"; "$@" >/dev/null 2>&1 )
}

# 4a. The must case: chezmoi prints a valid profile but exits non-zero.
#     The gate must fail closed, not trust the masked payload.
fake_chezmoi '{"profile":"personal"}' 3
if with_fixture_no_pipefail resolve_runtime_profile; then
  miss "resolve must fail closed when chezmoi exits non-zero (even with valid JSON, no pipefail)"
else
  pass "resolve fails closed on chezmoi non-zero exit despite valid JSON (no pipefail)"
fi
if with_fixture_no_pipefail require_secrets_access; then
  miss "gate must refuse when chezmoi exits non-zero (no pipefail)"
else
  pass "gate refuses on chezmoi non-zero exit (no pipefail)"
fi

# 4b. Healthy chezmoi resolving an allowed profile -> granted.
fake_chezmoi '{"profile":"personal"}' 0
if with_fixture require_secrets_access; then
  pass "gate grants for resolved personal profile"
else
  miss "gate should grant for resolved personal profile"
fi

# 4c. Healthy chezmoi resolving a denied profile -> refused.
fake_chezmoi '{"profile":"work"}' 0
if with_fixture require_secrets_access; then
  miss "gate must refuse for resolved work profile"
else
  pass "gate refuses for resolved work profile"
fi

# 4d. Healthy chezmoi but no profile key -> fail closed (empty profile).
fake_chezmoi '{}' 0
if with_fixture resolve_runtime_profile; then
  miss "resolve must fail closed on empty profile"
else
  pass "resolve fails closed on empty profile"
fi

# 4e. environmentKind limits hold at run time (#357): the gate refuses a
#     profile that sets allowSecretsAccess=true although its environmentKind
#     forbids it, with the environmentKind refusal (not "allowSecretsAccess !=
#     true", which would misstate the data), even though nothing ran
#     validate-policy first. Each case runs the gate of a repo copy
#     (copy_repo_fixture) whose data is changed fail-closed
#     (set_capability_all / set_environment_kind); the copy's validate-policy
#     rejecting the same data shows the change took, and the unchanged
#     control shows the copy's gate grants at all, so no refusal below can
#     come from a broken copy. The permission (profile_allows_secrets_access)
#     is checked in each copy too, not only the entry point.
ek_gate() {
  # $1 = repo copy; runs that copy's require_secrets_access with the fake chezmoi
  ek_rc=0
  ek_out="$(PATH="$fixture_bin:$PATH" bash -c 'source "$1/scripts/lib-policy.sh" || exit 2; require_secrets_access' _ "$1" 2>&1)" || ek_rc=$?
}
ek_copy() {
  # $1 = name; makes a fresh repo copy at $fixture_bin/$1 (removed with fixture_bin)
  rm -rf "${fixture_bin:?}/$1"
  mkdir -p "$fixture_bin/$1"
  copy_repo_fixture "$fixture_bin/$1"
}
ek_denies() {
  # $1 = repo copy, $2 = profile; whether that copy's permission denies secret access
  env FIXTURE_LIB="$1/scripts/lib-policy.sh" P="$2" bash -c 'source "$FIXTURE_LIB" || exit 2; ! profile_allows_secrets_access "$P"'
}
ek_rejects() {
  # $1 = repo copy, $2 = profile, $3 = kind; whether that copy's validate-policy
  # fails the profile with the allowSecretsAccess line of KIND's row (captured
  # first: a pipe into grep would take validate-policy's own exit 1 under
  # pipefail)
  local vrc=0 vout
  vout="$("$1/scripts/validate-policy.sh" "$2" 2>&1)" || vrc=$?
  [[ "$vrc" -eq 1 ]] && grep -Fxq "[fail] environmentKind $3 forbids allowSecretsAccess=true (profile $2)" <<< "$vout"
}
ek_copy ek-control
fake_chezmoi '{"profile":"personal"}' 0
ek_gate "$fixture_bin/ek-control"
if [[ "$ek_rc" -eq 0 ]] && grep -Fxq "[ok] secret access granted for profile 'personal'" <<< "$ek_out"; then
  pass "an unchanged repo copy's gate grants personal (control)"
else
  printf '%s\n' "$ek_out" >&2
  miss "the unchanged repo copy's gate must grant personal (rc=$ek_rc)"
fi
# set_environment_kind (test-lib.sh) is fail-closed: an undefined profile, or
# one without an environmentKind, fails and leaves the file as it was (a typo
# would otherwise add a new profile and the cases below would test the
# untouched one).
cp "$fixture_bin/ek-control/.chezmoidata/profiles.yaml" "$fixture_bin/ek-profiles-before"
if ! set_environment_kind "$fixture_bin/ek-control" no-such-profile sandbox 2>/dev/null \
  && cmp -s "$fixture_bin/ek-control/.chezmoidata/profiles.yaml" "$fixture_bin/ek-profiles-before"; then
  pass "set_environment_kind fails on an undefined profile and changes nothing"
else
  miss "set_environment_kind must fail on an undefined profile without writing"
fi
ek_copy ek-nokind
yq -i 'del(.profiles.work.environmentKind)' "$fixture_bin/ek-nokind/.chezmoidata/profiles.yaml"
cp "$fixture_bin/ek-nokind/.chezmoidata/profiles.yaml" "$fixture_bin/ek-profiles-before"
if ! set_environment_kind "$fixture_bin/ek-nokind" work sandbox 2>/dev/null \
  && cmp -s "$fixture_bin/ek-nokind/.chezmoidata/profiles.yaml" "$fixture_bin/ek-profiles-before"; then
  pass "set_environment_kind fails on a profile without an environmentKind and changes nothing"
else
  miss "set_environment_kind must fail on a profile without an environmentKind without writing"
fi
# work with allowSecretsAccess=true: the work row forbids it.
ek_copy ek-work
set_capability_all "$fixture_bin/ek-work" allowSecretsAccess true
fake_chezmoi '{"profile":"work"}' 0
ek_gate "$fixture_bin/ek-work"
if [[ "$ek_rc" -eq 1 ]] \
  && grep -Fxq "[fail] machine profile 'work' sets allowSecretsAccess=true, which environmentKind work forbids; refusing private-backup. Run: ./scripts/validate-policy.sh work" <<< "$ek_out" \
  && ek_rejects "$fixture_bin/ek-work" work work \
  && ek_denies "$fixture_bin/ek-work" work; then
  pass "gate refuses work with allowSecretsAccess=true (environmentKind work forbids it)"
else
  printf '%s\n' "$ek_out" >&2
  miss "gate must refuse work with a forbidden allowSecretsAccess=true (rc=$ek_rc)"
fi
# The same true reached through a YAML alias (work's capabilities are an
# alias of personal's map): the gate's own read sees true, so the table must
# too. The premise is checked first (that read sees true), and validate-policy
# must list the same line (the static check and the gate read the table the
# same way); the refusal line lists more than allowSecretsAccess, in the
# order of the work row.
ek_copy ek-alias
yq -i '.profiles.personal.capabilities anchor = "PC" | .profiles.work.capabilities alias = "PC"' \
  "$fixture_bin/ek-alias/.chezmoidata/profiles.yaml"
ek_gate "$fixture_bin/ek-alias"
if env FIXTURE_LIB="$fixture_bin/ek-alias/scripts/lib-policy.sh" bash -c 'source "$FIXTURE_LIB" || exit 2; profile_capability_is_true work allowSecretsAccess' \
  && ek_rejects "$fixture_bin/ek-alias" work work \
  && [[ "$ek_rc" -eq 1 ]] \
  && grep -Eq "^\[fail\] machine profile 'work' sets .*allowSecretsAccess=true.*, which environmentKind work forbids; refusing private-backup\. Run: \./scripts/validate-policy\.sh work$" <<< "$ek_out" \
  && ek_denies "$fixture_bin/ek-alias" work; then
  pass "gate refuses allowSecretsAccess made true through a YAML alias"
else
  printf '%s\n' "$ek_out" >&2
  miss "gate must refuse a forbidden allowSecretsAccess reached through an alias (rc=$ek_rc)"
fi
# sandbox forbids secret access too: personal retagged to sandbox keeps its true.
ek_copy ek-sandbox
set_environment_kind "$fixture_bin/ek-sandbox" personal sandbox
fake_chezmoi '{"profile":"personal"}' 0
ek_gate "$fixture_bin/ek-sandbox"
if [[ "$ek_rc" -eq 1 ]] \
  && grep -Fxq "[fail] machine profile 'personal' sets allowSecretsAccess=true, which environmentKind sandbox forbids; refusing private-backup. Run: ./scripts/validate-policy.sh personal" <<< "$ek_out" \
  && ek_rejects "$fixture_bin/ek-sandbox" personal sandbox \
  && ek_denies "$fixture_bin/ek-sandbox" personal; then
  pass "gate refuses a sandbox profile with allowSecretsAccess=true"
else
  printf '%s\n' "$ek_out" >&2
  miss "gate must refuse a sandbox profile with allowSecretsAccess=true (rc=$ek_rc)"
fi
# An unknown environmentKind picks no row: refused at the gate, and the
# permission grants nothing either (never read as unconstrained).
ek_copy ek-unknown
set_environment_kind "$fixture_bin/ek-unknown" personal no-such-kind
ek_gate "$fixture_bin/ek-unknown"
if [[ "$ek_rc" -eq 1 ]] \
  && grep -Fxq "[fail] machine profile 'personal' has no valid environmentKind in profiles.yaml, or its capabilities could not be read; refusing private-backup" <<< "$ek_out" \
  && ek_denies "$fixture_bin/ek-unknown" personal; then
  pass "gate refuses a profile whose environmentKind is unknown, and grants nothing"
else
  printf '%s\n' "$ek_out" >&2
  miss "gate must refuse an unknown environmentKind and grant nothing (rc=$ek_rc)"
fi
rm -f "$fixture_bin/chezmoi"

# 5. Consistency with the live host, only when chezmoi can resolve a
#    profile (skipped in CI). The gate's verdict must match the declared
#    allowSecretsAccess literal read straight from profiles.yaml — an
#    expectation independent of the lib's own check. (The previous version
#    compared require_secrets_access against profile_allows_secrets_access,
#    which the gate calls internally: f(x)==f(x), it could never fail. #149)
if resolved="$(resolve_runtime_profile 2>/dev/null)"; then
  declared="$(P="$resolved" yq '.profiles[strenv(P)].capabilities.allowSecretsAccess' "$PROFILES_FILE")"
  if require_secrets_access >/dev/null 2>&1; then verdict="granted"; else verdict="denied"; fi
  if { [[ "$declared" == "true" && "$verdict" == "granted" ]]; } \
    || { [[ "$declared" != "true" && "$verdict" == "denied" ]]; }; then
    pass "gate $verdict matches declared allowSecretsAccess=$declared for live profile '$resolved'"
  else
    miss "gate $verdict but profiles.yaml declares allowSecretsAccess=$declared for '$resolved'"
  fi
else
  item "chezmoi did not resolve a profile; skipping live consistency check"
fi

if [[ "$status" -eq 0 ]]; then
  ok "secrets-gate tests passed"
fi
exit "$status"
