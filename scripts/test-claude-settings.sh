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
# It also fixes the GitHub injection guard content (issue #119) in three deny
# tiers (Phase 2 task B): (1) an UNCONDITIONAL never-legit secret floor
# (ssh-key / env-dump / gh-secret reads) that is always rendered; (2) gateGitHubMcp
# -> deny the github MCP server (ON for personal); (3) enforceAiSandbox -> the
# human-legit write gate (main-push + .env-read deny, release/protection ask),
# which stays default false (absent until flipped). The matchers are
# best-effort/steering; a bypass negative test keeps that visible. See
# docs/ai-environment-boundary.md.
# It also fixes the hook registrations (#137 / #199): enableGitHubIsolatedReader
# (ON for personal) -> exactly one PreToolUse/Bash command hook pointing at the
# agent-tools-deployed personal-safe-gh-hook; enableQualityLoopHooks (ON for
# personal) -> exactly one PostToolUse/Edit|Write hook (personal-fast-edit-check)
# and one matcher-less Stop hook (personal-changed-scope-qa); enableHerdrIntegration
# (ON for personal, #225) -> exactly one SessionStart command hook in the
# shape herdr's installer emits (matcher ^(startup|resume|clear|compact|fork)$, herdr 0.9.3 / #274) (bash '<home>/.claude/hooks/herdr-agent-state.sh'
# session, timeout 10); each capability adds exactly its own events, and all
# three false -> no hooks key at all.
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
# root and registers it in tmp_roots, then reads the rendered
# ~/.claude/settings.json out of ROOT/home (caller-creates-root contract;
# see the #150 leak note in test-lib.sh).

section "claude settings sandbox content"

# 1) Committed default: enforceAiSandbox=false -> no sandbox block, and the
#    file is still valid JSON (the conditional must not corrupt it).
off_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings.XXXXXX")"
tmp_roots+=("$off_root")
if ! render_personal_into "$DOTFILES_ROOT" "$off_root"; then
  fail "test failed: personal apply (default) did not render"
  exit 1
fi
off_file="$off_root/home/.claude/settings.json"
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
make_flipped_source "$src_root"
flip_personal_capability "$src_root/src" enforceAiSandbox true

on_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings.XXXXXX")"
tmp_roots+=("$on_root")
if ! render_personal_into "$src_root/src" "$on_root"; then
  fail "test failed: personal apply (enforceAiSandbox=true) did not render"
  exit 1
fi
on_file="$on_root/home/.claude/settings.json"
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

# 3b) Third-party plugin marketplaces (#317): every extraKnownMarketplaces entry
#     pins its source to a ref (a tag — Claude Code's marketplace source takes
#     no commit sha, and a default-branch name would not pin anything) and sets
#     autoUpdate false explicitly (the settings value wins over the /plugin
#     toggle), so a plugin changes only through a PR that moves the ref
#     (docs/update-policy.md).
mkt_count="$(yq -p json '.extraKnownMarketplaces // {} | length' "$off_file")"
mkt_unpinned="$(yq -p json '.extraKnownMarketplaces // {} | to_entries | .[] | select((.value.source.ref // "") == "" or (.value.source.ref // "" | test("^(main|master|HEAD)$")) or .value.autoUpdate != false) | .key' "$off_file")"
if [[ "$mkt_count" -ge 1 && -z "$mkt_unpinned" ]]; then
  ok "test passed: every third-party plugin marketplace ($mkt_count) pins source.ref and sets autoUpdate=false"
else
  fail "test failed: plugin marketplace not pinned or auto-updating (count=$mkt_count): ${mkt_unpinned:-<none declared>}"
  status=1
fi

section "claude settings GitHub injection guard (#119)"

