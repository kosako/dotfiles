#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

profile="${1:-personal}"

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
  # enableGitSigning gates the managed SSH-signing mechanism
  # (~/.config/git/signing.gitconfig: gpg.format=ssh + 1Password signer).
  # AGENTS.md requires a capability to drive a doctor section. The signing KEY
  # (user.signingkey) and the per-context commit.gpgsign opt-in live in the
  # local identity files (docs/git-identity.md), never in the managed mechanism.
  if [[ "$(capability_value "$profile" enableGitSigning)" == "true" ]]; then
    if module_active_for_profile "$profile" git-signing; then
      ok "enableGitSigning=true; SSH signing mechanism managed (signing.gitconfig); commit.gpgsign defaults off (managed), opt in per repo/context (local key + commit.gpgsign=true)"
    else
      warn "enableGitSigning=true but the git-signing module is inactive for this profile (signing mechanism not managed)"
    fi
  else
    ok "Git signing mechanism not managed (enableGitSigning=false)"
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
  for key in before ignore-scripts save-exact fund audit userconfig globalconfig; do
    value="$(npm config get "$key" 2>/dev/null || true)"
    item "npm $key=$value"
  done
  npm_major="${npm_version%%.*}"
  npm_minor="$(printf '%s' "$npm_version" | cut -d. -f2)"
  if [[ "$npm_major" -gt 11 || ( "$npm_major" -eq 11 && "$npm_minor" -ge 10 ) ]] 2>/dev/null; then
    ok "npm supports min-release-age (>= 11.10)"
  else
    warn "npm older than 11.10, min-release-age is not enforced"
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
EOF
    # npm consumes min-release-age and flattens it into `before` (now - <days>),
    # deleting the original key, so `npm config get min-release-age` is always
    # null even when honored. Verify the operative `before` cutoff is ~7 days
    # ago instead: a non-empty `before` alone is not enough (a shorter age, or a
    # hand-set far-future date, would also be non-empty but not enforce the
    # 7-day cooldown). node ships with npm, so it is available to parse npm's
    # Date string portably; an unparseable/empty value yields no epoch and fails
    # the window check below.
    npm_before="$(npm config get before 2>/dev/null || true)"
    npm_before_epoch=""
    if [[ -n "$npm_before" && "$npm_before" != "null" ]]; then
      npm_before_epoch="$(node -e 'const t=Date.parse(process.argv[1]||"");process.stdout.write(Number.isNaN(t)?"":String(Math.floor(t/1000)))' "$npm_before" 2>/dev/null || true)"
    fi
    if npm_before_within_age_window "$npm_before_epoch" "$(date +%s)" 7 43200; then
      ok "npm min-release-age=7 honored (before=$npm_before)"
    else
      warn "enforce expects npm min-release-age=7 (before ~= now-7d), current before=${npm_before:-unset} (apply pending?)"
    fi
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

section "software catalog (report-only)"
# Drift between packages.yaml and what is actually installed. report_catalog_drift
# is report-only (always returns 0) and skips any missing package manager;
# the only fail path in doctor stays the policy validation at the top.
report_catalog_drift || true

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

section "SSH (1Password agent)"
# enable1PasswordSSH gates the agent setting in the managed ~/.ssh/config
# (scoped to github.com, never Host *; the op socket path is public-safe).
# AGENTS.md requires a capability to drive a doctor section. Report-only and
# contents-blind: doctor never reads ~/.ssh/config or probes the agent socket.
# Machine-specific hosts/keys live in ~/.ssh/config.local (docs/ssh.md).
if [[ "$(capability_value "$profile" enable1PasswordSSH)" == "true" ]]; then
  if module_active_for_profile "$profile" ssh-1password; then
    ok "enable1PasswordSSH=true; managed ~/.ssh/config carries the 1Password agent for github.com (scoped, not Host *); machine-specific hosts go in ~/.ssh/config.local"
  else
    warn "enable1PasswordSSH=true but the ssh-1password module is inactive for this profile (no managed SSH config carries the agent setting; dangling capability)"
  fi
