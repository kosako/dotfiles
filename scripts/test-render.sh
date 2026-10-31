#!/usr/bin/env bash
set -euo pipefail

# Render every profile into a throwaway destination and assert the
# managed target set. This is the apply-shaped safety net: template
# errors and unexpected managed targets fail here before any real
# `chezmoi apply`. It never touches the real home directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

require_yq || exit 1

if ! command -v jq >/dev/null 2>&1; then
  fail "jq not found; the JSON validity checks (strict_json_object) need it"
  exit 1
fi

if ! command -v chezmoi >/dev/null 2>&1; then
  fail "chezmoi not found; render tests require it"
  exit 1
fi

status=0
tmp_roots=()

cleanup() {
  local dir
  if [[ "${#tmp_roots[@]}" -eq 0 ]]; then
    return 0
  fi
  for dir in "${tmp_roots[@]}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

make_root() {
  root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-render-test.XXXXXX")"
  tmp_roots+=("$root")
  mkdir -p "$root/home"
}

write_config() {
  local profile="$1"
  printf '[data]\nprofile = "%s"\n' "$profile" > "$root/chezmoi.toml"
}

throwaway_chezmoi() {
  chezmoi --config "$root/chezmoi.toml" \
    --source "$DOTFILES_ROOT" --destination "$root/home" "$@"
}

# Every profile must have an expected managed set here. Adding or
# changing a profile without updating this list fails the test.
expected_managed() {
  local profile="$1"
  case "$profile" in
    personal)
      printf '%s\n' .claude .claude/settings.json .codex .codex/agent-tools-review.config.toml .codex/agent-tools-worker.config.toml .codex/hooks.json .codex/rules .codex/rules/default.rules .config .config/agent-tools .config/agent-tools/usage-reader.json .config/git .config/git-hook-gates .config/git-hook-gates/hooks .config/git-hook-gates/hooks.gitconfig .config/git-hook-gates/hooks/applypatch-msg .config/git-hook-gates/hooks/commit-msg .config/git-hook-gates/hooks/p4-changelist .config/git-hook-gates/hooks/p4-post-changelist .config/git-hook-gates/hooks/p4-pre-submit .config/git-hook-gates/hooks/p4-prepare-changelist .config/git-hook-gates/hooks/post-applypatch .config/git-hook-gates/hooks/post-checkout .config/git-hook-gates/hooks/post-commit .config/git-hook-gates/hooks/post-merge .config/git-hook-gates/hooks/post-receive .config/git-hook-gates/hooks/post-rewrite .config/git-hook-gates/hooks/post-update .config/git-hook-gates/hooks/pre-applypatch .config/git-hook-gates/hooks/pre-auto-gc .config/git-hook-gates/hooks/pre-commit .config/git-hook-gates/hooks/pre-merge-commit .config/git-hook-gates/hooks/pre-push .config/git-hook-gates/hooks/pre-rebase .config/git-hook-gates/hooks/pre-receive .config/git-hook-gates/hooks/prepare-commit-msg .config/git-hook-gates/hooks/sendemail-validate .config/git-hook-gates/hooks/update .config/git-profile .config/git-profile/identity-reset.gitconfig .config/git/ignore .config/git/signing.gitconfig .config/herdr .config/herdr/config.toml .config/mise .config/mise/config.toml .config/opencode .config/opencode/opencode.json .config/starship.toml .gitconfig .npmrc .ssh .ssh/config .zprofile .zshenv .zshrc
      ;;
    work)
      printf '%s\n' .config .config/git .config/git-profile .config/git-profile/identity-reset.gitconfig .config/git/gh-credential.gitconfig .config/mise .config/mise/config.toml .config/starship.toml .gitconfig .zprofile .zshenv .zshrc
      ;;
    *)
      return 1
      ;;
  esac
}

section "render and managed set per profile"