# 4) Committed personal render: the never-legit secret floor is UNCONDITIONAL
#    (30 entries: ssh-key / credential-store / env-dump / gh-secret reads; the
#    credential-store files — gh OAuth token, AWS keys, ~/.netrc, Codex
#    auth.json — joined in #136, OpenCode auth.json in #234; the credential
#    display forms `gh auth token` / `gh auth status --show-token|-t|-at`
#    plus `gh auth` with options before or right after `auth`, and the
#    keychain password read / dump / export, each also behind leading
#    `security` options, in #315, symmetric with OpenCode) and gateGitHubMcp
#    is ON (Phase 2). #304 adds, unconditionally, the hook-skip deny in the
#    one position argument data cannot take (--no-verify or -n right after
#    `git commit`, --no-verify right after `git push`) and the Edit deny on
#    any .agent-context.local.md, so the deny is those 34 + mcp__github = 35,
#    followed by gateUnusedClaudeMcp's 21 (#341, ON for personal: the four
#    claude.ai connectors as whole servers, then 17 Notion write tools) = 56
#    (the floor present even with enforceAiSandbox off is
#    the core of Phase 2 task B). The ask block is the whole 1Password CLI
#    (`op *`: global options can sit anywhere, so the program is the unit;
#    #315: human-directed uses exist, so approval rather than deny) followed
#    by #334's asks for reading the config files that may hold secrets (3)
#    and the git asks of #304 / #334 (71): the work-discarding git forms,
#    each option as a word of its own after its subcommand, and the hook
#    skips in any other position.
#    We pin the EXACT ordered
#    arrays, not length + a few representatives: this is a security-boundary
#    regression test, so it must catch a floor matcher being swapped for
#    another (which would keep the length). What the rules decide for real
#    commands is pinned separately (4c).
expected_git_deny=$'Bash(git commit --no-verify *)\nBash(git push --no-verify *)\nBash(git commit -n *)\nEdit(//**/.agent-context.local.md)'
expected_git_ask=$'Bash(git clean *)\nBash(git * clean *)\nBash(git restore *)\nBash(git * restore *)\nBash(git *checkout* -- *)\nBash(git *checkout* .)\nBash(git *push* +*)\nBash(git *push* :*)\nBash(git *reset* --hard)\nBash(git *reset* --hard *)\nBash(git *checkout* --force)\nBash(git *checkout* --force *)\nBash(git *checkout* -f)\nBash(git *checkout* -f *)\nBash(git *checkout* -qf)\nBash(git *checkout* -qf *)\nBash(git *checkout* -fq)\nBash(git *checkout* -fq *)\nBash(git *switch* --force)\nBash(git *switch* --force *)\nBash(git *switch* --discard-changes)\nBash(git *switch* --discard-changes *)\nBash(git *switch* -f)\nBash(git *switch* -f *)\nBash(git *switch* -qf)\nBash(git *switch* -qf *)\nBash(git *switch* -fq)\nBash(git *switch* -fq *)\nBash(git *push* --force)\nBash(git *push* --force *)\nBash(git *push* -f)\nBash(git *push* -f *)\nBash(git *push* -uf)\nBash(git *push* -uf *)\nBash(git *push* -fu)\nBash(git *push* -fu *)\nBash(git *branch* -D)\nBash(git *branch* -D *)\nBash(git *branch* --force)\nBash(git *branch* --force *)\nBash(git *branch* -f)\nBash(git *branch* -f *)\nBash(git *branch* -df)\nBash(git *branch* -df *)\nBash(git *branch* -fd)\nBash(git *branch* -fd *)\nBash(git *commit* -n)\nBash(git *commit* -n *)\nBash(git *commit* -nm)\nBash(git *commit* -nm *)\nBash(git *commit* -an)\nBash(git *commit* -an *)\nBash(git *commit* -anm)\nBash(git *commit* -anm *)\nBash(git *push* --mirror)\nBash(git *push* --mirror *)\nBash(git *push* --delete)\nBash(git *push* --delete *)\nBash(git *push* -d)\nBash(git *push* -d *)\nBash(git *branch* -M)\nBash(git *branch* -M *)\nBash(git *stash* drop)\nBash(git *stash* drop *)\nBash(git *stash* clear)\nBash(git *stash* clear *)\nBash(git *worktree remove* --force)\nBash(git *worktree remove* --force *)\nBash(git *worktree remove* -f)\nBash(git *worktree remove* -f *)\nBash(git *--no-verify*)'
expected_unused_mcp=$'mcp__claude_ai_Gmail\nmcp__claude_ai_Google_Calendar\nmcp__claude_ai_Google_Drive\nmcp__claude_ai_Claude_Docs'
for notion_tool in notion-create-comment notion-create-attachment notion-create-database notion-create-view notion-update-view notion-update-data-source notion-create-folder notion-update-folder notion-restore-pages notion-convert-page-to-skill notion-upload-skill notion-spawn-session notion-send-message-to-session notion-stop-session notion-move-pages notion-duplicate-page notion-create-file-upload; do
  expected_unused_mcp+=$'\nmcp__plugin_Notion_notion__'"$notion_tool"
done
expected_deny=$'Read(~/.ssh/**)\nRead(~/.aws/**)\nRead(~/.config/gh/**)\nRead(~/.netrc)\nRead(~/.codex/auth.json)\nRead(~/.local/share/opencode/auth.json)\nBash(cat ~/.ssh/*)\nBash(gh secret *)\nBash(gh api *secrets*)\nBash(env)\nBash(env *)\nBash(printenv)\nBash(printenv *)\nBash(gh auth token)\nBash(gh auth token *)\nBash(gh auth status *--show-token*)\nBash(gh auth status -t*)\nBash(gh auth status * -t*)\nBash(gh auth status -at*)\nBash(gh auth status * -at*)\nBash(gh -* auth *)\nBash(gh auth -*)\nBash(security find-generic-password *)\nBash(security * find-generic-password *)\nBash(security find-internet-password *)\nBash(security * find-internet-password *)\nBash(security dump-keychain*)\nBash(security * dump-keychain*)\nBash(security export *)\nBash(security * export *)\n'"$expected_git_deny"$'\nmcp__github\n'"$expected_unused_mcp"
actual_deny="$(yq -p json '.permissions.deny[]' "$off_file")"
expected_ask=$'Bash(op *)\nRead(~/.codex/config.toml)\nRead(~/.zshrc.local)\nRead(~/.config/opencode/opencode.local.json)\n'"$expected_git_ask"
ask_default="$(yq -p json '.permissions.ask[]' "$off_file" 2>/dev/null || true)"
if [[ "$actual_deny" == "$expected_deny" && "$ask_default" == "$expected_ask" ]]; then
  ok "test passed: committed personal deny is exactly the secret floor + #304 hook-skip / note deny + github MCP + #341's unused MCP (56, ordered); ask is exactly the whole 1Password CLI, #334's reads of secret-bearing config files, and the work-discarding git and hook skips of #304 / #334 (75, ordered; enforceAiSandbox off)"
