#!/usr/bin/env bash
set -euo pipefail

# Verify the doctor orphan detection with a fixture HOME. doctor stays
# report-only: both runs must exit 0; only the warnings differ.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

# The doctor resolves the agent-tools checkout from $AGENT_TOOLS (issue #71),
# so a developer shell that exports it (the documented #71/#73 override)
# would leak the real checkout into every fixture run below — the agent-tools
# cases then execute the real status.sh and fail (issue #142). Unset it once
# here; the AT-override case re-sets it explicitly for its own invocation.
unset AGENT_TOOLS

# write_root_pinned_status_sh DEST JSON_PAYLOAD
# Write a fake agent-tools status.sh at DEST that models the status
# contract: accept `--root DIR` and `--json` in any order, and assert the
# caller pins the inspection root to the checkout DEST lives in, not its
# own cwd (#73; the AGENT_TOOLS-override case regresses #71 the same way).
# Older status.sh defaulted its root to cwd (agent-tools#305 changed that to
# its own repo), so doctor must keep pinning --root; exit non-zero on a
# wrong/missing root to regress that loudly. Touches ../ran-marker so tests can prove it ran, then
# prints JSON_PAYLOAD verbatim (one line + newline).
write_root_pinned_status_sh() {
  local dest="$1" payload="$2"
  cat > "$dest" <<'SH'
#!/bin/sh
root=""; json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --json) json=1; shift ;;
    *) shift ;;
  esac
done
[ "$json" = 1 ] || exit 1
[ -n "$root" ] || exit 3
root="$(CDPATH= cd -- "$root" 2>/dev/null && pwd)" || exit 3
expected="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
[ "$root" = "$expected" ] || exit 3
: > "$(dirname "$0")/../ran-marker"
SH
  printf '%s\n' "cat <<'JSON'" "$payload" "JSON" >> "$dest"
  chmod +x "$dest"
}

# steps_consecutive OUTPUT FIRST SECOND — SECOND is on the line right after
# some line equal to FIRST. Next-actions steps are the contract under test
# in several places (identity reset #241, global gitignore #248), and more
# than one action may start with the same `mkdir -p ~/.config` step, so the
# pair is searched rather than the first FIRST match.
steps_consecutive() {
  local out="$1" first="$2" second="$3"
  grep -F -x -A1 -- "$first" <<< "$out" | grep -Fxq -- "$second"
}

status=0
fixture_home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-doctor-test.XXXXXX")"
# Host tools doctor would otherwise launch for real on a developer machine
# (`op whoami`, `herdr integration status`, codex / opencode probes): hundreds
# of runs below inherit this PATH, and the real tools are credential-bearing or
# slow to answer. A PATH-front dir of stubs that record the call and exit 1
# keeps every run hermetic: the tools are present on PATH but fail when run
# (e.g. op reads as "not signed in", not "not found"). Sections that need a
# specific answer put their own fake in front of these, as before (#306).
# Kept outside the fixture HOME so no section's cleanup removes it.
host_stub_dir=""
trap 'rm -rf "$fixture_home" ${host_stub_dir:+"$host_stub_dir"}' EXIT
host_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-doctor-host-stubs.XXXXXX")"
mkdir -p "$host_stub_dir/bin"
for host_tool in op herdr codex opencode; do
  printf '#!/bin/sh\nprintf "%%s\\n" %q >> %q\nexit 1\n' "$host_tool" "$host_stub_dir/calls" \
    > "$host_stub_dir/bin/$host_tool"
  chmod +x "$host_stub_dir/bin/$host_tool"
done
PATH="$host_stub_dir/bin:$PATH"
export PATH
# The go install target check (#305) reads `go env GOBIN` / `GOPATH`: a GOBIN
# exported by the developer's mise-activated shell (or a custom GOPATH) would
# otherwise turn every fixture run into an extra action. Unset, Go answers
# for the fixture HOME ($HOME/go); the GO cases below use their own fake go.
unset GOBIN GOPATH
for host_tool in op herdr codex opencode; do
  if [[ "$(command -v "$host_tool")" != "$host_stub_dir/bin/$host_tool" ]]; then
    fail "test failed: the host-tool stub for $host_tool is not what PATH resolves first"
    exit 1
  fi
done

# A leftover enforce-mode .npmrc, as after switching personal -> work.
printf '# Managed by chezmoi from kosako/dotfiles (npmHardeningMode=enforce).\nignore-scripts=true\n' \
  > "$fixture_home/.npmrc"

orphan_marker="orphan from another profile"

# work does not manage .npmrc (npmHardeningMode=report): orphan.
if ! output="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" work 2>&1)"; then
  printf '%s\n' "$output" >&2
  fail "test failed: doctor must stay exit 0 for work"
  status=1
fi
if grep -F "$orphan_marker" <<< "$output" | grep -Fq ".npmrc"; then
  ok "test passed: orphan .npmrc reported for work"
else
  printf '%s\n' "$output" >&2
  fail "test failed: orphan .npmrc not reported for work"
  status=1
fi

# personal manages .npmrc (npmHardeningMode=enforce): not an orphan.
if ! output="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  printf '%s\n' "$output" >&2
  fail "test failed: doctor must stay exit 0 for personal"
  status=1
fi
if grep -Fq "$orphan_marker" <<< "$output"; then
  printf '%s\n' "$output" >&2
  fail "test failed: personal must not report the fixture .npmrc as orphan"
  status=1
else
  ok "test passed: no orphan reported for personal"
fi

# A file without the managed-by header is never an orphan.
printf 'registry-noise=1\n' > "$fixture_home/.npmrc"
# Capture before matching so an early grep exit cannot mask an orphan via SIGPIPE.
doctor_rc=0
output="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" work 2>&1)" || doctor_rc=$?
if [[ "$doctor_rc" -ne 0 ]]; then
  printf '%s\n' "$output" >&2
  fail "test failed: doctor must stay exit 0 for a headerless file (got $doctor_rc)"
  status=1
elif grep -Fq "$orphan_marker" <<< "$output"; then
  printf '%s\n' "$output" >&2
  fail "test failed: headerless file must not be reported as orphan"
  status=1
else
  ok "test passed: headerless file ignored"
fi

# False-positive guard (#174): unrelated tool data under the ancestor
# directory of a declared file (~/.claude, which .chezmoiignore lets through
# only as the parent of ~/.claude/settings.json, #207) that merely quotes the
# header (Claude Code session logs, paste-cache) must not be scanned at all —
# only declared file paths are inspected.
mkdir -p "$fixture_home/.claude/projects"
printf 'transcript quoting: Managed by chezmoi from kosako/dotfiles\n' \
  > "$fixture_home/.claude/projects/session.jsonl"
for fp_profile in personal work; do
  # Capture, then grep: `doctor | grep -Fq` dies of SIGPIPE under pipefail
  # when grep matches early and the condition reads as "no match" (#143).
  fp_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" "$fp_profile" 2>&1)"
  if grep -Fq "projects/session.jsonl" <<< "$fp_out"; then
    fail "test failed: $fp_profile must not report session data under the ancestor directory of a declared file"
    status=1
  else
    ok "test passed: session data under the ancestor directory of a declared file ignored ($fp_profile)"
  fi
done

# Backup "never ran" is an actionable warn only where backup can run (#174):
# work refuses backup by design (allowSecretsAccess=false) -> neutral item;
# personal (allowed, marker absent in the fixture) keeps the warn.
backup_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" work 2>&1)"
if grep -Fq "no backup recorded yet" <<< "$backup_out"; then
  fail "test failed: work must not warn about a backup it is designed to refuse"
  status=1
elif grep -Fq "refused for profile work by design" <<< "$backup_out"; then
  ok "test passed: work shows the neutral backup item"
else
  fail "test failed: work backup line missing entirely"
  status=1
fi
backup_personal_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"
if grep -Fq "no backup recorded yet" <<< "$backup_personal_out"; then
  ok "test passed: personal keeps the no-backup warn"
else
  fail "test failed: personal must warn when no backup is recorded"
  status=1
fi

# agent-tools report-only section. Presence is always reported; running
# status.sh is opt-in via enableAgentToolsStatus. doctor must always
# exit 0 and never write. The fake status.sh records that it ran so the
# opt-in gate can be proven.
agent_dir="$fixture_home/src/agent/agent-tools"
agent_scripts="$agent_dir/scripts"
agent_marker="$agent_dir/ran-marker"
mkdir -p "$agent_scripts"
# Root-pinning fake (see write_root_pinned_status_sh): regression for #73.
write_root_pinned_status_sh "$agent_scripts/status.sh" \
  '{"contract_version":3,"repo":{"present":true,"clean":true},"assets":{"total":1,"manifest_errors":0},"checks":{"manifest_validation":"pass","prompt_injection_static":"pass"},"generated":{"total":1,"stale":0},"register":{"catalog_present":true,"registered":1,"human_review_required":0,"unsupported":0},"sync_targets":[{"tool":"codex","name":"x","state":"conflict"},{"tool":"codex","name":"y","state":"deployed_but_inactive"}]}'

# A) Opt-in disabled: present but status.sh must not run. Force the capability
#    off in a throwaway copy so the test is independent of the real default
#    (personal opts in by default since #73), mirroring the opt-in copy below.
optout_root="$fixture_home/.dotfiles-optout"
copy_repo_fixture "$optout_root"
set_capability_all "$optout_root" enableAgentToolsStatus false
rm -f "$agent_marker"
if at_out="$(HOME="$fixture_home" "$optout_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "status read disabled" <<< "$at_out" && [[ ! -e "$agent_marker" ]]; then
    ok "test passed: agent-tools status execution is opt-in (not run when disabled)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: agent-tools status.sh ran or was not reported as disabled"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 (agent-tools present, opt-in off)"
  status=1
fi

# Throwaway repo copy with the opt-in enabled for every profile, so the
# test does not depend on which profile comes first.
optin_root="$fixture_home/.dotfiles-optin"
copy_repo_fixture "$optin_root"
set_capability_all "$optin_root" enableAgentToolsStatus true

# B) Opt-in enabled: status.sh runs, summary shown, conflict flagged.
rm -f "$agent_marker"
if at_out="$(HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "agent-tools present; status contract v3" <<< "$at_out" \
    && grep -Fq "sync conflicts (unmanaged same-name targets; tools: codex)" <<< "$at_out" \
    && grep -Fq "deployed-but-inactive sync targets (gated entries still on disk; tools: codex;" <<< "$at_out" \
    && grep -Fxq "[info] - sync targets: 2 (codex 2)" <<< "$at_out" && [[ -e "$agent_marker" ]]; then
    ok "test passed: opt-in runs status.sh and summarizes (per-tool counts; conflict + inactive leftovers flagged with their tools)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: opt-in summary/conflict/marker missing"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 (opt-in summary)"
  status=1
fi

# B2) Per-tool summary (#263): counts per tool in a stable (sorted) order,
#     and each finding names exactly the tools whose rows are in that state.
#     The fixture mixes tools and states; restored afterwards for the cases
#     below.
write_root_pinned_status_sh "$agent_scripts/status.sh" \
  '{"contract_version":3,"repo":{"present":true,"clean":true},"assets":{"total":1,"manifest_errors":0},"checks":{"manifest_validation":"pass","prompt_injection_static":"pass"},"generated":{"total":1,"stale":0},"register":{"catalog_present":true,"registered":1,"human_review_required":0,"unsupported":0},"sync_targets":[{"tool":"opencode","name":"p","state":"stale"},{"tool":"codex","name":"c","state":"ok"},{"tool":"claude-code","name":"a","state":"stale"},{"tool":"codex","name":"d","state":"conflict"},{"tool":"claude-code","name":"e","state":"deployed_but_inactive"}]}'
if at_out="$(HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[info] - sync targets: 5 (claude-code 2, codex 2, opencode 1)" <<< "$at_out" \
    && grep -Fq "[warn] agent-tools has stale sync targets (generated artifact newer than target; tools: claude-code, opencode)" <<< "$at_out" \
    && grep -Fq "sync conflicts (unmanaged same-name targets; tools: codex)" <<< "$at_out" \
    && grep -Fq "deployed-but-inactive sync targets (gated entries still on disk; tools: claude-code;" <<< "$at_out"; then
    ok "test passed: sync targets are counted per tool (sorted) and each finding names only the tools in that state"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: per-tool sync target summary not reported as expected"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 (per-tool sync targets)"
  status=1
fi
write_root_pinned_status_sh "$agent_scripts/status.sh" \
  '{"contract_version":3,"repo":{"present":true,"clean":true},"assets":{"total":1,"manifest_errors":0},"checks":{"manifest_validation":"pass","prompt_injection_static":"pass"},"generated":{"total":1,"stale":0},"register":{"catalog_present":true,"registered":1,"human_review_required":0,"unsupported":0},"sync_targets":[{"tool":"codex","name":"x","state":"conflict"},{"tool":"codex","name":"y","state":"deployed_but_inactive"}]}'

# C) Opt-in + unknown contract version: not interpreted, still exit 0.
# Sentinel fields prove fail-closed: a doctor that warns but still interprets
# fields would emit the summary lines below, so their absence is asserted too.
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
json=0
for a in "$@"; do [ "$a" = "--json" ] && json=1; done
[ "$json" = 1 ] || exit 1
echo '{"contract_version":99,"repo":{"present":true,"clean":true},"sync_targets":[{"tool":"codex","name":"x","state":"conflict"},{"tool":"codex","name":"y","state":"deployed_but_inactive"}]}'
SH
chmod +x "$agent_scripts/status.sh"
if at_out="$(HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "expected 3 (not interpreting fields)" <<< "$at_out" \
    && ! grep -Fq "agent-tools working tree clean" <<< "$at_out" \
    && ! grep -Fq "sync conflicts" <<< "$at_out" \
    && ! grep -Fq "deployed-but-inactive sync targets" <<< "$at_out"; then
    ok "test passed: unknown contract version is not interpreted (exit 0)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: contract version mismatch not handled"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 on contract version mismatch"
  status=1
fi

# D) Opt-in + missing status.sh: warning, still exit 0.
rm -f "$agent_scripts/status.sh"
if at_out="$(HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "status.sh is missing or not executable" <<< "$at_out"; then
    ok "test passed: missing status.sh is a warning (exit 0)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: missing status.sh not reported"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 when status.sh missing"
  status=1
fi

# F) Opt-in + status.sh exits non-zero: warning, still exit 0.
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$agent_scripts/status.sh"
if at_out="$(HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "no usable output" <<< "$at_out"; then
    ok "test passed: status.sh failure is a warning (exit 0)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: status.sh failure not handled"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 when status.sh exits non-zero"
  status=1
fi

# G) Opt-in + malformed status JSON: doctor must not break, exit 0.
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
json=0
for a in "$@"; do [ "$a" = "--json" ] && json=1; done
[ "$json" = 1 ] || exit 1
echo 'this is not json {{{'
SH
chmod +x "$agent_scripts/status.sh"
if HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal >/dev/null 2>&1; then
  ok "test passed: malformed status JSON keeps doctor at exit 0"
else
  fail "test failed: malformed status JSON must not break doctor"
  status=1
fi

# E) Absent agent-tools: report-only warning on a profile that opted in to its
#    status (personal: enableAgentToolsStatus=true), exit 0.
rm -rf "$agent_dir"
if at_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[warn] agent-tools not present at $agent_dir (not auto-cloned)" <<< "$at_out"; then
    ok "test passed: absent agent-tools warned on personal (opted in), doctor exit 0"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: absent agent-tools not warned on personal"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 when agent-tools absent"
  status=1
fi
# E2) The same absence on work (enableAiPolicy=true, enableAgentToolsStatus=
#     false; agent-tools is not deployed on work machines) is the declared
#     state: a neutral item, never a warning on every run (#258).
if at_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" work 2>&1)"; then
  if grep -Fxq "[info] - agent-tools not present at $agent_dir (not expected by this profile: enableAgentToolsStatus=false; not auto-cloned)" <<< "$at_out" \
    && ! grep -Fq "[warn] agent-tools not present" <<< "$at_out"; then
    ok "test passed: absent agent-tools on work is neutral (no warning)"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: absent agent-tools on work was not reported neutrally"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 when agent-tools absent (work)"
  status=1
fi

# AT-override) AGENT_TOOLS overrides the expected path (issue #71). The
#    default ~/src/agent/agent-tools is absent (removed in E), so a v3 summary
#    plus the run marker proves doctor read the overridden checkout.
override_dir="$fixture_home/custom/agent-tools"
override_scripts="$override_dir/scripts"
override_marker="$override_dir/ran-marker"
mkdir -p "$override_scripts"
# Same root-pinning contract as the default-path fake: doctor must pass
# --root equal to the AGENT_TOOLS-overridden checkout (#71 + #73).
write_root_pinned_status_sh "$override_scripts/status.sh" \
  '{"contract_version":3,"repo":{"present":true,"clean":true},"assets":{"total":0,"manifest_errors":0},"checks":{"manifest_validation":"pass","prompt_injection_static":"pass"},"generated":{"total":0,"stale":0},"register":{"catalog_present":false,"registered":0,"human_review_required":0,"unsupported":0},"sync_targets":[]}'
rm -f "$override_marker"
if at_out="$(HOME="$fixture_home" AGENT_TOOLS="$override_dir" "$optin_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "agent-tools present; status contract v3" <<< "$at_out" && [[ -e "$override_marker" ]]; then
    ok "test passed: AGENT_TOOLS overrides the expected path"
  else
    printf '%s\n' "$at_out" >&2
    fail "test failed: AGENT_TOOLS override not honored"
    status=1
  fi
else
  printf '%s\n' "$at_out" >&2
  fail "test failed: doctor must stay exit 0 with AGENT_TOOLS override"
  status=1
fi

# private-backup report-only section (issue #60). doctor must report
# backup presence and the local supplement's EXISTENCE ONLY, never parse
# or read the supplement, and always stay exit 0.

# H) No marker yet: doctor reports "no backup recorded" and stays exit 0.
if pb_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "no backup recorded yet" <<< "$pb_out"; then
    ok "test passed: missing backup marker reported (exit 0)"
  else
    printf '%s\n' "$pb_out" >&2
    fail "test failed: missing backup marker not reported"
    status=1
  fi
else
  printf '%s\n' "$pb_out" >&2
  fail "test failed: doctor must stay exit 0 with no backup marker"
  status=1
fi

# I) With a marker, doctor surfaces the last-success time / archive / count.
mkdir -p "$fixture_home/.local/state/dotfiles"
printf '{"schema_version":1,"last_success":"2026-06-19T00:00:00Z","archive":"backup.age","file_count":2}\n' \
  > "$fixture_home/.local/state/dotfiles/private-backup.json"
if pb_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  # A marker from before #242 has no capture_incomplete field: the capture
  # state is UNKNOWN (never assumed complete), still an ok line.
  if grep -Fq "[ok] last backup: 2026-06-19T00:00:00Z (archive: backup.age, files: 2, capture: unknown)" <<< "$pb_out"; then
    ok "test passed: backup marker last-success reported (pre-#242 marker -> capture unknown)"
  else
    printf '%s\n' "$pb_out" >&2
    fail "test failed: backup marker details not reported"
    status=1
  fi
else
  printf '%s\n' "$pb_out" >&2
  fail "test failed: doctor must stay exit 0 with a backup marker"
  status=1
fi

# I2) capture_incomplete (#242): false -> "capture: complete" ok line; true ->
#     an action (warn + next-actions step) naming the re-run, exit 0.
printf '{"schema_version":1,"last_success":"2026-06-19T00:00:00Z","archive":"backup.age","file_count":2,"capture_incomplete":false}\n' \
  > "$fixture_home/.local/state/dotfiles/private-backup.json"
if pb_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && grep -Fq "[ok] last backup: 2026-06-19T00:00:00Z (archive: backup.age, files: 2, capture: complete)" <<< "$pb_out"; then
  ok "test passed: marker capture_incomplete=false -> capture: complete"
else
  printf '%s\n' "$pb_out" >&2
  fail "test failed: marker capture_incomplete=false not reported as complete (or doctor exited non-zero)"
  status=1
fi
printf '{"schema_version":1,"last_success":"2026-06-19T00:00:00Z","archive":"backup.age","file_count":2,"capture_incomplete":true}\n' \
  > "$fixture_home/.local/state/dotfiles/private-backup.json"
if pb_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && grep -Fq "[warn] last backup: 2026-06-19T00:00:00Z (archive: backup.age, files: 2) was INCOMPLETE: a declared directory could not be fully enumerated, so files under it are missing from that archive" <<< "$pb_out" \
  && grep -Fq "then run ./scripts/private-backup.sh backup again" <<< "$pb_out"; then
  ok "test passed: marker capture_incomplete=true -> INCOMPLETE action with the re-run step (exit 0)"
else
  printf '%s\n' "$pb_out" >&2
  fail "test failed: marker capture_incomplete=true not reported as an INCOMPLETE action"
  status=1
fi
printf '{"schema_version":1,"last_success":"2026-06-19T00:00:00Z","archive":"backup.age","file_count":2}\n' \
  > "$fixture_home/.local/state/dotfiles/private-backup.json"

# J) The local supplement is reported by existence only — never parsed or
#    its contents/count shown. A supplement with a recognisable secret-ish
#    line must not have that line (or an entry count) appear in output.
mkdir -p "$fixture_home/.config/dotfiles"
printf 'backup_paths:\n  - { path: .secret-canary-zzz, type: file }\n' \
  > "$fixture_home/.config/dotfiles/backup-paths.local"
if pb_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "local supplement present" <<< "$pb_out" \
    && ! grep -Fq "secret-canary-zzz" <<< "$pb_out"; then
    ok "test passed: local supplement reported by existence only (contents not leaked)"
  else
    printf '%s\n' "$pb_out" >&2
    fail "test failed: local supplement contents leaked or not reported"
    status=1
  fi
else
  printf '%s\n' "$pb_out" >&2
  fail "test failed: doctor must stay exit 0 with a local supplement"
  status=1
fi

# K) A malformed/null marker must not break doctor: report "unreadable"
#    and stay exit 0 (guards the set -euo pipefail paths in the section).
printf 'this is not valid json {{{\n' \
  > "$fixture_home/.local/state/dotfiles/private-backup.json"
if pb_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "backup marker present but unreadable" <<< "$pb_out"; then
    ok "test passed: malformed backup marker reported unreadable (exit 0)"
  else
    printf '%s\n' "$pb_out" >&2
    fail "test failed: malformed backup marker not handled"
    status=1
  fi
else
  printf '%s\n' "$pb_out" >&2
  fail "test failed: doctor must stay exit 0 on a malformed backup marker"
  status=1
fi

# project roots / agent root (#134): a missing STANDARD root is reported
# neutrally (an item), not as a warning, so a non-standard placement (repos kept
# outside ~/src) is not nagged. The fixture HOME has no ~/src/personal, so it
# must surface as a neutral "not present (standard root, optional)" item and
# never as a "missing: .../src/personal" warning.
if pr_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "not present (standard root, optional): $fixture_home/src/personal" <<< "$pr_out" \
    && ! grep -Fq "missing: $fixture_home/src/personal" <<< "$pr_out"; then
    ok "test passed: missing standard project root reported neutrally, not as a warning (#134)"
  else
    printf '%s\n' "$pr_out" >&2
    fail "test failed: standard project root missing must be neutral (#134), not a warning"
    status=1
  fi
else
  printf '%s\n' "$pr_out" >&2
  fail "test failed: doctor must stay exit 0 (project roots neutral)"
  status=1
fi

# Git signing report (enableGitSigning, issue #85). doctor stays report-only /
# exit 0 and must reflect both the active and the dangling (capability true but
# git-signing module inactive) cases. Throwaway repo copy so the edits do not
# touch the real data files.
sign_root="$fixture_home/.dotfiles-signing"
copy_repo_fixture "$sign_root"

# L) enableGitSigning=true with the git-signing module active -> managed mechanism.
set_capability_all "$sign_root" enableGitSigning true
if sg_out="$(HOME="$fixture_home" "$sign_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "SSH signing mechanism managed" <<< "$sg_out"; then
    ok "test passed: enableGitSigning=true reports the managed signing mechanism"
  else
    printf '%s\n' "$sg_out" >&2
    fail "test failed: managed signing mechanism not reported"
    status=1
  fi
else
  printf '%s\n' "$sg_out" >&2
  fail "test failed: doctor must stay exit 0 (enableGitSigning=true, module active)"
  status=1
fi

# M) enableGitSigning=true but the git-signing module removed -> dangling warning,
#    still exit 0.
remove_module_all "$sign_root" git-signing
if sg_out="$(HOME="$fixture_home" "$sign_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "git-signing module is inactive" <<< "$sg_out"; then
    ok "test passed: enableGitSigning=true with module inactive is reported as dangling"
  else
    printf '%s\n' "$sg_out" >&2
    fail "test failed: dangling enableGitSigning not reported"
    status=1
  fi
else
  printf '%s\n' "$sg_out" >&2
  fail "test failed: doctor must stay exit 0 (enableGitSigning dangling)"
  status=1
fi

# Global gitignore report (git-ignore module, #248). doctor stays report-only
# / exit 0 and must tell apart: managed file in effect (ok), missing
# (action naming mkdir + apply), redirected by core.excludesFile in the
# global scope, in the SYSTEM scope only, or by XDG_CONFIG_HOME (git reads
# another file; the value is a path and IS shown since it is not a secret),
# an explicitly EMPTY core.excludesFile (git reads no global excludes file:
# not "unset"), an unreadable config (unknown, not ok), drifted (a managed
# pattern line removed -> action), and the module-inactive profile (work).
# Every run is hermetic: `env -i` with only PATH, HOME and the git variables
# the case needs — GIT_CONFIG_NOSYSTEM=1 by default, GIT_CONFIG_SYSTEM
# pointing at a fixture file for the system-only case — so the developer
# shell's GIT_CONFIG_GLOBAL / XDG_CONFIG_HOME and the host's system
# gitconfig cannot leak in (Codex review).
gi_home="$fixture_home/gi"
gi_managed="$gi_home/.config/git/ignore"
gi_other="$gi_home/elsewhere/ignore"
# gi_check PROFILE EXPECT_LINE LABEL [VAR=value...] — extra env words for the
# doctor run; GIT_CONFIG_NOSYSTEM=1 when none are given.
gi_check() {
  local profile="$1" expect="$2" label="$3" out
  shift 3
  [[ $# -gt 0 ]] || set -- GIT_CONFIG_NOSYSTEM=1
  if out="$(env -i PATH="$PATH" HOME="$gi_home" "$@" "$SCRIPT_DIR/doctor.sh" "$profile" 2>&1)"; then
    if grep -Fxq -- "$expect" <<< "$out"; then
      ok "test passed: global gitignore $label"
    else
      printf '%s\n' "$out" >&2
      fail "test failed: global gitignore $label: expected the exact line '$expect'"
      status=1
    fi
  else
    printf '%s\n' "$out" >&2
    fail "test failed: doctor must stay exit 0 (global gitignore $label)"
    status=1
  fi
}
rm -rf "$gi_home"
mkdir -p "$gi_home/.config/git"
# GI-1) managed file present and read by git -> ok.
cp "$DOTFILES_ROOT/private_dot_config/git/ignore" "$gi_managed"
gi_check personal "[ok] global gitignore: managed $gi_managed is what git reads; excludes .agent-packets/ and **/.claude/settings.local.json in every repo" "managed file in effect -> ok"
# GI-2) missing -> action (mkdir then apply, %q-escaped like the identity reset).
rm -f "$gi_managed"
gi_check personal "[warn] global gitignore missing: $gi_managed (git-ignore module) — agent local-only files (.agent-packets/, .claude/settings.local.json) are excluded only where a repo's own .gitignore says so" "missing -> action"
if out="$(env -i PATH="$PATH" HOME="$gi_home" GIT_CONFIG_NOSYSTEM=1 "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && steps_consecutive "$out" "        \$ mkdir -p $(printf '%q' "$gi_home/.config")" \
    "        \$ chezmoi apply $(printf '%q' "$gi_home/.config/git") $(printf '%q' "$gi_managed")"; then
  ok "test passed: global gitignore missing -> steps are mkdir then apply, consecutive and %q-escaped"
else
  printf '%s\n' "${out:-<no output>}" >&2
  fail "test failed: global gitignore missing -> expected the mkdir step immediately followed by the apply step"
  status=1
fi
# GI-3) present but core.excludesFile points elsewhere -> git reads the other file.
cp "$DOTFILES_ROOT/private_dot_config/git/ignore" "$gi_managed"
mkdir -p "$gi_home/elsewhere"
: > "$gi_other"
gi_redirect="[warn] global gitignore: git reads $gi_other, not the managed $gi_managed (core.excludesFile in the global or system config, or XDG_CONFIG_HOME, redirects it) — the managed agent local-only patterns are not in effect"
printf '[core]\n\texcludesFile = %s\n' "$gi_other" > "$gi_home/.gitconfig"
gi_check personal "$gi_redirect" "redirected by core.excludesFile (global) -> warn"
# GI-3b) the same key in the SYSTEM scope only: git honours it, so a
#        --global-only lookup would wrongly report the managed file as in
#        effect (Codex must). GIT_CONFIG_SYSTEM stands in for the host file.
rm -f "$gi_home/.gitconfig"
printf '[core]\n\texcludesFile = %s\n' "$gi_other" > "$gi_home/system.gitconfig"
gi_check personal "$gi_redirect" "redirected by core.excludesFile (system scope only) -> warn" GIT_CONFIG_SYSTEM="$gi_home/system.gitconfig"
# GI-3c) ... but GIT_CONFIG_NOSYSTEM=1 makes git skip the system scope, and
#        so must the lookup (git config --system does not honour it itself).
gi_check personal "[ok] global gitignore: managed $gi_managed is what git reads; excludes .agent-packets/ and **/.claude/settings.local.json in every repo" "system-scope value is ignored under GIT_CONFIG_NOSYSTEM=1 -> ok" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM="$gi_home/system.gitconfig"
rm -f "$gi_home/system.gitconfig"
# GI-3d) XDG_CONFIG_HOME moves git's default location away from ~/.config.
gi_check personal "[warn] global gitignore: git reads $gi_home/xdg/git/ignore, not the managed $gi_managed (core.excludesFile in the global or system config, or XDG_CONFIG_HOME, redirects it) — the managed agent local-only patterns are not in effect" "redirected by XDG_CONFIG_HOME -> warn" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$gi_home/xdg"
# GI-3d2) ... but XDG_CONFIG_HOME naming ~/.config itself is the managed file,
#         however it is spelled: with repeated trailing slashes, or through a
#         symlink to ~/.config (-ef) — no false redirect warn (#309).
gi_ok="[ok] global gitignore: managed $gi_managed is what git reads; excludes .agent-packets/ and **/.claude/settings.local.json in every repo"
gi_check personal "$gi_ok" "XDG_CONFIG_HOME=~/.config// is the managed file -> ok" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$gi_home/.config//"
ln -s "$gi_home/.config" "$gi_home/config-alias"
gi_check personal "$gi_ok" "XDG_CONFIG_HOME through a symlink to ~/.config is the managed file -> ok" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$gi_home/config-alias"
rm -f "$gi_home/config-alias"
# GI-3e) explicitly EMPTY core.excludesFile: git reads no global excludes file
#        at all (measured: .agent-packets/x.md shows up in git status), so
#        falling back to the default path would be a false ok (Codex must).
printf '[core]\n\texcludesFile =\n' > "$gi_home/.gitconfig"
gi_check personal "[warn] global gitignore: core.excludesFile is explicitly empty (global or system config), so git reads NO global excludes file — the managed $gi_managed is not in effect; unset the key to restore git's default location" "explicitly empty core.excludesFile -> warn, no default fallback"
# GI-3f) a value-less key makes git refuse the config (fatal: missing
#        value): unknown, reported as such rather than as ok.
printf '[core]\n\texcludesFile\n' > "$gi_home/.gitconfig"
gi_check personal "[warn] global gitignore: git cannot read its global/system config (core.excludesFile lookup failed), so whether the managed $gi_managed is in effect is unknown — fix the config error first (git config --global --list / git config --system --list)" "unreadable global config -> unknown warn"
rm -f "$gi_home/.gitconfig"
# GI-4) present, read by git, but a managed pattern line is gone -> drift action.
grep -Fxv -- ".agent-packets/" "$DOTFILES_ROOT/private_dot_config/git/ignore" > "$gi_managed"
gi_check personal "[warn] global gitignore: $gi_managed lacks: .agent-packets/ (drifted from the managed file)" "pattern removed -> drift action"
# GI-5) work does not list the module -> not managed, whatever is on disk.
cp "$DOTFILES_ROOT/private_dot_config/git/ignore" "$gi_managed"
gi_check work "[ok] global gitignore not managed (git-ignore module inactive for profile work)" "work -> not managed"
rm -rf "$gi_home"

# herdr config report (herdr-config module, #261). doctor stays report-only
# / exit 0 and must tell apart: managed file present and accepted by `herdr
# config check` (ok), rejected by it (action naming the command — herdr then
# runs on all defaults), missing (action naming mkdir + apply), redirected by
# HERDR_CONFIG_PATH (to another file, or SET BUT EMPTY: herdr then reads no
# file) or by XDG_CONFIG_HOME (set but empty: a cwd-relative path) — a warn
# judged independently of presence, so a missing file under a redirect gets
# both lines and no "built-in defaults" claim (Codex review, PR #273), and a
# present one is not validated (the check would read the other file) — while
# the same directory spelled with a trailing slash is the same file, not a
# redirect, present or missing; and the module-inactive profile (work). `herdr config check` comes from a PATH-front fake whose exit
# status the case sets (the real herdr may or may not be on PATH). Every run
# is hermetic (`env -i`), so the developer shell's HERDR_CONFIG_PATH /
# XDG_CONFIG_HOME cannot leak in.
hc_home="$fixture_home/hc"
hc_managed="$hc_home/.config/herdr/config.toml"
hc_fakebin="$fixture_home/hcfake"
mkdir -p "$hc_fakebin"
# write_fake_herdr_config_check RC — `herdr config check` exits RC; anything
# else (the integration section's `herdr integration status`) exits 0 silently.
write_fake_herdr_config_check() {
  cat > "$hc_fakebin/herdr" <<SH
#!/bin/sh
if [ "\$1" = config ] && [ "\$2" = check ]; then exit $1; fi
exit 0
SH
  chmod +x "$hc_fakebin/herdr"
}
# hc_run PROFILE [VAR=value...] — doctor output in hc_out; returns doctor's status.
hc_run() {
  local profile="$1"
  shift
  hc_out="$(env -i PATH="$hc_fakebin:$PATH" HOME="$hc_home" "$@" "$SCRIPT_DIR/doctor.sh" "$profile" 2>&1)"
}
# hc_check LABEL EXPECT_LINE PROFILE [VAR=value...]
hc_check() {
  local label="$1" expect="$2"
  shift 2
  if hc_run "$@"; then
    if grep -Fxq -- "$expect" <<< "$hc_out"; then
      ok "test passed: herdr config $label"
    else
      printf '%s\n' "$hc_out" >&2
      fail "test failed: herdr config $label: expected the exact line '$expect'"
      status=1
    fi
  else
    printf '%s\n' "$hc_out" >&2
    fail "test failed: doctor must stay exit 0 (herdr config $label)"
    status=1
  fi
}
# hc_expect LABEL PROFILE [VAR=value...] -- EXPECT_LINE... [! ABSENT_SUBSTRING...]
# One doctor run; every EXPECT_LINE must appear as an exact line and, after a
# lone "!", no ABSENT_SUBSTRING may appear anywhere.
hc_expect() {
  local label="$1" run_args=() want=() absent=() mode=run arg missing=""
  shift
  for arg in "$@"; do
    case "$mode:$arg" in
      run:--) mode=want ;;
      run:*) run_args+=("$arg") ;;
      want:!) mode=absent ;;
      want:*) want+=("$arg") ;;
      absent:*) absent+=("$arg") ;;
    esac
  done
  if ! hc_run "${run_args[@]}"; then
    printf '%s\n' "$hc_out" >&2
    fail "test failed: doctor must stay exit 0 (herdr config $label)"
    status=1
    return
  fi
  for arg in "${want[@]}"; do
    grep -Fxq -- "$arg" <<< "$hc_out" || missing="${missing}expected line: $arg"$'\n'
  done
  for arg in "${absent[@]:-}"; do
    [[ -z "$arg" ]] && continue
    if grep -Fq -- "$arg" <<< "$hc_out"; then missing="${missing}unexpected: $arg"$'\n'; fi
  done
  if [[ -z "$missing" ]]; then
    ok "test passed: herdr config $label"
  else
    printf '%s\n%s' "$hc_out" "$missing" >&2
    fail "test failed: herdr config $label"
    status=1
  fi
}
hc_redirect_line() {
  printf '%s' "[warn] herdr config: HERDR_CONFIG_PATH or XDG_CONFIG_HOME in this environment points herdr at '$1', not the managed $hc_managed — the managed settings (including [ui.toast] delivery) are not in effect for a herdr started from here"
}
hc_missing_defaults="[warn] herdr config missing: $hc_managed (herdr-config module) — herdr runs on its built-in defaults, so agent state changes raise no OS notification ([ui.toast] delivery defaults to off)"
hc_missing_redirected="[warn] herdr config missing: $hc_managed (herdr-config module) — restoring it takes effect only once the redirect above is gone"
rm -rf "$hc_home"
mkdir -p "$hc_home/.config/herdr"
cp "$DOTFILES_ROOT/private_dot_config/herdr/config.toml" "$hc_managed"
# HC-1) present, herdr config check passes -> ok.
write_fake_herdr_config_check 0
hc_check "accepted -> ok" "[ok] herdr config: managed $hc_managed present and accepted by herdr config check" personal
# HC-2) present, herdr config check fails -> an ACTION naming the command:
#       the step line appears only in the next-actions summary, so a plain
#       warn would fail here (and drop out of --actions-only; Codex review).
write_fake_herdr_config_check 1
hc_expect "rejected -> action with the herdr config check step in next actions" personal -- \
  "[warn] herdr config: herdr config check did not pass for the managed $hc_managed (exit 1) — on a parse error herdr runs on ALL defaults, so agent state changes raise no OS notification; read its diagnostics, then fix the managed file" \
  "        \$ herdr config check"
