#!/usr/bin/env bash
set -euo pipefail

# Gating and content tests for the herdr-config module (#261): the managed
# herdr config at ~/.config/herdr/config.toml. It must (1) be applied for
# personal and not for work, (2) carry the managed-by header (the doctor
# orphan scan keys on it), (3) parse as TOML with exactly the pinned settings
# — notably [ui.toast] delivery = "system", which agent-tools' herdr
# operations count on (herdr's default is off) — (4) land with the modes the
# live file and directory already have (0644 / 0755), so the first apply on a
# host changes no permission, and (5) leave the rest of ~/.config/herdr
# (herdr's runtime state: session.json, logs) untouched, and work's own
# unmanaged config byte-identical. Renders into throwaway destinations; never
# touches the real home.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

require_yq || exit 1

if ! command -v chezmoi >/dev/null 2>&1; then
  fail "chezmoi not found; herdr-config tests require it"
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

# render_profile_into ROOT PROFILE — apply PROFILE from the committed source
# into ROOT/home (which the caller may have pre-seeded); the caller mktemps
# ROOT and registers it in tmp_roots (caller-creates-root contract, see the
# #150 note in test-lib.sh).
render_profile_into() {
  local root="$1" profile="$2"
  mkdir -p "$root/home"
  printf '[data]\nprofile = "%s"\n' "$profile" > "$root/chezmoi.toml"
  chezmoi --config "$root/chezmoi.toml" \
    --source "$DOTFILES_ROOT" --destination "$root/home" apply >/dev/null 2>&1
}

# seed_runtime_state HOME_DIR — herdr's runtime files next to the config.
# The same bytes go to HOME_DIR/../seed/ as the reference for cmp.
seed_runtime_state() {
  local name
  mkdir -p "$1/.config/herdr" "$1/../seed"
  printf '{"workspaces":[]}\n' > "$1/../seed/session.json"
  printf 'server log line\n' > "$1/../seed/herdr-server.log"
  for name in session.json herdr-server.log; do
    cp "$1/../seed/$name" "$1/.config/herdr/$name"
  done
}

managed_rel=".config/herdr/config.toml"
expected_settings='{"experimental":{"switch_ascii_input_source_in_prefix":true},"onboarding":false,"ui":{"agent_panel_sort":"priority","show_agent_labels_on_pane_borders":true,"toast":{"delivery":"system"}}}'

section "herdr-config: managed set per profile"

# 1) personal applies the file (over pre-seeded runtime state); work does not.
personal_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-herdr-config-personal.XXXXXX")"
tmp_roots+=("$personal_root")
seed_runtime_state "$personal_root/home"
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

work_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-herdr-config-work.XXXXXX")"
tmp_roots+=("$work_root")
mkdir -p "$work_root/home/.config/herdr"
printf '[ui]\nagent_panel_sort = "spaces"\n' > "$work_root/work-own.toml"
cp "$work_root/work-own.toml" "$work_root/home/$managed_rel"
if ! render_profile_into "$work_root" work; then
  fail "test failed: work apply did not render"
  exit 1
fi
if cmp -s "$work_root/work-own.toml" "$work_root/home/$managed_rel"; then
  ok "test passed: work leaves its own herdr config untouched (module not listed)"
else
  fail "test failed: work apply changed an unmanaged herdr config although it does not list herdr-config"
  status=1
fi

section "herdr-config: managed content"

# 2) Header on line 1 (doctor's managed-path orphan scan keys on it).
if head -n 1 "$managed" | grep -Fq "Managed by chezmoi"; then
  ok "test passed: line 1 carries the managed-by header"
else
  fail "test failed: line 1 must carry the managed-by header (doctor orphan scan)"
  status=1
fi

# 3) Parses as TOML and carries exactly the pinned settings (keys sorted, so
#    only a value or key change trips it). A setting added later must be
#    added here on purpose — and validated with `herdr config check`: herdr
#    runs on ALL defaults when the file does not parse.
if settings="$(yq -p toml -o json -I0 'sort_keys(..)' "$managed" 2>&1)" \
  && [[ "$settings" == "$expected_settings" ]]; then
  ok "test passed: parses as TOML with exactly the pinned settings ([ui.toast] delivery = \"system\")"
else
  printf 'expected:\n%s\nactual:\n%s\n' "$expected_settings" "${settings:-<no output>}" >&2
  fail "test failed: herdr config does not parse or drifted from the pinned settings"
  status=1
fi

# 4) Modes match a stock herdr install (file 0644 under a 0755 directory).
file_mode_got="$(file_mode "$managed")"
dir_mode_got="$(file_mode "$personal_root/home/.config/herdr")"
if [[ "$file_mode_got" == "644" && "$dir_mode_got" == "755" ]]; then
  ok "test passed: config.toml 0644 in a 0755 directory (apply changes no permission on a stock host)"
else
  fail "test failed: expected config.toml 0644 / directory 0755, got $file_mode_got / $dir_mode_got"
  status=1
fi

# 5) The rest of ~/.config/herdr is herdr's runtime state: untouched by apply.
if cmp -s "$personal_root/seed/session.json" "$personal_root/home/.config/herdr/session.json" \
  && cmp -s "$personal_root/seed/herdr-server.log" "$personal_root/home/.config/herdr/herdr-server.log"; then
  ok "test passed: session.json and the server log next to the config survive apply"
else
  fail "test failed: apply touched herdr's runtime state next to the managed config"
  status=1
fi

exit "$status"
