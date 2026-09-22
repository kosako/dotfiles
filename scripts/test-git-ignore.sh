#!/usr/bin/env bash
set -euo pipefail

# Behaviour and gating tests for the git-ignore module (#248): the managed
# global gitignore at git's DEFAULT excludes location (~/.config/git/ignore).
# It must (1) be applied for personal and not for work, (2) carry the
# managed-by header (the doctor orphan scan keys on it) and exactly the agent
# local-only patterns, (3) survive enableGitSigning=false (the #207 allowlist
# derives the ~/.config/git ancestor from every active module, not from
# git-signing alone), and (4) actually make git hide .agent-packets/ and
# .claude/settings.local.json in a repository that has NO .gitignore of its
# own — the acceptance criterion of #248 — while ordinary files and
# .agent-context.local.md (per-repo .gitignore by design) stay visible.
# Renders into throwaway destinations and runs git against a throwaway HOME
# with `env -i`; never touches the real home or global git config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

require_yq || exit 1

for tool in chezmoi git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    fail "$tool not found; git-ignore tests require it"
    exit 1
  fi
done

status=0
tmp_roots=()

cleanup() {
  local dir
  for dir in "${tmp_roots[@]:-}"; do
    [[ -n "$dir" ]] && rm -rf "$dir"
  done
}
trap cleanup EXIT

# render_profile_into SOURCE_DIR ROOT PROFILE — like render_personal_into
# (test-lib.sh) but for any profile; the caller mktemps ROOT and registers
# it in tmp_roots (caller-creates-root contract, see the #150 note there).
render_profile_into() {
  local source_dir="$1" root="$2" profile="$3"
  mkdir -p "$root/home"
  printf '[data]\nprofile = "%s"\n' "$profile" > "$root/chezmoi.toml"
  chezmoi --config "$root/chezmoi.toml" \
    --source "$source_dir" --destination "$root/home" apply >/dev/null 2>&1
}

managed_rel=".config/git/ignore"
expected_patterns=$'.agent-packets/\n**/.claude/settings.local.json'

section "git-ignore: managed set per profile"

# 1) personal applies the file; work does not (module not listed).
personal_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-ignore-personal.XXXXXX")"
tmp_roots+=("$personal_root")
if ! render_profile_into "$DOTFILES_ROOT" "$personal_root" personal; then
  fail "test failed: personal apply did not render"
  exit 1
fi
personal_home="$personal_root/home"
managed="$personal_home/$managed_rel"
if [[ -f "$managed" ]]; then
  ok "test passed: personal applies $managed_rel"
else
  fail "test failed: personal did not apply $managed_rel"
  exit 1
fi

work_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-ignore-work.XXXXXX")"
tmp_roots+=("$work_root")
if ! render_profile_into "$DOTFILES_ROOT" "$work_root" work; then
  fail "test failed: work apply did not render"
  exit 1
fi
if [[ -e "$work_root/home/$managed_rel" ]]; then
  fail "test failed: work applied $managed_rel although it does not list git-ignore"
  status=1
else
  ok "test passed: work does not apply $managed_rel (module not listed)"
fi

section "git-ignore: managed content"

# 2) Header on line 1 (orphan scan), and the pattern set pinned EXACTLY:
#    every non-comment, non-blank line is one of the two agent local-only
#    patterns and both are present. A pattern added later must be added
#    here and in doctor's list on purpose.
if head -n 1 "$managed" | grep -Fq "Managed by chezmoi"; then
  ok "test passed: line 1 carries the managed-by header"
else
  fail "test failed: line 1 must carry the managed-by header (doctor orphan scan)"
  status=1
fi
patterns="$(grep -v '^#' "$managed" | grep -v '^[[:space:]]*$' || true)"
if [[ "$patterns" == "$expected_patterns" ]]; then
  ok "test passed: pattern lines are exactly .agent-packets/ and **/.claude/settings.local.json"
else
  printf 'expected:\n%s\nactual:\n%s\n' "$expected_patterns" "$patterns" >&2
  fail "test failed: pattern set drifted from the pinned two lines"
  status=1
fi
if grep -Fxq -- ".agent-context.local.md" "$managed"; then
  fail "test failed: .agent-context.local.md must stay a per-repo .gitignore concern (#248 acceptance)"
  status=1
else
  ok "test passed: .agent-context.local.md is not globally ignored (per-repo .gitignore unchanged)"
fi

