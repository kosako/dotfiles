#!/usr/bin/env bash
set -euo pipefail

# Content test for the managed ~/.codex/hooks.json PreToolUse hook registration
# (#181, the Codex parity of the Claude side in #137 / test-claude-settings.sh
# section 8). test-render.sh fixes the managed *set* per profile (that personal
# manages .codex/hooks.json and work does not); this fixes the *content* the
# enableGitHubIsolatedReader capability drives on the Codex side:
#   - enableGitHubIsolatedReader=true (personal): a user-layer hooks.json with
#     EXACTLY one PreToolUse/Bash command hook pointing at the agent-tools-deployed
#     ~/.codex/agent-tools/scripts/personal-safe-gh-hook (absolute path), timeout 10.
#   - enableGitHubIsolatedReader=false: no ~/.codex/hooks.json at all, AND an
#     already-applied file is REMOVED on the next apply (template self-gate renders
#     empty -> chezmoi prunes the managed target). This is why the module uses a
#     template self-gate instead of a `requires:` gate: chezmoiignore would drop
#     the source but leave a live hook lingering (Codex review #184).
# The registration is declarative and must render without the body deployed
# (bootstrap-safe); runtime is fail-open (missing body / non-2 exit / bad JSON /
# timeout continue the tool call — only exit 2 blocks), and Codex adds an inert
# stage (silently skipped until a one-time `/hooks` trust). Steering, NOT an
# enforcement boundary — see docs/ai-environment-boundary.md.
# Renders into throwaway destinations; never touches the real home directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

require_yq || exit 1

if ! command -v chezmoi >/dev/null 2>&1; then
  fail "chezmoi not found; render tests require it"
  exit 1
fi

status=0
tmp_roots=()

cleanup() {
  local dir
  for dir in "${tmp_roots[@]:-}"; do
    [[ -n "$dir" ]] && rm -rf "$dir"
  done
}
trap cleanup EXIT

# Apply the personal profile from SOURCE_DIR into a throwaway home and print the
# path to that home (so callers can inspect the presence/absence of files).
# Returns non-zero on a failed apply.
render_personal_home() {
  local source_dir="$1" root
  root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-codex-settings.XXXXXX")"
  tmp_roots+=("$root")
  mkdir -p "$root/home"
  printf '[data]\nprofile = "personal"\n' > "$root/chezmoi.toml"
  if ! chezmoi --config "$root/chezmoi.toml" \
      --source "$source_dir" --destination "$root/home" apply >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "$root/home"
}

section "codex settings PreToolUse hook registration (#181)"

# 1) Committed personal: enableGitHubIsolatedReader is ON, so ~/.codex/hooks.json
#    exists and registers EXACTLY one hook: PreToolUse / matcher Bash / one command
#    hook pointing at the agent-tools-deployed body (absolute path per the
#    agent-tools#146 stable-path contract), timeout 10. Pinned as an exact set
#    (event count, matcher, hook count, type, command, timeout), not just "a hook
#    exists": this is security wiring, so a swapped matcher / extra event / wrong
#    path must fail the test.
if ! home="$(render_personal_home "$DOTFILES_ROOT")"; then
  fail "test failed: personal apply (default) did not render"
  exit 1
fi
hooks_file="$home/.codex/hooks.json"
expected_hook_cmd="$HOME/.codex/agent-tools/scripts/personal-safe-gh-hook"
if [[ ! -f "$hooks_file" ]]; then
  fail "test failed: committed personal did not render ~/.codex/hooks.json (enableGitHubIsolatedReader is ON)"
  status=1
elif ! yq -p json '.' "$hooks_file" >/dev/null 2>&1; then
  fail "test failed: ~/.codex/hooks.json is not valid JSON"
  status=1