profiles_found=0
while IFS= read -r profile; do
  [[ -z "$profile" ]] && continue
  profiles_found=1

  if ! expected="$(expected_managed "$profile")"; then
    fail "no expected managed set for profile: $profile (update test-render.sh)"
    status=1
    continue
  fi

  make_root
  write_config "$profile"

  if ! output="$(throwaway_chezmoi apply 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "test failed: apply renders for $profile"
    status=1
    continue
  fi
  ok "test passed: apply renders for $profile"

  managed="$(throwaway_chezmoi managed | sort)"
  if diff_output="$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$managed"))"; then
    ok "test passed: managed set matches for $profile"
  else
    printf '%s\n' "$diff_output" >&2
    fail "test failed: managed set mismatch for $profile"
    status=1
  fi
  # What apply wrote is part of the managed set, so the pin above also holds
  # on disk: e.g. work, which does not list opencode-settings, gets no
  # ~/.config/opencode. A subset, not equality: a managed template that
  # renders empty is not written.
  unmanaged="$(LC_ALL=C comm -13 <(printf '%s\n' "$managed" | LC_ALL=C sort) \
    <(cd "$root/home" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort))"
  if [[ -z "$unmanaged" ]]; then
    ok "test passed: apply writes nothing outside the managed set for $profile"
  else
    printf '%s\n' "$unmanaged" >&2
    fail "test failed: apply wrote entries outside the managed set for $profile"
    status=1
  fi

  # #305: the managed mise config leaves GOBIN unset, so `go install` (the
  # catalog's go_install) lands in ~/go/bin, where the statusLine and the
  # usage reader run tacho; ~/.zshenv appends ~/go/bin to PATH. Checked
  # wherever those files render.
  if [[ -f "$root/home/.config/mise/config.toml" ]]; then
    if [[ "$(yq -p toml -o json '.settings.go.set_gobin' "$root/home/.config/mise/config.toml" 2>/dev/null)" == "false" ]]; then
      ok "test passed: mise config leaves GOBIN unset (go.set_gobin = false) for $profile"
    else
      fail "test failed: mise config does not set go.set_gobin = false for $profile"
      status=1
    fi
    # #333 (F39): runtime は明示の `mise install` でだけ入れる。shim が無い runtime を
    # 勝手に取りに行かない (docs/runtime.md)。
    if [[ "$(yq -p toml -o json '.settings.not_found_auto_install' "$root/home/.config/mise/config.toml" 2>/dev/null)" == "false" ]]; then
      ok "test passed: mise config does not auto-install a missing runtime (not_found_auto_install = false) for $profile"
    else
      fail "test failed: mise config does not set not_found_auto_install = false for $profile"
      status=1
    fi
  fi
  if [[ -f "$root/home/.zshenv" ]]; then
    # shellcheck disable=SC2016 # the literal line, not an expansion
    if grep -Fxq 'export PATH="$PATH:${HOME%/}/go/bin"' "$root/home/.zshenv"; then
      ok "test passed: .zshenv appends ~/go/bin to PATH for $profile"
    else
      fail "test failed: .zshenv does not append ~/go/bin to PATH for $profile"
      status=1
    fi
  fi
done < <(known_profiles)

if [[ "$profiles_found" -eq 0 ]]; then
  fail "no profiles parsed from $PROFILES_FILE"
  exit 1
fi

# --- allowlist contract (#207) --------------------------------------------
# A source entry that no module declares must never reach a home — neither
# a committed one (declaration forgotten in a PR) nor an untracked one (a
# local experiment left in the source dir). .chezmoiignore ignores
# everything and un-ignores only the declared paths of active modules plus
# their ancestor directories, so a source with extra undeclared entries must
# produce exactly the pinned managed set for every profile, and apply must
# not create the extras.

fixture_chezmoi() {
  chezmoi --config "$root/chezmoi.toml" \
    --source "$root/src" --destination "$root/home" "$@"
}

# add_undeclared_sources SRC
# The three shapes an undeclared entry can take: a root file, a whole
# subtree, and a sibling inside a directory that a declared file lives in.
add_undeclared_sources() {
  local src="$1"
  printf 'undeclared\n' > "$src/dot_audit_undeclared"
  mkdir -p "$src/private_dot_config/audit_undeclared"
  printf 'undeclared\n' > "$src/private_dot_config/audit_undeclared/file"
  printf 'undeclared\n' > "$src/private_dot_config/mise/audit_sibling.toml"
}
undeclared_targets=(.audit_undeclared .config/audit_undeclared .config/audit_undeclared/file .config/mise/audit_sibling.toml)

section "allowlist: undeclared source entries are never applied (#207)"

while IFS= read -r profile; do
  [[ -z "$profile" ]] && continue
  expected="$(expected_managed "$profile")" || continue  # reported above

  make_root
  make_flipped_source "$root"
  add_undeclared_sources "$root/src"
  write_config "$profile"
  # An unmanaged file already in the home must stay untouched: ignored
  # means unmanaged, never "remove".
  printf 'pre-existing\n' > "$root/home/.audit_undeclared"

  if ! output="$(fixture_chezmoi apply 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "test failed: apply renders for $profile with undeclared sources"
    status=1
    continue
  fi

  managed="$(fixture_chezmoi managed | sort)"
  if diff_output="$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$managed"))"; then
    ok "test passed: undeclared sources do not change the managed set for $profile"
  else
    printf '%s\n' "$diff_output" >&2
    fail "test failed: undeclared sources changed the managed set for $profile"
    status=1
  fi

  for target in "${undeclared_targets[@]}"; do
    if [[ "$target" == ".audit_undeclared" ]]; then
      if [[ "$(cat "$root/home/$target")" == "pre-existing" ]]; then
        ok "test passed: pre-existing unmanaged $target left untouched for $profile"
      else
        fail "test failed: apply touched the unmanaged $target for $profile"
        status=1
      fi
    elif [[ -e "$root/home/$target" ]]; then
      fail "test failed: apply created undeclared $target for $profile"
      status=1
    else
      ok "test passed: undeclared $target not applied for $profile"
    fi
  done
done < <(known_profiles)

section "allowlist: every source entry maps to a declared target (#207)"

