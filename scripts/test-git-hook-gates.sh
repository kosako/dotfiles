#!/usr/bin/env bash
set -euo pipefail

# Content + behavior tests for the commit-boundary git hook gates wiring
# (#196). test-render.sh fixes the managed *set* per profile; this fixes the
# *content* and *arming semantics* the enableGitHookGates capability drives,
# and proves the wiring actually routes `git commit` through the shims (the
# #121 lesson: text equality alone missed a real ssh Include-scope bug, so
# drive the rendered artifacts for real).
#
# The wiring is a TWO-KEY gate (Codex review must-1 on PR #197): the
# capability is the INTENT, and a COMPLETE agent-tools deploy in the
# destination (dispatcher + both gates; .chezmoitemplates/git-hook-gates-armed)
# is the READINESS. The dispatcher is fail-closed (exit 2) when a gate next to
# it is missing, so:
#   - bare destination (fresh machine): apply must succeed and must NOT render
#     any wiring — bootstrap-safe by NOT arming, never by arming a brick.
#   - partial deploy (dispatcher only): must NOT arm either (must-2: arming on
#     the dispatcher alone would still block every commit).
#   - full deploy: shims + hooks.gitconfig render with exact pinned bytes, and
#     end to end a commit runs BOTH stages, a failing dispatcher blocks the
#     commit, and --no-verify bypasses it (documented best-effort limit).
#   - enableGitHookGates=false: already-applied wiring is REMOVED on the next
#     apply (template self-gate renders empty -> chezmoi prunes; a `requires:`
#     gate would leave a fail-closed shim lingering, the #184 lesson).
#   - enableGitSigning=false must NOT disturb the gates: they live OUTSIDE
#     ~/.config/git on purpose, because chezmoiignore drops a disabled
#     module's directory subtree wholesale (.config/git belongs to
#     git-signing), which would silently unwire the gates.
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

GATE_SCRIPTS=(personal-git-hook-dispatcher personal-public-safety-gate personal-ai-trailer-gate)

# plant_gate_deploy HOME_DIR SCRIPT...
# Simulate the agent-tools deploy in a throwaway destination home: executable
# no-op stubs at the contract path. Callers pass a subset to simulate a
# partial deploy.
plant_gate_deploy() {
  local home_dir="$1"
  shift
  local script
  mkdir -p "$home_dir/.claude/agent-tools/scripts"
  for script in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "$home_dir/.claude/agent-tools/scripts/$script"
    chmod +x "$home_dir/.claude/agent-tools/scripts/$script"
  done
}

gate_files_absent() {
  local home_dir="$1"
  [[ ! -e "$home_dir/.config/git-hook-gates/hooks/pre-commit" ]] \
    && [[ ! -e "$home_dir/.config/git-hook-gates/hooks/commit-msg" ]] \
    && [[ ! -e "$home_dir/.config/git-hook-gates/hooks.gitconfig" ]]
}

section "git hook gates arming (two-key gate, #196)"

# 1) Bare destination (fresh machine, no agent-tools): apply succeeds and no
#    wiring renders. This is the must-1 fix pinned as behavior — the OLD
#    (dangerous) behavior rendered fail-closed wiring here.
bare_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-hook-gates-bare.XXXXXX")"
tmp_roots+=("$bare_root")
if ! render_personal_into "$DOTFILES_ROOT" "$bare_root"; then
  fail "test failed: personal apply into a bare destination did not render"
  exit 1
fi
if gate_files_absent "$bare_root/home"; then
  ok "test passed: bare destination stays unarmed (no shims, no hooks.gitconfig — a fresh machine cannot be bricked)"
else
  fail "test failed: bare destination rendered gate wiring (fail-closed brick on fresh machines — must-1 regression)"
  status=1
fi

# 2) Partial deploy (dispatcher present, gates missing): must NOT arm. The
#    dispatcher fails closed when a gate next to it is missing, so arming on
#    the dispatcher alone still bricks commits (must-2, render side).
partial_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-hook-gates-partial.XXXXXX")"
tmp_roots+=("$partial_root")
mkdir -p "$partial_root/home"
plant_gate_deploy "$partial_root/home" personal-git-hook-dispatcher
if ! render_personal_into "$DOTFILES_ROOT" "$partial_root"; then
  fail "test failed: personal apply with a partial deploy did not render"
  status=1
