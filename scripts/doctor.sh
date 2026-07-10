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
elif ! npm_version="$(npm --version 2>/dev/null)" || [[ -z "$npm_version" ]]; then
  # A mise shim resolves on PATH even when no node runtime is installed; the
  # unguarded probe used to kill the whole doctor here via set -e, breaking
  # the report-only contract (#144).
  warn "npm on PATH but not runnable (shim without a runtime?); skipping npm checks"
else
  ok "npm: $npm_version"
  for key in before ignore-scripts save-exact fund audit userconfig globalconfig; do
    value="$(npm config get "$key" 2>/dev/null || true)"
    item "npm $key=$value"
  done
  npm_major="${npm_version%%.*}"
  npm_minor="$(printf '%s' "$npm_version" | cut -d. -f2)"
  # Guard before the arithmetic test: [[ -gt ]] evaluates its operands as
  # arithmetic, so a non-numeric component resolves as a variable name and
  # aborts the shell under set -u (the old 2>/dev/null hid even that) (#144).
  if [[ ! "$npm_major" =~ ^[0-9]+$ || ! "$npm_minor" =~ ^[0-9]+$ ]]; then
    warn "npm version '$npm_version' not recognized; cannot check min-release-age support"
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
elif profile_allows_secrets_access "$profile"; then
  warn "no backup recorded yet (run private-backup.sh backup)"
else
  # The backup runtime gate refuses profiles without allowSecretsAccess, so
  # "never ran" is the designed steady state here, not an actionable warning.
  item "no backup recorded (backup requires allowSecretsAccess=true; refused for profile $profile by design)"
fi

section "managed-path orphans"
# A file that carries the managed-by header but whose path is not
# managed for this profile is likely left over from another profile
# (e.g. ~/.npmrc after switching personal -> work). Report
# only; nothing is removed. Only the header line is inspected.
# Only declared FILE paths are inspected: directory declarations are
# .chezmoiignore gate plumbing (every managed file has its own line in
# modules.yaml), and recursing into them swept unrelated tool data that
# merely quotes the header — ~/.claude session logs / paste-cache — into
# false orphans (#174).
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
      warn "managed-by header but not managed for profile $profile: $target (orphan from another profile?)"
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
  # No initialized config in this HOME (e.g. test fixtures, pre-bootstrap).
  item "chezmoi not initialized for this home; skipping drift check"
else
  drift_lines=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    drift_lines=$((drift_lines + 1))
    warn "drift: $line (inspect with: chezmoi diff)"
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