write_fake_herdr_config_check 0
# HC-3) missing -> action whose steps are mkdir then apply, consecutive and %q-escaped.
rm -f "$hc_managed"
if hc_run personal \
  && grep -Fxq -- "$hc_missing_defaults" <<< "$hc_out" \
  && ! grep -Fq "points herdr at" <<< "$hc_out" \
  && steps_consecutive "$hc_out" "        \$ mkdir -p $(printf '%q' "$hc_home/.config")" \
    "        \$ chezmoi apply $(printf '%q' "$hc_home/.config/herdr") $(printf '%q' "$hc_managed")"; then
  ok "test passed: herdr config missing -> action with mkdir then apply steps"
else
  printf '%s\n' "${hc_out:-<no output>}" >&2
  fail "test failed: herdr config missing -> expected the action line and the mkdir step immediately followed by the apply step"
  status=1
fi
# HC-3b) missing AND redirected: the redirect is reported on its own and the
#        missing action drops the "built-in defaults" claim (the other file
#        may set delivery) for "takes effect only once the redirect is gone"
#        — to another file, and to nothing (set but empty).
hc_expect "missing + HERDR_CONFIG_PATH elsewhere -> redirect warn and redirect-aware missing action" \
  personal HERDR_CONFIG_PATH="$hc_home/other.toml" -- \
  "$(hc_redirect_line "$hc_home/other.toml")" "$hc_missing_redirected" ! "built-in defaults"
hc_expect "missing + HERDR_CONFIG_PATH empty -> redirect warn and redirect-aware missing action" \
  personal HERDR_CONFIG_PATH= -- \
  "$(hc_redirect_line "")" "$hc_missing_redirected" ! "built-in defaults"
# HC-3c) missing with XDG_CONFIG_HOME naming ~/.config with a trailing slash:
#        the same location (no -ef possible while the file is missing), so no
#        redirect warn and the plain missing action.
hc_expect "missing + XDG_CONFIG_HOME=~/.config/ -> plain missing action, no redirect" \
  personal XDG_CONFIG_HOME="$hc_home/.config/" -- "$hc_missing_defaults" ! "points herdr at"
cp "$DOTFILES_ROOT/private_dot_config/herdr/config.toml" "$hc_managed"
# HC-4) present but redirected: warn, and herdr config check is NOT run (it
#       would validate the other file) — the fake would fail it, so a run
#       would show the did-not-pass action. To another file, to nothing (set
#       but empty), by XDG_CONFIG_HOME, and by an empty XDG_CONFIG_HOME
#       (herdr then reads herdr/config.toml relative to its cwd).
write_fake_herdr_config_check 1
hc_not_checked="[info] - herdr config: managed $hc_managed present (validity not checked: herdr reads another file here)"
hc_expect "redirected by HERDR_CONFIG_PATH -> warn, check not run" \
  personal HERDR_CONFIG_PATH="$hc_home/other.toml" -- \
  "$(hc_redirect_line "$hc_home/other.toml")" "$hc_not_checked" ! "did not pass"
hc_expect "HERDR_CONFIG_PATH set but empty -> warn, check not run" \
  personal HERDR_CONFIG_PATH= -- "$(hc_redirect_line "")" "$hc_not_checked" ! "did not pass"
hc_expect "redirected by XDG_CONFIG_HOME -> warn, check not run" \
  personal XDG_CONFIG_HOME="$hc_home/xdg" -- \
  "$(hc_redirect_line "$hc_home/xdg/herdr/config.toml")" "$hc_not_checked" ! "did not pass"
hc_expect "XDG_CONFIG_HOME set but empty -> warn naming the cwd-relative path" \
  personal XDG_CONFIG_HOME= -- "$(hc_redirect_line "herdr/config.toml")" "$hc_not_checked"
write_fake_herdr_config_check 0
# HC-5) XDG_CONFIG_HOME naming ~/.config with a trailing slash is the same
#       file, so no redirect warning and the check runs.
hc_check "XDG_CONFIG_HOME=~/.config/ is the managed file -> ok" "[ok] herdr config: managed $hc_managed present and accepted by herdr config check" personal XDG_CONFIG_HOME="$hc_home/.config/"
# HC-5b) ... and so is XDG_CONFIG_HOME through a symlink to ~/.config (-ef, #307).
ln -s "$hc_home/.config" "$hc_home/config-alias"
hc_check "XDG_CONFIG_HOME through a symlink to ~/.config is the managed file -> ok" "[ok] herdr config: managed $hc_managed present and accepted by herdr config check" personal XDG_CONFIG_HOME="$hc_home/config-alias"
rm -f "$hc_home/config-alias"
# HC-6) work does not list the module -> not managed, whatever is on disk.
hc_check "work -> not managed" "[ok] herdr config not managed (herdr-config module inactive for profile work)" work
rm -rf "$hc_home" "$hc_fakebin"

# UR) agent-tools usage reader (agent-tools-usage-reader module, #301).
#     doctor stays report-only / exit 0. Presence is its own check: missing
#     -> action naming mkdir + apply; a symlink to nothing -> absent-like
#     action; not a regular file -> action. Whether a present file meets the
#     contract is the wrapper's verdict (#303): under the
#     enableAgentToolsStatus opt-in doctor asks the deployed wrapper's --help
#     whether it knows [--check], then runs --check with XDG_CONFIG_HOME
#     removed (the managed file, even under a redirect) and maps exit 0 -> ok,
#     2 -> action with the reason line, 3 -> the missing action, an exit
#     outside that contract -> not checked; no opt-in, no wrapper, or an
#     older wrapper -> not checked. An absolute
#     XDG_CONFIG_HOME elsewhere -> redirect warn (a relative one is ignored,
#     as the wrapper does; ~/.config/ with a trailing slash, or a symlink to
#     it, is the same file); work (module inactive) -> neutral. The wrapper
#     is a fake driven by files in $ur_ctl. A canary in the config must never
#     reach the report (contents-blind), the reader must never run, and the
#     wrapper may run only as --help / --check, the latter never seeing
#     XDG_CONFIG_HOME (each breach leaves a marker in $ur_ran). Every run is
#     hermetic (`env -i`).
ur_home="$fixture_home/ur"
ur_config="$ur_home/.config/agent-tools/usage-reader.json"
ur_reader="$ur_home/go/bin/tacho"
ur_wrapper="$ur_home/.claude/agent-tools/scripts/personal-usage-reader"
ur_canary="canary-usage-reader-7f3c"
ur_doctor="$SCRIPT_DIR/doctor.sh"
# ur_expect LABEL PROFILE [VAR=value...] -- EXPECT_LINE... [! ABSENT_SUBSTRING...]
# One doctor run ($ur_doctor); every EXPECT_LINE must appear as an exact line
# and, after a lone "!", no ABSENT_SUBSTRING may appear anywhere. The canary
# never may.
ur_expect() {
  local label="$1" run_args=() want=() absent=("$ur_canary") mode=run arg missing="" out
  shift
  for arg in "$@"; do
    case "$mode:$arg" in
      run:--) mode=want ;;
      run:*) run_args+=("$arg") ;;
      want:!) mode=absent ;;
      want:*) want+=("$arg") ;;
      absent:*) absent+=("$arg") ;;
    esac
  done
  if ! out="$(env -i PATH="$PATH" HOME="$ur_home" "${run_args[@]:1}" "$ur_doctor" "${run_args[0]}" 2>&1)"; then
    printf '%s\n' "$out" >&2
    fail "test failed: doctor must stay exit 0 (usage reader $label)"
    status=1
    return
  fi
  for arg in "${want[@]}"; do
    grep -Fxq -- "$arg" <<< "$out" || missing="${missing}expected line: $arg"$'\n'
  done
  for arg in "${absent[@]}"; do
    if grep -Fq -- "$arg" <<< "$out"; then missing="${missing}unexpected: $arg"$'\n'; fi
  done
  if [[ -z "$missing" ]]; then
    ok "test passed: usage reader $label"
  else
    printf '%s\n%s' "$out" "$missing" >&2
    fail "test failed: usage reader $label"
    status=1
  fi
}
# ur_write JSON — the config file's whole content.
ur_write() {
  mkdir -p "$(dirname "$ur_config")"
  printf '%s\n' "$1" > "$ur_config"
}
ur_ctl="$fixture_home/ur-ctl"
ur_ran="$fixture_home/ur-ran"
ur_asked="$fixture_home/ur-asked"
# ur_fake HELP_RC USAGE_LINE CHECK_RC [REASON] — how the fake wrapper answers
# --help (exit, first line) and --check (exit, stderr line), and a fresh
# record of what doctor asked it.
ur_fake() {
  printf '%s\n' "$1" > "$ur_ctl/help_rc"
  printf '%s\n' "$2" > "$ur_ctl/usage"
  printf '%s\n' "$3" > "$ur_ctl/check_rc"
  printf '%s' "${4:-}" > "$ur_ctl/reason"
  rm -rf "$ur_asked"
  mkdir -p "$ur_asked"
}
ur_usage="usage: personal-usage-reader [--help] [--check]"
ur_asked_check() {
  local label="$1" expected="$2"
  if [[ "$expected" == yes && -e "$ur_asked/check" ]] || [[ "$expected" == no && ! -e "$ur_asked/check" ]]; then
    ok "test passed: usage reader $label"
  else
    fail "test failed: usage reader $label (--check run: expected $expected)"
    status=1
  fi
}
ur_ok="[ok] usage reader config $ur_config present and accepted by personal-usage-reader --check (the agent-tools contract, argv[0] included; the reader itself not run)"
ur_unchecked="usage reader config $ur_config present; contract not checked"
ur_sync_step="        re-run the agent-tools sync (see the agent-tools README) so the current personal-usage-reader is deployed"
ur_apply_step="        \$ chezmoi apply $(printf '%q' "$ur_config")   # restores the managed content"
ur_install_step="        \$ ./scripts/install-packages.sh   # when the reason is the executable: dry-run first; --apply installs the catalog's tacho, the managed argv[0] under ~/go/bin"
ur_valid="{\"argv\": [\"$ur_reader\", \"$ur_canary\", \"--json\"], \"timeout_sec\": 20}"
ur_missing="[warn] usage reader config missing: $ur_config (agent-tools-usage-reader module) — agent-tools runs with no usage reader (assignment ignores the remaining budget; the maintenance sweep stays small)"
ur_redirect_line() {
  printf '%s' "[warn] usage reader: XDG_CONFIG_HOME in this environment points agent-tools at '$1', not the managed $ur_config — an agent started from here does not use the managed usage reader"
}
rm -rf "$ur_home" "$ur_ctl" "$ur_ran" "$ur_asked"
mkdir -p "$(dirname "$ur_reader")" "$(dirname "$ur_wrapper")" "$ur_ctl" "$ur_ran"
printf '#!/bin/sh\n: > %q\nexit 0\n' "$ur_ran/reader" > "$ur_reader"
chmod +x "$ur_reader"
cat > "$ur_wrapper" <<EOF
#!/bin/sh
case "\$*" in
  --help)
    : > $(printf '%q' "$ur_asked/help")
    cat $(printf '%q' "$ur_ctl/usage")
    exit "\$(cat $(printf '%q' "$ur_ctl/help_rc"))"
    ;;
  --check)
    : > $(printf '%q' "$ur_asked/check")
    if [ -n "\${XDG_CONFIG_HOME+set}" ]; then : > $(printf '%q' "$ur_ran/check-saw-xdg"); fi
    cat $(printf '%q' "$ur_ctl/reason") >&2
    exit "\$(cat $(printf '%q' "$ur_ctl/check_rc"))"
    ;;
esac
: > $(printf '%q' "$ur_ran/wrapper-without-check")
exit 0
EOF
chmod +x "$ur_wrapper"
ur_fake 0 "$ur_usage" 0
# UR-1) missing -> action whose steps are mkdir then apply, consecutive and
#       %q-escaped; presence needs no wrapper.
if ur_out="$(env -i PATH="$PATH" HOME="$ur_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && grep -Fxq -- "$ur_missing" <<< "$ur_out" \
  && ! grep -Fq "points agent-tools at" <<< "$ur_out" \
  && steps_consecutive "$ur_out" "        \$ mkdir -p $(printf '%q' "$ur_home/.config")" \
    "        \$ chezmoi apply $(printf '%q' "$ur_home/.config/agent-tools") $(printf '%q' "$ur_config")"; then
  ok "test passed: usage reader missing -> action with mkdir then apply steps"
else
  printf '%s\n' "${ur_out:-<no output>}" >&2
  fail "test failed: usage reader missing -> expected the action line and the mkdir step immediately followed by the apply step"
  status=1
fi
ur_asked_check "missing -> --check not run" no
# UR-1b) missing while an absolute XDG_CONFIG_HOME points elsewhere: the
#        redirect is reported and the missing action does not claim the
#        "no usage reader" effect (the other file may hold one).
ur_expect "missing + XDG_CONFIG_HOME elsewhere -> redirect warn and redirect-aware missing action" \
  personal XDG_CONFIG_HOME="$ur_home/xdg" -- \
  "$(ur_redirect_line "$ur_home/xdg/agent-tools/usage-reader.json")" \
  "[warn] usage reader config missing: $ur_config (agent-tools-usage-reader module) — restoring it takes effect only once the redirect above is gone" \
  ! "assignment ignores the remaining budget"
# UR-2) --check accepts -> ok, values never shown.
ur_write "$ur_valid"
ur_fake 0 "$ur_usage" 0
ur_expect "--check exit 0 -> ok" personal -- "$ur_ok" ! "contract not checked"
ur_asked_check "--check exit 0 -> --check run" yes
# UR-2b) doctor adopts the wrapper's verdict instead of judging the shape
#        itself: a file that is not JSON but that --check accepts is ok.
ur_write "not json $ur_canary"
ur_expect "--check accepts a non-JSON file -> ok (the wrapper decides, not doctor)" personal -- "$ur_ok"
ur_write "$ur_valid"
# UR-2c) XDG_CONFIG_HOME naming ~/.config with a trailing slash is the same
#        file; a relative XDG_CONFIG_HOME is ignored (as the wrapper does).
ur_expect "XDG_CONFIG_HOME=~/.config/ -> same file, ok" personal XDG_CONFIG_HOME="$ur_home/.config/" -- \
  "$ur_ok" ! "points agent-tools at"
ur_expect "relative XDG_CONFIG_HOME -> ignored, ok" personal XDG_CONFIG_HOME="rel/config" -- \
  "$ur_ok" ! "points agent-tools at"
# UR-2d) XDG_CONFIG_HOME through a symlink to ~/.config is the same file
#        (-ef): no redirect warning (#307).
ln -s "$ur_home/.config" "$ur_home/config-alias"
ur_expect "XDG_CONFIG_HOME through a symlink to ~/.config -> same file, ok" personal XDG_CONFIG_HOME="$ur_home/config-alias" -- \
  "$ur_ok" ! "points agent-tools at"
rm -f "$ur_home/config-alias"
# UR-3) --check rejects -> action carrying the reason without the wrapper's
#       name prefix, then the apply and the install steps.
ur_fake 0 "$ur_usage" 2 "personal-usage-reader: unknown key in the config"
if ur_out="$(env -i PATH="$PATH" HOME="$ur_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && grep -Fxq -- "[warn] usage reader config $ur_config rejected by personal-usage-reader --check (unknown key in the config) — personal-usage-reader fails (exit 2), so agent-tools reads no budget" <<< "$ur_out" \
  && steps_consecutive "$ur_out" "$ur_apply_step" "$ur_install_step" \
  && ! grep -Fq "$ur_canary" <<< "$ur_out"; then
  ok "test passed: usage reader --check exit 2 -> action with the reason, then the apply and install steps"
else
  printf '%s\n' "${ur_out:-<no output>}" >&2
  fail "test failed: usage reader --check exit 2 -> expected the action with the reason and the apply step immediately followed by the install step"
  status=1
fi
# UR-3b) terminal control in the reason is stripped (another repo's output).
ur_fake 0 "$ur_usage" 2 "personal-usage-reader: bad"$'\033'"[31m value"$'\r'
ur_expect "--check reason with terminal control -> stripped" personal -- \
  "[warn] usage reader config $ur_config rejected by personal-usage-reader --check (bad[31m value) — personal-usage-reader fails (exit 2), so agent-tools reads no budget"
# UR-3c) no reason line -> the action without a parenthesis.
ur_fake 0 "$ur_usage" 2
ur_expect "--check exit 2 without a reason -> action without a parenthesis" personal -- \
  "[warn] usage reader config $ur_config rejected by personal-usage-reader --check — personal-usage-reader fails (exit 2), so agent-tools reads no budget"
# UR-3d) rejected under a redirect: --check still judges the managed file (it
#        runs without XDG_CONFIG_HOME), while the wrapper agent-tools runs
#        reads the other file, so the action must not claim it fails (Codex
#        review, PR #302).
ur_fake 0 "$ur_usage" 2 "personal-usage-reader: unknown key in the config"
ur_expect "rejected + XDG_CONFIG_HOME elsewhere -> redirect-aware action" \
  personal XDG_CONFIG_HOME="$ur_home/xdg" -- \
  "$(ur_redirect_line "$ur_home/xdg/agent-tools/usage-reader.json")" \
  "[warn] usage reader config $ur_config rejected by personal-usage-reader --check (unknown key in the config) — fixing it takes effect only once the redirect above is gone" \
  ! "personal-usage-reader fails"
ur_asked_check "rejected + XDG_CONFIG_HOME elsewhere -> --check run" yes
# UR-4) --check exit 3 is the contract's "no config file" (the file went away
#       after doctor's presence check) -> the missing action with the same
#       mkdir then apply steps (Codex review R1, PR #324).
ur_fake 0 "$ur_usage" 3 "personal-usage-reader: no config file"
if ur_out="$(env -i PATH="$PATH" HOME="$ur_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && grep -Fxq -- "[warn] usage reader config $ur_config absent per personal-usage-reader --check (exit 3), though doctor found it a moment earlier — agent-tools runs with no usage reader (assignment ignores the remaining budget; the maintenance sweep stays small)" <<< "$ur_out" \
  && steps_consecutive "$ur_out" "        \$ mkdir -p $(printf '%q' "$ur_home/.config")" \
    "        \$ chezmoi apply $(printf '%q' "$ur_home/.config/agent-tools") $(printf '%q' "$ur_config")" \
  && ! grep -Fq "contract not checked" <<< "$ur_out"; then
  ok "test passed: usage reader --check exit 3 -> missing action with mkdir then apply steps"
else
  printf '%s\n' "${ur_out:-<no output>}" >&2
  fail "test failed: usage reader --check exit 3 -> expected the absent action and the mkdir step immediately followed by the apply step"
  status=1
fi
# UR-4b) an exit outside the contract (0 / 2 / 3) is no verdict -> not checked.
ur_fake 0 "$ur_usage" 1
ur_expect "--check exit 1 -> not checked" personal -- \
  "[warn] $ur_unchecked: personal-usage-reader --check exited 1, outside its contract (0 / 2 / 3)" \
  ! "$ur_ok" ! "rejected by" ! "absent per"
# UR-5) a wrapper that predates --check (--help without [--check], or no
#       --help at all) -> not checked, the sync step, and --check never run
#       (it would read as "invalid").
ur_fake 0 "usage: personal-usage-reader [--help]" 0
ur_expect "wrapper without [--check] in --help -> not checked, sync action" personal -- \
  "[warn] $ur_unchecked: the deployed personal-usage-reader predates --check (agent-tools#400)" \
  "$ur_sync_step" ! "$ur_ok"
ur_asked_check "wrapper without [--check] -> --check not run" no
# A failing --help may also be a wrapper that cannot run here (say, its
# interpreter is missing): not checked, without claiming it is old.
ur_fake 127 "" 0
ur_expect "wrapper whose --help fails -> not checked, no old-wrapper claim" personal -- \
  "[warn] $ur_unchecked: personal-usage-reader --help exited 127 (it cannot run here, or predates --help)" \
  ! "$ur_ok" ! "predates --check"
ur_asked_check "wrapper whose --help fails -> --check not run" no
# UR-6) the wrapper not deployed (absent, or not executable) -> not checked
#       with the sync step.
ur_fake 0 "$ur_usage" 0
chmod -x "$ur_wrapper"
ur_expect "wrapper not executable -> not deployed action" personal -- \
  "[warn] $ur_unchecked: agent-tools' personal-usage-reader is not deployed at $ur_wrapper, and nothing reads this config without it" \
  "$ur_sync_step" ! "$ur_ok"
mv "$ur_wrapper" "$ur_wrapper.away"
ur_expect "wrapper absent -> not deployed action" personal -- \
  "[warn] $ur_unchecked: agent-tools' personal-usage-reader is not deployed at $ur_wrapper, and nothing reads this config without it" ! "$ur_ok"
mv "$ur_wrapper.away" "$ur_wrapper"
chmod +x "$ur_wrapper"
# UR-7) without the enableAgentToolsStatus opt-in doctor runs no agent-tools
#       code: not checked, and the wrapper asked nothing at all.
ur_fake 0 "$ur_usage" 0
ur_doctor="$optout_root/scripts/doctor.sh"
ur_expect "no enableAgentToolsStatus opt-in -> not checked" personal -- \
  "[info] - $ur_unchecked (doctor runs agent-tools' personal-usage-reader --check only under enableAgentToolsStatus=true)" \
  ! "$ur_ok" ! "rejected by"
ur_doctor="$SCRIPT_DIR/doctor.sh"
if [[ -z "$(ls -A "$ur_asked")" ]]; then
  ok "test passed: usage reader: no opt-in -> the wrapper is not run at all"
else
  fail "test failed: usage reader: no opt-in, yet doctor ran the wrapper ($(ls -A "$ur_asked" | tr '\n' ' '))"
  status=1
fi
# UR-8) something other than a regular file at the path -> action, no --check.
rm -f "$ur_config"
mkdir -p "$ur_config"
ur_fake 0 "$ur_usage" 0
ur_expect "directory at the path -> action" personal -- \
  "[warn] usage reader config $ur_config is not a regular file — personal-usage-reader fails (exit 2), so agent-tools reads no budget"
ur_asked_check "directory at the path -> --check not run" no
rm -rf "$ur_config"
# UR-8b) a dangling symlink: the wrapper treats it as absent (exit 3), so the
#        action says "no usage reader", not that the wrapper fails (Codex
#        review R3, PR #302).
ln -s "$ur_home/nowhere.json" "$ur_config"
ur_expect "dangling symlink -> absent-like action, no exit-2 claim" personal -- \
  "[warn] usage reader config $ur_config is a symlink to nothing — agent-tools runs with no usage reader (assignment ignores the remaining budget; the maintenance sweep stays small)" \
  "        \$ rm -i $(printf '%q' "$ur_config")   # the dangling link" \
  ! "personal-usage-reader fails"
rm -f "$ur_config"
# UR-9) work does not list the module: a hand-placed file is neutral, none is
#       ok — and under a redirect neither claims what agent-tools reads
#       (Codex review R2, PR #302).
ur_expect "work, no file -> ok" work -- \
  "[ok] no usage reader config (not managed for this profile; agent-tools runs with no usage reader)"