elif gate_files_absent "$partial_root/home"; then
  ok "test passed: partial deploy (dispatcher only) stays unarmed (readiness requires all three scripts)"
else
  fail "test failed: partial deploy armed the wiring (dispatcher-only readiness — must-2 regression)"
  status=1
fi

# 2b) Non-executable deploy (all three present, dispatcher chmod 644): must
#     NOT arm. The probe requires the same `-x` readiness doctor and preflight
#     report — a presence-only probe would arm here while preflight says
#     "will NOT arm", and the armed shim then bricks every commit (Codex
#     re-review on PR #197).
nonexec_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-hook-gates-nonexec.XXXXXX")"
tmp_roots+=("$nonexec_root")
mkdir -p "$nonexec_root/home"
plant_gate_deploy "$nonexec_root/home" "${GATE_SCRIPTS[@]}"
chmod 644 "$nonexec_root/home/.claude/agent-tools/scripts/personal-git-hook-dispatcher"
if ! render_personal_into "$DOTFILES_ROOT" "$nonexec_root"; then
  fail "test failed: personal apply with a non-executable dispatcher did not render"
  status=1
elif gate_files_absent "$nonexec_root/home"; then
  ok "test passed: non-executable dispatcher stays unarmed (probe requires the same -x readiness as doctor/preflight)"
else
  fail "test failed: non-executable dispatcher armed the wiring (presence-only probe regression)"
  status=1
fi

section "git hook gates rendered content (full deploy)"

# 3) Full deploy planted BEFORE apply: both shims and hooks.gitconfig render
#    with the exact expected bytes and the shims are executable. The
#    dispatcher path pins the ~/.claude deploy (the dotfiles pick of record;
#    agent-tools deploys the same bytes to both tool homes).
home_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-hook-gates.XXXXXX")"
tmp_roots+=("$home_root")
mkdir -p "$home_root/home"
plant_gate_deploy "$home_root/home" "${GATE_SCRIPTS[@]}"
if ! render_personal_into "$DOTFILES_ROOT" "$home_root"; then
  fail "test failed: personal apply with a full deploy did not render"
  exit 1
fi
home="$home_root/home"
gates_dir="$home/.config/git-hook-gates"

shim_body() {
  local stage="$1"
  printf '%s\n' \
    '#!/bin/sh' \
    '# Managed by chezmoi from kosako/dotfiles (git-hook-gates, #196).' \
    '# Thin shim: gate logic lives in agent-tools (contract: docs/git-hook-gates.md' \
    '# there). Best-effort guardrail — --no-verify and a repo-local core.hooksPath' \
    '# bypass it.' \
    "exec \"\$HOME/.claude/agent-tools/scripts/personal-git-hook-dispatcher\" $stage \"\$@\""
}

for stage in pre-commit commit-msg; do
  shim="$gates_dir/hooks/$stage"
  if [[ ! -f "$shim" ]]; then
    fail "test failed: full deploy did not arm the $stage shim (enableGitHookGates is ON)"
    status=1
    continue
  fi
  if [[ ! -x "$shim" ]]; then
    fail "test failed: $stage shim is not executable (git silently skips a non-executable hook)"
    status=1
  fi
  if ! sh -n "$shim"; then
    fail "test failed: $stage shim does not parse as sh"
    status=1
  fi
  if diff <(shim_body "$stage") "$shim" >/dev/null; then
    ok "test passed: $stage shim renders the exact expected bytes (thin exec to the ~/.claude dispatcher, stage=$stage)"
  else
    fail "test failed: $stage shim content mismatch; rendered was:"
    cat "$shim" >&2
    status=1
  fi
done

