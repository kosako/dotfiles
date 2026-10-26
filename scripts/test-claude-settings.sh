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
# session, timeout 10); enableToolCallRecordHook (ON for personal, #353) ->
# the record hook on SessionStart and PreToolUse / PostToolUse /
# PostToolUseFailure / PermissionDenied (Claude only); each capability adds
# exactly its own events, and all four false -> no hooks key at all.
# Renders into throwaway destinations; never touches the real home directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

require_yq || exit 1

# jq runs inside the managed settings.json modify script whenever a live
# file exists (#360), and section 9 builds its live files with it.
if ! command -v jq >/dev/null 2>&1; then
  fail "jq not found; the settings.json modify script and section 9 need it"
  exit 1
fi

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

# render_flip LABEL CAP=VALUE...
# Set every CAP to VALUE for the personal profile (flip_personal_capability,
# which fails closed on an undeclared CAP) in a throwaway source copy, render
# personal, and set flip_file to the rendered settings.json and flip_src to
# the flipped source (9e applies it again with apply_over). Called as a plain
# statement and returning through variables ON PURPOSE: inside $(...) the
# function would run in a subshell and its tmp_roots+= registrations would
# never reach the parent's EXIT trap, leaking every source/render root (the
# #150 lesson in test-lib.sh; Codex review on PR #200).
render_flip() {
  local label="$1" src root arg
  shift
  src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings-$label.XXXXXX")"
  tmp_roots+=("$src")
  make_flipped_source "$src"
  for arg in "$@"; do
    if [[ "$arg" != *=* ]]; then
      fail "test failed: render_flip ($label) takes CAP=VALUE, got '$arg'"
      exit 1
    fi
    flip_personal_capability "$src/src" "${arg%%=*}" "${arg#*=}"
  done
  root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings.XXXXXX")"
  tmp_roots+=("$root")
  if ! render_personal_into "$src/src" "$root"; then
    fail "test failed: personal apply ($label) did not render"
    exit 1
  fi
  flip_src="$src/src"
  flip_file="$root/home/.claude/settings.json"
}

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
if ! yq -p json -o yaml '.' "$off_file" >/dev/null 2>&1; then
  fail "test failed: default settings.json is not valid JSON"
  status=1
elif [[ "$(yq -p json -o yaml '.sandbox // "absent"' "$off_file")" == "absent" ]]; then
  ok "test passed: default (enforceAiSandbox=false) emits no sandbox block"
else
  fail "test failed: default settings.json unexpectedly contains a sandbox block"
  status=1
fi

# 2) enforceAiSandbox=true (personal only) -> strict, public-safe sandbox
#    block. Flip the capability in a throwaway source copy so the committed
#    default stays false.
render_flip sandbox-on enforceAiSandbox=true
on_file="$flip_file"
if ! yq -p json -o yaml '.' "$on_file" >/dev/null 2>&1; then
  fail "test failed: enabled settings.json is not valid JSON"
  status=1
else
  enabled="$(yq -p json -o yaml '.sandbox.enabled' "$on_file")"
  fail_if="$(yq -p json -o yaml '.sandbox.failIfUnavailable' "$on_file")"
  unsandboxed="$(yq -p json -o yaml '.sandbox.allowUnsandboxedCommands' "$on_file")"
  domains_len="$(yq -p json -o yaml '.sandbox.network.allowedDomains | length' "$on_file")"
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
skip_warn="$(yq -p json -o yaml '.skipWorkflowUsageWarning // "absent"' "$off_file")"
tui_mode="$(yq -p json -o yaml '.tui // "absent"' "$off_file")"
# `//` would read false as absent, so presence is asked separately.
switch_models="$(yq -p json -o yaml 'select(has("switchModelsOnFlag")) | .switchModelsOnFlag' "$off_file")"
if [[ "$skip_warn" == "true" && "$tui_mode" == "fullscreen" && "$switch_models" == "false" ]]; then
  ok "test passed: managed template carries skipWorkflowUsageWarning=true, tui=fullscreen and switchModelsOnFlag=false"
else
  fail "test failed: managed global prefs missing (skipWorkflowUsageWarning=$skip_warn tui=$tui_mode switchModelsOnFlag=$switch_models)"
  status=1
fi

# 3b) Third-party plugin marketplaces (#317): every extraKnownMarketplaces entry
#     pins its source to a ref (a tag — Claude Code's marketplace source takes
#     no commit sha, and a default-branch name would not pin anything) and sets
#     autoUpdate false explicitly (the settings value wins over the /plugin
#     toggle), so a plugin changes only through a PR that moves the ref
#     (docs/update-policy.md).
mkt_count="$(yq -p json -o yaml '.extraKnownMarketplaces // {} | length' "$off_file")"
mkt_unpinned="$(yq -p json -o yaml '.extraKnownMarketplaces // {} | to_entries | .[] | select((.value.source.ref // "") == "" or (.value.source.ref // "" | test("^(main|master|HEAD)$")) or .value.autoUpdate != false) | .key' "$off_file")"
if [[ "$mkt_count" -ge 1 && -z "$mkt_unpinned" ]]; then
  ok "test passed: every third-party plugin marketplace ($mkt_count) pins source.ref and sets autoUpdate=false"
else
  fail "test failed: plugin marketplace not pinned or auto-updating (count=$mkt_count): ${mkt_unpinned:-<none declared>}"
  status=1
fi

# 3c) statusLine (#305 / #333): the managed status line runs the catalog's
#     tacho from <home>/go/bin — the path doctor and install-packages.sh take
#     as the managed argv[0] and the usage reader shares — as a command-type
#     status line with no padding. Pinned per key against the home chezmoi
#     rendered for (render_personal_into leaves HOME to chezmoi, as 8a's hook
#     pins do; shell_word keeps a home with a space or quote comparable, #329;
#     -o json -r because the YAML printer would quote a command that starts
#     with a quote). test-render.sh pins the command's shell splitting for
#     homes with special characters and the plain-home string.
status_type="$(yq -p json -o yaml '.statusLine.type // "absent"' "$off_file")"
status_cmd="$(yq -p json -o json -r '.statusLine.command // "absent"' "$off_file")"
status_pad="$(yq -p json -o yaml '.statusLine.padding // "absent"' "$off_file")"
if [[ "$status_type" == "command" && "$status_cmd" == "$(shell_word "$HOME/go/bin/tacho") statusline" && "$status_pad" == "0" ]]; then
  ok "test passed: statusLine is a command-type status line running <home>/go/bin/tacho statusline with padding 0"