section "AI policy"
if [[ "$(capability_value "$profile" enableAiPolicy)" == "true" ]]; then
  ok "enableAiPolicy=true (policy docs + report-only checks; see docs/ai-policy.md)"
  item "boundary today: directory convention + Git identity separation + policy docs"
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
    codex_rules="$HOME/.codex/rules/default.rules"
    if [[ -f "$codex_rules" ]]; then
      ok "Codex approval-rules baseline managed: ~/.codex/rules/default.rules (accumulated grants show as drift; apply resets to the vetted read-only baseline)"
      # Rules semantics are delegated to Codex's own engine: a fixed probe list
      # of outward/escalation commands is evaluated with `codex execpolicy
      # check` against the LIVE rules file. Grepping rule lines was rejected
      # (Codex review #187): it misses blanket prefixes (["gh","pr"] auto-allows
      # `gh pr create` — the exact 2026-07-02 regression form), multi-line
      # rules, and the omitted-decision default (= allow), and echoing rule
      # lines could leak secrets embedded in arbitrary pattern/justification
      # strings. The probe approach never reads the rules file here (the path is
      # only passed to codex) and only OUR fixed probe strings are echoed.
      if command -v codex >/dev/null 2>&1; then
        # Policy-derived probe set: every outward-action / escalation family the
        # Approval Required list in docs/ai-policy.md names, plus the raw-write
        # escape hatches (gh api POST, gh secret). Keep in sync with the pin in
        # test-doctor.sh (the fake-shim log asserts this exact set so a dropped
        # probe fails the test).
        outward_probes=(
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
          "sudo -v"
          "curl https://example.invalid"
          "wget https://example.invalid"
        )
        outward_allowed=0
        probe_failures=0
        for probe in "${outward_probes[@]}"; do
          # shellcheck disable=SC2086 # probes are fixed strings; word-splitting into tokens is intended
          if verdict="$(codex execpolicy check --rules "$codex_rules" $probe 2>/dev/null)"; then
            if grep -Fq '"decision":"allow"' <<< "$verdict"; then
              outward_allowed=$((outward_allowed + 1))
              warn "outward/escalation probe auto-allowed by live Codex rules: '$probe' (revoke the covering allow rule or move it behind approval; apply resets to the baseline)"
            fi
          else
            # rc!=0 = the engine could not evaluate (broken rules file, old
            # codex, unreadable path) — that is NOT "not allowed". Never let an
            # evaluation failure read as a clean scan (fail-open false-clean).
            probe_failures=$((probe_failures + 1))
          fi
        done
        if [[ "$probe_failures" -gt 0 ]]; then
          warn "rules-semantics scan INCOMPLETE: $probe_failures of ${#outward_probes[@]} probes failed to evaluate (codex execpolicy error — broken rules file or incompatible codex?); do NOT read this as clean"
        elif [[ "$outward_allowed" -eq 0 ]]; then
          ok "no outward/escalation probe is auto-allowed by the live Codex rules (${#outward_probes[@]} probes via codex execpolicy; read-only baseline holding)"
        fi
      else
        item "codex CLI not found; rules-semantics probe skipped (baseline presence still verified above)"
      fi
    else
      item "Codex approval-rules baseline not applied yet (chezmoi apply deploys ~/.codex/rules/default.rules)"
    fi
    # [projects] trust watch: parse ONLY [projects."<path>"] section headers and
    # the trust_level key inside each section (an entry can be "untrusted" —
    # only trusted ones matter). config.toml also carries MCP server env blocks
    # that may hold secrets, so nothing else is read or echoed (key-name-only
    # discipline, same as the #148 token scan).
    codex_config="$HOME/.codex/config.toml"
    if [[ -f "$codex_config" ]]; then
      # Tolerate the valid TOML spellings codex may write: optional whitespace
      # around `=` (compact `trust_level="trusted"` included) and single-quoted
      # literal strings. A parse/read failure must surface as an INCOMPLETE
      # scan, never as "0 trusted" (fail-open false-clean).
      if trusted_paths="$(awk '
        /^[[:space:]]*\[projects\."/ {
          p = $0
          sub(/^[[:space:]]*\[projects\."/, "", p)
          sub(/"\][[:space:]]*$/, "", p)
          current = p
          next
        }
        /^[[:space:]]*\[/ { current = "" ; next }
        current != "" && $0 ~ /^[[:space:]]*trust_level[[:space:]]*=[[:space:]]*("trusted"|'\''trusted'\'')[[:space:]]*(#.*)?$/ {
          print current
          current = ""
        }
      ' "$codex_config" 2>/dev/null)"; then
        trusted_total=0
        while IFS= read -r trusted_path; do
          [[ -z "$trusted_path" ]] && continue
          trusted_total=$((trusted_total + 1))
          if [[ "$trusted_path" == "$HOME" ]]; then
            warn "Codex projects trust covers the WHOLE home directory ($trusted_path) — every repo and file under ~ inherits trust; remove it in codex (config.toml is codex-owned, not managed here)"
          elif [[ ! -d "$trusted_path" ]]; then
            warn "stale Codex projects trust (path no longer exists): $trusted_path — leftover grant; remove it in codex"
          fi
        done <<< "$trusted_paths"
        item "Codex projects trust: $trusted_total path(s) trusted (report-only; codex-owned config.toml, project headers + trust_level scanned only)"
      else
        warn "projects-trust scan INCOMPLETE: could not parse ~/.codex/config.toml project headers; do NOT read this as zero trusted"
      fi
    else
      item "no ~/.codex/config.toml (codex not initialized); projects-trust watch skipped"
    fi
  else
    item "Codex-side permission files not managed for this profile (codex-settings module inactive)"
  fi
else
  ok "AI policy checks disabled for profile"
fi
if [[ "$(capability_value "$profile" enableAiTools)" == "true" ]]; then
  warn "enableAiTools=true but no implementation exists yet (nothing is managed; roadmap placeholder)"
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
    ok "enforceAiSandbox=true; managed ~/.claude/settings.json carries the native sandbox (Bash fs+network) and the human-legit GitHub write gate (main-push + .env-read deny, release/protection ask; best-effort — the never-legit secret floor is unconditional, see the injection guard section)"
  else
    warn "enforceAiSandbox=true but the claude-settings module is inactive for this profile; no managed settings carry the sandbox block (dangling capability)"
  fi
else
  ok "Claude Code native sandbox not enforced via managed settings (enforceAiSandbox=false)"
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
  # context for these is #119 Phase 3 (#131) — disclose the live state so the
  # green line above is not read as a complete injection guard.
  if [[ "$(capability_value "$profile" enforceAiSandbox)" == "true" ]]; then
    item "human-legit write gate active (enforceAiSandbox): main-push + .env-read deny, release/protection ask"
  else
    item "human-legit write gate INERT (enforceAiSandbox=false): main-push / .env-read deny and release/protection ask are not rendered — needs a restricted context (#119 Phase 3, #131), not the daily-driver egress block"
  fi
  # The main-push deny is leaky steering even where it renders: the matcher
  # `git push * main|master` only catches the explicit trailing-`main` form and
  # misses bare `git push`, `git push origin HEAD`, and refspecs (`HEAD:main`).
  # Verified against Claude Code matcher semantics (#119). Disclosed so the deny
  # is not mistaken for a real main-push boundary — the real enforcement is
  # server-side branch protection or the Phase 3 isolated reader (#131).
  item "note: the main-push deny is leaky steering — catches 'git push … main', misses bare 'git push' / HEAD / refspec; real block is branch protection or the Phase 3 isolated reader (#131)"
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
  # Claude — even a registered+present hook is silently skipped until a one-time
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
# Trust list (#119 PR3): the self trust basis (GitHub login + numeric id) plus
# any opt-in trusted collaborators live in a non-committed local file consumed by
# the isolated reader / safe-gh (Phase 3). Pointer only — never read here. Its
# existence is reported contents-blind by the private-backup section (it is in
# backup-paths.yaml). Absent ⇒ fail closed (only self is trusted).
item "trust list: ~/.config/dotfiles/github-trust.local (#119; contents never read; absent ⇒ only self trusted)"

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
# status.sh defaults its inspection root to its own cwd, so doctor pins
# --root to the resolved checkout; otherwise it would inspect doctor's cwd
# and falsely report an empty repo (#73).
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
  elif ! status_json="$("$agent_tools_status" --root "$agent_tools_dir" --json 2>/dev/null)" || [[ -z "$status_json" ]]; then
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
# Standard roots (docs/directory-convention.md). They are optional: repos may
# live outside ~/src (a non-standard placement) with repo-local identity, so a
# missing standard root is reported neutrally, not as a warning (#134).
for dir in "$HOME/src/personal" "$HOME/src/work" "$HOME/src/client" "$HOME/src/sandbox" "$HOME/src/agent"; do
  if [[ -d "$dir" ]]; then
    ok "exists: $dir"
  else
    item "not present (standard root, optional): $dir"
  fi
done

# doctor is report-only: warnings never change the exit code.
# The only non-zero path is the policy validation at the top.
exit 0
