#!/usr/bin/env bash
set -euo pipefail

# Gating test for the git-signing module (issue #85). signing.gitconfig (the
# SSH-signing mechanism: gpg.format=ssh + 1Password signer) is a managed file
# applied ONLY when enableGitSigning is true. Both gated states are forced in
# throwaway source copies so the test is independent of the committed default
# (the unconditional [include] in ~/.gitconfig is a no-op when the file is
# absent). The signing
# key and the per-context commit.gpgsign live in the local identity files
# (docs/git-identity.md) and are intentionally out of the managed mechanism.
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
elif grep -q 'format = ssh' "$f" && grep -q 'op-ssh-sign' "$f"; then
  ok "test passed: enableGitSigning=true applies signing.gitconfig (ssh format + 1Password signer)"
else
  fail "test failed: signing.gitconfig missing expected ssh/op-ssh-sign content"
  status=1
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