else
  fail "test failed: statusLine unexpected (type=$status_type command=$status_cmd padding=$status_pad)"
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
#    by #334's asks for reading the config files that may hold secrets (4)
#    and the git asks of #304 / #334 (71): the work-discarding git forms,
#    each option as a word of its own after its subcommand, and the hook
#    skips in any other position. Beside the two lists, permissions holds
#    only allow, and allow is exactly mcp__pencil (an added "Bash(*)" would
#    approve every Bash command neither list catches); that pin does not
#    depend on the key order under permissions (9c reorders it).
#    We pin the EXACT ordered
#    arrays, not length + a few representatives: this is a security-boundary
#    regression test, so it must catch a floor matcher being swapped for
#    another (which would keep the length). What the rules decide for real
#    commands is pinned separately (4c).
expected_git_deny=$'Bash(git commit --no-verify *)\nBash(git push --no-verify *)\nBash(git commit -n *)\nEdit(//**/.agent-context.local.md)'
expected_git_ask=$'Bash(git clean *)\nBash(git * clean *)\nBash(git restore *)\nBash(git * restore *)\nBash(git *checkout* -- *)\nBash(git *checkout* .)\nBash(git *push* +*)\nBash(git *push* :**)\nBash(git *reset* --hard)\nBash(git *reset* --hard *)\nBash(git *checkout* --force)\nBash(git *checkout* --force *)\nBash(git *checkout* -f)\nBash(git *checkout* -f *)\nBash(git *checkout* -qf)\nBash(git *checkout* -qf *)\nBash(git *checkout* -fq)\nBash(git *checkout* -fq *)\nBash(git *switch* --force)\nBash(git *switch* --force *)\nBash(git *switch* --discard-changes)\nBash(git *switch* --discard-changes *)\nBash(git *switch* -f)\nBash(git *switch* -f *)\nBash(git *switch* -qf)\nBash(git *switch* -qf *)\nBash(git *switch* -fq)\nBash(git *switch* -fq *)\nBash(git *push* --force)\nBash(git *push* --force *)\nBash(git *push* -f)\nBash(git *push* -f *)\nBash(git *push* -uf)\nBash(git *push* -uf *)\nBash(git *push* -fu)\nBash(git *push* -fu *)\nBash(git *branch* -D)\nBash(git *branch* -D *)\nBash(git *branch* --force)\nBash(git *branch* --force *)\nBash(git *branch* -f)\nBash(git *branch* -f *)\nBash(git *branch* -df)\nBash(git *branch* -df *)\nBash(git *branch* -fd)\nBash(git *branch* -fd *)\nBash(git *commit* -n)\nBash(git *commit* -n *)\nBash(git *commit* -nm)\nBash(git *commit* -nm *)\nBash(git *commit* -an)\nBash(git *commit* -an *)\nBash(git *commit* -anm)\nBash(git *commit* -anm *)\nBash(git *push* --mirror)\nBash(git *push* --mirror *)\nBash(git *push* --delete)\nBash(git *push* --delete *)\nBash(git *push* -d)\nBash(git *push* -d *)\nBash(git *branch* -M)\nBash(git *branch* -M *)\nBash(git *stash* drop)\nBash(git *stash* drop *)\nBash(git *stash* clear)\nBash(git *stash* clear *)\nBash(git *worktree remove* --force)\nBash(git *worktree remove* --force *)\nBash(git *worktree remove* -f)\nBash(git *worktree remove* -f *)\nBash(git *--no-verify*)'
expected_unused_mcp=$'mcp__claude_ai_Gmail\nmcp__claude_ai_Google_Calendar\nmcp__claude_ai_Google_Drive\nmcp__claude_ai_Claude_Docs'
for notion_tool in notion-create-comment notion-create-attachment notion-create-database notion-create-view notion-update-view notion-update-data-source notion-create-folder notion-update-folder notion-restore-pages notion-convert-page-to-skill notion-upload-skill notion-spawn-session notion-send-message-to-session notion-stop-session notion-move-pages notion-duplicate-page notion-create-file-upload; do
  expected_unused_mcp+=$'\nmcp__plugin_Notion_notion__'"$notion_tool"
done
expected_deny=$'Read(~/.ssh/**)\nRead(~/.aws/**)\nRead(~/.config/gh/**)\nRead(~/.netrc)\nRead(~/.codex/auth.json)\nRead(~/.local/share/opencode/auth.json)\nBash(cat ~/.ssh/*)\nBash(gh secret *)\nBash(gh api *secrets*)\nBash(env)\nBash(env *)\nBash(printenv)\nBash(printenv *)\nBash(gh auth token)\nBash(gh auth token *)\nBash(gh auth status *--show-token*)\nBash(gh auth status -t*)\nBash(gh auth status * -t*)\nBash(gh auth status -at*)\nBash(gh auth status * -at*)\nBash(gh -* auth *)\nBash(gh auth -*)\nBash(security find-generic-password *)\nBash(security * find-generic-password *)\nBash(security find-internet-password *)\nBash(security * find-internet-password *)\nBash(security dump-keychain*)\nBash(security * dump-keychain*)\nBash(security export *)\nBash(security * export *)\n'"$expected_git_deny"$'\nmcp__github\n'"$expected_unused_mcp"
actual_deny="$(yq -p json -o yaml '.permissions.deny[]' "$off_file")"
expected_ask=$'Bash(op *)\nRead(~/.codex/config.toml)\nRead(~/.zshrc.local)\nRead(~/.zprofile.local)\nRead(~/.config/opencode/opencode.local.json)\n'"$expected_git_ask"
ask_default="$(yq -p json -o yaml '.permissions.ask[]' "$off_file" 2>/dev/null || true)"
rest_default="$(yq -p json -o json -I0 '.permissions | del(.deny, .ask)' "$off_file" 2>/dev/null || true)"
if [[ "$actual_deny" == "$expected_deny" && "$ask_default" == "$expected_ask" && "$rest_default" == '{"allow":["mcp__pencil"]}' ]]; then
  ok "test passed: committed personal deny is exactly the secret floor + #304 hook-skip / note deny + github MCP + #341's unused MCP (56, ordered); ask is exactly the whole 1Password CLI, #334's reads of secret-bearing config files, and the work-discarding git and hook skips of #304 / #334 (76, ordered); allow is exactly mcp__pencil and permissions holds nothing else (enforceAiSandbox off)"
