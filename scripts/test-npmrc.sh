#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

require_yq || exit 1

NPMRC_TEMPLATE="$DOTFILES_ROOT/dot_npmrc.tmpl"
CHEZMOIIGNORE="$DOTFILES_ROOT/.chezmoiignore"

status=0

check_file_contains() {
  local name="$1"
  local file="$2"
  local needle="$3"
  if grep -Fq "$needle" "$file"; then
    ok "test passed: $name"
  else
    fail "test failed: $name (missing in $file: $needle)"
    status=1
  fi
}

# Whole-line match: substring matches (e.g. a comment that mentions the
# entry) must not satisfy ignore-entry presence checks.
check_file_has_line() {
  local name="$1"
  local file="$2"
  local line="$3"
  if grep -Fxq "$line" "$file"; then
    ok "test passed: $name"
  else
    fail "test failed: $name (missing exact line in $file: $line)"
    status=1
  fi
}

section "static checks: dot_npmrc.tmpl"

if [[ ! -f "$NPMRC_TEMPLATE" ]]; then
  fail "missing template: $NPMRC_TEMPLATE"
  exit 1
fi

check_file_contains "gated on enforce mode" "$NPMRC_TEMPLATE" 'eq $caps.npmHardeningMode "enforce"'
for needle in "ignore-scripts=true" "save-exact=true" "fund=false" "audit=true" "min-release-age=7"; do
  check_file_contains "hardening setting: $needle" "$NPMRC_TEMPLATE" "$needle"
done

if grep -Eq '_authToken|registry=|^//' "$NPMRC_TEMPLATE"; then
  fail "test failed: template contains token or registry configuration"
  status=1
else
  ok "test passed: no token or registry configuration in template"
fi

section "static checks: .chezmoiignore"

if [[ ! -f "$CHEZMOIIGNORE" ]]; then
  fail "missing file: $CHEZMOIIGNORE"
  exit 1
fi

check_file_contains "ignore generated from module paths" "$CHEZMOIIGNORE" 'range $module.paths'

for entry in README.md AGENTS.md LICENSE docs scripts templates worklog; do
  check_file_has_line "never applies repo file: $entry" "$CHEZMOIIGNORE" "$entry"
done

section "consistency: module path gates (modules.yaml)"

check_module_gate() {
  local name="$1"
  local module="$2"
  local expected_paths="$3"
  local expected_requires="$4"
  if [[ "$(module_paths "$module")" == "$expected_paths" \
     && "$(module_requires "$module")" == "$expected_requires" ]]; then
    ok "test passed: $name"
  else
    fail "test failed: $name (paths/requires mismatch for $module)"
    status=1
  fi
}

check_module_gate ".npmrc managed only with npmHardeningMode=enforce" \
  "supply-chain/npm" ".npmrc" "npmHardeningMode enforce"
check_module_gate "mise config managed only with enableRuntimeManagement" \
  "runtime" ".config/mise" "enableRuntimeManagement true"

section "consistency: doctor enforce expectations"

while IFS= read -r line; do
  if grep -Fq "$line" "$SCRIPT_DIR/doctor.sh"; then
    ok "test passed: doctor expects $line"
  else
    fail "test failed: doctor.sh does not expect template setting: $line"
    status=1
  fi
done < <(grep -E '^[a-z-]+=' "$NPMRC_TEMPLATE")

if [[ "$status" -eq 0 ]]; then
  ok "npmrc tests passed"
fi
exit "$status"