ur_expect "work, no file + XDG_CONFIG_HOME elsewhere -> ok naming the other file" work XDG_CONFIG_HOME="$ur_home/xdg" -- \
  "[ok] no usage reader config (not managed for this profile; XDG_CONFIG_HOME points agent-tools at '$ur_home/xdg/agent-tools/usage-reader.json' here)" \
  ! "runs with no usage reader"
ur_write "$ur_valid"
ur_expect "work, hand-placed file -> neutral item" work -- \
  "[info] - $ur_config present but not managed for this profile (hand-placed?); agent-tools' personal-usage-reader reads it whenever it exists" \
  ! "personal-usage-reader fails"
ur_expect "work, hand-placed file + XDG_CONFIG_HOME elsewhere -> neutral item naming the other file" work XDG_CONFIG_HOME="$ur_home/xdg" -- \
  "[info] - $ur_config present but not managed for this profile (hand-placed?); XDG_CONFIG_HOME points agent-tools at '$ur_home/xdg/agent-tools/usage-reader.json' here instead" \
  ! "reads it whenever it exists"
# UR-10) across every run above, doctor never ran the reader, ran the wrapper
#        only as --help / --check, and never let --check see XDG_CONFIG_HOME.
if [[ -z "$(ls -A "$ur_ran")" ]]; then
  ok "test passed: usage reader: doctor ran neither the reader nor the wrapper beyond --help / --check (which never saw XDG_CONFIG_HOME)"
else
  fail "test failed: usage reader: markers left: $(ls -A "$ur_ran" | tr '\n' ' ')(doctor must stay side-effect free and check the managed file)"
  status=1
fi
rm -rf "$ur_home" "$ur_ctl" "$ur_ran" "$ur_asked"

# SSH 1Password agent report (enable1PasswordSSH, issue #17). doctor stays
# report-only / exit 0 and must reflect both the active and the dangling
# (capability true but ssh-1password module inactive) cases. Throwaway repo
# copy so the edits do not touch the real data files.
ssh_root="$fixture_home/.dotfiles-ssh"
copy_repo_fixture "$ssh_root"

# N) enable1PasswordSSH=true with the ssh-1password module active -> managed agent.
#    personal's committed default is true + module present, so no mutation needed.
if ss_out="$(HOME="$fixture_home" "$ssh_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "managed ~/.ssh/config carries the 1Password agent" <<< "$ss_out"; then
    ok "test passed: enable1PasswordSSH=true reports the managed SSH agent"
  else
    printf '%s\n' "$ss_out" >&2
    fail "test failed: managed SSH agent not reported"
    status=1
  fi
else
  printf '%s\n' "$ss_out" >&2
  fail "test failed: doctor must stay exit 0 (enable1PasswordSSH=true, module active)"
  status=1
fi

# O) enable1PasswordSSH=true but the ssh-1password module removed -> dangling
#    warning, still exit 0.
remove_module_all "$ssh_root" ssh-1password
if ss_out="$(HOME="$fixture_home" "$ssh_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "ssh-1password module is inactive" <<< "$ss_out"; then
    ok "test passed: enable1PasswordSSH=true with module inactive is reported as dangling"
  else
    printf '%s\n' "$ss_out" >&2
    fail "test failed: dangling enable1PasswordSSH not reported"
    status=1
  fi
else
  printf '%s\n' "$ss_out" >&2
  fail "test failed: doctor must stay exit 0 (enable1PasswordSSH dangling)"
  status=1
fi

# GitHub injection guard report (gateGitHubMcp / enableGitHubIsolatedReader, #119).
# gateGitHubMcp is wired (PR2: MCP deny in managed settings.json); doctor must
# report it as enforced when active. enableGitHubIsolatedReader is wired too
# (#137: PreToolUse hook registration in managed settings.json); doctor reports
# the registration plus the agent-tools-deployed body's presence (absent ->
# fail-open no-op warn). doctor stays exit 0 (no dead capability).
# Throwaway repo copy so the flip does not touch the real data files.
gh_root="$fixture_home/.dotfiles-ghguard"
copy_repo_fixture "$gh_root"

# P) committed personal: gateGitHubMcp AND enableGitHubIsolatedReader are ON
#    (Phase 2 / #137) and claude-settings is active, so doctor reports the
#    github MCP server denied and the PreToolUse hook registered. The fixture
#    HOME has no agent-tools deployment, so the hook body is absent -> the
#    body-absent warn (fail-open no-op), and doctor stays exit 0 (report-only).
#    Check all so the section can't silently drop one (dead-capability guard).
if gh_out="$(HOME="$fixture_home" "$gh_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "denies the github MCP server" <<< "$gh_out" \
    && grep -Fq "hook registered in managed settings.json but the body is absent" <<< "$gh_out" \
    && grep -Fq "registered in managed ~/.codex/hooks.json but the body is absent" <<< "$gh_out" \
    && grep -Fq "secret floor active" <<< "$gh_out" \
    && grep -Fq "human-legit write gate INERT" <<< "$gh_out"; then
    ok "test passed: MCP deny + secret floor active + human-legit gate inert + Claude & Codex hooks registered with absent bodies warned (fail-open)"
  else
    printf '%s\n' "$gh_out" >&2
    fail "test failed: GitHub guard capability not reported"
    status=1
  fi
else
  printf '%s\n' "$gh_out" >&2
  fail "test failed: doctor must stay exit 0 (GitHub guard, default)"
  status=1
fi

# P2) trust list (#119 PR3): the injection-guard section points to the
#     non-committed trust list, and the private-backup section reports its
#     presence contents-blind (it is in backup-paths.yaml). The fixture HOME has
#     no trust list, so it must show as a baseline-absent target. Reuses the
#     default (case P) gh_out before case Q overwrites it.
if grep -Fq "trust list: ~/.config/dotfiles/github-trust.local" <<< "$gh_out" \
  && grep -Fq "baseline absent: .config/dotfiles/github-trust.local" <<< "$gh_out"; then
  ok "test passed: trust list wired (injection-guard pointer + backup catalog presence, contents-blind)"
else
  printf '%s\n' "$gh_out" >&2
  fail "test failed: trust list pointer or backup-catalog presence not reported"
  status=1
fi

# P3) trust list PRESENT: doctor must report it present via the backup catalog
#     but NEVER echo its contents (contents-blind even when the file exists). A
#     canary line catches a regression that read/leaked the file. Clean up after
#     so later cases (Q) see the absent state again.
mkdir -p "$fixture_home/.config/dotfiles"
printf 'trusted-login = CANARY_TRUST_LEAK_7f3a\n' \
  > "$fixture_home/.config/dotfiles/github-trust.local"
if tl_out="$(HOME="$fixture_home" "$gh_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "baseline present: .config/dotfiles/github-trust.local" <<< "$tl_out" \
    && ! grep -Fq "CANARY_TRUST_LEAK_7f3a" <<< "$tl_out"; then
    ok "test passed: trust list present reported, contents never echoed (contents-blind)"
  else
    printf '%s\n' "$tl_out" >&2
    fail "test failed: trust list present-state or contents-blind invariant not held"
    status=1
  fi
else
  printf '%s\n' "$tl_out" >&2
  fail "test failed: doctor must stay exit 0 (trust list present)"
  status=1
fi
rm -f "$fixture_home/.config/dotfiles/github-trust.local"

# Q) hook body PRESENT (executable) in the fixture HOME -> the isolated-reader
#    line flips from the body-absent warn (case P) to the wired ok. Presence is
#    reported contents-blind (doctor never reads the body). Clean up after so
#    later cases see the absent state again.
set_capability_all "$gh_root" gateGitHubMcp true
set_capability_all "$gh_root" enableGitHubIsolatedReader true
mkdir -p "$fixture_home/.claude/agent-tools/scripts"
printf '#!/bin/sh\nexit 0\n' > "$fixture_home/.claude/agent-tools/scripts/personal-safe-gh-hook"
chmod +x "$fixture_home/.claude/agent-tools/scripts/personal-safe-gh-hook"
# Codex parity (#181): deploy the Codex-home body too so the codex-settings line
# flips to its wired ok (present, contents-blind). Its stable path mirrors the
# Claude one under ~/.codex (agent-tools#146).
mkdir -p "$fixture_home/.codex/agent-tools/scripts"
printf '#!/bin/sh\nexit 0\n' > "$fixture_home/.codex/agent-tools/scripts/personal-safe-gh-hook"
chmod +x "$fixture_home/.codex/agent-tools/scripts/personal-safe-gh-hook"
if gh_out="$(HOME="$fixture_home" "$gh_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "denies the github MCP server" <<< "$gh_out" \
    && grep -Fq "managed settings.json registers the PreToolUse hook -> safe-gh steering (fail-open, not a boundary); hook body present" <<< "$gh_out" \
    && grep -Fq "managed ~/.codex/hooks.json registers the PreToolUse hook -> safe-gh steering (fail-open, not a boundary); hook body present" <<< "$gh_out"; then
    ok "test passed: gateGitHubMcp=true enforced; Claude & Codex hook registration + present bodies reported as wired steering"
  else
    printf '%s\n' "$gh_out" >&2
    fail "test failed: gateGitHubMcp wired-state or isolated-reader (Claude/Codex) wired state not reported"
    status=1
  fi
else
  printf '%s\n' "$gh_out" >&2
  fail "test failed: doctor must stay exit 0 (GitHub guard, flipped true)"
  status=1
fi
rm -f "$fixture_home/.claude/agent-tools/scripts/personal-safe-gh-hook"
rm -f "$fixture_home/.codex/agent-tools/scripts/personal-safe-gh-hook"

# R) enforceAiSandbox=true: the injection-guard section discloses the human-legit
#    write gate as ACTIVE (it rides on enforceAiSandbox), with the always-on secret
#    floor active too. Covers the other branch; case P covered the inert
#    (enforceAiSandbox=false) branch. Builds on case Q's mutated copy
#    (claude-settings active for personal). exit 0.
set_capability_all "$gh_root" enforceAiSandbox true
if gh_out="$(HOME="$fixture_home" "$gh_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "human-legit write gate active" <<< "$gh_out" \
    && grep -Fq "secret floor active" <<< "$gh_out"; then
    ok "test passed: enforceAiSandbox=true -> human-legit write gate active (secret floor active too)"
  else
    printf '%s\n' "$gh_out" >&2
    fail "test failed: human-legit write gate active-state not reported when enforceAiSandbox=true"
    status=1
  fi
else
  printf '%s\n' "$gh_out" >&2
  fail "test failed: doctor must stay exit 0 (human-legit write gate active)"
  status=1
fi

# QL) quality loop hooks (#199): enableQualityLoopHooks is ON for committed
#     personal, so doctor reports the registration in BOTH AI homes plus the
#     agent-tools-deployed bodies' presence (contents-blind), and the
#     checks.local.json declaration presence (contents-blind — it names
#     commands the hooks run). Own fixture copy so the flips here never
#     couple to the injection-guard cases above. doctor stays exit 0
#     throughout (report-only).
ql_root="$fixture_home/.dotfiles-qlhooks"
copy_repo_fixture "$ql_root"
ql_claude="$fixture_home/.claude/agent-tools/scripts"
ql_codex="$fixture_home/.codex/agent-tools/scripts"
#     QL-a) no bodies deployed, no checks file -> both homes warn body-absent
#           (fail-open no-op) and the checks-absent item shows.
if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "managed ~/.claude/settings.json registers the quality-loop hooks but a body is absent or non-executable: personal-fast-edit-check personal-changed-scope-qa" <<< "$ql_out" \
    && grep -Fq "managed ~/.codex/hooks.json registers the quality-loop hooks but a body is absent or non-executable: personal-fast-edit-check personal-changed-scope-qa" <<< "$ql_out" \
    && grep -Fq "checks.local.json absent" <<< "$ql_out"; then
    ok "test passed: quality-loop hooks registered in both homes with absent bodies warned (fail-open) and no check declaration reported"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: quality-loop hooks absent-body / absent-declaration state not reported"
    status=1
  fi
else
  printf '%s\n' "$ql_out" >&2
  fail "test failed: doctor must stay exit 0 (quality loop hooks, bodies absent)"
  status=1
fi
#     QL-b) one body missing in one home -> that home warns naming ONLY the
#           missing body; the fully deployed home reports ok. Plus a checks
#           file whose content must never be echoed (canary).
mkdir -p "$ql_claude" "$ql_codex" "$fixture_home/.config/agent-tools"
for ql_body in personal-fast-edit-check personal-changed-scope-qa; do
  printf '#!/bin/sh\nexit 0\n' > "$ql_claude/$ql_body"
  chmod +x "$ql_claude/$ql_body"
done
printf '#!/bin/sh\nexit 0\n' > "$ql_codex/personal-fast-edit-check"
chmod +x "$ql_codex/personal-fast-edit-check"
printf '{"/canary/repo": {"qa_checks": [{"name": "CANARY_CHECK_LEAK_5b1e", "command": ["true"]}]}}\n' \
  > "$fixture_home/.config/agent-tools/checks.local.json"
if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "managed ~/.claude/settings.json registers PostToolUse(Edit|Write) -> fast-edit-check and Stop -> changed-scope-qa (best-effort, not a boundary); both bodies present" <<< "$ql_out" \
    && grep -Fq "managed ~/.codex/hooks.json registers the quality-loop hooks but a body is absent or non-executable: personal-changed-scope-qa (" <<< "$ql_out" \
    && grep -Fq "checks.local.json present (contents never read" <<< "$ql_out" \
    && ! grep -Fq "CANARY_CHECK_LEAK_5b1e" <<< "$ql_out"; then
    ok "test passed: Claude home wired ok, Codex home warns only the missing body, checks file present reported contents-blind"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: partial-deploy / checks-present state not reported, or the checks file was echoed"
    status=1
  fi
else
  printf '%s\n' "$ql_out" >&2
  fail "test failed: doctor must stay exit 0 (quality loop hooks, partial deploy)"
  status=1
fi
#     QL-c) both homes fully deployed -> both ok lines (Codex with its trust
#           honest-label).
printf '#!/bin/sh\nexit 0\n' > "$ql_codex/personal-changed-scope-qa"
chmod +x "$ql_codex/personal-changed-scope-qa"
if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "managed ~/.claude/settings.json registers PostToolUse(Edit|Write) -> fast-edit-check and Stop -> changed-scope-qa (best-effort, not a boundary); both bodies present" <<< "$ql_out" \
    && grep -Fq "managed ~/.codex/hooks.json registers PostToolUse(Edit|Write) -> fast-edit-check and Stop -> changed-scope-qa (best-effort, not a boundary); both bodies present (Codex: inert until a one-time /hooks trust)" <<< "$ql_out"; then
    ok "test passed: quality-loop hooks reported wired in both homes once every body is deployed (Codex line carries the trust caveat)"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: fully deployed quality-loop hooks not reported as wired in both homes"
    status=1
  fi
else
  printf '%s\n' "$ql_out" >&2
  fail "test failed: doctor must stay exit 0 (quality loop hooks, fully deployed)"
  status=1
fi
rm -rf "$ql_claude" "$ql_codex" "$fixture_home/.config/agent-tools"
#     QL-d) capability off -> the not-wired ok line and none of the wired /
#           dangling lines (dead-capability guard in the other direction).
set_capability_all "$ql_root" enableQualityLoopHooks false
if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "quality loop hooks not wired (enableQualityLoopHooks=false)" <<< "$ql_out" \
    && ! grep -Fq "enableQualityLoopHooks=true" <<< "$ql_out"; then
    ok "test passed: enableQualityLoopHooks=false reports not wired and nothing else"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: enableQualityLoopHooks=false state not reported cleanly"
    status=1
  fi
else
  printf '%s\n' "$ql_out" >&2
  fail "test failed: doctor must stay exit 0 (quality loop hooks, capability off)"
  status=1
fi
#     QL-d2) capability off but a registration LINGERS in the live files (a
#            home that applied personal, then switched to a profile without
#            the settings modules — chezmoiignore never prunes the target):
#            doctor must warn instead of the not-wired ok, naming the file,
#            and must not echo the file's contents (canary). Codex review,
#            PR #200.
mkdir -p "$fixture_home/.claude" "$fixture_home/.codex"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/.codex/agent-tools/scripts/personal-changed-scope-qa"}]}]},"CANARY_LINGER_LEAK_9c2d":true}\n' \
  > "$fixture_home/.codex/hooks.json"
if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "enableQualityLoopHooks=false but a quality-loop hook registration lingers in $fixture_home/.codex/hooks.json" <<< "$ql_out" \
    && ! grep -Fq "quality loop hooks not wired (enableQualityLoopHooks=false)" <<< "$ql_out" \
    && ! grep -Fq "CANARY_LINGER_LEAK_9c2d" <<< "$ql_out"; then
    ok "test passed: enableQualityLoopHooks=false with a lingering registration warns (file named, contents never echoed)"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: lingering quality-loop registration not warned, or the file was echoed"
    status=1
  fi
else
  printf '%s\n' "$ql_out" >&2
  fail "test failed: doctor must stay exit 0 (quality loop hooks, lingering registration)"
  status=1
fi
rm -f "$fixture_home/.codex/hooks.json"
#     QL-e) capability on but the claude-settings module removed -> dangling
#           warn for the Claude home (the Codex home still reports normally).
set_capability_all "$ql_root" enableQualityLoopHooks true
remove_module_all "$ql_root" claude-settings
if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "enableQualityLoopHooks=true but the claude-settings module is inactive for this profile" <<< "$ql_out" \
    && grep -Fq "managed ~/.codex/hooks.json registers the quality-loop hooks but a body is absent" <<< "$ql_out"; then
    ok "test passed: enableQualityLoopHooks=true with claude-settings inactive is reported as dangling (Codex side unaffected)"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: dangling enableQualityLoopHooks not reported"
    status=1
  fi
else
  printf '%s\n' "$ql_out" >&2
  fail "test failed: doctor must stay exit 0 (quality loop hooks dangling)"
  status=1
fi

# HI) herdr integration (#225): enableHerdrIntegration is ON for committed
#     personal, so doctor reports the SessionStart registration in BOTH AI
#     homes plus the herdr-installed bodies' presence (contents-blind) and
#     their version currency per `herdr integration status`. The status
#     engine is a PATH-front fake herdr (fake-driven fixture, same pattern as
#     the codex shim below — the real herdr may or may not be on PATH, and a
#     fixture body would read as outdated/current at its whim), printing one
#     line per agent in herdr's `<agent>: <state> (<path>)` format. MODE
#     `ok` exits 0; `ok-nonl` exits 0 without a trailing newline (the
#     reader must still see the status line); `fail` prints the same lines
#     but exits 1 (doctor must discard them); `hang` forks a `sleep 60`
#     GRANDCHILD (pid recorded in sleep.pid) and waits on it, so the
#     deadline must reap the whole process tree, not just the wrapper;
#     `interrupt` does the same and then, from inside the running probe,
#     sends SIGTERM to the doctor whose pid the test left in doctor.pid —
#     the only way to deliver the interrupt while the probe is provably
#     running, with no timing window (Codex review, PR #226). Own fixture
#     copy; doctor stays exit 0 throughout.
hi_root="$fixture_home/.dotfiles-herdr"
copy_repo_fixture "$hi_root"
hi_claude_body="$fixture_home/.claude/hooks/herdr-agent-state.sh"
hi_codex_body="$fixture_home/.codex/herdr-agent-state.sh"
hi_fakebin="$fixture_home/herdrfake"
mkdir -p "$hi_fakebin"
# write_fake_herdr_status CLAUDE_STATE CODEX_STATE MODE
write_fake_herdr_status() {
  cat > "$hi_fakebin/herdr" <<SH
#!/bin/sh
[ "\$1" = integration ] && [ "\$2" = status ] || exit 2
if [ "$3" = hang ]; then sleep 60 & printf '%s\\n' "\$!" > "$hi_fakebin/sleep.pid"; wait; fi
if [ "$3" = interrupt ]; then sleep 60 & printf '%s\\n' "\$!" > "$hi_fakebin/sleep.pid"; kill -TERM "\$(cat "$hi_fakebin/doctor.pid")"; wait; fi
if [ "$3" = ok-nonl ]; then printf '%s\\n%s' "claude: $1 ($hi_claude_body)" "codex: $2 ($hi_codex_body)"; exit 0; fi
printf '%s\\n' "claude: $1 ($hi_claude_body)" "codex: $2 ($hi_codex_body)"
[ "$3" = ok ]
SH
  chmod +x "$hi_fakebin/herdr"
}
hi_claude_ok="managed ~/.claude/settings.json registers SessionStart -> herdr-agent-state.sh session; body present"
hi_codex_ok="managed ~/.codex/hooks.json registers SessionStart -> herdr-agent-state.sh session; body present"
hi_codex_note="(Codex: inert until a one-time /hooks trust; the installer also sets [features] hooks = true in codex-owned ~/.codex/config.toml, which dotfiles does not manage)"
hi_unchecked="(version currency not checked: herdr integration status unavailable)"
#     HI-a) no bodies installed -> both homes warn body-absent naming the
#           install command (fail-open no-op); the scope item shows. Real
#           PATH: the body-absent branch does not depend on herdr's answer.
if hi_out="$(HOME="$fixture_home" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "managed ~/.claude/settings.json registers the SessionStart hook but the body is absent or unreadable ($hi_claude_body; run: herdr integration install claude) — fail-open no-op until installed" <<< "$hi_out" \
    && grep -Fq "managed ~/.codex/hooks.json registers the SessionStart hook but the body is absent or unreadable ($hi_codex_body; run: herdr integration install codex) — fail-open no-op until installed $hi_codex_note" <<< "$hi_out" \
    && grep -Fq "scope: the hook reports the agent session id to the herdr server only from inside a herdr pane" <<< "$hi_out"; then
    ok "test passed: herdr integration registered in both homes with absent bodies warned (fail-open, install command named) and the scope item shown"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: herdr integration absent-body state not reported"
    status=1
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration, bodies absent)"
  status=1
fi
#     HI-b) both bodies present WITHOUT an exec bit (the registration runs
#           them via bash, so a readable regular file is what counts) and
#           herdr reports current -> both ok lines (Codex with its trust /
#           config.toml honest-label).
mkdir -p "$(dirname "$hi_claude_body")" "$(dirname "$hi_codex_body")"
printf '#!/bin/sh\nexit 0\n' > "$hi_claude_body"
printf '#!/bin/sh\nexit 0\n' > "$hi_codex_body"
chmod 0644 "$hi_claude_body" "$hi_codex_body"
write_fake_herdr_status "current (v9)" "current (v8)" ok
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "$hi_claude_ok and current per herdr integration status" <<< "$hi_out" \
    && grep -Fq "$hi_codex_ok and current per herdr integration status $hi_codex_note" <<< "$hi_out" \
    && ! grep -Fq "re-run: herdr integration install" <<< "$hi_out"; then
    ok "test passed: herdr integration reported wired and current in both homes with non-executable bodies (Codex line carries the trust + config.toml caveats)"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: current herdr integration not reported as wired in both homes"
    status=1
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration, current)"
  status=1
fi
#     HI-b1) herdr answers without a trailing newline -> the status line must
#            still be seen and the answer adopted (no "unchecked").
write_fake_herdr_status "current (v9)" "current (v8)" ok-nonl
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "$hi_claude_ok and current per herdr integration status" <<< "$hi_out" \
    && grep -Fq "$hi_codex_ok and current per herdr integration status $hi_codex_note" <<< "$hi_out"; then
    ok "test passed: a herdr answer without a trailing newline is still adopted as current"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: a herdr answer without a trailing newline was not adopted"
    status=1
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration, no trailing newline)"
  status=1
fi
#     HI-b2) a directory at the body path must NOT count as present (a
#            bare -x/-e probe would pass it).
rm -f "$hi_claude_body"
mkdir -p "$hi_claude_body"
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "managed ~/.claude/settings.json registers the SessionStart hook but the body is absent or unreadable ($hi_claude_body;" <<< "$hi_out" \
    && grep -Fq "$hi_codex_ok and current per herdr integration status" <<< "$hi_out"; then
    ok "test passed: a directory at the herdr body path is reported absent (regular-file check), Codex home unaffected"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: a directory at the herdr body path passed the presence check"
    status=1
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration, directory body)"
  status=1
fi
rmdir "$hi_claude_body"
printf '#!/bin/sh\nexit 0\n' > "$hi_claude_body"
chmod 0644 "$hi_claude_body"
#     HI-c) bodies present but herdr reports outdated / needs repair -> warn
#           per home naming the state and the re-install command.
write_fake_herdr_status "outdated (v1 < v9)" "needs repair (v8)" ok
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "managed ~/.claude/settings.json registers the SessionStart hook and the body is present, but herdr integration status reports it 'outdated' — re-run: herdr integration install claude" <<< "$hi_out" \
    && grep -Fq "managed ~/.codex/hooks.json registers the SessionStart hook and the body is present, but herdr integration status reports it 'needs repair' — re-run: herdr integration install codex $hi_codex_note" <<< "$hi_out" \
    && ! grep -Fq "and current per herdr integration status" <<< "$hi_out"; then
    ok "test passed: outdated / needs-repair herdr bodies warned per home with the re-install command"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: outdated herdr integration state not warned"
    status=1
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration, outdated)"
  status=1
fi
#     HI-d) herdr prints "current" lines but exits non-zero -> the output
#           must be discarded: presence-only ok lines saying currency was
#           not checked, never a "current". herdr absent from PATH (CI)
#           takes the same branch by construction.
write_fake_herdr_status "current (v9)" "current (v8)" fail
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "$hi_claude_ok $hi_unchecked" <<< "$hi_out" \
    && grep -Fq "$hi_codex_ok $hi_unchecked $hi_codex_note" <<< "$hi_out" \
    && ! grep -Fq "current per herdr integration status" <<< "$hi_out"; then
    ok "test passed: a failing herdr status (even with output) -> body presence reported with currency explicitly unchecked (no false current)"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: failing herdr status output was adopted or the unchecked state was not reported"
    status=1
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration, status failing)"
  status=1
fi
#     HI-d2) herdr hangs -> doctor must kill it at the deadline, finish, and
#            report the same unchecked state (a stuck herdr must not stall
#            the whole diagnosis). The fake's grandchild sleeps 60s; the run
#            must return well before that AND the grandchild must be dead
#            afterwards (tree reap, not just the wrapper).
write_fake_herdr_status "current (v9)" "current (v8)" hang
rm -f "$hi_fakebin/sleep.pid"
hi_started=$SECONDS
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  hi_elapsed=$((SECONDS - hi_started))
  sleep 0.5
  hi_sleep_pid="$(cat "$hi_fakebin/sleep.pid" 2>/dev/null || true)"
  if (( hi_elapsed < 45 )) \
    && [[ -n "$hi_sleep_pid" ]] && ! kill -0 "$hi_sleep_pid" 2>/dev/null \
    && grep -Fq "$hi_claude_ok $hi_unchecked" <<< "$hi_out" \
    && grep -Fq "$hi_codex_ok $hi_unchecked $hi_codex_note" <<< "$hi_out" \
    && grep -Fq "== agent-tools (report-only) ==" <<< "$hi_out"; then
    ok "test passed: a hung herdr status is killed at the deadline (${hi_elapsed}s) with its grandchild reaped, doctor continues and reports currency unchecked"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: hung herdr status stalled doctor (${hi_elapsed}s), left its grandchild alive (pid ${hi_sleep_pid:-none}), or the unchecked state was not reported"
    status=1
    [[ -n "$hi_sleep_pid" ]] && kill "$hi_sleep_pid" 2>/dev/null || true
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration, status hung)"
  status=1
fi
#     HI-d3) doctor interrupted (SIGTERM) while the probe is running -> its
#            trap must reap the probe tree. The TERM is sent BY THE PROBE
#            ITSELF (fake mode `interrupt`, reading doctor.pid), so it is
#            delivered while the probe is provably running — a test-side
#            timer could otherwise fire after doctor's own 5s deadline had
#            already reaped the probe and pass vacuously (Codex review, PR
#            #226 rounds 3-4). Proven three ways: doctor dies BY the signal
#            (exit 143 via the trap's re-raise), the grandchild is gone, and
#            the captured output shows the herdr section started but never
#            printed a result line (the deadline path would have).
#            doctor.pid is written by the launching shell itself (its $$
#            survives the exec into doctor), so the file exists before
#            doctor runs a single line — no parent-side write can race the
#            probe (Codex review, PR #226 round 5).
rm -f "$hi_fakebin/sleep.pid" "$hi_fakebin/doctor.pid"
write_fake_herdr_status "current (v9)" "current (v8)" interrupt
HOME="$fixture_home" PATH="$hi_fakebin:$PATH" \
  sh -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' _ "$hi_fakebin/doctor.pid" "$hi_root/scripts/doctor.sh" personal \
  > "$hi_fakebin/interrupt.out" 2>&1 &
hi_doctor_pid=$!
if wait "$hi_doctor_pid"; then hi_doctor_rc=0; else hi_doctor_rc=$?; fi
sleep 0.5
hi_sleep_pid="$(cat "$hi_fakebin/sleep.pid" 2>/dev/null || true)"
if [[ "$hi_doctor_rc" == 143 && -n "$hi_sleep_pid" ]] && ! kill -0 "$hi_sleep_pid" 2>/dev/null \
  && grep -Fq "== herdr integration (report-only) ==" "$hi_fakebin/interrupt.out" \
  && ! grep -Fq "herdr-agent-state.sh session; body present" "$hi_fakebin/interrupt.out"; then
  ok "test passed: a doctor interrupted mid-probe dies by SIGTERM (143), reaps the herdr probe tree (grandchild gone) and never reached the section's result lines"
else
  cat "$hi_fakebin/interrupt.out" >&2
  fail "test failed: interrupted doctor did not die by the signal (rc=$hi_doctor_rc), left the probe's grandchild alive (pid ${hi_sleep_pid:-none}), or had already passed the probe"
  status=1
  [[ -n "$hi_sleep_pid" ]] && kill "$hi_sleep_pid" 2>/dev/null || true
fi
#     HI-e) capability off with the settings modules ACTIVE (personal as
#           committed) -> the not-wired ok line labelled as declared state,
#           none of the wired / dangling lines, and herdr's own per-agent
#           view telling that the managed file drops an installer-added
#           registration (it is not herdr-owned there).
set_capability_all "$hi_root" enableHerdrIntegration false
write_fake_herdr_status "current (v9)" "not installed" ok
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "herdr integration not wired by dotfiles (enableHerdrIntegration=false; declared state — live registrations are not probed here)" <<< "$hi_out" \
    && grep -Fq "herdr's own view: claude integration current — managed ~/.claude/settings.json carries no registration while the capability is false; one added by herdr integration install is drift that the next apply removes" <<< "$hi_out" \
    && grep -Fq "herdr's own view: codex integration not installed — managed ~/.codex/hooks.json carries no registration while the capability is false" <<< "$hi_out" \
    && ! grep -Fq "left to herdr integration install" <<< "$hi_out" \
    && ! grep -Fq "enableHerdrIntegration=true" <<< "$hi_out"; then
    ok "test passed: enableHerdrIntegration=false with active settings modules reports not wired (declared) plus herdr's view with managed-file ownership, nothing else"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: enableHerdrIntegration=false (modules active) state not reported cleanly"
    status=1
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration, capability off)"
  status=1
