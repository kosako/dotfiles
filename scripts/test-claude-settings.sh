#!/usr/bin/env bash
set -euo pipefail

# Content test for the managed ~/.claude/settings.json sandbox block
# (issue #50). test-render.sh fixes the managed *set* per profile; this fixes
# the *content* the enforceAiSandbox capability drives:
#   - default (enforceAiSandbox=false): no "sandbox" key; settings unchanged.
#   - enforceAiSandbox=true: a sandbox block with enabled=true,
#     failIfUnavailable=true (hard-fail rather than silently run unsandboxed),
#     allowUnsandboxedCommands=false (no per-command escape hatch), and a
#     public-safe empty network allowlist.
# It also fixes the GitHub injection guard content (issue #119):
# gateGitHubMcp -> deny the github MCP server; enforceAiSandbox -> write deny
# (secret/main-push) + approval ask (release/protection). gateGitHubMcp is ON
# for personal (Phase 2), so the committed render carries the MCP deny;
# enforceAiSandbox stays default false (no sandbox/ask until flipped).
# The matchers are best-effort/steering; a bypass negative test keeps that
# visible. See docs/ai-environment-boundary.md.
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

# Apply the personal profile from SOURCE_DIR into a throwaway home and print
# the path to the rendered ~/.claude/settings.json. Returns non-zero on a
# failed apply.
render_personal_settings() {
  local source_dir="$1" root
  root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings.XXXXXX")"
  tmp_roots+=("$root")
  mkdir -p "$root/home"
  printf '[data]\nprofile = "personal"\n' > "$root/chezmoi.toml"
  if ! chezmoi --config "$root/chezmoi.toml" \
      --source "$source_dir" --destination "$root/home" apply >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "$root/home/.claude/settings.json"
}

section "claude settings sandbox content"

# 1) Committed default: enforceAiSandbox=false -> no sandbox block, and the
#    file is still valid JSON (the conditional must not corrupt it).
if ! off_file="$(render_personal_settings "$DOTFILES_ROOT")"; then
  fail "test failed: personal apply (default) did not render"
  exit 1
fi
if ! yq -p json '.' "$off_file" >/dev/null 2>&1; then
  fail "test failed: default settings.json is not valid JSON"
  status=1
elif [[ "$(yq -p json '.sandbox // "absent"' "$off_file")" == "absent" ]]; then
  ok "test passed: default (enforceAiSandbox=false) emits no sandbox block"
else
  fail "test failed: default settings.json unexpectedly contains a sandbox block"
  status=1
fi

# 2) enforceAiSandbox=true (personal only) -> strict, public-safe sandbox
#    block. Flip the capability in a throwaway source copy so the committed
#    default stays false.
src_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings-src.XXXXXX")"
tmp_roots+=("$src_root")
cp -R "$DOTFILES_ROOT" "$src_root/src"
rm -rf "$src_root/src/.git"
yq -i '.profiles.personal.capabilities.enforceAiSandbox = true' \
  "$src_root/src/.chezmoidata/profiles.yaml"

if ! on_file="$(render_personal_settings "$src_root/src")"; then
  fail "test failed: personal apply (enforceAiSandbox=true) did not render"
  exit 1
fi
if ! yq -p json '.' "$on_file" >/dev/null 2>&1; then
  fail "test failed: enabled settings.json is not valid JSON"
  status=1
else
  enabled="$(yq -p json '.sandbox.enabled' "$on_file")"
  fail_if="$(yq -p json '.sandbox.failIfUnavailable' "$on_file")"
  unsandboxed="$(yq -p json '.sandbox.allowUnsandboxedCommands' "$on_file")"
  domains_len="$(yq -p json '.sandbox.network.allowedDomains | length' "$on_file")"
  if [[ "$enabled" == "true" && "$fail_if" == "true" && "$unsandboxed" == "false" && "$domains_len" == "0" ]]; then
    ok "test passed: enforceAiSandbox=true emits enabled, hard-fail, no-escape, empty-allowlist sandbox"
  else
    fail "test failed: sandbox block wrong (enabled=$enabled failIfUnavailable=$fail_if allowUnsandboxedCommands=$unsandboxed allowedDomains.len=$domains_len)"
    status=1
  fi
fi

section "claude settings managed global prefs"

# 3) issue #93, option (a): stable, public-safe global preferences that Claude
#    Code persists to settings.json (NOT settings.local.json) are absorbed into
#    the managed template, so `chezmoi apply` is a no-op for them and the live
#    file does not drift. off_file is the committed-default personal render from
#    section 1; lock the two currently-absorbed keys there.
skip_warn="$(yq -p json '.skipWorkflowUsageWarning // "absent"' "$off_file")"
tui_mode="$(yq -p json '.tui // "absent"' "$off_file")"
if [[ "$skip_warn" == "true" && "$tui_mode" == "fullscreen" ]]; then
  ok "test passed: managed template carries skipWorkflowUsageWarning=true and tui=fullscreen"
else
  fail "test failed: managed global prefs missing (skipWorkflowUsageWarning=$skip_warn tui=$tui_mode)"
  status=1
fi

section "claude settings GitHub injection guard (#119)"