else
  fail "test failed: committed personal permissions unexpected (allow and the rest=$rest_default ask=$ask_default); deny was:"
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
#     deny is checked before ask. A body ending in `:*` is the legacy prefix
#     form instead (the command is the prefix or starts with it plus a
#     space, runs of spaces / tabs in both read as one space), where a `*`
#     inside the prefix stays literal — read from Claude Code 2.1.293 (#334),
#     and the reason a rule may not mix the two (4e).
#     This pins the rule TEXT against that reading; it does not prove the
#     harness — the matchers stay steering.
# claude_rule_regex BODY — sets claude_rule_re to the anchored regex of a
# wildcard Bash rule body (inside Bash(...)). A body with a regex-special
# character other than `*`, `.` and `+` returns 2 instead of being guessed at.
claude_rule_regex() {
  local body="$1" re="" i c
  for ((i = 0; i < ${#body}; i++)); do
    c="${body:i:1}"
    case "$c" in
      '*') re+='.*' ;;
      '.' | '+') re+="\\$c" ;;
      '[' | ']' | '(' | ')' | '{' | '}' | '|' | '^' | '$' | '?' | '\') return 2 ;;
      *) re+="$c" ;;
    esac
  done
  claude_rule_re="^${re}\$"
}
# claude_rule_matches BODY CMD — whether a Bash rule body matches CMD
# (2 when claude_rule_regex cannot read it).
claude_rule_matches() {
  local body="$1" cmd="$2" prefix
  if [[ "$body" =~ $claude_legacy_re ]]; then
    prefix="${BASH_REMATCH[1]//$'\t'/ }"
    while [[ "$prefix" == *"  "* ]]; do prefix="${prefix//  / }"; done
    cmd="${cmd//$'\t'/ }"
    while [[ "$cmd" == *"  "* ]]; do cmd="${cmd//  / }"; done
    [[ "$cmd" == "$prefix" || "$cmd" == "$prefix "* ]]
    return
  fi
  if [[ "$body" == *" *" && "${body%" *"}" != *"*"* && "$cmd" == "${body%" *"}" ]]; then
    return 0
  fi
  claude_rule_regex "$body" || return 2
  [[ "$cmd" =~ $claude_rule_re ]]
}
# The committed deny then ask Bash rules, read once: the kind, the body and
# its regex (empty for a legacy `:*` body, which claude_rule_matches reads;
# "unsupported" when claude_rule_regex cannot read it — reported only when a
# command reaches the rule, as before).
claude_legacy_re='^(.+):\*$'
claude_bash_kinds=()
claude_bash_bodies=()
claude_bash_res=()
for kind in deny ask; do
  while IFS= read -r rule; do
    [[ "$rule" == 'Bash('*')' ]] || continue
    rule="${rule#Bash(}"
    rule="${rule%)}"
    claude_rule_re=""
    if ! [[ "$rule" =~ $claude_legacy_re ]]; then
      claude_rule_regex "$rule" || claude_rule_re=unsupported
    fi
    claude_bash_kinds+=("$kind")
    claude_bash_bodies+=("$rule")
    claude_bash_res+=("$claude_rule_re")
  done < <(yq -p json -o yaml ".permissions.${kind}[]" "$off_file")
