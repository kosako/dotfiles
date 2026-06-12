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

profile_exists() {
  local profile="$1"
  awk -v profile="$profile" '$0 == "  " profile ":" { found = 1 } END { exit !found }' "$PROFILES_FILE"
}

known_profiles() {
  awk '
    /^  [^ ].*:[[:space:]]*$/ {
      name = $1
      sub(/:$/, "", name)
      print name
    }
  ' "$PROFILES_FILE"
}

profile_environment_kind() {
  local profile="$1"
  awk -v profile="$profile" '
    $0 == "  " profile ":" { in_profile = 1; next }
    in_profile && /^  [^ ].*:[[:space:]]*$/ { exit }
    in_profile && /^    environmentKind:/ { print $2; exit }
  ' "$PROFILES_FILE"
}

profile_modules() {
  local profile="$1"
  awk -v profile="$profile" '
    $0 == "  " profile ":" { in_profile = 1; next }
    in_profile && /^  [^ ].*:[[:space:]]*$/ { exit }
    in_profile && /^    modules:/ { in_modules = 1; next }
    in_profile && /^    [A-Za-z0-9_-]+:/ { in_modules = 0 }
    in_profile && in_modules && /^      - / {
      sub(/^      - /, "")
      print
    }
  ' "$PROFILES_FILE"
}

profile_capabilities() {
  local profile="$1"
  awk -v profile="$profile" '
    $0 == "  " profile ":" { in_profile = 1; next }
    in_profile && /^  [^ ].*:[[:space:]]*$/ { exit }
    in_profile && /^    capabilities:/ { in_caps = 1; next }
    in_profile && /^    [A-Za-z0-9_-]+:/ { in_caps = 0 }
    in_profile && in_caps && /^      [A-Za-z0-9_-]+:/ {
      key = $1
      sub(/:$/, "", key)
      print key
    }
  ' "$PROFILES_FILE"
}

capability_value() {
  local profile="$1"
  local capability="$2"
  awk -v profile="$profile" -v capability="$capability" '
    $0 == "  " profile ":" { in_profile = 1; next }
    in_profile && /^  [^ ].*:[[:space:]]*$/ { exit }
    in_profile && /^    capabilities:/ { in_caps = 1; next }
    in_profile && /^    [A-Za-z0-9_-]+:/ { in_caps = 0 }
    in_profile && in_caps && $1 == capability ":" { print $2; exit }
  ' "$PROFILES_FILE"
}

known_modules() {
  awk '
    /^  [^ ].*:[[:space:]]*$/ {
      name = $1
      sub(/:$/, "", name)
      print name
    }
  ' "$MODULES_FILE"
}

known_capabilities() {
  awk '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      name = $1
      sub(/:$/, "", name)
      print name
    }
  ' "$CAPABILITIES_FILE"
}

capability_type() {
  local capability="$1"
  awk -v capability="$capability" '
    $0 == "  " capability ":" { in_cap = 1; next }
    in_cap && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    in_cap && /^    type:/ { print $2; exit }
  ' "$CAPABILITIES_FILE"
}

capability_allowed_values() {
  local capability="$1"
  awk -v capability="$capability" '
    $0 == "  " capability ":" { in_cap = 1; next }
    in_cap && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    in_cap && /^    values:/ { in_values = 1; next }
    in_cap && in_values && /^      - / {
      sub(/^      - /, "")
      print
    }
    in_cap && in_values && /^    [A-Za-z0-9_-]+:/ { exit }
  ' "$CAPABILITIES_FILE"
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
