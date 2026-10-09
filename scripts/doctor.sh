#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

# Arguments: [PROFILE] [--actions-only]. --actions-only mutes every report
# line except [fail] and the closing next-actions summary (#227), so the
# list of things to run can be read (or redirected) without scanning the
# full report. doctor writes no file itself: it stays report-only.
profile=""
profile_given=0
actions_only=0
for doctor_arg in "$@"; do
  case "$doctor_arg" in
    --actions-only) actions_only=1 ;;
    -*)
      # Any other dash-word is rejected HERE, before the validator sees it:
      # a `-h` would otherwise reach validate-policy's help branch, skip the
      # validation and run the report against a profile named "-h" (Codex
      # review, PR #228).
      fail "unknown option: $doctor_arg (usage: doctor.sh [PROFILE] [--actions-only])"
      exit 2
      ;;
    *)
      # A second profile is rejected rather than silently replacing the
      # first, so a typo never reads as the intended profile's report
      # (preflight does the same, #309; #329).
      if [[ "$profile_given" -eq 1 ]]; then
        fail "too many arguments (usage: doctor.sh [PROFILE] [--actions-only])"
        exit 2
      fi
      profile="$doctor_arg"
      profile_given=1
      ;;
  esac
done
profile="${profile:-personal}"
if [[ "$actions_only" -eq 1 ]]; then
  # Read by the report helpers in lib-policy.sh (ok / item / warn ...).
  export POLICY_REPORT_QUIET=1
fi

section "doctor profile: $profile"

section "policy"
# Under --actions-only the validator's own [ok] lines are muted too; its
# [fail] lines go to stderr and stay visible, and a failure still exits 1.
if [[ "$actions_only" -eq 1 ]]; then
  run_policy_validation "$profile" >/dev/null || exit 1
else
  run_policy_validation "$profile" || exit 1
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
  ok "chezmoi: $(display_safe "$(chezmoi --version 2>/dev/null | head -n 1)")"
else
  warn "chezmoi not found"
fi
ok "source directory: $(display_safe "$DOTFILES_ROOT")"

section "Git"
if command -v git >/dev/null 2>&1; then
  ok "git: $(display_safe "$(git --version 2>/dev/null)")"
  use_config_only="$(git config --global --get user.useConfigOnly 2>/dev/null || true)"
  credentials_in_url="$(git config --global --get transfer.credentialsInUrl 2>/dev/null || true)"
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
  # git-ignore module (#248): the managed global gitignore sits at git's
  # DEFAULT excludes location (~/.config/git/ignore), which git reads only
  # while core.excludesFile is unset — in the global AND the system scope
  # (system-only values count; Codex review) — and XDG_CONFIG_HOME does not
  # redirect it. An explicitly EMPTY core.excludesFile is not "unset": git
  # then reads no global excludes file at all. The managed ~/.gitconfig
  # deliberately does not pin core.excludesFile: an explicit value would
  # silently override a host's own excludesFile (an unmanaged
  # ~/.config/git/config on a work machine). So doctor reports whether the
  # managed file is the one git actually reads (git_excludes_file_setting,
  # shared with preflight), and whether it still carries the agent
  # local-only patterns. Patterns are checked as exact lines: `git
  # check-ignore` needs a repository and doctor creates nothing; the real
  # ignore behaviour is pinned by test-git-ignore.sh.
  if module_active_for_profile "$profile" git-ignore; then
    managed_ignore="$HOME/.config/git/ignore"
    excludes_setting="$(git_excludes_file_setting)"
    case "$excludes_setting" in
      unset) effective_ignore="$(git_default_excludes_file)" ;;
      path\ *) effective_ignore="${excludes_setting#path }" ;;
      *) effective_ignore="" ;;
    esac
    if [[ ! -f "$managed_ignore" ]]; then
      action "global gitignore missing: $managed_ignore (git-ignore module) — agent local-only files (.agent-packets/, .claude/settings.local.json) are excluded only where a repo's own .gitignore says so" \
        "\$ mkdir -p $(shell_quote_safe "$HOME/.config")" \
        "\$ chezmoi apply $(shell_quote_safe "$HOME/.config/git") $(shell_quote_safe "$managed_ignore")"
    elif [[ "$excludes_setting" == error ]]; then
      warn "global gitignore: git cannot read its global/system config (core.excludesFile lookup failed), so whether the managed $managed_ignore is in effect is unknown — fix the config error first (git config --global --list / git config --system --list)"
    elif [[ "$excludes_setting" == empty ]]; then
      warn "global gitignore: core.excludesFile is explicitly empty (global or system config), so git reads NO global excludes file — the managed $managed_ignore is not in effect; unset the key to restore git's default location"
    elif [[ "$effective_ignore" != "$managed_ignore" && ! "$effective_ignore" -ef "$managed_ignore" ]]; then
      warn "global gitignore: git reads $(display_safe "$effective_ignore"), not the managed $managed_ignore (core.excludesFile in the global or system config, or XDG_CONFIG_HOME, redirects it) — the managed agent local-only patterns are not in effect"
    else
      missing_ignore_patterns=""
      for ignore_pattern in '.agent-packets/' '**/.claude/settings.local.json'; do
        grep -Fxq -- "$ignore_pattern" "$managed_ignore" \
          || missing_ignore_patterns="${missing_ignore_patterns:+$missing_ignore_patterns }$ignore_pattern"
      done
      if [[ -z "$missing_ignore_patterns" ]]; then
        ok "global gitignore: managed $managed_ignore is what git reads; excludes .agent-packets/ and **/.claude/settings.local.json in every repo"
      else
        action "global gitignore: $managed_ignore lacks: $missing_ignore_patterns (drifted from the managed file)" \
          "\$ chezmoi apply $(shell_quote_safe "$managed_ignore")"
      fi
    fi
  else
    ok "global gitignore not managed (git-ignore module inactive for profile $profile)"
  fi
else
  warn "git not found"
fi

# enableGitHookGates wires the commit-boundary git hook gates (#196): thin
# shims in ~/.config/git-hook-gates/hooks exec agent-tools'
# personal-git-hook-dispatcher (pre-commit -> public-safety gate then
# git-identity gate, commit-msg -> AI trailer gate, then chain to the repo's
# own .git/hooks), and global
# core.hooksPath points at the shim directory via the unconditional include in
# the managed ~/.gitconfig. The wiring is a TWO-KEY gate: the capability
# (intent) AND a complete agent-tools deploy in the destination (readiness;
# the templates render empty otherwise). Report the whole chain honestly:
# shims + hooksPath are dotfiles' side, the four gate scripts are
# agent-tools'. The dispatcher is FAIL-CLOSED (exit 2) when a gate NEXT TO IT
# is missing — the readiness check must cover all four scripts, not just the
# dispatcher, or a partial deploy shows green while commits are blocked
# (Codex review, PR #197; the pre-commit stage gained personal-git-identity-
# gate in agent-tools#281, so the list grew from three to four in #239 —
# keep it identical to .chezmoitemplates/git-hook-gates-armed and
# preflight.sh). Best-effort guardrail, NOT an enforcement boundary:
# --no-verify and a repo-local core.hooksPath (husky etc.) bypass it
# (docs/git-hook-gates.md).
section "git hook gates (report-only)"
hook_gates_dir="$HOME/.config/git-hook-gates"
hook_gates_deploy_dir="$HOME/.claude/agent-tools/scripts"
hook_gates_scripts=(personal-git-hook-dispatcher personal-public-safety-gate personal-git-identity-gate personal-ai-trailer-gate)
hook_gates_deploy_complete=1
for hook_gates_script in "${hook_gates_scripts[@]}"; do
  [[ -x "$hook_gates_deploy_dir/$hook_gates_script" ]] || hook_gates_deploy_complete=0
done
if [[ "$(capability_value "$profile" enableGitHookGates)" == "true" ]]; then
  if module_active_for_profile "$profile" git-hook-gates; then
    hook_gates_wired=1
    for hook_stage in pre-commit commit-msg; do
      if [[ -x "$hook_gates_dir/hooks/$hook_stage" ]]; then
        ok "shim present and executable: $hook_gates_dir/hooks/$hook_stage"
      else
        warn "shim missing or not executable: $hook_gates_dir/hooks/$hook_stage (chezmoi apply arms it once the agent-tools deploy is complete)"
        hook_gates_wired=0
      fi
    done
    if command -v git >/dev/null 2>&1; then
      # --includes is load-bearing: the value lives in the INCLUDED
      # hooks.gitconfig, and `git config --global --get` skips includes by
      # default when a scope file is given — without the flag a correctly
      # wired machine misreports as unwired (found in the #196 live smoke).
      hook_gates_path="$(git config --global --includes --get core.hooksPath 2>/dev/null || true)"
      # shellcheck disable=SC2088 # the first pattern is the literal value stored in gitconfig (git expands the tilde, not the shell)
      case "$hook_gates_path" in
        "~/.config/git-hook-gates/hooks" | "$hook_gates_dir/hooks")
          ok "global core.hooksPath -> managed shim directory"
          ;;
        "")
          action "global core.hooksPath is not set (chezmoi apply arms it via the ~/.gitconfig include once the agent-tools deploy is complete)" \
            "\$ chezmoi apply   # after agent-tools has deployed the dispatcher + gates (docs/git-hook-gates.md)"
          hook_gates_wired=0
          ;;
        *)
          warn "global core.hooksPath points somewhere else (value not shown); the managed gates are NOT on the commit path"
          hook_gates_wired=0
          ;;
      esac
    else
      warn "git not found, cannot check core.hooksPath"
      hook_gates_wired=0
    fi
    if [[ "$hook_gates_deploy_complete" -eq 1 ]]; then
      ok "agent-tools deploy complete: dispatcher + all three gates executable in $hook_gates_deploy_dir (bodies owned by agent-tools sync)"
    elif [[ "$hook_gates_wired" -eq 1 ]]; then
      warn "agent-tools deploy INCOMPLETE while the hooks are wired: git commit is BLOCKED fail-closed until agent-tools sync restores the dispatcher and all three gates in $hook_gates_deploy_dir — or set enableGitHookGates=false and apply"
    else
      warn "agent-tools deploy incomplete (dispatcher and/or a gate missing in $hook_gates_deploy_dir; agent-tools sync deploys them) and the wiring is also incomplete — commit behavior may be stage-dependent or blocked until sync and apply both complete"
    fi
    item "best-effort guardrail: git commit --no-verify and a repo-local core.hooksPath (husky etc.) bypass the gates (docs/git-hook-gates.md)"
  else
    warn "enableGitHookGates=true but the git-hook-gates module is inactive for this profile (shims and hooksPath not managed — dangling capability)"
  fi
else
  # Disabled is only honest if no wiring lingers from before the flip: a
  # leftover hooksPath/shim pair still routes (or blocks) every commit until
  # it is removed (Codex review, PR #197). The next apply prunes it only where
  # the git-hook-gates module is active (template self-gate); after a profile
  # switch the module is unlisted, .chezmoiignore skips the targets and apply
  # never touches them, so the remedy is removing them by hand (#201, #258).
  hook_gates_lingering=0
  for hook_stage in pre-commit commit-msg; do
    [[ -e "$hook_gates_dir/hooks/$hook_stage" ]] && hook_gates_lingering=1
  done
  if command -v git >/dev/null 2>&1; then
    # --includes for the same reason as the enabled branch above.
    hook_gates_path="$(git config --global --includes --get core.hooksPath 2>/dev/null || true)"
    # shellcheck disable=SC2088 # literal gitconfig value comparison, as above
    case "$hook_gates_path" in
      "~/.config/git-hook-gates/hooks" | "$hook_gates_dir/hooks") hook_gates_lingering=1 ;;
    esac
  fi
  if [[ "$hook_gates_lingering" -eq 1 ]] && module_active_for_profile "$profile" git-hook-gates; then
    action "enableGitHookGates=false but gate wiring lingers (shim and/or core.hooksPath still present) — run chezmoi apply to prune it" \
      "\$ chezmoi apply"
  elif [[ "$hook_gates_lingering" -eq 1 ]]; then
    hook_gates_leftovers=""
    for hook_gates_file in "$hook_gates_dir/hooks.gitconfig" "$hook_gates_dir/hooks/pre-commit" "$hook_gates_dir/hooks/commit-msg"; do
      [[ -e "$hook_gates_file" ]] && hook_gates_leftovers+=" $(shell_quote_safe "$hook_gates_file")"
    done
    if [[ -n "$hook_gates_leftovers" ]]; then
      action "enableGitHookGates=false but gate wiring lingers (shim and/or core.hooksPath still present), left by another profile — this profile does not manage ~/.config/git-hook-gates, so chezmoi apply will NOT remove it (#201); remove it by hand" \
        "\$ rm -i$hook_gates_leftovers" \
        "\$ git config --global --includes --show-origin --get core.hooksPath   # must no longer point at ~/.config/git-hook-gates/hooks; if it still does, remove that line at the origin shown"
    else
      action "enableGitHookGates=false but global core.hooksPath still points at the managed shim directory, set outside the managed include — this profile does not manage ~/.config/git-hook-gates, so chezmoi apply will NOT change it (#201)" \
        "\$ git config --global --includes --show-origin --get core.hooksPath   # find where it is set, then remove that line"
    fi
  else
    ok "git hook gates not wired (enableGitHookGates=false)"
  fi
fi