fi
#     HI-f) capability on but the claude-settings module removed -> dangling
#           warn for the Claude home while the Codex home reports normally.
set_capability_all "$hi_root" enableHerdrIntegration true
remove_module_all "$hi_root" claude-settings
write_fake_herdr_status "current (v9)" "current (v8)" ok
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "enableHerdrIntegration=true but the claude-settings module is inactive for this profile; no managed ~/.claude/settings.json carries the hook registration (dangling capability)" <<< "$hi_out" \
    && grep -Fq "$hi_codex_ok and current per herdr integration status" <<< "$hi_out"; then
    ok "test passed: enableHerdrIntegration=true with claude-settings inactive is reported as dangling (Codex side unaffected)"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: dangling enableHerdrIntegration not reported"
    status=1
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration dangling)"
  status=1
fi
#     HI-e2) capability off with BOTH settings modules inactive (a work
#            machine) -> herdr's own view says the unmanaged files are left
#            to herdr integration install for registration and body.
set_capability_all "$hi_root" enableHerdrIntegration false
remove_module_all "$hi_root" codex-settings
write_fake_herdr_status "current (v9)" "current (v8)" ok
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "herdr's own view: claude integration current — ~/.claude/settings.json is unmanaged for this profile, so registration and body are both left to herdr integration install" <<< "$hi_out" \
    && grep -Fq "herdr's own view: codex integration current — ~/.codex/hooks.json is unmanaged for this profile, so registration and body are both left to herdr integration install" <<< "$hi_out" \
    && ! grep -Fq "drift that the next apply removes" <<< "$hi_out"; then
    ok "test passed: enableHerdrIntegration=false with inactive settings modules leaves both files to herdr's installer in the report"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: enableHerdrIntegration=false (modules inactive) ownership not reported"
    status=1
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration, capability off, modules inactive)"
  status=1
fi
rm -rf "$hi_fakebin" "$hi_claude_body" "$hi_codex_body"

# OP) 1Password sign-in probe (#231): `op whoami` runs through the shared
#     bounded_probe, so a signed-out op blocking on the app's unlock prompt
#     cannot stall doctor. PATH-front fake op (same pattern as the fake herdr
#     above). MODE `ok` answers exit 0; `fail` exits 1 (signed out); `hang`
#     forks a `sleep 60` GRANDCHILD (pid in sleep.pid) and waits on it, so
#     the deadline must reap the whole tree; `stdin` exits 0 only when its
#     stdin IS /dev/null (test -ef), proving the probe reads no terminal
#     input even though doctor's own stdin carries a line. Committed
#     personal has allowSecretsAccess=true; doctor stays exit 0 throughout.
op_fakebin="$fixture_home/opfake"
mkdir -p "$op_fakebin"
# write_fake_op MODE
write_fake_op() {
  cat > "$op_fakebin/op" <<SH
#!/bin/sh
[ "\$1" = whoami ] || exit 2
if [ "$1" = hang ]; then sleep 60 & printf '%s\\n' "\$!" > "$op_fakebin/sleep.pid"; wait; fi
if [ "$1" = stdin ]; then [ /dev/fd/0 -ef /dev/null ]; exit; fi
printf 'URL: https://example.1password.com\\n'
[ "$1" = ok ]
SH
  chmod +x "$op_fakebin/op"
}
op_signed_in="[ok] op signed in"
op_signed_out="[warn] op available but not signed in"
op_unchecked="[warn] op sign-in state not checked: op whoami gave no answer within 5s (waiting on an unlock / sign-in prompt, or stuck; the probe was killed) — unlock or sign in to 1Password, then re-run doctor"
#     OP-a) signed in -> ok, and no other verdict on the same run.
write_fake_op ok
if op_out="$(HOME="$fixture_home" PATH="$op_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "$op_signed_in" <<< "$op_out" \
    && ! grep -Fq "$op_signed_out" <<< "$op_out" && ! grep -Fq "$op_unchecked" <<< "$op_out"; then
    ok "test passed: a signed-in op is reported ok"
  else
    printf '%s\n' "$op_out" >&2
    fail "test failed: signed-in op not reported as the single ok line"
    status=1
  fi
else
  printf '%s\n' "$op_out" >&2
  fail "test failed: doctor must stay exit 0 (1Password, op signed in)"
  status=1
fi
#     OP-b) signed out (op whoami answers exit 1) -> the existing warn, not
#           the deadline one.
write_fake_op fail
if op_out="$(HOME="$fixture_home" PATH="$op_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "$op_signed_out" <<< "$op_out" \
    && ! grep -Fq "$op_signed_in" <<< "$op_out" && ! grep -Fq "$op_unchecked" <<< "$op_out"; then
    ok "test passed: a signed-out op is reported as not signed in"
  else
    printf '%s\n' "$op_out" >&2
    fail "test failed: signed-out op not reported as the single not-signed-in line"
    status=1
  fi
else
  printf '%s\n' "$op_out" >&2
  fail "test failed: doctor must stay exit 0 (1Password, op signed out)"
  status=1
fi
#     OP-c) op hangs -> killed at the deadline with its grandchild reaped,
#           the state reported as NOT CHECKED (never as signed in / out),
#           and doctor goes on to the next section. The grandchild sleeps
#           60s; the run must return well before that.
write_fake_op hang
rm -f "$op_fakebin/sleep.pid"
op_started=$SECONDS
if op_out="$(HOME="$fixture_home" PATH="$op_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  op_elapsed=$((SECONDS - op_started))
  sleep 0.5
  op_sleep_pid="$(cat "$op_fakebin/sleep.pid" 2>/dev/null || true)"
  if (( op_elapsed < 45 )) \
    && [[ -n "$op_sleep_pid" ]] && ! kill -0 "$op_sleep_pid" 2>/dev/null \
    && grep -Fxq "$op_unchecked" <<< "$op_out" \
    && ! grep -Fq "$op_signed_in" <<< "$op_out" && ! grep -Fq "$op_signed_out" <<< "$op_out" \
    && grep -Fq "== SSH (1Password agent) ==" <<< "$op_out"; then
    ok "test passed: a hung op whoami is killed at the deadline (${op_elapsed}s) with its grandchild reaped, reported as not checked, and doctor continues"
  else
    printf '%s\n' "$op_out" >&2
    fail "test failed: hung op whoami stalled doctor (${op_elapsed}s), left its grandchild alive (pid ${op_sleep_pid:-none}), or was reported as a definite state"
    status=1
    [[ -n "$op_sleep_pid" ]] && kill "$op_sleep_pid" 2>/dev/null || true
  fi
else
  printf '%s\n' "$op_out" >&2
  fail "test failed: doctor must stay exit 0 (1Password, op hung)"
  status=1
fi
#     OP-d) the probe reads no terminal input: doctor's stdin is a pipe with
#           a line in it, and the fake answers "signed in" only if its own
#           stdin is /dev/null — a probe inheriting doctor's stdin would
#           read as signed out.
write_fake_op stdin
if op_out="$(printf 'typed input\n' | HOME="$fixture_home" PATH="$op_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "$op_signed_in" <<< "$op_out"; then
    ok "test passed: the op probe reads /dev/null, not doctor's stdin"
  else
    printf '%s\n' "$op_out" >&2
    fail "test failed: the op probe did not run with stdin from /dev/null"
    status=1
  fi
else
  printf '%s\n' "$op_out" >&2
  fail "test failed: doctor must stay exit 0 (1Password, stdin isolation)"
  status=1
fi
rm -rf "$op_fakebin"

# ID) Git identity contexts (#202): an existing identity file is checked for
#     completeness, presence-only. Fixture: ~/src/work exists and the work
#     identity file cycles through missing / empty / name-only / email-only /
#     complete / unparsable. The fixture name and email are canaries that
#     must never appear in the output (doctor reports key names only).
#     doctor stays exit 0 throughout.
id_root="$fixture_home/src/work"
id_file="$fixture_home/.config/git/work.gitconfig"
id_canary_email="canary-identity-9f2b@example.invalid"
id_canary_name="Canary Identity Name"
mkdir -p "$id_root" "$fixture_home/.config/git"
# id_check STATE EXPECT_LINE LABEL
id_check() {
  local state="$1" expect="$2" label="$3" out
  case "$state" in
    missing) rm -f "$id_file" ;;
    empty) : > "$id_file" ;;
    name-only) printf '[user]\n\tname = %s\n' "$id_canary_name" > "$id_file" ;;
    email-only) printf '[user]\n\temail = %s\n' "$id_canary_email" > "$id_file" ;;
    complete) printf '[user]\n\tname = %s\n\temail = %s\n' "$id_canary_name" "$id_canary_email" > "$id_file" ;;
    unparsable) printf '[user\n\tname = %s\n' "$id_canary_name" > "$id_file" ;;
    # Explicit EMPTY values (keys present, no value) — distinct from unset
    # keys once the identity reset is missing (#241 review F5).
    empty-values) printf '[user]\n\tname =\n\temail =\n' > "$id_file" ;;
    name-empty-email-unset) printf '[user]\n\tname =\n' > "$id_file" ;;
    # Keys with no `=` at all: git's boolean shorthand. `git config --get`
    # (untyped) prints an empty string with exit 0 for them, exactly like an
    # explicit empty value — but git's identity reader rejects them ("missing
    # value for 'user.email'", fatal; measured on git 2.50.1), so doctor must
    # diagnose them as their own state (#241 review F8 / F9).
    bare-keys) printf '[user]\n\tname\n\temail\n' > "$id_file" ;;
    email-bare) printf '[user]\n\tname = %s\n\temail\n' "$id_canary_name" > "$id_file" ;;
    # A large file with the bare key LAST: a `git config --list | grep -q`
    # pipe would stop reading at the first match and could lose the rest to
    # SIGPIPE under pipefail; doctor must read the whole listing.
    bare-large)
      {
        printf '[user]\n\tname = %s\n' "$id_canary_name"
        awk 'BEGIN { for (i = 1; i <= 20000; i++) printf "[alias]\n\tpadding%d = value%d\n", i, i }'
        printf '[user]\n\temail\n'
      } > "$id_file"
      ;;
  esac
  if out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
    if grep -Fxq "$expect" <<< "$out" \
      && ! grep -Fq "$id_canary_email" <<< "$out" && ! grep -Fq "$id_canary_name" <<< "$out"; then
      ok "test passed: identity file $state -> $label"
    else
      printf '%s\n' "$out" >&2
      fail "test failed: identity file $state: expected the exact line '$expect' and no identity value in the output"
      status=1
    fi
  else
    printf '%s\n' "$out" >&2
    fail "test failed: doctor must stay exit 0 (identity file $state)"
    status=1
  fi
}
# The managed identity reset (#202) is present for these cases: it is what
# makes "identity file missing" mean "commits refused" (its own check is
# ID-r below).
id_reset="$fixture_home/.config/git-profile/identity-reset.gitconfig"
mkdir -p "${id_reset%/*}"
cp "$DOTFILES_ROOT/private_dot_config/git-profile/identity-reset.gitconfig" "$id_reset"
id_check missing "[warn] project root exists but identity file missing: $id_file" "missing-file action (unchanged)"
id_check empty "[warn] identity file is partial: $id_file has no user.name user.email — commits under $id_root get an empty ident (a missing name is refused; a missing email is accepted as <> and shows as no-identity in the prompt)" "partial action naming both keys"
id_check name-only "[warn] identity file is partial: $id_file has no user.email — commits under $id_root get an empty ident (a missing name is refused; a missing email is accepted as <> and shows as no-identity in the prompt)" "partial action naming user.email"
id_check email-only "[warn] identity file is partial: $id_file has no user.name — commits under $id_root get an empty ident (a missing name is refused; a missing email is accepted as <> and shows as no-identity in the prompt)" "partial action naming user.name"
id_check complete "[ok] identity file exists: $id_file" "ok"
id_check unparsable "[warn] identity file exists but git cannot parse it: $id_file (syntax error?) — commits under $id_root fail until it is fixed" "unparsable warn"

# ID-r) The identity reset itself is checked, presence-only (#241): a partial
#     apply (Quickstart with ~/.gitconfig alone) leaves it missing and Git
#     silently skips the include, so the personal fallback leaks into
#     non-personal repos. Present -> ok line; absent -> action naming the
#     apply, and the missing-identity action for a NON-personal context must
#     then say the fallback is in use rather than "refused".
id_check missing "[ok] identity reset file present: $id_reset (non-personal contexts fail closed without a context file)" "reset present -> ok"
rm -f "$id_reset"
id_check missing "[warn] identity reset file missing: $id_reset — the fail-closed boundary of #202 is NOT in place: in a non-personal repo without its context file, a remote matching the personal patterns (hasconfig in ~/.gitconfig) inherits the personal identity instead of refusing to commit (other repos are still refused by useConfigOnly)" "reset absent -> action naming the apply"
id_check missing "[warn] project root exists but identity file missing: $id_file (and the identity reset is missing too: a repo under $id_root whose remote matches the personal patterns inherits the personal identity instead of being refused; other repos are still refused)" "reset absent -> missing-identity action says conditional inheritance"
# Partial files: without the reset an UNSET key keeps the personal identity
# (mixed identity) in a personal-remote repo, but an explicitly EMPTY value
# still overrides it — so the wording depends on which keys are unset.
id_mixed_tail="inherits the personal identity in a repo under $id_root whose remote matches the personal patterns — a mixed identity that is not refused; an explicitly empty key stays empty)"
id_check empty "[warn] identity file is partial: $id_file has no user.name user.email (and the identity reset is missing: the unset user.name user.email $id_mixed_tail" "reset absent -> empty file: both keys unset -> mixed identity"
id_check name-only "[warn] identity file is partial: $id_file has no user.email (and the identity reset is missing: the unset user.email $id_mixed_tail" "reset absent -> name-only: email unset -> mixed identity"
id_check email-only "[warn] identity file is partial: $id_file has no user.name (and the identity reset is missing: the unset user.name $id_mixed_tail" "reset absent -> email-only: name unset -> mixed identity"
id_check empty-values "[warn] identity file is partial: $id_file has no user.name user.email — commits under $id_root get an empty ident (a missing name is refused; a missing email is accepted as <> and shows as no-identity in the prompt)" "reset absent -> explicit empty values still blank the ident (no inheritance)"
# Value-less keys are their own state: git refuses to read the identity at
# all, whatever the reset — the "empty email is accepted as <>" wording would
# be wrong for them.
id_check bare-keys "[warn] identity file has a key without a value: $id_file (user.name user.email) — git rejects the whole identity (fatal: missing value), so commits under $id_root fail until it is fixed" "bare keys (no =) -> own action: git rejects the identity"
id_check email-bare "[warn] identity file has a key without a value: $id_file (user.email) — git rejects the whole identity (fatal: missing value), so commits under $id_root fail until it is fixed" "name set + bare email -> action names user.email only, no value shown"
id_check bare-large "[warn] identity file has a key without a value: $id_file (user.email) — git rejects the whole identity (fatal: missing value), so commits under $id_root fail until it is fixed" "bare key at the end of a 40k-line file is still found (whole listing read)"
# Inheritance and commit outcome are separate: with the name explicitly
# empty the email still inherits, but the commit is refused (empty name).
id_check name-empty-email-unset "[warn] identity file is partial: $id_file has no user.name user.email (and the identity reset is missing: the unset user.email inherits the personal identity in a repo under $id_root whose remote matches the personal patterns — but the commit is still refused because user.name is explicitly empty; an explicitly empty key stays empty)" "reset absent -> empty name + unset email: email inherits, commit still refused"
# The next-actions steps are printf %q-escaped by doctor, so the expected
# lines are built the same way (a TMPDIR with a space would otherwise fail a
# correct output). ORDER is the contract: mkdir must come right before the
# apply within the same action, so the apply step must be a line that
# immediately follows a mkdir line (steps_consecutive). Other actions start
# with the same mkdir step (the global gitignore one, #248), so the pair is
# searched, not the first mkdir match.
# assert_reset_steps HOME_DIR LABEL
assert_reset_steps() {
  local home_dir="$1" label="$2" out rc=0 step_mkdir step_apply
  out="$(HOME="$home_dir" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" || rc=$?
  step_mkdir="        \$ mkdir -p $(printf '%q' "$home_dir/.config")"
  step_apply="        \$ chezmoi apply $(printf '%q' "$home_dir/.config/git-profile") $(printf '%q' "$home_dir/.config/git-profile/identity-reset.gitconfig")"
  if [[ "$rc" -eq 0 ]] \
    && steps_consecutive "$out" "$step_mkdir" "$step_apply"; then
    ok "test passed: reset absent -> $label: doctor exit 0, steps are mkdir then apply, consecutive and %q-escaped"
  else
    printf '%s\n' "$out" >&2
    fail "test failed: reset absent -> $label: expected exit 0 (got $rc) and the mkdir step immediately followed by the apply step"
    status=1
  fi
}
assert_reset_steps "$fixture_home" "next-actions steps"
# The same on a fixture whose path contains a space: %q must make both the
# expectation and the output agree.
id_space_home="$fixture_home/id space home"
mkdir -p "$id_space_home/src/work" "$id_space_home/.config/git"
assert_reset_steps "$id_space_home" "home path with a space"
rm -rf "$id_space_home"
rm -rf "$id_root" "$id_file"

# OC) OpenCode (#234): presence-level report of the third harness. A fake
#     opencode sits at the front of PATH (the real one may or may not be
#     installed); the fixture HOME carries the managed floor or not, and a
#     fake credential store whose provider name and key are canaries that must
#     never be printed. personal lists opencode-settings (floor expected);
#     work does not. doctor stays exit 0 throughout.
oc_fakebin="$fixture_home/opencodefake"
mkdir -p "$oc_fakebin" "$fixture_home/.local/share/opencode"
printf '#!/bin/sh\nexit 0\n' > "$oc_fakebin/opencode"
chmod +x "$oc_fakebin/opencode"
oc_floor="$fixture_home/.config/opencode/opencode.json"
oc_auth="$fixture_home/.local/share/opencode/auth.json"
oc_canary_provider="canary-provider-7d1e"
oc_canary_key="canary-key-4b9c0f"
printf '{"%s":{"type":"api","key":"%s"}}\n' "$oc_canary_provider" "$oc_canary_key" > "$oc_auth"
#     OC-a) personal with the floor MISSING -> action naming the apply
#           targets; the credential store is reported by existence only.
rm -f "$oc_floor"
if oc_out="$(HOME="$fixture_home" PATH="$oc_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[ok] opencode: $oc_fakebin/opencode" <<< "$oc_out" \
    && grep -Fq "[warn] opencode-settings module active but the managed floor is missing: $oc_floor" <<< "$oc_out" \
    && grep -Fxq "[info] - opencode credential store present: $oc_auth (existence only; contents never read)" <<< "$oc_out" \
    && ! grep -Fq "$oc_canary_provider" <<< "$oc_out" && ! grep -Fq "$oc_canary_key" <<< "$oc_out"; then
    ok "test passed: OpenCode floor missing on personal is an action; credential store reported by existence only (canaries absent)"
  else
    printf '%s\n' "$oc_out" >&2
    fail "test failed: OpenCode section (personal, floor missing) did not report as expected or leaked a canary"
    status=1
  fi
else
  printf '%s\n' "$oc_out" >&2
  fail "test failed: doctor must stay exit 0 (OpenCode, floor missing)"
  status=1
fi
#     OC-b) personal with the floor PRESENT -> ok, no action.
mkdir -p "${oc_floor%/*}"
printf '{}\n' > "$oc_floor"
if oc_out="$(HOME="$fixture_home" PATH="$oc_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "[ok] managed permission floor present: $oc_floor (" <<< "$oc_out" \
    && ! grep -Fq "managed floor is missing" <<< "$oc_out"; then
    ok "test passed: OpenCode floor present on personal is ok"
  else
    printf '%s\n' "$oc_out" >&2
    fail "test failed: OpenCode floor present was not reported ok"
    status=1
  fi
else
  printf '%s\n' "$oc_out" >&2
  fail "test failed: doctor must stay exit 0 (OpenCode, floor present)"
  status=1
fi
#     OC-c) work (module inactive), no floor, no credential store -> the
#           floor is declared not managed (no action) and the store absent.
rm -rf "$fixture_home/.config/opencode" "$oc_auth"
if oc_out="$(HOME="$fixture_home" PATH="$oc_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" work 2>&1)"; then
  if grep -Fxq "[ok] OpenCode permission floor not managed for this profile (opencode-settings module inactive)" <<< "$oc_out" \
    && grep -Fxq "[info] - opencode credential store absent: $oc_auth (connect a provider with /connect when needed)" <<< "$oc_out" \
    && ! grep -Fq "managed floor is missing" <<< "$oc_out"; then
    ok "test passed: OpenCode on work is not managed (no action) and the credential store absence is neutral"
  else
    printf '%s\n' "$oc_out" >&2
    fail "test failed: OpenCode section on work did not report as expected"
    status=1
  fi
else
  printf '%s\n' "$oc_out" >&2
  fail "test failed: doctor must stay exit 0 (OpenCode, work)"
  status=1
fi
rm -rf "$oc_fakebin" "$fixture_home/.local/share/opencode"

# CX) Codex review / worker profile files (#264): presence-only report of the
#     agent-tools profile files codex-settings renders. The fixture files hold
#     a canary value that must never be printed (config values stay out of
#     the report). Own fixture copy for the capability flips. CODEX_HOME is
#     unset for every run except the one that sets it. doctor stays exit 0.
cx_root="$fixture_home/.dotfiles-codexprofiles"
copy_repo_fixture "$cx_root"
cx_review="$fixture_home/.codex/agent-tools-review.config.toml"
cx_worker="$fixture_home/.codex/agent-tools-worker.config.toml"
cx_canary="canary-effort-5e2a"
cx_run() {
  env -u CODEX_HOME HOME="$fixture_home" "$@" 2>&1
}
cx_expect() {
  local label="$1" out="$2"
  shift 2
  local line
  for line in "$@"; do
    if ! grep -Fxq -- "$line" <<< "$out"; then
      printf '%s\n' "$out" >&2
      fail "test failed: $label: missing line: $line"
      status=1
      return
    fi
  done
  if grep -Fq "$cx_canary" <<< "$out"; then
    fail "test failed: $label: a profile file value leaked into the report"
    status=1
    return
  fi
  ok "test passed: $label"
}
#     CX-a) committed personal (review=xhigh, worker=high), files missing ->
#           one action per file naming the apply target.
rm -f "$cx_review" "$cx_worker"
if cx_out="$(cx_run "$cx_root/scripts/doctor.sh" personal)"; then
  cx_expect "profile files missing on personal are actions" "$cx_out" \
    "[warn] codexReviewEffort=xhigh but $cx_review is missing — personal-codex-review falls back to the config.toml defaults" \
    "[warn] codexWorkerEffort=high but $cx_worker is missing — personal-codex-worker falls back to the config.toml defaults"
else
  fail "test failed: doctor must stay exit 0 (Codex profiles, missing)"
  status=1
fi
#     CX-b) files present -> ok, contents never printed.
mkdir -p "$fixture_home/.codex"
printf 'model_reasoning_effort = "%s"\n' "$cx_canary" > "$cx_review"
printf 'model_reasoning_effort = "%s"\n' "$cx_canary" > "$cx_worker"
if cx_out="$(cx_run "$cx_root/scripts/doctor.sh" personal)"; then
  cx_expect "profile files present on personal are ok (presence only)" "$cx_out" \
    "[ok] codexReviewEffort=xhigh; $cx_review present (read by personal-codex-review)" \
    "[ok] codexWorkerEffort=high; $cx_worker present (read by personal-codex-worker)"
else
  fail "test failed: doctor must stay exit 0 (Codex profiles, present)"
  status=1
fi
#     CX-c) codex-settings active but the capability off while a file
#           lingers -> action (agent-tools still reads it until apply).
set_capability_all "$cx_root" codexReviewEffort off
rm -f "$cx_worker"
set_capability_all "$cx_root" codexWorkerEffort off
if cx_out="$(cx_run "$cx_root/scripts/doctor.sh" personal)"; then
  cx_expect "capability off with a lingering file is an action; off without a file is ok" "$cx_out" \
    "[warn] codexReviewEffort=off but $cx_review exists — agent-tools still reads it; chezmoi apply removes it (the managed target renders empty)" \
    "[ok] codexWorkerEffort=off; no worker profile file (personal-codex-worker uses the config.toml defaults)"
else
  fail "test failed: doctor must stay exit 0 (Codex profiles, off)"
  status=1
fi
#     CX-d) work (module inactive): a hand-placed file is neutral, a missing
#           one is ok, and a non-off capability is a dangling warning.
set_capability_all "$cx_root" codexWorkerEffort high
if cx_out="$(cx_run "$cx_root/scripts/doctor.sh" work)"; then
  cx_expect "work reports hand-placed / missing files neutrally and a set capability as dangling" "$cx_out" \
    "[info] - $cx_review present but not managed for this profile (hand-placed, or left by another profile — see managed-path orphans); agent-tools reads it whenever it exists" \
    "[warn] codexWorkerEffort=high but the codex-settings module is inactive for this profile; nothing renders $cx_worker (dangling capability)" \
    "[ok] no worker profile file (not managed for this profile; personal-codex-worker uses the config.toml defaults)"
else
  fail "test failed: doctor must stay exit 0 (Codex profiles, work)"
  status=1
fi
#     CX-e) a CODEX_HOME that is not ~/.codex is flagged: agent-tools would
#           look there, chezmoi renders into ~/.codex. The default spelled
#           with a trailing slash is not flagged.
if cx_out="$(HOME="$fixture_home" CODEX_HOME="$fixture_home/elsewhere" "$cx_root/scripts/doctor.sh" personal 2>&1)" \
  && cx_default="$(HOME="$fixture_home" CODEX_HOME="$fixture_home/.codex/" "$cx_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[warn] CODEX_HOME is set to $fixture_home/elsewhere: agent-tools reads the review / worker profile files from there, but chezmoi renders them into ~/.codex" <<< "$cx_out" \
    && ! grep -Fq "CODEX_HOME is set to" <<< "$cx_default"; then
    ok "test passed: a diverging CODEX_HOME is flagged; the default (trailing slash) is not"
  else
    printf '%s\n' "$cx_out" >&2
    fail "test failed: CODEX_HOME divergence not reported as expected"
    status=1
  fi
else
  fail "test failed: doctor must stay exit 0 (Codex profiles, CODEX_HOME)"
  status=1
fi
rm -f "$cx_review" "$cx_worker"

# HL) git hook gates wiring that lingers while enableGitHookGates=false (#258).
#     `chezmoi apply` prunes it only where the git-hook-gates module is active
#     (template self-gate); on a profile that does not list the module (work,
#     e.g. after a personal -> work switch, #201) apply never touches it, so
#     doctor must say so and name the files instead of "run chezmoi apply".
#     Own HOME (git reads the global config from it) and own fixture copy for
#     the personal capability flip; git's config-selecting env is cleared.
hl_root="$fixture_home/.dotfiles-hooklinger"
copy_repo_fixture "$hl_root"
set_capability_all "$hl_root" enableGitHookGates false
hl_home="$fixture_home/hl-home"
hl_dir="$hl_home/.config/git-hook-gates"
hl_run() {
  env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u XDG_CONFIG_HOME GIT_CONFIG_NOSYSTEM=1 \
    HOME="$hl_home" "$hl_root/scripts/doctor.sh" "$1" 2>&1
}
hl_apply_msg="[warn] enableGitHookGates=false but gate wiring lingers (shim and/or core.hooksPath still present) — run chezmoi apply to prune it"
hl_foreign_msg="[warn] enableGitHookGates=false but gate wiring lingers (shim and/or core.hooksPath still present), left by another profile — this profile does not manage ~/.config/git-hook-gates, so chezmoi apply will NOT remove it (#201); remove it by hand"
#     HL-a) personal (module active), capability flipped off, a shim left
#           behind -> apply prunes it, so the apply action stands.
mkdir -p "$hl_dir/hooks"
printf '#!/bin/sh\n# Managed by chezmoi from kosako/dotfiles (git-hook-gates, #196).\n' > "$hl_dir/hooks/pre-commit"
if hl_out="$(hl_run personal)"; then
  if grep -Fxq "$hl_apply_msg" <<< "$hl_out" && ! grep -Fq "will NOT remove it" <<< "$hl_out"; then
    ok "test passed: lingering shim on a module-active profile keeps the chezmoi apply action"
  else
    printf '%s\n' "$hl_out" >&2
    fail "test failed: lingering shim on personal (module active) not reported with the apply action"
    status=1
  fi
else
  fail "test failed: doctor must stay exit 0 (hook gates lingering, personal)"
  status=1
fi
#     HL-b) work (module inactive) with the full managed wiring left by
#           personal: shims + hooks.gitconfig included from ~/.gitconfig, so
#           core.hooksPath is live -> hand removal of exactly the files that
#           exist, plus a confirmation step; never the apply action.
printf '#!/bin/sh\n' > "$hl_dir/hooks/commit-msg"
printf '[core]\n\thooksPath = ~/.config/git-hook-gates/hooks\n' > "$hl_dir/hooks.gitconfig"
printf '[include]\n\tpath = ~/.config/git-hook-gates/hooks.gitconfig\n' > "$hl_home/.gitconfig"
hl_rm_step="\$ rm -i $(printf '%q' "$hl_dir/hooks.gitconfig") $(printf '%q' "$hl_dir/hooks/pre-commit") $(printf '%q' "$hl_dir/hooks/commit-msg")"
hl_verify_step="\$ git config --global --includes --show-origin --get core.hooksPath   # must no longer point at ~/.config/git-hook-gates/hooks; if it still does, remove that line at the origin shown"
if hl_out="$(hl_run work)"; then
  if grep -Fxq "$hl_foreign_msg" <<< "$hl_out" && ! grep -Fq "$hl_apply_msg" <<< "$hl_out" \
    && grep -Fq -- "$hl_rm_step" <<< "$hl_out" && grep -Fq -- "$hl_verify_step" <<< "$hl_out"; then
    ok "test passed: lingering wiring on work (module inactive) names the files to remove, not apply"
  else
    printf '%s\n' "$hl_out" >&2
    fail "test failed: lingering wiring on work was not reported as hand removal of the existing files"
    status=1
  fi
else
  fail "test failed: doctor must stay exit 0 (hook gates lingering, work)"
  status=1