else
  ok "1Password SSH agent not managed (enable1PasswordSSH=false)"
fi

section "private-backup (report-only)"
# Report-only and contents-blind (issue #60). Resolve the PUBLIC baseline
# (backup-paths.yaml) and show whether each target exists; the local
# supplement is reported by EXISTENCE ONLY — never parsed, counted, or
# read, per docs/local-overrides.md. The state marker (repo-external)
# gives backup presence and last-success time. doctor never reads any
# captured file, the archive, or the supplement's contents.
if [[ ! -f "$BACKUP_PATHS_FILE" ]]; then
  warn "backup catalog missing: $BACKUP_PATHS_FILE"
elif ! baseline_rows="$(backup_paths 2>/dev/null)"; then
  # Capture first so a yq/parse failure becomes a warning instead of a
  # healthy-looking "0/0 present" (a failed process substitution would not
  # fail the while loop).
  warn "could not read backup catalog; skipping baseline resolution"
else
  baseline_present=0
  baseline_total=0
  while IFS='|' read -r _bp_type _bp_category bp_path; do
    [[ -z "$bp_path" ]] && continue
    baseline_total=$((baseline_total + 1))
    if [[ -e "$HOME/$bp_path" ]]; then
      item "baseline present: $bp_path"
      baseline_present=$((baseline_present + 1))
    else
      item "baseline absent: $bp_path"
    fi
  done <<< "$baseline_rows"
  ok "baseline targets: $baseline_present/$baseline_total present"
fi

# Local supplement: existence only. Do not parse, count, or read it.
backup_supplement="$HOME/.config/dotfiles/backup-paths.local"
if [[ -f "$backup_supplement" ]]; then
  item "local supplement present (contents not inspected)"
else
  item "local supplement absent"
fi

# State marker: presence + last success + basename + count, nothing else.
# The marker is repo-external and could be stale or hand-edited, so treat
# its fields as untrusted: drop non-printable chars, basename the archive,
# and require a numeric count — anything odd is shown as "unknown" rather
# than echoed verbatim to the terminal.
backup_marker="$HOME/.local/state/dotfiles/private-backup.json"
if [[ -f "$backup_marker" ]]; then
  bm() { yq -p=json -o=tsv "$1" "$backup_marker" 2>/dev/null | tr -dc '[:print:]' || true; }
  marker_last="$(bm '.last_success // ""')"
  marker_archive_raw="$(bm '.archive // ""')"
  marker_count="$(bm '.file_count // ""')"
  marker_archive="unknown"
  [[ -n "$marker_archive_raw" ]] && marker_archive="$(basename "$marker_archive_raw")"
  [[ "$marker_count" =~ ^[0-9]+$ ]] || marker_count="unknown"
  if [[ -n "$marker_last" ]]; then
    ok "last backup: $marker_last (archive: $marker_archive, files: $marker_count)"
  else
    warn "backup marker present but unreadable"
  fi
  unset -f bm
else
  warn "no backup recorded yet (run private-backup.sh backup)"
fi

section "managed-path orphans"
# A file that carries the managed-by header but whose path is not
# managed for this profile is likely left over from another profile
# (e.g. ~/.npmrc after switching personal -> work-minimal). Report
# only; nothing is removed. Only the header line is inspected.
orphan_count=0
while IFS= read -r module; do
  [[ -z "$module" ]] && continue
  while IFS= read -r managed_path; do
    [[ -z "$managed_path" ]] && continue
    target="$HOME/$managed_path"
    candidates=()
    if [[ -f "$target" ]]; then
      candidates=("$target")
    elif [[ -d "$target" ]]; then
      while IFS= read -r found_file; do
        candidates+=("$found_file")
      done < <(find "$target" -maxdepth 3 -type f 2>/dev/null)
    fi
    [[ "${#candidates[@]}" -eq 0 ]] && continue
    for candidate in "${candidates[@]}"; do
      grep -q "Managed by chezmoi" "$candidate" 2>/dev/null || continue
      if module_active_for_profile "$profile" "$module"; then
        item "managed and active: $candidate"
      else
        orphan_count=$((orphan_count + 1))
        warn "managed-by header but not managed for profile $profile: $candidate (orphan from another profile?)"
      fi
    done
  done < <(module_paths "$module")