# declared_targets: every module's paths plus each path's ancestors — the
# pass-through directories .chezmoiignore un-ignores. Profile-independent on
# purpose: a declaration is a module-level fact (the per-profile gate is
# pinned by the managed sets above), so a path declared by a module that no
# profile lists yet still counts as declared.
declared_targets() {
  local module path prefix part
  local -a parts
  while IFS= read -r module; do
    [[ -z "$module" ]] && continue
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      prefix=""
      IFS=/ read -ra parts <<< "$path"
      for part in "${parts[@]}"; do
        prefix="${prefix:+$prefix/}$part"
        printf '%s\n' "$prefix"
      done
    done < <(module_paths "$module")
  done < <(known_modules)
}

# Repo-management sources: never targets, kept out of the scan by name.
never_managed_sources=(README.md AGENTS.md LICENSE docs scripts worklog)
# chezmoi's own files this repo uses. Any other .chezmoi* entry
# (.chezmoiscripts, .chezmoiexternal*, .chezmoiremove, ...) is a source kind
# the allowlist contract does not cover and fails instead of being ignored
# unseen.
chezmoi_special_sources=(.chezmoi.toml.tmpl .chezmoidata .chezmoiignore .chezmoitemplates)
# Attribute prefixes this repo uses. Every other prefix chezmoi knows
# changes how a source is applied (script, symlink, modify, remove, exact
# directory, ...) and is not covered by the contract either.
allowed_attribute_re='^(private_|executable_|dot_)'
chezmoi_attribute_re='^(after_|before_|create_|empty_|encrypted_|exact_|external_|literal_|modify_|once_|onchange_|readonly_|remove_|run_|symlink_)'
# Sources allowed one attribute beyond the above, by exact path: the managed
# ~/.claude/settings.json is a modify script so the keys the template does
# not manage survive apply (#360). Any other modify_ source still fails.
allowed_modify_sources=(dot_claude/modify_settings.json.tmpl)

# scan_undeclared_sources SRC
# Print every target under SRC that no module declares, and every source
# entry of an unsupported kind (one per line); return 1 when anything was
# printed. Uses $root/chezmoi.toml (write_config first). Dot-prefixed
# entries are skipped the way chezmoi skips them; the repo-management roots
# are skipped by name.
scan_undeclared_sources() {
  local src="$1"
  local entry name rel comp stripped destination target found=0
  local -a prune=() entries=() comps
  local declared
  declared="$(declared_targets | sort -u)"

  while IFS= read -r entry; do
    name="${entry##*/}"
    if ! printf '%s\n' "${chezmoi_special_sources[@]}" | grep -Fxq -- "$name"; then
      printf 'unsupported chezmoi special source: %s\n' "$name"
      found=1
    fi
  done < <(find "$src" -mindepth 1 -maxdepth 1 -name '.chezmoi*')

  for name in "${never_managed_sources[@]}"; do
    prune+=(-o -path "$src/$name")
  done
  while IFS= read -r entry; do
    rel="${entry#"$src"/}"
    if printf '%s\n' "${allowed_modify_sources[@]}" | grep -Fxq -- "$rel"; then
      entries+=("$entry")
      continue
    fi
    IFS=/ read -ra comps <<< "$rel"
    for comp in "${comps[@]}"; do
      stripped="${comp%.tmpl}"
      while [[ "$stripped" =~ $allowed_attribute_re ]]; do
        stripped="${stripped#"${BASH_REMATCH[0]}"}"
      done
      if [[ "$stripped" =~ $chezmoi_attribute_re ]]; then
        printf 'unsupported source attribute: %s\n' "$rel"
        found=1
        continue 2
      fi
    done
    entries+=("$entry")
  done < <(find "$src" -mindepth 1 \( -name '.*' "${prune[@]}" \) -prune -o -print | sort)

  if [[ "${#entries[@]}" -gt 0 ]]; then
    # target-path with no argument prints the destination directory in the
    # same (canonical) form it uses for the per-entry output.
    destination="$(chezmoi --config "$root/chezmoi.toml" --source "$src" \
      --destination "$root/home" target-path)"
    while IFS= read -r target; do
      rel="${target#"$destination"/}"
      if ! grep -Fxq -- "$rel" <<< "$declared"; then
        printf '%s\n' "$rel"
        found=1
      fi
    done < <(chezmoi --config "$root/chezmoi.toml" --source "$src" \
      --destination "$root/home" target-path "${entries[@]}")
  fi

  [[ "$found" -eq 0 ]]
}

make_root
write_config personal
if output="$(scan_undeclared_sources "$DOTFILES_ROOT")"; then
  ok "test passed: every source entry maps to a declared target"
else
  printf '%s\n' "$output" >&2
  fail "test failed: source entries without a module declaration (declare them in modules.yaml or drop them)"
  status=1
fi

# The scan must flag the fixture's undeclared entries — otherwise the pass
# above is vacuous.
make_root
make_flipped_source "$root"
add_undeclared_sources "$root/src"
write_config personal
if output="$(scan_undeclared_sources "$root/src")"; then
  fail "test failed: scan passed a source with undeclared entries (vacuous check)"
  status=1