done
# claude_decision CMD — deny / ask / none for CMD under the committed rules.
claude_decision() {
  local i body re
  for ((i = 0; i < ${#claude_bash_bodies[@]}; i++)); do
    body="${claude_bash_bodies[i]}"
    re="${claude_bash_res[i]}"
    if [[ -z "$re" ]]; then
      claude_rule_matches "$body" "$1" || continue
    elif [[ "$body" == *" *" && "${body%" *"}" != *"*"* && "$1" == "${body%" *"}" ]]; then
      :
    elif [[ "$re" == unsupported ]]; then
      printf 'unsupported:%s\n' "$body"
      return 0
    elif ! [[ "$1" =~ $re ]]; then
      continue
    fi
    printf '%s\n' "${claude_bash_kinds[i]}"
    return 0
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
# The committed deny then ask Read rules, read once (kind and body).
claude_read_kinds=()
claude_read_bodies=()
for kind in deny ask; do
  while IFS= read -r rule; do
    [[ "$rule" == 'Read('*')' ]] || continue
    body="${rule#Read(}"
    claude_read_kinds+=("$kind")
    claude_read_bodies+=("${body%)}")
  done < <(yq -p json -o yaml ".permissions.${kind}[]" "$off_file")
done
# claude_read_decision PATH -> deny / ask / none under the committed Read rules.
claude_read_decision() {
  local i body base
  for ((i = 0; i < ${#claude_read_bodies[@]}; i++)); do
    body="${claude_read_bodies[i]}"
    # Only `~/<path>` and `~/<path>/**` (no other wildcard) are evaluated.
    if [[ "$body" != \~/* || "${body%/\*\*}" == *"*"* ]]; then
      printf 'unsupported:%s\n' "$body"
      return 0
    fi
    base="$claude_read_home/${body#\~/}"
    if [[ "$body" == *"/**" ]]; then
      base="${base%/\*\*}"
      [[ "$1" == "$base"/* ]] && { printf '%s\n' "${claude_read_kinds[i]}"; return 0; }
    elif [[ "$1" == "$base" ]]; then
      printf '%s\n' "${claude_read_kinds[i]}"
      return 0
    fi
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
ask|$claude_read_home/.zprofile.local
ask|$claude_read_home/.config/opencode/opencode.local.json
none|$claude_read_home/.codex/config.toml.bak
none|$claude_read_home/.zshrc
none|$claude_read_home/.config/opencode/opencode.json
none|$claude_read_home/src/repo/.zshrc.local
none|$claude_read_home/.zprofile
none|$claude_read_home/src/repo/.zprofile.local
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

# 4e) No Bash rule mixes `*` with the trailing `:*` (#334): Claude Code reads
#     such a body as the legacy prefix form with the `*` kept literal, so the
#     rule never matches a real command (`git *push* :*` was one, PR #338).
#     Both renders, every list.
dead_rules=""
legacy_tab=$'\t'
for rendered in "$off_file" "$on_file"; do
  while IFS= read -r rule; do
    [[ "$rule" == 'Bash('*':*)' ]] || continue
    body="${rule#Bash(}"
    body="${body%:\*)}"
    [[ "$body" == *'*'* ]] && dead_rules+="  $rule"$'\n'
  done < <(yq -p json -o yaml '(.permissions.deny // []) + (.permissions.ask // []) + (.permissions.allow // []) | .[]' "$rendered")
done
if [[ -z "$dead_rules" ]]; then
  ok "test passed: no Bash rule mixes * with the trailing :* (Claude Code would keep that * literal and never match)"
else
  fail "test failed: Bash rules that mix * with the trailing :* never match in Claude Code:"
  printf '%s' "$dead_rules" >&2
  status=1
fi
# The emulator's own legacy-prefix reading (no committed rule uses the form,
# so the decision cases above cannot pin it; Codex review R1, PR #339).
legacy_misses=""
while IFS='|' read -r want body cmd; do
  [[ -n "$want" ]] || continue
  got=no
  claude_rule_matches "$body" "$cmd" && got=yes
  [[ "$got" == "$want" ]] || legacy_misses+="  Bash($body) vs '$cmd' -> $got (expected $want)"$'\n'
done <<CASES
yes|git push:*|git push
yes|git push:*|git push origin main
yes|git push:*|git  push origin main
yes|gh${legacy_tab}pr merge:*|gh pr merge 12
yes|gh  pr merge:*|gh pr${legacy_tab}merge
no|git push:*|git pushx
no|git push:*|git -C x push
no|git *push* :*|git push origin :feat
no|git *push* :*|git push
CASES
if [[ -z "$legacy_misses" ]]; then
  ok "test passed: the emulator reads the legacy :* prefix the way Claude Code does (prefix or prefix + space, whitespace runs as one, * literal)"
else
  fail "test failed: the emulator's legacy :* prefix reading drifted:"
  printf '%s' "$legacy_misses" >&2
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
actual_deny_on="$(yq -p json -o yaml '.permissions.deny[]' "$on_file")"
actual_ask_on="$(yq -p json -o yaml '.permissions.ask[]' "$on_file" 2>/dev/null || true)"
actual_rest_on="$(yq -p json -o json -I0 '.permissions | del(.deny, .ask)' "$on_file" 2>/dev/null || true)"
if [[ "$actual_deny_on" == "$expected_deny_on" && "$actual_ask_on" == "$expected_ask_on" && "$actual_rest_on" == '{"allow":["mcp__pencil"]}' ]]; then
  ok "test passed: enforceAiSandbox=true is exactly the secret floor + github MCP + human-legit gate (main/master push, .env read) as deny, and the whole 1Password CLI + release/protection as ask (ordered), and allow is exactly mcp__pencil"
else
  fail "test failed: enforceAiSandbox=true permissions unexpected; deny / ask / allow and the rest were:"
  printf '%s\n' "$actual_deny_on" "---" "$actual_ask_on" "---" "$actual_rest_on" >&2
  status=1
fi
# merge/PR/comment/label must NOT be statically gated in Phase 1 (left to the hook).
if grep -Fq 'gh pr merge' "$on_file" || grep -Fq 'gh pr create' "$on_file" || grep -Fq 'gh label create' "$on_file"; then
  fail "test failed: context-gated writes are statically gated (should be deferred to the Phase 2 hook)"
  status=1
else
  ok "test passed: context-gated writes (merge/PR/comment/label) are not statically gated"
fi

# 6) gateGitHubMcp=false: the gate adds exactly the github MCP deny, so the
#    render is the committed one (gateGitHubMcp is ON for personal; 4 pins
#    mcp__github in place) minus that one entry, still valid JSON. The true
#    direction is the committed render itself (4 / 5 / 6c); flipping true was
#    a no-op (#332).
#    Validity is checked first in its own branch: a command substitution in
#    a plain assignment would abort the suite under set -e on invalid JSON,
#    and yq prints the first document before failing on trailing garbage, so
#    a `|| true` would let the comparison pass on it.
render_flip mcp-off gateGitHubMcp=false
mcp_file="$flip_file"
if ! yq -p json -o yaml '.' "$mcp_file" >/dev/null 2>&1; then
  fail "test failed: gateGitHubMcp=false settings.json is not valid JSON"
  status=1
elif [[ "$(yq -p json -o json '.' "$mcp_file")" == "$(yq -p json -o json 'del(.permissions.deny[] | select(. == "mcp__github"))' "$off_file")" ]] \
  && ! grep -Fq 'mcp__github' "$mcp_file"; then
  ok "test passed: gateGitHubMcp=false drops the github MCP deny and nothing else (valid JSON)"
else
  fail "test failed: gateGitHubMcp=false render is not the committed render minus the github MCP deny (mcp__github still denied or another change leaked)"
  status=1
fi

# 6b) gateGitHubMcp=false with enforceAiSandbox=true: the two capabilities
#     touch separate entries, so this render is exactly the sum of the two
#     separate differences: the enforceAiSandbox=true render (on_file, pinned
#     by 5) minus the github MCP deny (6). Compared as the whole JSON, so an
#     entry dropped or added only in this combination is caught too.
#     Validity is checked first in its own branch, for the reason given in 6.
render_flip mcp-off-sandbox-on gateGitHubMcp=false enforceAiSandbox=true
both_file="$flip_file"
if ! yq -p json -o yaml '.' "$both_file" >/dev/null 2>&1; then
  fail "test failed: gate off + sandbox on settings.json is not valid JSON"
  status=1
elif [[ "$(yq -p json -o json '.' "$both_file")" == "$(yq -p json -o json 'del(.permissions.deny[] | select(. == "mcp__github"))' "$on_file")" ]] \
  && ! grep -Fq 'mcp__github' "$both_file"; then
  ok "test passed: gate off + sandbox on is exactly the enforceAiSandbox=true render minus the github MCP deny (valid JSON, write gate kept)"
else
  fail "test failed: gate off + sandbox on is not the enforceAiSandbox=true render minus the github MCP deny (MCP deny kept, write gate lost, or another change leaked)"
  status=1
fi

# 6c) gateUnusedClaudeMcp=false (#341): the render is the committed one (4)
#     minus its 21 denies and nothing else, compared as the whole JSON (an
#     unrelated entry lost with the flip is caught too); validity first, as
#     in 6. The daily Notion writes are never denied either way.
render_flip unused-mcp-off gateUnusedClaudeMcp=false
unused_file="$flip_file"
if ! yq -p json -o yaml '.' "$unused_file" >/dev/null 2>&1; then
  fail "test failed: gateUnusedClaudeMcp=false settings.json is not valid JSON"
  status=1
elif [[ "$(yq -p json -o json '.' "$unused_file")" == "$(yq -p json -o json 'del(.permissions.deny[] | select(test("^mcp__(claude_ai_|plugin_Notion_notion__)")))' "$off_file")" ]] \
  && ! grep -Fq 'mcp__claude_ai_' "$unused_file" \
  && ! grep -Fq 'mcp__plugin_Notion_notion__' "$unused_file"; then
  ok "test passed: gateUnusedClaudeMcp=false drops its 21 denies and nothing else (valid JSON, github MCP deny kept)"
else
  fail "test failed: gateUnusedClaudeMcp=false render is not the committed render minus its 21 denies (one still renders or another change leaked)"
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

section "claude settings hook registration (#137 / #199 / #225 / #353)"

# 8a) Committed personal: enableGitHubIsolatedReader, enableQualityLoopHooks,
#     enableHerdrIntegration AND enableToolCallRecordHook are ON, so the
#     managed settings.json registers EXACTLY six events:
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
#     #353 (agent-tools#454) appends personal-tool-call-record-hook as the
#     SECOND entry of PreToolUse / PostToolUse (matcher "*") and SessionStart
#     (no matcher), and adds PostToolUseFailure / PermissionDenied (matcher
#     "*") — every record entry "async": true, timeout 10 — so the three
#     pre-existing entries stay at index 0, byte-identical (8e pins that).
#     Every agent-tools body is the agent-tools-deployed absolute path
#     (agent-tools#146 stable-path contract). Pinned as the WHOLE hooks
#     object (key-sorted; entry order kept), not just "a hooks key exists":
#     this is security / gate wiring, so a swapped matcher, an extra event or
#     entry, or a key added to an entry (an "async" on safe-gh would take its
#     steer out of the pre-call path; a "timeout" on it is Codex-only) must
#     fail the test (#129 lesson).
expected_hook_cmd="$(shell_word "$HOME/.claude/agent-tools/scripts/personal-safe-gh-hook")"
expected_edit_cmd="$(shell_word "$HOME/.claude/agent-tools/scripts/personal-fast-edit-check")"
expected_stop_cmd="$(shell_word "$HOME/.claude/agent-tools/scripts/personal-changed-scope-qa")"
expected_session_cmd="bash $(shell_single_quote "$HOME/.claude/hooks/herdr-agent-state.sh") session"
expected_record_cmd="$(shell_word "$HOME/.claude/agent-tools/scripts/personal-tool-call-record-hook")"
expected_hooks="$(jq -n -S --arg gh "$expected_hook_cmd" --arg edit "$expected_edit_cmd" \
  --arg stop "$expected_stop_cmd" --arg session "$expected_session_cmd" \
  --arg record "$expected_record_cmd" '
  def hook($cmd): {type: "command", command: $cmd};
  def record: {hooks: [hook($record) + {async: true, timeout: 10}]};
  {
    PreToolUse: [{matcher: "Bash", hooks: [hook($gh)]}, record + {matcher: "*"}],
    PostToolUse: [{matcher: "Edit|Write", hooks: [hook($edit)]}, record + {matcher: "*"}],
    Stop: [{hooks: [hook($stop)]}],
    SessionStart: [{matcher: "^(startup|resume|clear|compact|fork)$",
      hooks: [hook($session) + {timeout: 10}]}, record],
    PostToolUseFailure: [record + {matcher: "*"}],
    PermissionDenied: [record + {matcher: "*"}]
  }')"
actual_hooks="$(jq -S '.hooks' "$off_file" 2>/dev/null)" || actual_hooks=""
if [[ -n "$actual_hooks" && "$actual_hooks" == "$expected_hooks" ]]; then
  ok "test passed: committed personal registers exactly the pinned hooks object (six events; safe-gh / fast-edit-check / scope-qa / herdr first, the record hook second or alone, async + timeout 10; absolute paths; no other key)"
else
  fail "test failed: hook registration differs from the pinned hooks object (diff on stderr: expected, then rendered)"
  diff <(printf '%s\n' "$expected_hooks") <(printf '%s\n' "$actual_hooks") >&2 || true
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
  && ! -e "$off_home/.claude/agent-tools/scripts/personal-tool-call-record-hook" \
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
#     test, without a fixture that drifts). Since #353 three events hold two
#     entries, so "that capability's events" means its ENTRIES: the first
#     element of PreToolUse / PostToolUse / SessionStart belongs to the
#     pre-existing capability and the second to the record hook. All four
#     false -> no hooks key at all (an empty "hooks": {} must never be
#     emitted), and the all-off render is the all-on render minus the whole
#     hooks key.
render_flip reader-off enableGitHubIsolatedReader=false
reader_off_file="$flip_file"
render_flip quality-off enableQualityLoopHooks=false
quality_off_file="$flip_file"
render_flip herdr-off enableHerdrIntegration=false
herdr_off_file="$flip_file"
render_flip record-off enableToolCallRecordHook=false
record_off_file="$flip_file"
render_flip hooks-off enableGitHubIsolatedReader=false enableQualityLoopHooks=false \
  enableHerdrIntegration=false enableToolCallRecordHook=false
both_off_file="$flip_file"
hooks_off_src="$flip_src"
# check_hook_flip_off LABEL FILE EXPECTED_EVENTS DEL_FILTER
# The flipped-off render must keep exactly EXPECTED_EVENTS and equal the
# on-render with DEL_FILTER applied (that capability's entries removed).
check_hook_flip_off() {
  local label="$1" file="$2" expected_events="$3" del_filter="$4" events norm on_minus
  events="$(yq -p json -o json '.hooks | keys | sort' "$file" 2>/dev/null | tr -d ' \n')"
  norm="$(yq -p json -o json '.' "$file" 2>/dev/null)"
  on_minus="$(yq -p json -o json "$del_filter" "$off_file")"
  if [[ "$events" == "$expected_events" && -n "$norm" && "$on_minus" == "$norm" ]]; then
    ok "test passed: $label keeps exactly $expected_events and differs from the on-render by exactly its own entries"
  else
    fail "test failed: $label render is not the on-render minus its own entries (events=$events; gate leaked another change, dropped another capability's entry, or invalid JSON)"
    status=1
  fi
}
check_hook_flip_off "enableGitHubIsolatedReader=false" "$reader_off_file" \
  '["PermissionDenied","PostToolUse","PostToolUseFailure","PreToolUse","SessionStart","Stop"]' \
  'del(.hooks.PreToolUse[0])'
check_hook_flip_off "enableQualityLoopHooks=false" "$quality_off_file" \
  '["PermissionDenied","PostToolUse","PostToolUseFailure","PreToolUse","SessionStart"]' \
  'del(.hooks.PostToolUse[0]) | del(.hooks.Stop)'
check_hook_flip_off "enableHerdrIntegration=false" "$herdr_off_file" \
  '["PermissionDenied","PostToolUse","PostToolUseFailure","PreToolUse","SessionStart","Stop"]' \
  'del(.hooks.SessionStart[0])'
check_hook_flip_off "enableToolCallRecordHook=false" "$record_off_file" \
  '["PostToolUse","PreToolUse","SessionStart","Stop"]' \
  'del(.hooks.PreToolUse[1]) | del(.hooks.PostToolUse[1]) | del(.hooks.SessionStart[1]) | del(.hooks.PostToolUseFailure) | del(.hooks.PermissionDenied)'
on_minus_hooks="$(yq -p json -o json 'del(.hooks)' "$off_file")"
both_off_norm="$(yq -p json -o json '.' "$both_off_file")"
if [[ "$(yq -p json -o yaml '.hooks // "absent"' "$both_off_file")" == "absent" ]] \
  && [[ -n "$both_off_norm" && "$on_minus_hooks" == "$both_off_norm" ]]; then
  ok "test passed: all four hook capabilities false emits no hooks key (no empty object) and differs from the on-render by exactly the hooks key"
else
  fail "test failed: all-off render is not the on-render minus the hooks key (gate leaked another change, emitted an empty hooks object, or invalid JSON)"
  status=1
fi

# 8d) Single-capability renders (the other three flipped false): each must be
#     valid JSON with exactly its own events and equal the on-render minus
#     the other capabilities' entries. herdr-only is the path where
#     SessionStart is the FIRST event emitted (empty separator), which no
#     other combination exercises (Codex review, PR #226); record-only is
#     the path where every record entry is the FIRST (and only) element of
#     its event and PostToolUseFailure / PermissionDenied are preceded by a
#     separator from SessionStart (#353).
render_flip reader-only enableQualityLoopHooks=false enableHerdrIntegration=false enableToolCallRecordHook=false
reader_only_file="$flip_file"
render_flip quality-only enableGitHubIsolatedReader=false enableHerdrIntegration=false enableToolCallRecordHook=false
quality_only_file="$flip_file"
render_flip herdr-only enableGitHubIsolatedReader=false enableQualityLoopHooks=false enableToolCallRecordHook=false
herdr_only_file="$flip_file"
render_flip record-only enableGitHubIsolatedReader=false enableQualityLoopHooks=false enableHerdrIntegration=false
record_only_file="$flip_file"
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
check_hook_single_on "only enableGitHubIsolatedReader" "$reader_only_file" '["PreToolUse"]' 'del(.hooks.PreToolUse[1]) | del(.hooks.PostToolUse) | del(.hooks.Stop) | del(.hooks.SessionStart) | del(.hooks.PostToolUseFailure) | del(.hooks.PermissionDenied)'
check_hook_single_on "only enableQualityLoopHooks" "$quality_only_file" '["PostToolUse","Stop"]' 'del(.hooks.PreToolUse) | del(.hooks.PostToolUse[1]) | del(.hooks.SessionStart) | del(.hooks.PostToolUseFailure) | del(.hooks.PermissionDenied)'
check_hook_single_on "only enableHerdrIntegration" "$herdr_only_file" '["SessionStart"]' 'del(.hooks.PreToolUse) | del(.hooks.PostToolUse) | del(.hooks.Stop) | del(.hooks.SessionStart[1]) | del(.hooks.PostToolUseFailure) | del(.hooks.PermissionDenied)'
check_hook_single_on "only enableToolCallRecordHook" "$record_only_file" '["PermissionDenied","PostToolUse","PostToolUseFailure","PreToolUse","SessionStart"]' 'del(.hooks.PreToolUse[0]) | del(.hooks.PostToolUse[0]) | del(.hooks.Stop) | del(.hooks.SessionStart[0])'

# 8e) #353 must not disturb the pre-existing registrations: with the record
#     hook flipped false, the rendered file is BYTE-identical to what the
#     template produced before #353 for the same three capabilities — i.e.
#     the record-off render and the on-render agree on every byte outside
#     the record entries. Pinned by comparing the record-off render with the
#     on-render after the record entries are deleted (normalized), plus the
#     exact pins above; the one-time byte diff against the pre-#353 render
#     was done at the #353 PR.
if [[ "$(yq -p json -o yaml '.hooks.PreToolUse | length' "$record_off_file")" == "1" \
  && "$(yq -p json -o yaml '.hooks.PostToolUse | length' "$record_off_file")" == "1" \
  && "$(yq -p json -o yaml '.hooks.SessionStart | length' "$record_off_file")" == "1" ]]; then
  ok "test passed: enableToolCallRecordHook=false leaves one entry in PreToolUse / PostToolUse / SessionStart (the pre-#353 shape)"
else
  fail "test failed: enableToolCallRecordHook=false render still carries a second entry in PreToolUse / PostToolUse / SessionStart"
  status=1
fi

section "claude settings keep the keys the template does not manage (#360)"

# 9) ~/.claude/settings.json is a chezmoi modify script: with no live file it
#    prints the managed JSON (sections 1-8), with one it changes only what the
#    template manages. Each case applies onto a home whose settings.json is
#    already there. The live files are printed by jq, the formatter the script
#    re-prints with, so "unchanged" can be checked byte for byte.
# apply_over LABEL SOURCE SEED — apply SOURCE (personal) onto a fresh home
# whose ~/.claude/settings.json is SEED; sets over_root, over_file and over_rc
# (the apply's exit status). Called as a plain statement for the same
# tmp_roots reason as render_flip.
apply_over() {
  local label="$1" source_dir="$2" seed="$3"
  over_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings-$label.XXXXXX")"
  tmp_roots+=("$over_root")
  mkdir -p "$over_root/home/.claude"
  over_file="$over_root/home/.claude/settings.json"
  printf '%s\n' "$seed" > "$over_file"
  cp "$over_file" "$over_root/seed.json"
  over_rc=0
  render_personal_into "$source_dir" "$over_root" || over_rc=$?
}
# norm FILE [FILTER] — FILE as key-sorted one-line JSON after FILTER.
norm() {
  yq -p json -o json -I0 "${2:-.} | sort_keys(..)" "$1" 2>/dev/null
}

# 9a) A live file with the hand-kept keys, a /model choice, stale managed
#     values and a stale sandbox block (enforceAiSandbox is false here): the
#     hand-kept keys and the model stay as they were and where they were
#     (autoMode first), the managed keys come back to the render, the sandbox
#     block goes.
local_seed="$(jq '{autoMode: {environment: ["Trusted repo: example/example"]}} + .
  | .model = "sonnet"
  | .modelSettings = {"claude-sonnet-x": {effortLevel: "high"}}
  | .futureKey = {nested: [1, 2]}
  | .switchModelsOnFlag = true
  | .tui = "default"
  | .permissions.deny |= .[1:]
  | .sandbox = {enabled: false}' "$off_file")"
apply_over local "$DOTFILES_ROOT" "$local_seed"
local_file="$over_file"
local_root="$over_root"
kept="$(yq -p json -o json -I0 '[.autoMode, .modelSettings, .futureKey, .model]' "$local_file" 2>/dev/null)"
want_kept="$(printf '%s\n' "$local_seed" | yq -p json -o json -I0 '[.autoMode, .modelSettings, .futureKey, .model]')"
if [[ "$over_rc" -eq 0 && -n "$kept" && "$kept" == "$want_kept" \
  && "$(yq -p json -o yaml 'keys | .[0]' "$local_file")" == "autoMode" ]]; then
  ok "test passed: apply keeps autoMode, modelSettings, an unknown key and the /model choice, in place"
else
  fail "test failed: apply over a live file lost or moved a key the template does not manage (rc=$over_rc kept=$kept)"
  status=1
fi
if [[ -n "$(norm "$off_file")" \
  && "$(norm "$local_file" 'del(.autoMode, .modelSettings, .futureKey, .model)')" == "$(norm "$off_file" 'del(.model)')" ]]; then
  ok "test passed: every managed key comes back to the render (stale deny, switchModelsOnFlag and tui restored; the stale sandbox block removed)"
else
  fail "test failed: apply over a live file left a managed key different from the render"
  status=1
fi

# 9b) Right after 9a's apply, chezmoi diff is empty: it runs the modify
#     script over the merged file as a second apply would, so a second apply
#     would change no byte.
local_diff="$(chezmoi --config "$local_root/chezmoi.toml" --source "$DOTFILES_ROOT" \
  --destination "$local_root/home" diff 2>/dev/null)" || local_diff="<chezmoi diff failed>"
if [[ -z "$local_diff" ]]; then
  ok "test passed: after an apply over a live file chezmoi diff is empty (a second apply would change no byte)"
else
  fail "test failed: after an apply over a live file chezmoi diff is not empty (a second apply would change the file)"
  status=1
fi

# 9c) A managed value equal to the render up to object key order (as a hand
#     edit or Claude Code may leave it) keeps its live bytes: no diff for a
#     reordering alone.
reordered_seed="$(jq '.permissions = ({allow: .permissions.allow} + .permissions)
  | .hooks.PreToolUse[0].hooks[0] |= ({command: .command} + .)' "$off_file")"
apply_over reordered "$DOTFILES_ROOT" "$reordered_seed"
if [[ "$over_rc" -eq 0 ]] && [[ "$(cat "$over_file")" == "$reordered_seed" ]] \
  && [[ "$(yq -p json -o yaml '.permissions | keys | .[0]' "$over_file")" == "allow" ]] \
  && [[ "$(yq -p json -o yaml '.hooks.PreToolUse[0].hooks[0] | keys | .[0]' "$over_file")" == "command" ]]; then
  ok "test passed: a managed value equal up to key order keeps its live bytes"
else
  fail "test failed: a reordering alone rewrote the live file (rc=$over_rc)"
  status=1
fi

# 9d) No model in the live file: the template's model is the default.
no_model_seed="$(jq 'del(.model) | .autoMode = {environment: ["x"]}' "$off_file")"
apply_over no-model "$DOTFILES_ROOT" "$no_model_seed"
if [[ "$over_rc" -eq 0 && "$(yq -p json -o yaml '.model' "$over_file")" == "$(yq -p json -o yaml '.model' "$off_file")" \
  && "$(yq -p json -o json -I0 '.autoMode' "$over_file")" == '{"environment":["x"]}' ]]; then
  ok "test passed: a live file without model gets the template's model as the default"
else
  fail "test failed: model was not defaulted for a live file without one (rc=$over_rc)"
  status=1
fi

# 9e) All four hook capabilities false: the live hooks key goes (it would
#     otherwise keep a hook the capabilities turned off), the rest equals the
#     all-off render plus the hand-kept key. The source is 8c's hooks-off
#     copy (a render leaves its source as it was).
apply_over hooks-off "$hooks_off_src" "$(jq '.autoMode = {environment: ["x"]}' "$off_file")"
if [[ "$over_rc" -eq 0 && "$(yq -p json -o yaml '.hooks // "absent"' "$over_file")" == "absent" \
  && -n "$(norm "$both_off_file")" \
  && "$(norm "$over_file" 'del(.autoMode)')" == "$(norm "$both_off_file")" ]]; then
  ok "test passed: with the hook capabilities off, apply removes the live hooks key and keeps the hand-kept key"
else
  fail "test failed: apply kept a hooks key the capabilities turned off, or changed another key (rc=$over_rc)"
  status=1
fi

# 9f) The keys the script removes when the template does not emit them are
#     exactly the keys a capability adds: the all-on render (sandbox + hooks)
#     minus the all-off render. A new capability-gated top-level key must be
#     added to the script's list as well.
gated_keys="$(yq -p json -o json -I0 '[keys[]]' "$on_file" 2>/dev/null)"
off_keys="$(yq -p json -o json -I0 '[keys[]]' "$both_off_file" 2>/dev/null)"
gated_diff="$(GATED="$gated_keys" OFF="$off_keys" yq -n -o json -I0 '(env(GATED) - env(OFF)) | sort')"
if [[ -n "$gated_keys" && -n "$off_keys" && "$gated_diff" == '["hooks","sandbox"]' ]]; then
  ok "test passed: the capability-gated top-level keys are exactly hooks and sandbox (the modify script's removal list)"
else
  fail "test failed: capability-gated top-level keys are $gated_diff, not [hooks, sandbox]; update the modify script's removal list"
  status=1
fi

# 9g) A live file that is not exactly one JSON object stops the apply and is
#     left byte for byte as it was, rather than being replaced: an array,
#     broken JSON, whitespace only (jq would run no filter and print
#     nothing), two objects, and a lone newline (not 0 bytes, so not the
#     no-file case) (Codex review R1, PR #377).
for bad_seed in '[]' '{"model": ' '   ' '{} {}' ''; do
  apply_over bad "$DOTFILES_ROOT" "$bad_seed"
  if [[ "$over_rc" -ne 0 ]] && cmp -s "$over_root/seed.json" "$over_file"; then
    ok "test passed: a live file of '$bad_seed' (plus a newline) stops the apply and stays byte-identical"
  else
    fail "test failed: a live file of '$bad_seed' (plus a newline) was changed or the apply did not fail (rc=$over_rc)"
    status=1
  fi
done
# A NUL byte (never in JSON) stops the apply as well, both alone (dropped,
# it would leave 0 bytes: the no-file case) and after the render (dropped,
# the rest is the render), also as the last byte, which jq reading the file
# itself lets pass: the script keeps the live file in a shell variable,
# which cannot hold NUL, so it must not drop the byte (#446). The seeds are
# written directly, as a bash variable cannot carry NUL either.
nul_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings-nul.XXXXXX")"
tmp_roots+=("$nul_root")
mkdir -p "$nul_root/home/.claude"
nul_file="$nul_root/home/.claude/settings.json"
for nul_case in 'NUL only' 'the render then NUL' 'the render then a last NUL'; do
  if [[ "$nul_case" == 'NUL only' ]]; then
    printf '\000\000' > "$nul_file"
  elif [[ "$nul_case" == 'the render then NUL' ]]; then
    { cat "$off_file"; printf '\000\n'; } > "$nul_file"
  else
    { cat "$off_file"; printf '\000'; } > "$nul_file"
  fi
  cp "$nul_file" "$nul_root/seed.json"
  nul_rc=0
  render_personal_into "$DOTFILES_ROOT" "$nul_root" || nul_rc=$?
  if [[ "$nul_rc" -ne 0 ]] && cmp -s "$nul_root/seed.json" "$nul_file"; then
    ok "test passed: a live file of $nul_case stops the apply and stays byte-identical"
  else
    fail "test failed: a live file of $nul_case was changed or the apply did not fail (rc=$nul_rc)"
    status=1
  fi
done
# A byte that is not UTF-8 inside a JSON string does not stop the apply: jq
# reads it, and a file that is otherwise the render comes back byte for
# byte. The apply runs in a UTF-8 locale, where BSD tr would stop on that
# byte without the script's LC_ALL=C (#446); GNU tr reads bytes either way.
{ printf '{"probe": "\377\201",'; tail -c +2 "$off_file"; } > "$nul_file"
cp "$nul_file" "$nul_root/seed.json"
u8_rc=0
LC_ALL=C.UTF-8 chezmoi --config "$nul_root/chezmoi.toml" --source "$DOTFILES_ROOT" \
  --destination "$nul_root/home" apply >/dev/null 2>&1 || u8_rc=$?
if [[ "$u8_rc" -eq 0 ]] && cmp -s "$nul_root/seed.json" "$nul_file"; then
  ok "test passed: a live file with a byte that is not UTF-8 in a string applies in a UTF-8 locale and stays byte-identical"
else
  fail "test failed: a live file with a byte that is not UTF-8 in a string was changed or did not apply in a UTF-8 locale (rc=$u8_rc)"
  status=1
fi

# 9h) Section 1's off_root is a first apply on a home without the file
#     (nothing writes there afterwards): the managed JSON as the template
#     prints it (one-line deny / ask arrays). chezmoi diff over it is empty:
#     an unchanged file comes back as it was, not re-printed, so a second
#     apply would change no byte (Codex review R1, PR #377).
first_diff="$(chezmoi --config "$off_root/chezmoi.toml" --source "$DOTFILES_ROOT" \
  --destination "$off_root/home" diff 2>/dev/null)" || first_diff="<chezmoi diff failed>"
if [[ -z "$first_diff" ]]; then
  ok "test passed: right after a first apply chezmoi diff is empty (a second apply would change no byte)"
else
  fail "test failed: right after a first apply chezmoi diff is not empty (a second apply would re-print the file)"
  status=1
fi

# 9i) The script makes no temp file of its own for the live file (#446).
#     With TMPDIR at a directory that does not exist, chezmoi diff
#     over the 9a seed prints what it prints with a working TMPDIR, apply
#     writes what 9a wrote, and chezmoi status is empty afterwards (chezmoi
#     itself writes the script to a temp file before running it, so its
#     scriptTempDir is a directory that exists). Shims first on PATH for
#     those three runs log that mktemp never runs (BSD mktemp falls back to
#     another directory when TMPDIR is missing) and that jq reads the live
#     file from a pipe (bash as /bin/sh keeps a here-document in a temp
#     file). A write to a fixed path is not looked for.
notmp_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings-notmp.XXXXXX")"
tmp_roots+=("$notmp_root")
mkdir -p "$notmp_root/home/.claude" "$notmp_root/script-tmp" "$notmp_root/bin"
cat > "$notmp_root/bin/mktemp" <<'MKTEMP_SHIM'
#!/bin/sh
printf 'mktemp ran\n' >> "$SHIM_LOG"
exec "$MKTEMP_REAL" "$@"
MKTEMP_SHIM
cat > "$notmp_root/bin/jq" <<'JQ_SHIM'
#!/bin/sh
if [ -p /dev/stdin ]; then
  printf 'jq read a pipe\n' >> "$SHIM_LOG"
else
  printf 'jq read no pipe\n' >> "$SHIM_LOG"
fi
exec "$JQ_REAL" "$@"
JQ_SHIM
chmod +x "$notmp_root/bin/mktemp" "$notmp_root/bin/jq"
notmp_log="$notmp_root/shim.log"
: > "$notmp_log"
notmp_env=(TMPDIR="$notmp_root/missing" SHIM_LOG="$notmp_log" JQ_REAL="$(command -v jq)"
  MKTEMP_REAL="$(command -v mktemp)" PATH="$notmp_root/bin:$PATH")
jq -n --arg dir "$notmp_root/script-tmp" '{scriptTempDir: $dir, data: {profile: "personal"}}' \
  > "$notmp_root/chezmoi.json"
notmp_file="$notmp_root/home/.claude/settings.json"
printf '%s\n' "$local_seed" > "$notmp_file"
notmp_rc=0
notmp_want_diff="$(chezmoi --config "$notmp_root/chezmoi.json" --source "$DOTFILES_ROOT" \
  --destination "$notmp_root/home" diff "$notmp_file" 2>/dev/null)" || notmp_rc=1
notmp_diff="$(env "${notmp_env[@]}" chezmoi --config "$notmp_root/chezmoi.json" \
  --source "$DOTFILES_ROOT" --destination "$notmp_root/home" diff "$notmp_file" 2>/dev/null)" || notmp_rc=1
env "${notmp_env[@]}" chezmoi --config "$notmp_root/chezmoi.json" --source "$DOTFILES_ROOT" \
  --destination "$notmp_root/home" apply >/dev/null 2>&1 || notmp_rc=1
notmp_status="$(env "${notmp_env[@]}" chezmoi --config "$notmp_root/chezmoi.json" \
  --source "$DOTFILES_ROOT" --destination "$notmp_root/home" status 2>/dev/null)" || notmp_rc=1
if [[ "$notmp_rc" -eq 0 && -n "$notmp_want_diff" && "$notmp_diff" == "$notmp_want_diff" \
  && -z "$notmp_status" && ! -e "$notmp_root/missing" ]] && cmp -s "$local_file" "$notmp_file"; then
  ok "test passed: with TMPDIR at a missing directory, chezmoi diff, apply and status over a live file work as with a working one"
else
  fail "test failed: with TMPDIR at a missing directory, chezmoi diff, apply or status over a live file failed or differed (rc=$notmp_rc status=$notmp_status)"
  status=1
fi
if grep -Fqx 'jq read a pipe' "$notmp_log" && ! grep -Fvqx 'jq read a pipe' "$notmp_log"; then
  ok "test passed: no mktemp ran and jq read the live file from a pipe (diff, apply and status)"
else
  fail "test failed: mktemp ran, jq read the live file from no pipe, or jq did not run: $(sort "$notmp_log" | uniq -c | tr -s ' \n' ' ')"
  status=1
fi

# 9j) No live value reaches jq's arguments (#446): a jq shim first on PATH
#     logs every argument it gets and runs the real jq. A value that only
#     the live file's autoMode holds is kept by apply and never shows in the
#     log, while the log shows that jq ran with the managed JSON: chezmoi diff
#     over a live file with a stale managed key, the apply that merges it,
#     and chezmoi diff over the merged file (the unchanged case).
argv_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-claude-settings-argv.XXXXXX")"
tmp_roots+=("$argv_root")
mkdir -p "$argv_root/bin" "$argv_root/home/.claude"
cat > "$argv_root/bin/jq" <<'JQ_SHIM'
#!/bin/sh
printf '%s\n' "$@" >> "$JQ_ARGV_LOG"
exec "$JQ_REAL" "$@"
JQ_SHIM
chmod +x "$argv_root/bin/jq"
printf '[data]\nprofile = "personal"\n' > "$argv_root/chezmoi.toml"
argv_marker="dotfiles-argv-probe-$$-$RANDOM"
argv_file="$argv_root/home/.claude/settings.json"
jq --arg marker "$argv_marker" '{autoMode: {environment: [$marker]}} + . | .tui = "default"' \
  "$off_file" > "$argv_file"
argv_log="$argv_root/jq-argv.log"
: > "$argv_log"
argv_real_jq="$(command -v jq)"
argv_rc=0
for argv_step in diff apply diff; do
  JQ_ARGV_LOG="$argv_log" JQ_REAL="$argv_real_jq" PATH="$argv_root/bin:$PATH" \
    chezmoi --config "$argv_root/chezmoi.toml" --source "$DOTFILES_ROOT" \
    --destination "$argv_root/home" "$argv_step" >/dev/null 2>&1 || argv_rc=1
done
if [[ "$argv_rc" -eq 0 ]] && grep -Fqx -- '--argjson' "$argv_log" \
  && grep -Fq '"permissions"' "$argv_log" && ! grep -Fq -- "$argv_marker" "$argv_log" \
  && [[ "$(yq -p json -o yaml '.autoMode.environment[0]' "$argv_file")" == "$argv_marker" \
    && "$(yq -p json -o yaml '.tui' "$argv_file")" == "$(yq -p json -o yaml '.tui' "$off_file")" ]]; then
  ok "test passed: a value only the live file holds never reaches jq's arguments (diff, apply and diff again)"
else
  fail "test failed: a live-only value reached jq's arguments, the jq shim did not run, or the apply failed (rc=$argv_rc)"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "claude settings tests passed"
fi
exit "$status"
