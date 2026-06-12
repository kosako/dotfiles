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

# Modules that declare paths drive .chezmoiignore generation, so their
# declarations must be valid on their own (independent of any profile).
validate_modules() {
  local status=0
  local module path capability value type paths_count requires_count
  local all_paths_file
  all_paths_file="$(mktemp)"

  while IFS= read -r module; do
    [[ -z "$module" ]] && continue

    paths_count=0
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      paths_count=$((paths_count + 1))
      case "$path" in
        /*|*..*)
          fail "module path must be home-relative: $module: $path"
          status=1
          ;;
        *)
          ok "module path: $module: $path"
          printf '%s\n' "$path" >> "$all_paths_file"
          ;;
      esac
    done < <(module_paths "$module")

    requires_count=0
    while read -r capability value; do
      [[ -z "$capability" ]] && continue
      requires_count=$((requires_count + 1))
      if ! grep -Fxq -- "$capability" "$known_caps_file"; then
        fail "unknown capability in $module requires: $capability"
        status=1
        continue
      fi
      if [[ -z "$value" ]]; then
        fail "missing value in $module requires: $capability"
        status=1
        continue
      fi
      type="$(capability_type "$capability")"
      case "$type" in
        boolean)
          if [[ "$value" == "true" || "$value" == "false" ]]; then
            ok "module requires: $module: $capability=$value"
          else
            fail "module requires must be boolean: $module: $capability=$value"
            status=1
          fi
          ;;
        enum)
          if capability_value_is_allowed "$capability" "$value"; then
            ok "module requires: $module: $capability=$value"
          else
            fail "module requires enum invalid: $module: $capability=$value"
            status=1
          fi
          ;;
        *)
          fail "unknown capability type for $capability: $type"
          status=1
          ;;
      esac
    done < <(module_requires "$module")

    if [[ "$requires_count" -gt 0 && "$paths_count" -eq 0 ]]; then
      fail "module has requires but no paths: $module"
      status=1
    fi
  done < "$known_modules_file"

  # A path claimed by two modules would make the ignore gate ambiguous.
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    fail "path declared by multiple modules: $path"
    status=1
  done < <(sort "$all_paths_file" | uniq -d)
  rm -f "$all_paths_file"

  if [[ "$status" -eq 0 ]]; then
    ok "module validation passed"
  else
    fail "module validation failed"
  fi

  return "$status"
}

validate_profile() {
  local profile="$1"
  local status=0
  local environment_kind module capability value type duplicate

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
    if grep -Fxq -- "$module" "$known_modules_file"; then
      ok "module allowed: $module"
    else
      fail "unknown module in $profile: $module"
      status=1
    fi
  done < <(profile_modules "$profile")

  while IFS= read -r capability; do
    [[ -z "$capability" ]] && continue
    if grep -Fxq -- "$capability" "$known_caps_file"; then
      ok "capability allowed: $capability"
    else
      fail "unknown capability in $profile: $capability"
      status=1
    fi
  done < <(profile_capabilities "$profile")

  while IFS= read -r duplicate; do
    [[ -z "$duplicate" ]] && continue
    fail "duplicate capability in $profile: $duplicate"
    status=1
  done < <(profile_capabilities "$profile" | sort | uniq -d)

  while IFS= read -r duplicate; do
    [[ -z "$duplicate" ]] && continue
    fail "duplicate module in $profile: $duplicate"
    status=1
  done < <(profile_modules "$profile" | sort | uniq -d)

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
    profiles="$(known_profiles)"
    # Fail closed: an empty parse must not look like "no profiles, all fine".
    if [[ -z "$profiles" ]]; then
      fail "no profiles parsed from $PROFILES_FILE"
      exit 1
    fi
    printf '%s\n' "$profiles"
    exit 0
    ;;
esac

known_modules_file="$(mktemp)"
known_caps_file="$(mktemp)"
trap 'rm -f "$known_modules_file" "$known_caps_file"' EXIT

known_modules | sort > "$known_modules_file"
known_capabilities | sort > "$known_caps_file"

# Fail closed if the parsers return nothing: an empty known list would
# otherwise validate zero items and pass vacuously.
if [[ ! -s "$known_modules_file" ]]; then
  fail "no modules parsed from $MODULES_FILE"
  exit 1
fi
if [[ ! -s "$known_caps_file" ]]; then
  fail "no capabilities parsed from $CAPABILITIES_FILE"
  exit 1
fi

case "$command" in
  --all)
    status=0
    section "validating modules"
    validate_modules || status=1
    profiles_found=0
    while IFS= read -r profile; do
      [[ -z "$profile" ]] && continue
      profiles_found=1
      section "validating profile: $profile"
      validate_profile "$profile" || status=1
    done < <(known_profiles)
    if [[ "$profiles_found" -eq 0 ]]; then
      fail "no profiles parsed from $PROFILES_FILE"
      exit 1
    fi
    exit "$status"
    ;;
  -*)
    fail "unknown option: $command"
    usage >&2
    exit 2
    ;;
  *)
    status=0
    validate_modules || status=1
    validate_profile "$command" || status=1
    exit "$status"
    ;;
esac
