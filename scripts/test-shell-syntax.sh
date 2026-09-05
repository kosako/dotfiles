#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

require_yq
command -v zsh >/dev/null || { fail "zsh is required for syntax gate tests"; exit 1; }

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-shell-syntax.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts"

# Exercise the actual CI commands: multiple operands to shell -n parse only
# the first file, and a valid final file must not hide an earlier failure.
workflow="$DOTFILES_ROOT/.github/workflows/validate.yml"
for shell_name in bash zsh; do
  case "$shell_name" in
    bash)
      step="bash syntax check"
      files=(scripts/a.sh scripts/b.sh scripts/c.sh)
      ;;
    zsh)
      step="zsh syntax check (managed shell files)"
      files=(dot_zshenv dot_zshrc dot_zprofile)
      ;;
  esac
  check="$(STEP="$step" yq -r '.jobs.validate.steps[] | select(.name == strenv(STEP)) | .run' "$workflow")"
  [[ -n "$check" && "$check" != "null" ]] || { fail "missing CI syntax step: $step"; exit 1; }
  for file in "${files[@]}"; do
    printf ':\n' > "$fixture/$file"
  done
  if ! (cd "$fixture" && bash -e -c "$check"); then
    fail "$shell_name syntax gate rejected valid files"
    exit 1
  fi
  for file in "${files[@]}"; do
    printf 'if then\n' > "$fixture/$file"
    if (cd "$fixture" && bash -e -c "$check") >/dev/null 2>&1; then
      fail "$shell_name syntax gate missed invalid $file"
      exit 1
    fi
    printf ':\n' > "$fixture/$file"
    ok "$shell_name syntax gate rejects invalid $file"
  done
done

ok "shell syntax gate tests passed"
