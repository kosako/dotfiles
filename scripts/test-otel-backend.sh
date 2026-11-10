#!/usr/bin/env bash
set -euo pipefail

# Gating and content tests for the otel-backend module (#514): the managed
# compose file at ~/.config/otel-lgtm/compose.yaml that defines the local
# OpenTelemetry backend (grafana/otel-lgtm). It must (1) be applied for
# personal and not for work, (2) carry the managed-by header (the doctor
# orphan scan keys on it), (3) parse as YAML with exactly the pinned
# definition, (4) keep the properties the definition is trusted for whatever
# the pin says — the image fixed by version AND digest, every port published
# on 127.0.0.1 only (Grafana answers its API without a login, and Colima
# forwards a port published without an address to every interface of the
# host), named volumes only (no host path reaches the container), and none
# of the keys that widen what the container can touch — and (5) land 0644 in
# a 0755 directory. Renders into throwaway destinations; never touches the
# real home and never talks to a container runtime.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

require_yq || exit 1

if ! command -v chezmoi >/dev/null 2>&1; then
  fail "chezmoi not found; otel-backend tests require it"
  exit 1
fi

# chezmoi creates targets under the umask of the process that applies.
# Section 5's 0644 / 0755 is what a stock umask gives; pin it so the result
# does not depend on the shell that runs this test (#332 F38).
umask 022

status=0
tmp_roots=()

cleanup() {
  local dir
  for dir in "${tmp_roots[@]:-}"; do
    [[ -n "$dir" ]] && rm -rf "$dir"
  done
}
trap cleanup EXIT

managed_rel=".config/otel-lgtm/compose.yaml"
expected_definition='{"name":"otel-lgtm","services":{"lgtm":{"container_name":"otel-lgtm","image":"grafana/otel-lgtm:0.39.0@sha256:4c8056c9c05fcb3c8fd93800e85334bfd79b4d0271b47a54a121a64af41fe1fe","ports":["127.0.0.1:3000:3000","127.0.0.1:4317:4317","127.0.0.1:4318:4318"],"restart":"unless-stopped","volumes":["data:/data"]}},"volumes":{"data":null}}'

section "otel-backend: managed set per profile"

# 1) personal applies the file; work does not, and a file of its own at the
#    same path stays byte-identical.
personal_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-otel-backend-personal.XXXXXX")"
tmp_roots+=("$personal_root")
if ! render_profile_into "$DOTFILES_ROOT" "$personal_root" personal; then
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

work_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-otel-backend-work.XXXXXX")"
tmp_roots+=("$work_root")
mkdir -p "$work_root/home/.config/otel-lgtm"
printf 'services: {}\n' > "$work_root/work-own.yaml"
cp "$work_root/work-own.yaml" "$work_root/home/$managed_rel"
if ! render_profile_into "$DOTFILES_ROOT" "$work_root" work; then
  fail "test failed: work apply did not render"
  exit 1
fi
if cmp -s "$work_root/work-own.yaml" "$work_root/home/$managed_rel"; then
  ok "test passed: work leaves a compose file of its own untouched (module not listed)"
else
  fail "test failed: work apply changed an unmanaged compose file although it does not list otel-backend"
  status=1
fi

section "otel-backend: managed content"

# 2) Header on line 1 (doctor's managed-path orphan scan keys on it).
if head -n 1 "$managed" | grep -Fq "Managed by chezmoi"; then
  ok "test passed: line 1 carries the managed-by header"
else
  fail "test failed: line 1 must carry the managed-by header (doctor orphan scan)"
  status=1
fi

# 3) Parses as YAML and is exactly the pinned definition (keys sorted, so
#    only a value or key change trips it). An image update changes the
#    version and the digest here on purpose, in the same PR as the file.
if definition="$(yq -o json -I0 'sort_keys(..)' "$managed" 2>&1)" \
  && [[ "$definition" == "$expected_definition" ]]; then
  ok "test passed: parses as YAML with exactly the pinned definition"
else
  printf 'expected:\n%s\nactual:\n%s\n' "$expected_definition" "${definition:-<no output>}" >&2
  fail "test failed: compose file does not parse or drifted from the pinned definition"
  status=1
fi

# 4) The properties the definition is trusted for, checked on their own so
#    that a careless update of the pin above still fails here.
# every_line_matches REGEX — stdin has at least one line and each matches.
every_line_matches() {
  local re="$1" line seen=0
  while IFS= read -r line; do
    seen=1
    [[ "$line" =~ $re ]] || return 1
  done
  [[ "$seen" -eq 1 ]]
}

