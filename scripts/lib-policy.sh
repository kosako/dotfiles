#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILES_FILE="$DOTFILES_ROOT/.chezmoidata/profiles.yaml"
MODULES_FILE="$DOTFILES_ROOT/.chezmoidata/modules.yaml"
CAPABILITIES_FILE="$DOTFILES_ROOT/.chezmoidata/capabilities.schema.yaml"
PACKAGES_FILE="$DOTFILES_ROOT/.chezmoidata/packages.yaml"

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
  for file in "$PROFILES_FILE" "$MODULES_FILE" "$CAPABILITIES_FILE" "$PACKAGES_FILE"; do
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

# Valid sources for the software catalog (packages.yaml). Validation and
# drift detection check against this set; an unknown source is a
# fail-closed error. See docs/policy-model.md.
known_package_sources() {
  printf '%s\n' \
    brew_formula \
    brew_cask \
    npm_global \
    go_install \
    mas \
    manual
}

# Emit one row per catalog package as pipe-joined fields:
#   name|source|pkg|bin|track_only
# pkg and bin are raw (empty when unset) so validation can detect a missing
# canonical id; consumers default pkg and bin to name. A non-whitespace
# delimiter is used on purpose: `read` collapses consecutive IFS-whitespace
# (tab/space), which would drop empty fields, while "|" never appears in a
# package identifier. Read it back with IFS='|'. Drift matching uses the
# canonical id (pkg, defaulting to name) per source. This reads the data
# file, not user input, so values are not passed through strenv.
catalog_packages() {
  yq '.packages[]? | [(.name // ""), (.source // ""), (.pkg // ""), (.bin // ""), ((.track_only // false) | tostring)] | join("|")' "$PACKAGES_FILE"
}

# Emit the advisory source-preference order for a category (cli / gui).
catalog_source_preference() {
  local category="$1"
  c="$category" yq '.source_preference[strenv(c)][]?' "$PACKAGES_FILE"
}

