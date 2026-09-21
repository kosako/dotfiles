#!/usr/bin/env bash
set -euo pipefail

# Content test for the managed ~/.config/opencode/opencode.json (#234, the
# OpenCode permission floor). test-render.sh fixes the managed *set* per
# profile (personal manages it, work does not); this fixes the *content*:
#   - the permission floor is EXACTLY the pinned ordered rule maps for read
#     (secret-store / .env deny) and bash (env-dump / gh-secret deny, outward
#     and escalation ask) — a swapped or dropped rule must fail, so the maps
#     are compared whole, not sampled;
#   - autoupdate is off, share is disabled, and instructions name exactly the
#     agent-tools operating-rules file (absolute, under the rendered home);
#   - nothing local leaks into the managed file: no provider / model /
#     small_model / plugin / mcp / agent / server keys and no secret-shaped
#     strings;
#   - the work profile renders no file at all (module not listed).
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

section "opencode settings permission floor (#234)"

home_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-opencode-settings.XXXXXX")"
tmp_roots+=("$home_root")
if ! render_personal_into "$DOTFILES_ROOT" "$home_root"; then
  fail "test failed: personal apply (default) did not render"
  exit 1
fi
home="$home_root/home"
config_file="$home/.config/opencode/opencode.json"

# 1) Committed personal renders the managed file as valid JSON with the schema.
if [[ -f "$config_file" ]] && yq -p json -e '."$schema" == "https://opencode.ai/config.json"' "$config_file" >/dev/null 2>&1; then
  ok "test passed: personal renders ~/.config/opencode/opencode.json (valid JSON, opencode schema)"
else
  fail "test failed: personal did not render a valid ~/.config/opencode/opencode.json with the opencode schema"
  status=1
fi

# 2) Update / share posture and the instructions pointer. instructions is the
#    whole array, pinned: exactly one entry, the agent-tools operating rules
#    as an absolute path under chezmoi's homeDir — the REAL home even in a
#    throwaway render, same as the Codex hook paths in test-codex-settings.sh
#    (OpenCode does not follow the `@` import in ~/.claude/CLAUDE.md, so the
#    imported file is named here).
autoupdate="$(yq -p json '.autoupdate' "$config_file")"
share="$(yq -p json '.share' "$config_file")"
instructions="$(yq -p json '.instructions[]' "$config_file")"
if [[ "$autoupdate" == "false" && "$share" == "disabled" && "$instructions" == "$HOME/.claude/agent-tools/CLAUDE.md" ]]; then
  ok "test passed: autoupdate off, share disabled, instructions = exactly the agent-tools operating rules"
else
  fail "test failed: posture mismatch (autoupdate=$autoupdate share=$share instructions=$instructions)"
  status=1
fi

# 3) The read floor, EXACT and ordered (last match wins in OpenCode, so the
#    order is part of the contract: the .env.example allow must come after the
#    .env denies).
expected_read=$'*=allow\n~/.ssh/*=deny\n~/.aws/*=deny\n~/.config/gh/*=deny\n~/.netrc=deny\n~/.codex/auth.json=deny\n~/.local/share/opencode/auth.json=deny\n*.env=deny\n*.env.*=deny\n*.env.example=allow'
actual_read="$(yq -p json '.permission.read | to_entries | .[] | .key + "=" + .value' "$config_file")"
if [[ "$actual_read" == "$expected_read" ]]; then
  ok "test passed: permission.read is exactly the secret floor (10 rules, ordered)"
else
  fail "test failed: permission.read drifted from the pinned floor; was:"
  printf '%s\n' "$actual_read" >&2
  status=1
fi

# 4) The bash floor, EXACT and ordered: allow-all base, env-dump / gh-secret /
#    ssh-key deny, outward + escalation ask (docs/ai-policy.md: local read-only
#    work needs no approval, leaving the machine or escalating does). The ask
#    patterns end in `*` WITHOUT a space so the argument-less forms (`git
#    push`, `gh pr create`) match too; a `git push *` spelling would let the
#    bare command fall through to the allow-all base (Codex review, PR #235).
expected_bash=$'*=allow\ncat ~/.ssh/*=deny\ngh secret *=deny\ngh api *secrets*=deny\nenv=deny\nenv *=deny\nprintenv=deny\nprintenv *=deny\ngit push*=ask\ngit clone*=ask\ngh pr create*=ask\ngh pr merge*=ask\ngh pr comment*=ask\ngh pr review*=ask\ngh issue create*=ask\ngh issue comment*=ask\ngh release*=ask\ngh repo*=ask\ngh auth*=ask\nsudo*=ask\ncurl*=ask\nwget*=ask'
actual_bash="$(yq -p json '.permission.bash | to_entries | .[] | .key + "=" + .value' "$config_file")"
if [[ "$actual_bash" == "$expected_bash" ]]; then
  ok "test passed: permission.bash is exactly the pinned floor (8 deny, 14 ask, ordered)"
else
  fail "test failed: permission.bash drifted from the pinned floor; was:"
  printf '%s\n' "$actual_bash" >&2
  status=1
fi

# 5) Only the intended top-level keys: anything local (provider / model /
#    plugin / mcp / agent / server ...) must never be in the managed file.
expected_keys=$'$schema\nautoupdate\nshare\ninstructions\npermission'
actual_keys="$(yq -p json 'keys | .[]' "$config_file")"
if [[ "$actual_keys" == "$expected_keys" ]]; then
  ok "test passed: top-level keys are exactly schema / autoupdate / share / instructions / permission (no provider, model, plugin, mcp, agent)"
else
  fail "test failed: unexpected top-level keys in the managed opencode.json:"
  printf '%s\n' "$actual_keys" >&2
  status=1
fi

# 6) No secret-shaped value and no real identity in the rendered file (the
#    only '@' allowed is none; the only home path is the rendered fixture home).
if grep -Eqi 'sk-[a-z0-9]|api[_-]?key|token|@' "$config_file"; then
  fail "test failed: rendered opencode.json contains a secret-like or email-like string"
  status=1
else
  ok "test passed: no secret-like or email-like string in the rendered file"
fi

# 7) work does not list opencode-settings: nothing renders.
work_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-opencode-settings-work.XXXXXX")"
tmp_roots+=("$work_root")
mkdir -p "$work_root/home"
printf '[data]\nprofile = "work"\n' > "$work_root/chezmoi.toml"
if chezmoi --config "$work_root/chezmoi.toml" --source "$DOTFILES_ROOT" --destination "$work_root/home" apply >/dev/null 2>&1 \
  && [[ ! -e "$work_root/home/.config/opencode" ]]; then
  ok "test passed: work renders no ~/.config/opencode (module not listed)"
else
  fail "test failed: work must not render ~/.config/opencode"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "opencode settings tests passed"
fi
exit "$status"