section "Git identity contexts"
# The managed identity reset (#202) is what makes a missing / empty context
# file fail closed: ~/.gitconfig includes it before each non-personal context
# file, and Git silently ignores a missing include. A partial apply (README
# Quickstart step 3 used to apply ~/.gitconfig alone, #241) therefore leaves
# the personal remote fallback leaking into work / client / sandbox / agent
# repos without any error. Presence-only check; the remedy is the same apply
# the Quickstart names (the parent directory target is required).
identity_reset_file="$HOME/.config/git-profile/identity-reset.gitconfig"
identity_reset_present=1
if module_active_for_profile "$profile" git-profile; then
  if [[ -f "$identity_reset_file" ]]; then
    ok "identity reset file present: $identity_reset_file (non-personal contexts fail closed without a context file)"
  else
    identity_reset_present=0
    # Two steps: chezmoi does not create ancestors outside the target set, so
    # on a home without ~/.config the apply alone fails (README Quickstart
    # step 3 has the same mkdir for the same reason).
    action "identity reset file missing: $identity_reset_file — the fail-closed boundary of #202 is NOT in place: in a non-personal repo without its context file, a remote matching the personal patterns (hasconfig in ~/.gitconfig) inherits the personal identity instead of refusing to commit (other repos are still refused by useConfigOnly)" \
      "\$ mkdir -p $(shell_quote_safe "$HOME/.config")" \
      "\$ chezmoi apply $(shell_quote_safe "${identity_reset_file%/*}") $(shell_quote_safe "$identity_reset_file")"
  fi
else
  item "identity reset not managed for this profile (git-profile module inactive)"
fi
# An existing identity file is also checked for COMPLETENESS, presence-only:
# `git config --file` tells whether user.name / user.email are set and
# non-empty; the values are never printed. A partial file is the one state the
# managed identity reset (#202) cannot fail close — Git refuses an empty name
# but accepts an empty email (the action below describes Git itself). doctor
# reports it before any commit; at commit time only the git hook gates'
# git-identity gate refuses it, where those gates are armed (#239). Elsewhere
# commits under that root carry an empty ident, visibly broken rather than
# another context's identity. A file git cannot parse is reported as such, not
# as partial.
for context in personal work client sandbox agent; do
  identity_file="$HOME/.config/git/$context.gitconfig"
  project_root="$HOME/src/$context"
  if [[ -f "$identity_file" ]]; then
    if ! command -v git >/dev/null 2>&1; then
      ok "identity file exists: $identity_file (completeness not checked: git not found)"
    elif ! git config --file "$identity_file" --list >/dev/null 2>&1; then
      warn "identity file exists but git cannot parse it: $identity_file (syntax error?) — commits under $project_root fail until it is fixed"
    else
      # Two kinds of "no value": a key that is UNSET (git config --get exits
      # 1) and a key set to an explicit EMPTY value (exits 0, prints nothing).
      # With the reset in place both yield an empty ident. Without it they
      # differ: an explicit empty value still overrides whatever applied
      # before, but an unset key keeps it — the personal identity, in a repo
      # whose remote matches the personal patterns. The value itself is never
      # printed (key names only).
      # A third kind: a key with NO value at all (`name` on a line by itself,
      # git's boolean shorthand). `--get` prints an empty string for it too,
      # but git's identity reader rejects it outright ("missing value for
      # 'user.email'", fatal), so it is neither empty nor unset — it breaks
      # every commit under the root regardless of the reset. `--list` shows
      # such a key without "=", which is how it is told apart here (the
      # listing is only grepped, never printed).
      identity_missing=""
      identity_unset=""
      identity_bare=""
      # Capture the listing once, then grep the variable: a `git | grep -q`
      # pipe would let grep exit on the first match and leave git to die of
      # SIGPIPE on a large file, and under pipefail that reads as "no match"
      # (Codex review, PR #250 — same trap as module_active_for_profile).
      identity_listing="$(git config --file "$identity_file" --list 2>/dev/null || true)"
      for identity_key in name email; do
        if grep -Fxq -- "user.$identity_key" <<< "$identity_listing"; then
          identity_bare+="${identity_bare:+ }user.$identity_key"
        elif identity_value="$(git config --file "$identity_file" --get "user.$identity_key" 2>/dev/null)"; then
          [[ -n "$identity_value" ]] || identity_missing+="${identity_missing:+ }user.$identity_key"
        else
          identity_missing+="${identity_missing:+ }user.$identity_key"
          identity_unset+="${identity_unset:+ }user.$identity_key"
        fi
      done
      identity_value=""
      identity_listing=""
      if [[ -n "$identity_bare" ]]; then
        action "identity file has a key without a value: $identity_file ($identity_bare) — git rejects the whole identity (fatal: missing value), so commits under $project_root fail until it is fixed" \
          "give $identity_bare a value in $identity_file, or remove the line (local-only, never managed; docs/git-identity.md)"
      elif [[ -z "$identity_missing" ]]; then
        ok "identity file exists: $identity_file"
      elif [[ "$identity_reset_present" -eq 1 || "$context" == "personal" || -z "$identity_unset" ]]; then
        action "identity file is partial: $identity_file has no $identity_missing — commits under $project_root get an empty ident (a missing name is refused; a missing email is accepted as <> and shows as no-identity in the prompt)" \
          "set $identity_missing in $identity_file (local-only, never managed; docs/git-identity.md); until then a missing email is refused at commit time only where the git hook gates' git-identity gate is armed (#239)"
      else
        # Inheritance and the commit outcome are separate facts: an unset
        # key inherits, but an explicitly empty NAME still refuses the commit
        # (Git rejects an empty name; an empty email is accepted as <>).
        identity_outcome="a mixed identity that is not refused"
        case " $identity_missing " in
          *" user.name "*)
            case " $identity_unset " in
              *" user.name "*) ;;
              *) identity_outcome="but the commit is still refused because user.name is explicitly empty" ;;
            esac
            ;;
        esac
        action "identity file is partial: $identity_file has no $identity_missing (and the identity reset is missing: the unset $identity_unset inherits the personal identity in a repo under $project_root whose remote matches the personal patterns — $identity_outcome; an explicitly empty key stays empty)" \
          "set $identity_missing in $identity_file (local-only, never managed; docs/git-identity.md) and apply the identity reset (see above)"
      fi
    fi
  elif [[ -d "$project_root" ]]; then
    if [[ "$identity_reset_present" -eq 1 || "$context" == "personal" ]]; then
      action "project root exists but identity file missing: $identity_file" \
        "create $identity_file with the [user] name/email for the $context context (local-only, never managed; docs/git-identity.md) — commits under $project_root are refused until then"
    else
      action "project root exists but identity file missing: $identity_file (and the identity reset is missing too: a repo under $project_root whose remote matches the personal patterns inherits the personal identity instead of being refused; other repos are still refused)" \
        "create $identity_file with the [user] name/email for the $context context (local-only, never managed; docs/git-identity.md) and apply the identity reset (see above)"
    fi
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
  remote_scan_failures=0
  for root in "$DOTFILES_ROOT" "$HOME/src/personal" "$HOME/src/work" "$HOME/src/client" "$HOME/src/sandbox" "$HOME/src/agent"; do
    [[ -d "$root" ]] || continue
    # A listing that fails (the root itself or a dir under it cannot be
    # opened) is INCOMPLETE, not empty: the markers it did print are still
    # scanned, the rest is named as not checked (#359).
    if ! repo_markers="$(find "$root" -maxdepth 4 -name .git -prune -print 2>/dev/null)"; then
      remote_scan_failures=$((remote_scan_failures + 1))
      warn "remote URL scan INCOMPLETE: repositories under $(display_safe "$root") could not be listed completely (permission denied or a symlink loop?); the repos it did not list are not checked"
    fi
    while IFS= read -r git_marker; do
      [[ -z "$git_marker" ]] && continue
      repo="$(dirname "$git_marker")"
      # A remote config that cannot be read is not a scan result: the repo is
      # named as not checked and left out of the scanned count (#359).
      if ! remote_hits="$(git_remotes_with_credentials "$repo")"; then
        remote_scan_failures=$((remote_scan_failures + 1))
        warn "remote URL scan INCOMPLETE: the remote config of repo=$(display_safe "$repo") could not be read (permission denied, not a repository, a dangling gitdir pointer or an unparsable config?); its remotes not checked"
        continue
      fi
      scanned_repos=$((scanned_repos + 1))
      while IFS= read -r remote_name; do
        [[ -z "$remote_name" ]] && continue
        flagged_remotes=$((flagged_remotes + 1))
        warn "credential-like userinfo in remote URL: repo=$(display_safe "$repo") remote=$(display_safe "$remote_name") (URL not shown)"
      done <<< "$remote_hits"
    done <<< "$repo_markers"
  done
  ok "scanned repositories: $scanned_repos"
  if [[ "$flagged_remotes" -gt 0 ]]; then
    warn "remotes with credential-like userinfo: $flagged_remotes"
  fi
  if [[ "$remote_scan_failures" -gt 0 ]]; then
    warn "remote URL scan INCOMPLETE: $remote_scan_failures root(s) / repo(s) could not be listed or read (see above); do NOT read this as clean"
  elif [[ "$flagged_remotes" -eq 0 ]]; then
    ok "no credential-like userinfo in remote URLs"
  fi
fi

section "npm hardening"
npm_mode="$(capability_value "$profile" npmHardeningMode)"
ok "npmHardeningMode=$npm_mode"
if [[ "$npm_mode" == "off" ]]; then
  ok "npm hardening intentionally unmanaged"
elif ! command -v npm >/dev/null 2>&1; then
  warn "npm not found"
elif ! npm_version="$(npm --version 2>/dev/null)" || [[ -z "$npm_version" ]]; then
  # A mise shim resolves on PATH even when no node runtime is installed; the
  # unguarded probe used to kill the whole doctor here via set -e, breaking
  # the report-only contract (#144).
  warn "npm on PATH but not runnable (shim without a runtime?); skipping npm checks"
else
  ok "npm: $(display_safe "$npm_version")"
  for key in before ignore-scripts save-exact fund audit userconfig globalconfig; do
    value="$(npm config get "$key" 2>/dev/null || true)"
    item "npm $key=$(display_safe "$value")"
  done
  npm_major="${npm_version%%.*}"
  npm_minor="$(printf '%s' "$npm_version" | LC_ALL=C cut -d. -f2 2>/dev/null)"
  # Guard before the arithmetic test: [[ -gt ]] evaluates its operands as
  # arithmetic, so a non-numeric component resolves as a variable name and
  # aborts the shell under set -u (the old 2>/dev/null hid even that) (#144).
  if [[ ! "$npm_major" =~ ^[0-9]+$ || ! "$npm_minor" =~ ^[0-9]+$ ]]; then
    warn "npm version '$(display_safe "$npm_version")' not recognized; cannot check min-release-age support"
  elif [[ "$npm_major" -gt 11 || ( "$npm_major" -eq 11 && "$npm_minor" -ge 10 ) ]]; then
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
        warn "enforce expects npm $key=$expected, current: $(display_safe "$actual") (apply pending?)"
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
      ok "npm min-release-age=7 honored (before=$(display_safe "$npm_before"))"
    else
      warn "enforce expects npm min-release-age=7 (before ~= now-7d), current before=$(display_safe "${npm_before:-unset}") (apply pending?)"
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
  ok "corepack: $(display_safe "$(corepack --version 2>/dev/null || true)")"
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
# report_go_install_target — where `go install` puts binaries here. The
# managed mise config leaves GOBIN unset (go.set_gobin = false) so the
# software catalog's go_install tools land in ~/go/bin, the path the managed
# statusLine and agent-tools usage reader run tacho from (#305). Anything
# else (a GOBIN exported by a shell activated before the config was applied,
# or GOBIN / GOPATH set elsewhere) means install-packages.sh installs where
# those never look. Report-only.
# fold_slashes PATH — print PATH with each run of `/` folded to one and a
# trailing `/` dropped, so two spellings of one directory compare equal
# without touching the filesystem. The replacement is a variable: bash 3.2
# keeps the backslash of a literal `\/` in it.
fold_slashes() {
  local dir="$1" slash=/
  while [[ "$dir" == *//* ]]; do
    dir="${dir//\/\//$slash}"
  done
  printf '%s' "${dir%/}"
}
report_go_install_target() {
  local target home_dir
  home_dir="${HOME%/}"
  # PATH first: it matters (go-installed tools by name) whether or not Go
  # itself is here or answers.
  case ":$PATH:" in
    *":$home_dir/go/bin:"*) ;;
    *) item "PATH here lacks ~/go/bin, so go-installed tools do not resolve by name (the managed ~/.zshenv appends it; open a new shell)" ;;
  esac
  if ! command -v go >/dev/null 2>&1; then
    item "go not on PATH; go install target not checked"
    return 0
  fi
  if ! target="$(go_bin_dir)"; then
    warn "go install target could not be determined (go env failed or gave an unusable path); not checked against ~/go/bin"
    return 0
  fi
  # go env returns GOBIN as spelled, so the same directory can come back with
  # a trailing `/` or a doubled `//` (#329): compare the two with those
  # folded away, or as the same directory (-ef), like the other sections.
  if [[ "$(fold_slashes "$target")" == "$(fold_slashes "$home_dir/go/bin")" || "$target" -ef "$home_dir/go/bin" ]]; then
    ok "go install target: ~/go/bin (catalog go_install tools land where the managed statusLine and usage reader run them)"
  else
    # An action, not a warn: it must reach --actions-only, and ahead of the
    # usage reader's install-packages step (later section), because the
    # installer judges "installed" by this same target and would skip a
    # tool already sitting in the old one.
    action "go install target is $(display_safe "$target"), not ~/go/bin — catalog go_install tools (e.g. tacho for the statusLine and the usage reader) land outside the managed path, and install-packages.sh judges them installed there" \
      "\$ chezmoi apply $(shell_quote_safe "$home_dir/.config/mise/config.toml") $(shell_quote_safe "$home_dir/.zshenv")   # leaves GOBIN unset; ~/go/bin on PATH" \
      "\$ exec env -u GOBIN -u GOPATH zsh -l   # a new shell: an exported GOBIN / GOPATH is inherited otherwise (go.set_gobin only stops mise from setting it)" \
      "# and do not set GOBIN / GOPATH elsewhere (e.g. ~/.zshrc.local); then re-run doctor"
  fi
}
if [[ "$(capability_value "$profile" enableRuntimeManagement)" == "true" ]]; then
  command_status mise || true
  report_go_install_target
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

# ---- bounded external-command probe ----
# doctor asks a few external commands for an answer it wants but must not
# wait for forever: a signed-out `op whoami` blocks on the 1Password app's
# unlock prompt (#231), a broken herdr could block likewise (#225). The
# rule, set by the herdr section under Codex review (PR #226) and shared
# here since #231: every such probe runs under one deadline, reads no
# terminal input, uses no temp file (a failing mktemp must not break the
# report-only contract), and its output is adopted only on a clean exit 0
# (or an exit status whose output the probed command's contract defines).
# A command that gives no exit status in time (hung, so killed at the
# deadline) is reported as "not checked", never as a partial answer read as
# a definite one; what a prompt non-zero exit means is the caller's call
# (herdr: currency not checked; op: not signed in). At the deadline, and
# when doctor itself is interrupted, the probe's whole process tree is
# reaped.
#
# bounded_probe CMD [ARG...]
# Run CMD with stdin from /dev/null and stderr discarded for at most
# $probe_deadline seconds. On return, probe_rc holds CMD's exit status ("" when
# none arrived in time: killed at the deadline) and probe_lines its stdout
# (newline-terminated lines, blank lines dropped) — complete only when
# probe_rc is set; callers adopt it on 0 (the usage reader also reads the
# reason line of its contract's exit 2).
probe_deadline=5
probe_job=""
probe_launching=0
probe_rc=""
probe_lines=""
# kill_process_tree PID — SIGTERM then SIGKILL PID and every descendant
# (children first, via pgrep -P), so a wrapper on PATH that forked the real
# work does not leave an orphan behind the deadline.
kill_process_tree() {
  local pid="$1" child
  while IFS= read -r child; do
    [[ -n "$child" ]] && kill_process_tree "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill -TERM "$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
}
# probe_cleanup — reap the probe's process substitution (and thus the probe
# and anything it forked) if it is still alive; also the INT / TERM / EXIT
# handler below, so an interrupted doctor leaves no probe behind. The probe
# is identified by the substitution's pid, which bash exposes as $! the
# moment `exec 3< <(...)` returns, so there is no window in which the probe
# exists but is unknown: an interrupt landing before `probe_job` is
# assigned finds it through $! — trusted only while the launch is in flight
# AND it is a live child of this doctor, because a stale $! from an earlier
# process substitution could have been reused by an unrelated process. bash
# 3.2 errors on an unset $! under set -u, so it is read in a subshell with
# -u off (Codex review, PR #226 rounds 3-4).
probe_cleanup() {
  local job
  job="$probe_job"
  if [[ -z "$job" && "$probe_launching" == 1 ]]; then
    job="$( ( set +u; printf '%s' "$!" ) 2>/dev/null || true)"
    if [[ -n "$job" ]] && ! pgrep -P $$ 2>/dev/null | grep -qx "$job"; then
      job=""
    fi
  fi
  if [[ -n "$job" ]] && kill -0 "$job" 2>/dev/null; then
    kill_process_tree "$job"
  fi
  probe_job=""
  return 0
}
trap probe_cleanup EXIT
trap 'probe_cleanup; trap - INT; kill -INT $$' INT
trap 'probe_cleanup; trap - TERM; kill -TERM $$' TERM
# Bounded run WITHOUT a temp file: the probe's stdout comes through a
# process substitution whose subshell appends the probe's exit status as a
# status line (a per-call nonce, then the status), preceded by a newline of
# its own so an output that ends
# without one cannot swallow it (the blank line that adds is dropped); each
# read carries the remaining deadline. A read that fails while the deadline
# has not produced the status line is the deadline (bash 3.2's read -t
# returns 1 there, 4+ returns >128, so neither status is relied on): the
# tree is killed and nothing is adopted. Only output whose status line was
# seen is adopted: a clean exit 0, or a non-zero exit whose output the probed
# command's contract defines (the usage reader's exit 2 reason line).
bounded_probe() {
  local started remaining line sentinel
  probe_rc=""
  probe_lines=""
  started=$SECONDS
  # The exit-status line carries a per-call nonce the probed command never
  # sees (it is not exported), so a line it prints cannot pass for its own
  # exit status (#335; a forged `__rc=0` read as a pass, any other text was
  # shown raw).
  sentinel="__doctor_probe_rc_${RANDOM}${RANDOM}${RANDOM}_$$="
  probe_launching=1
  exec 3< <({ if "$@" 2>/dev/null </dev/null; then printf '\n%s0\n' "$sentinel"; else printf '\n%s%s\n' "$sentinel" "$?"; fi; } 2>/dev/null)
  probe_job=$!
  probe_launching=0
  while :; do
    remaining=$(( probe_deadline - (SECONDS - started) ))
    (( remaining > 0 )) || break
    IFS= read -r -t "$remaining" line <&3 || break
    case "$line" in
      "$sentinel"*) probe_rc="${line#"$sentinel"}"; break ;;
      "") ;;
      *) probe_lines+="$line"$'\n' ;;
    esac
  done
  probe_cleanup
  exec 3<&-
}

section "1Password"
if [[ "$(capability_value "$profile" allowSecretsAccess)" == "true" ]]; then
  if command -v op >/dev/null 2>&1; then
    # A signed-out op (or one waiting on the 1Password app's unlock prompt)
    # gives `op whoami` no answer; unbounded, it stalled the whole doctor
    # here (#231). The deadline is reported as exactly that — unknown — not
    # as "not signed in".
    bounded_probe op whoami
    case "$probe_rc" in
      0) ok "op signed in" ;;
      "") warn "op sign-in state not checked: op whoami gave no answer within ${probe_deadline}s (waiting on an unlock / sign-in prompt, or stuck; the probe was killed) — unlock or sign in to 1Password, then re-run doctor" ;;
      *) warn "op available but not signed in" ;;
    esac
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
# its fields as untrusted: display_safe them, basename the archive,
# and require a numeric count — anything odd is shown as "unknown" rather
# than echoed verbatim to the terminal.
backup_marker="$HOME/.local/state/dotfiles/private-backup.json"
if [[ -f "$backup_marker" ]]; then
  bm() { display_safe "$(yq -p=json -o=tsv "$1" "$backup_marker" 2>/dev/null || true)"; }
  marker_last="$(bm '.last_success // ""')"
  marker_archive_raw="$(bm '.archive // ""')"
  marker_count="$(bm '.file_count // ""')"
  # capture_incomplete (#242): a boolean, so `// "unknown"` would turn false
  # into unknown — read it as a string instead. Absent (a marker written
  # before #242) is UNKNOWN, never assumed complete.
  marker_incomplete_raw="$(bm '.capture_incomplete | tostring')"
  marker_archive="unknown"
  [[ -n "$marker_archive_raw" ]] && marker_archive="$(basename "$marker_archive_raw")"
  [[ "$marker_count" =~ ^[0-9]+$ ]] || marker_count="unknown"
  case "$marker_incomplete_raw" in
    true) marker_capture="INCOMPLETE" ;;
    false) marker_capture="complete" ;;
    *) marker_capture="unknown" ;;
  esac
  if [[ -z "$marker_last" ]]; then
    warn "backup marker present but unreadable"
  elif [[ "$marker_capture" == "INCOMPLETE" ]]; then
    action "last backup: $marker_last (archive: $marker_archive, files: $marker_count) was INCOMPLETE: a declared directory could not be fully enumerated, so files under it are missing from that archive" \
      "fix the unreadable entries (see the backup run's warnings), then run ./scripts/private-backup.sh backup again with --out PATH"
  else
    ok "last backup: $marker_last (archive: $marker_archive, files: $marker_count, capture: $marker_capture)"
  fi
  unset -f bm
elif profile_allows_secrets_access "$profile"; then
  warn "no backup recorded yet (run ./scripts/private-backup.sh backup --out PATH; see docs/private-backup.md)"
else
  # The backup runtime gate refuses profiles without allowSecretsAccess, so
  # "never ran" is the designed steady state here, not an actionable warning.
  item "no backup recorded (backup requires allowSecretsAccess=true; refused for profile $profile by design)"
fi

section "managed-path orphans"
# A file that carries the managed-by header but whose path is not
# managed for this profile is likely left over from another profile
# (e.g. ~/.npmrc after switching personal -> work). Report
# only; nothing is removed. The header is searched for in the whole file,
# not only on line 1: the git hook shims carry it on line 2, after the
# shebang (#329).
# Only declared FILE paths are inspected (every managed file has its own
# line in modules.yaml; ancestor directories are derived by .chezmoiignore,
# #207): recursing into directories swept unrelated tool data that merely
# quotes the header — ~/.claude session logs / paste-cache — into false
# orphans (#174).
orphan_count=0
while IFS= read -r module; do
  [[ -z "$module" ]] && continue
  while IFS= read -r managed_path; do
    [[ -z "$managed_path" ]] && continue
    target="$HOME/$managed_path"
    [[ -f "$target" ]] || continue
    grep -q "Managed by chezmoi" "$target" 2>/dev/null || continue
    if module_active_for_profile "$profile" "$module"; then
      item "managed and active: $target"
    else
      orphan_count=$((orphan_count + 1))
      action "managed-by header but not managed for profile $profile: $target (orphan from another profile?)" \
        "\$ rm -i $(shell_quote_safe "$target")   # if it is a leftover from another profile; keep it if this profile should manage it (then fix the module list)"
    fi
  done < <(module_paths "$module")
done < <(known_modules)
if [[ "$orphan_count" -eq 0 ]]; then
  ok "no managed-path orphans"
fi

# Managed-file drift (#148): the repo is fail-closed about what gets managed,
# but nothing watched whether applied files silently diverged afterwards —
# twice a token reappeared in ~/.npmrc / preference keys drifted (#91/#93
# relapses) with no signal. Report-only: chezmoi status is read-only and a
# pending-intake drift is expected operation (docs/claude-settings.md), so
# drift is a warn, never an exit-code change.
section "managed drift (report-only)"
if ! command -v chezmoi >/dev/null 2>&1; then
  warn "chezmoi not found; skipping drift check"
elif ! drift_status="$(chezmoi status 2>/dev/null)"; then
  # Without a chezmoi config file this home is simply not initialized (test
  # fixtures, pre-bootstrap). With one, the failure is a config / template
  # error (a profile typo, a broken template) that also breaks apply, so it
  # must not read as a neutral skip (#309). The error text is not echoed:
  # the command step shows it.
  chezmoi_config_dir="$HOME/.config/chezmoi"
  [[ "${XDG_CONFIG_HOME:-}" == /* ]] && chezmoi_config_dir="$XDG_CONFIG_HOME/chezmoi"
  chezmoi_config_found=0
  for chezmoi_config_ext in toml yaml yml json jsonc; do
    [[ -f "$chezmoi_config_dir/chezmoi.$chezmoi_config_ext" ]] && chezmoi_config_found=1
  done
  if [[ "$chezmoi_config_found" -eq 1 ]]; then
    action "chezmoi status failed although this home has a chezmoi config — a config or template error (e.g. an unknown profile) also breaks chezmoi apply; drift is not checked until it is fixed" \
      "\$ chezmoi status   # read the error, then fix the config or the template"
  else
    item "chezmoi not initialized for this home; skipping drift check"
  fi
else
  drift_lines=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    drift_lines=$((drift_lines + 1))
    # `chezmoi status` lines are two status columns, a space, then the path
    # (" M x" / "MM x"), so the path starts at offset 3 — a split on the
    # first space would keep the second column (Codex review, PR #228).
    action "drift: $line (inspect with: chezmoi diff)" \
      "\$ chezmoi diff $(shell_quote_safe "$HOME/${line:3}")   # then chezmoi apply that target, or absorb the live key into the template (docs/claude-settings.md)"
  done <<< "$drift_status"
  if [[ "$drift_lines" -eq 0 ]]; then
    ok "no drift: managed files match the source state"
  else
    item "a drift can be intended (new keys pending intake, #93); reconcile or take in, do not ignore"
  fi
fi
# ~/.npmrc must never carry a token (docs/supply-chain-npm.md): scan for
# credential-shaped keys by name only — values are never read or printed.
# Gated on enforce: profiles that do not manage ~/.npmrc (report/off) would
# get false header alarms; leftovers there are the orphan section's job.
if [[ "$npm_mode" == "enforce" && -f "$HOME/.npmrc" ]]; then
  # Key-shaped occurrences only ((^|:)_authToken=): a mention inside a value
  # or comment is not a credential line and must not alarm.
  token_lines="$(grep -cE '(^|:)_authToken[[:space:]]*=' "$HOME/.npmrc" 2>/dev/null || true)"
  if [[ "${token_lines:-0}" -gt 0 ]]; then
    warn "npmrc contains $token_lines _authToken line(s) — tokens do not belong there (npm logout, then chezmoi apply; see docs/supply-chain-npm.md)"
  else
    ok "npmrc carries no _authToken line"
  fi
  if head -n 1 "$HOME/.npmrc" | grep -Fq "Managed by chezmoi"; then
    ok "npmrc managed-by header present"
  else
    warn "npmrc lacks the managed-by header (overwritten by a tool? chezmoi apply restores it)"
  fi
fi

# Probe commands shared by the AI-harness accumulation watchers (#139,
# #334): every outward-action / escalation family the Approval Required list
# in docs/ai-policy.md names, plus the raw-write escape hatches (gh api POST,
# gh secret) and credential-display commands; then the secret-reading
# families the Claude / OpenCode floors stop (env dump, keychain password
# read / dump / export, the 1Password CLI). Fixed strings, split into argv
# tokens where evaluated. test-doctor.sh pins the Codex set (both lists).
outward_probe_commands=(
  "git push"
  "git clone https://example.invalid/repo"
  "gh pr create"
  "gh pr merge"
  "gh pr comment"
  "gh pr edit"
  "gh pr close"
  "gh issue create"
  "gh issue comment"
  "gh issue edit"
  "gh issue close"
  "gh issue delete"
  "gh issue transfer"
  "gh release create"
  "gh release edit"
  "gh release delete"
  "gh release upload"
  "gh repo delete"
  "gh repo edit"
  "gh repo archive"
  "gh repo rename"
  "gh api --method POST repos/o/r/issues"
  "gh secret set"
  "gh auth login"
  "gh auth status --show-token"
  "gh auth status -t"
  "gh auth token"
  "sudo -v"
  "curl https://example.invalid"
  "wget https://example.invalid"
)
secret_read_probe_commands=(
  "env"
  "printenv"
  "op read op://example/item/field"
  "op item get example"
  "security find-generic-password -s example.invalid -w"
  "security -q find-generic-password -s example.invalid -w"
  "security find-internet-password -s example.invalid -w"
  "security dump-keychain"
  "security export -k login.keychain"
)

# Codex permission-surface watchers (#139), extracted as functions: the AI
# policy section is the most-edited part of doctor (probe/watch additions in
# #139/#181/#137) and sat five levels of nesting deep inline. Both are
# report-only — every path ends in ok/item/warn (return 0), so the plain
# calls below are set -e safe without || true.
report_codex_rules_probes() {
  local codex_rules_dir codex_rules rules_file rules_name rules_args unmanaged_rules rules_listing_complete rules_dir_error
  local baseline_state
  local outward_probes outward_allowed probe_failures probe verdict decision
  codex_rules_dir="$HOME/.codex/rules"
  codex_rules="$codex_rules_dir/default.rules"
  # Codex loads EVERY *.rules in the rules dir, not only default.rules
  # (codex-rs/core/src/exec_policy.rs collect_policy_files, verified 0.159.3:
  # extension == "rules" and a regular file — a symlink is not followed and
  # default.rules.bak.<date> is not loaded; most restrictive decision wins
  # across files) (#316). The probe below gets the same set, or an allow in a
  # sibling file would never show up here. Only default.rules is managed, so a
  # sibling never shows as drift either: it is named as unmanaged. Scope: the
  # user layer only — a trusted project's <repo>/.codex/rules/ and Team Config
  # layers are loaded by Codex too but not seen here.
  rules_args=()
  unmanaged_rules=()
  # Only a CONFIRMED absence is "no rules": Codex treats NotFound (incl. a
  # dangling symlink) as empty, but any other failure to resolve the dir
  # (not a directory, permission denied — also on a parent a symlink points
  # into —, a symlink loop) is a read_dir error there. `test -e` /
  # `-d` collapse all of those into "absent", and BSD `ls -L` silently falls
  # back to the link itself, so the errno is read from the builtin cd in a
  # subshell (follows the link; the C locale keeps the message stable; the
  # raw error, which carries the path, is never echoed).
  if ! rules_dir_error="$( (LC_ALL=C; cd -P -- "$codex_rules_dir") 2>&1 )"; then
    # Match the strerror at the END only: the message embeds the path, and a
    # HOME containing the same words must not turn a permission error into
    # "absent".
    case "$rules_dir_error" in
      *": No such file or directory") ;;
      *)
        warn "Codex rules dir could not be opened (~/.codex/rules — not a directory, permission denied or a symlink loop; Codex fails to read it too): rules-semantics scan INCOMPLETE; do NOT read this as clean"
        return 0
        ;;
    esac
  fi
  if [[ -d "$codex_rules_dir" ]]; then
    # The listing must be COMPLETE: a find that prints some entries and then
    # fails would otherwise leave a subset that reads as clean. The producer
    # appends an end marker only when both find and sort exit 0 (checked via
    # PIPESTATUS, so it holds whether or not pipefail / errexit carry into the
    # process substitution); every real record starts with "$codex_rules_dir/",
    # so the marker cannot collide with one. -H follows the rules dir itself
    # when it is a symlink (Codex's read_dir does) but still not a symlinked
    # entry (Codex skips those).
    rules_listing_complete=0
    while IFS= read -r -d '' rules_file; do
      if [[ "$rules_file" == "::rules-listing-complete::" ]]; then
        rules_listing_complete=1
        continue
      fi
      rules_args+=(--rules "$rules_file")
      rules_name="${rules_file##*/}"
      [[ "$rules_name" == "default.rules" ]] || unmanaged_rules+=("$rules_name")
    done < <(
      find -H "$codex_rules_dir" -mindepth 1 -maxdepth 1 -type f -name '*.rules' ! -name '.rules' -print0 2>/dev/null \
        | LC_ALL=C sort -z
      rules_listing_status="${PIPESTATUS[*]}"
      if [[ "$rules_listing_status" == "0 0" ]]; then
        printf '%s\0' "::rules-listing-complete::"
      fi
    )
    if [[ "$rules_listing_complete" -ne 1 ]]; then
      warn "Codex rules dir could not be listed completely (~/.codex/rules — the listing failed partway): rules-semantics scan INCOMPLETE; do NOT read this as clean"
      return 0
    fi
  fi
  # The clean ok below names the baseline's state: it may run over sibling
  # files alone, so "baseline holding" is only said when the managed file is
  # actually what Codex loads.
  baseline_state="the managed baseline is NOT in effect"
  if [[ -L "$codex_rules" ]]; then
    warn "Codex approval-rules baseline is a symlink (~/.codex/rules/default.rules): Codex does not load a symlinked rules file, so the vetted baseline is not in effect (chezmoi apply writes a regular file)"
  elif [[ -f "$codex_rules" ]]; then
    baseline_state="read-only baseline holding"
    ok "Codex approval-rules baseline managed: ~/.codex/rules/default.rules (accumulated grants show as drift; apply resets to the vetted read-only baseline)"
  else
    item "Codex approval-rules baseline not applied yet (chezmoi apply deploys ~/.codex/rules/default.rules)"
  fi
  # Names only (never the content); a name is attacker-shapeable, so it is
  # shown through display_safe.
  for rules_name in ${unmanaged_rules[@]+"${unmanaged_rules[@]}"}; do
    warn "unmanaged Codex rules file, loaded by Codex alongside the baseline: ~/.codex/rules/$(display_safe "$rules_name") (not managed by dotfiles, so its grants never show as drift; probed below — remove it, or fold vetted rules into the managed baseline)"
  done
  if [[ "${#rules_args[@]}" -gt 0 ]]; then
    # Rules semantics are delegated to Codex's own engine: a fixed probe list
    # of outward/escalation/credential-display commands is evaluated with
    # `codex execpolicy check` against the LIVE rules files. Grepping rule lines was rejected
    # (Codex review #187): it misses blanket prefixes (["gh","pr"] auto-allows
    # `gh pr create` — the exact 2026-07-02 regression form), multi-line
    # rules, and the omitted-decision default (= allow), and echoing rule
    # lines could leak secrets embedded in arbitrary pattern/justification
    # strings. The probe approach never reads the rules files here (the paths
    # are only passed to codex) and only OUR fixed probe strings are echoed.
    if command -v codex >/dev/null 2>&1; then
      # Policy-derived probe set (the shared lists above; #315 / #334 added the
      # secret-reading families so an allow piled up for them shows here too).
      # Keep in sync with the pin in test-doctor.sh (the fake-shim log asserts
      # this exact set so a dropped probe fails the test).
      outward_probes=("${outward_probe_commands[@]}" "${secret_read_probe_commands[@]}")
      outward_allowed=0
      probe_failures=0
      for probe in "${outward_probes[@]}"; do
        # shellcheck disable=SC2086 # probes are fixed strings; word-splitting into tokens is intended
        if verdict="$(codex execpolicy check "${rules_args[@]}" $probe 2>/dev/null)"; then
          # Only the effective, top-level decision is authoritative. A
          # matched allow rule can coexist with a stronger forbidden rule.
          # The engine omits decision when no rules match; all other unknown
          # or malformed output is an incomplete scan, never a clean result.
          if decision="$(yq -p=json -r -e '
            select(tag == "!!map") |
            select(.decision == "allow" or .decision == "prompt" or .decision == "forbidden" or
              ((has("decision") | not) and (.matchedRules | tag) == "!!seq" and (.matchedRules | length) == 0)) |
            .decision // "no-match"
          ' <<< "$verdict" 2>/dev/null)"; then
            case "$decision" in
              allow)
                outward_allowed=$((outward_allowed + 1))
                warn "outward/escalation/credential-display probe auto-allowed by live Codex rules: '$probe' (revoke the covering allow rule or move it behind approval; apply resets to the baseline)"
                ;;
              prompt|forbidden|no-match) ;;
              *) probe_failures=$((probe_failures + 1)) ;;
            esac
          else
            probe_failures=$((probe_failures + 1))
          fi
        else
          # rc!=0 = the engine could not evaluate (broken rules file, old
          # codex, unreadable path) — that is NOT "not allowed". Never let an
          # evaluation failure read as a clean scan (fail-open false-clean).
          probe_failures=$((probe_failures + 1))
        fi
      done
      if [[ "$probe_failures" -gt 0 ]]; then
        warn "rules-semantics scan INCOMPLETE: $probe_failures of ${#outward_probes[@]} probes failed to evaluate (codex execpolicy error or invalid result — broken rules file or incompatible codex?); do NOT read this as clean"
      elif [[ "$outward_allowed" -eq 0 ]]; then
        ok "no outward/escalation/credential-display probe is auto-allowed by the live Codex rules (${#outward_probes[@]} probes over $(( ${#rules_args[@]} / 2 )) rules file(s) via codex execpolicy; $baseline_state)"
      fi
    else
      item "codex CLI not found; rules-semantics probe skipped (baseline presence still verified above)"
    fi
  fi
}