# 4a) Each image is name:version@sha256:<64 hex>: a tag alone can be moved
#     upstream, and a digest alone does not say which release it is.
image_re='^[a-z0-9][a-z0-9./-]*:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'
if yq -r '.services[] | .image // ""' "$managed" | every_line_matches "$image_re"; then
  ok "test passed: every image is pinned by version and sha256 digest"
else
  fail "test failed: every service image must be name:X.Y.Z@sha256:<64 hex>"
  status=1
fi

# 4b) Each published port is a string starting with 127.0.0.1: (the long
#     map syntax and a missing address both fail: the tag is printed first
#     and only !!str passes).
port_re='^!!str 127\.0\.0\.1:[0-9]+:[0-9]+$'
if yq -r '.services[] | .ports[] | (tag + " " + (. | tostring))' "$managed" 2>/dev/null | every_line_matches "$port_re"; then
  ok "test passed: every port is published on 127.0.0.1 only"
else
  fail "test failed: every port must be the string 127.0.0.1:<host port>:<container port>"
  status=1
fi

# 4c) Each mount is a named volume declared at the top level: no host path
#     (absolute, relative or ~) reaches the container. The declaration
#     itself must be empty (null or {}): one with driver_opts (type: none,
#     o: bind, device: /...) binds a path under a name that still reads as
#     a named volume, and external / name point at a volume defined
#     elsewhere (Codex review, PR #516).
volume_re='^!!str [a-z][a-z0-9_-]*:/[^:]*$'
mounts_ok=1
# A top-level volumes that is not a map makes yq fail: no declared names
# then, so every mount below is undeclared and the check fails with its own
# message instead of the script stopping here.
declared_volumes="$(yq -r '.volumes // {} | keys | .[]' "$managed" 2>/dev/null)" || declared_volumes=""
if ! nonempty_volume_decls="$(yq -r '.volumes // {} | to_entries | .[]
    | select((.value | tag) != "!!null" and ((.value | tag) != "!!map" or (.value | length) != 0)) | .key' "$managed" 2>/dev/null)" \
  || [[ -n "$nonempty_volume_decls" ]]; then
  mounts_ok=0
fi
yq -r '.services[] | .volumes[] | (tag + " " + (. | tostring))' "$managed" 2>/dev/null | every_line_matches "$volume_re" || mounts_ok=0
while IFS= read -r mount_source; do
  [[ -n "$mount_source" ]] || continue
  grep -Fxq -- "$mount_source" <<< "$declared_volumes" || mounts_ok=0
done < <(yq -r '.services[] | .volumes[] | (. | tostring) | sub(":.*$"; "")' "$managed" 2>/dev/null)
if [[ "$mounts_ok" -eq 1 ]]; then
  ok "test passed: every mount is a declared named volume with an empty declaration (no host path)"
else
  fail "test failed: every mount must be <declared named volume>:<container path>, and every volume declaration must be empty"
  status=1
fi

# 4d) None of the keys that hand the container more of the VM or the
#     network than a published loopback port.
widening="$(yq -r '.services[] | keys | .[] | select(. == "privileged" or . == "network_mode" or . == "pid" or . == "ipc" or . == "cap_add" or . == "devices" or . == "extra_hosts" or . == "security_opt")' "$managed")"
if [[ -z "$widening" ]]; then
  ok "test passed: no privileged / host-namespace / capability keys"
else
  fail "test failed: the definition must not use: $(tr '\n' ' ' <<< "$widening")"
  status=1
fi

# 4e) The restart policy that brings the container back with the daemon
#     (docs/otel-backend.md relies on it for the always-on setup).
if [[ "$(yq -r '[.services[] | .restart // ""] | unique | join(",")' "$managed")" == "unless-stopped" ]]; then
  ok "test passed: restart policy is unless-stopped"
else
  fail "test failed: every service must use restart: unless-stopped"
  status=1
fi

# 5) Modes under the stock umask pinned above: file 0644 in a 0755 directory.
file_mode_got="$(file_mode "$managed")"
dir_mode_got="$(file_mode "$personal_root/home/.config/otel-lgtm")"
if [[ "$file_mode_got" == "644" && "$dir_mode_got" == "755" ]]; then
  ok "test passed: compose.yaml 0644 in a 0755 directory"
else
  fail "test failed: expected compose.yaml 0644 / directory 0755, got $file_mode_got / $dir_mode_got"
  status=1
fi

exit "$status"