hooks_gitconfig="$gates_dir/hooks.gitconfig"
expected_gitconfig="$(printf '%s\n' \
  '# Managed by chezmoi from kosako/dotfiles (git-hook-gates, #196).' \
  "# Read via the unconditional [include] in ~/.gitconfig. Points every repo's" \
  '# hooks at the managed shim directory; the shims chain to each repo'"'"'s own' \
  '# .git/hooks, so existing repo hooks keep running (docs/git-hook-gates.md).' \
  '[core]' \
  $'\thooksPath = ~/.config/git-hook-gates/hooks')"
if [[ ! -f "$hooks_gitconfig" ]]; then
  fail "test failed: full deploy did not arm hooks.gitconfig (enableGitHookGates is ON)"
  status=1
elif [[ "$(cat "$hooks_gitconfig")" == "$expected_gitconfig" ]]; then
  ok "test passed: hooks.gitconfig renders exactly core.hooksPath -> ~/.config/git-hook-gates/hooks"
else
  fail "test failed: hooks.gitconfig content mismatch; rendered was:"
  cat "$hooks_gitconfig" >&2
  status=1
fi

section "git hook gates end to end (rendered ~/.gitconfig drives the shims)"

# 4) Drive a real commit through the RENDERED artifacts: HOME is the armed
#    render home, the rendered ~/.gitconfig is the global config (its
#    unconditional include pulls hooks.gitconfig, which sets core.hooksPath),
#    and the planted dispatcher stub is swapped for a logging fake. A passing
#    dispatcher must see BOTH stages; a failing one must block the commit;
#    --no-verify must bypass both (the documented best-effort limit).
if ! command -v git >/dev/null 2>&1; then
  warn "git not found, skipping end-to-end checks"
else
  # includeIf "gitdir:~/..." compares physical paths, so HOME must be the
  # physical path too (same as test-gitconfig.sh).
  home="$(cd "$home" && pwd -P)"
  fake_dispatcher="$home/.claude/agent-tools/scripts/personal-git-hook-dispatcher"
  dispatcher_log="$home/dispatcher-invocations.log"
  cat > "$fake_dispatcher" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$dispatcher_log"
exit "\${FAKE_DISPATCHER_EXIT:-0}"
EOF
  chmod +x "$fake_dispatcher"

  # Identity so useConfigOnly resolves inside ~/src/personal (the managed
  # global config is fail-closed on identity; same fixture as test-gitconfig).
  mkdir -p "$home/.config/git" "$home/src/personal/demo"
  cat > "$home/.config/git/personal.gitconfig" <<'EOF'
[user]
	name = Dotfiles Test
	email = dotfiles-test@example.invalid
EOF

  run_git() {
    local repo="$1"
    shift
    env -u EMAIL -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
      HOME="$home" \
      XDG_CONFIG_HOME="$home/.config" \
      LC_ALL=C \
      GIT_CONFIG_NOSYSTEM=1 \
      GIT_CONFIG_GLOBAL="$home/.gitconfig" \
      git -C "$repo" "$@"
  }

  repo="$home/src/personal/demo"
  run_git "$repo" init --quiet --initial-branch=main

  if output="$(FAKE_DISPATCHER_EXIT=0 run_git "$repo" commit --allow-empty -m test 2>&1)"; then
    if [[ "$(cat "$dispatcher_log" 2>/dev/null)" == $'pre-commit\ncommit-msg' ]]; then
      ok "test passed: a commit routes through the shims and the dispatcher sees pre-commit then commit-msg"
    else
      fail "test failed: dispatcher invocations unexpected; log was:"
      cat "$dispatcher_log" >&2 || true
      status=1
    fi
  else
    printf '%s\n' "$output" >&2
    fail "test failed: commit did not succeed with a passing dispatcher"
    status=1
  fi

  : > "$dispatcher_log"
  if output="$(FAKE_DISPATCHER_EXIT=2 run_git "$repo" commit --allow-empty -m test 2>&1)"; then
    fail "test failed: commit succeeded although the dispatcher failed (gate not on the commit path?)"
    status=1
  else
    ok "test passed: a failing dispatcher blocks the commit (fail-closed on the normal path)"
  fi

  : > "$dispatcher_log"
  if output="$(FAKE_DISPATCHER_EXIT=2 run_git "$repo" commit --no-verify --allow-empty -m test 2>&1)"; then
    if [[ ! -s "$dispatcher_log" ]]; then
      ok "test passed: --no-verify bypasses both shims (documented best-effort limit)"
    else
      fail "test failed: --no-verify still invoked the dispatcher; log was:"
      cat "$dispatcher_log" >&2
      status=1
    fi
  else
    printf '%s\n' "$output" >&2
    fail "test failed: --no-verify commit did not succeed"
    status=1
  fi