else
  for target in "${undeclared_targets[@]}"; do
    if grep -Fxq -- "$target" <<< "$output"; then
      ok "test passed: scan flags undeclared $target"
    else
      printf '%s\n' "$output" >&2
      fail "test failed: scan did not flag undeclared $target"
      status=1
    fi
  done
fi

# Unsupported source kinds fail loudly instead of being ignored by "**".
make_root
make_flipped_source "$root"
printf '#!/bin/sh\n' > "$root/src/run_once_audit.sh"
# The modify_ exception is the one exact path, not the attribute (#360).
printf '#!/bin/sh\n' > "$root/src/dot_claude/modify_extra.json"
mkdir -p "$root/src/.chezmoiscripts"
write_config personal
if output="$(scan_undeclared_sources "$root/src")"; then
  fail "test failed: scan passed unsupported source kinds"
  status=1
else
  for expected_line in "unsupported source attribute: run_once_audit.sh" \
    "unsupported source attribute: dot_claude/modify_extra.json" \
    "unsupported chezmoi special source: .chezmoiscripts"; do
    if grep -Fxq -- "$expected_line" <<< "$output"; then
      ok "test passed: scan reports $expected_line"
    else
      printf '%s\n' "$output" >&2
      fail "test failed: scan did not report: $expected_line"
      status=1
    fi
  done
fi

section "Quickstart minimal Git apply deploys the identity reset (#241)"

# README Quickstart step 3 applies a minimal Git set on a fresh machine. It
# must carry the managed identity reset (#202) along with ~/.gitconfig: Git
# silently ignores a missing include, so ~/.gitconfig alone leaks the personal
# fallback into non-personal contexts. Pin the exact command line the README
# shows, then prove that applying exactly those targets (and nothing else)
# lands both files. The parent directory target is part of the command on
# purpose (chezmoi cannot apply a file whose parent is not also a target),
# and ~/.config is created beforehand because chezmoi does not create
# ancestors outside the target set — and ~/.config as a TARGET would apply
# its whole subtree, which is not minimal (probed on chezmoi 2.70.5).
quickstart_mkdir='mkdir -p ~/.config'
quickstart_cmd='chezmoi apply --source ~/dotfiles ~/.gitconfig ~/.config/git-profile ~/.config/git-profile/identity-reset.gitconfig'
if grep -Fxq -- "$quickstart_mkdir" "$DOTFILES_ROOT/README.md" && grep -Fxq -- "$quickstart_cmd" "$DOTFILES_ROOT/README.md"; then
  ok "test passed: README Quickstart creates ~/.config and applies ~/.gitconfig together with the identity reset"
else
  fail "test failed: README Quickstart must contain (exact lines): $quickstart_mkdir / $quickstart_cmd"
  status=1
fi
make_root
write_config personal
mkdir -p "$root/home/.config"
if output="$(throwaway_chezmoi apply "$root/home/.gitconfig" "$root/home/.config/git-profile" \
    "$root/home/.config/git-profile/identity-reset.gitconfig" 2>&1)" \
  && [[ -f "$root/home/.gitconfig" && -f "$root/home/.config/git-profile/identity-reset.gitconfig" ]] \
  && [[ "$(find "$root/home" -type f | wc -l | tr -d ' ')" -eq 2 ]]; then
  ok "test passed: applying exactly the Quickstart targets lands ~/.gitconfig and the identity reset (2 files, nothing else)"
else
  printf '%s\n' "$output" >&2
  fail "test failed: the Quickstart target set did not deploy ~/.gitconfig plus the identity reset"
  status=1
fi

section "fail-closed render guards"

make_root
write_config "no-such-profile"
if output="$(throwaway_chezmoi managed 2>&1)"; then
  printf '%s\n' "$output" >&2
  fail "test failed: typo profile must not render"
  status=1
elif grep -Fq 'unknown profile "no-such-profile"' <<< "$output"; then
  ok "test passed: typo profile fails with known-profile message"
else
  printf '%s\n' "$output" >&2
  fail "test failed: typo profile fails without the expected message"
  status=1
fi

make_root
: > "$root/chezmoi.toml"
if output="$(throwaway_chezmoi managed 2>&1)"; then
  printf '%s\n' "$output" >&2
  fail "test failed: missing profile must not render"
  status=1
elif grep -Fq 'profile is not set' <<< "$output"; then
  ok "test passed: missing profile fails with init guidance"
else
  printf '%s\n' "$output" >&2
  fail "test failed: missing profile fails without the expected message"
  status=1
fi

section "non-interactive init"

make_root
if output="$(env HOME="$root/home" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" \
  chezmoi init --source "$DOTFILES_ROOT" --promptString profile=work 2>&1)"; then
  config_file="$root/config/chezmoi/chezmoi.toml"
  if grep -Fxq 'profile = "work"' "$config_file"; then
    ok "test passed: non-interactive init writes the chosen profile"
  else
    fail "test failed: init config does not contain the chosen profile"
    status=1
  fi