# 4) Committed personal render: gateGitHubMcp is ON (Phase 2, #119), so the
#    permissions carry EXACTLY the github MCP deny (length 1) and nothing more;
#    enforceAiSandbox is still off, so there is no ask block. Pinning the exact
#    deny (not just "contains mcp__github") keeps the flip from silently growing
#    extra denies. (Before Phase 2 this asserted no deny/ask at all.)
deny_len="$(yq -p json '.permissions.deny | length' "$off_file")"
deny_first="$(yq -p json '.permissions.deny[0] // ""' "$off_file")"
ask_default="$(yq -p json '.permissions.ask // "absent"' "$off_file")"
if [[ "$deny_len" == "1" && "$deny_first" == "mcp__github" && "$ask_default" == "absent" ]]; then
  ok "test passed: committed personal denies exactly the github MCP (gateGitHubMcp on), no ask (enforceAiSandbox off)"
else
  fail "test failed: committed personal deny/ask unexpected (deny_len=$deny_len first=$deny_first ask=$ask_default)"
  status=1
fi

# 5) enforceAiSandbox=true: the write deny/ask rides on the same gate (on_file
#    from section 2). secret + direct main push are hard deny; release and
#    branch-protection need approval (ask). Context-gated writes (merge/PR/
#    comment/label/push ai/*) are intentionally NOT here (Phase 2 hook).
if grep -Fq '"Bash(git push * main)"' "$on_file" \
  && grep -Fq '"Bash(printenv)"' "$on_file" \
  && grep -Fq '"Read(//**/.env*)"' "$on_file" \
  && grep -Fq '"Read(~/.ssh/**)"' "$on_file" \
  && grep -Fq '"Bash(gh release create *)"' "$on_file" \
  && grep -Fq '"Bash(gh api *protection*)"' "$on_file"; then
  ok "test passed: enforceAiSandbox=true adds write deny (secret via Bash+Read, main-push) + approval ask (release/protection)"
else
  fail "test failed: enforceAiSandbox=true missing expected write deny/ask matchers"
  status=1
fi
# merge/PR/comment/label must NOT be statically gated in Phase 1 (left to the hook).
if grep -Fq 'gh pr merge' "$on_file" || grep -Fq 'gh pr create' "$on_file" || grep -Fq 'gh label create' "$on_file"; then
  fail "test failed: context-gated writes are statically gated (should be deferred to the Phase 2 hook)"
  status=1
else
  ok "test passed: context-gated writes (merge/PR/comment/label) are not statically gated"
fi

# 6) gateGitHubMcp=true: the GitHub MCP server is denied entirely. Flip in a
#    throwaway copy so the committed default stays false.
mcp_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings-mcp.XXXXXX")"
tmp_roots+=("$mcp_src")
cp -R "$DOTFILES_ROOT" "$mcp_src/src"
rm -rf "$mcp_src/src/.git"
yq -i '.profiles.personal.capabilities.gateGitHubMcp = true' \
  "$mcp_src/src/.chezmoidata/profiles.yaml"
if ! mcp_file="$(render_personal_settings "$mcp_src/src")"; then
  fail "test failed: personal apply (gateGitHubMcp=true) did not render"
  exit 1
fi
# Valid JSON (comma regression guard for the conditional deny block) + the bare
# server-name deny (mcp__github covers all tools; mcp__github__* is redundant).
if yq -p json '.' "$mcp_file" >/dev/null 2>&1 \
  && grep -Fq '"mcp__github"' "$mcp_file"; then
  ok "test passed: gateGitHubMcp=true denies the github MCP server (valid JSON)"
else
  fail "test failed: gateGitHubMcp=true did not deny the github MCP server (or invalid JSON)"
  status=1
fi

# 6b) Both gates on: the deny/ask blocks plus sandbox must still be valid JSON
#     (catches a comma regression when several conditional keys are present).
both_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings-both.XXXXXX")"
tmp_roots+=("$both_src")
cp -R "$DOTFILES_ROOT" "$both_src/src"
rm -rf "$both_src/src/.git"
yq -i '.profiles.personal.capabilities.gateGitHubMcp = true | .profiles.personal.capabilities.enforceAiSandbox = true' \
  "$both_src/src/.chezmoidata/profiles.yaml"
if ! both_file="$(render_personal_settings "$both_src/src")"; then
  fail "test failed: personal apply (both gates true) did not render"
  exit 1
fi
if yq -p json '.' "$both_file" >/dev/null 2>&1 \
  && grep -Fq '"mcp__github"' "$both_file" \
  && grep -Fq '"Bash(git push * main)"' "$both_file"; then
  ok "test passed: both gates on -> valid JSON with combined MCP + write deny"
else
  fail "test failed: both gates on produced invalid JSON or missing matchers"
  status=1
fi

# 7) Bypass negative test. The static command-string matchers are steering, NOT
#    an enforcement boundary: equivalent read/exfil paths are deliberately not
#    covered. Assert their absence (in the max-deny enforceAiSandbox render) so
#    the limitation stays visible and nobody mistakes this for a boundary. If a
#    future change "covers" one of these, re-check the honest labeling first.
bypass_hit=0
for bypass in 'git fetch' 'gh api *contents' 'gh issue view' 'WebFetch'; do
  if grep -Fq "$bypass" "$on_file"; then
    fail "test failed: matcher unexpectedly covers '$bypass' — re-check honest labeling / update the bypass test"
    bypass_hit=1
    status=1
  fi
done
if [[ "$bypass_hit" -eq 0 ]]; then
  ok "test passed: known equivalent read/exfil paths are NOT covered (matchers are steering, not a boundary)"
fi

if [[ "$status" -eq 0 ]]; then
  ok "claude settings tests passed"
fi
exit "$status"
