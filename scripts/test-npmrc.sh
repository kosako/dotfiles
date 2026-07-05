#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

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

for entry in README.md AGENTS.md LICENSE docs scripts worklog; do
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
  "supply-chain-npm" ".npmrc" "npmHardeningMode enforce"
check_module_gate "mise config managed only with enableRuntimeManagement" \
  "runtime" ".config/mise" "enableRuntimeManagement true"

section "consistency: doctor enforce expectations"

while IFS= read -r line; do
  key="${line%%=*}"
  if [[ "$key" == "min-release-age" ]]; then
    # npm flattens min-release-age into `before` (now - <days>) and deletes the
    # original key, so doctor cannot assert `min-release-age=<n>` via
    # `npm config get`. It verifies the operative `before` cutoff is ~7 days ago
    # through npm_before_within_age_window (exercised below); a mere presence
    # grep would not catch a loosened window.
    # Require the exact call args (days=7, tolerance=43200), not just the
    # function name: a loosened window (e.g. `7 90000`) or wrong age
    # (e.g. `1 43200`) must break this test, locking the 7-day +/-12h contract.
    if grep -Eq 'npm_before_within_age_window .* 7 43200([[:space:]]|;|$)' "$SCRIPT_DIR/doctor.sh"; then
      ok "test passed: doctor verifies min-release-age via before cutoff (7d +/-12h)"
    else
      fail "test failed: doctor.sh must call npm_before_within_age_window with '7 43200'"
      status=1
    fi
    continue
  fi
  if grep -Fq "$line" "$SCRIPT_DIR/doctor.sh"; then
    ok "test passed: doctor expects $line"
  else
    fail "test failed: doctor.sh does not expect template setting: $line"
    status=1
  fi
done < <(grep -E '^[a-z-]+=' "$NPMRC_TEMPLATE")

section "unit: npm before cutoff window (min-release-age=7)"

check_window() {
  local name="$1" expected_rc="$2"; shift 2
  local actual_rc=0
  npm_before_within_age_window "$@" || actual_rc=1
  if [[ "$actual_rc" == "$expected_rc" ]]; then
    ok "test passed: $name"
  else
    fail "test failed: $name (rc=$actual_rc, want $expected_rc)"
    status=1
  fi
}

# Fixed reference instant so the assertions are deterministic.
now=1781000000
day=86400
tol=43200
# Honored: cutoff exactly 7 days ago, and a few seconds inside the window.
check_window "exactly 7 days ago is honored"        0 $(( now - 7*day ))       "$now" 7 "$tol"
check_window "7 days minus 30s still honored"       0 $(( now - 7*day + 30 ))  "$now" 7 "$tol"
# Rejected: a shorter age (Codex's min-release-age=1 case) is not the 7d policy.
check_window "1 day ago is rejected (too short)"    1 $(( now - 1*day ))       "$now" 7 "$tol"
check_window "6 days ago is rejected (off by 1d)"   1 $(( now - 6*day ))       "$now" 7 "$tol"
check_window "8 days ago is rejected (off by 1d)"   1 $(( now - 8*day ))       "$now" 7 "$tol"
# Rejected: a hand-set far-future before disables the cooldown.
check_window "far-future before is rejected"        1 $(( now + 1000*day ))    "$now" 7 "$tol"
# Rejected: unset / non-numeric before (npm older than 11.10, parse failure).
check_window "empty before is rejected"             1 ""                       "$now" 7 "$tol"
check_window "non-numeric before is rejected"       1 "abc"                    "$now" 7 "$tol"
# Rejected: non-numeric now / days / tolerance fail closed (no coercion to 0).
check_window "non-numeric now is rejected"          1 $(( now - 7*day ))      "abc" 7 "$tol"
check_window "non-numeric days is rejected"         1 $(( now - 7*day ))      "$now" abc "$tol"
check_window "non-numeric tolerance is rejected"    1 $(( now - 7*day ))      "$now" 7 abc
# Honored: leading zeros are read base-10, not octal (no arithmetic error).
check_window "leading-zero before is honored"       0 "0$(( now - 7*day ))"   "$now" 7 "$tol"
check_window "leading-zero days=07 is honored"      0 $(( now - 7*day ))      "$now" 07 "$tol"

# Rendered content (#150): the static grep above pins the template SOURCE,
# not what a profile actually renders — a flipped gate condition would keep
# every static check green. Render for real when chezmoi is available (the
# render job runs this; the validate job has no chezmoi and skips).
section "rendered content (chezmoi)"
if ! command -v chezmoi >/dev/null 2>&1; then
  warn "chezmoi not found; skipping rendered-content checks (the CI render job runs them)"
else
  tmp_roots=()
  cleanup() {
    for dir in "${tmp_roots[@]:-}"; do
      [[ -n "$dir" ]] && rm -rf "$dir"
    done
  }
  trap cleanup EXIT

  # Apply personal from SOURCE_DIR into ROOT/home. ROOT is created by the
  # CALLER and registered in tmp_roots there: a helper that mktemps and
  # returns via command substitution would append to tmp_roots only inside
  # the substitution subshell, so the cleanup trap would never see it and
  # the render roots would leak (Codex review, #150).
  render_personal_into() {
    local source_dir="$1" root="$2"
    mkdir -p "$root/home"
    printf '[data]\nprofile = "personal"\n' > "$root/chezmoi.toml"
    chezmoi --config "$root/chezmoi.toml" \
      --source "$source_dir" --destination "$root/home" apply >/dev/null 2>&1
  }

  # enforce (personal default): every hardening line renders, tokens never do.
  enforce_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-npmrc-render.XXXXXX")"
  tmp_roots+=("$enforce_root")
  if render_personal_into "$DOTFILES_ROOT" "$enforce_root" \
    && [[ -f "$enforce_root/home/.npmrc" ]]; then
    for line in "ignore-scripts=true" "save-exact=true" "fund=false" "audit=true" "min-release-age=7"; do
      check_file_has_line "rendered enforce npmrc has: $line" "$enforce_root/home/.npmrc" "$line"
    done
    if grep -Eq '_authToken|registry=|^//' "$enforce_root/home/.npmrc"; then
      fail "test failed: rendered npmrc contains token or registry configuration"
      status=1
    else
      ok "test passed: rendered npmrc carries no token or registry configuration"
    fi
  else
    fail "test failed: personal (enforce) did not render ~/.npmrc"
    status=1
  fi

  # report: the supply-chain-npm module requires enforce, so ~/.npmrc must
  # leave the managed set entirely (not render as an empty file).
  flip_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-npmrc-flip.XXXXXX")"
  tmp_roots+=("$flip_root")
  cp -R "$DOTFILES_ROOT/." "$flip_root/repo"
  set_capability_all "$flip_root/repo" npmHardeningMode report
  report_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-npmrc-render.XXXXXX")"
  tmp_roots+=("$report_root")
  if render_personal_into "$flip_root/repo" "$report_root"; then
    if [[ -e "$report_root/home/.npmrc" ]]; then
      fail "test failed: npmHardeningMode=report must not manage ~/.npmrc"
      status=1
    else
      ok "test passed: npmHardeningMode=report leaves ~/.npmrc unmanaged"
    fi
  else
    fail "test failed: apply failed with npmHardeningMode=report"
    status=1
  fi
fi

if [[ "$status" -eq 0 ]]; then
  ok "npmrc tests passed"
fi
exit "$status"
