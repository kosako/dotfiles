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
      printf '%s\n' .claude .claude/settings.json .codex .codex/hooks.json .codex/rules .codex/rules/default.rules .config .config/git .config/git-hook-gates .config/git-hook-gates/hooks .config/git-hook-gates/hooks.gitconfig .config/git-hook-gates/hooks/commit-msg .config/git-hook-gates/hooks/pre-commit .config/git/signing.gitconfig .config/mise .config/mise/config.toml .config/starship.toml .gitconfig .npmrc .ssh .ssh/config .zprofile .zshenv .zshrc
      ;;
    work)
      printf '%s\n' .config .config/mise .config/mise/config.toml .config/starship.toml .gitconfig .zprofile .zshenv .zshrc
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
