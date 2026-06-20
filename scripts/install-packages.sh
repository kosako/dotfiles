#!/usr/bin/env bash
set -euo pipefail

# Catalog installer (#53 stage 2). Installs catalog entries
# (.chezmoidata/packages.yaml) that are declared installable and not yet
# present, gated by the host profile's install capabilities (installPackages
# / installGuiApps, resolved fail-closed from the real chezmoi profile).
#
# Manual invocation only — never wired into `chezmoi apply`. Dry-run by
# default; --apply performs installs. Install and update are separate (see
# docs/update-policy.md): an entry already present is skipped, never
# reinstalled or upgraded, so `go install ...@latest` / `npm install -g`
# never run for something already there.
#
# Language runtimes (node/go/uv) are mise's domain and are not in the catalog;
# this tool needs the source's manager (brew / npm / go) on PATH to install,
# and skips with a warning when it is absent (fail-safe, no capability added).

TOOL_NAME="install-packages.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

usage() {
  cat >&2 <<EOF
usage:
  $TOOL_NAME [--apply]

Installs catalog entries (.chezmoidata/packages.yaml) that are declared
installable and not yet present, gated by the host profile's installPackages
/ installGuiApps capabilities. Dry-run by default; --apply performs installs.
Never upgrades an already-installed entry. Manual only; not wired into
chezmoi apply.
EOF
}

# Whether NAME is already installed for SOURCE. canonical = pkg|name,
# bincmd = bin|name. Read-only; a present entry is left untouched (no upgrade).
is_installed() {
  local source="$1" canonical="$2" bincmd="$3"
  case "$source" in
    brew_formula)
      brew list --formula -1 2>/dev/null | grep -Fxq -- "$canonical" && return 0
      command -v "$bincmd" >/dev/null 2>&1 ;;
    brew_cask)
      brew list --cask -1 2>/dev/null | grep -Fxq -- "$canonical" ;;
    npm_global)
      npm ls -g --depth=0 --json 2>/dev/null \
        | yq -p json '.dependencies // {} | keys | .[]' 2>/dev/null \
        | grep -Fxq -- "$canonical" && return 0
      command -v "$bincmd" >/dev/null 2>&1 ;;
    go_install)
      command -v "$bincmd" >/dev/null 2>&1 ;;
    mas)
      mas list 2>/dev/null | awk '{print $1}' | grep -Fxq -- "$canonical" ;;
    *) return 0 ;;
  esac
}

# Whether the manager SOURCE needs is on PATH. npm_global / go_install depend
# on a runtime (node / go) that mise provides, and mas needs the `mas` CLI;
# absence means "skip", not "install failed".
manager_present() {
  case "$1" in
    brew_formula | brew_cask) command -v brew >/dev/null 2>&1 ;;
    npm_global) command -v npm >/dev/null 2>&1 ;;
    go_install) command -v go >/dev/null 2>&1 ;;
    mas) command -v mas >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Build the install command for SOURCE into the INSTALL_CMD array (global),
# using CANONICAL (= pkg, defaulting to name) as the install id. Returns 1
# for an unsupported source.
build_install_cmd() {
  local source="$1" canonical="$2"
  case "$source" in
    brew_formula) INSTALL_CMD=(brew install "$canonical") ;;
    brew_cask) INSTALL_CMD=(brew install --cask "$canonical") ;;
    npm_global) INSTALL_CMD=(npm install -g "$canonical") ;;
    go_install) INSTALL_CMD=(go install "${canonical}@latest") ;;
    mas) INSTALL_CMD=(mas install "$canonical") ;;
    *) return 1 ;;
  esac
}

main() {
  local apply=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) apply=1; shift ;;
      -h | --help) usage; return 0 ;;
      *) fail "unknown argument: $1"; usage; return 2 ;;
    esac
  done

  require_yq || return 1
  [[ -f "$PACKAGES_FILE" ]] || { fail "catalog missing: $PACKAGES_FILE"; return 1; }

  # Fail-closed profile resolution: never assume a default. work / client /
  # sandbox / agent then gate out via installPackages / installGuiApps = false.
  local profile
  if ! profile="$(resolve_runtime_profile)"; then
    fail "cannot resolve the machine profile from chezmoi config; refusing. Run: chezmoi init --source ~/dotfiles"
    return 1
  fi
  if ! profile_exists "$profile"; then
    fail "machine profile '$profile' is not defined in profiles.yaml; refusing"
    return 1
  fi

  section "catalog install (profile: $profile)"
  if [[ "$apply" -eq 1 ]]; then
    item "apply mode: missing installable entries will be installed"
  else
    item "dry-run: nothing will be installed (pass --apply to perform)"
  fi

  local rows
  rows="$(catalog_packages)" || { fail "could not read catalog packages"; return 1; }

  local name source pkg bin track_only canonical bincmd cap
  local planned=0 installed_now=0 skipped=0 failed=0
  local INSTALL_CMD=()
  while IFS='|' read -r name source pkg bin track_only; do
    [[ -z "$name$source" ]] && continue
    canonical="${pkg:-$name}"
    bincmd="${bin:-$name}"

    # track-only / manual: inventory only, never installed by tooling.
    if [[ "$track_only" == "true" || "$source" == "manual" ]]; then
      item "skip $name: track-only ($source)"
      skipped=$((skipped + 1)); continue
    fi

    # Capability gate (fail-closed per source). Keeps work / client / agent
    # from installing anything: their installPackages / installGuiApps = false.
    if ! profile_installs_source "$profile" "$source"; then
      cap="$(source_install_capability "$source" 2>/dev/null || echo '?')"
      item "skip $name: $cap not granted for '$profile' ($source)"
      skipped=$((skipped + 1)); continue
    fi

    # Manager must be present (npm/go come from mise). Absent -> skip, not fail.
    if ! manager_present "$source"; then
      warn "skip $name: manager for $source not on PATH (runtime not ready?)"
      skipped=$((skipped + 1)); continue
    fi

    # Idempotent: never touch an already-installed entry (install != update).
    if is_installed "$source" "$canonical" "$bincmd"; then
      ok "already installed: $name ($source)"
      skipped=$((skipped + 1)); continue
    fi

    if ! build_install_cmd "$source" "$canonical"; then
      warn "skip $name: unsupported source '$source'"
      skipped=$((skipped + 1)); continue
    fi

    planned=$((planned + 1))
    if [[ "$apply" -eq 1 ]]; then
      item "installing: $name -> ${INSTALL_CMD[*]}"
      if "${INSTALL_CMD[@]}"; then
        ok "installed: $name ($source)"
        installed_now=$((installed_now + 1))
      else
        warn "install failed: $name ($source)"
        failed=$((failed + 1))
      fi
    else
      item "would install: $name -> ${INSTALL_CMD[*]}"
    fi
  done <<< "$rows"

  if [[ "$apply" -eq 1 ]]; then
    ok "done: $installed_now installed, $skipped skipped, $failed failed"
    [[ "$failed" -eq 0 ]]
  else
    ok "dry-run: $planned would be installed, $skipped skipped (pass --apply to perform)"
  fi
}

# Run only when executed, not when sourced (test-install-packages.sh sources
# this to unit-test build_install_cmd without performing installs).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
