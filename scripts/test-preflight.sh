#!/usr/bin/env bash
set -euo pipefail

# Behavior tests for preflight.sh (#150 — it had none and never ran in CI).
# Hermetic: a fixture HOME per case; the repo itself is only copied for the
# one case that needs broken policy data. Contract under test: report-only
# (exit 0 whatever the host looks like) except a failing policy validation,
# plus the apply-impact warnings that protect an existing host from a
# surprising first apply.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

status=0
pass() { ok "test passed: $*"; }
miss() {
  fail "test failed: $*"
  status=1
}

fixture_home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-preflight-test.XXXXXX")"
trap 'rm -rf "$fixture_home"' EXIT

# 1. An empty home stays report-only: exit 0, no apply-impact warnings.
empty_home="$fixture_home/empty"
mkdir -p "$empty_home"
if pf_out="$(HOME="$empty_home" "$SCRIPT_DIR/preflight.sh" personal 2>&1)"; then
  if grep -Fq "preflight profile: personal" <<< "$pf_out" \
    && ! grep -Fq "replaces it" <<< "$pf_out"; then
    pass "empty home: exit 0 and no apply-impact warnings"
  else
    printf '%s\n' "$pf_out" >&2
    miss "empty home should report cleanly without replace warnings"
  fi
else
  printf '%s\n' "$pf_out" >&2
  miss "preflight must exit 0 on an empty home (report-only)"
fi

# 2. shell-extra apply impact (personal manages the shell files): an existing
#    ~/.zshrc warns with the .local pointer; .zshenv and starship.toml carry
#    their special no-local-override wording.
shell_home="$fixture_home/shell"
mkdir -p "$shell_home/.config"
printf '# existing\n' > "$shell_home/.zshrc"
printf '# existing\n' > "$shell_home/.zshenv"
printf '# existing\n' > "$shell_home/.config/starship.toml"
if pf_out="$(HOME="$shell_home" "$SCRIPT_DIR/preflight.sh" personal 2>&1)"; then
  if grep -Fq ".zshrc — apply (shell-extra) replaces it; move machine-specific lines to ~/.zshrc.local" <<< "$pf_out" \
    && grep -Fq ".zshenv has no ~/.zshenv.local" <<< "$pf_out" \
    && grep -Fq "starship has no local override" <<< "$pf_out"; then
    pass "shell-extra: existing shell files warn with the right override pointers"
  else
    printf '%s\n' "$pf_out" >&2
    miss "shell-extra apply-impact warnings missing or wrong"
  fi
else
  printf '%s\n' "$pf_out" >&2
  miss "preflight must exit 0 with existing shell files"
fi

# 3. A path whose module the profile does not carry is a left-as-is item,
#    not a replace warning. work has no ssh-1password module, so an existing
#    ~/.ssh/config exercises the unmanaged branch (shell files are managed by
#    work since the #146 profile merge, so they no longer fit this case).
unmanaged_home="$fixture_home/unmanaged"
mkdir -p "$unmanaged_home/.ssh"
printf 'Host canary-host\n' > "$unmanaged_home/.ssh/config"
if pf_out="$(HOME="$unmanaged_home" "$SCRIPT_DIR/preflight.sh" work 2>&1)"; then
  if grep -Fq "not managed for profile work (left as-is)" <<< "$pf_out" \
    && ! grep -Fq "apply (ssh-1password) replaces it" <<< "$pf_out"; then
    pass "unmanaged module path: existing ssh config is a left-as-is item"
  else
    printf '%s\n' "$pf_out" >&2
    miss "unmanaged module path must not warn about replacing ssh config"
  fi
else
  printf '%s\n' "$pf_out" >&2
  miss "preflight must exit 0 for work"
fi

# 4. ssh-1password apply impact: an existing ~/.ssh/config warns with the
#    config.local pointer; a present config.local is reported by existence
#    only (its contents never echo).
ssh_home="$fixture_home/ssh"
mkdir -p "$ssh_home/.ssh"
printf 'Host canary-host\n  User canary-user\n' > "$ssh_home/.ssh/config"
printf 'Host secret-canary\n' > "$ssh_home/.ssh/config.local"
if pf_out="$(HOME="$ssh_home" "$SCRIPT_DIR/preflight.sh" personal 2>&1)"; then
  if grep -Fq "apply (ssh-1password) replaces it; move machine-specific hosts to ~/.ssh/config.local" <<< "$pf_out" \
    && grep -Fq "local override present" <<< "$pf_out" \
    && ! grep -Fq "secret-canary" <<< "$pf_out"; then
    pass "ssh: replace warning + local-override presence, contents never echoed"
  else
    printf '%s\n' "$pf_out" >&2
    miss "ssh apply-impact warning wrong, or config.local contents leaked"
  fi