else
  fail "test failed: committed personal deny/ask unexpected (ask=$ask_default); deny was:"
  printf '%s\n' "$actual_deny" >&2
  status=1
fi

# 4b) ALL four human-legit gate matchers must be absent from the committed render
#     (enforceAiSandbox off): main/master push and both .env read paths ride on
#     enforceAiSandbox, so none appear until it is flipped (the tier split).
if grep -Fq '"Bash(git push * main)"' "$off_file" \
  || grep -Fq '"Bash(git push * master)"' "$off_file" \
  || grep -Fq '"Bash(cat *.env*)"' "$off_file" \
  || grep -Fq '"Read(//**/.env*)"' "$off_file"; then
  fail "test failed: a human-legit gate matcher leaked into committed render with enforceAiSandbox off"
  status=1
else
  ok "test passed: all human-legit gate matchers (main/master push, .env reads) absent until enforceAiSandbox (committed render)"
fi

# 4c) What the committed rules decide for real git commands (#304): the
#     work-discarding forms ask (an option counts as a word of its own, so a
#     branch name merely containing -f / -D does not; representative short
#     bundles such as -uf / -df / -qf do), a hook skip denies where argument
#     data cannot be (right after `git commit` / `git push`) and asks anywhere
#     else (global options, later or last words, or a quoted mention — Codex
#     review R1 / R2, PR #326), and everyday git (plain commit /
#     push, --force-with-lease, branch switching and creation, -d of a
#     merged branch, soft resets) is left to the harness. The rules
#     are evaluated the way Claude Code documents Bash rule matching
#     (code.claude.com/docs/en/permissions, "Wildcard patterns"): `*` stands
#     for any text, spaces included, everything else is literal, a trailing
#     " *" that is the rule's only wildcard also matches the bare command, and
#     deny is checked before ask. This pins the rule TEXT against that
#     reading; it does not prove the harness — the matchers stay steering.
# claude_rule_matches BODY CMD — whether a Bash rule body (inside Bash(...))
# matches CMD. A body with a regex-special character other than `*`, `.`
# and `+` fails the test instead of being guessed at.
claude_rule_matches() {
  local body="$1" cmd="$2" re="" i c
  if [[ "$body" == *" *" && "${body%" *"}" != *"*"* && "$cmd" == "${body%" *"}" ]]; then
    return 0
  fi
  for ((i = 0; i < ${#body}; i++)); do
    c="${body:i:1}"
    case "$c" in
      '*') re+='.*' ;;
      '.' | '+') re+="\\$c" ;;
      '[' | ']' | '(' | ')' | '{' | '}' | '|' | '^' | '$' | '?' | '\') return 2 ;;
      *) re+="$c" ;;
    esac
  done
  re="^${re}\$"
  [[ "$cmd" =~ $re ]]
}
# claude_decision CMD — deny / ask / none for CMD under the committed rules.
claude_decision() {
  local kind rule rc
  for kind in deny ask; do
    while IFS= read -r rule; do
      [[ "$rule" == 'Bash('*')' ]] || continue
      rule="${rule#Bash(}"
      rule="${rule%)}"
      rc=0
      claude_rule_matches "$rule" "$1" || rc=$?
      if [[ "$rc" -eq 2 ]]; then
        printf 'unsupported:%s\n' "$rule"
        return 0
      elif [[ "$rc" -eq 0 ]]; then
        printf '%s\n' "$kind"
        return 0
      fi
    done < <(yq -p json ".permissions.${kind}[]" "$off_file")
  done
  printf 'none\n'
}
decision_misses=""
while IFS='|' read -r want cmd; do
  [[ -n "$want" ]] || continue
  got="$(claude_decision "$cmd")"
  [[ "$got" == "$want" ]] || decision_misses+="  $cmd -> $got (expected $want)"$'\n'