fi

section "git hook gates gating (#196)"

# 5) enableGitHookGates=false REMOVES already-applied wiring on the next apply
#    — not just "does not newly create it". A lingering shim + hooksPath after
#    a cap flip would keep commits pointed at a fail-closed dispatcher, so
#    drive both applies into the SAME (fully deployed) home: cap ON renders
#    the files, cap OFF must delete all three (template self-gate renders
#    empty and chezmoi prunes; a `requires:` gate would miss this, #184).
off_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-hook-gates-off-src.XXXXXX")"
tmp_roots+=("$off_src")
make_flipped_source "$off_src"
flip_personal_capability "$off_src/src" enableGitHookGates false

removal_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-hook-gates-removal.XXXXXX")"
tmp_roots+=("$removal_root")
mkdir -p "$removal_root/home"
plant_gate_deploy "$removal_root/home" "${GATE_SCRIPTS[@]}"
printf '[data]\nprofile = "personal"\n' > "$removal_root/chezmoi.toml"
apply_into_removal_home() {
  chezmoi --config "$removal_root/chezmoi.toml" \
    --source "$1" --destination "$removal_root/home" apply >/dev/null 2>&1
}
if ! apply_into_removal_home "$DOTFILES_ROOT"; then
  fail "test failed: cap-on apply into removal home did not render"
  status=1
elif gate_files_absent "$removal_root/home"; then
  fail "test failed: cap-on apply did not arm the gate wiring (removal test precondition; deploy was planted)"
  status=1
elif ! apply_into_removal_home "$off_src/src"; then
  fail "test failed: cap-off apply into removal home did not run"
  status=1
elif gate_files_absent "$removal_root/home"; then
  ok "test passed: enableGitHookGates=false removes already-applied shims and hooks.gitconfig (no lingering fail-closed wiring)"
else
  fail "test failed: enableGitHookGates=false left gate wiring lingering (a requires: gate regression?)"
  status=1
fi

# 6) Independence from git-signing: the gates live OUTSIDE ~/.config/git on
#    purpose — that directory belongs to the git-signing module, and
#    chezmoiignore drops a disabled module's directory subtree WHOLESALE, so
#    gates placed under it would silently unwire when signing is off. Pin the
#    placement: with enableGitSigning=false (and a full deploy) the gates must
#    still arm.
signing_off_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-hook-gates-signoff.XXXXXX")"
tmp_roots+=("$signing_off_src")
make_flipped_source "$signing_off_src"
flip_personal_capability "$signing_off_src/src" enableGitSigning false

signing_off_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-hook-gates-signoff-home.XXXXXX")"
tmp_roots+=("$signing_off_root")
mkdir -p "$signing_off_root/home"
plant_gate_deploy "$signing_off_root/home" "${GATE_SCRIPTS[@]}"
if ! render_personal_into "$signing_off_src/src" "$signing_off_root"; then
  fail "test failed: enableGitSigning=false apply did not render"
  status=1
elif [[ -x "$signing_off_root/home/.config/git-hook-gates/hooks/pre-commit" ]] \
  && [[ -x "$signing_off_root/home/.config/git-hook-gates/hooks/commit-msg" ]] \
  && [[ -f "$signing_off_root/home/.config/git-hook-gates/hooks.gitconfig" ]] \
  && [[ ! -e "$signing_off_root/home/.config/git/signing.gitconfig" ]]; then
  ok "test passed: enableGitSigning=false keeps the gates armed (placement outside ~/.config/git is load-bearing)"
else
  fail "test failed: enableGitSigning=false disturbed the gate wiring (were the gates moved under ~/.config/git?)"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "git hook gates tests passed"
fi
exit "$status"