report_codex_projects_trust() {
  local codex_config projects_kind trusted_paths trusted_path trusted_total trusted_count
  # [projects] trust watch: which project paths config.toml marks
  # trust_level = "trusted" (an entry can be "untrusted" — only trusted ones
  # matter). The file is read with yq's TOML decoder (#309): every valid
  # spelling — header tables, a [projects] table, inline tables, dotted or
  # quoted keys, escapes, multi-line strings — means what TOML says, which a
  # line-based scan could not keep up with (it counted valid trust as zero,
  # #292 / #309). Only the trusted project KEYS (paths) leave yq; config.toml
  # also carries MCP server env blocks that may hold secrets, so no value is
  # ever echoed and yq's errors are discarded (key-name-only discipline, same
  # as the #148 token scan). Anything that does not read as a map of project
  # tables — a TOML error, projects as a string or an array, a trusted key
  # that is empty or has a control character (\p{Cc}, C1 included: one path
  # per output line could not carry it) — is an INCOMPLETE scan, never
  # "0 trusted". The remedy names the path, not a TOML spelling: the entry may
  # be a header table, an inline table or a dotted key.
  codex_config="$HOME/.codex/config.toml"
  if [[ ! -f "$codex_config" ]]; then
    item "no ~/.codex/config.toml (codex not initialized); projects-trust watch skipped"
    return 0
  fi
  trusted_paths=""
  trusted_count=0
  if ! projects_kind="$(yq -p toml -o json -r '.projects | kind' "$codex_config" 2>/dev/null)"; then
    projects_kind="unreadable"
  elif [[ "$projects_kind" == scalar ]]; then
    [[ "$(yq -p toml -o json -r '.projects == null' "$codex_config" 2>/dev/null)" == true ]] && projects_kind="absent"
  fi
  if [[ "$projects_kind" == map ]]; then
    if ! trusted_paths="$(yq -p toml -o json -r '.projects | to_entries | map(select(.value.trust_level == "trusted")) | .[].key' "$codex_config" 2>/dev/null)" \
      || ! trusted_count="$(yq -p toml -o json -r '.projects | to_entries | map(select(.value.trust_level == "trusted")) | length' "$codex_config" 2>/dev/null)" \
      || [[ "$(yq -p toml -o json -r '.projects | to_entries | map(select((.value.trust_level == "trusted") and ((.key == "") or (.key | test("\\p{Cc}"))))) | length' "$codex_config" 2>/dev/null)" != 0 ]]; then
      projects_kind="unreadable"
    fi
  fi
  if [[ "$projects_kind" != map && "$projects_kind" != absent ]]; then
    warn "projects-trust scan INCOMPLETE: could not read the projects table of ~/.codex/config.toml; do NOT read this as zero trusted"
    return 0
  fi
  trusted_total=0
  while IFS= read -r trusted_path; do
    [[ -z "$trusted_path" ]] && continue
    trusted_total=$((trusted_total + 1))
    if [[ "$trusted_path" == "$HOME" ]]; then
      action "Codex projects trust covers the WHOLE home directory ($(display_safe "$trusted_path")) — every repo and file under ~ inherits trust; remove it in codex (config.toml is codex-owned, not managed here)" \
        "edit ~/.codex/config.toml: remove the project entry for this path (or set its trust_level to untrusted)"
    elif [[ ! -d "$trusted_path" ]]; then
      action "stale Codex projects trust (path no longer exists): $(display_safe "$trusted_path") — leftover grant; remove it in codex" \
        "edit ~/.codex/config.toml: remove the project entry for this path"
    fi
  done <<< "$trusted_paths"
  if [[ "$projects_kind" == map && "$trusted_total" != "$trusted_count" ]]; then
    warn "projects-trust scan INCOMPLETE: could not read the projects table of ~/.codex/config.toml; do NOT read this as zero trusted"
    return 0
  fi
  item "Codex projects trust: $trusted_total path(s) trusted (report-only; codex-owned config.toml read with yq's TOML decoder, project keys only)"
}

