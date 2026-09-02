#!/usr/bin/env bash
set -euo pipefail

# Content test for the managed ~/.codex/hooks.json hook registrations (#181,
# the Codex parity of the Claude side in #137 / test-claude-settings.sh section
# 8; #199 adds the quality-loop pair). test-render.sh fixes the managed *set*
# per profile (that personal manages .codex/hooks.json and work does not); this
# fixes the *content* the two hook capabilities drive on the Codex side:
#   - enableGitHubIsolatedReader=true (personal): EXACTLY one PreToolUse/Bash
#     command hook pointing at the agent-tools-deployed
#     ~/.codex/agent-tools/scripts/personal-safe-gh-hook (absolute path), timeout 10.
#   - enableQualityLoopHooks=true (personal): EXACTLY one PostToolUse/Edit|Write
#     command hook -> personal-fast-edit-check and one matcher-less Stop command
#     hook -> personal-changed-scope-qa (absolute paths, no timeout; Codex
#     ignores a Stop matcher, so none is emitted).
#   - each capability false drops exactly its own events; BOTH false: no
#     ~/.codex/hooks.json at all, AND an already-applied file is REMOVED on the
#     next apply (template self-gate renders empty -> chezmoi prunes the managed
#     target). This is why the module uses a template self-gate instead of a
#     `requires:` gate: chezmoiignore would drop the source but leave a live
#     hook lingering (Codex review #184).
# The registration is declarative and must render without the body deployed
# (bootstrap-safe); runtime is fail-open (missing body / non-2 exit / bad JSON /
# timeout continue the tool call — only exit 2 blocks), and Codex adds an inert
# stage (silently skipped until a one-time `/hooks` trust). Steering, NOT an
# enforcement boundary — see docs/ai-environment-boundary.md.
# Renders into throwaway destinations; never touches the real home directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

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

# Renders use render_personal_into (test-lib.sh): the caller mktemps the
# root and registers it in tmp_roots, then inspects ROOT/home
# (caller-creates-root contract; see the #150 leak note in test-lib.sh).

section "codex settings hook registration (#181 / #199)"

# 1) Committed personal: enableGitHubIsolatedReader and enableQualityLoopHooks
#    are ON, so ~/.codex/hooks.json exists and registers EXACTLY three events:
#    PreToolUse / matcher Bash / one command hook pointing at the agent-tools-
#    deployed safe-gh body (absolute path per the agent-tools#146 stable-path
#    contract), timeout 10; PostToolUse / matcher Edit|Write / one command hook
#    -> personal-fast-edit-check; matcher-less Stop / one command hook ->
#    personal-changed-scope-qa (no timeout on the quality pair). Pinned as an
#    exact set (event set, matcher, hook count, type, command, timeout), not
#    just "a hook exists": this is security / gate wiring, so a swapped matcher /
#    extra event / wrong path must fail the test.
home_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-codex-settings.XXXXXX")"
tmp_roots+=("$home_root")
if ! render_personal_into "$DOTFILES_ROOT" "$home_root"; then
  fail "test failed: personal apply (default) did not render"
  exit 1
