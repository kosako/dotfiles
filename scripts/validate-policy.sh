#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

usage() {
  cat <<EOF
Usage:
  $0 [profile]
  $0 --all
  $0 --list-profiles

Validate profile/module/capability policy data.
EOF
}

validate_profile() {
  local profile="$1"
  local status=0
  local environment_kind module capability value type

  if ! profile_exists "$profile"; then
    fail "unknown profile: $profile"
    return 1
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
        if capability_value_is_allowed "$capability" "$value"; then
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

  return "$status"
}

if [[ "$#" -gt 1 ]]; then
  usage >&2
  exit 2
fi

command="${1:-personal}"

case "$command" in
  -h|--help)
    usage
    exit 0
    ;;
esac

require_data_files || exit 1

case "$command" in
  --list-profiles)
    known_profiles
    exit 0
    ;;
esac

known_modules_file="$(mktemp)"
known_caps_file="$(mktemp)"
trap 'rm -f "$known_modules_file" "$known_caps_file"' EXIT

known_modules | sort > "$known_modules_file"
known_capabilities | sort > "$known_caps_file"

case "$command" in
  --all)
    status=0
    while IFS= read -r profile; do
      [[ -z "$profile" ]] && continue
      section "validating profile: $profile"
      validate_profile "$profile" || status=1
    done < <(known_profiles)
    exit "$status"
    ;;
  --*)
    fail "unknown option: $command"
    usage >&2
    exit 2
    ;;
  *)
    validate_profile "$command"
    exit "$?"
    ;;
esac