# Claude permission surface (#334, S1-1). Claude's managed floor has no ask
# for outward actions (the agent's own push / PR flow would stall on it), and
# "Yes, and don't ask again" piles allow rules up per project in
# <repo>/.claude/settings.local.json (a shared <repo>/.claude/settings.json
# can carry them too) — the same erosion #139 found on the Codex side. So,
# as with the Codex rules probes, the shared outward probe commands are
# evaluated against the allow rules of those files in the repos directly
# under the standard project roots (and this repo when it is under HOME),
# matched the way Claude Code classifies a Bash rule (claude_bash_rule_matches
# below); the bare tool `Bash` allows every command. A probe a deny / ask of
# the live ~/.claude/settings.json or of the project's own two files covers is
# skipped (deny and ask beat allow, whichever file holds them). Report-only and contents-blind: a rule saved from an
# approved command can carry a token, so only the file and the probe names
# are shown, never a rule. Deeper checkouts (clones of clones) are not read.
# The characters JavaScript's String.prototype.trim() removes (Claude Code
# trims a wildcard rule with it), as UTF-8 byte strings so the trim does not
# depend on the locale: the ASCII whitespace, NBSP, U+1680, U+2000-U+200A,
# the line / paragraph separators, U+202F, U+205F, U+3000 and the BOM.
claude_js_space=(' ' $'\t' $'\n' $'\v' $'\f' $'\r' $'\xc2\xa0' $'\xe1\x9a\x80'
  $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' $'\xe2\x80\x83' $'\xe2\x80\x84' $'\xe2\x80\x85'
  $'\xe2\x80\x86' $'\xe2\x80\x87' $'\xe2\x80\x88' $'\xe2\x80\x89' $'\xe2\x80\x8a'
  $'\xe2\x80\xa8' $'\xe2\x80\xa9' $'\xe2\x80\xaf' $'\xe2\x81\x9f' $'\xe3\x80\x80' $'\xef\xbb\xbf')
