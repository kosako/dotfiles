#!/usr/bin/env bash
set -euo pipefail

# Render every profile into a throwaway destination and assert the
# managed target set. This is the apply-shaped safety net: template
# errors and unexpected managed targets fail here before any real
# `chezmoi apply`. It never touches the real home directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

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
      printf '%s\n' .claude .claude/settings.json .config .config/git .config/git/signing.gitconfig .config/mise .config/mise/config.toml .config/starship.toml .gitconfig .npmrc .zprofile .zshenv .zshrc
      ;;
    work-minimal)
      printf '%s\n' .config .gitconfig
      ;;
    work-dev)
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
  chezmoi init --source "$DOTFILES_ROOT" --promptString profile=work-minimal 2>&1)"; then
  config_file="$root/config/chezmoi/chezmoi.toml"
  if grep -Fxq 'profile = "work-minimal"' "$config_file"; then
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

if [[ "$status" -eq 0 ]]; then
  ok "render tests passed"
fi
exit "$status"
