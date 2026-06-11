#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

profile="${1:-personal}"
status=0

section "doctor profile: $profile"

section "policy"
if ! "$SCRIPT_DIR/validate-policy.sh" "$profile"; then
  exit 1
fi

environment_kind="$(profile_environment_kind "$profile")"
ok "environmentKind: $environment_kind"

section "modules"
while IFS= read -r module; do
  item "$module"
done < <(profile_modules "$profile")

section "capabilities"
profile_capabilities "$profile" | while IFS= read -r capability; do
  item "$capability=$(capability_value "$profile" "$capability")"
done

section "chezmoi"
if command -v chezmoi >/dev/null 2>&1; then
  ok "chezmoi: $(chezmoi --version 2>/dev/null | head -n 1)"
else
  warn "chezmoi not found"
fi
ok "source directory: $DOTFILES_ROOT"

section "Git"
if command -v git >/dev/null 2>&1; then
  ok "git: $(git --version)"
  use_config_only="$(git config --global --get user.useConfigOnly || true)"
  credentials_in_url="$(git config --global --get transfer.credentialsInUrl || true)"
  if [[ "$use_config_only" == "true" ]]; then
    ok "user.useConfigOnly=true"
  else
    warn "user.useConfigOnly is not true"
  fi
  if [[ "$credentials_in_url" == "die" ]]; then
    ok "transfer.credentialsInUrl=die"
  else
    warn "transfer.credentialsInUrl is not die"
  fi
else
  warn "git not found"
fi

section "Git identity contexts"
for context in personal work client sandbox agent; do
  identity_file="$HOME/.config/git/$context.gitconfig"
  project_root="$HOME/src/$context"
  if [[ -f "$identity_file" ]]; then
    ok "identity file exists: $identity_file"
  elif [[ -d "$project_root" ]]; then
    warn "project root exists but identity file missing: $identity_file"
  else
    item "context unused, identity file not configured: $context"
  fi
done

section "Git remote URLs"
if ! command -v git >/dev/null 2>&1; then
  warn "git not found, skipping remote URL scan"
else
  scanned_repos=0
  flagged_remotes=0
  for root in "$DOTFILES_ROOT" "$HOME/src/personal" "$HOME/src/work" "$HOME/src/client" "$HOME/src/sandbox" "$HOME/src/agent"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r git_marker; do
      repo="$(dirname "$git_marker")"
      scanned_repos=$((scanned_repos + 1))
      while IFS= read -r remote_name; do
        [[ -z "$remote_name" ]] && continue
        flagged_remotes=$((flagged_remotes + 1))
        warn "credential-like userinfo in remote URL: repo=$repo remote=$remote_name (URL not shown)"
      done < <(git_remotes_with_credentials "$repo")
    done < <(find "$root" -maxdepth 4 -name .git -prune -print 2>/dev/null)
  done
  ok "scanned repositories: $scanned_repos"
  if [[ "$flagged_remotes" -eq 0 ]]; then
    ok "no credential-like userinfo in remote URLs"
  else
    warn "remotes with credential-like userinfo: $flagged_remotes"
  fi
fi

section "npm hardening"
npm_mode="$(capability_value "$profile" npmHardeningMode)"
ok "npmHardeningMode=$npm_mode"
if [[ "$npm_mode" == "off" ]]; then
  ok "npm hardening intentionally unmanaged"
elif ! command -v npm >/dev/null 2>&1; then
  warn "npm not found"
else
  npm_version="$(npm --version)"
  ok "npm: $npm_version"
  for key in min-release-age ignore-scripts save-exact fund audit userconfig globalconfig; do
    value="$(npm config get "$key" 2>/dev/null || true)"
    item "npm $key=$value"
  done
  npm_major="${npm_version%%.*}"
  npm_minor="$(printf '%s' "$npm_version" | cut -d. -f2)"
  if [[ "$npm_major" -gt 11 || ( "$npm_major" -eq 11 && "$npm_minor" -ge 6 ) ]] 2>/dev/null; then
    ok "npm supports min-release-age (>= 11.6)"
  else
    warn "npm older than 11.6, min-release-age is not enforced"
  fi
  if [[ "$npm_mode" == "enforce" ]]; then
    while IFS='=' read -r key expected; do
      [[ -z "$key" ]] && continue
      actual="$(npm config get "$key" 2>/dev/null || true)"
      if [[ "$actual" == "$expected" ]]; then
        ok "npm $key=$expected"
      else
        warn "enforce expects npm $key=$expected, current: $actual (apply pending?)"
      fi
    done <<'EOF'
ignore-scripts=true
save-exact=true
fund=false
audit=true
min-release-age=10080
EOF
  fi
fi

section "Corepack"
corepack_mode="$(capability_value "$profile" corepackMode)"
ok "corepackMode=$corepack_mode"
if [[ "$corepack_mode" == "off" ]]; then
  ok "corepack intentionally unmanaged"
elif ! command -v corepack >/dev/null 2>&1; then
  warn "corepack not found"
else
  ok "corepack: $(corepack --version 2>/dev/null || true)"
  if [[ "$corepack_mode" == "enable" ]]; then
    for pm in pnpm yarn; do
      pm_path="$(command -v "$pm" 2>/dev/null || true)"
      if [[ -n "$pm_path" ]]; then
        item "$pm shim: $pm_path"
      else
        warn "corepackMode=enable but $pm not resolvable (run 'corepack enable' manually)"
      fi
    done
  fi
fi

section "runtime and shell"
if [[ "$(capability_value "$profile" enableRuntimeManagement)" == "true" ]]; then
  command_status mise || true
else
  ok "runtime management disabled for profile"
fi
if [[ "$(capability_value "$profile" enableDirenv)" == "true" ]]; then
  command_status direnv || true
else
  ok "direnv disabled for profile"
fi
for command_name in zsh starship; do
  command_status "$command_name" || true
done

section "VS Code"
if [[ "$(capability_value "$profile" enableVsCodeSettings)" == "true" ]]; then
  command_status code || true
else
  ok "VS Code settings disabled for profile"
fi
if [[ "$(capability_value "$profile" enableVsCodeExtensions)" == "true" ]]; then
  warn "VS Code extension auto-install is enabled"
else
  ok "VS Code extension auto-install disabled"
fi

section "1Password"
if [[ "$(capability_value "$profile" allowSecretsAccess)" == "true" ]]; then
  if command -v op >/dev/null 2>&1; then
    if op whoami >/dev/null 2>&1; then
      ok "op signed in"
    else
      warn "op available but not signed in"
    fi
  else
    warn "op not found"
  fi
else
  ok "secret access disabled for profile"
fi

section "project roots"
for dir in "$HOME/src/personal" "$HOME/src/work" "$HOME/src/client" "$HOME/src/sandbox" "$HOME/src/agent"; do
  if [[ -d "$dir" ]]; then
    ok "exists: $dir"
  else
    warn "missing: $dir"
  fi
done

exit "$status"
