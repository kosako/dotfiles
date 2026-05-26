#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

profile="${1:-personal}"
status=0

info "preflight profile: $profile"

if ! "$SCRIPT_DIR/validate-policy.sh" "$profile"; then
  exit 1
fi

info "system"
ok "arch: $(uname -m)"
if command -v sw_vers >/dev/null 2>&1; then
  ok "macOS: $(sw_vers -productVersion)"
fi

if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode Command Line Tools: $(xcode-select -p)"
else
  warn "Xcode Command Line Tools: not configured"
fi

info "existing home files"
for file in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.gitconfig" "$HOME/.ssh/config" "$HOME/.npmrc"; do
  if [[ -e "$file" ]]; then
    warn "exists: $file"
  else
    ok "absent: $file"
  fi
done

info "commands"
for command_name in git chezmoi brew op node npm corepack mise direnv code yq shellcheck shfmt; do
  command_status "$command_name" || true
done

info "Homebrew"
if command -v brew >/dev/null 2>&1; then
  ok "brew prefix: $(brew --prefix)"
else
  warn "brew unavailable"
fi

info "source directory"
if [[ -d "$DOTFILES_ROOT" ]]; then
  ok "dotfiles root exists: $DOTFILES_ROOT"
else
  fail "dotfiles root missing: $DOTFILES_ROOT"
  status=1
fi

if [[ -w "$DOTFILES_ROOT" ]]; then
  ok "dotfiles root writable"
else
  warn "dotfiles root is not writable"
fi

info "known project roots"
for dir in "$HOME/src/personal" "$HOME/src/work" "$HOME/src/client" "$HOME/src/sandbox" "$HOME/src/agent"; do
  if [[ -d "$dir" ]]; then
    ok "exists: $dir"
  else
    warn "missing: $dir"
  fi
done

exit "$status"
