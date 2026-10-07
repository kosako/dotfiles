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

# 3b) external_directory is pinned to ask (#315): the read floor matches paths
#     for the read tool only — grep matches its regex and glob its pattern, so
#     neither honours a read deny (OpenCode docs). Outside the project every
#     tool hits external_directory, which must stay "ask" in the managed floor
#     rather than ride on OpenCode's default.
if [[ "$(yq -p json '.permission.external_directory' "$config_file")" == ask ]]; then
  ok "test passed: permission.external_directory is pinned to ask"
else
  fail "test failed: permission.external_directory must be ask"
  status=1
fi

# 3c) edit (#304): the user-owned reference note `.agent-context.local.md`
#     is read by agents and never written, so OpenCode's file modifications
#     (edit / write / patch) deny it on an allow-all base: the bare name (a
#     path relative to the start directory) and `*/.agent-context.local.md`
#     (a sub directory or an absolute path — `*` in OpenCode patterns
#     matches any character, `/` included), so a look-alike such as
#     example.agent-context.local.md stays allowed (Codex review R1, PR
#     #327). This checks the patterns under the documented glob only; which
#     path form OpenCode passes in is not verified here.
actual_edit="$(yq -p json '.permission.edit | to_entries | .[] | .key + "=" + .value' "$config_file")"
edit_rows="$(yq -p json '.permission.edit | to_entries | .[] | .key + "\t" + .value' "$config_file")"
# opencode_edit_decision PATH -> allow | deny (last match wins).
opencode_edit_decision() {
  local path="$1" key value decision=""
  while IFS=$'\t' read -r key value; do
    [[ -z "$key" ]] && continue
    # shellcheck disable=SC2254 # the rule IS a glob pattern by contract
    case "$path" in
      $key) decision="$value" ;;
    esac
  done <<< "$edit_rows"
  printf '%s\n' "$decision"
}
edit_misses=""
for edit_case in "deny|.agent-context.local.md" "deny|sub/dir/.agent-context.local.md" "deny|/Users/someone/src/repo/.agent-context.local.md" \
  "allow|README.md" "allow|docs/agent-context.md" "allow|.agent-context.local.md.bak" "allow|/Users/someone/src/repo/AGENTS.md" \
  "allow|example.agent-context.local.md" "allow|/Users/someone/src/repo/example.agent-context.local.md"; do
  edit_got="$(opencode_edit_decision "${edit_case#*|}")"
  [[ "$edit_got" == "${edit_case%%|*}" ]] || edit_misses+="  ${edit_case#*|} -> ${edit_got:-<no rule>} (expected ${edit_case%%|*})"$'\n'
done
if [[ "$actual_edit" == $'*=allow\n.agent-context.local.md=deny\n*/.agent-context.local.md=deny' && -z "$edit_misses" ]]; then
  ok "test passed: permission.edit is exactly allow-all with the reference note denied (in and outside the project)"
else
  fail "test failed: permission.edit unexpected; map was:"
  printf '%s\n%s' "$actual_edit" "$edit_misses" >&2
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
#    #304 adds the same git rules as the Claude floor (dot_claude/
#    settings.json.tmpl): the work-discarding forms and the hook skips in
#    any placement ask, each option a word of its own; the hook skips right
#    after `git commit` / `git push` deny, last. OpenCode has no rule that
#    makes a trailing " *" match the bare command, so those denies list the
#    bare form too.
expected_bash=$'*=allow\ngit push*=ask\ngit clone*=ask\ngh *=ask\ngh pr view=allow\ngh pr view *=allow\ngh pr list=allow\ngh pr list *=allow\ngh pr diff=allow\ngh pr diff *=allow\ngh pr checks=allow\ngh pr checks *=allow\ngh pr status=allow\ngh pr status *=allow\ngh issue view=allow\ngh issue view *=allow\ngh issue list=allow\ngh issue list *=allow\ngh issue status=allow\ngh issue status *=allow\ngh repo view=allow\ngh repo view *=allow\ngh release view=allow\ngh release view *=allow\ngh release list=allow\ngh release list *=allow\ngh run view=allow\ngh run view *=allow\ngh run list=allow\ngh run list *=allow\ngh workflow view=allow\ngh workflow view *=allow\ngh workflow list=allow\ngh workflow list *=allow\ngh label list=allow\ngh label list *=allow\ngh gist view=allow\ngh gist view *=allow\ngh gist list=allow\ngh gist list *=allow\ngh search *=allow\ngh status=allow\ngh status *=allow\ngh auth status=allow\ngh --version=allow\ngh version=allow\ngh help=allow\ngh help *=allow\nsudo*=ask\ncurl*=ask\nwget*=ask\nop *=ask\ngit clean *=ask\ngit * clean *=ask\ngit restore *=ask\ngit * restore *=ask\ngit *checkout* -- *=ask\ngit *checkout* .=ask\ngit *push* +*=ask\ngit *reset* --hard=ask\ngit *reset* --hard *=ask\ngit *checkout* --force=ask\ngit *checkout* --force *=ask\ngit *checkout* -f=ask\ngit *checkout* -f *=ask\ngit *checkout* -qf=ask\ngit *checkout* -qf *=ask\ngit *checkout* -fq=ask\ngit *checkout* -fq *=ask\ngit *switch* --force=ask\ngit *switch* --force *=ask\ngit *switch* --discard-changes=ask\ngit *switch* --discard-changes *=ask\ngit *switch* -f=ask\ngit *switch* -f *=ask\ngit *switch* -qf=ask\ngit *switch* -qf *=ask\ngit *switch* -fq=ask\ngit *switch* -fq *=ask\ngit *push* --force=ask\ngit *push* --force *=ask\ngit *push* -f=ask\ngit *push* -f *=ask\ngit *push* -uf=ask\ngit *push* -uf *=ask\ngit *push* -fu=ask\ngit *push* -fu *=ask\ngit *branch* -D=ask\ngit *branch* -D *=ask\ngit *branch* --force=ask\ngit *branch* --force *=ask\ngit *branch* -f=ask\ngit *branch* -f *=ask\ngit *branch* -df=ask\ngit *branch* -df *=ask\ngit *branch* -fd=ask\ngit *branch* -fd *=ask\ngit *commit* -n=ask\ngit *commit* -n *=ask\ngit *commit* -nm=ask\ngit *commit* -nm *=ask\ngit *commit* -an=ask\ngit *commit* -an *=ask\ngit *commit* -anm=ask\ngit *commit* -anm *=ask\ngit *--no-verify*=ask\ncat ~/.ssh/*=deny\ngh secret *=deny\ngh api *secrets*=deny\ngh auth token*=deny\ngh auth status*--show-token*=deny\ngh auth status* -t*=deny\ngh auth status* -at*=deny\ngh -* auth *=deny\ngh auth -*=deny\nenv=deny\nenv *=deny\nprintenv=deny\nprintenv *=deny\nsecurity find-generic-password*=deny\nsecurity * find-generic-password*=deny\nsecurity find-internet-password*=deny\nsecurity * find-internet-password*=deny\nsecurity dump-keychain*=deny\nsecurity * dump-keychain*=deny\nsecurity export*=deny\nsecurity * export*=deny\ngit commit --no-verify=deny\ngit commit --no-verify *=deny\ngit push --no-verify=deny\ngit push --no-verify *=deny\ngit commit -n=deny\ngit commit -n *=deny'
actual_bash="$(yq -p json '.permission.bash | to_entries | .[] | .key + "=" + .value' "$config_file")"
if [[ "$actual_bash" == "$expected_bash" ]]; then
  ok "test passed: permission.bash is exactly the pinned floor (allow-all, 7 ask incl. gh default and the whole 1Password CLI, 44 read allow-backs as exact + '... *' pairs, #304's 54 work-discarding git / hook-skip asks, 27 deny last incl. the gh token display bundle -at, gh auth with options before or right after auth, keychain password read / dump / export with and without leading options, and #304's hook skips right after git commit / git push; ordered)"
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
#     the map. The command set is the Codex probe list of doctor.sh (keep in
#     sync; test-doctor.sh pins that list; the outward probes are the rows
#     without a tab, expecting ask, and the secret-read probes of #334 carry
#     their own expected decision) plus the forms the audit
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
# Rows are "<expected>\t<command>". A row with no tab is one of doctor.sh's
# outward_probes VERBATIM (argument-less forms included) and expects ask —
# the same strings, so a decision regression on the bare forms is caught too.
while IFS=$'\t' read -r expected cmd; do
  if [[ -z "$cmd" ]]; then
    [[ -z "$expected" ]] && continue
    cmd="$expected"
    expected="ask"
  fi
  actual="$(opencode_bash_decision "$cmd")"
  if [[ "$actual" == "$expected" ]]; then
    ok "test passed: $expected: $cmd"
  else
    fail "test failed: expected $expected, got '${actual:-<no rule matched>}': $cmd"
    decision_failures=$((decision_failures + 1))
  fi
done <<'CASES'
git push
git clone https://example.invalid/repo
gh pr create
gh pr merge
gh pr comment
gh pr edit
gh pr close
gh issue create
gh issue comment
gh issue edit
gh issue close
gh issue delete
gh issue transfer
gh release create
gh release edit
gh release delete
gh release upload
gh repo delete
gh repo edit
gh repo archive
gh repo rename
gh api --method POST repos/o/r/issues
gh auth login
sudo -v
curl https://example.invalid
wget https://example.invalid
ask	op read op://example/item/field
ask	op item get example
deny	security find-generic-password -s example.invalid -w
deny	security -q find-generic-password -s example.invalid -w
deny	security find-internet-password -s example.invalid -w
deny	gh secret set
ask	git push origin main
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
ask	gh status-token
ask	gh statusx
ask	gh help-token
ask	gh pr viewx
ask	gh pr view-token 1
ask	gh search
ask	gh auth
ask	sudo -v
ask	sudo ls
ask	curl https://example.invalid
ask	wget https://example.invalid
deny	gh secret set X
deny	gh secret list
deny	gh api repos/o/r/actions/secrets
deny	gh api --method PUT repos/o/r/actions/secrets/X
deny	gh auth token
deny	gh auth token --hostname github.com
deny	gh auth status --show-token
deny	gh auth status -t
deny	gh auth status --hostname github.com -t
deny	gh auth status --hostname github.com --show-token
deny	gh auth status -at
deny	gh auth status --hostname github.com -at
ask	gh auth status -a
deny	gh auth --hostname=example.invalid token
deny	gh --hostname example.invalid auth token
deny	gh --hostname=example.invalid auth status -t
deny	gh auth -at status
deny	gh auth --hostname example.invalid status --show-token
ask	gh issue comment 1 --body auth token
ask	gh auth login --with-token
ask	gh auth status --hostname github.com
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
allow	gh status --org o
allow	gh --version
allow	gh version
allow	gh help
allow	gh help pr
allow	gh pr view
allow	gh issue list --state open
allow	gh release list --limit 5
ask	op read op://vault/item/field
ask	op item get x --reveal
ask	op run -- env
ask	op inject -i tpl.env
ask	op document get x
ask	op --account my read op://vault/item/field
ask	op --account=my item get x --reveal
ask	op --account my run -- env
ask	op --account my inject -i tpl.env
ask	op --account my document get x
ask	op item --account my get x --reveal
ask	op document --account my get x
ask	op signin --raw
ask	op whoami
ask	op item list
ask	op --account my whoami
deny	security find-generic-password -s gh:github.com -w
deny	security find-internet-password -s example.invalid -g
deny	security dump-keychain
deny	security export -k login.keychain
deny	security -q find-generic-password -s gh:github.com -w
deny	security -v find-internet-password -s example.invalid -g
deny	security -q dump-keychain -d
deny	security -q export -k login.keychain
allow	security find-identity -v -p codesigning
allow	security -q find-identity -v -p codesigning
allow	git status
allow	git commit -m x
allow	git fetch origin
allow	ghq get o/r
allow	ls -la
allow	cat README.md
ask	git reset --hard
ask	git reset HEAD~1 --hard
ask	git -C /tmp/x reset --hard
ask	git clean -fd
ask	git -C /tmp/x clean -f
ask	git checkout -- a.txt
ask	git checkout HEAD .
ask	git checkout -f main
ask	git checkout -qf main
ask	git switch --discard-changes main
ask	git switch -qf main
ask	git restore a.txt
ask	git -C /tmp/x push --force origin main
ask	git -C /tmp/x push -uf origin main
ask	git branch -D feat
ask	git branch -df topic
ask	git -C /tmp/x branch --delete --force feat
ask	git commit -m x --no-verify
ask	git -C /tmp/x commit --no-verify -m x
ask	git commit -nm x
ask	git commit -m x -n
ask	git grep -e --no-verify
ask	git commit -m "document --no-verify"
deny	git commit --no-verify
deny	git commit --no-verify -m x
deny	git push --no-verify
deny	git push --no-verify origin main
deny	git commit -n
deny	git commit -n -m x
allow	git commit --amend --no-edit
allow	git checkout main
allow	git checkout -b feat/conf
allow	git switch -c feat/x
allow	git branch -d feature-Draft
allow	git branch -d feature-f
allow	git checkout feature-f
allow	git reset --soft HEAD~1
allow	git -C /tmp/x status
allow	git commit -m "tidy cleanup"
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

# 6) No secret-shaped VALUE and no real identity in the rendered file (the
#    only '@' allowed is none; the only home path is the rendered fixture home).
#    Matches value shapes (provider key prefixes, `api_key: ...` / `token: "..."`
#    assignments), not the bare word: the bash rules legitimately name
#    `gh auth token` / `--show-token` as deny patterns (#240).
if grep -Eqi 'sk-[a-z0-9]|ghp_[a-z0-9]|gho_[a-z0-9]|github_pat_|api[_-]?key"?[[:space:]]*[:=]|token"?[[:space:]]*[:=][[:space:]]*"[^"]+"|@' "$config_file"; then
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
