#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# A signal that ends the run mid-report leaves no report writer behind
# (#378, lib-policy.sh); INT and TERM are ignored first, so a second signal
# cannot cut that short.
trap 'trap "" INT TERM; report_write_stop' EXIT

usage() {
  cat <<EOF
Usage:
  $0 [profile]      (default: personal)
  $0 --all
  $0 --list-profiles

Validate the policy data: modules, the capability registry, the software
catalog (packages.yaml), the backup-paths catalog, and the given profile
(--all: every profile).
EOF
}

# Report every line on stdin (a `sort | uniq -d` stream) as a duplicate,
# prefixed with $1. Returns non-zero when any duplicate was seen; callers
# fold that into their status with `fail_duplicates "..." < <(...) ||
# status=1` (keep the `||` — a bare call would trip set -e).
fail_duplicates() {
  local d found=0
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    fail "$1$d"
    found=1
  done
  [[ "$found" -eq 0 ]]
}

# The profiles, modules and capabilities are listed by their keys, one per
# line, so a key holding a newline would be validated as two names while
# chezmoi reads the one real key (#428). Checked before anything is listed.
# Args: label yq-path file.
check_name_map() {
  local rc=0
  yaml_name_map "$2" "$3" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) fail "cannot read the $1 in $3" ;;
    *) fail "$1 must be a map keyed by names (strings without control characters): $3" ;;
  esac
  return 1
}

# Modules that declare paths drive .chezmoiignore generation, so their
# declarations must be valid on their own (independent of any profile).
validate_modules() {
  local status=0
  local module path capability value type paths_count paths_shape paths_list requires_count requires requires_shape
  # Collected in a variable, not a temp file, so an interrupt leaves nothing
  # behind (#329; the same holds for the lists in validate_packages and
  # validate_backup_paths).
  local all_paths=""

  while IFS= read -r module; do
    [[ -z "$module" ]] && continue

    paths_count=0
    # Same shape check as a profile's modules (#412, #422): a string, bool or
    # number under paths: lists as nothing and passes when the module has no
    # requires, and a newline in one path lists as two.
    paths_shape=0
    m="$module" yaml_string_list '.modules[strenv(m)].paths' "$MODULES_FILE" || paths_shape=$?
    # Captured, not read through a process substitution, so a failed listing
    # after the shape check is reported too.
    if [[ "$paths_shape" -eq 0 ]] && ! paths_list="$(module_paths "$module")"; then
      paths_shape=2
    fi
    case "$paths_shape" in
      0)
        while IFS= read -r path; do
          [[ -z "$path" ]] && continue
          paths_count=$((paths_count + 1))
          case "$path" in
            /*|*..*)
              fail "module path must be home-relative: $module: $path"
              status=1
              ;;
            # Each declared path becomes a literal "!<path>" line of the
            # .chezmoiignore allowlist (#207). Pattern characters, whitespace,
            # a leading "~" / "./" or a trailing "/" would change what that line
            # admits (or match nothing), so they are rejected here.
            *[][*?{}!#\\]*|*[[:space:]]*|~*|.|./*|*/.|*/./*|*//*|*/)
              fail "module path must be a literal path (no pattern characters, whitespace, or trailing slash): $module: $path"
              status=1
              ;;
            *)
              ok "module path: $module: $path"
              all_paths+="$path"$'\n'
              ;;
          esac
        done <<< "$paths_list"
        ;;
      2)
        fail "cannot read the paths of module $module"
        status=1
        ;;
      *)
        fail "module paths must be a list of paths (strings without control characters): $module"
        status=1
        ;;
    esac

    # Capture the status before consuming entries; a failed enumeration is
    # not an empty set of conditions, even if yq emitted partial output.
    if ! requires="$(module_requires "$module")"; then
      fail "cannot enumerate module requires: $module"
      status=1
      continue
    fi
    # The listing has one `capability value` line per condition, so a key or
    # a value holding a newline would read as two conditions, each of which
    # could pass, while .chezmoiignore compares the value itself (#428).
    # module_requires has already refused a requires that is not a map.
    requires_shape=0
    m="$module" yaml_name_map '.modules[strenv(m)].requires' "$MODULES_FILE" || requires_shape=$?
    if [[ "$requires_shape" -eq 0 ]]; then
      m="$module" yaml_plain_string_values '.modules[strenv(m)].requires' "$MODULES_FILE" || requires_shape=$?
    fi
    case "$requires_shape" in
      0) ;;
      2)
        fail "cannot read the requires of module $module"
        status=1
        continue
        ;;
      *)
        fail "module requires must map capability names to values without control characters: $module"
        status=1
        continue
        ;;
    esac
    requires_count=0
    while read -r capability value; do
      [[ -z "$capability" ]] && continue
      requires_count=$((requires_count + 1))
      if ! grep -Fxq -- "$capability" <<< "$known_caps_list"; then
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
          if m="$module" c="$capability" yq -e \
            '.modules[strenv(m)].requires[strenv(c)] | ((tag == "!!bool") and (. == true or . == false))' \
            "$MODULES_FILE" >/dev/null; then
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
    done <<< "$requires"

    if [[ "$paths_shape" -eq 0 && "$requires_count" -gt 0 && "$paths_count" -eq 0 ]]; then
      fail "module has requires but no paths: $module"
      status=1
    fi
  done <<< "$known_modules_list"

  # A path claimed by two modules would make the ignore gate ambiguous.
  fail_duplicates "path declared by multiple modules: " \
    < <(sort <<< "$all_paths" | uniq -d) || status=1

  if [[ "$status" -eq 0 ]]; then
    ok "module validation passed"
  else
    fail "module validation failed"
  fi

  return "$status"
}

