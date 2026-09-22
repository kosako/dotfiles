#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

profile="${1:-personal}"

section "preflight profile: $profile"

section "policy"
run_policy_validation "$profile" || exit 1

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
for file in "$HOME/.gitconfig" "$HOME/.npmrc"; do
  if [[ -e "$file" ]]; then
    warn "exists: $file"
  else
    ok "absent: $file"
  fi
done

section "shell config (apply impact)"
# When shell-extra is active for this profile, apply replaces ~/.zshenv,
# ~/.zshrc and ~/.zprofile with managed versions. Surface that, and point
# to the local-override files so machine-specific lines are not lost.
if module_active_for_profile "$profile" "shell-extra"; then
  shell_managed=1
else
  shell_managed=0
fi
for file in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.config/starship.toml"; do
  base="$(basename "$file")"
  if [[ ! -e "$file" ]]; then
    ok "absent: $file"
  elif [[ "$shell_managed" -eq 1 ]]; then
    if [[ "$base" == ".zshenv" ]]; then
      # .zshenv has no ~/.zshenv.local override (it must stay minimal), so do
      # not tell users to move lines there — they would be lost. See docs/shell.md.
      warn "exists: $file — apply (shell-extra) replaces it; back up and diff first. .zshenv has no ~/.zshenv.local: move interactive lines to ~/.zshrc.local; non-interactive needs must go into managed .zshenv (see docs/shell.md)"
    elif [[ "$base" == "starship.toml" ]]; then
      # starship has no local-override file; the managed config is the whole file.
      warn "exists: $file — apply (shell-extra) replaces it; back up and diff first. starship has no local override: fold custom prompt config into the managed ~/.config/starship.toml (see docs/shell.md)"
    else
      warn "exists: $file — apply (shell-extra) replaces it; move machine-specific lines to ~/$base.local first (see docs/shell.md)"
    fi
  else
    item "exists: $file — not managed for profile $profile (left as-is)"
  fi
done

section "ssh config (apply impact)"
# When ssh-1password is active, apply replaces ~/.ssh/config with the managed
# version. Machine-specific hosts (and the 1Password agent for them) must move
# to ~/.ssh/config.local first, or they are lost. The local file is reported by
# existence only — never read (docs/local-overrides.md). See docs/ssh.md.
if module_active_for_profile "$profile" "ssh-1password"; then
  if [[ -e "$HOME/.ssh/config" ]]; then
    warn "exists: $HOME/.ssh/config — apply (ssh-1password) replaces it; move machine-specific hosts to ~/.ssh/config.local first, then diff (see docs/ssh.md)"
  else
    ok "absent: $HOME/.ssh/config"
  fi
  if [[ -e "$HOME/.ssh/config.local" ]]; then
    item "local override present: $HOME/.ssh/config.local (contents not read)"
  fi
elif [[ -e "$HOME/.ssh/config" ]]; then
  item "exists: $HOME/.ssh/config — not managed for profile $profile (left as-is)"
else
  ok "absent: $HOME/.ssh/config"
fi

section "config directory permission"
# private_dot_config makes chezmoi manage ~/.config itself at 0700.
# On an existing host where ~/.config is 0755, the first apply changes
# it. Surface that here so it is never a surprise (see
# docs/directory-convention.md).
config_dir="$HOME/.config"
if [[ -L "$config_dir" ]]; then
  warn "$config_dir is a symlink; apply may replace or follow it (verify with chezmoi diff)"
