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

if [[ "$status" -eq 0 ]]; then
  ok "claude settings tests passed"
fi
exit "$status"