# claude_bash_rule_matches BODY CMD — whether a Bash rule body matches CMD,
# classified the way Claude Code does (read from 2.1.293). The body is first
# unescaped (`\(` `\)` `\\`), then: a body ending in `:*` is the legacy
# prefix form when what precedes it is non-empty and has no line terminator
# (\n, \r, U+2028, U+2029: JavaScript's `.` stops there) (CMD
# is the prefix, or starts with it plus a space; whitespace runs collapse; a
# `*` inside that prefix stays literal, so such a rule never matches a real
# command); any other body ending in `:*` is exact; a body with an unescaped
# `*` is a wildcard (trimmed as JavaScript's trim() does, and runs of spaces
# / tabs read as one space in
# both the pattern and CMD; `*` any text, `\*` a literal star, `/**/` any
# directories, a trailing " *" that is the only wildcard also matches the
# bare command); anything else is exact (as written).
claude_bash_rule_matches() {
  local body="$1" cmd="$2" bs='\' lp='(' rp=')' prefix pattern re="" i c ws trimmed stars=0
  # Unquoted replacements: bash 3.2 keeps the quotes of a quoted one.
  body="${body//"$bs$lp"/$lp}"
  body="${body//"$bs$rp"/$rp}"
  body="${body//"$bs$bs"/$bs}"
  if [[ "$body" == *":*" ]]; then
    prefix="${body%:\*}"
    if [[ -z "$prefix" || "$prefix" == *[$'\n\r']* || "$prefix" == *$'\xe2\x80\xa8'* || "$prefix" == *$'\xe2\x80\xa9'* ]]; then
      [[ "$cmd" == "$body" ]]
      return
    fi
    prefix="${prefix//$'\t'/ }"
    while [[ "$prefix" == *"  "* ]]; do prefix="${prefix//  / }"; done
    cmd="${cmd//$'\t'/ }"
    while [[ "$cmd" == *"  "* ]]; do cmd="${cmd//  / }"; done
    [[ "$cmd" == "$prefix" || "$cmd" == "$prefix "* ]]
    return
  fi
  pattern="$body"
  trimmed=0
  while [[ "$trimmed" -eq 0 ]]; do
    trimmed=1
    for ws in "${claude_js_space[@]}"; do
      if [[ "$pattern" == "$ws"* ]]; then
        pattern="${pattern#"$ws"}"
        trimmed=0
      fi
      if [[ "$pattern" == *"$ws" ]]; then
        pattern="${pattern%"$ws"}"
        trimmed=0
      fi
    done
  done
  pattern="${pattern//$'\t'/ }"
  while [[ "$pattern" == *"  "* ]]; do pattern="${pattern//  / }"; done
  for ((i = 0; i < ${#pattern}; i++)); do
    c="${pattern:i:1}"
    if [[ "$c" == "$bs" && "${pattern:i+1:1}" == [*\\] ]]; then
      re+="[${pattern:i+1:1}]"
      i=$((i + 1))
      continue
    fi
    if [[ "$c" == / && "${pattern:i+1:3}" == '**/' ]]; then
      while [[ "${pattern:i+1:3}" == '**/' ]]; do
        i=$((i + 3))
        stars=$((stars + 2))
      done
      re+='/(.*/)?'
      continue
    fi
    case "$c" in
      '*')
        re+='.*'
        stars=$((stars + 1))
        ;;
      [A-Za-z0-9\ _-]) re+="$c" ;;
      '^') re+='\^' ;;
      ']') re+='[]]' ;;
      *) re+="[$c]" ;;
    esac
  done
  if [[ "$stars" -eq 0 ]]; then
    [[ "$cmd" == "$body" ]]
    return
  fi
  [[ "$stars" -eq 1 && "$re" == *" .*" ]] && re="${re%" .*"}( .*)?"
  re="^${re}\$"
  cmd="${cmd//$'\t'/ }"
  while [[ "$cmd" == *"  "* ]]; do cmd="${cmd//  / }"; done
  [[ "$cmd" =~ $re ]]
}
# claude_rules_cover CMD [RULE...] — whether any of the Bash rules matches
# CMD: the bare tool (`Bash`, `Bash()`, `Bash(*)`) matches everything; a
# rule whose closing parenthesis is escaped is malformed (Claude Code skips
# it); other tools' rules are ignored.
claude_rules_cover() {
  local cmd="$1" rule body trailing
  shift
  for rule in "$@"; do
    case "$rule" in
      Bash | 'Bash()' | 'Bash(*)') return 0 ;;
      'Bash('*')')
        body="${rule#Bash(}"
        body="${body%)}"
        trailing="${body##*[!\\]}"
        (( ${#trailing} % 2 == 0 )) || continue
        claude_bash_rule_matches "$body" "$cmd" && return 0
        ;;
    esac
  done
  return 1
}
# claude_read_rules FILE — fill claude_allow_rules and claude_stop_rules (deny
# + ask) with the string entries of FILE's permission lists, one element per
# JSON string: NUL-delimited, so a rule holding a line break stays one rule.
# One read of all documents at once (eval-all): exactly one JSON document is
# required, and yq ends the stream with the marker `E` only when the whole
# evaluation succeeded, so a file that changes or breaks mid-read, or holds
# more than one document, is not taken as read. A key repeated in an object
# is refused too: yq answers with the first, JSON.parse (Claude Code) with
# the last. Returns 1 when FILE is not one JSON document of the expected
# shape (an object whose permissions is an object of arrays, no repeated
# key), a rule holds a NUL, or the marker never arrives.
claude_read_rules() {
  local rule complete=0 expr='[.] as $docs | select(($docs | length) == 1 or error("not one document")) | $docs[0] | (tag == "!!map" and ([.. | select(tag == "!!map") | (keys | length) == (keys | unique | length)] | all) and (.permissions == null or (.permissions | tag) == "!!map") and ([.permissions.allow, .permissions.deny, .permissions.ask] | all_c(. == null or tag == "!!seq"))) as $ok | select($ok or error("unexpected shape")) | ((.permissions.allow // [] | .[] | select(tag == "!!str") | "A" + .), ((.permissions.deny // []) + (.permissions.ask // []) | .[] | select(tag == "!!str") | "S" + .), "E")'
  claude_allow_rules=()
  claude_stop_rules=()
  while IFS= read -r -d '' rule; do
    case "$rule" in
      E) complete=1 ;;
      A*) claude_allow_rules+=("${rule#A}") ;;
      S*) claude_stop_rules+=("${rule#S}") ;;
    esac
  done < <(yq eval-all -p json -o json -0 -r "$expr" "$1" 2>/dev/null)
  [[ "$complete" -eq 1 ]]
}
# claude_settings_dir_state DIR — "open" when DIR can be searched, "absent"
# only on a confirmed absence (No such file or directory, a dangling symlink
# included), "error" otherwise (permission denied, not a directory, a symlink
# loop): `-f` / `-e` read every failure to stat as absence, so the errno is
# taken from the builtin cd in a subshell, the C locale keeping the message
# stable and the raw error (it carries the path) never echoed (as for the
# Codex rules dir, #316).
claude_settings_dir_state() {
  local error
  if error="$( (LC_ALL=C; cd -P -- "$1") 2>&1 )"; then
    echo open
    return 0
  fi
  case "$error" in
    *": No such file or directory") echo absent ;;
    *) echo error ;;
  esac
}
# claude_settings_file_state FILE — in a DIR that is "open": "file" for a
# regular file (followed through a symlink), "absent" when nothing is there,
# "other" for anything else (a directory, a dangling or looping symlink).
claude_settings_file_state() {
  if [[ -f "$1" ]]; then
    echo file
  elif [[ -e "$1" || -L "$1" ]]; then
    echo other
  else
    echo absent
  fi
}
report_claude_project_allows() {
  local floor_file="$HOME/.claude/settings.json" floor_stops=() stop_rules dirs root dir seen dup file kind allows probe hits hit_count shown
  local home_dir dir_state file_state local_allows shared_allows local_read shared_read files_read=0 files_unreadable=0 files_flagged=0
  # The floor: absent (confirmed) means no deny / ask; anything that cannot
  # be read decides nothing, so the check stops there.
  dir_state="$(claude_settings_dir_state "$HOME/.claude")"
  file_state=absent
  [[ "$dir_state" == open ]] && file_state="$(claude_settings_file_state "$floor_file")"
  if [[ "$dir_state" == error || "$file_state" == other ]] \
    || { [[ "$file_state" == file ]] && ! claude_read_rules "$floor_file"; }; then
    item "Claude project-level allows not checked: the live ~/.claude/settings.json could not be read (its deny / ask decide which allows matter)"
    return 0
  fi
  [[ "$file_state" == file ]] && floor_stops=(${claude_stop_rules[@]+"${claude_stop_rules[@]}"})
  # This repo counts only when it sits under HOME (where the user's Claude
  # sessions run; a fixture HOME elsewhere does not read the real checkout).
  # A directory reached twice (this repo under a standard root, a symlink)
  # is read once.
  # HOME is compared in the spelling `pwd` gives DOTFILES_ROOT (a HOME with
  # a doubled or trailing slash would never match as typed).
  dirs=()
  home_dir="$(CDPATH='' cd -- "$HOME" 2>/dev/null && pwd)" || home_dir="$HOME"
  [[ "$DOTFILES_ROOT" == "${home_dir%/}"/* ]] && dirs+=("$DOTFILES_ROOT")
  # A root that cannot be searched or listed would yield no repos at all, so
  # it is unreadable, not empty; dot-named repos are listed too.
  for root in "$HOME/src/personal" "$HOME/src/work" "$HOME/src/client" "$HOME/src/sandbox" "$HOME/src/agent"; do
    dir_state="$(claude_settings_dir_state "$root")"
    [[ "$dir_state" == open && ! -r "$root" ]] && dir_state=error
    if [[ "$dir_state" == error ]]; then
      item "the project root $(shell_quote_safe "$root") could not be listed (permission denied, not a directory or a symlink loop); the repos under it not checked"
      files_unreadable=$((files_unreadable + 1))
      continue
    fi
    [[ "$dir_state" == open ]] || continue
    for dir in "$root"/*/ "$root"/.[!.]*/ "$root"/..?*/; do
      [[ -d "$dir" ]] || continue
      dir="${dir%/}"
      dup=0
      for seen in ${dirs[@]+"${dirs[@]}"}; do
        if [[ "$dir" -ef "$seen" ]]; then
          dup=1
          break
        fi
      done
      [[ "$dup" -eq 1 ]] || dirs+=("$dir")
    done
  done
  for dir in ${dirs[@]+"${dirs[@]}"}; do
    # The deny / ask of either project file beat the allows of both.
    stop_rules=(${floor_stops[@]+"${floor_stops[@]}"})
    local_allows=()
    shared_allows=()
    local_read=0
    shared_read=0
    dir_state="$(claude_settings_dir_state "$dir/.claude")"
    if [[ "$dir_state" == error ]]; then
      item "the .claude directory of $(shell_quote_safe "$dir") could not be opened (permission denied, not a directory or a symlink loop); its settings not checked"
      files_unreadable=$((files_unreadable + 1))
      continue
    fi
    [[ "$dir_state" == open ]] || continue
    for kind in local shared; do
      file="$dir/.claude/settings.json"
      [[ "$kind" == local ]] && file="$dir/.claude/settings.local.json"
      file_state="$(claude_settings_file_state "$file")"
      [[ "$file_state" != absent ]] || continue
      if [[ "$file_state" == other ]] || ! claude_read_rules "$file"; then
        item "the permission rules of $(shell_quote_safe "$file") could not be read (not a regular file holding JSON of the expected shape?); not checked (contents never shown)"
        files_unreadable=$((files_unreadable + 1))
        continue
      fi
      files_read=$((files_read + 1))
      stop_rules+=(${claude_stop_rules[@]+"${claude_stop_rules[@]}"})
      if [[ "$kind" == local ]]; then
        local_allows=(${claude_allow_rules[@]+"${claude_allow_rules[@]}"})
        local_read=1
      else
        shared_allows=(${claude_allow_rules[@]+"${claude_allow_rules[@]}"})
        shared_read=1
      fi
    done
    for kind in local shared; do
      if [[ "$kind" == local ]]; then
        [[ "$local_read" -eq 1 && "${#local_allows[@]}" -gt 0 ]] || continue
        file="$dir/.claude/settings.local.json"
        allows=("${local_allows[@]}")
      else
        [[ "$shared_read" -eq 1 && "${#shared_allows[@]}" -gt 0 ]] || continue
        file="$dir/.claude/settings.json"
        allows=("${shared_allows[@]}")
      fi
      hits=()
      for probe in "${outward_probe_commands[@]}"; do
        claude_rules_cover "$probe" "${allows[@]}" || continue
        claude_rules_cover "$probe" ${stop_rules[@]+"${stop_rules[@]}"} && continue
        hits+=("$probe")
      done
      hit_count="${#hits[@]}"
      [[ "$hit_count" -gt 0 ]] || continue
      files_flagged=$((files_flagged + 1))
      shown="$(printf "'%s', " "${hits[@]:0:5}")"
      shown="${shown%, }"
      [[ "$hit_count" -gt 5 ]] && shown+=" and $((hit_count - 5)) more"
      action "$hit_count outward probe(s) auto-allowed for Claude by project-level allow rules in $(shell_quote_safe "$file"): $shown — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" \
        "edit $(shell_quote_safe "$file"): remove the allow rules covering those commands (approve them per use instead)"
    done
  done
  if [[ "$files_flagged" -eq 0 && "$files_unreadable" -eq 0 ]]; then
    ok "no project-level Claude allow rule covers an outward probe (${#outward_probe_commands[@]} probes over $files_read settings file(s) in this repo and the repos directly under the standard project roots)"
  elif [[ "$files_flagged" -eq 0 ]]; then
    item "Claude project-level allows partly checked: no outward probe auto-allowed in the $files_read file(s) read, but $files_unreadable could not be read — not a clean result"
  fi
}

section "AI policy"
if [[ "$(capability_value "$profile" enableAiPolicy)" == "true" ]]; then
  ok "enableAiPolicy=true (policy docs + report-only checks, plus the managed Codex approval-rules baseline where codex-settings is active; see docs/ai-policy.md)"
  item "boundary today: directory convention + Git identity separation + policy docs + managed Codex approval-rules baseline (codex-settings profiles only)"
  # The standard agent root is optional: agent repos may live outside ~/src (a
  # non-standard placement) resolved via AGENT_TOOLS / repo-local identity, so a
  # missing standard root is reported neutrally, not as a warning (#134).
  if [[ -d "$HOME/src/agent" ]]; then
    ok "agent project root exists: $HOME/src/agent"
  else
    item "agent project root not present (standard root, optional): $HOME/src/agent"
  fi
  # Codex permission surface (#139). Two accumulation channels erode the human
  # gate silently ("don't ask again" piles up): the approval rules file and the
  # [projects] trust in config.toml. The rules baseline is chezmoi-managed (a
  # read-only allowlist; accumulated grants surface as drift and reset on apply);
  # config.toml is codex-owned (#181) so its trust list can only be WATCHED here.
  # Report-only, exit 0. Only meaningful where codex-settings manages the Codex
  # home at all (work has no Codex management; keep it silent there).
  if module_active_for_profile "$profile" codex-settings; then
    report_codex_rules_probes
    report_codex_projects_trust
  else
    item "Codex-side permission files not managed for this profile (codex-settings module inactive)"
  fi
  # Claude-side accumulation (#334): only where claude-settings manages the
  # Claude floor the watcher compares against.
  if module_active_for_profile "$profile" claude-settings; then
    report_claude_project_allows
  else
    item "Claude project-level allows not watched for this profile (claude-settings module inactive)"
  fi
else
  ok "AI policy checks disabled for profile"
fi
if [[ "$(capability_value "$profile" enableAiTools)" == "true" ]]; then
  warn "enableAiTools=true but no implementation exists yet (nothing is managed; roadmap placeholder)"
else
  ok "AI tool install/sync not managed (enableAiTools=false)"
fi

section "OpenCode (report-only)"
# Third AI harness (#234). Its permission floor is a managed file under the
# opencode-settings module (personal only). Presence-level report: the binary
# (catalog: opencode), the managed floor, and the credential store
# ~/.local/share/opencode/auth.json — EXISTENCE only, never its contents or
# provider names (it holds API keys / OAuth tokens; the Claude secret floor
# denies reading it). Drift of the floor is the managed-drift section's job.
# Where the module is inactive (work) the floor is declared not managed; a
# locally installed opencode is still shown.
opencode_floor="$HOME/.config/opencode/opencode.json"
opencode_auth="$HOME/.local/share/opencode/auth.json"
if command -v opencode >/dev/null 2>&1; then
  ok "opencode: $(command -v opencode)"
else
  item "opencode not installed (catalog: opencode via brew; docs/opencode-settings.md)"
fi
if module_active_for_profile "$profile" opencode-settings; then
  if [[ -f "$opencode_floor" ]]; then
    ok "managed permission floor present: $opencode_floor (secret-floor deny, outward/escalation ask, autoupdate off, share disabled; drift shows in the managed drift section)"
  else
    action "opencode-settings module active but the managed floor is missing: $opencode_floor — OpenCode defaults to allow-all without it; run chezmoi apply for the directory and the file" \
      "\$ chezmoi apply $(shell_quote_safe "${opencode_floor%/*}") $(shell_quote_safe "$opencode_floor")"
  fi
else
  ok "OpenCode permission floor not managed for this profile (opencode-settings module inactive)"
fi
if [[ -f "$opencode_auth" ]]; then
  item "opencode credential store present: $opencode_auth (existence only; contents never read)"
else
  item "opencode credential store absent: $opencode_auth (connect a provider with /connect when needed)"
fi

# agent-tools' OpenCode plugins (#263, agent-tools#295). A file in the
# global plugins dir IS the registration (no config entry, no trust gate), so
# agent-tools owns plugins/personal-*.js end to end and its own doctor checks
# the files and their marker line; this side checks the layout OpenCode will
# load from (docs/config-ownership.md). Static only: doctor never runs
# OpenCode — even `opencode debug config` writes its database
# (~/.local/share/opencode/opencode.db, measured on 1.18.30), which would
# break doctor's no-side-effects rule. So presence in the global plugins dir
# is reported, not a successful load; an init that throws is invisible to
# the user (agent-tools probe M2) and 1.18.30 logs nothing about plugin
# loading. personal-agent-tools logs its own init marker instead (#311,
# agent-tools#343), read from OpenCode's existing log below.
# Double loading: a copy OpenCode would also pick up (.ts / .mjs next to the
# .js, the singular plugin/ dir) or the same plugin name listed in a config
# file's `plugin` key. Config files can hold secrets (provider options, MCP
# headers), so only that key is read and nothing from them is printed.
opencode_config_dir="$HOME/.config/opencode"
opencode_plugins=()
for opencode_plugin_file in "$opencode_config_dir"/plugins/personal-*.js; do
  [[ -f "$opencode_plugin_file" ]] && opencode_plugins+=("${opencode_plugin_file##*/}")
done
for opencode_plugin_file in "$opencode_config_dir"/plugins/personal-*.ts "$opencode_config_dir"/plugins/personal-*.mjs "$opencode_config_dir"/plugin/personal-*; do
  [[ -e "$opencode_plugin_file" ]] || continue
  warn "agent-tools plugin copy that OpenCode may load twice: $(display_safe "$opencode_plugin_file") (agent-tools deploys only plugins/personal-*.js; remove the extra copy)"
done
if [[ "${#opencode_plugins[@]}" -eq 0 ]]; then
  item "no agent-tools plugin in ~/.config/opencode/plugins (agent-tools sync deploys personal-*.js there)"
else
  # Plugin names listed in the `plugin` key of the config files OpenCode
  # actually reads from this shell: the managed floor (always) and the file
  # OPENCODE_CONFIG points at. opencode.local.json counts only when
  # OPENCODE_CONFIG points at it; a listing in it that is not active here is
  # shown as a note, never as a double load (Codex review, PR #270).
  # opencode_plugin_names FILE — print the basenames in FILE's plugin key,
  # one per line; fail (and print nothing) when FILE cannot be parsed.
  opencode_plugin_names() {
    local names
    names="$(yq -p json -o json '.plugin // [] | map(select(type == "!!str") | sub(".*/"; ""))' "$1" 2>/dev/null)" || return 1
    yq -p json '.[]' <<< "$names" 2>/dev/null
  }
  opencode_listed_active=""
  opencode_listed_inactive=""
  opencode_local_cfg="$opencode_config_dir/opencode.local.json"
  for opencode_cfg_file in "$opencode_config_dir/opencode.json" "${OPENCODE_CONFIG:-}"; do
    [[ -n "$opencode_cfg_file" && -f "$opencode_cfg_file" ]] || continue
    if opencode_cfg_plugins="$(opencode_plugin_names "$opencode_cfg_file")"; then
      opencode_listed_active+="$opencode_cfg_plugins"$'\n'
    else
      item "the plugin key of $opencode_cfg_file could not be read (not JSON?); double loading via config not checked (contents never shown)"
    fi
  done
  if [[ -f "$opencode_local_cfg" ]] && ! [[ -n "${OPENCODE_CONFIG:-}" && "$OPENCODE_CONFIG" -ef "$opencode_local_cfg" ]]; then
    if opencode_cfg_plugins="$(opencode_plugin_names "$opencode_local_cfg")"; then
      opencode_listed_inactive+="$opencode_cfg_plugins"$'\n'
    else
      item "the plugin key of $opencode_local_cfg could not be read (not JSON?); double loading via config not checked (contents never shown)"
    fi
  fi
  # plugin_listed_in NAMES STEM — true when a name in NAMES (one per line)
  # equals STEM once its extension is dropped (literal, not a pattern).
  plugin_listed_in() {
    local listed_name
    while IFS= read -r listed_name; do
      [[ -n "$listed_name" && "${listed_name%.*}" == "$2" ]] && return 0
    done <<< "$1"
    return 1
  }
  # opencode_plugin_init_report FILE — whether OpenCode's log shows that the
  # personal-agent-tools plugin deployed as FILE got through its init. The
  # plugin logs `agent-tools:plugin-init v=1 name=personal-agent-tools
  # build_id=<sha256:64 hex | unknown>` once its init returns (agent-tools'
  # docs/boundary-with-dotfiles.md, a public contract). Confirmed only when
  # the newest such line's build_id equals the one in FILE's marker (line 1);
  # anything else is "not confirmed", never a failure: no log (OpenCode not
  # started here yet), no line (--pure, a log level above INFO, a rotated
  # log, an init that threw), another build, or a line outside the v=1 form
  # (a newer v= included). The line proves that some past start of this
  # build got through init, not that the latest one did. Only the verdict,
  # the build_id and a short reason are shown, never a log line. Where the
  # log lives and how its line wraps the message are OpenCode's (1.18.30:
  # <data>/opencode/log/opencode.log, data = ${XDG_DATA_HOME:-~/.local/share};
  # `timestamp=… level=… run=… message="…"`, the message quoted since it has
  # spaces). So only a line's own message field — its first ` message=` —
  # counts, both for picking the newest marker line and for its form, which
  # must be exactly the marker closed by its quote: marker text further
  # inside a message is not the plugin's line (Codex review R1 / R2, PR #325),
  # and the build_id is cut by that form, not by the end of the line. FILE's line 1
  # must be agent-tools' marker for this plugin (prefix and identity fields;
  # its full check is agent-tools' doctor's), and the log is read only as a
  # regular file (a FIFO would block grep).
  opencode_plugin_init_report() {
    local plugin_file="$1" label="agent-tools plugin personal-agent-tools init" first deployed data_home log rc=0 field
    # Lowercase hex spelled out: a range like a-f may take in other letters
    # under some locales' collation.
    local sha='sha256:[0123456789abcdef]{64}'
    local marker_re='^/\* agent-tools:managed v=1 repo=agent-tools name=personal-agent-tools target=opencode artifact_kind=plugin source=[^ /][^ ]* build_id=('"${sha}"') \*/$'
    # Prints the message field (from its opening quote to the end of the
    # line) of the last line whose FIRST message field opens with the marker
    # prefix and names this plugin (any v=, any build_id: the form is judged
    # below); exit 1 when there is none. Picking by the first field keeps a
    # later line that merely quotes a marker from hiding an earlier real one
    # (Codex review R2, PR #325).
    local pick='{ s = " " $0; i = index(s, " message="); if (i == 0) next
      f = substr(s, i + 9)
      if (f ~ /^"agent-tools:plugin-init ([^"]* )?name=personal-agent-tools[ "]/) last = f }
      END { if (last == "") exit 1; print last }'
    local v1_re='^"agent-tools:plugin-init v=1 name=personal-agent-tools build_id=('"${sha}"'|unknown)"([[:space:]]|$)'
    first="$(head -n 1 "$plugin_file" 2>/dev/null)" || first=""
    if [[ "$first" =~ $marker_re ]]; then
      deployed="${BASH_REMATCH[1]}"
    else
      item "$label not confirmed: the deployed file's line 1 is not agent-tools' marker for this plugin with a sha256 build_id (agent-tools' doctor checks its marker)"
      return 0
    fi
    data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    if [[ "$data_home" != /* ]]; then
      item "$label not confirmed: XDG_DATA_HOME is a relative path here, so where OpenCode logs depends on the directory it starts in (deployed build_id $deployed)"
      return 0
    fi
    log="${data_home%/}/opencode/log/opencode.log"
    if [[ ! -e "$log" && ! -L "$log" ]]; then
      item "$label not confirmed: no OpenCode log yet (not started here; deployed build_id $deployed)"
      return 0
    fi
    if [[ ! -f "$log" ]]; then
      item "$label not confirmed: OpenCode's log is not a regular file (deployed build_id $deployed)"
      return 0
    fi
    # Checked before awk: gawk warns about a file it cannot open yet still
    # runs END, whose `exit 1` would read as "no marker".
    if [[ ! -r "$log" ]]; then
      item "$label not confirmed: OpenCode's log could not be read (deployed build_id $deployed)"
      return 0
    fi
    field="$(LC_ALL=C awk "$pick" "$log" 2>/dev/null)" || rc=$?
    if [[ "$rc" -eq 1 ]]; then
      item "$label not confirmed: no init marker in OpenCode's log (not started since the plugin began logging it, started with --pure or a log level above INFO, a rotated log, or an init that threw; deployed build_id $deployed)"
    elif [[ "$rc" -ne 0 ]]; then
      item "$label not confirmed: OpenCode's log could not be read (deployed build_id $deployed)"
    elif ! [[ "$field" =~ $v1_re ]]; then
      item "$label not confirmed: the newest init marker is not in the v=1 form this doctor reads (deployed build_id $deployed)"
    elif [[ "${BASH_REMATCH[1]}" == unknown ]]; then
      item "$label not confirmed: the newest init marker carries build_id unknown (the plugin could not read its own marker; deployed build_id $deployed)"
    elif [[ "${BASH_REMATCH[1]}" != "$deployed" ]]; then
      item "$label not confirmed: the newest init marker is from build_id ${BASH_REMATCH[1]}, not the deployed $deployed (OpenCode not started since the last sync, or a process still on the old build)"
    else
      ok "$label confirmed by OpenCode's log (build_id $deployed: some start of this build got through init, not necessarily the latest)"
    fi
  }
  for opencode_plugin_name in "${opencode_plugins[@]}"; do
    opencode_stem="${opencode_plugin_name%.js}"
    if [[ "$opencode_stem" == personal-agent-tools ]]; then
      opencode_init_note="its init is reported below"
    else
      opencode_init_note="its init is not verifiable: only personal-agent-tools logs an init marker, and doctor does not run OpenCode"
    fi
    if plugin_listed_in "$opencode_listed_active" "$opencode_stem"; then
      warn "agent-tools plugin $(display_safe "$opencode_stem") is also listed in an OpenCode config's plugin key — OpenCode loads it twice; drop the config entry (the plugins dir already registers it)"
    else
      ok "agent-tools plugin $(display_safe "$opencode_plugin_name") in the global plugins dir (OpenCode loads it at startup; $opencode_init_note)"
      if plugin_listed_in "$opencode_listed_inactive" "$opencode_stem"; then
        item "$(display_safe "$opencode_stem") is also listed in opencode.local.json's plugin key, which OpenCode reads only when OPENCODE_CONFIG points at it — it would then load twice"
      fi
    fi
    if [[ "$opencode_stem" == personal-agent-tools ]]; then
      opencode_plugin_init_report "$opencode_config_dir/plugins/$opencode_plugin_name"
    fi
  done
  unset -f plugin_listed_in opencode_plugin_names opencode_plugin_init_report
fi

# The local (non-managed) config — provider / model / plugin / mcp — lives in
# opencode.local.json and is only read when OPENCODE_CONFIG points at it
# (docs/opencode-settings.md). The export sits in ~/.zshrc.local, so a shell
# that did not load it starts OpenCode without the local config. Checked
# against doctor's own environment; the variable's key is looked up in
# ~/.zshrc.local by name only (the file is never printed).
opencode_local="$opencode_config_dir/opencode.local.json"
if [[ -f "$opencode_local" ]]; then
  if [[ -z "${OPENCODE_CONFIG:-}" ]]; then
    if grep -q 'OPENCODE_CONFIG' "$HOME/.zshrc.local" 2>/dev/null; then
      item "OPENCODE_CONFIG is exported in ~/.zshrc.local but not set in this shell — OpenCode started from here would not read opencode.local.json (normal for a non-interactive shell; run doctor from an interactive one to check)"
    else
      action "opencode.local.json exists but OPENCODE_CONFIG is not set — OpenCode ignores the local provider / model / mcp config" \
        "add export OPENCODE_CONFIG=\"\$HOME/.config/opencode/opencode.local.json\" to ~/.zshrc.local (docs/opencode-settings.md)"
    fi
  elif [[ "$OPENCODE_CONFIG" -ef "$opencode_local" ]]; then
    ok "OPENCODE_CONFIG -> opencode.local.json (local provider / model / mcp config is read)"
  elif [[ -f "$OPENCODE_CONFIG" ]]; then
    warn "OPENCODE_CONFIG points to a different file than opencode.local.json — that local config is not read"
  else
    warn "OPENCODE_CONFIG points to a file that does not exist — OpenCode reads no local config"
  fi
elif [[ -n "${OPENCODE_CONFIG:-}" && ! -f "$OPENCODE_CONFIG" ]]; then
  warn "OPENCODE_CONFIG points to a file that does not exist — OpenCode reads no local config"
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
# Captured once and reused by the injection-guard section below (the same
# single-read pattern as npm_mode near the top).
enforce_ai_sandbox="$(capability_value "$profile" enforceAiSandbox)"
if [[ "$enforce_ai_sandbox" == "true" ]]; then
  if module_active_for_profile "$profile" claude-settings; then
    ok "enforceAiSandbox=true; managed ~/.claude/settings.json carries the native sandbox (Bash fs+network) and the human-legit GitHub write gate (main-push + .env-read deny, release/protection ask; best-effort — the never-legit secret floor is unconditional, see the injection guard section)"
  else
    warn "enforceAiSandbox=true but the claude-settings module is inactive for this profile; no managed settings carry the sandbox block (dangling capability)"
  fi
else
  ok "Claude Code native sandbox not enforced via managed settings (enforceAiSandbox=false)"
fi

section "Claude MCP exposure (report-only)"
# gateUnusedClaudeMcp (#341) denies, in the managed ~/.claude/settings.json, the
# MCP that Claude Code is connected to but does not use day to day: the
# claude.ai hosted connectors Gmail / Google Calendar / Google Drive / Claude
# Docs (whole servers) and the Notion plugin's write tools with no or rare use.
# Exposure reduction only — it binds Claude Code, not the web / mobile chat, and
# is best-effort / steering, not an enforcement boundary. Safety-hardening
# polarity like gateGitHubMcp, so it is absent from the forbidden table.
# Report-only and contents-blind (the live file is not probed here).
if [[ "$(capability_value "$profile" gateUnusedClaudeMcp)" == "true" ]]; then
  if module_active_for_profile "$profile" claude-settings; then
    ok "gateUnusedClaudeMcp=true; managed ~/.claude/settings.json denies the claude.ai Gmail / Google Calendar / Google Drive / Claude Docs connectors and the rarely used Notion write tools (exposure reduction for Claude Code only, not a boundary)"
  else
    warn "gateUnusedClaudeMcp=true but the claude-settings module is inactive for this profile; no managed settings carry the MCP deny (dangling capability)"
  fi
else
  ok "gateUnusedClaudeMcp not active (false)"
fi

section "tool call record hook (report-only)"
# enableToolCallRecordHook (#353, agent-tools#454) registers, in the managed
# ~/.claude/settings.json, agent-tools' personal-tool-call-record-hook on
# SessionStart / PreToolUse / PostToolUse / PostToolUseFailure / PermissionDenied
# (matcher "*", async, timeout 10) so each Claude Code tool call leaves one JSON
# line (argument keys only) in the user state dir. Record / fail-open: a missing
# body is a non-blocking hook error, the subject is the client self-report and
# the JSONL is writable by the same OS user — a guardrail, not a boundary. Claude
# only (no Codex registration). Report-only and contents-blind (the live file is
# not probed here).
if [[ "$(capability_value "$profile" enableToolCallRecordHook)" == "true" ]]; then
  if module_active_for_profile "$profile" claude-settings; then
    ok "enableToolCallRecordHook=true; managed ~/.claude/settings.json registers personal-tool-call-record-hook on SessionStart / PreToolUse / PostToolUse / PostToolUseFailure / PermissionDenied (record / fail-open, Claude Code only, not a boundary)"
  else
    warn "enableToolCallRecordHook=true but the claude-settings module is inactive for this profile; no managed settings carry the record hook (dangling capability)"
  fi
else
  ok "enableToolCallRecordHook not active (false)"
fi

section "GitHub injection guard (report-only)"
# gateGitHubMcp / enableGitHubIsolatedReader are safety-hardening capabilities for
# the GitHub runtime prompt-injection defense (epic #119). Like enforceAiSandbox
# they are opposite polarity to the install / secret / network capabilities, so
# they are intentionally absent from environment_kind_forbidden_capabilities (a
# restrictive kind may set them true). All matchers are best-effort / steering,
# NOT an enforcement boundary (see docs/ai-environment-boundary.md). Report-only
# and contents-blind. AGENTS.md requires each capability to drive a section.
#
# gateGitHubMcp is wired (PR2): it denies the github MCP server in the managed
# ~/.claude/settings.json (when claude-settings is active for the profile).
if [[ "$(capability_value "$profile" gateGitHubMcp)" == "true" ]]; then
  if module_active_for_profile "$profile" claude-settings; then
    ok "gateGitHubMcp=true; managed ~/.claude/settings.json denies the github MCP server (best-effort, not a boundary)"
  else
    warn "gateGitHubMcp=true but the claude-settings module is inactive for this profile; no managed settings carry the MCP deny (dangling capability)"
  fi
else
  ok "gateGitHubMcp not active (false)"
fi
# The #119 write/secret deny is split into two tiers (Phase 2 task B). Only
# meaningful where claude-settings manages the file at all.
if module_active_for_profile "$profile" claude-settings; then
  # Tier 1 — never-legit secret floor: unconditional in the managed
  # settings.json (SSH-key / credential-store / env-dump / gh-secret reads;
  # credential stores — aws, gh OAuth, netrc, codex auth — joined in #136).
  # The human never legitimately asks Claude to do these and the deny binds
  # only Claude's own tool calls, so it is always on. Live on personal today,
  # no enforceAiSandbox needed.
  ok "secret floor active: SSH-key / credential-store / env-dump / gh-secret reads denied unconditionally (best-effort, not a boundary)"
  # Tier 2 — human-legit write gate: main-push deny, .env read deny, and the
  # release/branch-protection ask still ride on enforceAiSandbox, which personal
  # keeps false (its egress block is unusable on a daily driver). A restricted
  # context for these is not built (#131 closed without it; no tracking issue) —
  # disclose the live state so the green line above is not read as a complete
  # injection guard.
  if [[ "$enforce_ai_sandbox" == "true" ]]; then
    item "human-legit write gate active (enforceAiSandbox): main-push + .env-read deny, release/protection ask"
  else
    item "human-legit write gate INERT (enforceAiSandbox=false): main-push / .env-read deny and release/protection ask are not rendered — needs a restricted context (not built: #131 closed without it; no tracking issue), not the daily-driver egress block"
  fi
  # The main-push deny is leaky steering even where it renders: the matcher
  # `git push * main|master` only catches the explicit trailing-`main` form and
  # misses bare `git push`, `git push origin HEAD`, and refspecs (`HEAD:main`).
  # Verified against Claude Code matcher semantics (#119). Disclosed so the deny
  # is not mistaken for a real main-push boundary — the real block is
  # server-side branch protection (the isolated reader / safe-gh are steering,
  # not a block).
  item "note: the main-push deny is leaky steering — catches 'git push … main', misses bare 'git push' / HEAD / refspec; the real block is server-side branch protection"
fi
# enableGitHubIsolatedReader wires the isolated-reader steering (#137 + #181): one
# capability registers the PreToolUse hook (matcher Bash) that steers raw `gh`
# reads of untrusted GitHub content to the safe-gh reader, in BOTH AI homes — the
# managed ~/.claude/settings.json (claude-settings) and the user-layer
# ~/.codex/hooks.json (codex-settings). Steering / fail-open (a missing body,
# non-2 exit, bad JSON or timeout all let the tool call continue; only exit 2
# blocks) — NOT an enforcement boundary. The hook body is agent-tools-deployed
# (registration=dotfiles, body=agent-tools; agent-tools#146 pins the path);
# report its presence only, contents-blind.
if [[ "$(capability_value "$profile" enableGitHubIsolatedReader)" == "true" ]]; then
  if module_active_for_profile "$profile" claude-settings; then
    hook_body="$HOME/.claude/agent-tools/scripts/personal-safe-gh-hook"
    if [[ -x "$hook_body" ]]; then
      ok "enableGitHubIsolatedReader=true; managed settings.json registers the PreToolUse hook -> safe-gh steering (fail-open, not a boundary); hook body present"
    else
      warn "enableGitHubIsolatedReader=true; PreToolUse hook registered in managed settings.json but the body is absent or non-executable ($hook_body; agent-tools sync deploys it) — fail-open no-op until deployed"
    fi
  else
    warn "enableGitHubIsolatedReader=true but the claude-settings module is inactive for this profile; no managed settings carry the hook registration (dangling capability)"
  fi
  # Codex parity (#181): the same capability registers the hook in the user-layer
  # ~/.codex/hooks.json (codex-settings module). Codex has an EXTRA inert stage vs
  # Claude — even a registered+present hook is skipped (current Codex shows a
  # startup warning; it was silent at #181) until a one-time
  # interactive `/hooks` trust (trust recorded in ~/.codex/config.toml
  # [hooks.state]). Report registration + body presence contents-blind and honest-
  # label the trust requirement; never read config.toml here.
  if module_active_for_profile "$profile" codex-settings; then
    codex_hook_body="$HOME/.codex/agent-tools/scripts/personal-safe-gh-hook"
    if [[ -x "$codex_hook_body" ]]; then
      ok "enableGitHubIsolatedReader=true; managed ~/.codex/hooks.json registers the PreToolUse hook -> safe-gh steering (fail-open, not a boundary); hook body present (Codex: inert until a one-time /hooks trust)"
    else
      warn "enableGitHubIsolatedReader=true; PreToolUse hook registered in managed ~/.codex/hooks.json but the body is absent or non-executable ($codex_hook_body; agent-tools sync deploys it) — fail-open no-op until deployed (Codex also needs a one-time /hooks trust)"
    fi
  else
    warn "enableGitHubIsolatedReader=true but the codex-settings module is inactive for this profile; no managed ~/.codex/hooks.json carries the hook registration (dangling capability on the Codex side)"
  fi
else
  ok "enableGitHubIsolatedReader not active (false)"
fi
# Trust list (#119 PR3): the self trust basis only (GitHub login + numeric id;
# no collaborator entries) lives in a non-committed local file read by
# agent-tools' personal-safe-gh (env SAFE_GH_TRUST_FILE overrides the path).
# Pointer only — never read here. Its existence is reported contents-blind by the
# private-backup section (it is in backup-paths.yaml). Absent ⇒ safe-gh resolves
# self via `gh api user`; if that also fails, every author is untrusted (fail closed).
item "trust list: ~/.config/dotfiles/github-trust.local (#119; contents never read; absent ⇒ only self trusted)"

section "quality loop hooks (report-only)"
# enableQualityLoopHooks wires the two quality-loop lifecycle hooks of
# agent-tools#203 (hook plan Phase 2; dotfiles #199) in BOTH AI homes, with the
# same registration=dotfiles / body=agent-tools split as the safe-gh hook above:
# PostToolUse (Edit|Write) -> personal-fast-edit-check (steering, never blocks)
# and Stop -> personal-changed-scope-qa (best-effort gate: blocks once per new
# dirty scope, never when stop_hook_active; bypassable). Both are silent no-ops
# until the user declares a repo in the untracked ~/.config/agent-tools/
# checks.local.json (contract: agent-tools docs/quality-loop-hooks.md). Report
# registration + body presence contents-blind; the checks file names commands
# the hooks will RUN, so doctor reports only its presence and never reads it.
quality_hooks_bodies=(personal-fast-edit-check personal-changed-scope-qa)
if [[ "$(capability_value "$profile" enableQualityLoopHooks)" == "true" ]]; then
  for quality_hooks_home in .claude .codex; do
    case "$quality_hooks_home" in
      .claude)
        quality_hooks_module=claude-settings
        quality_hooks_target="managed ~/.claude/settings.json"
        quality_hooks_note=""
        ;;
      .codex)
        quality_hooks_module=codex-settings
        quality_hooks_target="managed ~/.codex/hooks.json"
        # The #199-era caveat (codex-cli 0.145.0: apply_patch carries no
        # file_path, so the edit check never ran on Codex) was lifted by
        # agent-tools#232: the body now reads apply_patch's tool_input.command.
        # Only the trust requirement is left to disclose.
        quality_hooks_note=" (Codex: inert until a one-time /hooks trust)"
        ;;
    esac
    if module_active_for_profile "$profile" "$quality_hooks_module"; then
      quality_hooks_deploy_dir="$HOME/$quality_hooks_home/agent-tools/scripts"
      quality_hooks_missing=()
      for quality_hooks_body in "${quality_hooks_bodies[@]}"; do
        [[ -x "$quality_hooks_deploy_dir/$quality_hooks_body" ]] || quality_hooks_missing+=("$quality_hooks_body")
      done
      if [[ "${#quality_hooks_missing[@]}" -eq 0 ]]; then
        ok "enableQualityLoopHooks=true; $quality_hooks_target registers PostToolUse(Edit|Write) -> fast-edit-check and Stop -> changed-scope-qa (best-effort, not a boundary); both bodies present$quality_hooks_note"
      else
        warn "enableQualityLoopHooks=true; $quality_hooks_target registers the quality-loop hooks but a body is absent or non-executable: ${quality_hooks_missing[*]} (in $quality_hooks_deploy_dir; agent-tools sync deploys them) — fail-open no-op until deployed$quality_hooks_note"
      fi
    else
      warn "enableQualityLoopHooks=true but the $quality_hooks_module module is inactive for this profile; no $quality_hooks_target carries the hook registration (dangling capability)"
    fi
  done
  if [[ -f "$HOME/.config/agent-tools/checks.local.json" ]]; then
    item "check declarations: ~/.config/agent-tools/checks.local.json present (contents never read; the hooks act only in repos declared there)"
  else
    item "check declarations: ~/.config/agent-tools/checks.local.json absent — both hooks are silent no-ops in every repo until a repo is declared there (per-repo opt-in; agent-tools docs/quality-loop-hooks.md)"
  fi
  item "best-effort: fast-edit-check never blocks; changed-scope-qa blocks once per new dirty scope and is bypassable (hook disabled, stop_hook_active) — not an enforcement boundary"
else
  # Disabled is only honest if no registration lingers from before the flip:
  # a home that applied personal and then switched to a profile without the
  # settings modules keeps its ~/.claude/settings.json / ~/.codex/hooks.json
  # untouched (chezmoiignore drops the source, it never prunes the target),
  # so the hooks keep running user-declared checks while this line says
  # "not wired" (Codex review, PR #200 — same shape as the git-hook-gates
  # lingering check). Probe the live files for the body path only, by
  # fixed-string match; never echo their contents.
  quality_hooks_lingering=()
  for quality_hooks_live in "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json"; do
    if [[ -f "$quality_hooks_live" ]] && grep -Fq "agent-tools/scripts/personal-changed-scope-qa" "$quality_hooks_live"; then
      quality_hooks_lingering+=("$quality_hooks_live")
    fi
  done
  if [[ "${#quality_hooks_lingering[@]}" -eq 0 ]]; then
    ok "quality loop hooks not wired (enableQualityLoopHooks=false)"
  else
    warn "enableQualityLoopHooks=false but a quality-loop hook registration lingers in ${quality_hooks_lingering[*]} (applied by another profile; this profile does not manage the file, so apply will not remove it) — remove the hooks or the file by hand"
  fi
fi

section "herdr integration (report-only)"
# enableHerdrIntegration (#225, agent-tools#252 hand-off) registers herdr's
# SessionStart integration hook in BOTH AI homes so an agent started inside a
# herdr pane reports its session id to herdr (native session restore). Same
# registration=dotfiles split as the hooks above, with the body owned by
# herdr instead of agent-tools: `herdr integration install <agent>` writes
# the versioned body and dotfiles renders exactly the entry shape that
# installer emits. The body exits 0 outside a herdr pane and a missing body
# is a non-blocking hook error (fail-open), so the registration is safe
# before the install. Body presence is checked contents-blind: the
# registration runs it as `bash '<path>' session`, so a readable regular
# file is what matters, not an exec bit. Version currency comes from `herdr
# integration status`, which only reads the body header under $HOME (no
# server, no writes — herdr v0.9.0 src/integration). It runs through
# bounded_probe (the shared deadline / no-temp-file / tree-reaping helper
# defined before the 1Password section) and its output is adopted only on
# exit 0, so an absent, failing or hung herdr all collapse to "currency not
# checked": doctor neither stalls nor reports a partial answer as current
# (Codex review, PR #226).
herdr_status=""
if command -v herdr >/dev/null 2>&1; then
  bounded_probe herdr integration status
  if [[ "$probe_rc" == "0" ]]; then
    herdr_status="$probe_lines"
  fi
fi
# herdr_integration_state AGENT
# Print the state herdr reports for AGENT ("current", "outdated", "needs
# repair", "not installed"), or nothing when herdr gave no usable line.
herdr_integration_state() {
  local line
  line="$(LC_ALL=C grep -E "^$1: " <<< "$herdr_status" 2>/dev/null | head -n 1 || true)"
  [[ -n "$line" ]] || return 0
  line="${line#"$1: "}"
  display_safe "${line%% (*}"
  printf '\n'
}
# herdr_integration_home DIR
# Set the per-home facts for .claude / .codex: agent, settings module, the
# managed live file (and its bare name), herdr's body path (its per-agent
# layout) and the Codex honest-label.
herdr_integration_home() {
  case "$1" in
    .claude)
      herdr_agent=claude
      herdr_module=claude-settings
      herdr_target="managed ~/.claude/settings.json"
      herdr_body="$HOME/.claude/hooks/herdr-agent-state.sh"
      herdr_note=""
      ;;
    .codex)
      herdr_agent=codex
      herdr_module=codex-settings
      herdr_target="managed ~/.codex/hooks.json"
      herdr_body="$HOME/.codex/herdr-agent-state.sh"
      herdr_note=" (Codex: inert until a one-time /hooks trust; the installer also sets [features] hooks = true in codex-owned ~/.codex/config.toml, which dotfiles does not manage)"
      ;;
  esac
  herdr_file="${herdr_target#managed }"
}
if [[ "$(capability_value "$profile" enableHerdrIntegration)" == "true" ]]; then
  for herdr_home in .claude .codex; do
    herdr_integration_home "$herdr_home"
    if module_active_for_profile "$profile" "$herdr_module"; then
      if [[ -f "$herdr_body" && -r "$herdr_body" ]]; then
        herdr_state="$(herdr_integration_state "$herdr_agent")"
        case "$herdr_state" in
          current)
            ok "enableHerdrIntegration=true; $herdr_target registers SessionStart -> herdr-agent-state.sh session; body present and current per herdr integration status$herdr_note"
            ;;
          "")
            ok "enableHerdrIntegration=true; $herdr_target registers SessionStart -> herdr-agent-state.sh session; body present (version currency not checked: herdr integration status unavailable)$herdr_note"
            ;;
          *)
            action "enableHerdrIntegration=true; $herdr_target registers the SessionStart hook and the body is present, but herdr integration status reports it '$herdr_state' — re-run: herdr integration install $herdr_agent$herdr_note" \
              "\$ herdr integration install $herdr_agent"
            ;;
        esac
      else
        action "enableHerdrIntegration=true; $herdr_target registers the SessionStart hook but the body is absent or unreadable ($herdr_body; run: herdr integration install $herdr_agent) — fail-open no-op until installed$herdr_note" \
          "\$ herdr integration install $herdr_agent"
      fi
    else
      warn "enableHerdrIntegration=true but the $herdr_module module is inactive for this profile; no $herdr_target carries the hook registration (dangling capability)"
    fi
  done
  item "scope: the hook reports the agent session id to the herdr server only from inside a herdr pane (HERDR_ENV / HERDR_SOCKET_PATH / HERDR_PANE_ID set) and exits 0 elsewhere — session restore only, not a boundary; agent state stays screen-detected"
else
  ok "herdr integration not wired by dotfiles (enableHerdrIntegration=false; declared state — live registrations are not probed here)"
  # Ownership of the live file differs per home: where the settings module is
  # active the file is managed, so a registration added by herdr's installer
  # is drift that the next apply removes (the managed-drift section reports
  # it); where it is inactive the file is unmanaged and both registration and
  # body are left to `herdr integration install` (a work machine). Show
  # herdr's own per-agent view either way, contents-blind.
  # Where dotfiles does not manage the file (a work machine) the installer is
  # the whole story, so "not installed" or "outdated" there is the one thing
  # a fresh machine would otherwise never be told (#227): report it as an
  # action naming the command. Where the file IS managed the capability is
  # simply off by choice, so herdr's view stays informational.
  for herdr_home in .claude .codex; do
    herdr_integration_home "$herdr_home"
    herdr_state="$(herdr_integration_state "$herdr_agent")"
    [[ -n "$herdr_state" ]] || continue
    if module_active_for_profile "$profile" "$herdr_module"; then
      item "herdr's own view: $herdr_agent integration $herdr_state — $herdr_target carries no registration while the capability is false; one added by herdr integration install is drift that the next apply removes"
    elif [[ "$herdr_state" == "current" ]]; then
      item "herdr's own view: $herdr_agent integration current — $herdr_file is unmanaged for this profile, so registration and body are both left to herdr integration install"
    else
      action "herdr integration for $herdr_agent is $herdr_state — $herdr_file is unmanaged for this profile, so herdr integration install owns both the registration and the body here (dotfiles does nothing on this profile)$herdr_note" \
        "\$ herdr integration install $herdr_agent"
    fi
  done
  if ! command -v herdr >/dev/null 2>&1; then
    item "herdr not on PATH: nothing to check (the software catalog section reports it as declared-missing; this profile does not auto-install)"
  fi
fi
# OpenCode (#263): herdr's installer drops its own plugin into OpenCode's
# global plugins dir (placing the file IS the registration), so dotfiles has
# no registration to render and enableHerdrIntegration does not reach it.
# Shown as herdr's view only, where OpenCode is installed; installing it is
# the user's call (session restore for OpenCode started in herdr panes).
if command -v opencode >/dev/null 2>&1; then
  opencode_herdr_state="$(herdr_integration_state opencode)"
  if [[ -n "$opencode_herdr_state" ]]; then
    item "herdr's own view: opencode integration $opencode_herdr_state (~/.config/opencode/plugins/herdr-agent-state.js is placed by herdr integration install opencode and not managed by dotfiles; install it if you run OpenCode in herdr panes)"
  fi
fi

section "herdr config (report-only)"
# herdr-config module (#261): the managed ~/.config/herdr/config.toml carries
# the UI preferences and the built-in notification delivery ([ui.toast]
# delivery; herdr's own default is off) that agent-tools' herdr operations
# count on to hear about a finished worker. herdr reads exactly one file:
# HERDR_CONFIG_PATH if SET (even empty: then none, all defaults), else
# $XDG_CONFIG_HOME/herdr/config.toml if SET (even empty: then herdr/config.toml
# relative to herdr's cwd), else this one
# (measured, herdr 0.9.0) — so a variable in this environment can leave the
# managed file unread. The redirect is judged on its own, BEFORE presence: a
# missing managed file under a redirect does not mean "all defaults" (the
# other file may set delivery), and restoring it alone does not bring it
# into effect (Codex review, PR #273). Same file means the same spelling
# (trailing slashes of XDG_CONFIG_HOME dropped) or, when both exist, -ef.
# Validity comes from herdr itself: on a parse error (a value a newer herdr
# no longer accepts) it silently runs on ALL defaults, and `herdr config
# check` exits non-zero for that and for unknown keys (measured: it reads
# the file and writes nothing). It runs through bounded_probe, so an absent
# or hung herdr is "not checked"; its output is not shown (contents-blind).
# Drift of the managed file is the managed drift section's job. The rest of
# ~/.config/herdr (session.json, logs, sockets) is herdr's runtime state
# and never managed.
herdr_config="$HOME/.config/herdr/config.toml"
if module_active_for_profile "$profile" herdr-config; then
  if [[ -n "${HERDR_CONFIG_PATH+set}" ]]; then
    herdr_config_read="$HERDR_CONFIG_PATH"
  elif [[ -n "${XDG_CONFIG_HOME+set}" ]]; then
    if [[ -z "$XDG_CONFIG_HOME" ]]; then
      # Empty: herdr joins onto it, i.e. a path relative to its cwd (measured).
      herdr_config_read="herdr/config.toml"
    else
      herdr_xdg="$XDG_CONFIG_HOME"
      while [[ "$herdr_xdg" == */ ]]; do herdr_xdg="${herdr_xdg%/}"; done
      herdr_config_read="$herdr_xdg/herdr/config.toml"
    fi
  else
    herdr_config_read="$herdr_config"
  fi
  if [[ "$herdr_config_read" == "$herdr_config" || "$herdr_config_read" -ef "$herdr_config" ]]; then
    herdr_config_redirected=0
  else
    herdr_config_redirected=1
    warn "herdr config: HERDR_CONFIG_PATH or XDG_CONFIG_HOME in this environment points herdr at '$herdr_config_read', not the managed $herdr_config — the managed settings (including [ui.toast] delivery) are not in effect for a herdr started from here"
  fi
  if [[ ! -f "$herdr_config" ]]; then
    if [[ "$herdr_config_redirected" -eq 0 ]]; then
      herdr_config_missing_effect="herdr runs on its built-in defaults, so agent state changes raise no OS notification ([ui.toast] delivery defaults to off)"
    else
      herdr_config_missing_effect="restoring it takes effect only once the redirect above is gone"
    fi
    action "herdr config missing: $herdr_config (herdr-config module) — $herdr_config_missing_effect" \
      "\$ mkdir -p $(shell_quote_safe "$HOME/.config")" \
      "\$ chezmoi apply $(shell_quote_safe "$HOME/.config/herdr") $(shell_quote_safe "$herdr_config")"
  elif [[ "$herdr_config_redirected" -eq 1 ]]; then
    # herdr config check would validate the other file, not the managed one.
    item "herdr config: managed $herdr_config present (validity not checked: herdr reads another file here)"
  elif ! command -v herdr >/dev/null 2>&1; then
    ok "herdr config: managed $herdr_config present (validity not checked: herdr not on PATH)"
  else
    bounded_probe herdr config check
    case "$probe_rc" in
      0)
        ok "herdr config: managed $herdr_config present and accepted by herdr config check"
        ;;
      "")
        ok "herdr config: managed $herdr_config present (validity not checked: herdr config check gave no answer in time)"
        ;;
      *)
        action "herdr config: herdr config check did not pass for the managed $herdr_config (exit $probe_rc) — on a parse error herdr runs on ALL defaults, so agent state changes raise no OS notification; read its diagnostics, then fix the managed file" \
          "\$ herdr config check"
        ;;
    esac
  fi