fi
#     HL-e) work with the shims left but no hooks.gitconfig, while another
#           origin (here ~/.gitconfig directly) still points core.hooksPath at
#           the shim directory: rm lists only the shims, and the verification
#           step is what catches the setting that rm does not remove.
rm -f "$hl_dir/hooks.gitconfig"
printf '[core]\n\thooksPath = ~/.config/git-hook-gates/hooks\n' > "$hl_home/.gitconfig"
hl_rm_shims="\$ rm -i $(printf '%q' "$hl_dir/hooks/pre-commit") $(printf '%q' "$hl_dir/hooks/commit-msg")"
if hl_out="$(hl_run work)"; then
  if grep -Fxq "$hl_foreign_msg" <<< "$hl_out" \
    && grep -Fq -- "$hl_rm_shims" <<< "$hl_out" && ! grep -Fq "hooks.gitconfig" <<< "$(grep -F -- "\$ rm -i" <<< "$hl_out")" \
    && grep -Fq -- "$hl_verify_step" <<< "$hl_out"; then
    ok "test passed: shims without hooks.gitconfig list only the shims and keep the hooksPath verification step"
  else
    printf '%s\n' "$hl_out" >&2
    fail "test failed: shims left with hooksPath set elsewhere were not reported as expected"
    status=1
  fi
else
  fail "test failed: doctor must stay exit 0 (hook gates shims + stray hooksPath, work)"
  status=1
fi
#     HL-c) work with only core.hooksPath set directly in ~/.gitconfig (no
#           managed file left) -> point at the setting, not at rm or apply.
rm -rf "$hl_dir"
printf '[core]\n\thooksPath = ~/.config/git-hook-gates/hooks\n' > "$hl_home/.gitconfig"
if hl_out="$(hl_run work)"; then
  if grep -Fxq "[warn] enableGitHookGates=false but global core.hooksPath still points at the managed shim directory, set outside the managed include — this profile does not manage ~/.config/git-hook-gates, so chezmoi apply will NOT change it (#201)" <<< "$hl_out" \
    && ! grep -Fq "\$ rm -i" <<< "$hl_out"; then
    ok "test passed: a hooksPath set outside the managed include is reported by its setting"
  else
    printf '%s\n' "$hl_out" >&2
    fail "test failed: stray core.hooksPath on work was not reported as expected"
    status=1
  fi
else
  fail "test failed: doctor must stay exit 0 (hook gates stray hooksPath, work)"
  status=1
fi
#     HL-d) work with nothing left -> not wired, no action.
rm -f "$hl_home/.gitconfig"
if hl_out="$(hl_run work)"; then
  if grep -Fxq "[ok] git hook gates not wired (enableGitHookGates=false)" <<< "$hl_out" \
    && ! grep -Fq "gate wiring lingers" <<< "$hl_out"; then
    ok "test passed: nothing left on work reports not wired"
  else
    printf '%s\n' "$hl_out" >&2
    fail "test failed: clean work home not reported as not wired"
    status=1
  fi
else
  fail "test failed: doctor must stay exit 0 (hook gates clean, work)"
  status=1
fi
rm -rf "$hl_home"

# GS) Git section (#307): user.useConfigOnly / transfer.credentialsInUrl come
#     from the global config and are warned while not set, and the remote URL
#     scan walks every documented root under ~/src: a repo with credential-like
#     userinfo in each of personal / work / client / sandbox / agent is
#     flagged, its URL (a canary) never shown. Hermetic (env -i, own HOME, no
#     system git config).
gs_home="$fixture_home/gs-home"
gs_canary="canary-remote-userinfo-307"
rm -rf "$gs_home"
mkdir -p "$gs_home"
: > "$gs_home/.gitconfig"
for gs_root in personal work client sandbox agent; do
  env -i PATH="$PATH" HOME="$gs_home" GIT_CONFIG_NOSYSTEM=1 \
    git init -q --template= "$gs_home/src/$gs_root/repo"
  env -i PATH="$PATH" HOME="$gs_home" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$gs_home/src/$gs_root/repo" remote add origin "https://user:$gs_canary@example.invalid/x.git"
done
if gs_out="$(env -i PATH="$PATH" HOME="$gs_home" GIT_CONFIG_NOSYSTEM=1 "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  gs_missing=""
  for gs_line in "[warn] user.useConfigOnly is not true" "[warn] transfer.credentialsInUrl is not die"; do
    grep -Fxq -- "$gs_line" <<< "$gs_out" || gs_missing="$gs_missing$gs_line"$'\n'
  done
  for gs_root in personal work client sandbox agent; do
    gs_line="[warn] credential-like userinfo in remote URL: repo=$gs_home/src/$gs_root/repo remote=origin (URL not shown)"
    grep -Fxq -- "$gs_line" <<< "$gs_out" || gs_missing="$gs_missing$gs_line"$'\n'
  done
  if [[ -z "$gs_missing" ]] && ! grep -Fq "$gs_canary" <<< "$gs_out"; then
    ok "test passed: Git section warns on the two unset keys and flags a credential remote under every ~/src root without showing the URL"
  else
    printf '%s\n%s' "$gs_out" "$gs_missing" >&2
    fail "test failed: Git section / remote URL scan"
    status=1
  fi
else
  fail "test failed: doctor must stay exit 0 (Git section)"
  status=1
fi
printf '[user]\n\tuseConfigOnly = true\n[transfer]\n\tcredentialsInUrl = die\n' > "$gs_home/.gitconfig"
if gs_out="$(env -i PATH="$PATH" HOME="$gs_home" GIT_CONFIG_NOSYSTEM=1 "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && grep -Fxq "[ok] user.useConfigOnly=true" <<< "$gs_out" \
  && grep -Fxq "[ok] transfer.credentialsInUrl=die" <<< "$gs_out"; then
  ok "test passed: Git section reports both keys ok once the global config sets them"
else
  printf '%s\n' "${gs_out:-<no output>}" >&2
  fail "test failed: Git section must report both keys ok when set"
  status=1
fi
rm -rf "$gs_home"

# HG) git hook gates readiness on a module-active profile (#307): the
#     observer side of the two-key gate. Each case plants the agent-tools
#     deploy (all four scripts, a subset, or one not executable) and the
#     wiring (both shims + core.hooksPath at the managed shim directory, or
#     nothing) in an own HOME and pins doctor's exact readiness lines — a
#     deploy list cut short in doctor.sh (e.g. the dispatcher alone) would
#     report a partial deploy as complete and fail here. Hermetic (env -i).
hg_home="$fixture_home/hg-home"
hg_deploy="$hg_home/.claude/agent-tools/scripts"
hg_shims="$hg_home/.config/git-hook-gates/hooks"
hg_all=(personal-git-hook-dispatcher personal-public-safety-gate personal-git-identity-gate personal-ai-trailer-gate)
# hg_setup WIRED SCRIPT... — a fresh HOME; WIRED=1 plants both shims and
# core.hooksPath; each SCRIPT is planted executable.
hg_setup() {
  local wired="$1" hg_script
  shift
  rm -rf "$hg_home"
  mkdir -p "$hg_deploy"
  for hg_script in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "$hg_deploy/$hg_script"
    chmod +x "$hg_deploy/$hg_script"
  done
  if [[ "$wired" -eq 1 ]]; then
    mkdir -p "$hg_shims"
    for hg_script in pre-commit commit-msg; do
      printf '#!/bin/sh\nexit 0\n' > "$hg_shims/$hg_script"
      chmod +x "$hg_shims/$hg_script"
    done
    printf '[core]\n\thooksPath = ~/.config/git-hook-gates/hooks\n' > "$hg_home/.gitconfig"
  fi
}
# hg_expect LABEL -- EXPECT_LINE... [! ABSENT_SUBSTRING...]
hg_expect() {
  local label="$1" want=() absent=() mode=want arg missing="" out
  shift 2
  for arg in "$@"; do
    case "$mode:$arg" in
      want:!) mode=absent ;;
      want:*) want+=("$arg") ;;
      absent:*) absent+=("$arg") ;;
    esac
  done
  if ! out="$(env -i PATH="$PATH" HOME="$hg_home" GIT_CONFIG_NOSYSTEM=1 "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
    printf '%s\n' "$out" >&2
    fail "test failed: doctor must stay exit 0 (hook gates readiness $label)"
    status=1
    return
  fi
  for arg in "${want[@]}"; do
    grep -Fxq -- "$arg" <<< "$out" || missing="${missing}expected line: $arg"$'\n'
  done
  for arg in "${absent[@]:-}"; do
    [[ -z "$arg" ]] && continue
    if grep -Fq -- "$arg" <<< "$out"; then missing="${missing}unexpected: $arg"$'\n'; fi
  done
  if [[ -z "$missing" ]]; then
    ok "test passed: hook gates readiness $label"
  else
    printf '%s\n%s' "$out" "$missing" >&2
    fail "test failed: hook gates readiness $label"
    status=1
  fi
}
hg_complete="[ok] agent-tools deploy complete: dispatcher + all three gates executable in $hg_deploy (bodies owned by agent-tools sync)"
hg_wired_incomplete="[warn] agent-tools deploy INCOMPLETE while the hooks are wired: git commit is BLOCKED fail-closed until agent-tools sync restores the dispatcher and all three gates in $hg_deploy — or set enableGitHookGates=false and apply"
hg_both_incomplete="[warn] agent-tools deploy incomplete (dispatcher and/or a gate missing in $hg_deploy; agent-tools sync deploys them) and the wiring is also incomplete — commit behavior may be stage-dependent or blocked until sync and apply both complete"
# HG-1) wired + all four deployed -> both shims ok, hooksPath ok, deploy complete.
hg_setup 1 "${hg_all[@]}"
hg_expect "wired + complete deploy -> all ok" -- \
  "[ok] shim present and executable: $hg_shims/pre-commit" \
  "[ok] shim present and executable: $hg_shims/commit-msg" \
  "[ok] global core.hooksPath -> managed shim directory" \
  "$hg_complete" ! "deploy INCOMPLETE" "deploy incomplete ("
# HG-2) wired + the pre-#281 deploy (identity gate missing) -> commits blocked.
hg_setup 1 personal-git-hook-dispatcher personal-public-safety-gate personal-ai-trailer-gate
hg_expect "wired + pre-#281 deploy (identity gate missing) -> BLOCKED warning" -- \
  "$hg_wired_incomplete" ! "$hg_complete"
# HG-3) wired + all four present but one gate not executable -> the same.
hg_setup 1 "${hg_all[@]}"
chmod 644 "$hg_deploy/personal-public-safety-gate"
hg_expect "wired + a non-executable gate -> BLOCKED warning" -- \
  "$hg_wired_incomplete" ! "$hg_complete"
# HG-4) nothing wired + the dispatcher alone -> both halves incomplete.
hg_setup 0 personal-git-hook-dispatcher
hg_expect "not wired + dispatcher only -> deploy and wiring both incomplete" -- \
  "[warn] shim missing or not executable: $hg_shims/pre-commit (chezmoi apply arms it once the agent-tools deploy is complete)" \
  "[warn] global core.hooksPath is not set (chezmoi apply arms it via the ~/.gitconfig include once the agent-tools deploy is complete)" \
  "$hg_both_incomplete" ! "$hg_complete"
rm -rf "$hg_home"

# OP) OpenCode plugins, OPENCODE_CONFIG and herdr's OpenCode view (#263).
#     Static checks only: doctor must never run OpenCode (even `opencode
#     debug config` writes its database), so a PATH-front fake opencode
#     records any invocation and every case asserts it stayed unused. Config
#     files carry a canary "secret" (an MCP header) that must never reach the
#     report. A fake herdr answers `integration status`. Own HOME;
#     OPENCODE_CONFIG is unset unless a case sets it. doctor stays exit 0.
#     XDG_DATA_HOME too (the init marker's log, OP-i).
op_home="$fixture_home/op-home"
op_fakebin="$fixture_home/opfake"
op_cfg="$op_home/.config/opencode"
op_ran="$fixture_home/op-ran"
op_canary="canary-mcp-header-3e8b"
mkdir -p "$op_fakebin" "$op_cfg/plugins"
cat > "$op_fakebin/opencode" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$op_ran"
exit 0
SH
cat > "$op_fakebin/herdr" <<'SH'
#!/bin/sh
[ "$1" = integration ] && [ "$2" = status ] || exit 2
printf '%s\n' "claude: not installed (x)" "codex: not installed (y)" "opencode: not installed (z)"
SH
chmod +x "$op_fakebin/opencode" "$op_fakebin/herdr"
printf '// personal-agent-tools\n' > "$op_cfg/plugins/personal-agent-tools.js"
op_run() {
  env -u OPENCODE_CONFIG -u XDG_DATA_HOME HOME="$op_home" PATH="$op_fakebin:$PATH" "$@" "$SCRIPT_DIR/doctor.sh" personal 2>&1
}
op_expect() {
  local label="$1" out="$2"
  shift 2
  local line
  for line in "$@"; do
    if ! grep -Fq -- "$line" <<< "$out"; then
      printf '%s\n' "$out" >&2
      fail "test failed: $label: missing: $line"
      status=1
      return
    fi
  done
  if grep -Fq "$op_canary" <<< "$out"; then
    fail "test failed: $label: an OpenCode config value leaked into the report"
    status=1
    return
  fi
  if [[ -e "$op_ran" ]]; then
    fail "test failed: $label: doctor ran opencode ($(head -n 1 "$op_ran")) — it must stay static"
    status=1
    rm -f "$op_ran"
    return
  fi
  ok "test passed: $label"
}
op_ok_line="[ok] agent-tools plugin personal-agent-tools.js in the global plugins dir (OpenCode loads it at startup; its init is reported below)"
#     OP-a) plugin in the global plugins dir, no config lists it -> ok with
#           the honest-label; OpenCode never runs.
if op_out="$(op_run)"; then
  op_expect "the agent-tools plugin in the global plugins dir is ok (static, OpenCode not run)" "$op_out" "$op_ok_line"
else
  fail "test failed: doctor must stay exit 0 (OpenCode plugin present)"
  status=1
fi
#     OP-b) the same plugin also listed in a config's plugin key -> double
#           load warning; the config's other values never show.
printf '{"mcp":{"x":{"headers":{"Authorization":"%s"}}},"plugin":["file:///elsewhere/personal-agent-tools.js","some-npm-plugin@1"]}\n' "$op_canary" > "$op_cfg/opencode.local.json"
if op_out="$(op_run OPENCODE_CONFIG="$op_cfg/opencode.local.json")"; then
  op_expect "a plugin also listed in the active config's plugin key is a double-load warning" "$op_out" \
    "[warn] agent-tools plugin personal-agent-tools is also listed in an OpenCode config's plugin key — OpenCode loads it twice"
else
  fail "test failed: doctor must stay exit 0 (OpenCode plugin listed in config)"
  status=1
fi
#     OP-b2) the same listing in opencode.local.json while OPENCODE_CONFIG does
#            not point at it: OpenCode does not read that file here, so it is
#            a note, never a double-load warning.
if op_out="$(op_run)"; then
  op_expect "a listing in an opencode.local.json that is not read here is only a note" "$op_out" \
    "$op_ok_line" \
    "[info] - personal-agent-tools is also listed in opencode.local.json's plugin key, which OpenCode reads only when OPENCODE_CONFIG points at it"
  if grep -Fq "loads it twice" <<< "$op_out"; then
    fail "test failed: an inactive opencode.local.json listing was reported as a double load"
    status=1
  fi
else
  fail "test failed: doctor must stay exit 0 (OpenCode inactive local listing)"
  status=1
fi
#     OP-c) names are compared literally, not as regexes: personal-a.b.js
#           on disk does not match personal-a-b.js in the config.
printf '//\n' > "$op_cfg/plugins/personal-a.b.js"
printf '{"plugin":["personal-a-b.js"]}\n' > "$op_cfg/opencode.local.json"
if op_out="$(op_run OPENCODE_CONFIG="$op_cfg/opencode.local.json")"; then
  op_expect "plugin names are matched literally (no regex false positive)" "$op_out" \
    "[ok] agent-tools plugin personal-a.b.js in the global plugins dir"
  if grep -Fq "personal-a.b is also listed" <<< "$op_out"; then
    fail "test failed: personal-a.b.js was matched against personal-a-b.js"
    status=1
  fi
else
  fail "test failed: doctor must stay exit 0 (OpenCode literal names)"
  status=1
fi
rm -f "$op_cfg/plugins/personal-a.b.js"
#     OP-d) a config that is not JSON -> that check is reported as not done,
#           never guessed, never printed.
printf '{ "mcp": "%s", broken\n' "$op_canary" > "$op_cfg/opencode.local.json"
if op_out="$(op_run)"; then
  op_expect "an unreadable config reports the double-load check as not done" "$op_out" \
    "[info] - the plugin key of $op_cfg/opencode.local.json could not be read (not JSON?); double loading via config not checked (contents never shown)" \
    "$op_ok_line"
else
  fail "test failed: doctor must stay exit 0 (OpenCode unreadable config)"
  status=1
fi
#     OP-d2) the same broken file as the ACTIVE config (OPENCODE_CONFIG points
#            at it) -> the active branch also reports "not checked".
if op_out="$(op_run OPENCODE_CONFIG="$op_cfg/opencode.local.json")"; then
  op_expect "an unreadable active config reports the double-load check as not done" "$op_out" \
    "[info] - the plugin key of $op_cfg/opencode.local.json could not be read (not JSON?); double loading via config not checked (contents never shown)" \
    "$op_ok_line"
else
  fail "test failed: doctor must stay exit 0 (OpenCode unreadable active config)"
  status=1
fi
rm -f "$op_cfg/opencode.local.json"
#     OP-e) no agent-tools plugin -> neutral item.
mv "$op_cfg/plugins/personal-agent-tools.js" "$op_cfg/personal-agent-tools.js.off"
if op_out="$(op_run)"; then
  op_expect "no agent-tools plugin is neutral" "$op_out" \
    "[info] - no agent-tools plugin in ~/.config/opencode/plugins (agent-tools sync deploys personal-*.js there)"
else
  fail "test failed: doctor must stay exit 0 (OpenCode no plugin)"
  status=1
fi
mv "$op_cfg/personal-agent-tools.js.off" "$op_cfg/plugins/personal-agent-tools.js"
#     OP-f) extra copies that OpenCode may load twice (.ts next to .js,
#           singular plugin/ dir) -> one warning each.
mkdir -p "$op_cfg/plugin"
printf '//\n' > "$op_cfg/plugins/personal-agent-tools.ts"
printf '//\n' > "$op_cfg/plugin/personal-agent-tools.js"
if op_out="$(op_run)"; then
  op_expect "extra plugin copies are warned" "$op_out" \
    "[warn] agent-tools plugin copy that OpenCode may load twice: $op_cfg/plugins/personal-agent-tools.ts" \
    "[warn] agent-tools plugin copy that OpenCode may load twice: $op_cfg/plugin/personal-agent-tools.js"
else
  fail "test failed: doctor must stay exit 0 (OpenCode extra copies)"
  status=1
fi
rm -rf "$op_cfg/plugin" "$op_cfg/plugins/personal-agent-tools.ts"
#     OP-g) OPENCODE_CONFIG against a present opencode.local.json.
printf '{}\n' > "$op_cfg/opencode.local.json"
if op_out="$(op_run)"; then
  op_expect "local config present but OPENCODE_CONFIG unset (no export anywhere) is an action" "$op_out" \
    "[warn] opencode.local.json exists but OPENCODE_CONFIG is not set — OpenCode ignores the local provider / model / mcp config"
else
  fail "test failed: doctor must stay exit 0 (OPENCODE_CONFIG unset)"
  status=1
fi
printf 'export OPENCODE_CONFIG="$HOME/.config/opencode/opencode.local.json"\n' > "$op_home/.zshrc.local"
if op_out="$(op_run)"; then
  op_expect "an export in ~/.zshrc.local that this shell did not load is neutral" "$op_out" \
    "[info] - OPENCODE_CONFIG is exported in ~/.zshrc.local but not set in this shell"
else
  fail "test failed: doctor must stay exit 0 (OPENCODE_CONFIG exported elsewhere)"
  status=1
fi
if op_out="$(op_run OPENCODE_CONFIG="$op_cfg/opencode.local.json")"; then
  op_expect "OPENCODE_CONFIG pointing at opencode.local.json is ok" "$op_out" \
    "[ok] OPENCODE_CONFIG -> opencode.local.json (local provider / model / mcp config is read)"
else
  fail "test failed: doctor must stay exit 0 (OPENCODE_CONFIG ok)"
  status=1
fi
printf '{}\n' > "$op_home/other.json"
if op_out="$(op_run OPENCODE_CONFIG="$op_home/other.json")"; then
  op_expect "OPENCODE_CONFIG pointing elsewhere is warned" "$op_out" \
    "[warn] OPENCODE_CONFIG points to a different file than opencode.local.json — that local config is not read"
else
  fail "test failed: doctor must stay exit 0 (OPENCODE_CONFIG elsewhere)"
  status=1
fi
if op_out="$(op_run OPENCODE_CONFIG="$op_home/missing.json")"; then
  op_expect "OPENCODE_CONFIG pointing at a missing file is warned" "$op_out" \
    "[warn] OPENCODE_CONFIG points to a file that does not exist — OpenCode reads no local config"
else
  fail "test failed: doctor must stay exit 0 (OPENCODE_CONFIG missing file)"
  status=1
fi
#     OP-h) herdr's view of its OpenCode integration is shown neutrally
#           (installing it is the user's call; never an action).
if op_out="$(op_run)"; then
  op_expect "herdr's OpenCode integration state is shown as herdr's view" "$op_out" \
    "[info] - herdr's own view: opencode integration not installed"
  if grep -Fq "\$ herdr integration install opencode" <<< "$op_out"; then
    fail "test failed: herdr's OpenCode integration must not become an action"
    status=1
  fi
else
  fail "test failed: doctor must stay exit 0 (herdr OpenCode view)"
  status=1
fi
#     OP-i) the init marker of personal-agent-tools (#311, agent-tools#343):
#           doctor reads OpenCode's existing log (never runs OpenCode) and
#           calls the init confirmed only when the newest marker line's
#           build_id equals the deployed file's marker; everything else is a
#           neutral "not confirmed" with a reason. Log lines carry the canary
#           in other fields and messages, so a line printed into the report
#           fails op_expect. Exactly one init line per run.
op_log="$op_home/.local/share/opencode/log/opencode.log"
op_hex_a="$(printf '%064d' 0 | tr 0 a)"
op_hex_b="$(printf '%064d' 0 | tr 0 b)"
op_init="agent-tools plugin personal-agent-tools init"
op_deployed="deployed build_id sha256:$op_hex_a"
op_confirmed="[ok] $op_init confirmed by OpenCode's log (build_id sha256:$op_hex_a: some start of this build got through init, not necessarily the latest)"
op_no_marker="[info] - $op_init not confirmed: no init marker in OpenCode's log (not started since the plugin began logging it, started with --pure or a log level above INFO, a rotated log, or an init that threw; $op_deployed)"
op_not_v1="[info] - $op_init not confirmed: the newest init marker is not in the v=1 form this doctor reads ($op_deployed)"
op_no_log="[info] - $op_init not confirmed: no OpenCode log yet (not started here; $op_deployed)"
# op_line MESSAGE [quoted|bare] — one OpenCode 1.18.30 log line around MESSAGE.
op_line() {
  if [[ "${2:-quoted}" == quoted ]]; then
    printf 'timestamp=2026-10-05T00:00:00.000Z level=INFO run=%s message="%s"\n' "$op_canary" "$1"
  else
    printf 'timestamp=2026-10-05T00:00:00.000Z level=INFO run=%s message=%s\n' "$op_canary" "$1"
  fi
}
op_marker() {
  printf 'agent-tools:plugin-init v=1 name=personal-agent-tools build_id=%s' "$1"
}
# op_log_write LINE... — the log's whole content: an unrelated line first.
op_log_write() {
  mkdir -p "$(dirname "$op_log")"
  { op_line "service=x $op_canary unrelated"; printf '%s\n' "$@"; } > "$op_log"
}
# op_init_case LABEL EXPECTED_LINE [VAR=value...] — one run: EXPECTED_LINE is
# the one and only init line, nothing leaks, OpenCode stays unrun.
op_init_case() {
  local label="$1" expected="$2" out
  shift 2
  if ! out="$(op_run "$@")"; then
    fail "test failed: doctor must stay exit 0 (OpenCode init: $label)"
    status=1
    return
  fi
  op_init_check "$label" "$expected" "$out"
}
# op_init_check LABEL EXPECTED_LINE OUTPUT — the checks of op_init_case on a
# doctor output already in hand.
op_init_check() {
  local label="$1" expected="$2" out="$3" count
  count="$(grep -c -F -- "$op_init" <<< "$out" || true)"
  if ! grep -Fxq -- "$expected" <<< "$out" || [[ "$count" != 1 ]]; then
    printf '%s\n' "$out" | grep -F -- "$op_init" >&2 || true
    fail "test failed: OpenCode init: $label (expected exactly: $expected)"
    status=1
    return
  fi
  op_expect "OpenCode init: $label" "$out" "$expected"
}
#     OP-i1) line 1 is not agent-tools' marker for this plugin -> no build_id
#            to compare: no marker (the fixture so far), a plain comment that
#            merely carries a build_id, another plugin's marker, a marker for
#            another target (Codex review R1, PR #325). A matching log line is
#            in place, so a lax marker check would turn into "confirmed".
op_not_marker="[info] - $op_init not confirmed: the deployed file's line 1 is not agent-tools' marker for this plugin with a sha256 build_id (agent-tools' doctor checks its marker)"
op_plugin_file() {
  printf '%s\n// personal-agent-tools\n' "$1" > "$op_cfg/plugins/personal-agent-tools.js"
}
op_marker_line() {
  printf '/* agent-tools:managed v=1 repo=agent-tools name=%s target=%s artifact_kind=plugin source=shared/plugins/personal-agent-tools.js build_id=sha256:%s */' "$1" "$2" "$op_hex_a"
}
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")"
op_init_case "deployed file without a marker -> not confirmed" "$op_not_marker"
op_plugin_file "// build_id=sha256:$op_hex_a"
op_init_case "a plain comment carrying a build_id is no marker -> not confirmed" "$op_not_marker"
op_plugin_file "$(op_marker_line personal-other opencode)"
op_init_case "another plugin's marker -> not confirmed" "$op_not_marker"
op_plugin_file "$(op_marker_line personal-agent-tools claude-code)"
op_init_case "a marker for another target -> not confirmed" "$op_not_marker"
op_plugin_file "$(op_marker_line personal-agent-tools opencode)"
rm -rf "$op_home/.local/share/opencode"
#     OP-i2) no log at all -> not started.
op_init_case "no OpenCode log -> not confirmed (not started)" "$op_no_log"
#     OP-i3) a log without the marker.
op_log_write
op_init_case "log without the marker -> not confirmed" "$op_no_marker"
#     OP-i4) the newest marker matches, quoted (as 1.18.30 writes it) or bare.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")"
op_init_case "quoted marker with the deployed build_id -> confirmed" "$op_confirmed"
# A message with spaces is always quoted in OpenCode's key=value line, so an
# unquoted one is not the plugin's marker line.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")" bare)"
op_init_case "unquoted marker text -> no marker" "$op_no_marker"
#     OP-i5) only the newest marker counts, whichever way round.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" "$(op_line "$(op_marker "sha256:$op_hex_b")")"
op_init_case "newest marker from another build -> not confirmed, naming both" \
  "[info] - $op_init not confirmed: the newest init marker is from build_id sha256:$op_hex_b, not the deployed sha256:$op_hex_a (OpenCode not started since the last sync, or a process still on the old build)"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_b")")" "$(op_line "$(op_marker "sha256:$op_hex_a")")"
op_init_case "an older marker from another build, newest matches -> confirmed" "$op_confirmed"
#     OP-i6) build_id unknown.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" "$(op_line "$(op_marker unknown)")"
op_init_case "newest marker with build_id unknown -> not confirmed" \
  "[info] - $op_init not confirmed: the newest init marker carries build_id unknown (the plugin could not read its own marker; $op_deployed)"
#     OP-i7) lines outside the v=1 form, each newest after a matching one: a
#            newer version, an extra token, 65 hex digits, uppercase hex.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" \
  "$(op_line "agent-tools:plugin-init v=2 name=personal-agent-tools build_id=sha256:$op_hex_a")"
op_init_case "newest marker in v=2 -> not confirmed" "$op_not_v1"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" "$(op_line "$(op_marker "sha256:$op_hex_a") extra")"
op_init_case "newest marker with an extra token -> not confirmed" "$op_not_v1"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" "$(op_line "$(op_marker "sha256:${op_hex_a}a")")"
op_init_case "newest marker with 65 hex digits -> not confirmed" "$op_not_v1"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" "$(op_line "$(op_marker "sha256:$(printf '%064d' 0 | tr 0 A)")")"
op_init_case "newest marker with uppercase hex -> not confirmed" "$op_not_v1"
#     OP-i8) marker text that does not open the message, or names another
#            plugin, is no marker at all.
op_log_write "$(op_line "grep $(op_marker "sha256:$op_hex_a")")" \
  "$(op_line "agent-tools:plugin-init v=1 name=personal-agent-tools-x build_id=sha256:$op_hex_a")"
op_init_case "marker text inside another message, or another plugin's marker -> no marker" "$op_no_marker"
#            ... and a message that only quotes the marker after other text,
#            even with its own quote, is not the marker: the line's first
#            message field decides (Codex review R1, PR #325).
op_log_write "$(op_line "copied message=$(op_marker "sha256:$op_hex_a") extra")"
op_init_case "marker text after other text in a message -> no marker" "$op_no_marker"
op_log_write "$(op_line "copied message=\"$(op_marker "sha256:$op_hex_a")\" extra")"
op_init_case "a quoted marker inside another message -> no marker" "$op_no_marker"
#            ... nor does such a later line hide an earlier real marker: the
#            newest line is picked by its first message field too (Codex
#            review R2, PR #325).
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" \
  "$(op_line "copied message=\"$(op_marker "sha256:$op_hex_b")\" extra")"
op_init_case "a real marker, then a line quoting another marker -> confirmed" "$op_confirmed"
#     OP-i9) XDG_DATA_HOME moves the log: absolute -> read there; empty -> the
#            default; relative -> not confirmed (it depends on OpenCode's cwd).
op_log_write
mkdir -p "$op_home/xdg-data/opencode/log"
op_line "$(op_marker "sha256:$op_hex_a")" > "$op_home/xdg-data/opencode/log/opencode.log"
op_init_case "absolute XDG_DATA_HOME -> the log there" "$op_confirmed" XDG_DATA_HOME="$op_home/xdg-data/"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")"
op_init_case "empty XDG_DATA_HOME -> the default log" "$op_confirmed" XDG_DATA_HOME=
op_init_case "absolute XDG_DATA_HOME without a log -> not started" "$op_no_log" XDG_DATA_HOME="$op_home/xdg-none"
op_init_case "relative XDG_DATA_HOME -> not confirmed" \
  "[info] - $op_init not confirmed: XDG_DATA_HOME is a relative path here, so where OpenCode logs depends on the directory it starts in ($op_deployed)" \
  XDG_DATA_HOME=rel/data