done < <(known_modules)
if [[ "$orphan_count" -eq 0 ]]; then
  ok "no managed-path orphans"
fi

section "AI policy"
if [[ "$(capability_value "$profile" enableAiPolicy)" == "true" ]]; then
  ok "enableAiPolicy=true (policy docs + report-only checks; see docs/ai-policy.md)"
  item "boundary today: directory convention + Git identity separation + policy docs"
  if [[ -d "$HOME/src/agent" ]]; then
    ok "agent project root exists: $HOME/src/agent"
  else
    warn "agent project root missing: $HOME/src/agent"
  fi
else
  ok "AI policy checks disabled for profile"
fi
if [[ "$(capability_value "$profile" enableAiTools)" == "true" ]]; then
  warn "enableAiTools=true but the ai-tools module is not implemented yet (nothing is managed)"
else
  ok "AI tool install/sync not managed (enableAiTools=false)"
fi

# enforceAiSandbox drives the Claude Code native sandbox block in the managed
# ~/.claude/settings.json (Bash tool fs+network only; see
# docs/ai-environment-boundary.md). Reported here because AGENTS.md requires a
# capability to drive a doctor section, never a placeholder. It is a
# safety-hardening capability (opposite polarity to the install / secret /
# network / AI-tool capabilities), so it is intentionally absent from
# environment_kind_forbidden_capabilities. The sandbox block only reaches a
# real settings.json where the claude-settings module is active (personal
# today), so a true value without that module is reported as dangling.
if [[ "$(capability_value "$profile" enforceAiSandbox)" == "true" ]]; then
  if module_active_for_profile "$profile" claude-settings; then
    ok "enforceAiSandbox=true; Claude Code native sandbox managed in ~/.claude/settings.json (Bash tool fs+network only)"
  else
    warn "enforceAiSandbox=true but the claude-settings module is inactive for this profile; no managed settings carry the sandbox block (dangling capability)"
  fi
else
  ok "Claude Code native sandbox not enforced via managed settings (enforceAiSandbox=false)"
fi

section "agent-tools (report-only)"
# Report-only companion check. dotfiles never clones/pulls/syncs
# agent-tools. Presence is always reported, but running its status.sh
# (executing code from another repo) is opt-in via enableAgentToolsStatus
# so doctor's no-side-effects invariant is never delegated implicitly.
# See docs/ai-environment-boundary.md and the agent-tools
# status-manifest-contract (contract_version 2).
# The expected path defaults to the dotfiles directory convention
# (~/src/agent/agent-tools) but is overridable via the AGENT_TOOLS env so a
# non-standard checkout can still be reported. presence only; never cloned.
if [[ "$(capability_value "$profile" enableAiPolicy)" != "true" ]]; then
  ok "AI policy disabled; skipping agent-tools check"