# Report drift between the declared catalog (packages.yaml) and what is
# actually installed, per source. Report-only: every path returns 0 so a
# caller under `set -e` (doctor.sh) keeps its exit code, and all probes are
# read-only with a missing package manager skipped rather than failed.
#
# Three drift kinds (see docs/policy-model.md):
#   - declared but not installed          -> warn (suggest installing)
#   - installed but not declared (sprawl) -> warn (undeclared)
#   - declared source vs reality mismatch -> info (declared in source S,
#                                            absent from S, yet the command
#                                            resolves on PATH)
#
# Matching uses the canonical installed id (pkg, defaulting to name) per
# source, never a cross-manager name table: the catalog design rejected
# cross-source availability checks as unreliable. The source-mismatch
# signal is deliberately weak ("not in S's inventory but on PATH") because
# it never guesses which other manager owns the tool. Undeclared detection
# uses `brew leaves` (top-level installs) so dependencies are not flagged,
# excludes node-bundled npm globals (npm, corepack: runtime domain, like
# node/go/uv), and is skipped for mas (the App Store carries many apps
# unrelated to the dev catalog; flagging them all would be noise).
report_catalog_drift() {
  if ! require_yq; then
    warn "yq unavailable; skipping catalog drift"
    return 0
  fi
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    warn "catalog missing: $PACKAGES_FILE; skipping drift"
    return 0
  fi

  local rows
  if ! rows="$(catalog_packages)" || [[ -z "$rows" ]]; then
    warn "could not read catalog packages; skipping drift"
    return 0
  fi

  local brew_formulae brew_leaves brew_casks npm_globals go_bins mas_ids
  local decl_brew_formula decl_brew_cask decl_npm decl_go_bins
  brew_formulae="$(mktemp)"; brew_leaves="$(mktemp)"; brew_casks="$(mktemp)"
  npm_globals="$(mktemp)"; go_bins="$(mktemp)"; mas_ids="$(mktemp)"
  decl_brew_formula="$(mktemp)"; decl_brew_cask="$(mktemp)"
  decl_npm="$(mktemp)"; decl_go_bins="$(mktemp)"
  local drift_tmp=(
    "$brew_formulae" "$brew_leaves" "$brew_casks" "$npm_globals" "$go_bins"
    "$mas_ids" "$decl_brew_formula" "$decl_brew_cask" "$decl_npm"
    "$decl_go_bins"
  )

  # Inventories (read-only). A failing probe leaves the list empty via
  # `|| true`; per-source availability flags gate whether absence means
  # "not installed" or "manager not present, skip".
  local have_brew=0 have_npm=0 have_mas=0 gobin=""
  if command -v brew >/dev/null 2>&1; then
    have_brew=1
    brew list --formula -1 2>/dev/null | sort > "$brew_formulae" || true
    brew leaves 2>/dev/null | sort > "$brew_leaves" || true
    brew list --cask -1 2>/dev/null | sort > "$brew_casks" || true
  fi
  if command -v npm >/dev/null 2>&1; then
    have_npm=1
    npm ls -g --depth=0 --json 2>/dev/null \
      | yq -p json '.dependencies // {} | keys | .[]' 2>/dev/null \
      | grep -vxE 'npm|corepack' | sort > "$npm_globals" || true
  fi
  if command -v go >/dev/null 2>&1; then
    gobin="$(go env GOBIN 2>/dev/null || true)"
    [[ -z "$gobin" ]] && gobin="$(go env GOPATH 2>/dev/null || true)/bin"
  else
    gobin="${GOPATH:-$HOME/go}/bin"
  fi
  if [[ -n "$gobin" && -d "$gobin" ]]; then
    find "$gobin" -maxdepth 1 -type f -perm -u+x -exec basename {} \; 2>/dev/null \
      | sort > "$go_bins" || true
  fi
  if command -v mas >/dev/null 2>&1; then
    have_mas=1
    mas list 2>/dev/null | awk '{print $1}' | sort > "$mas_ids" || true
  fi

  # Report which inventories were inspected. npm's global root differs by
  # active node (mise-managed vs system); naming it avoids misreading a
  # shim-shadowed inventory (same root cause as the mise shims problem).
  if [[ "$have_brew" -eq 1 ]]; then
    item "brew: $(command -v brew)"
  else
    item "brew: not found (brew sources skipped)"
  fi
  if [[ "$have_npm" -eq 1 ]]; then
    item "npm: $(command -v npm) (global root: $(npm root -g 2>/dev/null || echo unknown))"
  else
    item "npm: not found (npm_global sources skipped)"
  fi
  item "go bin: ${gobin:-unknown}"
  if [[ "$have_mas" -eq 1 ]]; then
    item "mas: $(command -v mas)"
  else
    item "mas: not found (mas sources skipped)"
  fi

  local drift_count=0
  local name source pkg bin track_only canonical bincmd
  while IFS='|' read -r name source pkg bin track_only; do
    [[ -z "$name$source" ]] && continue
    canonical="${pkg:-$name}"
    bincmd="${bin:-$name}"

    # Accumulate declared sets (track-only included: a declared track-only
    # entry must not later surface as undeclared sprawl).
    case "$source" in
      brew_formula) printf '%s\n' "$canonical" >> "$decl_brew_formula" ;;
      brew_cask) printf '%s\n' "$canonical" >> "$decl_brew_cask" ;;
      npm_global) printf '%s\n' "$canonical" >> "$decl_npm" ;;
      go_install) printf '%s\n' "$bincmd" >> "$decl_go_bins" ;;
    esac

    # track-only / manual entries are inventory only; never installed by
    # tooling, so they produce no "not installed" drift.
    if [[ "$track_only" == "true" || "$source" == "manual" ]]; then
      if command -v "$bincmd" >/dev/null 2>&1; then
        item "track-only present: $name ($source)"
      else
        item "track-only, not present: $name ($source)"
      fi
      continue
    fi

    case "$source" in
      brew_formula)
        if [[ "$have_brew" -eq 0 ]]; then
          item "skip $name: brew not available"
        elif grep -Fxq -- "$canonical" "$brew_formulae"; then
          ok "installed: $name (brew_formula)"
        elif command -v "$bincmd" >/dev/null 2>&1; then
          info "source drift: $name declared brew_formula, absent from brew; '$bincmd' on PATH (installed elsewhere?)"
          drift_count=$((drift_count + 1))
        else
          warn "not installed: $name (brew_formula)"
          drift_count=$((drift_count + 1))
        fi
        ;;
      brew_cask)
        if [[ "$have_brew" -eq 0 ]]; then
          item "skip $name: brew not available"
        elif grep -Fxq -- "$canonical" "$brew_casks"; then
          ok "installed: $name (brew_cask)"
        else
          warn "not installed: $name (brew_cask)"
          drift_count=$((drift_count + 1))
        fi
        ;;
      npm_global)
        if [[ "$have_npm" -eq 0 ]]; then
          item "skip $name: npm not available"
        elif grep -Fxq -- "$canonical" "$npm_globals"; then
          ok "installed: $name (npm_global)"
        elif command -v "$bincmd" >/dev/null 2>&1; then
          info "source drift: $name declared npm_global, absent from npm -g; '$bincmd' on PATH (installed elsewhere?)"
          drift_count=$((drift_count + 1))
        else
          warn "not installed: $name (npm_global)"
          drift_count=$((drift_count + 1))
        fi
        ;;
      go_install)
        if grep -Fxq -- "$bincmd" "$go_bins"; then
          ok "installed: $name (go_install)"
        elif command -v "$bincmd" >/dev/null 2>&1; then
          info "source drift: $name declared go_install, absent from go bin; '$bincmd' on PATH (installed elsewhere?)"
          drift_count=$((drift_count + 1))
        else
          warn "not installed: $name (go_install)"
          drift_count=$((drift_count + 1))
        fi
        ;;
      mas)
        if [[ "$have_mas" -eq 0 ]]; then
          item "skip $name: mas not available"
        elif grep -Fxq -- "$canonical" "$mas_ids"; then
          ok "installed: $name (mas)"
        else
          warn "not installed: $name (mas)"
          drift_count=$((drift_count + 1))
        fi
        ;;
      *)
        # validate-policy rejects unknown sources; defensive skip here.
        item "skip $name: unhandled source $source"
        ;;
    esac
  done <<< "$rows"

  # Undeclared (sprawl): installed top-level items absent from the catalog.
  if [[ "$have_brew" -eq 1 ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      grep -Fxq -- "$f" "$decl_brew_formula" || {
        warn "undeclared: $f (brew_formula leaf not in catalog)"
        drift_count=$((drift_count + 1))
      }
    done < "$brew_leaves"
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      grep -Fxq -- "$c" "$decl_brew_cask" || {
        warn "undeclared: $c (brew_cask not in catalog)"
        drift_count=$((drift_count + 1))
      }
    done < "$brew_casks"
  fi
  if [[ "$have_npm" -eq 1 ]]; then
    while IFS= read -r n; do
      [[ -z "$n" ]] && continue
      grep -Fxq -- "$n" "$decl_npm" || {
        warn "undeclared: $n (npm global not in catalog)"
        drift_count=$((drift_count + 1))
      }
    done < "$npm_globals"
  fi
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    grep -Fxq -- "$b" "$decl_go_bins" || {
      warn "undeclared: $b (go binary not in catalog)"
      drift_count=$((drift_count + 1))
    }
  done < "$go_bins"

  if [[ "$drift_count" -eq 0 ]]; then
    ok "no catalog drift"
  fi

  rm -f "${drift_tmp[@]}"
  return 0
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