#     OP-i10) a log that is not a regular file (a FIFO would block a read:
#             Codex review R1, PR #325) or cannot be read (skipped where
#             permissions do not bind, e.g. as root).
#             The FIFO run has a deadline: should doctor read the FIFO, it
#             would block for good, so it is killed (with what it started)
#             and the case fails instead of hanging the suite (Codex review
#             R2, PR #325).
mv "$op_log" "$op_log.keep"
mkfifo "$op_log"
# op_kill_tree PID — KILL PID and its descendants (collected before the kill).
op_kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do
    op_kill_tree "$child"
  done
  kill -KILL "$1" 2>/dev/null || true
}
op_run > "$fixture_home/op-fifo.out" 2>&1 &
op_fifo_pid=$!
op_fifo_waited=0
while kill -0 "$op_fifo_pid" 2>/dev/null && [[ "$op_fifo_waited" -lt 120 ]]; do
  sleep 1
  op_fifo_waited=$((op_fifo_waited + 1))
done
if kill -0 "$op_fifo_pid" 2>/dev/null; then
  op_kill_tree "$op_fifo_pid"
  wait "$op_fifo_pid" 2>/dev/null || true
  fail "test failed: OpenCode init: a FIFO in place of the log hung doctor (killed after 120s)"
  status=1
elif ! wait "$op_fifo_pid"; then
  fail "test failed: doctor must stay exit 0 (OpenCode init: a FIFO in place of the log)"
  status=1
else
  op_init_check "a FIFO in place of the log -> not confirmed, no hang" \
    "[info] - $op_init not confirmed: OpenCode's log is not a regular file ($op_deployed)" \
    "$(cat "$fixture_home/op-fifo.out")"
fi
rm -f "$op_log" "$fixture_home/op-fifo.out"
mv "$op_log.keep" "$op_log"
chmod 000 "$op_log"
if [[ ! -r "$op_log" ]]; then
  op_init_case "unreadable log -> not confirmed" \
    "[info] - $op_init not confirmed: OpenCode's log could not be read ($op_deployed)"
fi
chmod 644 "$op_log"
rm -rf "$op_home/.local/share/opencode" "$op_home/xdg-data"
rm -rf "$op_home" "$op_fakebin" "$op_ran"

# NA) next-actions summary (#227): every warning reported through `action`
#     is repeated once, numbered, at the end of the run with its steps, and
#     `--actions-only` prints just that list. doctor stays exit 0 (report-
#     only) and writes no file. Fixture: a fresh empty HOME with the
#     committed repo (personal) — it always yields a few actions (identity
#     files, drift is skipped without chezmoi state, ...); the assertions
#     are structural (count = numbered lines, each with >= 1 step line, the
#     same list in both modes), so they do not pin which host-side warnings
#     a given environment produces.
na_home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-doctor-na.XXXXXX")"
mkdir -p "$na_home/src/personal"
#     NA-a) full run: summary section is last, count matches, steps present.
if na_out="$(HOME="$na_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  na_count="$(printf '%s\n' "$na_out" | sed -n 's/^\[info\] == next actions (\([0-9][0-9]*\)) ==$/\1/p')"
  na_numbered="$(printf '%s\n' "$na_out" | grep -c -E '^\[info\] [0-9]+\. ')"
  na_steps="$(printf '%s\n' "$na_out" | grep -c -E '^        [^ ]')"
  na_last_section="$(printf '%s\n' "$na_out" | grep -E '^\[info\] == ' | tail -n 1)"
  # Every numbered reason must also be an inline [warn] line, in the SAME
  # relative order (the summary is the warn stream filtered to actions —
  # a dropped or reordered action would break the monotonic index walk).
  na_order_ok=1
  na_prev=0
  while IFS= read -r na_reason; do
    [[ -n "$na_reason" ]] || continue
    na_idx="$(printf '%s\n' "$na_out" | grep -n -F -x -- "[warn] $na_reason" | head -n 1 | cut -d: -f1)"
    if [[ -z "$na_idx" || "$na_idx" -le "$na_prev" ]]; then
      na_order_ok=0
      break
    fi
    na_prev="$na_idx"
  done <<< "$(printf '%s\n' "$na_out" | sed -n 's/^\[info\] [0-9][0-9]*\. //p')"
  # The deterministic actions of this fixture carry exact step lines: the
  # identity file (prose step) and the two herdr bodies (command steps).
  na_identity_step="        create $na_home/.config/git/personal.gitconfig with the [user] name/email for the personal context (local-only, never managed; docs/git-identity.md) — commits under $na_home/src/personal are refused until then"
  if [[ -n "$na_count" && "$na_count" -gt 0 && "$na_count" == "$na_numbered" && "$na_steps" -ge "$na_count" \
    && "$na_last_section" == "[info] == next actions ($na_count) ==" && "$na_order_ok" == 1 ]] \
    && grep -Eq "^\[info\] [0-9]+\. project root exists but identity file missing: $na_home/.config/git/personal.gitconfig" <<< "$na_out" \
    && grep -F -x -q -- "$na_identity_step" <<< "$na_out" \
    && grep -F -x -q -- '        $ herdr integration install claude' <<< "$na_out" \
    && grep -F -x -q -- '        $ herdr integration install codex' <<< "$na_out"; then
    ok "test passed: next-actions summary closes the report with $na_count numbered actions in warn order, each with its exact step line"
  else
    printf '%s\n' "$na_out" >&2
    fail "test failed: next-actions summary malformed (count=$na_count numbered=$na_numbered steps=$na_steps order_ok=$na_order_ok last=$na_last_section)"
    status=1
  fi
else
  printf '%s\n' "$na_out" >&2
  fail "test failed: doctor must stay exit 0 (next actions, full run)"
  status=1
fi
#     NA-b) --actions-only: only the summary (plus nothing else) and the
#           same numbered list as the full run. (doctor itself writes no
#           file; the tools it probes — npm, brew — keep their own caches
#           under HOME, so "no file written" is not asserted on a fixture.)
if na_only="$(HOME="$na_home" "$SCRIPT_DIR/doctor.sh" personal --actions-only 2>&1)"; then
  na_full_list="$(printf '%s\n' "$na_out" | sed -n '/^\[info\] == next actions (/,$p')"
  if [[ "$na_only" == "$na_full_list" ]] \
    && ! grep -q -E '^\[(ok|warn)\]' <<< "$na_only" \
    && ! grep -q -E '^\[info\] (- |== [^n])' <<< "$na_only"; then
    ok "test passed: --actions-only prints exactly the summary of the full run (no other report lines)"
  else
    printf '%s\n' "$na_only" >&2
    fail "test failed: --actions-only output differs from the full run's summary or leaked other lines"
    status=1
  fi
else
  printf '%s\n' "$na_only" >&2
  fail "test failed: doctor must stay exit 0 (--actions-only)"
  status=1
fi
#     NA-c) any unknown dash-word is a usage error (exit 2, no report), so a
#           typo never silently runs the full report as personal — including
#           short ones: `-h` would otherwise reach the validator's help
#           branch and the report would run against a profile named "-h"
#           (Codex review, PR #228).
for na_opt in --actions-onyl -h -x; do
  if na_bad="$(HOME="$na_home" "$SCRIPT_DIR/doctor.sh" --actions-only "$na_opt" 2>&1)"; then
    fail "test failed: unknown option $na_opt must not run doctor"
    status=1
  elif [[ $? -eq 2 ]] && grep -Fq "unknown option: $na_opt" <<< "$na_bad" && ! grep -Fq "== policy ==" <<< "$na_bad" && ! grep -Fq "next actions" <<< "$na_bad"; then
    ok "test passed: unknown option $na_opt -> usage error (exit 2) without running the report"
  else
    printf '%s\n' "$na_bad" >&2
    fail "test failed: unknown option $na_opt handling wrong"
    status=1
  fi
done
#     NA-d) helper-level exact pins (deterministic, no host state): zero
#           actions -> "none"; then two actions where the steps carry a
#           printf directive (%), a leading dash and a shell-quoted path
#           with a space — the summary must print them verbatim, in order,
#           with the [warn] lines emitted first (Codex review, PR #228).
na_zero="$(bash -c 'set -euo pipefail; source "$1"; report_actions' _ "$SCRIPT_DIR/lib-policy.sh" 2>&1)"
if [[ "$na_zero" == $'[info] == next actions (0) ==\n[ok] next actions: none' ]]; then
  ok "test passed: zero actions -> 'next actions: none'"
else
  printf '%s\n' "$na_zero" >&2
  fail "test failed: zero-actions summary wrong"
  status=1
fi
na_two="$(bash -c 'set -euo pipefail; source "$1"
action "first reason 100%" "\$ step one" "-n second step"
action "second reason" "\$ rm -i $(printf "%q" "/tmp/a b/c")"
report_actions' _ "$SCRIPT_DIR/lib-policy.sh" 2>&1)"
na_two_expected="$(cat <<'TXT'
[warn] first reason 100%
[warn] second reason
[info] == next actions (2) ==
[info] 1. first reason 100%
        $ step one
        -n second step
[info] 2. second reason
        $ rm -i /tmp/a\ b/c
TXT
)"
if [[ "$na_two" == "$na_two_expected" ]]; then
  ok "test passed: action/report_actions print reasons and multi-line steps verbatim (%, leading dash, quoted path) in order"
else
  diff <(printf '%s\n' "$na_two_expected") <(printf '%s\n' "$na_two") >&2 || true
  fail "test failed: helper-level next-actions output differs from the expected block"
  status=1
fi
#     NA-d2) drift step path: a chezmoi status line with a single-column
#            status (" M x") must yield "~/x", not "~/M x" (the path starts
#            after the fixed two status columns + space). Fake chezmoi on
#            PATH so the drift section is deterministic.
na_fakebin="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-doctor-na-fake.XXXXXX")"
cat > "$na_fakebin/chezmoi" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo "chezmoi version v0.0.0-fake" ;;
  status) printf '%s\n' " M .gitconfig" "MM .npmrc" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$na_fakebin/chezmoi"
if na_drift="$(HOME="$na_home" PATH="$na_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal --actions-only 2>&1)"; then
  if grep -F -q -- "        \$ chezmoi diff $na_home/.gitconfig   #" <<< "$na_drift" \
    && grep -F -q -- "        \$ chezmoi diff $na_home/.npmrc   #" <<< "$na_drift" \
    && ! grep -F -q -- "/M .gitconfig" <<< "$na_drift"; then
    ok "test passed: drift steps point at the path after the two status columns (' M x' -> ~/x)"
  else
    printf '%s\n' "$na_drift" >&2
    fail "test failed: drift step path extraction wrong"
    status=1
  fi
else
  printf '%s\n' "$na_drift" >&2
  fail "test failed: doctor must stay exit 0 (drift steps)"
  status=1
fi
rm -rf "$na_fakebin"
#     NA-e) work machine (settings modules inactive) with herdr on PATH but
#           its integrations not installed -> an action per agent naming the
#           installer; installed -> informational only; herdr absent -> a
#           pointer to the catalog section, no action. Reuses the herdr
#           fake from the HI block (rebuilt here; HI removed it).
mkdir -p "$hi_fakebin" "$na_home/.claude" "$na_home/.codex"
hi_claude_body="$na_home/.claude/hooks/herdr-agent-state.sh"
hi_codex_body="$na_home/.codex/herdr-agent-state.sh"
write_fake_herdr_status "not installed" "outdated (v1 < v8)" ok
if na_work="$(HOME="$na_home" PATH="$hi_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" work --actions-only 2>&1)"; then
  if grep -Fq "herdr integration for claude is not installed — ~/.claude/settings.json is unmanaged for this profile, so herdr integration install owns both the registration and the body here" <<< "$na_work" \
    && grep -Fq '        $ herdr integration install claude' <<< "$na_work" \
    && grep -Fq "herdr integration for codex is outdated — ~/.codex/hooks.json is unmanaged for this profile" <<< "$na_work" \
    && grep -Fq '        $ herdr integration install codex' <<< "$na_work"; then
    ok "test passed: work profile with herdr present but not installed/outdated -> next actions name herdr integration install per agent"
  else
    printf '%s\n' "$na_work" >&2
    fail "test failed: work-profile herdr install actions missing"
    status=1
  fi
else
  printf '%s\n' "$na_work" >&2
  fail "test failed: doctor must stay exit 0 (work, herdr not installed)"
  status=1
fi
write_fake_herdr_status "current (v9)" "current (v8)" ok
if na_work="$(HOME="$na_home" PATH="$hi_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" work 2>&1)"; then
  if grep -Fq "herdr's own view: claude integration current — ~/.claude/settings.json is unmanaged for this profile" <<< "$na_work" \
    && ! grep -Fq "herdr integration install" <<< "$(printf '%s\n' "$na_work" | sed -n '/^\[info\] == next actions (/,$p')"; then
    ok "test passed: work profile with both integrations current -> informational only, no herdr action"
  else
    printf '%s\n' "$na_work" >&2
    fail "test failed: current integrations on work produced an action or lost the info line"
    status=1
  fi
else
  printf '%s\n' "$na_work" >&2
  fail "test failed: doctor must stay exit 0 (work, herdr current)"
  status=1
fi
#           herdr absent: a PATH of the system dirs plus a private bin
#           holding a yq symlink — the real yq's directory (homebrew bin) is
#           NOT on it, because that is where a real herdr lives — and the
#           op / codex / opencode stubs (this PATH replaces the one carrying
#           them, #306). A herdr in the system dirs would make this case run
#           the real tool, so it fails up front instead of running doctor.
rm -f "$hi_fakebin/herdr"
ln -sf "$(command -v yq)" "$hi_fakebin/yq"
for host_tool in op codex opencode; do
  ln -sf "$host_stub_dir/bin/$host_tool" "$hi_fakebin/$host_tool"
done
if (PATH="$hi_fakebin:/usr/bin:/bin"; hash -r; command -v herdr >/dev/null 2>&1); then
  fail "test failed: the herdr-absent case needs a PATH without herdr, but /usr/bin:/bin has one (doctor not run against a real herdr)"
  status=1
elif na_work="$(HOME="$na_home" PATH="$hi_fakebin:/usr/bin:/bin" "$SCRIPT_DIR/doctor.sh" work 2>&1)"; then
  if grep -Fq "herdr not on PATH: nothing to check (the software catalog section reports it as declared-missing" <<< "$na_work" \
    && ! grep -Fq "herdr integration install" <<< "$(printf '%s\n' "$na_work" | sed -n '/^\[info\] == next actions (/,$p')"; then
    ok "test passed: work profile without herdr on PATH -> pointer to the catalog section, no herdr action"
  else
    printf '%s\n' "$na_work" >&2
    fail "test failed: herdr-absent state on work not reported as a pointer"
    status=1
  fi
else
  printf '%s\n' "$na_work" >&2
  fail "test failed: doctor must stay exit 0 (work, herdr absent)"
  status=1
fi
rm -rf "$na_home" "$hi_fakebin"

# AIP) AI policy — Codex permission surface (#139). doctor watches the two
#      accumulation channels report-only: (1) a fixed probe list of outward/
#      escalation commands evaluated against the LIVE rules via `codex
#      execpolicy check` — doctor never reads the rules file itself (Codex
#      review #187: line-grepping misses blanket prefixes / multi-line rules /
#      the omitted-decision default=allow, and echoing rule lines can leak
#      secrets embedded in arbitrary strings); (2) [projects] trust in
#      codex-owned config.toml -> warn on trusted whole-home and on trusted
#      stale (nonexistent) paths, parsing ONLY section headers + trust_level
#      (a canary in an MCP env block must never be echoed).
#      The engine is faked with a PATH-front codex shim (fake-driven fixture,
#      same pattern as the npm fakes in #150): the shim allows a probe iff its
#      joined command string appears in $CODEX_FAKE_ALLOWS, so these cases pin
#      doctor's REPORTING contract (probe loop, warn wording, no-echo, exit 0)
#      deterministically — rules semantics themselves are the real engine's
#      job at runtime. Committed personal profile (codex-settings active,
#      enableAiPolicy=true) against $DOTFILES_ROOT scripts. exit 0 throughout.
codex_fakebin="$fixture_home/codexfake"
mkdir -p "$codex_fakebin" "$fixture_home/.codex/rules" "$fixture_home/real-project"
cat > "$codex_fakebin/codex" <<'SH'
#!/bin/sh
# fake codex: execpolicy check --rules <path> [--rules <path> ...] <tokens...>
# - logs each joined probe to $CODEX_FAKE_LOG (pins the probe SET in tests)
# - logs the basename of every --rules path to $CODEX_FAKE_RULES_LOG, NUL-
#   delimited (pins the rules-file SET doctor hands to the engine, newline in
#   a name included, #316)
# - CODEX_FAKE_MODE=fail -> exit 1 (engine-evaluation failure path; real codex
#   exits 1 on a broken/missing rules file, verified 0.142.5)
# - else emits an allow verdict iff the probe appears in $CODEX_FAKE_ALLOWS —
#   and, when $CODEX_FAKE_ALLOWS_IF_RULES names a rules file, only if that file
#   was passed (an allow that lives in that file alone, #316).
[ "$1" = "execpolicy" ] && [ "$2" = "check" ] || exit 2
shift 2
rules_seen=","
while [ "$1" = "--rules" ]; do
  [ -n "${CODEX_FAKE_RULES_LOG:-}" ] && printf '%s\0' "${2##*/}" >> "$CODEX_FAKE_RULES_LOG"
  rules_seen="$rules_seen${2##*/},"
  shift 2
done
probe="$*"
[ -n "${CODEX_FAKE_LOG:-}" ] && printf '%s\n' "$probe" >> "$CODEX_FAKE_LOG"
[ "${CODEX_FAKE_MODE:-}" = "fail" ] && exit 1
if [ -n "${CODEX_FAKE_RESULT:-}" ]; then
  cat "$CODEX_FAKE_RESULT"
  exit 0
fi
if [ -n "${CODEX_FAKE_ALLOWS_IF_RULES:-}" ]; then
  case "$rules_seen" in
    *",$CODEX_FAKE_ALLOWS_IF_RULES,"*) ;;
    *) printf '{"matchedRules":[]}\n'; exit 0 ;;
  esac
fi
case ",${CODEX_FAKE_ALLOWS:-}," in
  *",$probe,"*) printf '{"matchedRules":[{"x":1}],"decision":"allow"}\n' ;;
  *)            printf '{"matchedRules":[]}\n' ;;
esac
SH
chmod +x "$codex_fakebin/codex"
# The rules file content is irrelevant to the fake (doctor must not read it) —
# plant a canary to pin exactly that: a secret-looking string inside a rule
# line must never reach doctor output.
cat > "$fixture_home/.codex/rules/default.rules" <<'RULES'
prefix_rule(pattern=["gh", "pr", "view"], decision="allow")
prefix_rule(pattern=["curl", "-H", "Authorization: Bearer CANARY_RULES_LEAK_a71c"], decision="allow")
RULES
# TOML spelling coverage (Codex review #187, round 2): the whole-home entry is
# COMPACT (trust_level="trusted", no spaces) and one stale entry is single-
# quoted — both valid TOML codex may write; missing either would undercount and
# silently skip the home-trust warn.
cat > "$fixture_home/.codex/config.toml" <<TOML
approval_policy = "on-request"

[mcp_servers.fake.env]
FAKE_TOKEN = "CANARY_CODEX_ENV_LEAK_3b9d"

[projects."$fixture_home"]
trust_level="trusted"

[projects."$fixture_home/gone-project"]
trust_level = 'trusted'

[projects."$fixture_home/gone-untrusted"]
trust_level = "untrusted"

[projects."$fixture_home/real-project"]
trust_level = "trusted"
TOML
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" \
    CODEX_FAKE_ALLOWS="git push,gh pr create,gh auth status --show-token,gh auth status -t,gh auth token,env,op read op://example/item/field,security -q find-generic-password -s example.invalid -w" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'git push'" <<< "$aip_out" \
    && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'gh pr create'" <<< "$aip_out" \
    && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'gh auth status --show-token'" <<< "$aip_out" \
    && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'gh auth status -t'" <<< "$aip_out" \
    && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'gh auth token'" <<< "$aip_out" \
    && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'env'" <<< "$aip_out" \
    && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'op read op://example/item/field'" <<< "$aip_out" \
    && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'security -q find-generic-password -s example.invalid -w'" <<< "$aip_out" \
    && grep -Fq "Codex projects trust covers the WHOLE home directory" <<< "$aip_out" \
    && grep -Fq "stale Codex projects trust (path no longer exists): $fixture_home/gone-project" <<< "$aip_out" \
    && ! grep -Fq "gone-untrusted" <<< "$aip_out" \
    && grep -Fq "3 path(s) trusted" <<< "$aip_out" \
    && ! grep -Fq "CANARY_CODEX_ENV_LEAK_3b9d" <<< "$aip_out" \
    && ! grep -Fq "CANARY_RULES_LEAK_a71c" <<< "$aip_out"; then
    ok "test passed: allowed probes warned by name, trusted whole-home (compact TOML) + trusted stale (single-quoted) warned, untrusted entry ignored, contents never echoed"
  else
    printf '%s\n' "$aip_out" >&2
    fail "test failed: Codex permission-surface watch (probes/projects trust) not reported as expected"
    status=1
  fi
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: doctor must stay exit 0 (Codex permission surface)"
  status=1
fi

# AIP-H) Project headers (#292): both quoted key forms, optional whitespace
# and trailing comments must preserve the path; unsupported headers make the
# entire scan INCOMPLETE, even if an earlier entry was parsed successfully.
cat > "$fixture_home/.codex/config.toml" <<TOML
[projects.'$fixture_home' ] # whole-home grant
trust_level = "trusted"
TOML
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
  && grep -Fq "Codex projects trust covers the WHOLE home directory" <<< "$aip_out" \
  && grep -Fq "edit ~/.codex/config.toml: remove the project entry for this path (or set its trust_level to untrusted)" <<< "$aip_out" \
  && grep -Fq "Codex projects trust: 1 path(s) trusted" <<< "$aip_out" \
  && ! grep -Fq "projects-trust scan INCOMPLETE" <<< "$aip_out"; then
  ok "test passed: single-quoted project header reports the whole-home action (exit 0)"
else
  fail "test failed: single-quoted project header must report the whole-home action (exit 0)"
  status=1
fi

cat > "$fixture_home/.codex/config.toml" <<TOML
[projects."$fixture_home/real-project"] # CANARY_HEADER_COMMENT_292
trust_level = "trusted"
[mcp_servers.fake.env]
FAKE_TOKEN = "CANARY_HEADER_ENV_292"
TOML
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
  && grep -Fq "Codex projects trust: 1 path(s) trusted" <<< "$aip_out" \
  && ! grep -Fq "stale Codex projects trust" <<< "$aip_out" \
  && ! grep -Fq "projects-trust scan INCOMPLETE" <<< "$aip_out" \
  && ! grep -Fq "CANARY_HEADER_" <<< "$aip_out"; then
  ok "test passed: commented project header counts a real trusted path without stale warnings or value leaks (exit 0)"
else
  fail "test failed: commented project header must count the real path without stale warnings or value leaks (exit 0)"
  status=1
fi

# Headers that are TOML syntax errors make the whole file unreadable: INCOMPLETE.
# (Valid spellings such as [projects.bare] are counted — see the trust form
# cases below.)
for aip_header in "[projects.'/path' trailing]" '[projects."/path"] trailing'; do
  cat > "$fixture_home/.codex/config.toml" <<TOML
[projects."$fixture_home/real-project"]
trust_level = "trusted"
$aip_header
trust_level = "trusted"
[mcp_servers.fake.env]
FAKE_TOKEN = "CANARY_HEADER_ENV_292"
TOML
  if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" \
      "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
    && grep -Fq "projects-trust scan INCOMPLETE" <<< "$aip_out" \
    && grep -Fq "do NOT read this as zero trusted" <<< "$aip_out" \
    && ! grep -Fq "Codex projects trust:" <<< "$aip_out" \
    && ! grep -Fq "CANARY_HEADER_" <<< "$aip_out"; then
    ok "test passed: a header that is a TOML syntax error reports INCOMPLETE without a trusted count (exit 0): $aip_header"
  else
    fail "test failed: a header that is a TOML syntax error must report INCOMPLETE without a trusted count (exit 0): $aip_header"
    status=1
  fi
done

# The scan reads config.toml with a TOML parser (yq, #309), so every valid
# spelling of a project table counts as TOML says — a [projects] table,
# inline tables, dotted / quoted / escaped keys, multi-line strings — and only
# what does not read as a map of project tables (a TOML error, projects as a
# string or an array, a trusted key with a control character) is INCOMPLETE,
# never "0 trusted". Each case writes the whole config line by line (printf
# '%s\n', so a TOML escape such as j stays literal), with a real trusted
# project and an MCP env canary that must never be printed.
aip_real_header="[projects.\"$fixture_home/real-project\"]"
aip_bs='\'   # one backslash: the escape cases spell TOML escapes (u006a = j) with it
# aip_trust_case LABEL EXPECT LINE... — EXPECT is "incomplete" or a count.
aip_trust_case() {
  local label="$1" expect="$2"
  shift 2
  printf '%s\n' "$@" '[mcp_servers.fake.env]' 'FAKE_TOKEN = "CANARY_FORM_ENV_309"' \
    > "$fixture_home/.codex/config.toml"
  if ! aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" \
      "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)"; then
    fail "test failed: doctor must stay exit 0 (trust form: $label)"
    status=1
  elif grep -Fq "CANARY_FORM_" <<< "$aip_out"; then
    fail "test failed: trust form $label leaked a config value"
    status=1
  elif [[ "$expect" == incomplete ]]; then
    if grep -Fq "projects-trust scan INCOMPLETE" <<< "$aip_out" \
      && grep -Fq "do NOT read this as zero trusted" <<< "$aip_out" \
      && ! grep -Fq "Codex projects trust:" <<< "$aip_out"; then
      ok "test passed: trust form reports INCOMPLETE without a trusted count: $label"
    else
      fail "test failed: trust form must report INCOMPLETE without a trusted count: $label"
      status=1
    fi
  elif grep -Fq "Codex projects trust: $expect path(s) trusted" <<< "$aip_out" \
    && ! grep -Fq "projects-trust scan INCOMPLETE" <<< "$aip_out"; then
    ok "test passed: trust form counts as TOML says ($expect): $label"
  else
    fail "test failed: trust form must count as TOML says ($expect), not INCOMPLETE or another count: $label"
    status=1
  fi
}
# Valid spellings that grant trust: counted with the real project (2).
aip_trust_case "root inline table" 2 \
  "projects = { \"/x\" = { trust_level = \"trusted\" }, \"$fixture_home/real-project\" = { trust_level = \"trusted\" } }"
aip_trust_case "root dotted key" 2 \
  'projects."/x".trust_level = "trusted"' "$aip_real_header" 'trust_level = "trusted"'
aip_trust_case "escaped root key" 2 \
  "\"pro${aip_bs}u006aects\".\"/x\".trust_level = \"trusted\"" "$aip_real_header" 'trust_level = "trusted"'
aip_trust_case "[projects] table" 2 \
  "$aip_real_header" 'trust_level = "trusted"' '[projects]' '"/x" = { trust_level = "trusted" }'
aip_trust_case "spaced table name" 2 \
  "$aip_real_header" 'trust_level = "trusted"' '[ projects."/x" ]' 'trust_level = "trusted"'
aip_trust_case "quoted table name" 2 \
  "$aip_real_header" 'trust_level = "trusted"' '["projects"."/x"]' 'trust_level = "trusted"'
aip_trust_case "escaped table name" 2 \
  "$aip_real_header" 'trust_level = "trusted"' "[\"pro${aip_bs}u006aects\".\"/x\"]" 'trust_level = "trusted"'
aip_trust_case "bare project key" 2 \
  "$aip_real_header" 'trust_level = "trusted"' '[projects.bare]' 'trust_level = "trusted"'
aip_trust_case "escaped backslash in a project key" 2 \
  "$aip_real_header" 'trust_level = "trusted"' "[projects.\"/escaped${aip_bs}${aip_bs}path\"]" 'trust_level = "trusted"'
aip_trust_case "quoted trust_level key" 2 \
  "$aip_real_header" 'trust_level = "trusted"' '[projects."/x"]' '"trust_level" = "trusted"'
aip_trust_case "escaped trust_level key" 2 \
  "$aip_real_header" 'trust_level = "trusted"' '[projects."/x"]' "\"trust${aip_bs}u005flevel\" = \"trusted\""
aip_trust_case "multi-line trust_level" 2 \
  "$aip_real_header" 'trust_level = "trusted"' '[projects."/x"]' 'trust_level = """trusted"""'
aip_trust_case "root projects key after a multi-line array" 2 \
  'arr = [' '  "a",' ']' "projects = { \"/x\" = { trust_level = \"trusted\" }, \"$fixture_home/real-project\" = { trust_level = \"trusted\" } }"
# ... while trust_level in a sub-table, look-alike keys and tables, the same
# key inside another table, string contents that look like tables, comments,
# escapes in values or other tables' names, and an untrusted entry do not.
aip_trust_case "trust_level in a sub-table of a project" 1 \
  "$aip_real_header" 'trust_level = "trusted"' '[projects."/path".extra]' 'trust_level = "trusted"'
aip_trust_case "look-alike keys and tables" 1 \
  'project_doc_max_bytes = 32768' "$aip_real_header" 'trust_level = "trusted"' \
  '[profiles.projects]' 'model = "m"' '[projects."/y"]' 'trust_level = "untrusted" # note'
aip_trust_case "projects key inside an MCP env table" 1 \
  "$aip_real_header" 'trust_level = "trusted"' '[mcp_servers.demo.env]' 'projects = "demo"'
aip_trust_case "multi-line basic string with table-like text" 1 \
  'developer_instructions = """' '[projects]' 'projects = 1' '"""' "$aip_real_header" 'trust_level = "trusted"'
aip_trust_case "multi-line literal string with table-like text" 1 \
  "notes = '''" '[projects]' "'''" "$aip_real_header" 'trust_level = "trusted"'
aip_trust_case "triple quote inside a comment" 1 \
  '# a """ example in a comment' "$aip_real_header" 'trust_level = "trusted"'
aip_trust_case "escaped quotes inside a multi-line string" 1 \
  'developer_instructions = """' "say ${aip_bs}\"\"\"hi" '[projects]' '"""' "$aip_real_header" 'trust_level = "trusted"'