else
  ok "herdr config not managed (herdr-config module inactive for profile $profile)"
fi

section "Codex review / worker profiles (report-only)"
# #264 (agent-tools#339 hand-off): codex-settings renders the Codex profile
# files that agent-tools' personal-codex-review and personal-codex-worker pick
# up whenever they exist (both read only the top-level model / effort and
# re-pass them with -c, agent-tools#358); without them both use the
# config.toml defaults. PRESENCE only — the contents are config values
# and stay out of the report; drift of a managed file is the managed drift
# section's job. agent-tools looks in $CODEX_HOME when it is set, while
# chezmoi always renders into ~/.codex, so a diverging CODEX_HOME is flagged.
# Each file carries the effort only, from its own capability (the review
# file's service tier went with #299: nothing reads it any more).
for codex_profile_kind in review worker; do
  case "$codex_profile_kind" in
    review) codex_profile_caps=(codexReviewEffort) ;;
    worker) codex_profile_caps=(codexWorkerEffort) ;;
  esac
  codex_profile_state=""
  codex_profile_set=""
  for codex_profile_cap in "${codex_profile_caps[@]}"; do
    codex_profile_value="$(capability_value "$profile" "$codex_profile_cap")"
    codex_profile_state+="${codex_profile_state:+, }$codex_profile_cap=$codex_profile_value"
    [[ "$codex_profile_value" != "off" ]] && codex_profile_set+="${codex_profile_set:+, }$codex_profile_cap=$codex_profile_value"
  done
  codex_profile_file="$HOME/.codex/agent-tools-$codex_profile_kind.config.toml"
  if module_active_for_profile "$profile" codex-settings; then
    if [[ -z "$codex_profile_set" ]]; then
      if [[ -e "$codex_profile_file" ]]; then
        action "$codex_profile_state but $codex_profile_file exists — agent-tools still reads it; chezmoi apply removes it (the managed target renders empty)" \
          "\$ chezmoi apply $(shell_quote_safe "$codex_profile_file")"
      else
        ok "$codex_profile_state; no $codex_profile_kind profile file (personal-codex-$codex_profile_kind uses the config.toml defaults)"
      fi
    elif [[ -f "$codex_profile_file" ]]; then
      ok "$codex_profile_state; $codex_profile_file present (read by personal-codex-$codex_profile_kind)"
    else
      action "$codex_profile_state but $codex_profile_file is missing — personal-codex-$codex_profile_kind falls back to the config.toml defaults" \
        "\$ chezmoi apply $(shell_quote_safe "$codex_profile_file")"
    fi
  else
    if [[ -n "$codex_profile_set" ]]; then
      warn "$codex_profile_set but the codex-settings module is inactive for this profile; nothing renders $codex_profile_file (dangling capability)"
    fi
    if [[ -e "$codex_profile_file" ]]; then
      item "$codex_profile_file present but not managed for this profile (hand-placed, or left by another profile — see managed-path orphans); agent-tools reads it whenever it exists"
    else
      ok "no $codex_profile_kind profile file (not managed for this profile; personal-codex-$codex_profile_kind uses the config.toml defaults)"
    fi
  fi