else
  printf '%s\n' "$pf_out" >&2
  miss "preflight must exit 0 with an existing ssh config"
fi

# 5. ~/.config permission: 0755 warns about the 0700 change; 0700 is ok.
perm_home="$fixture_home/perm"
mkdir -p "$perm_home/.config"
chmod 755 "$perm_home/.config"
if pf_out="$(HOME="$perm_home" "$SCRIPT_DIR/preflight.sh" personal 2>&1)"; then
  if grep -Fq "mode is 755; apply manages it at 0700" <<< "$pf_out"; then
    pass "config dir at 0755 warns about the 0700 change"
  else
    printf '%s\n' "$pf_out" >&2
    miss "0755 config dir should warn about the mode change"
  fi
else
  printf '%s\n' "$pf_out" >&2
  miss "preflight must exit 0 with a 0755 config dir"
fi
chmod 700 "$perm_home/.config"
if pf_out="$(HOME="$perm_home" "$SCRIPT_DIR/preflight.sh" personal 2>&1)"; then
  if grep -Fq "mode already 0700" <<< "$pf_out"; then
    pass "config dir at 0700 reports ok"
  else
    printf '%s\n' "$pf_out" >&2
    miss "0700 config dir should report ok"
  fi
else
  printf '%s\n' "$pf_out" >&2
  miss "preflight must exit 0 with a 0700 config dir"
fi

# 5b. git-ignore apply impact (#248): personal manages ~/.config/git/ignore
#     (git's default global excludes file), so an existing one warns with the
#     .git/info/exclude pointer, and a set core.excludesFile warns WITHOUT
#     showing its value; an explicitly empty one has its own wording. work
#     does not list the module: left-as-is item. The runs are hermetic
#     (`env -i` with PATH, HOME and GIT_CONFIG_NOSYSTEM only), so the
#     developer shell's GIT_CONFIG_GLOBAL / XDG_CONFIG_HOME and the host's
#     system gitconfig cannot leak into the fixture (Codex review).
gi_home="$fixture_home/gitignore"
mkdir -p "$gi_home/.config/git"
printf '# host patterns\n' > "$gi_home/.config/git/ignore"
gi_canary="$gi_home/canary-excludes-7c1d"
printf '[core]\n\texcludesFile = %s\n' "$gi_canary" > "$gi_home/.gitconfig"
if pf_out="$(env -i PATH="$PATH" HOME="$gi_home" GIT_CONFIG_NOSYSTEM=1 "$SCRIPT_DIR/preflight.sh" personal 2>&1)"; then
  if grep -Fq "$gi_home/.config/git/ignore — apply (git-ignore) replaces it; git reads one global excludes file (no .local), so move host-specific patterns to each repo's .git/info/exclude first" <<< "$pf_out" \
    && grep -Fq "core.excludesFile is set (value not shown; global or system config)" <<< "$pf_out" \
    && ! grep -Fq "$gi_canary" <<< "$pf_out"; then
    pass "git-ignore: existing global ignore warns with the exclude pointer; a set core.excludesFile warns without its value"
  else
    printf '%s\n' "$pf_out" >&2
    miss "git-ignore apply-impact warnings missing, wrong, or leaking the excludesFile value"
  fi
else
  printf '%s\n' "$pf_out" >&2
  miss "preflight must exit 0 with an existing global gitignore"
fi
printf '[core]\n\texcludesFile =\n' > "$gi_home/.gitconfig"
if pf_out="$(env -i PATH="$PATH" HOME="$gi_home" GIT_CONFIG_NOSYSTEM=1 "$SCRIPT_DIR/preflight.sh" personal 2>&1)" \
  && grep -Fq "core.excludesFile is explicitly empty (global or system config) — git reads no global excludes file" <<< "$pf_out" \
  && ! grep -Fq "core.excludesFile is set (value not shown" <<< "$pf_out"; then
  pass "git-ignore: an explicitly empty core.excludesFile gets its own warning (not the set/redirect one)"
