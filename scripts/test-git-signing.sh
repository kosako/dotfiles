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

# Apply the personal profile from SOURCE_DIR into a throwaway home and print the
# home path. Returns non-zero on a failed apply.
apply_personal() {
  local source_dir="$1" root
  root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-signing.XXXXXX")"
  tmp_roots+=("$root")
  mkdir -p "$root/home"
  printf '[data]\nprofile = "personal"\n' > "$root/chezmoi.toml"
  if ! chezmoi --config "$root/chezmoi.toml" \
      --source "$source_dir" --destination "$root/home" apply >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "$root/home"
}

section "git-signing gating"

# 1) enableGitSigning=false: signing.gitconfig is not applied. Force the value in
#    a copy so the test is independent of the committed default.
off_src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-signing-off.XXXXXX")"
tmp_roots+=("$off_src")
cp -R "$DOTFILES_ROOT" "$off_src/src"
rm -rf "$off_src/src/.git"
yq -i '.profiles.personal.capabilities.enableGitSigning = false' \
  "$off_src/src/.chezmoidata/profiles.yaml"
if ! off_home="$(apply_personal "$off_src/src")"; then
  fail "test failed: personal apply (enableGitSigning=false) did not render"
  exit 1
fi
if [[ -e "$off_home/.config/git/signing.gitconfig" ]]; then
  fail "test failed: signing.gitconfig applied while enableGitSigning=false"
  status=1
else
  ok "test passed: enableGitSigning=false does not apply signing.gitconfig"
fi

# 2) enableGitSigning=true: signing.gitconfig is applied with the SSH mechanism.
src="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-git-signing-src.XXXXXX")"
tmp_roots+=("$src")
cp -R "$DOTFILES_ROOT" "$src/src"
rm -rf "$src/src/.git"
yq -i '.profiles.personal.capabilities.enableGitSigning = true' \
  "$src/src/.chezmoidata/profiles.yaml"

if ! on_home="$(apply_personal "$src/src")"; then
  fail "test failed: personal apply (enableGitSigning=true) did not render"
  exit 1
fi
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