elif [[ -d "$config_dir" ]]; then
  config_mode="$(file_mode "$config_dir" 2>/dev/null || echo unknown)"
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
# git-ignore apply impact (#248): with the module active, apply replaces
# ~/.config/git/ignore — git's default global excludes file — with the
# managed one. Git reads exactly ONE global excludes file, so there is no
# .local companion: host-specific patterns must move to each repo's
# .git/info/exclude before apply (or be diffed first). Existence only; the
# file is never read here. A core.excludesFile set in the global OR system
# scope makes git read a different file than the managed one (an explicitly
# empty one makes it read none), so report the state (value not shown) —
# the managed ~/.gitconfig does not pin it (docs/git-ignore.md).
global_ignore="$HOME/.config/git/ignore"
if module_active_for_profile "$profile" git-ignore; then
  if [[ -e "$global_ignore" ]]; then
    warn "exists: $global_ignore — apply (git-ignore) replaces it; git reads one global excludes file (no .local), so move host-specific patterns to each repo's .git/info/exclude first, then diff (see docs/git-ignore.md)"
  else
    ok "absent: $global_ignore (apply creates the managed global gitignore)"
  fi
  if command -v git >/dev/null 2>&1; then
    case "$(git_excludes_file_setting)" in
      path\ *)
        warn "core.excludesFile is set (value not shown; global or system config) — git reads that file instead of the managed $global_ignore; unset it and fold its patterns into per-repo .git/info/exclude (see docs/git-ignore.md)"
        ;;
      empty)
        warn "core.excludesFile is explicitly empty (global or system config) — git reads no global excludes file, so the managed $global_ignore would not be in effect; unset the key (see docs/git-ignore.md)"
        ;;
      error)
        warn "git cannot read its global/system config (core.excludesFile lookup failed) — fix the config error before apply (see docs/git-ignore.md)"
        ;;
    esac
  fi
elif [[ -e "$global_ignore" ]]; then
  item "exists: $global_ignore — not managed for profile $profile (left as-is)"
fi
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

# Apply impact of the git hook gates (#196): with enableGitHookGates on,
# apply wires global core.hooksPath at thin shims that exec agent-tools'
# personal-git-hook-dispatcher. The templates only render when the
# agent-tools deploy is COMPLETE in the destination (two-key gate), so a
# fresh machine does not get bricked — but readiness must be judged on ALL
# FOUR scripts (dispatcher + public-safety / git-identity / ai-trailer gates;
# the identity gate joined the pre-commit stage in agent-tools#281, #239):
# the dispatcher is FAIL-CLOSED (exit 2) when a gate next to it is missing,
# so "dispatcher present, gate missing" would arm the wiring and then block
# every commit (Codex review, PR #197). This list must stay identical to
# .chezmoitemplates/git-hook-gates-armed and doctor.sh. Report-only, like
# everything here.
section "git hook gates (apply impact)"
if [[ "$(capability_value "$profile" enableGitHookGates)" == "true" ]]; then
  hook_gates_deploy_dir="$HOME/.claude/agent-tools/scripts"
  hook_gates_missing=0
  for hook_gates_script in personal-git-hook-dispatcher personal-public-safety-gate personal-git-identity-gate personal-ai-trailer-gate; do
    if [[ -x "$hook_gates_deploy_dir/$hook_gates_script" ]]; then
      ok "deployed: $hook_gates_deploy_dir/$hook_gates_script"
    else
      warn "missing or not executable: $hook_gates_deploy_dir/$hook_gates_script"
      hook_gates_missing=1
    fi
  done
  if [[ "$hook_gates_missing" -eq 1 ]]; then
    warn "agent-tools deploy incomplete: apply will NOT arm the commit gates (two-key gate); run agent-tools sync first, then apply again. Do not arm a partial deploy — the dispatcher fails closed and would block every git commit"
  else
    ok "agent-tools deploy complete: apply arms the commit gates (fail-closed on the normal git commit path)"
  fi
  if command -v git >/dev/null 2>&1; then
    # --includes is load-bearing: the managed value lives in the INCLUDED
    # hooks.gitconfig, and `git config --global --get` skips includes by
    # default when a scope file is given — without the flag a correctly
    # wired machine misreports (found in the #196 live smoke).
    hook_gates_path="$(git config --global --includes --get core.hooksPath || true)"
    # shellcheck disable=SC2088 # literal gitconfig value comparison (git expands the tilde, not the shell)
    case "$hook_gates_path" in
      "")
        ;;
      "~/.config/git-hook-gates/hooks" | "$HOME/.config/git-hook-gates/hooks")
        ok "global core.hooksPath already points at the managed shim directory"
        ;;
      *)
        warn "global core.hooksPath is set to something else (value not shown) — apply replaces ~/.gitconfig and the managed include takes over; diff first"
        ;;
    esac
  fi
else
  ok "git hook gates disabled for this profile (enableGitHookGates=false)"
fi

section "commands"
for command_name in git chezmoi brew op node npm corepack mise direnv yq shellcheck shfmt; do
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
report_standard_project_roots

# preflight is report-only: warnings never change the exit code.
# The only non-zero path is the policy validation at the top.
exit 0