else
  printf '%s\n' "${pf_out:-<no output>}" >&2
  miss "explicitly empty core.excludesFile must warn that git reads no global excludes file"
fi
rm -f "$gi_home/.gitconfig"
if pf_out="$(env -i PATH="$PATH" HOME="$gi_home" GIT_CONFIG_NOSYSTEM=1 "$SCRIPT_DIR/preflight.sh" work 2>&1)"; then
  if grep -Fq "$gi_home/.config/git/ignore — not managed for profile work (left as-is)" <<< "$pf_out" \
    && ! grep -Fq "apply (git-ignore) replaces it" <<< "$pf_out"; then
    pass "git-ignore: work leaves an existing global ignore as-is"
  else
    printf '%s\n' "$pf_out" >&2
    miss "work must report the existing global ignore as left-as-is, not replaced"
  fi
else
  printf '%s\n' "$pf_out" >&2
  miss "preflight must exit 0 for work with an existing global gitignore"
fi
if pf_out="$(env -i PATH="$PATH" HOME="$empty_home" GIT_CONFIG_NOSYSTEM=1 "$SCRIPT_DIR/preflight.sh" personal 2>&1)" \
  && grep -Fq "absent: $empty_home/.config/git/ignore (apply creates the managed global gitignore)" <<< "$pf_out"; then
  pass "git-ignore: absent global ignore is an ok line (apply creates it)"
else
  printf '%s\n' "${pf_out:-<no output>}" >&2
  miss "personal with no global ignore must report the absent/creates ok line"
fi

# 5c. herdr-config apply impact (#261): personal manages
#     ~/.config/herdr/config.toml, so an existing one warns (herdr reads one
#     file, no .local: fold host-only settings into the managed file); work
#     does not list the module: left-as-is item; absent: ok line.
hc_home="$fixture_home/herdr"
mkdir -p "$hc_home/.config/herdr"
printf '[ui]\nagent_panel_sort = "spaces"\n' > "$hc_home/.config/herdr/config.toml"
if pf_out="$(HOME="$hc_home" "$SCRIPT_DIR/preflight.sh" personal 2>&1)" \
  && grep -Fq "exists: $hc_home/.config/herdr/config.toml — apply (herdr-config) replaces it; herdr reads one config file (no .local), so diff first and fold host-only settings into the managed file" <<< "$pf_out"; then
  pass "herdr-config: an existing herdr config warns that apply replaces it (no .local)"
else
  printf '%s\n' "${pf_out:-<no output>}" >&2
  miss "personal with an existing herdr config must warn that apply replaces it"
fi
if pf_out="$(HOME="$hc_home" "$SCRIPT_DIR/preflight.sh" work 2>&1)" \
  && grep -Fq "exists: $hc_home/.config/herdr/config.toml — not managed for profile work (left as-is)" <<< "$pf_out" \
  && ! grep -Fq "apply (herdr-config) replaces it" <<< "$pf_out"; then
  pass "herdr-config: work leaves an existing herdr config as-is"
else
  printf '%s\n' "${pf_out:-<no output>}" >&2
  miss "work must report the existing herdr config as left-as-is, not replaced"
fi
if pf_out="$(HOME="$empty_home" "$SCRIPT_DIR/preflight.sh" personal 2>&1)" \
  && grep -Fq "absent: $empty_home/.config/herdr/config.toml (apply creates the managed herdr config)" <<< "$pf_out"; then
  pass "herdr-config: absent herdr config is an ok line (apply creates it)"
else
  printf '%s\n' "${pf_out:-<no output>}" >&2
  miss "personal with no herdr config must report the absent/creates ok line"
fi