else
  # 0.142.5 parse-safety: the top-level object must be EXACTLY {hooks} — Codex
  # 0.142.5 rejects unknown top-level keys (a top-level "description" is a parse
  # error and the hook fails to load), so pin the key set, not just "hooks
  # exists" (#185).
  top_keys="$(yq -p json -o json '[keys[]] | sort' "$hooks_file" 2>/dev/null | tr -d ' \n')"
  if [[ "$top_keys" == '["hooks"]' ]]; then
    ok "test passed: top-level keys are exactly {hooks} (no description/unknown key — Codex 0.142.5 parse-safe)"
  else
    fail "test failed: unexpected top-level key(s) in ~/.codex/hooks.json: $top_keys (Codex 0.142.5 rejects unknown top-level keys — #185)"
    status=1
  fi
  events="$(yq -p json '.hooks | keys | length' "$hooks_file")"
  pre_len="$(yq -p json '.hooks.PreToolUse | length' "$hooks_file")"
  matcher="$(yq -p json '.hooks.PreToolUse[0].matcher' "$hooks_file")"
  inner_len="$(yq -p json '.hooks.PreToolUse[0].hooks | length' "$hooks_file")"
  inner_type="$(yq -p json '.hooks.PreToolUse[0].hooks[0].type' "$hooks_file")"
  inner_cmd="$(yq -p json '.hooks.PreToolUse[0].hooks[0].command' "$hooks_file")"
  inner_timeout="$(yq -p json '.hooks.PreToolUse[0].hooks[0].timeout' "$hooks_file")"
  if [[ "$events" == "1" && "$pre_len" == "1" && "$matcher" == "Bash" \
    && "$inner_len" == "1" && "$inner_type" == "command" \
    && "$inner_cmd" == "$expected_hook_cmd" && "$inner_timeout" == "10" ]]; then
    ok "test passed: committed personal registers exactly one PreToolUse/Bash command hook -> personal-safe-gh-hook (absolute path, timeout 10)"
  else
    fail "test failed: codex hook registration wrong (events=$events pre_len=$pre_len matcher=$matcher inner_len=$inner_len type=$inner_type cmd=$inner_cmd timeout=$inner_timeout)"
    status=1
  fi
fi

# 2) Bootstrap order is safe: the throwaway render home has NO agent-tools scripts,
#    yet the apply succeeded and rendered the registration. The registration is
#    declarative — it must not depend on the body being deployed. At runtime a
#    missing body is fail-open, and doctor reports the absent body (plus the Codex
#    /hooks trust requirement).
if [[ -n "${home:-}" && ! -e "$home/.codex/agent-tools/scripts/personal-safe-gh-hook" ]]; then
  ok "test passed: registration renders without the hook body present (agent-tools sync can come later; runtime is fail-open)"
else
  fail "test failed: throwaway render home unexpectedly contains a codex hook body (fixture assumption broken)"
  status=1
fi

# 3) enableGitHubIsolatedReader=false REMOVES an ALREADY-APPLIED ~/.codex/hooks.json
#    on the next apply — not just "does not newly create it". This is the exact
#    lingering scenario a `requires:` module gate would miss (chezmoiignore drops
#    the source but never prunes an existing target), so we drive both applies into
#    the SAME home: cap ON renders the file, then cap OFF must delete it (the
#    template self-gate renders empty and chezmoi prunes the managed target).
off_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-codex-settings-off-src.XXXXXX")"
tmp_roots+=("$off_src")
cp -R "$DOTFILES_ROOT" "$off_src/src"
rm -rf "$off_src/src/.git"
yq -i '.profiles.personal.capabilities.enableGitHubIsolatedReader = false' \
  "$off_src/src/.chezmoidata/profiles.yaml"

removal_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-codex-settings-removal.XXXXXX")"
tmp_roots+=("$removal_root")
mkdir -p "$removal_root/home"
printf '[data]\nprofile = "personal"\n' > "$removal_root/chezmoi.toml"
apply_into_removal_home() {
  chezmoi --config "$removal_root/chezmoi.toml" \
    --source "$1" --destination "$removal_root/home" apply >/dev/null 2>&1
}
if ! apply_into_removal_home "$DOTFILES_ROOT"; then
  fail "test failed: cap-on apply into removal home did not render"
  status=1
elif [[ ! -f "$removal_root/home/.codex/hooks.json" ]]; then
  fail "test failed: cap-on apply did not create ~/.codex/hooks.json (removal test precondition)"
  status=1
elif ! apply_into_removal_home "$off_src/src"; then
  fail "test failed: cap-off apply into removal home did not run"
  status=1
elif [[ ! -e "$removal_root/home/.codex/hooks.json" ]]; then
  ok "test passed: enableGitHubIsolatedReader=false removes an already-applied ~/.codex/hooks.json (template self-gate prunes the target — no lingering hook)"
else
  fail "test failed: enableGitHubIsolatedReader=false left a lingering ~/.codex/hooks.json (a requires: gate regression?)"
  status=1
fi

