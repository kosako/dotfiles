#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

profile="${1:-personal}"

section "preflight profile: $profile"

section "policy"
if ! "$SCRIPT_DIR/validate-policy.sh" "$profile"; then
  exit 1
fi

section "system"
ok "arch: $(uname -m)"
if command -v sw_vers >/dev/null 2>&1; then
  ok "macOS: $(sw_vers -productVersion)"
fi

if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode Command Line Tools: $(xcode-select -p)"
else
  warn "Xcode Command Line Tools: not configured"
fi

section "existing home files"
for file in "$HOME/.gitconfig" "$HOME/.ssh/config" "$HOME/.npmrc"; do
  if [[ -e "$file" ]]; then
    warn "exists: $file"
  else
    ok "absent: $file"
  fi
done

section "shell config (apply impact)"
# When shell-extra is active for this profile, apply replaces ~/.zshrc
# and ~/.zprofile with managed versions. Surface that, and point to the
# local-override files so machine-specific lines are not lost.
if module_active_for_profile "$profile" "shell-extra"; then
  shell_managed=1
else
  shell_managed=0
fi
for file in "$HOME/.zshrc" "$HOME/.zprofile"; do
  base="$(basename "$file")"
  if [[ ! -e "$file" ]]; then
    ok "absent: $file"
  elif [[ "$shell_managed" -eq 1 ]]; then
    warn "exists: $file — apply (shell-extra) replaces it; move machine-specific lines to ~/$base.local first (see docs/shell.md)"
  else
    item "exists: $file — not managed for profile $profile (left as-is)"
  fi
done

section "config directory permission"
# private_dot_config makes chezmoi manage ~/.config itself at 0700.
# On an existing host where ~/.config is 0755, the first apply changes
# it. Surface that here so it is never a surprise (see
# docs/directory-convention.md).
config_dir="$HOME/.config"
if [[ -L "$config_dir" ]]; then
  warn "$config_dir is a symlink; apply may replace or follow it (verify with chezmoi diff)"
elif [[ -d "$config_dir" ]]; then
  # BSD (macOS) and GNU stat take different flags; pick by OS rather
  # than chaining them, since `stat -f` means --file-system on GNU.
  if [[ "$(uname)" == "Darwin" ]]; then
    config_mode="$(stat -f '%Lp' "$config_dir" 2>/dev/null || echo unknown)"
  else
    config_mode="$(stat -c '%a' "$config_dir" 2>/dev/null || echo unknown)"
  fi
  if [[ "$config_mode" == "700" ]]; then
    ok "$config_dir mode already 0700"
  else
    warn "$config_dir mode is $config_mode; apply manages it at 0700 (private_dot_config)"
  fi
else
  item "$config_dir absent; apply will create it at 0700"
fi

section "existing Git config"
if [[ -e "$HOME/.config/git/config" ]]; then
  warn "exists: $HOME/.config/git/config"
else
  ok "absent: $HOME/.config/git/config"
fi
for context in personal work client sandbox agent; do
  identity_file="$HOME/.config/git/$context.gitconfig"
  if [[ -e "$identity_file" ]]; then
    item "identity file already present: $identity_file"
  fi
done
if command -v git >/dev/null 2>&1; then
  if git config --global --get user.name >/dev/null 2>&1; then
    warn "global user.name is set (value not shown)"
  else
    ok "global user.name not set"
  fi
  if git config --global --get user.email >/dev/null 2>&1; then
    warn "global user.email is set (value not shown)"
  else
    ok "global user.email not set"
  fi
fi

section "commands"
for command_name in git chezmoi brew op node npm corepack mise direnv code yq shellcheck shfmt; do
  command_status "$command_name" || true
done

section "Homebrew"
if command -v brew >/dev/null 2>&1; then
  ok "brew prefix: $(brew --prefix)"
else
  warn "brew unavailable"
fi

section "source directory"
# DOTFILES_ROOT is resolved by lib-policy.sh at source time, so it
# always exists here; report it for the record.
ok "dotfiles root exists: $DOTFILES_ROOT"

if [[ -w "$DOTFILES_ROOT" ]]; then
  ok "dotfiles root writable"
else
  warn "dotfiles root is not writable"
fi

section "known project roots"
for dir in "$HOME/src/personal" "$HOME/src/work" "$HOME/src/client" "$HOME/src/sandbox" "$HOME/src/agent"; do
  if [[ -d "$dir" ]]; then
    ok "exists: $dir"
  else
    warn "missing: $dir"
  fi
done

# preflight is report-only: warnings never change the exit code.
# The only non-zero path is the policy validation at the top.
exit 0
