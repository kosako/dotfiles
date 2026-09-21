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
      printf '%s\n' .claude .claude/settings.json .codex .codex/hooks.json .codex/rules .codex/rules/default.rules .config .config/git .config/git-hook-gates .config/git-hook-gates/hooks .config/git-hook-gates/hooks.gitconfig .config/git-hook-gates/hooks/commit-msg .config/git-hook-gates/hooks/pre-commit .config/git-profile .config/git-profile/identity-reset.gitconfig .config/git/signing.gitconfig .config/mise .config/mise/config.toml .config/opencode .config/opencode/opencode.json .config/starship.toml .gitconfig .npmrc .ssh .ssh/config .zprofile .zshenv .zshrc
      ;;
    work)
      printf '%s\n' .config .config/git-profile .config/git-profile/identity-reset.gitconfig .config/mise .config/mise/config.toml .config/starship.toml .gitconfig .zprofile .zshenv .zshrc
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
mkdir -p "$root/src/.chezmoiscripts"
write_config personal
if output="$(scan_undeclared_sources "$root/src")"; then
  fail "test failed: scan passed unsupported source kinds"
  status=1
else
  for expected_line in "unsupported source attribute: run_once_audit.sh" \
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
# instead of silently picking one.
make_root
if output="$(env HOME="$root/home" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" \
  chezmoi init --source "$DOTFILES_ROOT" --no-tty </dev/null 2>&1)"; then
  printf '%s\n' "$output" >&2
  fail "test failed: init without a profile answer must fail (default has been reintroduced?)"
  status=1
else
  ok "test passed: init without a profile answer fails"
fi

section "typed boolean guards (direct chezmoi, without validate-policy)"

for invalid_bool in '"true"' '"false"' 0 null '[]' '{}'; do
  for bool_input in profile requires implemented; do
    make_root
    make_flipped_source "$root"
    write_config personal
    case "$bool_input" in
      profile)
        V="$invalid_bool" yq -i '.profiles.personal.capabilities.enableQualityLoopHooks = env(V)' \
          "$root/src/.chezmoidata/profiles.yaml"
        expected_error="capability must be boolean: personal.enableQualityLoopHooks"
        ;;
      requires)
        V="$invalid_bool" yq -i '.modules.runtime.requires.enableRuntimeManagement = env(V)' \
          "$root/src/.chezmoidata/modules.yaml"
        expected_error="module requires must be boolean: runtime.enableRuntimeManagement"
        ;;
      implemented)
        V="$invalid_bool" yq -i '.capabilities.enableQualityLoopHooks.implemented = env(V)' \
          "$root/src/.chezmoidata/capabilities.schema.yaml"
        expected_error="capability registry: enableQualityLoopHooks implemented must be a YAML boolean"
        ;;
    esac
    if output="$(chezmoi --config "$root/chezmoi.toml" --source "$root/src" \
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
    for agent_template in dot_claude/settings.json.tmpl dot_codex/hooks.json.tmpl; do
      if output="$(chezmoi --config "$root/chezmoi.toml" --source "$root/src" \
        --destination "$root/home" execute-template < "$root/src/$agent_template" 2>&1)"; then
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

if [[ "$status" -eq 0 ]]; then
  ok "render tests passed"
fi
exit "$status"
