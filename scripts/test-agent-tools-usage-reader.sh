#!/usr/bin/env bash
set -euo pipefail

# Gating and content tests for the agent-tools-usage-reader module (#301): the
# managed ~/.config/agent-tools/usage-reader.json that agent-tools' wrapper
# personal-usage-reader reads (agent-tools#385; file name and keys are its
# public contract). It must (1) be applied for personal and not for work,
# leaving work's own hand-placed file byte-identical, (2) be strict JSON with
# exactly the contract's keys — argv = [<home>/go/bin/tacho, "status",
# "--json"] (the statusLine's CLI, same path convention) and timeout_sec = 20
# as an integer — since the wrapper rejects any other key, (3) keep the home
# path intact through JSON escaping (a home with `"`, `\`, `&` and `<`),
# (4) land as a 0644 file in a 0755 directory, and (5) leave the rest of
# ~/.config/agent-tools untouched. Renders into throwaway destinations; never
# touches the real home.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

require_yq || exit 1

if ! command -v chezmoi >/dev/null 2>&1; then
  fail "chezmoi not found; agent-tools-usage-reader tests require it"
  exit 1
fi

status=0
tmp_roots=()

cleanup() {
  local dir
  for dir in "${tmp_roots[@]:-}"; do
    [[ -n "$dir" ]] && rm -rf "$dir"
  done
}
trap cleanup EXIT

# render_profile_into ROOT PROFILE [HOME_DIR] — apply PROFILE from the
# committed source into ROOT/home (which the caller may have pre-seeded),
# with chezmoi's home directory (.chezmoi.homeDir) taken from HOME_DIR when
# given; the caller mktemps ROOT and registers it in tmp_roots
# (caller-creates-root contract, see the #150 note in test-lib.sh).
render_profile_into() {
  local root="$1" profile="$2" home_dir="${3:-$HOME}"
  mkdir -p "$root/home"
  printf '[data]\nprofile = "%s"\n' "$profile" > "$root/chezmoi.toml"
  HOME="$home_dir" chezmoi --config "$root/chezmoi.toml" \
    --source "$DOTFILES_ROOT" --destination "$root/home" apply >/dev/null 2>&1
}

# json_query FILE EXPR — one yq query against FILE read as JSON; a scalar
# result comes out unquoted (-r), a collection as one line of JSON.
json_query() {
  yq -p json -o json -I0 -r "$2" "$1"
}

managed_rel=".config/agent-tools/usage-reader.json"

section "agent-tools-usage-reader: managed set per profile"

# 1) personal applies the file (next to a pre-seeded sibling); work does not.
personal_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-usage-reader-personal.XXXXXX")"
tmp_roots+=("$personal_root")
mkdir -p "$personal_root/home/.config/agent-tools"
printf '{"other": true}\n' > "$personal_root/sibling.json"
cp "$personal_root/sibling.json" "$personal_root/home/.config/agent-tools/sibling.json"
if ! render_profile_into "$personal_root" personal; then
  fail "test failed: personal apply did not render"
  exit 1
fi
managed="$personal_root/home/$managed_rel"
if [[ -f "$managed" ]]; then
  ok "test passed: personal applies $managed_rel"
else
  fail "test failed: personal did not apply $managed_rel"
  exit 1
fi

work_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-usage-reader-work.XXXXXX")"
tmp_roots+=("$work_root")
mkdir -p "$work_root/home/.config/agent-tools"
printf '{"argv": ["/usr/bin/true"]}\n' > "$work_root/work-own.json"
cp "$work_root/work-own.json" "$work_root/home/$managed_rel"
if ! render_profile_into "$work_root" work; then
  fail "test failed: work apply did not render"
  exit 1
fi
if cmp -s "$work_root/work-own.json" "$work_root/home/$managed_rel"; then
  ok "test passed: work leaves its own usage reader config untouched (module not listed)"
else
  fail "test failed: work apply changed an unmanaged usage reader config although it does not list agent-tools-usage-reader"
  status=1
fi

section "agent-tools-usage-reader: managed content (agent-tools contract)"

# 2) Strict JSON with exactly the contract's keys and the pinned values. A
#    key added later must be agreed in agent-tools' contract first: the
#    wrapper rejects an unknown key (exit 2), which leaves agent-tools with
#    no usage reader.
check_content() {
  local label="$1" file="$2" home_dir="$3" got
  if ! json_query "$file" '.' >/dev/null 2>&1; then
    fail "test failed: $label: not valid JSON"
    status=1
  elif [[ "$(json_query "$file" 'keys')" != '["argv","timeout_sec"]' ]]; then
    fail "test failed: $label: keys must be exactly argv and timeout_sec, got $(json_query "$file" 'keys')"
    status=1
  elif [[ "$(json_query "$file" '.argv | length')" != "3" ]] \
    || [[ "$(json_query "$file" '.argv | all_c(tag == "!!str")')" != "true" ]]; then
    fail "test failed: $label: argv must be three strings"
    status=1
  elif ! got="$(json_query "$file" '.argv[0]')" || [[ "$got" != "$home_dir/go/bin/tacho" ]]; then
    printf 'expected argv[0]: %s\nactual argv[0]:   %s\n' "$home_dir/go/bin/tacho" "$got" >&2
    fail "test failed: $label: argv[0] must be the home's go/bin/tacho (the statusLine's path convention)"
    status=1
  elif [[ "$(json_query "$file" '.argv[1]')" != "status" || "$(json_query "$file" '.argv[2]')" != "--json" ]]; then
    fail "test failed: $label: argv must run 'status --json'"
    status=1
  elif [[ "$(json_query "$file" '.timeout_sec | tag')" != "!!int" ]] \
    || [[ "$(json_query "$file" '.timeout_sec')" != "20" ]] \
    || ! grep -Eq '"timeout_sec": 20$' "$file"; then
    fail "test failed: $label: timeout_sec must be the integer 20"
    status=1
  else
    ok "test passed: $label: strict JSON, keys argv / timeout_sec only, argv = [<home>/go/bin/tacho, status, --json], timeout_sec = 20"
  fi
}
check_content "committed personal" "$managed" "$HOME"

# 3) A home path with JSON-special characters survives (toJson escapes it).
odd_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-usage-reader-odd.XXXXXX")"
tmp_roots+=("$odd_root")
# chezmoi cleans the home path (a TMPDIR with a trailing slash leaves `//`).
odd_root="${odd_root//\/\//\/}"
odd_home="$odd_root/h\"o\\me & <x>"
mkdir -p "$odd_home"
if render_profile_into "$odd_root" personal "$odd_home"; then
  check_content "home with \", \\, & and <" "$odd_root/home/$managed_rel" "$odd_home"
else
  fail "test failed: personal apply with an unusual home path did not render"
  status=1
fi

# 4) Modes: file 0644 in a 0755 directory.
file_mode_got="$(file_mode "$managed")"
dir_mode_got="$(file_mode "$personal_root/home/.config/agent-tools")"
if [[ "$file_mode_got" == "644" && "$dir_mode_got" == "755" ]]; then
  ok "test passed: usage-reader.json 0644 in a 0755 directory"
else
  fail "test failed: expected usage-reader.json 0644 / directory 0755, got $file_mode_got / $dir_mode_got"
  status=1
fi

# 5) Only the declared file is managed: a sibling in ~/.config/agent-tools survives.
if cmp -s "$personal_root/sibling.json" "$personal_root/home/.config/agent-tools/sibling.json"; then
  ok "test passed: a sibling file in ~/.config/agent-tools survives apply"
else
  fail "test failed: apply touched another file in ~/.config/agent-tools"
  status=1
fi

exit "$status"
