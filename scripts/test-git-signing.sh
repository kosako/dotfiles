#!/usr/bin/env bash
set -euo pipefail

# Gating test for the git-signing module (issue #85). signing.gitconfig (the
# SSH-signing mechanism: gpg.format=ssh + 1Password signer) is a managed file
# applied ONLY when enableGitSigning is true. Both gated states are forced in
# throwaway source copies so the test is independent of the committed default
# (the unconditional [include] in ~/.gitconfig is a no-op when the file is
# absent). The off state must drop only signing.gitconfig and keep
# git-ignore's sibling under ~/.config/git (#207). The signing
# key and the per-context commit.gpgsign live in the local identity files
# (docs/git-identity.md) and are intentionally out of the managed mechanism.
# The mechanism's values are read the way Git reads them (through the include in
# the rendered ~/.gitconfig), with controls that a substring grep would pass
# (#384).
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

section "git-signing gating"

# 1) enableGitSigning=false: signing.gitconfig is not applied. Force the value in
#    a copy so the test is independent of the committed default.
off_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-signing-off.XXXXXX")"
tmp_roots+=("$off_src")
make_flipped_source "$off_src"
flip_personal_capability "$off_src/src" enableGitSigning false
off_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-signing.XXXXXX")"
tmp_roots+=("$off_root")
if ! render_personal_into "$off_src/src" "$off_root"; then
  fail "test failed: personal apply (enableGitSigning=false) did not render"
  exit 1
fi
off_home="$off_root/home"
if [[ -e "$off_home/.config/git/signing.gitconfig" ]]; then
  fail "test failed: signing.gitconfig applied while enableGitSigning=false"
  status=1
else
  ok "test passed: enableGitSigning=false does not apply signing.gitconfig"
fi

# 1b) enableGitSigning=false drops signing.gitconfig only: a sibling under
#     ~/.config/git (git-ignore's ~/.config/git/ignore, #248) stays, because
#     the allowlist derives the ~/.config/git ancestor from EVERY active
#     module's paths (#207), not from git-signing alone.
if [[ -f "$off_home/.config/git/ignore" ]]; then
  ok "test passed: enableGitSigning=false keeps .config/git/ignore (the ~/.config/git ancestor is not owned by git-signing, #207)"
else
  fail "test failed: enableGitSigning=false must keep .config/git/ignore (the ~/.config/git ancestor is not owned by git-signing, #207)"
  status=1
fi

# signing_values HOME -> "gpg.format|gpg.ssh.program" as Git itself resolves them
# from HOME/.gitconfig, following its [include] of ~/.config/git/signing.gitconfig
# (#384). A substring grep passes on a commented-out line or a key under the
# wrong section; Git's own reading does not. An empty field means Git found no
# value.
expected_signer=/Applications/1Password.app/Contents/MacOS/op-ssh-sign
signing_values() {
  local fmt prog
  fmt="$(env -i PATH="$PATH" HOME="$1" GIT_CONFIG_NOSYSTEM=1 \
    git config --global --includes --get gpg.format 2>/dev/null || true)"
  prog="$(env -i PATH="$PATH" HOME="$1" GIT_CONFIG_NOSYSTEM=1 \
    git config --global --includes --get gpg.ssh.program 2>/dev/null || true)"
  printf '%s|%s\n' "$fmt" "$prog"
}

# 2) enableGitSigning=true: signing.gitconfig is applied with the SSH mechanism.
src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-signing-src.XXXXXX")"
tmp_roots+=("$src")
make_flipped_source "$src"
flip_personal_capability "$src/src" enableGitSigning true

on_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-signing.XXXXXX")"
tmp_roots+=("$on_root")
if ! render_personal_into "$src/src" "$on_root"; then
  fail "test failed: personal apply (enableGitSigning=true) did not render"
  exit 1
fi
on_home="$on_root/home"
f="$on_home/.config/git/signing.gitconfig"
if [[ ! -f "$f" ]]; then
  fail "test failed: signing.gitconfig not applied while enableGitSigning=true"
  status=1
elif [[ "$(signing_values "$on_home")" == "ssh|$expected_signer" ]]; then
  ok "test passed: enableGitSigning=true applies signing.gitconfig; Git resolves gpg.format=ssh and the 1Password signer through ~/.gitconfig's include"
else
  fail "test failed: Git must resolve gpg.format=ssh and gpg.ssh.program=$expected_signer through ~/.gitconfig (got $(signing_values "$on_home"))"
  status=1
fi

# 2b) Controls (#384): the same check rejects a signing.gitconfig whose lines are
#     commented out, and one whose signer sits under [gpg] instead of
#     [gpg "ssh"]. Both still hold the strings the pre-#384 grep looked for, so
#     a check that only greps would pass them.
if [[ -f "$f" ]]; then
  for ctl in commented wrong-section; do
    ctl_home="$on_root/ctl-$ctl"
    mkdir -p "$ctl_home/.config/git"
    cp "$on_home/.gitconfig" "$ctl_home/.gitconfig"
    case "$ctl" in
      commented) sed -E 's/^([[:space:]]*)(format|program)/\1# \2/' "$f" > "$ctl_home/.config/git/signing.gitconfig" ;;
      wrong-section) grep -v '^\[gpg "ssh"\]$' "$f" > "$ctl_home/.config/git/signing.gitconfig" ;;
    esac
    ctl_file="$ctl_home/.config/git/signing.gitconfig"
    if ! grep -q 'format = ssh' "$ctl_file" || ! grep -q 'op-ssh-sign' "$ctl_file"; then
      fail "test failed: control $ctl lost the strings the old grep checked (the control would not show the gap)"
      status=1
    elif [[ "$(signing_values "$ctl_home")" == "ssh|$expected_signer" ]]; then
      fail "test failed: control $ctl resolved as a working signer (got $(signing_values "$ctl_home"))"
      status=1
    else
      ok "test passed: control $ctl is rejected (Git resolves $(signing_values "$ctl_home"))"
    fi
  done
fi

# 3) The managed mechanism must NOT carry the key or the per-context opt-in;
#    those are local per-context (a leak would force signing globally / expose a key).
if [[ -f "$f" ]] && grep -qiE '^[[:space:]]*(signingkey|gpgsign)[[:space:]]*=' "$f"; then
  fail "test failed: signing.gitconfig contains user.signingkey/commit.gpgsign (must be local per-context)"
  status=1
else
  ok "test passed: signing.gitconfig carries the mechanism only (no key, no gpgsign)"
fi

if [[ "$status" -eq 0 ]]; then
  ok "git-signing tests passed"
fi
exit "$status"