aip_trust_case "multi-line string closed by four quotes inside an array" 1 \
  'notify = ["sh", "-c", """echo "done""""]' "$aip_real_header" 'trust_level = "trusted"'
aip_trust_case "escaped quotes in a multi-line array value" 1 \
  'notify = [' '  "sh",' '  "-c",' "  \"printf '%s' ${aip_bs}\"done${aip_bs}\"\"," ']' "$aip_real_header" 'trust_level = "trusted"'
aip_trust_case "backslash in a header comment" 1 \
  "$aip_real_header # C:${aip_bs}work" 'trust_level = "trusted"'
aip_trust_case "escape in another table's name" 1 \
  "[mcp_servers.\"demo${aip_bs}u002dserver\"]" 'command = "x"' "$aip_real_header" 'trust_level = "trusted"'
aip_trust_case "backslash in a literal header and in a value" 2 \
  "$aip_real_header" 'trust_level = "trusted"' "[projects.'/tmp/project${aip_bs}name']" 'trust_level = "trusted"' \
  '[mcp_servers.demo.env]' "PATHX = \"C:${aip_bs}${aip_bs}dir\""
aip_trust_case "no projects at all" 0 \
  '[profiles.default]' 'model = "m"'
# What does not read as a map of project tables is INCOMPLETE.
aip_trust_case "TOML syntax error" incomplete \
  "$aip_real_header" 'trust_level = "trusted"' 'this is not toml'
aip_trust_case "projects as a string" incomplete \
  'projects = "everything"'
aip_trust_case "projects as an array of tables" incomplete \
  '[[projects]]' 'path = "/x"' 'trust_level = "trusted"'
aip_trust_case "an empty trusted key" incomplete \
  "$aip_real_header" 'trust_level = "trusted"' '[projects.""]' 'trust_level = "trusted"'
aip_trust_case "a trusted key with a C1 control character" incomplete \
  "$aip_real_header" 'trust_level = "trusted"' "[projects.\"/tmp/a${aip_bs}u0085b\"]" 'trust_level = "trusted"'
aip_trust_case "a trusted key with a control character" incomplete \
  "$aip_real_header" 'trust_level = "trusted"' "[projects.\"/a${aip_bs}nb\"]" 'trust_level = "trusted"'

# AIP-2) Clean state: no probe allowed, only a real trusted project -> the ok
#        line (with the probe count), no warns from this watch. The shim log
#        pins the EXACT probe set (policy-derived contract): a probe silently
#        dropped from doctor.sh fails this test (coverage regression guard).
cat > "$fixture_home/.codex/config.toml" <<TOML
[projects."$fixture_home/real-project"]
trust_level = "trusted"
TOML
aip_probe_log="$fixture_home/.codex-probe-log"
: > "$aip_probe_log"
expected_probes=$'curl https://example.invalid\nenv\ngh api --method POST repos/o/r/issues\ngh auth login\ngh auth status --show-token\ngh auth status -t\ngh auth token\ngh issue close\ngh issue comment\ngh issue create\ngh issue delete\ngh issue edit\ngh issue transfer\ngh pr close\ngh pr comment\ngh pr create\ngh pr edit\ngh pr merge\ngh release create\ngh release delete\ngh release edit\ngh release upload\ngh repo archive\ngh repo delete\ngh repo edit\ngh repo rename\ngh secret set\ngit clone https://example.invalid/repo\ngit push\nop item get example\nop read op://example/item/field\nprintenv\nsecurity -q find-generic-password -s example.invalid -w\nsecurity dump-keychain\nsecurity export -k login.keychain\nsecurity find-generic-password -s example.invalid -w\nsecurity find-internet-password -s example.invalid -w\nsudo -v\nwget https://example.invalid'
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" \
    CODEX_FAKE_ALLOWS="" CODEX_FAKE_LOG="$aip_probe_log" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "no outward/escalation/credential-display probe is auto-allowed by the live Codex rules" <<< "$aip_out" \
    && grep -Fq "1 path(s) trusted" <<< "$aip_out" \
    && ! grep -Fq "outward/escalation/credential-display probe auto-allowed" <<< "$aip_out" \
    && ! grep -Fq "WHOLE home directory" <<< "$aip_out" \
    && ! grep -Fq "stale Codex projects trust" <<< "$aip_out"; then
    ok "test passed: clean Codex permission surface reports ok (no false warns)"
  else
    printf '%s\n' "$aip_out" >&2
    fail "test failed: clean Codex permission surface produced unexpected output"
    status=1
  fi
  if probe_diff="$(diff <(printf '%s\n' "$expected_probes") <(sort "$aip_probe_log"))"; then
    ok "test passed: doctor evaluated exactly the pinned outward/escalation/credential-display/secret-read probe set (39 probes)"
  else
    printf '%s\n' "$probe_diff" >&2
    fail "test failed: outward/escalation/credential-display probe set drifted from the pinned contract (update both doctor.sh and this pin deliberately)"
    status=1
  fi
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: doctor must stay exit 0 (Codex permission surface, clean)"
  status=1
fi

# AIP-3) Engine-evaluation failure (codex execpolicy exits 1 — broken rules
#        file, incompatible codex): the scan must surface INCOMPLETE and must
#        NOT emit the clean ok (a failure that reads as clean is the fail-open
#        false-clean the review flagged). doctor stays exit 0 (report-only).
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" \
    CODEX_FAKE_ALLOWS="" CODEX_FAKE_MODE="fail" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "rules-semantics scan INCOMPLETE" <<< "$aip_out" \
    && ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
    ok "test passed: probe-evaluation failure reports scan INCOMPLETE and suppresses the clean ok (no fail-open false-clean)"
  else
    printf '%s\n' "$aip_out" >&2
    fail "test failed: probe-evaluation failure did not surface as INCOMPLETE (or still claimed clean)"
    status=1
  fi
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: doctor must stay exit 0 (probe-evaluation failure)"
  status=1
fi
# AIP-4) Interpret the effective decision, not a nested rule match (#210).
# Invalid JSON and unknown result shapes must remain report-only INCOMPLETE.
aip_result="$fixture_home/.codex-result"
for aip_case in forbidden prompt pretty-allow malformed empty unknown missing null-decision non-object; do
  case "$aip_case" in
    forbidden|prompt)
      printf '{"decision":"%s","matchedRules":[{"decision":"allow"}]}\n' "$aip_case" > "$aip_result"
      aip_expected="clean"
      ;;
    pretty-allow)
      printf '{\n  "decision": "allow",\n  "matchedRules": []\n}\n' > "$aip_result"
      aip_expected="allow"
      ;;
    *)
      case "$aip_case" in
        malformed) printf '{CANARY_INVALID_RESULT' > "$aip_result" ;;
        empty) : > "$aip_result" ;;
        unknown) printf '{"decision":"CANARY_UNKNOWN_RESULT","matchedRules":[]}' > "$aip_result" ;;
        missing) printf '{}' > "$aip_result" ;;
        null-decision) printf '{"decision":null,"matchedRules":[]}' > "$aip_result" ;;
        non-object) printf '[{"decision":"allow"}]' > "$aip_result" ;;
      esac
      aip_expected="incomplete"
      ;;
  esac
  if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" \
      CODEX_FAKE_RESULT="$aip_result" "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)"; then
    aip_actual="unexpected"
    if grep -Fq "rules-semantics scan INCOMPLETE" <<< "$aip_out"; then
      aip_actual="incomplete"
    elif grep -Fq "outward/escalation/credential-display probe auto-allowed" <<< "$aip_out"; then
      aip_actual="allow"
    elif grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
      aip_actual="clean"
    fi
    if [[ "$aip_actual" == "$aip_expected" ]] && ! grep -Fq "CANARY_" <<< "$aip_out" \
      && { [[ "$aip_expected" == "clean" ]] || ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; }; then
      ok "test passed: Codex result $aip_case reports $aip_expected without leaking output"
    else
      fail "test failed: Codex result $aip_case expected $aip_expected, got $aip_actual"
      status=1
    fi
  else
    fail "test failed: doctor must stay exit 0 (Codex result $aip_case)"
    status=1
  fi
done
rm -f "$aip_result"

# AIP-5) Every *.rules Codex loads is probed, not only default.rules (#316).
#        Codex reads each regular file with the .rules extension in the rules
#        dir (exec_policy.rs collect_policy_files, 0.159.3): a sibling and a
#        hidden one count; a symlink, a dir, default.rules.bak.<date> and a
#        bare ".rules" do not. doctor must hand the engine exactly that set
#        (shim log), name each unmanaged one (sanitized: a control character
#        in a name must not reach the terminal), and report an allow that
#        lives only in a sibling file.
aip_rules_dir="$fixture_home/.codex/rules"
aip_rules_log="$fixture_home/.codex-rules-log"
aip_esc="$(printf '\033')"
aip_evil_name="evil${aip_esc}[31m.rules"
aip_nl_name="nl"$'\n'"name.rules"
aip_rules_expected="$fixture_home/.codex-rules-expected"
printf 'prefix_rule(pattern=["git", "push"], decision="allow")\n' > "$aip_rules_dir/extra.rules"
: > "$aip_rules_dir/.hidden.rules"
: > "$aip_rules_dir/$aip_evil_name"
: > "$aip_rules_dir/$aip_nl_name"
: > "$aip_rules_dir/..rules"
: > "$aip_rules_dir/.rules"
: > "$aip_rules_dir/default.rules.bak.20260702"
mkdir -p "$aip_rules_dir/dir.rules"
ln -s "$aip_rules_dir/extra.rules" "$aip_rules_dir/link.rules"
# Codex's Path::extension() gives "..rules" the extension "rules" (only a
# bare ".rules" has none), so it is loaded too.
printf '%s\0' ".hidden.rules" "..rules" "default.rules" "$aip_evil_name" "extra.rules" "$aip_nl_name" \
  | LC_ALL=C sort -z > "$aip_rules_expected"
: > "$aip_rules_log"
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" \
    CODEX_FAKE_ALLOWS="git push" CODEX_FAKE_ALLOWS_IF_RULES="extra.rules" \
    CODEX_FAKE_RULES_LOG="$aip_rules_log" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)"; then
  aip_unmanaged_prefix="unmanaged Codex rules file, loaded by Codex alongside the baseline: ~/.codex/rules/"
  if grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'git push'" <<< "$aip_out" \
    && grep -Fq "${aip_unmanaged_prefix}extra.rules " <<< "$aip_out" \
    && grep -Fq "${aip_unmanaged_prefix}.hidden.rules " <<< "$aip_out" \
    && grep -Fq "${aip_unmanaged_prefix}evil?[31m.rules " <<< "$aip_out" \
    && grep -Fq "${aip_unmanaged_prefix}nl?name.rules " <<< "$aip_out" \
    && grep -Fq "${aip_unmanaged_prefix}..rules " <<< "$aip_out" \
    && ! grep -Fq "$aip_esc" <<< "$aip_out" \
    && ! grep -Fq "${aip_unmanaged_prefix}default.rules" <<< "$aip_out" \
    && ! grep -Fq "link.rules" <<< "$aip_out" \
    && ! grep -Fq "dir.rules" <<< "$aip_out" \
    && ! grep -Fq "default.rules.bak" <<< "$aip_out" \
    && ! grep -Fq "${aip_unmanaged_prefix}.rules " <<< "$aip_out"; then
    ok "test passed: unmanaged sibling rules files are named (sanitized) and an allow living only in one is reported"
  else
    printf '%s\n' "$aip_out" >&2
    fail "test failed: unmanaged Codex rules files not reported as expected"
    status=1
  fi
  if LC_ALL=C sort -z -u "$aip_rules_log" | cmp -s - "$aip_rules_expected"; then
    ok "test passed: doctor hands the engine exactly the rules files Codex loads (regular *.rules incl. hidden, ..rules and a newline in a name; no symlink / dir / .bak / bare .rules)"
  else
    LC_ALL=C sort -z -u "$aip_rules_log" | tr '\0' '\n' >&2
    fail "test failed: rules-file set passed to codex execpolicy differs from what Codex loads"
    status=1
  fi
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: doctor must stay exit 0 (unmanaged Codex rules files)"
  status=1
fi
# Same tree, nothing allowed: the clean ok counts the files it probed.
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" CODEX_FAKE_ALLOWS="" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
  && grep -Fq "probes over 6 rules file(s) via codex execpolicy" <<< "$aip_out"; then
  ok "test passed: the clean ok reports the number of rules files probed"
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: clean ok missing the probed rules-file count"
  status=1
fi
rm -rf "${aip_rules_dir:?}/extra.rules" "${aip_rules_dir:?}/.hidden.rules" "${aip_rules_dir:?}/${aip_evil_name:?}" \
  "${aip_rules_dir:?}/${aip_nl_name:?}" "${aip_rules_dir:?}/..rules" \
  "${aip_rules_dir:?}/.rules" "${aip_rules_dir:?}/default.rules.bak.20260702" "${aip_rules_dir:?}/dir.rules" \
  "${aip_rules_dir:?}/link.rules" "$aip_rules_log" "$aip_rules_expected"

# AIP-6) A symlinked default.rules is not loaded by Codex, so the baseline is
#        not in effect: warn, and do not pass it to the engine (no clean ok).
mv "$aip_rules_dir/default.rules" "$fixture_home/.codex/default.rules.real"
ln -s "$fixture_home/.codex/default.rules.real" "$aip_rules_dir/default.rules"
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" CODEX_FAKE_ALLOWS="" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "Codex approval-rules baseline is a symlink" <<< "$aip_out" \
    && ! grep -Fq "Codex approval-rules baseline managed" <<< "$aip_out" \
    && ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
    ok "test passed: a symlinked default.rules is warned as not in effect and is not probed"
  else
    printf '%s\n' "$aip_out" >&2
    fail "test failed: symlinked default.rules not reported as not in effect"
    status=1
  fi
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: doctor must stay exit 0 (symlinked default.rules)"
  status=1
fi
# Same symlinked baseline beside a (clean) sibling file: the sibling is still
# probed, and the clean ok must not claim the baseline is holding.
: > "$aip_rules_dir/extra.rules"
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" CODEX_FAKE_ALLOWS="" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
  && grep -Fq "probes over 1 rules file(s) via codex execpolicy; the managed baseline is NOT in effect)" <<< "$aip_out" \
  && ! grep -Fq "read-only baseline holding" <<< "$aip_out"; then
  ok "test passed: with the baseline not in effect, the clean ok over a sibling file does not claim the baseline is holding"
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: the clean ok claimed a holding baseline while default.rules is not in effect"
  status=1
fi
rm -f "$aip_rules_dir/extra.rules" "$aip_rules_dir/default.rules"
mv "$fixture_home/.codex/default.rules.real" "$aip_rules_dir/default.rules"

# AIP-7) An unreadable rules dir cannot be enumerated the way Codex does, so
#        the scan is INCOMPLETE, never clean. Skipped as root (root reads it).
if [[ "$(id -u)" != "0" ]]; then
  chmod 000 "$aip_rules_dir"
  if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" CODEX_FAKE_ALLOWS="" \
      "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
    && grep -Fq "Codex rules dir could not be opened (~/.codex/rules" <<< "$aip_out" \
    && ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
    ok "test passed: an unreadable rules dir reports the scan INCOMPLETE (no false clean)"
  else
    printf '%s\n' "$aip_out" >&2
    fail "test failed: unreadable rules dir did not surface as INCOMPLETE"
    status=1
  fi
  chmod 755 "$aip_rules_dir"
fi

# AIP-8) ~/.codex/rules itself a symlink to a directory: Codex's read_dir
#        follows it, so the listing must too (while still skipping symlinked
#        entries) — an allow in a sibling there must surface.
mv "$aip_rules_dir" "$fixture_home/.codex/rules-real"
ln -s "$fixture_home/.codex/rules-real" "$aip_rules_dir"
printf 'prefix_rule(pattern=["git", "push"], decision="allow")\n' > "$fixture_home/.codex/rules-real/extra.rules"
: > "$aip_rules_log"
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" \
    CODEX_FAKE_ALLOWS="git push" CODEX_FAKE_ALLOWS_IF_RULES="extra.rules" \
    CODEX_FAKE_RULES_LOG="$aip_rules_log" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
  && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'git push'" <<< "$aip_out" \
  && grep -Fq "unmanaged Codex rules file, loaded by Codex alongside the baseline: ~/.codex/rules/extra.rules " <<< "$aip_out" \
  && [[ "$(LC_ALL=C sort -z -u "$aip_rules_log" | tr '\0' '\n')" == $'default.rules\nextra.rules' ]]; then
  ok "test passed: a symlinked rules dir is followed (its files are probed and named)"
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: a symlinked rules dir was not followed"
  status=1
fi
rm -f "$aip_rules_dir" "$fixture_home/.codex/rules-real/extra.rules" "$aip_rules_log"
mv "$fixture_home/.codex/rules-real" "$aip_rules_dir"

# AIP-9) A listing that prints some entries and then fails must not leave a
#        subset that reads as clean: a PATH-front find prints default.rules for
#        the rules dir and exits 1 (any other find call goes to the real one).
aip_findbin="$fixture_home/findfake"
mkdir -p "$aip_findbin"
aip_real_find="$(command -v find)"
cat > "$aip_findbin/find" <<SH
#!/bin/sh
case "\$*" in
  *"/.codex/rules "*) printf '%s\0' "\$HOME/.codex/rules/default.rules"; exit 1 ;;
esac
exec "$aip_real_find" "\$@"
SH
chmod +x "$aip_findbin/find"
if aip_out="$(HOME="$fixture_home" PATH="$aip_findbin:$codex_fakebin:$PATH" CODEX_FAKE_ALLOWS="" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
  && grep -Fq "Codex rules dir could not be listed completely (~/.codex/rules" <<< "$aip_out" \
  && ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
  ok "test passed: a listing that fails after partial output reports the scan INCOMPLETE (no subset read as clean)"
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: a partially failed rules listing was read as clean"
  status=1
fi
rm -rf "${aip_findbin:?}"

# AIP-10) ~/.codex/rules exists but is not a directory: Codex cannot read its
#         rules dir, so the scan is INCOMPLETE, never "not applied" or clean.
mv "$aip_rules_dir" "$fixture_home/.codex/rules-real"
: > "$aip_rules_dir"
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" CODEX_FAKE_ALLOWS="" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
  && grep -Fq "Codex rules dir could not be opened (~/.codex/rules" <<< "$aip_out" \
  && ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
  ok "test passed: a non-directory rules path reports the scan INCOMPLETE"
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: a non-directory rules path was not reported as INCOMPLETE"
  status=1
fi
rm -f "$aip_rules_dir"
mv "$fixture_home/.codex/rules-real" "$aip_rules_dir"

# AIP-11) Only a confirmed absence is "no rules": ~/.codex/rules a symlink into
#         a parent without search permission is a read error for Codex, so it
#         must be INCOMPLETE — `test -e` alone would call it absent and report
#         only "not applied yet". Skipped as root.
if [[ "$(id -u)" != "0" ]]; then
  mv "$aip_rules_dir" "$fixture_home/.codex/rules-real"
  mkdir -p "$fixture_home/locked-parent"
  mv "$fixture_home/.codex/rules-real" "$fixture_home/locked-parent/rules"
  ln -s "$fixture_home/locked-parent/rules" "$aip_rules_dir"
  chmod 000 "$fixture_home/locked-parent"
  if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" CODEX_FAKE_ALLOWS="" \
      "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
    && grep -Fq "Codex rules dir could not be opened (~/.codex/rules" <<< "$aip_out" \
    && ! grep -Fq "Codex approval-rules baseline not applied yet" <<< "$aip_out" \
    && ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
    ok "test passed: a rules dir behind an unsearchable parent is INCOMPLETE, not absent"
  else
    printf '%s\n' "$aip_out" >&2
    fail "test failed: an unresolvable rules dir was read as absent"
    status=1
  fi
  chmod 755 "$fixture_home/locked-parent"
  rm -f "$aip_rules_dir"
  mv "$fixture_home/locked-parent/rules" "$aip_rules_dir"
  rmdir "$fixture_home/locked-parent"
fi

# AIP-13) The absence test matches the strerror at the END of the message
#         only: a HOME whose path contains "No such file or directory" must
#         not turn a permission error into "absent". Skipped as root.
if [[ "$(id -u)" != "0" ]]; then
  aip_odd_home="$fixture_home/odd: No such file or directory"
  mkdir -p "$aip_odd_home/.codex" "$aip_odd_home/locked-parent/rules"
  : > "$aip_odd_home/locked-parent/rules/default.rules"
  ln -s "$aip_odd_home/locked-parent/rules" "$aip_odd_home/.codex/rules"
  chmod 000 "$aip_odd_home/locked-parent"
  if aip_out="$(HOME="$aip_odd_home" PATH="$codex_fakebin:$PATH" CODEX_FAKE_ALLOWS="" \
      "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
    && grep -Fq "Codex rules dir could not be opened (~/.codex/rules" <<< "$aip_out" \
    && ! grep -Fq "Codex approval-rules baseline not applied yet" <<< "$aip_out"; then
    ok "test passed: a HOME containing the strerror words does not turn a permission error into absent"
  else
    printf '%s\n' "$aip_out" >&2
    fail "test failed: a permission error under a HOME containing the strerror words was read as absent"
    status=1
  fi
  chmod 755 "$aip_odd_home/locked-parent"
  rm -rf "${aip_odd_home:?}"
fi

# AIP-12) A dangling ~/.codex/rules symlink IS a confirmed absence (Codex's
#         NotFound -> no rules): "not applied yet", not INCOMPLETE.
mv "$aip_rules_dir" "$fixture_home/.codex/rules-real"
ln -s "$fixture_home/.codex/rules-gone" "$aip_rules_dir"
if aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" CODEX_FAKE_ALLOWS="" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" \
  && grep -Fq "Codex approval-rules baseline not applied yet" <<< "$aip_out" \
  && ! grep -Fq "Codex rules dir could not be" <<< "$aip_out"; then
  ok "test passed: a dangling rules dir symlink is a confirmed absence (not applied, not INCOMPLETE)"
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: a dangling rules dir symlink was not treated as absent"
  status=1
fi
rm -f "$aip_rules_dir"
mv "$fixture_home/.codex/rules-real" "$aip_rules_dir"

rm -rf "$fixture_home/.codex/rules" "$fixture_home/.codex/config.toml" \
  "$fixture_home/real-project" "$codex_fakebin" "$aip_probe_log"

# CL) Claude project-level allow accumulation (#334). Approving a command with
#     "don't ask again" saves an allow rule into the project's
#     .claude/settings.local.json; doctor evaluates the outward probes against
#     the allow rules of the repos directly under the standard project roots
#     and reports the ones no deny / ask stops (the live floor
#     ~/.claude/settings.json, or the project's own two files). Rules are read
#     one per JSON string, so a rule holding a line break stays one rule.
#     Report-only, contents-blind (a saved rule can carry a token: only the
#     file and the probe names are shown). A HOME of its own,
#     so no other case's files are read; the real checkout is outside it and
#     is not scanned.
cl_home="$fixture_home/cl-home"
cl_canary="CANARY_CL_LEAK_5e2f"
cl_write() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}
cl_run() {
  HOME="$cl_home" "$SCRIPT_DIR/doctor.sh" "${1:-personal}" 2>&1
}
cl_floor='{"permissions":{"deny":["Bash(gh auth token)",7],"ask":["Bash(gh  pr merge *)","Bash(echo harmless\nBash\n)"]}}'
cl_write "$cl_home/.claude/settings.json" "$cl_floor"
cl_a="$cl_home/src/personal/repo-a/.claude/settings.local.json"
cl_b="$cl_home/src/agent/repo-b/.claude/settings.json"
cl_c="$cl_home/src/work/repo c/.claude/settings.local.json"
cl_d="$cl_home/src/client/repo-d/.claude/settings.local.json"
cl_deep="$cl_home/src/personal/group/nested/.claude/settings.local.json"
cl_f="$cl_home/src/sandbox/repo-f/.claude/settings.local.json"
cl_h="$cl_home/src/client/.repo-h/.claude/settings.local.json"
cl_write "$cl_a" "{\"permissions\":{\"allow\":[\"Bash(git push:*)\",\"Bash(npm test:*)\",\"Bash(gh * create)\",\"Bash(sudo.*)\",\"Bash(gh *:*)\",\"Bash(git clone https://example.invalid/**/repo)\",\"Bash(curl -H \\\"x: $cl_canary\\\" *)\",\"Read(~/notes/**)\",42]}}"
cl_write "$cl_b" '{"permissions":{"allow":["Bash(gh auth token)","Bash(gh pr merge:*)","Bash(wget:*)"]}}'
cl_write "$cl_c" '{"permissions":{"allow":["Bash"]}}'
cl_write "$cl_d" "{\"permissions\":{\"allow\":[\"Bash($cl_canary)\""
cl_write "$cl_deep" '{"permissions":{"allow":["Bash"]}}'
cl_write "$cl_h" '{"permissions":{"allow":["Bash(sudo -v)"]}}'
cl_write "$cl_home/src/personal/repo-a/.claude/settings.json" '{"permissions":{"ask":["Bash(gh release *)"]}}'
cl_write "$cl_f" '{"permissions":{"allow":["Bash(\u00a0gh pr close *)","Bash(gh  repo\t*)","Bash(sudo -v *\n)","Bash(echo x\nBash\n)"],"deny":["Bash(gh repo delete)"]}}'

# CL-1) one run over every shape: a `:*` rule matching the bare command, the
#       floor's deny and ask winning over allow, the bare `Bash` tool (first
#       five named, the rest counted), a `*` mid-rule, a regex character
#       taken literally (`sudo.*` is not `sudo -v`), a `*` before the legacy
#       `:*` staying literal (`gh *:*` matches nothing, as in Claude Code),
#       `/**/` standing for zero or more directories, the project's own ask
#       (in its shared settings.json) beating its local allow, a deny in the
#       same file beating its allow, a rule with line breaks staying one rule
#       (the floor's multi-line ask does not read as the bare tool; a trailing
#       line break of an allow is trimmed, as Claude Code does), a file that is
#       not JSON (an item, no contents), a dot-named repo read, a deeper
#       checkout not read, a
#       non-string entry ignored, runs of spaces / tabs in a wildcard read as
#       one space (the floor's `gh  pr merge *` ask, repo-f's `gh  repo\t*`),
#       a wildcard trimmed as JavaScript does whatever the locale (repo-f's
#       NBSP-led allow; this run uses LC_ALL=C).
if cl_out="$(LC_ALL=C cl_run)"; then
  if grep -Fxq "[warn] 4 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_a: 'git push', 'git clone https://example.invalid/repo', 'gh pr create', 'gh issue create' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "        edit $cl_a: remove the allow rules covering those commands (approve them per use instead)" <<< "$cl_out" \
    && grep -Fxq "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_b: 'wget https://example.invalid' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "[warn] 28 outward probe(s) auto-allowed for Claude by project-level allow rules in $(printf '%q' "$cl_c"): 'git push', 'git clone https://example.invalid/repo', 'gh pr create', 'gh pr comment', 'gh pr edit' and 23 more — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "[warn] 5 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_f: 'gh pr close', 'gh repo edit', 'gh repo archive', 'gh repo rename', 'sudo -v' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_h: 'sudo -v' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "[info] - the permission rules of $cl_d could not be read (not a regular file holding JSON of the expected shape?); not checked (contents never shown)" <<< "$cl_out" \
    && ! grep -Fq "$cl_deep" <<< "$cl_out" \
    && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out" \
    && ! grep -Fq "$cl_canary" <<< "$cl_out"; then
    ok "test passed: project-level Claude allows covering outward probes are reported per file, floor deny / ask respected, contents never shown"
  else
    printf '%s\n' "$cl_out" >&2
    fail "test failed: project-level Claude allow report drifted"
    status=1
  fi
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: doctor must stay exit 0 (Claude project-level allows)"
  status=1
fi

# CL-2) files whose allows the floor already stops (or that cover no probe)
#       -> the ok line, counting the files read.
rm -rf "$cl_home/src"
cl_write "$cl_b" '{"permissions":{"allow":["Bash(gh auth token)","Bash(gh  pr merge:*)","Bash(npm test *)"]}}'
cl_write "$cl_home/src/sandbox/repo-e/.claude/settings.local.json" '{"permissions":{"deny":["Bash"]}}'
if cl_out="$(cl_run)" \
  && grep -Fxq "[ok] no project-level Claude allow rule covers an outward probe (30 probes over 2 settings file(s) in this repo and the repos directly under the standard project roots)" <<< "$cl_out" \
  && ! grep -Fq "auto-allowed for Claude" <<< "$cl_out"; then
  ok "test passed: allows the floor stops are not reported; the ok line counts the files read"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: floor-covered project allows must leave the ok line"
  status=1
fi

# CL-2b) a file that cannot be read keeps the result from being clean: no ok
#        line, an item saying so (here the only other file is clean). An
#        allow list of the wrong shape counts as unreadable too.
cl_write "$cl_d" '{"permissions":{"allow":"Bash"}}'
if cl_out="$(cl_run)" \
  && grep -Fxq "[info] - the permission rules of $cl_d could not be read (not a regular file holding JSON of the expected shape?); not checked (contents never shown)" <<< "$cl_out" \
  && grep -Fxq "[info] - Claude project-level allows partly checked: no outward probe auto-allowed in the 2 file(s) read, but 1 could not be read — not a clean result" <<< "$cl_out" \
  && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
  ok "test passed: an unreadable project file keeps the Claude allow check from reporting clean"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: an unreadable project file must not leave the clean ok"
  status=1
fi
rm -rf "$cl_home/src/client"

# CL-6) this repo under a standard root is read once: a minimal repo copy at
#       ~/src/personal/dotfiles runs doctor from there, so it is both "this
#       repo" and a repo under the root -> one action, not two (counted
#       whatever the path spelling: the fixture HOME may hold a doubled
#       slash from TMPDIR, which `pwd` drops from the repo's own path).
copy_repo_fixture "$cl_home/src/personal/dotfiles"
cl_self="$cl_home/src/personal/dotfiles/.claude/settings.local.json"
cl_write "$cl_self" '{"permissions":{"allow":["Bash(sudo -v)"]}}'
if cl_out="$(HOME="$cl_home" "$cl_home/src/personal/dotfiles/scripts/doctor.sh" personal 2>&1)" \
  && [[ "$(grep -F "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in " <<< "$cl_out" | grep -Fc "/src/personal/dotfiles/.claude/settings.local.json: 'sudo -v'")" -eq 1 ]]; then
  ok "test passed: this repo under a standard project root is read once (one action)"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: this repo under a standard project root must be read once"
  status=1
fi
rm -rf "$cl_home/src/personal/dotfiles"