done <<'CASES'
ask|git reset --hard
ask|git reset --hard HEAD~1
ask|git reset HEAD~1 --hard
ask|git -C /tmp/x reset --hard
ask|git clean -fd
ask|git clean -fdx
ask|git clean -f
ask|git -C /tmp/x clean -fd
ask|git checkout -- a.txt
ask|git checkout HEAD -- a.txt
ask|git checkout .
ask|git checkout HEAD~1 .
ask|git -C /tmp/x checkout -- a.txt
ask|git checkout -f main
ask|git checkout main -f
ask|git checkout --force main
ask|git switch --discard-changes main
ask|git switch -f main
ask|git switch main --force
ask|git restore a.txt
ask|git restore --staged --worktree a.txt
ask|git -C /tmp/x restore .
ask|git push --force
ask|git push -f
ask|git push origin main --force
ask|git push origin -f main
ask|git push origin +main
ask|git push +main
ask|git -C /tmp/x push --force origin main
ask|git branch -D feat
ask|git branch --delete --force feat
ask|git branch -d -f feat
ask|git -C /tmp/x branch -D feat
ask|git push --mirror origin
ask|git push origin --delete feat
ask|git push -d origin feat
ask|git push origin :feat
ask|git branch -M main
ask|git stash drop
ask|git stash drop stash@{0}
ask|git stash clear
ask|git worktree remove --force ../wt
ask|git worktree remove -f ../wt
ask|git -C /tmp/x stash clear
ask|git push -uf origin main
ask|git push -fu
ask|git branch -df topic
ask|git checkout -qf main
ask|git switch -qf main
deny|git commit --no-verify -m x
deny|git commit --no-verify
deny|git push --no-verify
deny|git push --no-verify origin main
deny|git commit -n
deny|git commit -n -m x
ask|git commit -m x --no-verify
ask|git push origin main --no-verify
ask|git merge topic --no-verify
ask|git commit -m x -n
ask|git grep -e --no-verify
ask|git commit -m -n
ask|git -C /tmp/x commit --no-verify -m x
ask|git merge --no-verify topic
ask|git commit --amend --no-verify -m x
ask|git -C /tmp/x commit -n -m x
ask|git commit -a -n -m x
ask|git commit -nm x
ask|git commit -an -m x
ask|git log --grep=--no-verify
ask|git commit -m "document --no-verify"
ask|git commit -m "document -n option"
none|git status
none|git commit -m x
none|git commit -m "tidy cleanup"
none|git commit -m "checkouts restored"
none|git commit --amend --no-edit
none|git commit -am x
none|git push
none|git push origin main
none|git push -u origin feat/x-fix
none|git push --force-with-lease
none|git push --force-with-lease origin feat
none|git push --follow-tags
none|git push --force-with-lease origin feature-f
none|git branch -d feature-Draft
none|git checkout -b feat/conf
none|git checkout main
none|git checkout -b feat/foo-fix
none|git checkout -
none|git switch main
none|git switch -c feat/x
none|git branch -d merged
none|git branch feat-foo
none|git reset HEAD~1
none|git reset --soft HEAD~1
none|git log --oneline
none|git diff
none|git add -A
none|git fetch
none|git pull --ff-only
none|git rebase main
none|git stash
none|git stash pop
none|git stash list
none|git worktree add ../wt feat
none|git worktree remove ../wt
none|git worktree add --force ../wt main
none|git worktree add -f ../wt main
none|git branch -m old new
none|git push origin main:main
none|git -C /tmp/x status
CASES
if [[ -z "$decision_misses" ]]; then
  ok "test passed: the committed rules ask for work-discarding git, deny hook skips right after commit / push and ask elsewhere, and leave everyday git alone (per the documented matching)"
else
  fail "test failed: committed rules decide git commands unexpectedly:"
  printf '%s' "$decision_misses" >&2
  status=1
fi