# Capability registry (#151): every capability must declare
# implemented: true|false (fail closed — an unlabeled capability cannot claim
# honest-labeling). implemented: false additionally requires a doctor
# disclosure; the static proxy is that doctor.sh mentions the capability name
# at all. This is a source-text check, not a behavior check (a mention inside
# a comment would satisfy it), but it catches exactly the failure #145
# removed: a capability living in schema + profiles with zero doctor
# references. The keep-criterion for implemented: false entries is in
# docs/policy-model.md.
validate_capability_registry() {
  local status=0 capability impl values_shape
  local doctor_script="$DOTFILES_ROOT/scripts/doctor.sh"
  while IFS= read -r capability; do
    [[ -z "$capability" ]] && continue
    # An enum's values are listed one per line (capability_allowed_values),
    # so a value holding a newline would allow two values (#428).
    values_shape=0
    c="$capability" yaml_string_list '.capabilities[strenv(c)].values' "$CAPABILITIES_FILE" || values_shape=$?
    case "$values_shape" in
      0) ;;
      2)
        fail "cannot read the values of capability $capability"
        status=1
        ;;
      *)
        fail "capability registry: $capability values must be a list of strings without control characters"
        status=1
        ;;
    esac
    impl="$(capability_implemented "$capability")"
    if ! c="$capability" yq -e \
      '.capabilities[strenv(c)].implemented | ((tag == "!!bool") and (. == true or . == false))' \
      "$CAPABILITIES_FILE" >/dev/null; then
      fail "capability registry: $capability lacks implemented: true|false (must be a YAML boolean)"
      status=1
      continue
    fi
    case "$impl" in
      true)
        ok "capability registry: $capability implemented=true"
        ;;
      false)
        if grep -Fq -- "$capability" "$doctor_script"; then
          ok "capability registry: $capability implemented=false, doctor discloses it"
        else
          fail "capability registry: $capability is implemented=false but doctor.sh never mentions it (undisclosed dormant declaration)"
          status=1
        fi
        ;;
      *)
        fail "capability registry: $capability lacks implemented: true|false"
        status=1
        ;;
    esac
  done <<< "$known_caps_list"

  if [[ "$status" -eq 0 ]]; then
    ok "capability registry validation passed"
  else
    fail "capability registry validation failed"
  fi

  return "$status"
}