# CL-7) this repo under HOME but outside the standard roots is read only as
#       "this repo", and HOME is compared in normalized form: the copy at
#       ~/dotfiles runs with a HOME spelled with a doubled slash (Codex review
#       R4, PR #340) -> its action appears.
copy_repo_fixture "$cl_home/dotfiles"
cl_write "$cl_home/dotfiles/.claude/settings.local.json" '{"permissions":{"allow":["Bash(sudo -v)"]}}'
cl_home_dbl="${cl_home%/*}//${cl_home##*/}"
if cl_out="$(HOME="$cl_home_dbl" "$cl_home/dotfiles/scripts/doctor.sh" personal 2>&1)" \
  && [[ "$(grep -F "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in " <<< "$cl_out" | grep -Fc "/cl-home/dotfiles/.claude/settings.local.json: 'sudo -v'")" -eq 1 ]]; then
  ok "test passed: this repo under HOME outside the standard roots is read (HOME compared normalized)"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: this repo under HOME outside the standard roots must be read"
  status=1
fi
rm -rf "$cl_home/dotfiles"

# CL-U) the matcher itself, on shapes the probes cannot reach (no probe holds
#       a backslash, a star, `^` or `]`, or a run of spaces): extracted from
#       doctor.sh and run in a subshell, each pair one match and one miss
#       (`\n` / `\t` / `<NBSP>` / `<BOM>` / `<LS>` in a case stand for a line
#       break / tab / U+00A0 / U+FEFF / U+2028). Run under LC_ALL=C and the
#       inherited locale: the trim must not depend on it.
cl_fns="$(sed -n '/^claude_js_space=(/,/)$/p; /^claude_bash_rule_matches() {/,/^}/p; /^claude_rules_cover() {/,/^}/p' "$SCRIPT_DIR/doctor.sh")"
read -r -d '' cl_cases <<'CASES' || true
yes|Bash(wget \* x*)|wget * xyz
no|Bash(wget \* x*)|wget a xyz
yes|Bash(wget \*)|wget \*
no|Bash(wget \*)|wget *
yes|Bash(echo \\\*)|echo \anything
no|Bash(echo \\\*)|echo anything
yes|Bash(echo a\\b)|echo a\b
no|Bash(echo a\\b)|echo a\\b
yes|Bash(echo \(x\))|echo (x)
no|Bash(echo \(x\))|echo \(x\)
yes|Bash(a^b *)|a^b c
no|Bash(a^b *)|ab c
yes|Bash(a]b *)|a]b c
no|Bash(a]b *)|ab c
yes|Bash()|anything
yes|Bash(*)|anything
no|Read(*)|anything
no|Bash(gh auth token\)|gh auth token\
yes|Bash(gh auth token\\)|gh auth token\
no|Bash(a\nb:*)|a
yes|Bash(a\nb:*)|a\nb:*
no|Bash(:*)|anything
yes|Bash(git  push *)|git push
yes|Bash(git push *)|git  push\tx
no|Bash(git push x*)|git pushx
yes|Bash(git\tpush x*)|git push xy
no|Bash(git  push)|git push
yes|Bash(git  push)|git  push
yes|Bash(<NBSP>git push *)|git push
yes|Bash(git push *<BOM>)|git push x
no|Bash(<NBSP>git push)|git push
yes|Bash(<NBSP>git push)|<NBSP>git push
no|Bash(a<LS>b:*)|a
yes|Bash(a<LS>b:*)|a<LS>b:*
CASES
# cl_matcher_misses LOCALE — run the cases in a subshell under LC_ALL=LOCALE
# ('' keeps the inherited locale); print each miss.
cl_matcher_misses() {
  (
    [[ -z "$1" ]] || export LC_ALL="$1"
    eval "$cl_fns"
    nl=$'\n'
    tab=$'\t'
    nbsp=$'\xc2\xa0'
    bom=$'\xef\xbb\xbf'
    lsep=$'\xe2\x80\xa8'
    while IFS='|' read -r want rule cmd; do
      [[ -n "$want" ]] || continue
      for token in rule cmd; do
        value="${!token}"
        value="${value//\\n/$nl}"
        value="${value//\\t/$tab}"
        value="${value//<NBSP>/$nbsp}"
        value="${value//<BOM>/$bom}"
        value="${value//<LS>/$lsep}"
        printf -v "$token" '%s' "$value"
      done
      got=no
      claude_rules_cover "$cmd" "$rule" && got=yes
      [[ "$got" == "$want" ]] || printf '  [LC_ALL=%s] %q vs %q -> %s (expected %s)\n' "${1:-inherited}" "$rule" "$cmd" "$got" "$want"
    done <<< "$cl_cases"
  )
}
if [[ -z "$cl_fns" ]]; then
  fail "test failed: claude_js_space / claude_bash_rule_matches / claude_rules_cover not found in doctor.sh"
  status=1
elif cl_misses="$(cl_matcher_misses C; cl_matcher_misses '')" && [[ -z "$cl_misses" ]]; then
  ok "test passed: the Claude rule matcher reads escapes, regex characters, the bare forms and line breaks the way Claude Code does"
else
  fail "test failed: the Claude rule matcher drifted:"
  printf '%s\n' "$cl_misses" >&2
  status=1
fi

# CL-R) the reader takes a file as read only when yq's stream ends with the
#       marker it emits after a complete evaluation (Codex review R5, PR
#       #340): a stub yq that stops mid-stream must leave the file unread,
#       one that completes fills both lists, one element per string.
cl_reader="$(sed -n '/^claude_read_rules() {/,/^}/p' "$SCRIPT_DIR/doctor.sh")"
if [[ -n "$cl_reader" ]] && cl_reader_out="$(
  eval "$cl_reader"
  claude_allow_rules=()
  claude_stop_rules=()
  yq() { printf 'ABash(git push)\0Sx\0'; return 1; }
  if claude_read_rules /dev/null; then echo "partial-read-accepted"; fi
  yq() { printf 'ABash(git push *\n)\0ABash(npm test)\0SBash(gh repo *)\0E\0'; }
  if claude_read_rules /dev/null; then
    printf 'allow=%s stop=%s first=%q\n' "${#claude_allow_rules[@]}" "${#claude_stop_rules[@]}" "${claude_allow_rules[0]}"
  else
    echo "complete-read-rejected"
  fi
)" && [[ "$cl_reader_out" == "allow=2 stop=1 first=$(printf '%q' $'Bash(git push *\n)')" ]]; then
  ok "test passed: the Claude rule reader needs yq's end marker and keeps one element per rule"
else
  printf '%s\n' "${cl_reader_out:-claude_read_rules not found in doctor.sh}" >&2
  fail "test failed: the Claude rule reader accepted a partial read or split a rule"
  status=1
fi

# CL-3) no live floor file: nothing beats the allows, so every covered probe
#       is reported (in probe order; the legacy prefix collapses whitespace
#       runs, so `gh  pr merge:*` covers `gh pr merge`).
rm -f "$cl_home/.claude/settings.json"
if cl_out="$(cl_run)" \
  && grep -Fxq "[warn] 2 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_b: 'gh pr merge', 'gh auth token' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out"; then
  ok "test passed: without a live floor every covered probe is reported"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: allows without a live floor were not all reported"
  status=1
fi

# CL-4) a live floor that cannot be read decides nothing -> an item, neither
#       the ok line nor a warn.
cl_write "$cl_home/.claude/settings.json" '{"permissions":'
if cl_out="$(cl_run)" \
  && grep -Fxq "[info] - Claude project-level allows not checked: the live ~/.claude/settings.json could not be read (its deny / ask decide which allows matter)" <<< "$cl_out" \
  && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out" \
  && ! grep -Fq "auto-allowed for Claude" <<< "$cl_out"; then
  ok "test passed: an unreadable live floor leaves the project allows unchecked (no false clean)"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: an unreadable live floor must report not checked"
  status=1
fi

# CL-4b) a floor of two JSON documents (not one JSON value; yq would read
#        each) is unreadable too, so its first document's deny of the bare
#        tool cannot hide the project allows (Codex review R6, PR #340).
printf '%s\n%s\n' '{"permissions":{"deny":["Bash"]}}' '{}' > "$cl_home/.claude/settings.json"
if cl_out="$(cl_run)" \
  && grep -Fxq "[info] - Claude project-level allows not checked: the live ~/.claude/settings.json could not be read (its deny / ask decide which allows matter)" <<< "$cl_out" \
  && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
  ok "test passed: a floor of more than one JSON document is not read (no false clean)"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: a floor of more than one JSON document must not be read"
  status=1
fi
# ... and so is a floor repeating a key: yq would take the first
#     `permissions` (a deny of the bare tool), JSON.parse the last (none).
printf '%s\n' '{"permissions":{"deny":["Bash"]},"permissions":{}}' > "$cl_home/.claude/settings.json"
if cl_out="$(cl_run)" \
  && grep -Fxq "[info] - Claude project-level allows not checked: the live ~/.claude/settings.json could not be read (its deny / ask decide which allows matter)" <<< "$cl_out" \
  && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
  ok "test passed: a floor repeating a key is not read (yq and JSON.parse would disagree)"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: a floor repeating a key must not be read"
  status=1
fi

# CL-5) work does not manage the Claude floor (claude-settings inactive) ->
#       not watched, whatever is on disk.
cl_write "$cl_home/.claude/settings.json" "$cl_floor"
cl_write "$cl_c" '{"permissions":{"allow":["Bash"]}}'
if cl_out="$(cl_run work)" \
  && grep -Fxq "[info] - Claude project-level allows not watched for this profile (claude-settings module inactive)" <<< "$cl_out" \
  && ! grep -Fq "auto-allowed for Claude" <<< "$cl_out"; then
  ok "test passed: work does not watch Claude project-level allows"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: work must not watch Claude project-level allows"
  status=1
fi

# CL-8) only a confirmed absence counts as "no settings" (Codex review R7,
#       PR #340): a .claude dir that cannot be searched, or a settings path
#       that is not a regular file, is unreadable (an item, no clean ok), and
#       so is a floor dir that cannot be searched. The rest of the HOME is
#       clean here (repo-b's allows are all stopped by the floor). Skipped as
#       root (root searches the dir).
rm -rf "$cl_home/src/work" "$cl_home/src/sandbox"
cl_g="$cl_home/src/personal/repo-g/.claude"
cl_write "$cl_g/settings.local.json" '{"permissions":{"allow":["Bash(npm test)"]}}'
if [[ "$(id -u)" != "0" ]]; then
  chmod 000 "$cl_g"
  if cl_out="$(cl_run)" \
    && grep -Fxq "[info] - the .claude directory of $cl_home/src/personal/repo-g could not be opened (permission denied, not a directory or a symlink loop); its settings not checked" <<< "$cl_out" \
    && grep -Fq "Claude project-level allows partly checked:" <<< "$cl_out" \
    && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
    ok "test passed: a .claude dir that cannot be searched is unreadable, not absent (no false clean)"
  else
    printf '%s\n' "$cl_out" >&2
    fail "test failed: a .claude dir that cannot be searched must not read as absent"
    status=1
  fi
  chmod 755 "$cl_g"
  chmod 000 "$cl_home/.claude"
  if cl_out="$(cl_run)" \
    && grep -Fxq "[info] - Claude project-level allows not checked: the live ~/.claude/settings.json could not be read (its deny / ask decide which allows matter)" <<< "$cl_out" \
    && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
    ok "test passed: a floor dir that cannot be searched leaves the check not done (no false clean)"
  else
    printf '%s\n' "$cl_out" >&2
    fail "test failed: a floor dir that cannot be searched must not read as no floor"
    status=1
  fi
  chmod 755 "$cl_home/.claude"
  for cl_mode in 000 111; do
    chmod "$cl_mode" "$cl_home/src/personal"
    if cl_out="$(cl_run)" \
      && grep -Fxq "[info] - the project root $cl_home/src/personal could not be listed (permission denied, not a directory or a symlink loop); the repos under it not checked" <<< "$cl_out" \
      && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
      ok "test passed: a project root that cannot be listed (mode $cl_mode) is unreadable, not empty"
    else
      printf '%s\n' "$cl_out" >&2
      fail "test failed: a project root that cannot be listed (mode $cl_mode) must not read as empty"
      status=1
    fi
    chmod 755 "$cl_home/src/personal"
  done
  # ... and so is a root under a ~/src that cannot be searched (`-d` would
  # read that as no root at all).
  chmod 000 "$cl_home/src"
  if cl_out="$(cl_run)" \
    && grep -Fxq "[info] - the project root $cl_home/src/personal could not be listed (permission denied, not a directory or a symlink loop); the repos under it not checked" <<< "$cl_out" \
    && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
    ok "test passed: the roots under a ~/src that cannot be searched are unreadable, not absent"
  else
    printf '%s\n' "$cl_out" >&2
    fail "test failed: the roots under a ~/src that cannot be searched must not read as absent"
    status=1
  fi
  chmod 755 "$cl_home/src"
fi
rm -f "$cl_g/settings.local.json"
mkdir -p "$cl_g/settings.local.json"
if cl_out="$(cl_run)" \
  && grep -Fxq "[info] - the permission rules of $cl_g/settings.local.json could not be read (not a regular file holding JSON of the expected shape?); not checked (contents never shown)" <<< "$cl_out" \
  && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
  ok "test passed: a settings path that is not a regular file is unreadable, not absent"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: a settings path that is not a regular file must not read as absent"
  status=1
fi
rm -rf "${cl_home:?}"

# GO) go install target (#305): the managed mise config leaves GOBIN unset so
#     `go install` lands in ~/go/bin, where the statusLine and the usage
#     reader run tacho. A PATH-front fake go answers `go env GOBIN|GOPATH`
#     from the environment (or fails), so the cases do not depend on the
#     host's Go. Any other target warns; a failed query is not checked; PATH
#     without ~/go/bin is an info line.
go_fakebin="$fixture_home/gofake"
mkdir -p "$go_fakebin"
cat > "$go_fakebin/go" <<'SH'
#!/bin/sh
[ "${FAKE_GO_FAIL:-}" = "1" ] && exit 1
[ "$1" = "env" ] || exit 2
case "$2" in
  GOBIN) printf '%s\n' "${FAKE_GOBIN-}" ;;
  GOPATH) printf '%s\n' "${FAKE_GOPATH-}" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$go_fakebin/go"
for go_case in default-gopath explicit-gobin elsewhere no-path query-fails query-fails-no-path trailing-slash-home; do
  go_gobin=""
  go_gopath="$fixture_home/go"
  go_path="$go_fakebin:$fixture_home/go/bin:$PATH"
  go_fail=""
  go_home="$fixture_home"
  case "$go_case" in
    explicit-gobin) go_gobin="$fixture_home/go/bin" ;;
    elsewhere) go_gobin="$fixture_home/toolchain/bin" ;;
    no-path) go_path="$go_fakebin:$PATH" ;;
    query-fails) go_fail=1 ;;
    query-fails-no-path) go_fail=1; go_path="$go_fakebin:$PATH" ;;
    # .zshenv appends ${HOME%/}/go/bin, so a trailing-slash HOME still matches.
    trailing-slash-home) go_home="$fixture_home/" ;;
  esac
  if go_out="$(HOME="$go_home" PATH="$go_path" FAKE_GOBIN="$go_gobin" FAKE_GOPATH="$go_gopath" \
      FAKE_GO_FAIL="$go_fail" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
    go_ok=0
    case "$go_case" in
      default-gopath|explicit-gobin|trailing-slash-home)
        grep -Fq "[ok] go install target: ~/go/bin" <<< "$go_out" \
          && ! grep -Fq "go install target is" <<< "$go_out" \
          && ! grep -Fq "PATH here lacks ~/go/bin" <<< "$go_out" && go_ok=1
        ;;
      elsewhere)
        # An action: it must also reach --actions-only with its steps, so
        # the fix is listed (ahead of the usage reader's installer step).
        go_only="$(HOME="$go_home" PATH="$go_path" FAKE_GOBIN="$go_gobin" FAKE_GOPATH="$go_gopath" \
          FAKE_GO_FAIL="$go_fail" "$SCRIPT_DIR/doctor.sh" personal --actions-only 2>&1)" || go_only=""
        grep -Fq "[warn] go install target is $fixture_home/toolchain/bin, not ~/go/bin" <<< "$go_out" \
          && ! grep -Fq "[ok] go install target" <<< "$go_out" \
          && grep -Fq "go install target is $fixture_home/toolchain/bin, not ~/go/bin" <<< "$go_only" \
          && grep -Fq "chezmoi apply $fixture_home/.config/mise/config.toml $fixture_home/.zshenv" <<< "$go_only" \
          && grep -Fq "\$ exec env -u GOBIN -u GOPATH zsh -l" <<< "$go_only" && go_ok=1
        ;;
      no-path)
        grep -Fq "[ok] go install target: ~/go/bin" <<< "$go_out" \
          && grep -Fq "PATH here lacks ~/go/bin" <<< "$go_out" && go_ok=1
        ;;
      query-fails)
        grep -Fq "[warn] go install target could not be determined" <<< "$go_out" \
          && ! grep -Fq "[ok] go install target" <<< "$go_out" \
          && ! grep -Fq "PATH here lacks ~/go/bin" <<< "$go_out" && go_ok=1
        ;;
      query-fails-no-path)
        grep -Fq "[warn] go install target could not be determined" <<< "$go_out" \
          && grep -Fq "PATH here lacks ~/go/bin" <<< "$go_out" && go_ok=1
        ;;
    esac
    if [[ "$go_ok" -eq 1 ]]; then
      ok "test passed: go install target ($go_case) reported as expected"
    else
      printf '%s\n' "$go_out" | grep -F 'go' >&2
      fail "test failed: go install target ($go_case) not reported as expected"
      status=1
    fi
  else
    printf '%s\n' "$go_out" >&2
    fail "test failed: doctor must stay exit 0 (go install target, $go_case)"
    status=1
  fi
done
rm -rf "${go_fakebin:?}"
# The new-shell step must actually drop an inherited GOBIN / GOPATH (a plain
# `exec zsh -l` keeps exported values): check that this env(1) honors the
# `-u` form the action prints, with a probe in place of the shell.
if [[ "$(GOBIN=/inherited/bin GOPATH=/inherited env -u GOBIN -u GOPATH sh -c 'printf "%s:%s" "${GOBIN-unset}" "${GOPATH-unset}"')" == "unset:unset" ]]; then
  ok "test passed: the action's env -u GOBIN -u GOPATH form drops inherited values here"
else
  fail "test failed: env -u GOBIN -u GOPATH did not drop inherited values"
  status=1
fi

# NPM-A) A broken npm (shim without a runtime) must not kill the doctor:
# report-only means warn + skip, exit 0 (#144).
npm_fakebin="$fixture_home/npmfake"
mkdir -p "$npm_fakebin"
cat > "$npm_fakebin/npm" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$npm_fakebin/npm"
if np_out="$(HOME="$fixture_home" PATH="$npm_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "npm on PATH but not runnable" <<< "$np_out"; then
    ok "test passed: broken npm is warned and skipped, doctor stays exit 0"
  else
    printf '%s\n' "$np_out" >&2
    fail "test failed: broken npm should be reported as not runnable"
    status=1
  fi
else
  printf '%s\n' "$np_out" >&2
  fail "test failed: doctor must stay exit 0 with a broken npm on PATH"
  status=1
fi

# NPM-B) A non-numeric npm version must not abort the min-release-age
# arithmetic ([[ -gt ]] resolves non-numeric operands as variable names and
# dies under set -u); expect a warn and exit 0 (#144).
cat > "$npm_fakebin/npm" <<'SH'
#!/bin/sh
if [ "$1" = "--version" ]; then printf 'not-a-version\n'; exit 0; fi
exit 0
SH
if np_out="$(HOME="$fixture_home" PATH="$npm_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "npm version 'not-a-version' not recognized" <<< "$np_out"; then
    ok "test passed: unrecognized npm version is warned, doctor stays exit 0"
  else
    printf '%s\n' "$np_out" >&2
    fail "test failed: unrecognized npm version should be warned"
    status=1
  fi
else
  printf '%s\n' "$np_out" >&2
  fail "test failed: doctor must stay exit 0 with an unrecognized npm version"
  status=1
fi

# NPM-C/D) The enforce expectation checks, deterministic via fake npm/node on
# PATH (#150): a mismatched config value is warned; the min-release-age
# before-cutoff is honored/warned based on the parsed epoch. The fakes are
# env-driven so each case pins one branch; doctor stays exit 0 throughout.
cat > "$npm_fakebin/npm" <<'SH'
#!/bin/sh
case "$1" in
  --version) printf '11.10.0\n' ;;
  config)
    case "$3" in
      ignore-scripts) printf '%s\n' "${FAKE_NPM_IGNORE_SCRIPTS:-true}" ;;
      save-exact) printf 'true\n' ;;
      fund) printf 'false\n' ;;
      audit) printf 'true\n' ;;
      before) printf '%s\n' "${FAKE_NPM_BEFORE:-null}" ;;
      *) printf 'null\n' ;;
    esac ;;
esac
exit 0
SH
cat > "$npm_fakebin/node" <<'SH'
#!/bin/sh
printf '%s' "${FAKE_NODE_EPOCH:-}"
exit 0
SH
chmod +x "$npm_fakebin/npm" "$npm_fakebin/node"
now_epoch="$(date +%s)"

if np_out="$(HOME="$fixture_home" PATH="$npm_fakebin:$PATH" \
  FAKE_NPM_IGNORE_SCRIPTS=false FAKE_NPM_BEFORE="fake-date" \
  FAKE_NODE_EPOCH="$(( now_epoch - 7*86400 ))" \
  "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "enforce expects npm ignore-scripts=true, current: false" <<< "$np_out" \
    && grep -Fq "npm min-release-age=7 honored" <<< "$np_out"; then
    ok "test passed: enforce mismatch warned while a good before-cutoff is honored"
  else
    printf '%s\n' "$np_out" >&2
    fail "test failed: enforce mismatch warn or honored cutoff missing"
    status=1
  fi
else
  printf '%s\n' "$np_out" >&2
  fail "test failed: doctor must stay exit 0 on an enforce mismatch"
  status=1
fi

if np_out="$(HOME="$fixture_home" PATH="$npm_fakebin:$PATH" \
  FAKE_NPM_BEFORE="fake-date" FAKE_NODE_EPOCH="$(( now_epoch - 86400 ))" \
  "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "enforce expects npm min-release-age=7 (before ~= now-7d)" <<< "$np_out"; then
    ok "test passed: a too-recent before cutoff is warned (cooldown not enforced)"
  else
    printf '%s\n' "$np_out" >&2
    fail "test failed: too-recent before cutoff not warned"
    status=1
  fi
else
  printf '%s\n' "$np_out" >&2
  fail "test failed: doctor must stay exit 0 on a too-recent cutoff"
  status=1
fi

# COREPACK-A) corepackMode=off says intentionally unmanaged; B) report mode
# with a corepack on PATH reports its version line (fake for determinism —
# the CI validate job may or may not ship corepack) (#150).
cp_root="$fixture_home/.dotfiles-corepack"
copy_repo_fixture "$cp_root"
set_capability_all "$cp_root" corepackMode off
if cp_out="$(HOME="$fixture_home" "$cp_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "corepack intentionally unmanaged" <<< "$cp_out"; then
    ok "test passed: corepackMode=off reports intentionally unmanaged"
  else
    printf '%s\n' "$cp_out" >&2
    fail "test failed: corepackMode=off not reported as unmanaged"
    status=1
  fi
else
  printf '%s\n' "$cp_out" >&2
  fail "test failed: doctor must stay exit 0 with corepackMode=off"
  status=1
fi

cat > "$npm_fakebin/corepack" <<'SH'
#!/bin/sh
[ "$1" = "--version" ] && printf '0.0-fake\n'
exit 0
SH
chmod +x "$npm_fakebin/corepack"
if cp_out="$(HOME="$fixture_home" PATH="$npm_fakebin:$PATH" \
  "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "corepack: 0.0-fake" <<< "$cp_out"; then
    ok "test passed: corepackMode=report shows the corepack version"
  else
    printf '%s\n' "$cp_out" >&2
    fail "test failed: corepack version line missing under report mode"
    status=1
  fi
else
  printf '%s\n' "$cp_out" >&2
  fail "test failed: doctor must stay exit 0 under corepackMode=report"
  status=1
fi

# DRIFT-A) A token-shaped line in ~/.npmrc is warned by name only (the value
# never appears in the output), doctor stays exit 0 (#148).
dr_home="$fixture_home/drift"
mkdir -p "$dr_home"
printf '# Managed by chezmoi from kosako/dotfiles (npmHardeningMode=enforce).\nignore-scripts=true\n//registry.npmjs.org/:_authToken=secret-placeholder-value\n' \
  > "$dr_home/.npmrc"
if dr_out="$(HOME="$dr_home" XDG_CONFIG_HOME='' "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "npmrc contains 1 _authToken line" <<< "$dr_out" \
    && ! grep -Fq "secret-placeholder-value" <<< "$dr_out"; then
    ok "test passed: npmrc token line warned by count, value never echoed"
  else
    printf '%s\n' "$dr_out" >&2
    fail "test failed: token line not warned, or the value leaked into output"
    status=1
  fi
else
  printf '%s\n' "$dr_out" >&2
  fail "test failed: doctor must stay exit 0 with a token line present"
  status=1
fi

# DRIFT-B) A managed .npmrc missing the managed-by header is warned; the
# status check itself must skip — as not-initialized when chezmoi exists
# (fixture homes carry no chezmoi state), as not-found where it does not
# (the CI validate job has no chezmoi).
if command -v chezmoi >/dev/null 2>&1; then
  drift_skip="chezmoi not initialized for this home; skipping drift check"
else
  drift_skip="chezmoi not found; skipping drift check"
fi
printf 'ignore-scripts=true\n' > "$dr_home/.npmrc"
if dr_out="$(HOME="$dr_home" XDG_CONFIG_HOME='' "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "npmrc lacks the managed-by header" <<< "$dr_out" \
    && grep -Fq "$drift_skip" <<< "$dr_out"; then
    ok "test passed: missing managed-by header warned; uninitialized home skips the status check"
  else
    printf '%s\n' "$dr_out" >&2
    fail "test failed: header warn or the not-initialized skip line missing"
    status=1
  fi
else
  printf '%s\n' "$dr_out" >&2
  fail "test failed: doctor must stay exit 0 with a headerless npmrc"
  status=1
fi

# DRIFT-C) The chezmoi-status branches, deterministic via a fake chezmoi on
# PATH (the CI validate job has no chezmoi and the render job does not run
# this test, so without the fake these branches would never be exercised in
# CI): drift lines -> per-line warn + exit 0; empty -> ok; failure -> the
# not-initialized skip, all report-only.
cz_fakebin="$fixture_home/czfake"
mkdir -p "$cz_fakebin"
cat > "$cz_fakebin/chezmoi" <<'SH'
#!/bin/sh
case "$1" in
  --version) printf 'chezmoi version v0.0-fake\n' ;;
  status)
    [ -n "$FAKE_CHEZMOI_STATUS" ] && printf '%s\n' "$FAKE_CHEZMOI_STATUS"
    exit "${FAKE_CHEZMOI_RC:-0}" ;;
esac
exit 0
SH
chmod +x "$cz_fakebin/chezmoi"

if dr_out="$(HOME="$dr_home" PATH="$cz_fakebin:$PATH" \
  FAKE_CHEZMOI_STATUS='MM .npmrc' FAKE_CHEZMOI_RC=0 \
  "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "drift: MM .npmrc" <<< "$dr_out" \
    && grep -Fq "a drift can be intended" <<< "$dr_out"; then
    ok "test passed: a chezmoi status line is warned as drift, doctor stays exit 0"
  else
    printf '%s\n' "$dr_out" >&2
    fail "test failed: drift line not warned"
    status=1
  fi
else
  printf '%s\n' "$dr_out" >&2
  fail "test failed: doctor must stay exit 0 when drift is reported"
  status=1
fi

if dr_out="$(HOME="$dr_home" PATH="$cz_fakebin:$PATH" \
  FAKE_CHEZMOI_STATUS='' FAKE_CHEZMOI_RC=0 \
  "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "no drift: managed files match the source state" <<< "$dr_out"; then
    ok "test passed: an empty chezmoi status reports no drift"
  else
    printf '%s\n' "$dr_out" >&2
    fail "test failed: empty status should report no drift"
    status=1
  fi
else
  printf '%s\n' "$dr_out" >&2
  fail "test failed: doctor must stay exit 0 with a clean status"
  status=1
fi

if dr_out="$(HOME="$dr_home" PATH="$cz_fakebin:$PATH" \
  FAKE_CHEZMOI_STATUS='' FAKE_CHEZMOI_RC=1 XDG_CONFIG_HOME='' \
  "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "chezmoi not initialized for this home; skipping drift check" <<< "$dr_out"; then
    ok "test passed: a failing chezmoi status is skipped, doctor stays exit 0"
  else
    printf '%s\n' "$dr_out" >&2
    fail "test failed: failing status should skip with the not-initialized item"
    status=1
  fi
else
  printf '%s\n' "$dr_out" >&2
  fail "test failed: doctor must stay exit 0 when chezmoi status fails"
  status=1
fi

# ... but with a chezmoi config in this home, a failing status is a config /
# template error (e.g. an unknown profile) that also breaks apply: an action
# naming `chezmoi status`, never the neutral not-initialized skip (#309).
mkdir -p "$dr_home/.config/chezmoi"
printf '[data]\nprofile = "persnal"\n' > "$dr_home/.config/chezmoi/chezmoi.toml"
if dr_out="$(HOME="$dr_home" PATH="$cz_fakebin:$PATH" \
  FAKE_CHEZMOI_STATUS='' FAKE_CHEZMOI_RC=1 XDG_CONFIG_HOME='' \
  "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[warn] chezmoi status failed although this home has a chezmoi config — a config or template error (e.g. an unknown profile) also breaks chezmoi apply; drift is not checked until it is fixed" <<< "$dr_out" \
    && grep -Fxq "        \$ chezmoi status   # read the error, then fix the config or the template" <<< "$dr_out" \
    && ! grep -Fq "chezmoi not initialized for this home" <<< "$dr_out"; then
    ok "test passed: a failing chezmoi status with a config present is an action, not the not-initialized skip"
  else
    printf '%s\n' "$dr_out" >&2
    fail "test failed: a failing status with a chezmoi config must be an action naming chezmoi status"
    status=1
  fi
else
  printf '%s\n' "$dr_out" >&2
  fail "test failed: doctor must stay exit 0 when chezmoi status fails with a config present"
  status=1
fi
rm -rf "$dr_home/.config/chezmoi"

if [[ "$status" -eq 0 ]]; then
  ok "doctor tests passed"
fi
exit "$status"