fi
home="$home_root/home"
hooks_file="$home/.codex/hooks.json"
expected_hook_cmd="$HOME/.codex/agent-tools/scripts/personal-safe-gh-hook"
expected_edit_cmd="$HOME/.codex/agent-tools/scripts/personal-fast-edit-check"
expected_stop_cmd="$HOME/.codex/agent-tools/scripts/personal-changed-scope-qa"
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
  events="$(yq -p json -o json '.hooks | keys | sort' "$hooks_file" | tr -d ' \n')"
  pre_len="$(yq -p json '.hooks.PreToolUse | length' "$hooks_file")"
  matcher="$(yq -p json '.hooks.PreToolUse[0].matcher' "$hooks_file")"
  inner_len="$(yq -p json '.hooks.PreToolUse[0].hooks | length' "$hooks_file")"
  inner_type="$(yq -p json '.hooks.PreToolUse[0].hooks[0].type' "$hooks_file")"
  inner_cmd="$(yq -p json '.hooks.PreToolUse[0].hooks[0].command' "$hooks_file")"
  inner_timeout="$(yq -p json '.hooks.PreToolUse[0].hooks[0].timeout' "$hooks_file")"
  if [[ "$events" == '["PostToolUse","PreToolUse","Stop"]' && "$pre_len" == "1" && "$matcher" == "Bash" \
    && "$inner_len" == "1" && "$inner_type" == "command" \
    && "$inner_cmd" == "$expected_hook_cmd" && "$inner_timeout" == "10" ]]; then
    ok "test passed: committed personal registers exactly {PreToolUse, PostToolUse, Stop}, with one PreToolUse/Bash command hook -> personal-safe-gh-hook (absolute path, timeout 10)"
  else
    fail "test failed: codex hook registration wrong (events=$events pre_len=$pre_len matcher=$matcher inner_len=$inner_len type=$inner_type cmd=$inner_cmd timeout=$inner_timeout)"
    status=1
  fi
  post_len="$(yq -p json '.hooks.PostToolUse | length' "$hooks_file")"
  post_matcher="$(yq -p json '.hooks.PostToolUse[0].matcher' "$hooks_file")"
  post_inner_len="$(yq -p json '.hooks.PostToolUse[0].hooks | length' "$hooks_file")"
  post_type="$(yq -p json '.hooks.PostToolUse[0].hooks[0].type' "$hooks_file")"
  post_cmd="$(yq -p json '.hooks.PostToolUse[0].hooks[0].command' "$hooks_file")"
  post_timeout="$(yq -p json '.hooks.PostToolUse[0].hooks[0].timeout // "absent"' "$hooks_file")"
  stop_len="$(yq -p json '.hooks.Stop | length' "$hooks_file")"
  stop_matcher="$(yq -p json '.hooks.Stop[0].matcher // "absent"' "$hooks_file")"
  stop_inner_len="$(yq -p json '.hooks.Stop[0].hooks | length' "$hooks_file")"
  stop_type="$(yq -p json '.hooks.Stop[0].hooks[0].type' "$hooks_file")"
  stop_cmd="$(yq -p json '.hooks.Stop[0].hooks[0].command' "$hooks_file")"
  stop_timeout="$(yq -p json '.hooks.Stop[0].hooks[0].timeout // "absent"' "$hooks_file")"
  if [[ "$post_len" == "1" && "$post_matcher" == "Edit|Write" && "$post_inner_len" == "1" \
    && "$post_type" == "command" && "$post_cmd" == "$expected_edit_cmd" && "$post_timeout" == "absent" \
    && "$stop_len" == "1" && "$stop_matcher" == "absent" && "$stop_inner_len" == "1" \
    && "$stop_type" == "command" && "$stop_cmd" == "$expected_stop_cmd" && "$stop_timeout" == "absent" ]]; then
    ok "test passed: committed personal registers one PostToolUse/Edit|Write hook -> personal-fast-edit-check and one matcher-less Stop hook -> personal-changed-scope-qa (absolute paths, no timeout)"
  else
    fail "test failed: codex quality-loop hook registration wrong (post_len=$post_len matcher=$post_matcher inner=$post_inner_len type=$post_type cmd=$post_cmd timeout=$post_timeout | stop_len=$stop_len matcher=$stop_matcher inner=$stop_inner_len type=$stop_type cmd=$stop_cmd timeout=$stop_timeout)"
    status=1
  fi
fi

# 2) Bootstrap order is safe: the throwaway render home has NO agent-tools scripts,
#    yet the apply succeeded and rendered the registration. The registration is
#    declarative — it must not depend on the body being deployed. At runtime a
#    missing body is fail-open, and doctor reports the absent body (plus the Codex
#    /hooks trust requirement).
if [[ -n "${home:-}" && ! -e "$home/.codex/agent-tools/scripts/personal-safe-gh-hook" \
  && ! -e "$home/.codex/agent-tools/scripts/personal-fast-edit-check" \
  && ! -e "$home/.codex/agent-tools/scripts/personal-changed-scope-qa" ]]; then
  ok "test passed: registration renders without any hook body present (agent-tools sync can come later; runtime is fail-open)"
else
  fail "test failed: throwaway render home unexpectedly contains a codex hook body (fixture assumption broken)"
  status=1
fi