section "codex approval-rules baseline (#139)"

# 4) Committed personal: enableAiPolicy is ON, so ~/.codex/rules/default.rules
#    renders the vetted READ-ONLY baseline. Pinned as the EXACT ordered file
#    content (same spirit as the settings.json deny exact-set test): this is a
#    security baseline, so an outward/escalation allow (git push, gh pr create,
#    …) sneaking in — or a read rule silently swapped — must fail the test, not
#    just "some rules exist".
rules_file="${home:-}/.codex/rules/default.rules"
expected_rules=$'prefix_rule(pattern=["git", "commit"], decision="allow")\nprefix_rule(pattern=["git", "add"], decision="allow")\nprefix_rule(pattern=["git", "checkout"], decision="allow")\nprefix_rule(pattern=["gh", "auth", "status"], decision="allow")\nprefix_rule(pattern=["gh", "pr", "view"], decision="allow")\nprefix_rule(pattern=["gh", "pr", "list"], decision="allow")\nprefix_rule(pattern=["gh", "pr", "diff"], decision="allow")\nprefix_rule(pattern=["gh", "pr", "checks"], decision="allow")\nprefix_rule(pattern=["gh", "issue", "view"], decision="allow")\nprefix_rule(pattern=["gh", "issue", "list"], decision="allow")'
if [[ ! -f "$rules_file" ]]; then
  fail "test failed: committed personal did not render ~/.codex/rules/default.rules (enableAiPolicy is ON)"
  status=1
elif [[ "$(cat "$rules_file")" == "$expected_rules" ]]; then
  ok "test passed: committed personal renders exactly the read-only rules baseline (10 allow rules, ordered; no outward/escalation rule, no git clone)"
else
  fail "test failed: rules baseline content mismatch; rendered was:"
  cat "$rules_file" >&2
  status=1
fi

# 5) Gate independence, both directions: the two files in this module ride on
#    DIFFERENT capabilities, so flipping one must not disturb the other.
#    5a) enableAiPolicy=false removes an already-applied rules file (true
#        removal, same lingering scenario as case 3) while hooks.json survives.
ai_off_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-codex-settings-aioff.XXXXXX")"
tmp_roots+=("$ai_off_src")
cp -R "$DOTFILES_ROOT" "$ai_off_src/src"
rm -rf "$ai_off_src/src/.git"
yq -i '.profiles.personal.capabilities.enableAiPolicy = false' \
  "$ai_off_src/src/.chezmoidata/profiles.yaml"
rules_removal_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-codex-settings-rulesrm.XXXXXX")"
tmp_roots+=("$rules_removal_root")
mkdir -p "$rules_removal_root/home"
printf '[data]\nprofile = "personal"\n' > "$rules_removal_root/chezmoi.toml"
apply_into_rules_home() {
  chezmoi --config "$rules_removal_root/chezmoi.toml" \
    --source "$1" --destination "$rules_removal_root/home" apply >/dev/null 2>&1
}
if ! apply_into_rules_home "$DOTFILES_ROOT"; then
  fail "test failed: cap-on apply into rules-removal home did not render"
  status=1
elif [[ ! -f "$rules_removal_root/home/.codex/rules/default.rules" ]]; then
  fail "test failed: cap-on apply did not create the rules baseline (removal test precondition)"
  status=1
elif ! apply_into_rules_home "$ai_off_src/src"; then
  fail "test failed: enableAiPolicy=false apply did not run"
  status=1
elif [[ ! -e "$rules_removal_root/home/.codex/rules/default.rules" ]] \
  && [[ -f "$rules_removal_root/home/.codex/hooks.json" ]]; then
  ok "test passed: enableAiPolicy=false removes an already-applied rules baseline while hooks.json stays (independent gates)"
else
  fail "test failed: enableAiPolicy=false left the rules baseline lingering or disturbed hooks.json"
  status=1
fi

#    5b) The case-3 reader-off render (same home, enableGitHubIsolatedReader
#        already flipped false there) must still carry the rules baseline:
#        hooks gone, rules present.
if [[ -f "$removal_root/home/.codex/rules/default.rules" ]]; then
  ok "test passed: enableGitHubIsolatedReader=false keeps the rules baseline (independent gates, other direction)"
else
  fail "test failed: enableGitHubIsolatedReader=false unexpectedly removed the rules baseline"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "codex settings tests passed"
fi
exit "$status"
