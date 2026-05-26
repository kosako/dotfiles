#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

profile="${1:-personal}"
status=0

require_data_files || exit 1

if ! profile_exists "$profile"; then
  fail "unknown profile: $profile"
  exit 1
fi

ok "profile exists: $profile"

environment_kind="$(profile_environment_kind "$profile")"
if [[ -z "$environment_kind" ]]; then
  fail "profile has no environmentKind: $profile"
  status=1
elif is_allowed_environment_kind "$environment_kind"; then
  ok "environmentKind: $environment_kind"
else
  fail "unknown environmentKind for $profile: $environment_kind"
  status=1
fi

known_modules_file="$(mktemp)"
known_caps_file="$(mktemp)"
trap 'rm -f "$known_modules_file" "$known_caps_file"' EXIT

known_modules | sort > "$known_modules_file"
known_capabilities | sort > "$known_caps_file"

while IFS= read -r module; do
  [[ -z "$module" ]] && continue
  if grep -Fxq "$module" "$known_modules_file"; then
    ok "module allowed: $module"
  else
    fail "unknown module in $profile: $module"
    status=1
  fi
done < <(profile_modules "$profile")

while IFS= read -r capability; do
  [[ -z "$capability" ]] && continue
  if grep -Fxq "$capability" "$known_caps_file"; then
    ok "capability allowed: $capability"
  else
    fail "unknown capability in $profile: $capability"
    status=1
  fi
done < <(profile_capabilities "$profile")

while IFS= read -r capability; do
  [[ -z "$capability" ]] && continue
  value="$(capability_value "$profile" "$capability")"
  if [[ -z "$value" ]]; then
    fail "missing capability in $profile: $capability"
    status=1
    continue
  fi

  type="$(capability_type "$capability")"
  case "$type" in
    boolean)
      if [[ "$value" == "true" || "$value" == "false" ]]; then
        ok "capability value: $capability=$value"
      else
        fail "capability must be boolean: $capability=$value"
        status=1
      fi
      ;;
    enum)
      if capability_allowed_values "$capability" | grep -Fxq "$value"; then
        ok "capability value: $capability=$value"
      else
        fail "capability enum invalid: $capability=$value"
        status=1
      fi
      ;;
    *)
      fail "unknown capability type for $capability: $type"
      status=1
      ;;
  esac
done < "$known_caps_file"

if [[ "$status" -eq 0 ]]; then
  ok "policy validation passed for profile: $profile"
else
  fail "policy validation failed for profile: $profile"
fi

exit "$status"