# 2b) Each capability drops exactly its own events (parity with the Claude
#     side, test-claude-settings.sh 8c): reader off -> exactly {PostToolUse,
#     Stop} and the on-render minus PreToolUse; quality off -> exactly
#     {PreToolUse} and the on-render minus PostToolUse/Stop (normalized JSON
#     compare, so a gate that dropped the other capability's events or leaked
#     anything else would fail).
render_codex_hook_flip() { # $1=label  $2=cap -> prints the rendered hooks.json path
  local label="$1" cap="$2" src root
  src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-codex-settings-$label.XXXXXX")"
  tmp_roots+=("$src")
  make_flipped_source "$src"
  flip_personal_capability "$src/src" "$cap" false
  root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-codex-settings.XXXXXX")"
  tmp_roots+=("$root")
  if ! render_personal_into "$src/src" "$root"; then
    fail "test failed: personal apply ($label) did not render"
    exit 1
  fi
  printf '%s\n' "$root/home/.codex/hooks.json"
}
reader_off_hooks="$(render_codex_hook_flip reader-off enableGitHubIsolatedReader)"
quality_off_hooks="$(render_codex_hook_flip quality-off enableQualityLoopHooks)"
if [[ -f "$reader_off_hooks" ]] \
  && [[ "$(yq -p json -o json '.hooks | keys | sort' "$reader_off_hooks" | tr -d ' \n')" == '["PostToolUse","Stop"]' ]] \
  && [[ "$(yq -p json -o json 'del(.hooks.PreToolUse)' "$hooks_file")" == "$(yq -p json -o json '.' "$reader_off_hooks")" ]]; then
  ok "test passed: enableGitHubIsolatedReader=false keeps ~/.codex/hooks.json with exactly {PostToolUse, Stop} (on-render minus PreToolUse)"
else
  fail "test failed: enableGitHubIsolatedReader=false render is not the on-render minus PreToolUse (file missing, quality pair dropped, or another change leaked)"
  status=1
fi
if [[ -f "$quality_off_hooks" ]] \
  && [[ "$(yq -p json -o json '.hooks | keys | sort' "$quality_off_hooks" | tr -d ' \n')" == '["PreToolUse"]' ]] \
  && [[ "$(yq -p json -o json 'del(.hooks.PostToolUse) | del(.hooks.Stop)' "$hooks_file")" == "$(yq -p json -o json '.' "$quality_off_hooks")" ]]; then
  ok "test passed: enableQualityLoopHooks=false keeps ~/.codex/hooks.json with exactly {PreToolUse} (on-render minus PostToolUse/Stop)"
else
  fail "test failed: enableQualityLoopHooks=false render is not the on-render minus PostToolUse/Stop (file missing, safe-gh hook dropped, or another change leaked)"
  status=1
fi

# 3) BOTH hook capabilities false REMOVES an ALREADY-APPLIED ~/.codex/hooks.json
#    on the next apply — not just "does not newly create it". This is the exact
#    lingering scenario a `requires:` module gate would miss (chezmoiignore drops
#    the source but never prunes an existing target), so we drive both applies into
#    the SAME home: caps ON render the file, then caps OFF must delete it (the
#    template self-gate renders empty and chezmoi prunes the managed target).
off_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-codex-settings-off-src.XXXXXX")"
tmp_roots+=("$off_src")
make_flipped_source "$off_src"
flip_personal_capability "$off_src/src" enableGitHubIsolatedReader false
flip_personal_capability "$off_src/src" enableQualityLoopHooks false

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
  ok "test passed: both hook capabilities false removes an already-applied ~/.codex/hooks.json (template self-gate prunes the target — no lingering hook)"
else
  fail "test failed: both hook capabilities false left a lingering ~/.codex/hooks.json (a requires: gate regression?)"
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
make_flipped_source "$ai_off_src"
flip_personal_capability "$ai_off_src/src" enableAiPolicy false
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

#    5b) The case-3 hooks-off render (same home, both hook capabilities
#        already flipped false there) must still carry the rules baseline:
#        hooks gone, rules present.
if [[ -f "$removal_root/home/.codex/rules/default.rules" ]]; then
  ok "test passed: both hook capabilities false keeps the rules baseline (independent gates, other direction)"
else
  fail "test failed: hook capabilities false unexpectedly removed the rules baseline"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "codex settings tests passed"
fi
exit "$status"
