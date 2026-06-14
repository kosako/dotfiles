#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILES_FILE="$DOTFILES_ROOT/.chezmoidata/profiles.yaml"
MODULES_FILE="$DOTFILES_ROOT/.chezmoidata/modules.yaml"
CAPABILITIES_FILE="$DOTFILES_ROOT/.chezmoidata/capabilities.schema.yaml"

ok() {
  printf '[ok] %s\n' "$*"
}

info() {
  printf '[info] %s\n' "$*"
}

section() {
  printf '[info] == %s ==\n' "$*"
}

item() {
  printf '[info] - %s\n' "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

fail() {
  printf '[fail] %s\n' "$*" >&2
}

# The policy parsers below require mikefarah/yq v4. Fail closed and
# loudly on a missing binary or the unrelated Python "yq", so a wrong
# tool never silently parses nothing and passes vacuously.
require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    fail "yq not found; install mikefarah/yq v4 (brew install yq). See docs/policy-model.md"
    return 1
  fi
  local version major
  version="$(yq --version 2>/dev/null)"
  if [[ "$version" != *mikefarah* ]]; then
    fail "wrong yq variant: need mikefarah/yq v4, got: ${version:-unknown}"
    return 1
  fi
  major="${version##*version }"
  major="${major#v}"
  major="${major%%.*}"
  if [[ ! "$major" =~ ^[0-9]+$ ]] || ((major < 4)); then
    fail "yq v4+ required, got: $version"
    return 1
  fi
  return 0
}

require_data_files() {
  local missing=0
  for file in "$PROFILES_FILE" "$MODULES_FILE" "$CAPABILITIES_FILE"; do
    if [[ ! -f "$file" ]]; then
      fail "missing data file: $file"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]]
}

# Names are passed to yq via strenv(), never interpolated into the
# expression, so a name with special characters cannot break or inject
# into the query.

profile_exists() {
  local profile="$1"
  [[ "$(p="$profile" yq '.profiles // {} | has(strenv(p))' "$PROFILES_FILE" 2>/dev/null)" == "true" ]]
}

known_profiles() {
  yq '.profiles // {} | keys | .[]' "$PROFILES_FILE"
}

profile_environment_kind() {
  local profile="$1"
  # environmentKind is always a string, so // "" only fires on absence.
  p="$profile" yq '.profiles[strenv(p)].environmentKind // ""' "$PROFILES_FILE"
}

profile_modules() {
  local profile="$1"
  p="$profile" yq '.profiles[strenv(p)].modules[]?' "$PROFILES_FILE"
}

profile_capabilities() {
  local profile="$1"
  # // {} guards an absent capabilities map; duplicate keys are kept in
  # the output so callers can detect them with `sort | uniq -d`.
  p="$profile" yq '.profiles[strenv(p)].capabilities // {} | keys | .[]' "$PROFILES_FILE"
}

capability_value() {
  local profile="$1"
  local capability="$2"
  # select(has()) yields nothing when the key is absent while keeping a
  # literal false value; a bare `// ""` would collapse false into "".
  p="$profile" c="$capability" \
    yq '.profiles[strenv(p)].capabilities // {} | select(has(strenv(c))) | .[strenv(c)]' "$PROFILES_FILE"
}

known_modules() {
  yq '.modules // {} | keys | .[]' "$MODULES_FILE"
}

module_paths() {
  local module="$1"
  m="$module" yq '.modules[strenv(m)].paths[]?' "$MODULES_FILE"
}

# Print "capability value" pairs from a module requires: section.
module_requires() {
  local module="$1"
  m="$module" \
    yq '.modules[strenv(m)].requires // {} | to_entries | .[] | .key + " " + (.value | tostring)' "$MODULES_FILE"
}

# A module's paths are managed for a profile when the profile lists the
# module and every requires: condition matches the profile's value.
# Mirrors the .chezmoiignore generation logic.
module_active_for_profile() {
  local profile="$1"
  local module="$2"
  local capability value modules

  # Capture, then test against a here-string. A `yq | grep -q` pipe
  # would make yq exit with SIGPIPE once grep -q closes it early, which
  # trips callers running under `set -o pipefail` (e.g. doctor.sh).
  modules="$(profile_modules "$profile")"
  grep -Fxq -- "$module" <<< "$modules" || return 1

  while read -r capability value; do
    [[ -z "$capability" ]] && continue
    [[ "$(capability_value "$profile" "$capability")" == "$value" ]] || return 1
  done < <(module_requires "$module")
  return 0
}

known_capabilities() {
  yq '.capabilities // {} | keys | .[]' "$CAPABILITIES_FILE"
}

capability_type() {
  local capability="$1"
  # type is always a string, so // "" only fires on absence.
  c="$capability" yq '.capabilities[strenv(c)].type // ""' "$CAPABILITIES_FILE"
}

capability_allowed_values() {
  local capability="$1"
  c="$capability" yq '.capabilities[strenv(c)].values[]?' "$CAPABILITIES_FILE"
}

capability_value_is_allowed() {
  local capability="$1"
  local value="$2"
  local allowed_value

  while IFS= read -r allowed_value; do
    if [[ "$allowed_value" == "$value" ]]; then
      return 0
    fi
  done < <(capability_allowed_values "$capability")

  return 1
}

is_allowed_environment_kind() {
  case "$1" in
    personal|work|client|sandbox|agent) return 0 ;;
    *) return 1 ;;
  esac
}

# Boolean capabilities that must be false for a given environmentKind.
# Encodes the policy that work / client / agent environments do not carry
# elevated permissions (install, system mutation, secrets, network, AI
# tooling) by default, and that sandbox forbids secret access. personal
# is unconstrained; enum capabilities are out of scope here. See
# docs/policy-model.md. agent has no profile yet; the row is defined so
# the constraint takes effect the moment an agent profile is added.
environment_kind_forbidden_capabilities() {
  case "$1" in
    work | client | agent)
      printf '%s\n' \
        installPackages \
        installGuiApps \
        enableMacOSDefaults \
        allowSecretsAccess \
        allowNetworkTunnels \
        enableAiTools
      ;;
    sandbox)
      printf '%s\n' allowSecretsAccess
      ;;
  esac
}

# Print names of remotes whose URL embeds password-like userinfo
# (scheme://user:password@host). URL values are never printed.
git_remotes_with_credentials() {
  local repo="$1"
  git -C "$repo" config --local --get-regexp '^remote\..*\.url$' 2>/dev/null |
    awk '$2 ~ /:\/\/[^\/@]*:[^\/@]+@/ {
      name = $1
      sub(/^remote\./, "", name)
      sub(/\.url$/, "", name)
      print name
    }'
}

command_status() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    ok "$command_name: $(command -v "$command_name")"
    return 0
  fi
  warn "$command_name: not found"
  return 1
}