else
  agent_tools_dir="${AGENT_TOOLS:-$HOME/src/agent/agent-tools}"
  agent_tools_status="$agent_tools_dir/scripts/status.sh"
  if [[ ! -d "$agent_tools_dir" ]]; then
    warn "agent-tools not present at $agent_tools_dir (not auto-cloned)"
  elif [[ "$(capability_value "$profile" enableAgentToolsStatus)" != "true" ]]; then
    ok "agent-tools present; status read disabled (set enableAgentToolsStatus=true to let doctor run its status.sh)"
  elif [[ ! -x "$agent_tools_status" ]]; then
    warn "agent-tools present but scripts/status.sh is missing or not executable"
  elif ! status_json="$("$agent_tools_status" --json 2>/dev/null)" || [[ -z "$status_json" ]]; then
    warn "agent-tools status.sh produced no usable output (skipping summary)"
  else
    # Null-safe queries plus `|| true` keep doctor report-only even if
    # the JSON is malformed (a failed substitution would trip set -e).
    sj() { printf '%s' "$status_json" | yq -p json "$1" 2>/dev/null || true; }
    contract_version="$(sj '.contract_version // ""')"
    if [[ "$contract_version" != "2" ]]; then
      warn "agent-tools status contract_version=${contract_version:-unknown}, expected 2 (not interpreting fields)"
    else
      ok "agent-tools present; status contract v2"

      if [[ "$(sj '.repo.clean // false')" == "true" ]]; then
        ok "agent-tools working tree clean"
      else
        warn "agent-tools working tree not clean"
      fi

      item "assets: $(sj '.assets.total // 0') (manifest errors: $(sj '.assets.manifest_errors // 0'))"
      if [[ "$(sj '.assets.manifest_errors // 0')" != "0" ]]; then
        warn "agent-tools manifest validation errors present"
      fi

      for check in manifest_validation prompt_injection_static; do
        result="$(sj ".checks.$check // \"not_run\"")"
        if [[ "$result" == "pass" ]]; then
          ok "check $check: pass"
        else
          warn "check $check: $result"
        fi
      done

      item "generated: $(sj '.generated.total // 0') (stale: $(sj '.generated.stale // 0'))"
      if [[ "$(sj '.generated.stale // 0')" != "0" ]]; then
        warn "agent-tools has stale generated artifacts"
      fi

      if [[ "$(sj '.register.catalog_present // false')" == "true" ]]; then
        item "register: registered=$(sj '.register.registered // 0') human_review=$(sj '.register.human_review_required // 0') unsupported=$(sj '.register.unsupported // 0')"
        if [[ "$(sj '.register.human_review_required // 0')" != "0" ]]; then
          warn "agent-tools assets require human review"
        fi
      else
        item "register: catalog not present"
      fi

      item "sync targets: $(sj '.sync_targets // [] | length')"
      if [[ "$(sj '[.sync_targets[]? | select(.state == "conflict")] | length')" != "0" ]]; then
        warn "agent-tools sync conflicts (unmanaged same-name targets); sync must not change them"
      fi
      if [[ "$(sj '[.sync_targets[]? | select(.state == "stale")] | length')" != "0" ]]; then
        warn "agent-tools has stale sync targets (generated artifact newer than target)"
      fi
    fi
    unset -f sj
  fi
fi

section "network tunnels"
allow_tunnels="$(capability_value "$profile" allowNetworkTunnels)"
ok "allowNetworkTunnels=$allow_tunnels"
tunnel_tools_found=0
for tunnel_tool in tailscale cloudflared ngrok zerotier-cli; do
  command -v "$tunnel_tool" >/dev/null 2>&1 || continue
  tunnel_tools_found=$((tunnel_tools_found + 1))
  if [[ "$allow_tunnels" == "true" ]]; then
    item "tunnel tool present: $tunnel_tool"
  else
    warn "tunnel tool present but allowNetworkTunnels=false: $tunnel_tool (not removed automatically)"
  fi
done
if [[ "$tunnel_tools_found" -eq 0 ]]; then
  ok "no tunnel tools found"
fi

section "project roots"
for dir in "$HOME/src/personal" "$HOME/src/work" "$HOME/src/client" "$HOME/src/sandbox" "$HOME/src/agent"; do
  if [[ -d "$dir" ]]; then
    ok "exists: $dir"
  else
    warn "missing: $dir"
  fi
done

# doctor is report-only: warnings never change the exit code.
# The only non-zero path is the policy validation at the top.
exit 0