else
  printf '%s\n' "$output" >&2
  fail "test failed: non-interactive init with --promptString"
  status=1
fi

# No default profile on purpose: init without an answer must fail
# instead of silently picking one. --promptDefaults answers every prompt
# that has a default with that default, so only a prompt without one
# still hits EOF on the closed stdin (without the flag the prompt fails
# at EOF whether or not a default exists). The failure must come from
# the profile prompt, not from e.g. an unknown flag.
make_root
if output="$(env HOME="$root/home" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" \
  chezmoi init --source "$DOTFILES_ROOT" --no-tty --promptDefaults </dev/null 2>&1)"; then
  printf '%s\n' "$output" >&2
  fail "test failed: init without a profile answer must fail (default has been reintroduced?)"
  status=1
elif grep -Fq 'promptStringOnce' <<< "$output"; then
  ok "test passed: init without a profile answer fails (no default profile)"
else
  printf '%s\n' "$output" >&2
  fail "test failed: init without a profile answer failed before reaching the profile prompt"
  status=1
fi

section "typed boolean guards (direct chezmoi, without validate-policy)"

# One source copy per section: a pass only reads the source (apply and
# execute-template), and it first puts the whole .chezmoidata back, so each
# pass starts from the same source a fresh copy would give. The root
# (config, home, chezmoi state) stays fresh per pass.
make_root
make_flipped_source "$root"
guard_src="$root/src"
for invalid_bool in '"true"' '"false"' 0 null '[]' '{}'; do
  for bool_input in profile requires implemented; do
    make_root
    write_config personal
    rm -rf "$guard_src/.chezmoidata"
    cp -R "$DOTFILES_ROOT/.chezmoidata" "$guard_src/.chezmoidata"
    case "$bool_input" in
      profile)
        V="$invalid_bool" yq -i '.profiles.personal.capabilities.enableQualityLoopHooks = env(V)' \
          "$guard_src/.chezmoidata/profiles.yaml"
        expected_error="capability must be boolean: personal.enableQualityLoopHooks"
        ;;
      requires)
        V="$invalid_bool" yq -i '.modules.runtime.requires.enableRuntimeManagement = env(V)' \
          "$guard_src/.chezmoidata/modules.yaml"
        expected_error="module requires must be boolean: runtime.enableRuntimeManagement"
        ;;
      implemented)
        V="$invalid_bool" yq -i '.capabilities.enableQualityLoopHooks.implemented = env(V)' \
          "$guard_src/.chezmoidata/capabilities.schema.yaml"
        expected_error="capability registry: enableQualityLoopHooks implemented must be a YAML boolean"
        ;;
    esac
    if output="$(chezmoi --config "$root/chezmoi.toml" --source "$guard_src" \
      --destination "$root/home" apply 2>&1)"; then
      fail "test failed: apply accepted $bool_input YAML value $invalid_bool"
      status=1
    elif grep -Fq "$expected_error" <<< "$output"; then
      ok "test passed: apply rejects $bool_input YAML value $invalid_bool"
    else
      printf '%s\n' "$output" >&2
      fail "test failed: apply did not report the $bool_input type error"
      status=1
    fi
    if [[ -e "$root/home/.claude/settings.json" || -e "$root/home/.codex/hooks.json" ]]; then
      fail "test failed: invalid boolean created a live hook registration"
      status=1
    fi

    # Each agent's template must guard itself as well as .chezmoiignore:
    # execute-template bypasses the managed-set/apply path entirely.
    for agent_template in dot_claude/modify_settings.json.tmpl dot_codex/hooks.json.tmpl; do
      if output="$(chezmoi --config "$root/chezmoi.toml" --source "$guard_src" \
        --destination "$root/home" execute-template < "$guard_src/$agent_template" 2>&1)"; then
        fail "test failed: $agent_template accepted $bool_input YAML value $invalid_bool"
        status=1
      elif ! grep -Fq "$expected_error" <<< "$output"; then
        printf '%s\n' "$output" >&2
        fail "test failed: $agent_template did not report the $bool_input type error"
        status=1
      fi
    done
  done
done

section "typed enum guards (direct chezmoi, without validate-policy)"