# The software catalog (packages.yaml) is profile-independent data, like
# modules: every entry must name a known source, go_install / mas need an
# explicit canonical pkg id (a bare name cannot reconstruct a module path
# or app id), and names must be unique.
validate_packages() {
  local status=0
  local name source pkg bin track_only entry_ok rows
  local sources names=""
  sources="$(known_package_sources)"

  # Fail closed: a yq error or a missing/empty packages list must not pass
  # vacuously (mirrors the profiles / modules / capabilities guards).
  if ! rows="$(catalog_packages)"; then
    fail "could not parse packages from $PACKAGES_FILE"
    return 1
  fi
  if [[ -z "$rows" ]]; then
    fail "no packages parsed from $PACKAGES_FILE"
    return 1
  fi

  while IFS='|' read -r name source pkg bin track_only; do
    [[ -z "$name$source$pkg$bin$track_only" ]] && continue
    entry_ok=1
    if [[ -z "$name" ]]; then
      fail "package missing name (source=${source:-none})"
      status=1
      continue
    fi
    if [[ -z "$source" ]]; then
      fail "package missing source: $name"
      status=1
      continue
    fi
    if ! grep -Fxq -- "$source" <<< "$sources"; then
      fail "unknown package source: $name: $source"
      status=1
      continue
    fi
    names+="$name"$'\n'
    case "$track_only" in
      true | false | "") ;;
      *)
        fail "package track_only must be true or false: $name: $track_only"
        status=1
        entry_ok=0
        ;;
    esac
    if [[ "$track_only" != "true" && -z "$pkg" ]]; then
      case "$source" in
        go_install | mas)
          fail "$source package needs an explicit pkg (canonical id): $name"
          status=1
          entry_ok=0
          ;;
      esac
    fi
    [[ "$entry_ok" -eq 1 ]] && ok "package: $name ($source)"
  done <<< "$rows"

  fail_duplicates "duplicate package name: " \
    < <(sort <<< "$names" | uniq -d) || status=1

  if [[ "$status" -eq 0 ]]; then
    ok "package validation passed"
  else
    fail "package validation failed"
  fi

  return "$status"
}