# 4d) What the committed Read rules decide for real paths (#334, Codex review
#     R2, PR #338), per the documented path rules: `~/path` is from the home
#     directory, a trailing `/**` covers everything under it, and deny is
#     checked before ask. Only those two shapes are evaluated; any other Read
#     rule fails the test instead of being guessed at. A made-up home keeps
#     the real one out of it.
claude_read_home="/fixture-home"
# claude_read_decision PATH -> deny / ask / none under the committed Read rules.
claude_read_decision() {
  local kind rule body base
  for kind in deny ask; do
    while IFS= read -r rule; do
      [[ "$rule" == 'Read('*')' ]] || continue
      body="${rule#Read(}"
      body="${body%)}"
      # Only `~/<path>` and `~/<path>/**` (no other wildcard) are evaluated.
      if [[ "$body" != \~/* || "${body%/\*\*}" == *"*"* ]]; then
        printf 'unsupported:%s\n' "$body"
        return 0
      fi
      base="$claude_read_home/${body#\~/}"
      if [[ "$body" == *"/**" ]]; then
        base="${base%/\*\*}"
        [[ "$1" == "$base"/* ]] && { printf '%s\n' "$kind"; return 0; }
      elif [[ "$1" == "$base" ]]; then
        printf '%s\n' "$kind"
        return 0
      fi
    done < <(yq -p json ".permissions.${kind}[]" "$off_file")
  done
  printf 'none\n'
}
read_misses=""
while IFS='|' read -r want path; do
  [[ -n "$want" ]] || continue
  got="$(claude_read_decision "$path")"
  [[ "$got" == "$want" ]] || read_misses+="  $path -> $got (expected $want)"$'\n'
done <<CASES
ask|$claude_read_home/.codex/config.toml
ask|$claude_read_home/.zshrc.local
ask|$claude_read_home/.config/opencode/opencode.local.json
none|$claude_read_home/.codex/config.toml.bak
none|$claude_read_home/.zshrc
none|$claude_read_home/.config/opencode/opencode.json
none|$claude_read_home/src/repo/.zshrc.local
deny|$claude_read_home/.ssh/id_ed25519
deny|$claude_read_home/.codex/auth.json
deny|$claude_read_home/.config/gh/hosts.yml
deny|$claude_read_home/.netrc
CASES
if [[ -z "$read_misses" ]]; then
  ok "test passed: the committed Read rules ask for the secret-bearing config files, deny the credential stores, and leave look-alikes alone (per the documented path rules)"
else
  fail "test failed: committed Read rules decide paths unexpectedly:"
  printf '%s' "$read_misses" >&2
  status=1
fi

# 5) enforceAiSandbox=true: the human-legit write gate is ADDED on top of the
#    unconditional floor (on_file from section 2). main push + .env read become
#    deny; release and branch-protection need approval (ask). The floor entries
#    (ssh / env reads) are present regardless. Context-gated writes (merge/PR/
#    comment/label/push ai/*) are intentionally NOT here (Phase 2 hook).
#    Pinned as the EXACT ordered arrays (the unconditional floor of section 4
#    followed by the gated entries), so losing a floor entry or the 1Password
#    ask in this state is caught too, not only in the committed render.
expected_deny_on="$expected_deny"$'\nBash(cat *.env*)\nRead(//**/.env*)\nBash(git push * main)\nBash(git push * master)'
expected_ask_on="$expected_ask"$'\nBash(gh release create *)\nBash(gh release delete *)\nBash(gh release edit *)\nBash(gh api *protection*)\nBash(gh api *rulesets*)'
actual_deny_on="$(yq -p json '.permissions.deny[]' "$on_file")"
actual_ask_on="$(yq -p json '.permissions.ask[]' "$on_file" 2>/dev/null || true)"
if [[ "$actual_deny_on" == "$expected_deny_on" && "$actual_ask_on" == "$expected_ask_on" ]]; then
  ok "test passed: enforceAiSandbox=true is exactly the secret floor + github MCP + human-legit gate (main/master push, .env read) as deny, and the whole 1Password CLI + release/protection as ask (ordered)"
else
  fail "test failed: enforceAiSandbox=true deny/ask unexpected; deny / ask were:"
  printf '%s\n' "$actual_deny_on" "---" "$actual_ask_on" >&2
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
make_flipped_source "$mcp_src"
flip_personal_capability "$mcp_src/src" gateGitHubMcp true
mcp_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings.XXXXXX")"
tmp_roots+=("$mcp_root")
if ! render_personal_into "$mcp_src/src" "$mcp_root"; then
  fail "test failed: personal apply (gateGitHubMcp=true) did not render"
  exit 1
fi
mcp_file="$mcp_root/home/.claude/settings.json"
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
make_flipped_source "$both_src"
flip_personal_capability "$both_src/src" gateGitHubMcp true
flip_personal_capability "$both_src/src" enforceAiSandbox true
both_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings.XXXXXX")"
tmp_roots+=("$both_root")
if ! render_personal_into "$both_src/src" "$both_root"; then
  fail "test failed: personal apply (both gates true) did not render"
  exit 1
fi
both_file="$both_root/home/.claude/settings.json"
if yq -p json '.' "$both_file" >/dev/null 2>&1 \
  && grep -Fq '"mcp__github"' "$both_file" \
  && grep -Fq '"Bash(git push * main)"' "$both_file"; then
  ok "test passed: both gates on -> valid JSON with combined MCP + write deny"
else
  fail "test failed: both gates on produced invalid JSON or missing matchers"
  status=1
fi

# 6c) gateUnusedClaudeMcp=false (#341): none of its 21 denies render, the JSON
#     stays valid, and the daily Notion writes are never denied either way.
unused_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings-unused.XXXXXX")"
tmp_roots+=("$unused_src")
make_flipped_source "$unused_src"
flip_personal_capability "$unused_src/src" gateUnusedClaudeMcp false
unused_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings.XXXXXX")"
tmp_roots+=("$unused_root")
if ! render_personal_into "$unused_src/src" "$unused_root"; then
  fail "test failed: personal apply (gateUnusedClaudeMcp=false) did not render"
  exit 1
fi
unused_file="$unused_root/home/.claude/settings.json"
if yq -p json '.' "$unused_file" >/dev/null 2>&1 \
  && ! grep -Fq 'mcp__claude_ai_' "$unused_file" \
  && ! grep -Fq 'mcp__plugin_Notion_notion__' "$unused_file" \
  && grep -Fq '"mcp__github"' "$unused_file"; then
  ok "test passed: gateUnusedClaudeMcp=false renders none of its denies (valid JSON, github MCP deny kept)"
else
  fail "test failed: gateUnusedClaudeMcp=false still renders its denies (or invalid JSON)"
  status=1
fi
if grep -Fq 'notion-update-page' "$off_file" || grep -Fq 'notion-create-pages' "$off_file"; then
  fail "test failed: a daily Notion write (notion-update-page / notion-create-pages) is denied"
  status=1
else
  ok "test passed: the daily Notion writes (notion-update-page / notion-create-pages) are not denied"
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

section "claude settings hook registration (#137 / #199 / #225)"

# 8a) Committed personal: enableGitHubIsolatedReader, enableQualityLoopHooks
#     AND enableHerdrIntegration are ON, so the managed settings.json registers
#     EXACTLY four events:
#     PreToolUse / matcher Bash / one command hook -> personal-safe-gh-hook
#     (#137); PostToolUse / matcher Edit|Write / one command hook ->
#     personal-fast-edit-check and a matcher-less Stop / one command hook ->
#     personal-changed-scope-qa (#199; Stop takes no matcher in Claude Code);
#     SessionStart / matcher "^(startup|resume|clear|compact|fork)$" / one command hook in
#     the exact shape herdr's installer emits — `bash
#     '<home>/.claude/hooks/herdr-agent-state.sh' session`, timeout 10 (#225;
#     since herdr 0.9.3 / integration v10 the installer compares the WHOLE
#     entry with its canonical one and replaces a legacy "*" entry, so any
#     deviation — the matcher included — makes `herdr integration install
#     claude` rewrite the managed registration; #274).
#     Every agent-tools body is the agent-tools-deployed absolute path
#     (agent-tools#146 stable-path contract). Pinned as an exact set (event
#     set, matcher, hook count, type, full command path, timeouts), not just
#     "a hooks key exists": this is security / gate wiring, so a swapped
#     matcher or an extra registered event must fail the test (#129 lesson).
expected_hook_cmd="$HOME/.claude/agent-tools/scripts/personal-safe-gh-hook"
expected_edit_cmd="$HOME/.claude/agent-tools/scripts/personal-fast-edit-check"
expected_stop_cmd="$HOME/.claude/agent-tools/scripts/personal-changed-scope-qa"
expected_session_cmd="bash '$HOME/.claude/hooks/herdr-agent-state.sh' session"
hook_events="$(yq -p json -o json '.hooks | keys | sort' "$off_file" | tr -d ' \n')"
pre_len="$(yq -p json '.hooks.PreToolUse | length' "$off_file")"
pre_matcher="$(yq -p json '.hooks.PreToolUse[0].matcher' "$off_file")"
inner_len="$(yq -p json '.hooks.PreToolUse[0].hooks | length' "$off_file")"
inner_type="$(yq -p json '.hooks.PreToolUse[0].hooks[0].type' "$off_file")"
inner_cmd="$(yq -p json '.hooks.PreToolUse[0].hooks[0].command' "$off_file")"
if [[ "$hook_events" == '["PostToolUse","PreToolUse","SessionStart","Stop"]' && "$pre_len" == "1" && "$pre_matcher" == "Bash" \
  && "$inner_len" == "1" && "$inner_type" == "command" \
  && "$inner_cmd" == "$expected_hook_cmd" ]]; then
  ok "test passed: committed personal registers exactly {PreToolUse, PostToolUse, Stop, SessionStart}, with one PreToolUse/Bash command hook -> personal-safe-gh-hook (absolute path)"
else
  fail "test failed: hook registration wrong (events=$hook_events pre_len=$pre_len matcher=$pre_matcher inner_len=$inner_len type=$inner_type cmd=$inner_cmd)"
  status=1
fi
post_len="$(yq -p json '.hooks.PostToolUse | length' "$off_file")"
post_matcher="$(yq -p json '.hooks.PostToolUse[0].matcher' "$off_file")"
post_inner_len="$(yq -p json '.hooks.PostToolUse[0].hooks | length' "$off_file")"
post_type="$(yq -p json '.hooks.PostToolUse[0].hooks[0].type' "$off_file")"
post_cmd="$(yq -p json '.hooks.PostToolUse[0].hooks[0].command' "$off_file")"
post_timeout="$(yq -p json '.hooks.PostToolUse[0].hooks[0].timeout // "absent"' "$off_file")"
stop_len="$(yq -p json '.hooks.Stop | length' "$off_file")"
stop_matcher="$(yq -p json '.hooks.Stop[0].matcher // "absent"' "$off_file")"
stop_inner_len="$(yq -p json '.hooks.Stop[0].hooks | length' "$off_file")"
stop_type="$(yq -p json '.hooks.Stop[0].hooks[0].type' "$off_file")"
stop_cmd="$(yq -p json '.hooks.Stop[0].hooks[0].command' "$off_file")"
stop_timeout="$(yq -p json '.hooks.Stop[0].hooks[0].timeout // "absent"' "$off_file")"
if [[ "$post_len" == "1" && "$post_matcher" == "Edit|Write" && "$post_inner_len" == "1" \
  && "$post_type" == "command" && "$post_cmd" == "$expected_edit_cmd" && "$post_timeout" == "absent" \
  && "$stop_len" == "1" && "$stop_matcher" == "absent" && "$stop_inner_len" == "1" \
  && "$stop_type" == "command" && "$stop_cmd" == "$expected_stop_cmd" && "$stop_timeout" == "absent" ]]; then
  ok "test passed: committed personal registers one PostToolUse/Edit|Write hook -> personal-fast-edit-check and one matcher-less Stop hook -> personal-changed-scope-qa (absolute paths, no timeout)"
else
  fail "test failed: quality-loop hook registration wrong (post_len=$post_len matcher=$post_matcher inner=$post_inner_len type=$post_type cmd=$post_cmd timeout=$post_timeout | stop_len=$stop_len matcher=$stop_matcher inner=$stop_inner_len type=$stop_type cmd=$stop_cmd timeout=$stop_timeout)"
  status=1
fi
session_len="$(yq -p json '.hooks.SessionStart | length' "$off_file")"
session_matcher="$(yq -p json '.hooks.SessionStart[0].matcher // "absent"' "$off_file")"
session_inner_len="$(yq -p json '.hooks.SessionStart[0].hooks | length' "$off_file")"
session_type="$(yq -p json '.hooks.SessionStart[0].hooks[0].type' "$off_file")"
session_cmd="$(yq -p json '.hooks.SessionStart[0].hooks[0].command' "$off_file")"
session_timeout="$(yq -p json '.hooks.SessionStart[0].hooks[0].timeout // "absent"' "$off_file")"
if [[ "$session_len" == "1" && "$session_matcher" == "^(startup|resume|clear|compact|fork)$" && "$session_inner_len" == "1" \
  && "$session_type" == "command" && "$session_cmd" == "$expected_session_cmd" && "$session_timeout" == "10" ]]; then
  ok "test passed: committed personal registers one SessionStart hook in herdr 0.9.3's installer shape (matcher ^(startup|resume|clear|compact|fork)$, bash '<home>/.claude/hooks/herdr-agent-state.sh' session, timeout 10)"
else
  fail "test failed: herdr SessionStart registration wrong (len=$session_len matcher=$session_matcher inner=$session_inner_len type=$session_type cmd=$session_cmd timeout=$session_timeout)"
  status=1
fi

# 8b) Bootstrap order is safe: the throwaway render home has NO agent-tools
#     scripts, yet the apply succeeded and rendered the registration. The
#     registration is declarative — it must not depend on the body being
#     deployed. At runtime a missing body is fail-open (exit 127 is a
#     non-blocking hook error; only exit 2 blocks — Claude Code hook
#     semantics, verified 2026-06-25), and doctor reports the absent body.
off_home="$(dirname "$(dirname "$off_file")")"
if [[ ! -e "$off_home/.claude/agent-tools/scripts/personal-safe-gh-hook" \
  && ! -e "$off_home/.claude/agent-tools/scripts/personal-fast-edit-check" \
  && ! -e "$off_home/.claude/agent-tools/scripts/personal-changed-scope-qa" \
  && ! -e "$off_home/.claude/hooks/herdr-agent-state.sh" ]]; then
  ok "test passed: registration renders without any hook body present (agent-tools sync / herdr integration install can come later; runtime is fail-open)"
else
  fail "test failed: throwaway render home unexpectedly contains a hook body (fixture assumption broken)"
  status=1
fi

# 8c) Each capability adds EXACTLY its own events and nothing else: deleting
#     that capability's events from the both-on render must equal the render
#     with only that capability flipped false (normalized JSON compare, so a
#     gate that leaked any other key/content — or dropped the other
#     capability's events — would fail; the same exact-set spirit as the deny
#     test, without a fixture that drifts). All three false -> no hooks key at
#     all (an empty "hooks": {} must never be emitted), and the all-off render
#     is the all-on render minus the whole hooks key.
# render_hook_flip LABEL CAP...
# Flip every CAP to false in a throwaway source copy, render personal, and
# set hook_flip_file to the rendered settings.json. Called as a plain
# statement and returning through a variable ON PURPOSE: inside $(...) the
# function would run in a subshell and its tmp_roots+= registrations would
# never reach the parent's EXIT trap, leaking every source/render root (the
# #150 lesson in test-lib.sh; Codex review on PR #200).
render_hook_flip() {
  local label="$1" src root cap
  shift
  src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings-$label.XXXXXX")"
  tmp_roots+=("$src")
  make_flipped_source "$src"
  for cap in "$@"; do
    flip_personal_capability "$src/src" "$cap" false
  done
  root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings.XXXXXX")"
  tmp_roots+=("$root")
  if ! render_personal_into "$src/src" "$root"; then
    fail "test failed: personal apply ($label) did not render"
    exit 1
  fi
  hook_flip_file="$root/home/.claude/settings.json"
}
render_hook_flip reader-off enableGitHubIsolatedReader
reader_off_file="$hook_flip_file"
render_hook_flip quality-off enableQualityLoopHooks
quality_off_file="$hook_flip_file"
render_hook_flip herdr-off enableHerdrIntegration
herdr_off_file="$hook_flip_file"
render_hook_flip hooks-off enableGitHubIsolatedReader enableQualityLoopHooks enableHerdrIntegration
both_off_file="$hook_flip_file"
on_minus_reader="$(yq -p json -o json 'del(.hooks.PreToolUse)' "$off_file")"
reader_off_norm="$(yq -p json -o json '.' "$reader_off_file")"
if [[ "$(yq -p json -o json '.hooks | keys | sort' "$reader_off_file" | tr -d ' \n')" == '["PostToolUse","SessionStart","Stop"]' ]] \
  && [[ -n "$reader_off_norm" && "$on_minus_reader" == "$reader_off_norm" ]]; then
  ok "test passed: enableGitHubIsolatedReader=false keeps exactly {PostToolUse, Stop, SessionStart} and differs from the on-render by exactly the PreToolUse event"
else
  fail "test failed: enableGitHubIsolatedReader=false render is not the on-render minus PreToolUse (gate leaked another change, dropped the quality pair, or invalid JSON)"
  status=1
fi
on_minus_quality="$(yq -p json -o json 'del(.hooks.PostToolUse) | del(.hooks.Stop)' "$off_file")"
quality_off_norm="$(yq -p json -o json '.' "$quality_off_file")"
if [[ "$(yq -p json -o json '.hooks | keys | sort' "$quality_off_file" | tr -d ' \n')" == '["PreToolUse","SessionStart"]' ]] \
  && [[ -n "$quality_off_norm" && "$on_minus_quality" == "$quality_off_norm" ]]; then
  ok "test passed: enableQualityLoopHooks=false keeps exactly {PreToolUse, SessionStart} and differs from the on-render by exactly the PostToolUse + Stop events"
else
  fail "test failed: enableQualityLoopHooks=false render is not the on-render minus PostToolUse/Stop (gate leaked another change, dropped the safe-gh hook, or invalid JSON)"
  status=1
fi
on_minus_herdr="$(yq -p json -o json 'del(.hooks.SessionStart)' "$off_file")"
herdr_off_norm="$(yq -p json -o json '.' "$herdr_off_file")"
if [[ "$(yq -p json -o json '.hooks | keys | sort' "$herdr_off_file" | tr -d ' \n')" == '["PostToolUse","PreToolUse","Stop"]' ]] \
  && [[ -n "$herdr_off_norm" && "$on_minus_herdr" == "$herdr_off_norm" ]]; then
  ok "test passed: enableHerdrIntegration=false keeps exactly {PreToolUse, PostToolUse, Stop} and differs from the on-render by exactly the SessionStart event"
else
  fail "test failed: enableHerdrIntegration=false render is not the on-render minus SessionStart (gate leaked another change, dropped another hook, or invalid JSON)"
  status=1
fi
on_minus_hooks="$(yq -p json -o json 'del(.hooks)' "$off_file")"
both_off_norm="$(yq -p json -o json '.' "$both_off_file")"
if [[ "$(yq -p json '.hooks // "absent"' "$both_off_file")" == "absent" ]] \
  && [[ -n "$both_off_norm" && "$on_minus_hooks" == "$both_off_norm" ]]; then
  ok "test passed: all three hook capabilities false emits no hooks key (no empty object) and differs from the on-render by exactly the hooks key"
else
  fail "test failed: all-off render is not the on-render minus the hooks key (gate leaked another change, emitted an empty hooks object, or invalid JSON)"
  status=1
fi

# 8d) Single-capability renders (the other two flipped false): each must be
#     valid JSON with exactly its own events and equal the on-render minus
#     the other capabilities' events. herdr-only is the path where
#     SessionStart is the FIRST event emitted (empty separator), which no
#     other combination exercises (Codex review, PR #226).
render_hook_flip reader-only enableQualityLoopHooks enableHerdrIntegration
reader_only_file="$hook_flip_file"
render_hook_flip quality-only enableGitHubIsolatedReader enableHerdrIntegration
quality_only_file="$hook_flip_file"
render_hook_flip herdr-only enableGitHubIsolatedReader enableQualityLoopHooks
herdr_only_file="$hook_flip_file"
# check_hook_single_on LABEL FILE EXPECTED_EVENTS DEL_FILTER
check_hook_single_on() {
  local label="$1" file="$2" expected_events="$3" del_filter="$4" events norm on_minus
  events="$(yq -p json -o json '.hooks | keys | sort' "$file" 2>/dev/null | tr -d ' \n')"
  norm="$(yq -p json -o json '.' "$file" 2>/dev/null)"
  on_minus="$(yq -p json -o json "$del_filter" "$off_file")"
  if [[ "$events" == "$expected_events" && -n "$norm" && "$on_minus" == "$norm" ]]; then
    ok "test passed: $label keeps exactly $expected_events and differs from the on-render by exactly the other capabilities' events"
  else
    fail "test failed: $label render is not the on-render minus the other capabilities' events (events=$events; gate leaked, dropped its own event, or invalid JSON)"
    status=1
  fi
}
check_hook_single_on "only enableGitHubIsolatedReader" "$reader_only_file" '["PreToolUse"]' 'del(.hooks.PostToolUse) | del(.hooks.Stop) | del(.hooks.SessionStart)'
check_hook_single_on "only enableQualityLoopHooks" "$quality_only_file" '["PostToolUse","Stop"]' 'del(.hooks.PreToolUse) | del(.hooks.SessionStart)'
check_hook_single_on "only enableHerdrIntegration" "$herdr_only_file" '["SessionStart"]' 'del(.hooks.PreToolUse) | del(.hooks.PostToolUse) | del(.hooks.Stop)'

if [[ "$status" -eq 0 ]]; then
  ok "claude settings tests passed"
fi
exit "$status"