# The Codex profile files (#264) write the enum value verbatim, so an unknown,
# mistyped or missing value must stop the apply in require-profile rather than
# reach a rendered file. npmHardeningMode shows the guard is generic. One
# source copy for the section, as for the boolean guards above.
make_root
make_flipped_source "$root"
guard_src="$root/src"
for enum_cap in codexReviewEffort codexWorkerEffort npmHardeningMode; do
  for invalid_enum in '"turbo"' '"HIGH"' true 0 null '[]' missing; do
    make_root
    write_config personal
    rm -rf "$guard_src/.chezmoidata"
    cp -R "$DOTFILES_ROOT/.chezmoidata" "$guard_src/.chezmoidata"
    if [[ "$invalid_enum" == missing ]]; then
      C="$enum_cap" yq -i 'del(.profiles.personal.capabilities[strenv(C)])' \
        "$guard_src/.chezmoidata/profiles.yaml"
    else
      C="$enum_cap" V="$invalid_enum" yq -i '.profiles.personal.capabilities[strenv(C)] = env(V)' \
        "$guard_src/.chezmoidata/profiles.yaml"
    fi
    expected_error="capability enum invalid: personal.$enum_cap (allowed: "
    if output="$(chezmoi --config "$root/chezmoi.toml" --source "$guard_src" \
      --destination "$root/home" apply 2>&1)"; then
      fail "test failed: apply accepted $enum_cap value $invalid_enum"
      status=1
    elif grep -Fq "$expected_error" <<< "$output"; then
      ok "test passed: apply rejects $enum_cap value $invalid_enum"
    else
      printf '%s\n' "$output" >&2
      fail "test failed: apply did not report the $enum_cap enum error"
      status=1
    fi
    if [[ -e "$root/home/.codex/agent-tools-review.config.toml" || -e "$root/home/.codex/agent-tools-worker.config.toml" ]]; then
      fail "test failed: invalid $enum_cap value rendered a Codex profile file"
      status=1
    fi
    # Each profile-file template guards itself too: execute-template bypasses
    # the managed-set/apply path.
    for profile_template in dot_codex/agent-tools-review.config.toml.tmpl dot_codex/agent-tools-worker.config.toml.tmpl; do
      if output="$(chezmoi --config "$root/chezmoi.toml" --source "$guard_src" \
        --destination "$root/home" execute-template < "$guard_src/$profile_template" 2>&1)"; then
        fail "test failed: $profile_template accepted $enum_cap value $invalid_enum"
        status=1
      elif ! grep -Fq "$expected_error" <<< "$output"; then
        printf '%s\n' "$output" >&2
        fail "test failed: $profile_template did not report the $enum_cap enum error"
        status=1
      fi
    done
  done
done

section "home path in the JSON settings and their command strings (#329)"

# The home path reaches three JSON files: the Claude statusLine and hook
# commands, the Codex hook commands (a shell parses each command string) and
# the OpenCode instructions path. A home with JSON- or shell-special
# characters must still give valid JSON whose commands a shell splits into
# exactly the intended words; a normal home must render the command as
# before (no quotes), which test-claude-settings / test-codex-settings pin
# for the hooks and the statusLine check below pins here.
# shell_words CMD — the words a shell makes of CMD, one per line (CMD is a
# string this test rendered from a fixture home, not outside input). A CMD
# the shell cannot parse fails here: printing the untouched arguments instead
# would pass an unquoted path off as one word.
shell_words() {
  bash -c 'eval "set -- $1" && printf "%s\n" "$@"' _ "$1"
}
# check_command LABEL CMD EXPECTED_WORD...
check_command() {
  local label="$1" cmd="$2" got want
  shift 2
  got="$(shell_words "$cmd")" || got="<shell error>"
  want="$(printf '%s\n' "$@")"
  if [[ "$got" == "$want" ]]; then
    ok "test passed: $label splits into the intended $# word(s)"
  else
    printf 'command: %s\ngot:\n%s\nwant:\n%s\n' "$cmd" "$got" "$want" >&2
    fail "test failed: $label does not split into the intended words"
    status=1
  fi
}
# check_home_render ROOT HOME — the three files rendered for HOME.
check_home_render() {
  local root="$1" home="$2" agent file cmd
  for file in .claude/settings.json .codex/hooks.json .config/opencode/opencode.json; do
    if ! strict_json_object "$root/home/$file"; then
      fail "test failed: $file is not valid JSON for home $home"
      status=1
      return 0
    fi
  done
  cmd="$(yq -p json -o json -r '.statusLine.command' "$root/home/.claude/settings.json")"
  check_command "Claude statusLine" "$cmd" "$home/go/bin/tacho" statusline
  for agent in claude codex; do
    file="$root/home/.$agent/settings.json"
    [[ "$agent" == codex ]] && file="$root/home/.codex/hooks.json"
    cmd="$(yq -p json -o json -r '.hooks.PreToolUse[0].hooks[0].command' "$file")"
    check_command "$agent PreToolUse hook" "$cmd" "$home/.$agent/agent-tools/scripts/personal-safe-gh-hook"
    cmd="$(yq -p json -o json -r '.hooks.PostToolUse[0].hooks[0].command' "$file")"
    check_command "$agent PostToolUse hook" "$cmd" "$home/.$agent/agent-tools/scripts/personal-fast-edit-check"
    cmd="$(yq -p json -o json -r '.hooks.Stop[0].hooks[0].command' "$file")"
    check_command "$agent Stop hook" "$cmd" "$home/.$agent/agent-tools/scripts/personal-changed-scope-qa"
  done
  cmd="$(yq -p json -o json -r '.hooks.SessionStart[0].hooks[0].command' "$root/home/.claude/settings.json")"
  check_command "claude SessionStart (herdr) hook" "$cmd" bash "$home/.claude/hooks/herdr-agent-state.sh" session
  cmd="$(yq -p json -o json -r '.hooks.SessionStart[0].hooks[0].command' "$root/home/.codex/hooks.json")"
  check_command "codex SessionStart (herdr) hook" "$cmd" bash "$home/.codex/herdr-agent-state.sh" session
  if [[ "$(yq -p json -o json -r '.instructions[0]' "$root/home/.config/opencode/opencode.json")" == "$home/.claude/agent-tools/CLAUDE.md" ]]; then
    ok "test passed: OpenCode instructions name <home>/.claude/agent-tools/CLAUDE.md"
  else
    fail "test failed: OpenCode instructions path differs for home $home"
    status=1
  fi
}