# 3) enableGitSigning=false must not drop the file: ~/.config/git is an
#    ancestor derived from EVERY active module's paths (#207), so the
#    git-signing gate no longer takes the subtree with it.
nosign_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-ignore-nosign-src.XXXXXX")"
tmp_roots+=("$nosign_src")
make_flipped_source "$nosign_src"
flip_personal_capability "$nosign_src/src" enableGitSigning false
nosign_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-ignore-nosign.XXXXXX")"
tmp_roots+=("$nosign_root")
if ! render_profile_into "$nosign_src/src" "$nosign_root" personal; then
  fail "test failed: personal apply (enableGitSigning=false) did not render"
  exit 1
fi
if [[ -f "$nosign_root/home/$managed_rel" && ! -e "$nosign_root/home/.config/git/signing.gitconfig" ]]; then
  ok "test passed: enableGitSigning=false keeps $managed_rel (ancestor is not owned by git-signing)"
else
  fail "test failed: enableGitSigning=false must keep $managed_rel while dropping signing.gitconfig"
  status=1
fi

section "git-ignore: git behaviour (repository without its own .gitignore)"

# 4) Every git call — the init included — runs hermetically: `env -i`
#    drops XDG_CONFIG_HOME and any GIT_* of the developer shell,
#    GIT_CONFIG_NOSYSTEM keeps a system gitconfig out, and the init uses an
#    EMPTY template directory so a host init.templateDir cannot seed
#    .git/info/exclude (Codex review). The repo has no .gitignore at all. A
#    control run against an EMPTY home must list every file, so the
#    assertion cannot pass vacuously.
repo="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-ignore-repo.XXXXXX")"
tmp_roots+=("$repo")
empty_home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-ignore-empty-home.XXXXXX")"
tmp_roots+=("$empty_home")
empty_template="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-ignore-template.XXXXXX")"
tmp_roots+=("$empty_template")

# git_in HOME_DIR ARGS... — git in the fixture repo with HOME_DIR as git's
# home and nothing else from the environment.
git_in() {
  local home_dir="$1"
  shift
  env -i HOME="$home_dir" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 git -C "$repo" "$@"
}

git_in "$empty_home" init -q --template="$empty_template"
mkdir -p "$repo/.agent-packets" "$repo/.claude" "$repo/pkg/sub/.claude"
printf 'private packet\n' > "$repo/.agent-packets/123.md"
printf '{}\n' > "$repo/.claude/settings.local.json"
printf '{}\n' > "$repo/pkg/sub/.claude/settings.local.json"
printf 'context\n' > "$repo/.agent-context.local.md"
printf 'keep\n' > "$repo/keep.md"

# git_status HOME_DIR — untracked listing under HOME_DIR as git's home.
git_status() {
  git_in "$1" status --porcelain --untracked-files=all
}

expected_visible=$'?? .agent-context.local.md\n?? keep.md'
expected_control=$'?? .agent-context.local.md\n?? .agent-packets/123.md\n?? .claude/settings.local.json\n?? keep.md\n?? pkg/sub/.claude/settings.local.json'

if control="$(git_status "$empty_home")" && [[ "$control" == "$expected_control" ]]; then
  ok "test passed: control (empty home) lists all five files, including the agent local-only ones"
else
  printf '%s\n' "${control:-<no output>}" >&2
  fail "test failed: control run must list every file (the assertion below would otherwise be vacuous)"
  status=1
fi

if visible="$(git_status "$personal_home")" && [[ "$visible" == "$expected_visible" ]]; then
  ok "test passed: with the managed global gitignore, .agent-packets/ and .claude/settings.local.json (any depth) are hidden; keep.md and .agent-context.local.md stay visible"
else
  printf '%s\n' "${visible:-<no output>}" >&2
  fail "test failed: git status under the rendered home must hide exactly the two agent local-only patterns"
  status=1
fi

# The decision must come from the managed file itself (check-ignore -v names
# the source), not from anything else in the rendered home.
if src_line="$(git_in "$personal_home" check-ignore -v --no-index -- .agent-packets/123.md pkg/sub/.claude/settings.local.json)" \
  && [[ "$(grep -c -F "$managed:" <<< "$src_line")" == "2" ]]; then
  ok "test passed: git check-ignore attributes both decisions to $managed_rel"
else
  printf '%s\n' "${src_line:-<no output>}" >&2
  fail "test failed: check-ignore must attribute the decisions to the managed global gitignore"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "git-ignore tests passed"
fi
exit "$status"