# 5d. agent-tools-usage-reader apply impact (#301): personal manages
#     ~/.config/agent-tools/usage-reader.json, so an existing one warns
#     (agent-tools reads that one file, no .local: diff first); work does not
#     list the module: left-as-is item; absent: ok line.
ur_home="$fixture_home/usage-reader"
mkdir -p "$ur_home/.config/agent-tools"
printf '{"argv": ["/usr/bin/true"]}\n' > "$ur_home/.config/agent-tools/usage-reader.json"
if pf_out="$(HOME="$ur_home" "$SCRIPT_DIR/preflight.sh" personal 2>&1)" \
  && grep -Fq "exists: $ur_home/.config/agent-tools/usage-reader.json — apply (agent-tools-usage-reader) replaces it; agent-tools reads this one file (no .local), so diff first" <<< "$pf_out"; then
  pass "agent-tools-usage-reader: an existing usage reader config warns that apply replaces it"
else
  printf '%s\n' "${pf_out:-<no output>}" >&2
  miss "personal with an existing usage reader config must warn that apply replaces it"
fi
if pf_out="$(HOME="$ur_home" "$SCRIPT_DIR/preflight.sh" work 2>&1)" \
  && grep -Fq "exists: $ur_home/.config/agent-tools/usage-reader.json — not managed for profile work (left as-is)" <<< "$pf_out" \
  && ! grep -Fq "apply (agent-tools-usage-reader) replaces it" <<< "$pf_out"; then
  pass "agent-tools-usage-reader: work leaves an existing usage reader config as-is"
else
  printf '%s\n' "${pf_out:-<no output>}" >&2
  miss "work must report the existing usage reader config as left-as-is, not replaced"
fi
if pf_out="$(HOME="$empty_home" "$SCRIPT_DIR/preflight.sh" personal 2>&1)" \
  && grep -Fq "absent: $empty_home/.config/agent-tools/usage-reader.json (apply creates the managed usage reader config)" <<< "$pf_out"; then
  pass "agent-tools-usage-reader: absent usage reader config is an ok line (apply creates it)"
else
  printf '%s\n' "${pf_out:-<no output>}" >&2
  miss "personal with no usage reader config must report the absent/creates ok line"
fi

# 6. The only non-zero path: a failing policy validation aborts (a broken
#    profiles.yaml in a repo copy — the mutation is fail-closed because the
#    exit-1 assertion itself would fail on a no-op).
broken_root="$fixture_home/broken"
copy_repo_fixture "$broken_root"
printf 'profiles: {}\n' > "$broken_root/.chezmoidata/profiles.yaml"
if HOME="$empty_home" "$broken_root/scripts/preflight.sh" personal >/dev/null 2>&1; then
  miss "preflight must exit non-zero when policy validation fails"
else
  pass "broken policy data makes preflight exit non-zero (fail-closed)"
fi

# Commands section (#259): every tool preflight checks is declared in the
# software catalog (name / pkg / bin) or is one of the named prerequisites
# outside it, so a tool dropped from the catalog (shfmt, #53) cannot keep
# warning "not found" on every machine installed from the catalog.
require_yq || exit 1
commands_lines="$(grep -E '^for command_name in .*; do$' "$SCRIPT_DIR/preflight.sh" || true)"
if [[ "$(grep -c . <<< "$commands_lines")" -ne 1 ]]; then
  miss "commands section: expected exactly one 'for command_name in ...; do' loop in preflight.sh"
else
  commands_list="${commands_lines#for command_name in }"
  commands_list="${commands_list%; do}"
  prereqs_outside_catalog=" git brew node npm corepack "
  commands_checked=0
  commands_bad=""
  for command_name in $commands_list; do
    commands_checked=$((commands_checked + 1))
    [[ "$prereqs_outside_catalog" == *" $command_name "* ]] && continue
    declared="$(C="$command_name" yq '[.packages[] | select(.name == strenv(C) or .pkg == strenv(C) or .bin == strenv(C))] | length' "$DOTFILES_ROOT/.chezmoidata/packages.yaml")"
    [[ "$declared" == "0" ]] && commands_bad+=" $command_name"
  done
  if [[ "$commands_checked" -eq 0 ]]; then
    miss "commands section: parsed an empty command list"
  elif [[ -n "$commands_bad" ]]; then
    miss "commands section checks tools that are neither in the catalog nor a named prerequisite:$commands_bad"
  else
    pass "commands section: all $commands_checked checked tools are in the catalog or named prerequisites"
  fi
fi

if [[ "$status" -eq 0 ]]; then
  ok "preflight tests passed"
fi
exit "$status"