# A normal home renders every command exactly as before the quoting: a fixed
# plain home, so the expectation does not depend on the host's $HOME (chezmoi
# renders for it without creating it; the destination is the fixture).
plain_home="/dotfiles-render-test-home"
make_root
write_config personal
if HOME="$plain_home" throwaway_chezmoi apply >/dev/null 2>&1; then
  plain_got="$(yq -p json -o json -r '.statusLine.command, .hooks.PreToolUse[0].hooks[0].command, .hooks.PostToolUse[0].hooks[0].command, .hooks.Stop[0].hooks[0].command, .hooks.SessionStart[0].hooks[0].command' "$root/home/.claude/settings.json"
    yq -p json -o json -r '.hooks.PreToolUse[0].hooks[0].command, .hooks.PostToolUse[0].hooks[0].command, .hooks.Stop[0].hooks[0].command, .hooks.SessionStart[0].hooks[0].command' "$root/home/.codex/hooks.json"
    yq -p json -o json -r '.instructions[0]' "$root/home/.config/opencode/opencode.json")"
  plain_want="$(printf '%s\n' \
    "$plain_home/go/bin/tacho statusline" \
    "$plain_home/.claude/agent-tools/scripts/personal-safe-gh-hook" \
    "$plain_home/.claude/agent-tools/scripts/personal-fast-edit-check" \
    "$plain_home/.claude/agent-tools/scripts/personal-changed-scope-qa" \
    "bash '$plain_home/.claude/hooks/herdr-agent-state.sh' session" \
    "$plain_home/.codex/agent-tools/scripts/personal-safe-gh-hook" \
    "$plain_home/.codex/agent-tools/scripts/personal-fast-edit-check" \
    "$plain_home/.codex/agent-tools/scripts/personal-changed-scope-qa" \
    "bash '$plain_home/.codex/herdr-agent-state.sh' session" \
    "$plain_home/.claude/agent-tools/CLAUDE.md")"
  if [[ "$plain_got" == "$plain_want" ]]; then
    ok "test passed: a normal home renders the statusLine, hook commands and instructions path unquoted, as before"
  else
    diff <(printf '%s\n' "$plain_want") <(printf '%s\n' "$plain_got") >&2 || true
    fail "test failed: a command string changed for a normal home"
    status=1
  fi
else
  fail "test failed: personal apply did not render (normal home)"
  status=1
fi

make_root
write_config personal
# chezmoi cleans the home path (a TMPDIR with a trailing slash leaves `//`).
odd_home="${root//\/\//\/}/h\"o\\me & <x> 'q' \$v"
mkdir -p "$odd_home"
# The check must reject what the quoting prevents: this home's path left
# unquoted does not come back from a shell as that one word.
if [[ "$(shell_words "$odd_home/x" 2>/dev/null)" == "$odd_home/x" ]]; then
  fail "test failed: shell_words takes the unquoted unusual home path for one word, so the checks below could not catch a missing quote"
  status=1
else
  ok "test passed: the unquoted unusual home path is not one shell word (the checks below can catch a missing quote)"
fi
if HOME="$odd_home" throwaway_chezmoi apply >/dev/null 2>&1; then
  check_home_render "$root" "$odd_home"
else
  fail "test failed: personal apply with an unusual home path did not render"
  status=1
fi

section "GitHub HTTPS credential helper (gh-credential-helper, #492)"