done
if [[ -n "${CODEX_HOME:-}" && "${CODEX_HOME%/}" != "$HOME/.codex" ]]; then
  warn "CODEX_HOME is set to $CODEX_HOME: agent-tools reads the review / worker profile files from there, but chezmoi renders them into ~/.codex"
fi

section "agent-tools usage reader (report-only)"
# agent-tools-usage-reader module (#301, agent-tools#385 hand-off): the managed
# ~/.config/agent-tools/usage-reader.json holds the argv that agent-tools'
# fixed wrapper personal-usage-reader runs (no shell, cwd /) to read the
# remaining usage budget; without the file agent-tools runs with "no usage
# reader" (assignment ignores the budget, the maintenance sweep stays small).
# The wrapper reads ${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/... but uses
# XDG_CONFIG_HOME only when it is an absolute path, while chezmoi renders into
# ~/.config — so an absolute XDG_CONFIG_HOME elsewhere is a redirect (same
# file: same spelling after dropping trailing slashes, or -ef).
# Presence (missing / a symlink to nothing / not a regular file) is
# dotfiles' own check. Whether a present file meets the contract is the
# wrapper's call (#303, agent-tools#400): doctor runs its --check, which
# validates the file and argv[0] with the wrapper's own code and never runs
# the reader (no file written, no child, no network), instead of copying its
# rules here. That is code from another repo, so it runs only under the
# enableAgentToolsStatus opt-in (as status.sh in the next section), through
# bounded_probe, and only once --help's usage line advertises [--check] (an
# older wrapper takes --check as a usage error, exit 2, indistinguishable
# from "invalid"; agent-tools' docs/boundary-with-dotfiles.md). "ok" means
# --check accepted the file, not that a read succeeded. Contents-blind: the
# contract keeps the config's values and paths out of the wrapper's one-line
# reason, the only thing of its output shown. The file is strict JSON with no
# room for a managed-by header, so the managed-path orphan scan cannot see it.
usage_reader_config="$HOME/.config/agent-tools/usage-reader.json"
usage_reader_wrapper="$HOME/.claude/agent-tools/scripts/personal-usage-reader"
# usage_reader_run_check — the wrapper's --check on the managed file: without
# XDG_CONFIG_HOME it reads ~/.config even where a redirect points it
# elsewhere. Its stdout is empty by contract, so its stderr (the reason line)
# is what bounded_probe collects.
usage_reader_run_check() {
  env -u XDG_CONFIG_HOME "$usage_reader_wrapper" --check 2>&1
}
# Where the wrapper reads, whatever the profile (it does not know profiles).
usage_reader_read="$usage_reader_config"
if [[ "${XDG_CONFIG_HOME:-}" == /* ]]; then
  usage_reader_xdg="$XDG_CONFIG_HOME"
  while [[ "$usage_reader_xdg" == */ ]]; do usage_reader_xdg="${usage_reader_xdg%/}"; done
  usage_reader_read="$usage_reader_xdg/agent-tools/usage-reader.json"