# The private-backup catalog (backup-paths.yaml) is profile-independent
# data. Every entry needs a home-relative path (no leading "/", no "..",
# no glob metacharacters), an optional type from a known set, and paths
# must be unique. Public-safety of the listed paths is a human review
# concern (this file is committed to a public repo); validation enforces
# the mechanical safety rules only.
validate_backup_paths() {
  local status=0
  local line path type _category entry_ok rows
  local types paths=""
  types="$(known_backup_path_types)"

  # Fail closed: a yq error or a missing/empty list must not pass vacuously.
  if ! rows="$(backup_paths)"; then
    fail "could not parse backup paths from $BACKUP_PATHS_FILE"
    return 1
  fi
  if [[ -z "$rows" ]]; then
    fail "no backup paths parsed from $BACKUP_PATHS_FILE"
    return 1
  fi

  # Strip only the two leading fields, preserving any "|" in the path. An
  # entry that resolves to an empty path (a null/empty list item, or a
  # missing path: key) must fail closed, not be silently skipped: backup_paths
  # always emits at least two "|" per entry, so there are no blank rows to skip.
  # _category is a field-splitting placeholder: backup_paths emits
  # type|category|path but validation has no category rule (the leading
  # underscore marks it intentionally unused for SC2034).
  while IFS= read -r line; do
    type="${line%%|*}"; line="${line#*|}"
    _category="${line%%|*}"; path="${line#*|}"
    entry_ok=1
    if [[ -z "$path" ]]; then
      fail "backup path entry missing path"
      status=1
      continue
    fi
    # backup_path_is_safe (lib-policy.sh) is the single authority on
    # whether a path is accepted; the case below only derives a specific
    # message for the rejection. Keeping the decision in one place stops
    # the safety rule from drifting between validation and the runtime.
    if ! backup_path_is_safe "$path"; then
      status=1
      entry_ok=0
      case "$path" in
        /*) fail "backup path must be home-relative (no leading /): $path" ;;
        *..*) fail "backup path must not contain ..: $path" ;;
        *[*?[]*) fail "backup path must not contain glob metacharacters: $path" ;;
        *) fail "unsafe backup path: $path" ;;
      esac
    fi
    if [[ -n "$type" ]] && ! grep -Fxq -- "$type" <<< "$types"; then
      fail "unknown backup path type: $path: $type"
      status=1
      entry_ok=0
    fi
    paths+="$path"$'\n'
    [[ "$entry_ok" -eq 1 ]] && ok "backup path: $path"
  done <<< "$rows"

  fail_duplicates "duplicate backup path: " \
    < <(sort <<< "$paths" | uniq -d) || status=1

  if [[ "$status" -eq 0 ]]; then
    ok "backup path validation passed"
  else
    fail "backup path validation failed"
  fi

  return "$status"
}

validate_profile() {
  local profile="$1"
  local status=0
  local environment_kind module capability value type forbidden ek_violations ek_list modules_shape modules_list caps_shape

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

  # A string, bool, number or map under modules: would list as nothing or as
  # the map's values (#412), and a newline in one name as two names (#422),
  # so the shape is checked before the names.
  modules_shape=0
  p="$profile" yaml_string_list '.profiles[strenv(p)].modules' "$PROFILES_FILE" || modules_shape=$?
  # Captured once (a failed listing is reported too) and reused below.
  if [[ "$modules_shape" -eq 0 ]] && ! modules_list="$(profile_modules "$profile")"; then
    modules_shape=2
  fi
  case "$modules_shape" in
    0)
      while IFS= read -r module; do
        [[ -z "$module" ]] && continue
        if grep -Fxq -- "$module" <<< "$known_modules_list"; then
          ok "module allowed: $module"
        else
          fail "unknown module in $profile: $module"
          status=1
        fi
      done <<< "$modules_list"
      ;;
    2)
      fail "cannot read the modules of profile $profile"
      status=1
      ;;
    *)
      fail "profile modules must be a list of module names (strings without control characters): $profile"
      status=1
      ;;
  esac

  # The capabilities are listed by key, so a key holding a newline would read
  # as two names (#428). The value checks below look each known capability
  # up by name and run either way.
  caps_shape=0
  p="$profile" yaml_name_map '.profiles[strenv(p)].capabilities' "$PROFILES_FILE" || caps_shape=$?
  case "$caps_shape" in
    0)
      while IFS= read -r capability; do
        [[ -z "$capability" ]] && continue
        if grep -Fxq -- "$capability" <<< "$known_caps_list"; then
          ok "capability allowed: $capability"
        else
          fail "unknown capability in $profile: $capability"
          status=1
        fi
      done < <(profile_capabilities "$profile")

      fail_duplicates "duplicate capability in $profile: " \
        < <(profile_capabilities "$profile" | sort | uniq -d) || status=1
      ;;
    2)
      fail "cannot read the capabilities of profile $profile"
      status=1
      ;;
    *)
      fail "profile capabilities must be a map keyed by capability names (strings without control characters): $profile"
      status=1
      ;;
  esac

  if [[ "$modules_shape" -eq 0 ]]; then
    fail_duplicates "duplicate module in $profile: " \
      < <(sort <<< "$modules_list" | uniq -d) || status=1
  fi

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
        if p="$profile" c="$capability" yq -e \
          '.profiles[strenv(p)].capabilities[strenv(c)] | ((tag == "!!bool") and (. == true or . == false))' \
          "$PROFILES_FILE" >/dev/null; then
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
  done <<< "$known_caps_list"

  # environmentKind cross-check: boolean capabilities the environmentKind
  # forbids must be false, and enum capabilities must not carry a forbidden
  # value (#45: npmHardeningMode=off is below the work/client/agent floor).
  # This makes the work/client/agent/sandbox restrictions a hard invariant
  # rather than a convention (see docs/policy-model.md). Only meaningful for
  # a valid kind; an unknown/missing environmentKind has already failed
  # above, and must not print "satisfied".
  if is_allowed_environment_kind "$environment_kind"; then
    ek_violations=0
    # The boolean rows go through the listing the runtime gates refuse on
    # (profile_environment_kind_violations, #357), so the static check and
    # install / private-backup cannot apply the table differently. A failed
    # read is a failure, never "no violations".
    if ek_list="$(profile_environment_kind_violations "$profile")"; then
      while IFS= read -r forbidden; do
        [[ -z "$forbidden" ]] && continue
        fail "environmentKind $environment_kind forbids $forbidden=true (profile $profile)"
        status=1
        ek_violations=$((ek_violations + 1))
      done <<< "$ek_list"
    else
      fail "could not read the environmentKind constraints of profile $profile"
      status=1
      ek_violations=$((ek_violations + 1))
    fi
    while IFS= read -r pair; do
      [[ -z "$pair" ]] && continue
      # The table row itself is checked fail-closed: a malformed pair or a
      # capability/value that the schema does not know would otherwise be a
      # silently dead constraint — the exact failure mode this cross-check
      # exists to prevent (#45).
      if [[ "$pair" != *=* ]]; then
        fail "forbidden-enum row malformed for $environment_kind: '$pair' (expected capability=value)"
        status=1
        ek_violations=$((ek_violations + 1))
        continue
      fi
      enum_cap="${pair%%=*}"
      forbidden_value="${pair#*=}"
      if [[ "$(capability_type "$enum_cap")" != "enum" ]] \
        || ! capability_value_is_allowed "$enum_cap" "$forbidden_value"; then
        fail "forbidden-enum row invalid for $environment_kind: $pair (not a declared enum value)"
        status=1
        ek_violations=$((ek_violations + 1))
        continue
      fi
      value="$(capability_value "$profile" "$enum_cap")"
      if [[ "$value" == "$forbidden_value" ]]; then
        fail "environmentKind $environment_kind forbids $enum_cap=$forbidden_value (profile $profile)"
        status=1
        ek_violations=$((ek_violations + 1))
      fi
    done < <(environment_kind_forbidden_enum_values "$environment_kind")
    if [[ "$ek_violations" -eq 0 ]]; then
      ok "environmentKind constraints satisfied: $environment_kind"
    fi
  fi

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

require_yq || exit 1
require_data_files || exit 1

# The profile names are listed by --list-profiles and --all; the module and
# capability names feed every check below (#428).
check_name_map profiles '.profiles' "$PROFILES_FILE" || exit 1

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

names_status=0
check_name_map modules '.modules' "$MODULES_FILE" || names_status=1
check_name_map capabilities '.capabilities' "$CAPABILITIES_FILE" || names_status=1
[[ "$names_status" -eq 0 ]] || exit 1

# The known lists are held in variables, not temp files behind an EXIT
# trap: bash 3.2 runs no EXIT trap when Ctrl-C ends the script, so such
# files were left in TMPDIR (#329).
known_modules_list="$(known_modules | sort)"
known_caps_list="$(known_capabilities | sort)"

# Fail closed if the parsers return nothing: an empty known list would
# otherwise validate zero items and pass vacuously.
if [[ -z "$known_modules_list" ]]; then
  fail "no modules parsed from $MODULES_FILE"
  exit 1
fi
if [[ -z "$known_caps_list" ]]; then
  fail "no capabilities parsed from $CAPABILITIES_FILE"
  exit 1
fi

case "$command" in
  --all)
    status=0
    section "validating modules"
    validate_modules || status=1
    section "validating capability registry"
    validate_capability_registry || status=1
    section "validating packages"
    validate_packages || status=1
    section "validating backup paths"
    validate_backup_paths || status=1
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
    validate_capability_registry || status=1
    validate_packages || status=1
    validate_backup_paths || status=1
    validate_profile "$command" || status=1
    exit "$status"
    ;;
esac