# The work profile renders ~/.config/git/gh-credential.gitconfig only while
# gh is on chezmoi's PATH at an absolute path that needs no quoting, and only
# while enableGhCredentialHelper is true; either key missing renders it empty
# and apply prunes a file left from before (template self-gate). chezmoi runs
# by absolute path with a PATH holding only a fake gh (or nothing), so the
# host's gh is never found (no template runs another command). git then runs
# on the rendered home with a fixture system config whose helper records its
# calls: GitHub's HTTPS must reach gh alone (the managed list starts with
# `helper =`), another host the system helper alone.
chezmoi_bin="$(command -v chezmoi)"
gc_bins="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-render-test.XXXXXX")"
tmp_roots+=("$gc_bins")
# The physical path, so the expected helper line does not depend on whether
# lookPath resolves a symlinked TMPDIR (macOS: /var -> /private/var).
gc_bins="$(cd -P "$gc_bins" && pwd)"
mkdir -p "$gc_bins/gh" "$gc_bins/none" "$gc_bins/sp ace" "$gc_bins/sys"
gc_calls="$gc_bins/calls"
cat > "$gc_bins/gh/gh" <<SH
#!/bin/sh
printf '%s %s\n' gh "\$*" >> $(shell_single_quote "$gc_calls")
cat > /dev/null
[ "\$3" != get ] || printf 'username=x-access-token\npassword=fake-gh-token\n'
SH
cat > "$gc_bins/sys/system-helper" <<SH
#!/bin/sh
printf '%s %s\n' system-helper "\$*" >> $(shell_single_quote "$gc_calls")
cat > /dev/null
SH
chmod +x "$gc_bins/gh/gh" "$gc_bins/sys/system-helper"
cp "$gc_bins/gh/gh" "$gc_bins/sp ace/gh"
printf '[credential]\n\thelper = !%s\n' "$gc_bins/sys/system-helper" > "$gc_bins/system.gitconfig"
gc_file=".config/git/gh-credential.gitconfig"
# gc_render ROOT PATH SOURCE — apply the work profile from SOURCE into
# ROOT/home, chezmoi seeing only PATH.
gc_render() {
  mkdir -p "$1/home"
  printf '[data]\nprofile = "work"\n' > "$1/chezmoi.toml"
  env PATH="$2" "$chezmoi_bin" --config "$1/chezmoi.toml" --source "$3" --destination "$1/home" apply >/dev/null 2>&1
}
# gc_fill HOST — `git credential fill` for https://HOST on the rendered home,
# with the fixture system helper and no terminal prompt.
gc_fill() {
  printf 'protocol=https\nhost=%s\n\n' "$1" | fixture_git_env "$root/home" "$root/home/.gitconfig" \
    GIT_CONFIG_NOSYSTEM=0 GIT_CONFIG_SYSTEM="$gc_bins/system.gitconfig" GIT_TERMINAL_PROMPT=0 -- git credential fill 2>/dev/null
}
gc_want=$'\n'"!$gc_bins/gh/gh auth git-credential"

make_root
if gc_render "$root" "$gc_bins/gh" "$DOTFILES_ROOT" && [[ -f "$root/home/$gc_file" ]] \
  && [[ "$(head -n 1 "$root/home/$gc_file")" == "# Managed by chezmoi from kosako/dotfiles (gh-credential-helper, #492)." ]] \
  && [[ "$(git config --file "$root/home/$gc_file" --get-all credential.https://github.com.helper)" == "$gc_want" ]] \
  && [[ "$(git config --file "$root/home/$gc_file" --get-all credential.https://gist.github.com.helper)" == "$gc_want" ]]; then
  ok "test passed: work with gh on PATH renders the helper list (reset, then gh at that path) for github.com and gist.github.com"
else
  [[ ! -f "$root/home/$gc_file" ]] || cat "$root/home/$gc_file" >&2
  fail "test failed: work with gh on PATH must render the gh helper for github.com and gist.github.com"
  status=1
fi
: > "$gc_calls"
gc_out="$(gc_fill github.com || true)"
if grep -Fxq 'password=fake-gh-token' <<< "$gc_out" && [[ "$(cat "$gc_calls")" == "gh auth git-credential get" ]]; then
  ok "test passed: git asks only gh for https://github.com (the system helper is reset for it)"
else
  printf 'calls:\n%s\n' "$(cat "$gc_calls")" >&2
  fail "test failed: https://github.com must reach gh alone"
  status=1
fi
: > "$gc_calls"
gc_fill example.com >/dev/null || true
if [[ "$(cat "$gc_calls")" == "system-helper get" ]]; then
  ok "test passed: another host keeps the system helper (gh is not asked)"
else
  printf 'calls:\n%s\n' "$(cat "$gc_calls")" >&2
  fail "test failed: https://example.com must reach the system helper alone"
  status=1
fi
if gc_render "$root" "$gc_bins/none" "$DOTFILES_ROOT" && [[ ! -e "$root/home/$gc_file" ]]; then
  ok "test passed: without gh on PATH the render is empty and apply prunes the file left from before"
else
  fail "test failed: without gh on PATH, apply must prune $gc_file"
  status=1
fi

make_root
if gc_render "$root" "$gc_bins/sp ace" "$DOTFILES_ROOT" && [[ ! -e "$root/home/$gc_file" ]]; then
  ok "test passed: gh at a path that needs quoting renders nothing (the helper line carries it unquoted)"
else
  fail "test failed: gh at a path with a space must not render $gc_file"
  status=1
fi

make_root
make_flipped_source "$root"
set_capability_all "$root/src" enableGhCredentialHelper false
if gc_render "$root" "$gc_bins/gh" "$DOTFILES_ROOT" && [[ -f "$root/home/$gc_file" ]] \
  && gc_render "$root" "$gc_bins/gh" "$root/src" && [[ ! -e "$root/home/$gc_file" ]]; then
  ok "test passed: enableGhCredentialHelper=false renders nothing and apply prunes the file left from before, gh on PATH or not"
else
  fail "test failed: enableGhCredentialHelper=false must prune $gc_file"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "render tests passed"
fi
exit "$status"