fi
if [[ "$usage_reader_read" == "$usage_reader_config" || "$usage_reader_read" -ef "$usage_reader_config" ]]; then
  usage_reader_redirected=0
else
  usage_reader_redirected=1
fi
if module_active_for_profile "$profile" agent-tools-usage-reader; then
  if [[ "$usage_reader_redirected" -eq 1 ]]; then
    warn "usage reader: XDG_CONFIG_HOME in this environment points agent-tools at '$usage_reader_read', not the managed $usage_reader_config — an agent started from here does not use the managed usage reader"
  fi
  # Under a redirect the wrapper reads the other file, so a broken or missing
  # managed file says nothing about what agent-tools reads (Codex review,
  # PR #302): the effect is only "takes effect once the redirect is gone".
  if [[ "$usage_reader_redirected" -eq 0 ]]; then
    usage_reader_broken_effect="personal-usage-reader fails (exit 2), so agent-tools reads no budget"
    usage_reader_missing_effect="agent-tools runs with no usage reader (assignment ignores the remaining budget; the maintenance sweep stays small)"
  else
    usage_reader_broken_effect="fixing it takes effect only once the redirect above is gone"
    usage_reader_missing_effect="restoring it takes effect only once the redirect above is gone"
  fi
  # Restores a missing file; also where --check finds none (exit 3).
  usage_reader_restore_steps=(
    "\$ mkdir -p $(shell_quote_safe "$HOME/.config")"
    "\$ chezmoi apply $(shell_quote_safe "$HOME/.config/agent-tools") $(shell_quote_safe "$usage_reader_config")"
  )
  if [[ ! -e "$usage_reader_config" && ! -L "$usage_reader_config" ]]; then
    action "usage reader config missing: $usage_reader_config (agent-tools-usage-reader module) — $usage_reader_missing_effect" \
      "${usage_reader_restore_steps[@]}"
  elif [[ ! -e "$usage_reader_config" ]]; then
    # A dangling symlink: the wrapper follows it, finds nothing and treats
    # the config as absent (exit 3), not as invalid (Codex review R3, PR #302).
    action "usage reader config $usage_reader_config is a symlink to nothing — $usage_reader_missing_effect" \
      "\$ rm -i $(shell_quote_safe "$usage_reader_config")   # the dangling link" \
      "\$ chezmoi apply $(shell_quote_safe "$usage_reader_config")"
  elif [[ ! -f "$usage_reader_config" ]]; then
    action "usage reader config $usage_reader_config is not a regular file — $usage_reader_broken_effect" \
      "\$ mv -i $(shell_quote_safe "$usage_reader_config") $(shell_quote_safe "$usage_reader_config.bak")   # keep it aside" \
      "\$ chezmoi apply $(shell_quote_safe "$usage_reader_config")"
  else
    usage_reader_unchecked="usage reader config $usage_reader_config present; contract not checked"
    usage_reader_sync_step="re-run the agent-tools sync (see the agent-tools README) so the current personal-usage-reader is deployed"
    if [[ "$(capability_value "$profile" enableAgentToolsStatus)" != "true" ]]; then
      item "$usage_reader_unchecked (doctor runs agent-tools' personal-usage-reader --check only under enableAgentToolsStatus=true)"
    elif [[ ! -f "$usage_reader_wrapper" || ! -x "$usage_reader_wrapper" ]]; then
      action "$usage_reader_unchecked: agent-tools' personal-usage-reader is not deployed at $usage_reader_wrapper, and nothing reads this config without it" \
        "$usage_reader_sync_step"
    else
      bounded_probe "$usage_reader_wrapper" --help
      if [[ -z "$probe_rc" ]]; then
        warn "$usage_reader_unchecked: personal-usage-reader --help gave no answer within ${probe_deadline}s (the probe was killed)"
      elif [[ "$probe_rc" != 0 ]]; then
        # Not necessarily an old wrapper: one that cannot run here (its
        # interpreter missing, say) fails too, and a sync would not help.
        warn "$usage_reader_unchecked: personal-usage-reader --help exited $probe_rc (it cannot run here, or predates --help)"
      elif [[ "${probe_lines%%$'\n'*}" != *"[--check]"* ]]; then
        action "$usage_reader_unchecked: the deployed personal-usage-reader predates --check (agent-tools#400)" \
          "$usage_reader_sync_step"
      else
        bounded_probe usage_reader_run_check
        case "$probe_rc" in
          0)
            ok "usage reader config $usage_reader_config present and accepted by personal-usage-reader --check (the agent-tools contract, argv[0] included; the reader itself not run)"
            ;;
          2)
            # The reason without the wrapper's name prefix, through
            # display_safe: it is another repo's output.
            usage_reader_reason="$(display_safe "${probe_lines%%$'\n'*}")"
            usage_reader_reason="${usage_reader_reason#personal-usage-reader: }"
            if [[ -n "$usage_reader_reason" ]]; then
              usage_reader_reason=" ($usage_reader_reason)"
            fi
            action "usage reader config $usage_reader_config rejected by personal-usage-reader --check$usage_reader_reason — $usage_reader_broken_effect" \
              "\$ chezmoi apply $(shell_quote_safe "$usage_reader_config")   # restores the managed content" \
              "\$ ./scripts/install-packages.sh   # when the reason is the executable: dry-run first; --apply installs the catalog's tacho, the managed argv[0] under ~/go/bin"
            ;;
          3)
            # The contract's "no config file" (Codex review R1, PR #324): the
            # file went away after the presence check above, so it is missing.
            action "usage reader config $usage_reader_config absent per personal-usage-reader --check (exit 3), though doctor found it a moment earlier — $usage_reader_missing_effect" \
              "${usage_reader_restore_steps[@]}"
            ;;
          "")
            warn "$usage_reader_unchecked: personal-usage-reader --check gave no answer within ${probe_deadline}s (the probe was killed)"
            ;;
          *)
            warn "$usage_reader_unchecked: personal-usage-reader --check exited $probe_rc, outside its contract (0 / 2 / 3)"
            ;;
        esac
      fi
    fi
  fi
else
  # Not managed here: report what is on disk, and claim what agent-tools
  # reads only when no redirect makes that another file (Codex review, PR #302).
  if [[ "$usage_reader_redirected" -eq 0 ]]; then
    usage_reader_reads_note="agent-tools' personal-usage-reader reads it whenever it exists"
    usage_reader_none_note="agent-tools runs with no usage reader"
  else
    usage_reader_reads_note="XDG_CONFIG_HOME points agent-tools at '$usage_reader_read' here instead"
    usage_reader_none_note="XDG_CONFIG_HOME points agent-tools at '$usage_reader_read' here"
  fi
  if [[ -e "$usage_reader_config" || -L "$usage_reader_config" ]]; then
    item "$usage_reader_config present but not managed for this profile (hand-placed?); $usage_reader_reads_note"
  else
    ok "no usage reader config (not managed for this profile; $usage_reader_none_note)"
  fi
fi

section "agent-tools (report-only)"
# Report-only companion check. dotfiles never clones/pulls/syncs
# agent-tools. Presence is reported whenever enableAiPolicy=true, but running
# its status.sh (executing code from another repo) is opt-in via
# enableAgentToolsStatus so doctor's no-side-effects invariant is never
# delegated implicitly.
# See docs/ai-environment-boundary.md and the agent-tools
# status-manifest-contract (contract_version 3).
# The expected path defaults to the dotfiles directory convention
# (~/src/agent/agent-tools) but is overridable via the AGENT_TOOLS env so a
# non-standard checkout can still be reported. presence only; never cloned.
# status.sh used to default its inspection root to its own cwd and falsely
# report an empty repo (#73); since agent-tools#305 it defaults to its own
# repo, but doctor still pins --root to the resolved checkout so the
# inspected tree is explicit on older checkouts too.
if [[ "$(capability_value "$profile" enableAiPolicy)" != "true" ]]; then
  ok "AI policy disabled; skipping agent-tools check"
else
  agent_tools_dir="${AGENT_TOOLS:-$HOME/src/agent/agent-tools}"
  agent_tools_status="$agent_tools_dir/scripts/status.sh"
  agent_tools_status_opt_in="$(capability_value "$profile" enableAgentToolsStatus)"
  # Absence is only a warning where the profile opted in to agent-tools'
  # status (it expects a checkout). Elsewhere it is the declared state — work
  # does not deploy agent-tools at all (profiles.yaml) — so a warn on every run
  # would bury real warnings (#258).
  if [[ ! -d "$agent_tools_dir" && "$agent_tools_status_opt_in" == "true" ]]; then
    warn "agent-tools not present at $agent_tools_dir (not auto-cloned)"
  elif [[ ! -d "$agent_tools_dir" ]]; then
    item "agent-tools not present at $agent_tools_dir (not expected by this profile: enableAgentToolsStatus=false; not auto-cloned)"
  elif [[ "$agent_tools_status_opt_in" != "true" ]]; then
    ok "agent-tools present; status read disabled (set enableAgentToolsStatus=true to let doctor run its status.sh)"
  elif [[ ! -x "$agent_tools_status" ]]; then
    warn "agent-tools present but scripts/status.sh is missing or not executable"
  elif ! status_json="$("$agent_tools_status" --root "$agent_tools_dir" --json 2>/dev/null)" || [[ -z "$status_json" ]]; then
    warn "agent-tools status.sh produced no usable output (skipping summary)"
  else
    # Null-safe queries plus `|| true` keep doctor report-only even if
    # the JSON is malformed (a failed substitution would trip set -e).
    sj() { display_safe "$(printf '%s' "$status_json" | yq -p json "$1" 2>/dev/null || true)"; }
    contract_version="$(sj '.contract_version // ""')"
    if [[ "$contract_version" != "3" ]]; then
      warn "agent-tools status contract_version=${contract_version:-unknown}, expected 3 (not interpreting fields)"
    else
      ok "agent-tools present; status contract v3"

      if [[ "$(sj '.repo.clean // false')" == "true" ]]; then
        ok "agent-tools working tree clean"
      else
        action "agent-tools working tree not clean" \
          "\$ git -C $(shell_quote_safe "$agent_tools_dir") status   # commit or discard, then re-run its sync"
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
        action "agent-tools has stale generated artifacts" \
          "regenerate in $agent_tools_dir (its build / sync; see the agent-tools README)"
      fi

      if [[ "$(sj '.register.catalog_present // false')" == "true" ]]; then
        item "register: registered=$(sj '.register.registered // 0') human_review=$(sj '.register.human_review_required // 0') unsupported=$(sj '.register.unsupported // 0')"
        if [[ "$(sj '.register.human_review_required // 0')" != "0" ]]; then
          warn "agent-tools assets require human review"
        fi
      else
        item "register: catalog not present"
      fi

      # Rows carry the target tool (claude-code / codex / opencode since
      # agent-tools#295; the contract stays v3), so counts and the tools a
      # finding touches are shown per tool (#263).
      sync_target_count="$(sj '.sync_targets // [] | length')"
      if [[ "$sync_target_count" == "0" ]]; then
        item "sync targets: 0"
      else
        item "sync targets: $sync_target_count ($(sj '[.sync_targets[]? | (.tool // "unknown")] | sort | group_by(.) | map(.[0] + " " + (length | tostring)) | join(", ")'))"
      fi
      if [[ "$(sj '[.sync_targets[]? | select(.state == "conflict")] | length')" != "0" ]]; then
        warn "agent-tools sync conflicts (unmanaged same-name targets; tools: $(sj '[.sync_targets[]? | select(.state == "conflict") | (.tool // "unknown")] | sort | unique | join(", ")')); sync must not change them"
      fi
      if [[ "$(sj '[.sync_targets[]? | select(.state == "stale")] | length')" != "0" ]]; then
        action "agent-tools has stale sync targets (generated artifact newer than target; tools: $(sj '[.sync_targets[]? | select(.state == "stale") | (.tool // "unknown")] | sort | unique | join(", ")'))" \
          "re-run the agent-tools sync from $agent_tools_dir (see its README) so the deployed copies match"
      fi
      # v3 (#194): gated-but-still-deployed leftovers are cleanup candidates.
      if [[ "$(sj '[.sync_targets[]? | select(.state == "deployed_but_inactive")] | length')" != "0" ]]; then
        warn "agent-tools has deployed-but-inactive sync targets (gated entries still on disk; tools: $(sj '[.sync_targets[]? | select(.state == "deployed_but_inactive") | (.tool // "unknown")] | sort | unique | join(", ")'); clean up or re-approve)"
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
report_standard_project_roots

# Close with the numbered list of everything reported through `action`
# (#227): what to run, and why, without re-reading the report. Printed even
# under --actions-only.
report_actions

# doctor is report-only: warnings never change the exit code.
# The only non-zero path is the policy validation at the top.
exit 0
