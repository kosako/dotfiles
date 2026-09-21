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

# 4) The bash floor, EXACT and ordered: allow-all base; outward (`git push` /
#    `git clone`) and escalation (sudo / curl / wget) ask; the GitHub CLI ask
#    BY DEFAULT (`gh *`) with only read-only subcommands allowed back (#240:
#    enumerating mutations left `gh issue edit`, `gh pr close`, `gh api
#    -XPOST`, ... on the allow-all base); the deny rules LAST, because a
#    later broader ask would override an earlier deny (last match wins). The
#    ask patterns end in `*` WITHOUT a space so the argument-less forms (`git
#    push`, `gh pr create`) match too; a `git push *` spelling would let the
#    bare command fall through to the allow-all base (Codex review, PR #235).
expected_bash=$'*=allow\ngit push*=ask\ngit clone*=ask\ngh *=ask\ngh pr view*=allow\ngh pr list*=allow\ngh pr diff*=allow\ngh pr checks*=allow\ngh pr status*=allow\ngh issue view*=allow\ngh issue list*=allow\ngh issue status*=allow\ngh repo view*=allow\ngh release view*=allow\ngh release list*=allow\ngh run view*=allow\ngh run list*=allow\ngh workflow view*=allow\ngh workflow list*=allow\ngh label list*=allow\ngh gist view*=allow\ngh gist list*=allow\ngh search *=allow\ngh status*=allow\ngh auth status*=allow\ngh --version=allow\ngh version=allow\ngh help*=allow\nsudo*=ask\ncurl*=ask\nwget*=ask\ncat ~/.ssh/*=deny\ngh secret *=deny\ngh api *secrets*=deny\nenv=deny\nenv *=deny\nprintenv=deny\nprintenv *=deny'
actual_bash="$(yq -p json '.permission.bash | to_entries | .[] | .key + "=" + .value' "$config_file")"
if [[ "$actual_bash" == "$expected_bash" ]]; then
  ok "test passed: permission.bash is exactly the pinned floor (allow-all, 6 ask incl. gh default, 24 read allow-backs, 7 deny last; ordered)"
else
  fail "test failed: permission.bash drifted from the pinned floor; was:"
  printf '%s\n' "$actual_bash" >&2
  status=1
fi

# 4b) Policy-derived evaluation (#240). The exact pin above catches a changed
#     map but not a map that is exactly what a wrong design intended, so the
#     rendered map is also EVALUATED against a fixed command set with
#     OpenCode's rule semantics (glob, last match wins). Expected decisions
#     are written here by hand from docs/ai-policy.md — never derived from
#     the map. The command set is the Codex outward probe list of doctor.sh
#     (keep in sync; test-doctor.sh pins that list) plus the forms the audit
#     found: short-flag `gh api`, aliases, and the reads that must stay
#     allowed. Only `*` is a metacharacter in OpenCode patterns; bash `case`
#     also interprets `?`, `[`, `]` and `\`, so a rule containing those is
#     rejected up front rather than silently evaluated differently.
section "opencode bash rules: policy-derived decisions (#240)"

rule_rows="$(yq -p json '.permission.bash | to_entries | .[] | .key + "\t" + .value' "$config_file")"
if grep -Eq '[][?\\]' <<< "$rule_rows"; then
  fail "test failed: a bash rule uses ?, [, ] or \\ — only * is portable between OpenCode and this evaluator"
  status=1
fi

# opencode_bash_decision CMD -> prints allow | ask | deny (last match wins).
opencode_bash_decision() {
  local cmd="$1" key value decision=""
  while IFS=$'\t' read -r key value; do
    [[ -z "$key" ]] && continue
    # shellcheck disable=SC2254 # the rule IS a glob pattern by contract
    case "$cmd" in
      $key) decision="$value" ;;
    esac
  done <<< "$rule_rows"
  printf '%s\n' "$decision"
}

decision_failures=0
while IFS=$'\t' read -r expected cmd; do
  [[ -z "$cmd" ]] && continue
  actual="$(opencode_bash_decision "$cmd")"
  if [[ "$actual" == "$expected" ]]; then
    ok "test passed: $expected: $cmd"
  else
    fail "test failed: expected $expected, got '${actual:-<no rule matched>}': $cmd"
    decision_failures=$((decision_failures + 1))
  fi
done <<'CASES'
ask	git push
ask	git push origin main
ask	git clone https://example.invalid/repo
ask	gh pr create
ask	gh pr merge 1
ask	gh pr comment 1 --body x
ask	gh pr review 1 --approve
ask	gh pr edit 1 --body x
ask	gh pr close 1
ask	gh pr reopen 1
ask	gh pr ready 1
ask	gh pr checkout 1
ask	gh pr co 1
ask	gh pr lock 1
ask	gh issue create --title x
ask	gh issue comment 1 --body x
ask	gh issue edit 1 --body x
ask	gh issue close 1
ask	gh issue reopen 1
ask	gh issue delete 1 --yes
ask	gh issue transfer 1 o/r
ask	gh issue pin 1
ask	gh issue develop 1
ask	gh release create v1
ask	gh release edit v1
ask	gh release delete v1
ask	gh release upload v1 f
ask	gh repo create x
ask	gh repo clone o/r
ask	gh repo delete o/r
ask	gh repo edit o/r
ask	gh repo archive o/r
ask	gh repo rename x
ask	gh api --method POST repos/o/r/issues
ask	gh api repos/o/r/issues -XPOST
ask	gh api repos/o/r/issues -ftitle=x
ask	gh api repos/o/r/issues -F title=x --input body.json
ask	gh api graphql -f query=x
ask	gh api repos/o/r
ask	gh auth login
ask	gh auth logout
ask	gh auth refresh -s repo
ask	gh gist create f
ask	gh gist delete x
ask	gh workflow run x
ask	gh workflow disable x
ask	gh run cancel 1
ask	gh run rerun 1
ask	gh run delete 1
ask	gh label create x
ask	gh label delete x
ask	gh ssh-key add k
ask	gh gpg-key add k
ask	gh variable set X
ask	gh cache delete x
ask	gh project create
ask	gh secret
ask	gh extension install o/r
ask	sudo -v
ask	sudo ls
ask	curl https://example.invalid
ask	wget https://example.invalid
deny	gh secret set X
deny	gh secret list
deny	gh api repos/o/r/actions/secrets
deny	gh api --method PUT repos/o/r/actions/secrets/X
deny	env
deny	env FOO=1 gh pr create
deny	printenv
deny	printenv PATH
deny	cat ~/.ssh/id_ed25519
allow	gh pr view 1
allow	gh pr view 1 --comments
allow	gh pr list --state open
allow	gh pr diff 1
allow	gh pr checks 1
allow	gh pr status
allow	gh issue view 1
allow	gh issue list
allow	gh issue status
allow	gh auth status
allow	gh repo view o/r
allow	gh release list
allow	gh release view v1
allow	gh run list
allow	gh run view 1 --log
allow	gh workflow list
allow	gh workflow view x
allow	gh label list
allow	gh gist list
allow	gh gist view x
allow	gh search issues x
allow	gh status
allow	gh --version
allow	gh help pr
allow	git status
allow	git commit -m x
allow	git fetch origin
allow	ghq get o/r
allow	ls -la
allow	cat README.md
CASES
if [[ "$decision_failures" -gt 0 ]]; then
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
