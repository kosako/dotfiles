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

# The suite runs in parts on CI's macOS runner, where it is slowest (#456):
# TEST_DOCTOR_PART=N runs the shared setup below and part N only; unset or
# empty runs every part, as locally and on the Linux validate job. Each part
# is one contiguous range of cases inside `if doctor_part N; then` ... `fi`,
# so a case added inside a range joins that part, and what more than one
# part uses (helpers, the fixture HOME, the host-tool stubs) belongs to the
# setup before part 1. Any other value stops the suite before it runs a
# case, so a typo cannot pass with nothing tested.
doctor_parts=3
if [[ -n "${TEST_DOCTOR_PART-}" ]] \
  && ! [[ "$TEST_DOCTOR_PART" =~ ^[1-9]$ && "$TEST_DOCTOR_PART" -le "$doctor_parts" ]]; then
  printf 'TEST_DOCTOR_PART must be empty or 1 to %s, got: %s\n' "$doctor_parts" "$(display_safe "$TEST_DOCTOR_PART")" >&2
  exit 2
fi
doctor_part() {
  [[ -z "${TEST_DOCTOR_PART-}" || "$TEST_DOCTOR_PART" == "$1" ]]
}

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

# doctor_exit_fail LABEL RC OUTPUT — the doctor run of LABEL did not exit 0:
# show its output and its exit status, then fail. A failure seen once is then
# readable from the CI log (#378: CX-c failed once on the macOS runner with
# nothing to go on); the status tells a signal (128+N) from a failure doctor
# reported itself.
doctor_exit_fail() {
  printf '%s\n' "$3" >&2
  fail "test failed: doctor must stay exit 0 ($1): exited $2"
  status=1
}

status=0
fixture_home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-doctor-test.XXXXXX")"
# Host tools doctor would otherwise launch for real on a developer machine
# (`op whoami`, `herdr integration status`, codex / opencode probes, and the
# brew / npm queries of the software catalog and npm hardening): hundreds of
# runs below inherit this PATH, and the real tools are credential-bearing,
# slow to answer, or write to the fixture HOME (brew fetches its formula API
# into a fresh HOME's cache, npm writes logs there). A PATH-front dir of stubs
# that record the call and exit 1 keeps every run hermetic: the tools are
# present on PATH but fail when run (e.g. op reads as "not signed in", not
# "not found"; the catalog and npm hardening then only warn). Sections that
# need a specific answer put their own fake in front of these, as before
# (#306, #458).
# Kept outside the fixture HOME so no section's cleanup removes it.
host_stub_dir=""
# Sections that plant a mode-000 dir or file under the fixture HOME (GS-2,
# OCP, AIP, CL-8) restore the mode on their normal path only: a run that
# stops inside that window would leave a tree `rm -rf` cannot enter. The
# modes are re-opened first (chmod -R visits a dir before reading it, so a
# 000 dir is passed; best effort, the removal must still run), and the
# cleanup is also wired to INT / TERM, so a second signal that lands
# while it runs starts it over (modes first) instead of killing it
# halfway (#359 review). The background cases (HI-d3's doctor, the FIFO
# runs of QL-f5's doctor and of OCP-i10's init reporter) do not get the
# suite's INT (a background job of a non-interactive shell ignores it) and
# are past the deadline that would have reaped them, so every process the
# suite started is stopped and reaped before the fixture goes (#413).
cleanup_fixtures() {
  stop_child_trees
  chmod -R u+rwX "$fixture_home" 2>/dev/null || true
  rm -rf "$fixture_home" ${host_stub_dir:+"$host_stub_dir"}
}
trap cleanup_fixtures EXIT
trap 'cleanup_fixtures; trap - INT; kill -INT $$' INT
trap 'cleanup_fixtures; trap - TERM; kill -TERM $$' TERM
[[ -z "${SUITE_INTERRUPT_CUE:-}" ]] || suite_interrupt_inner "$SUITE_INTERRUPT_CUE" "$fixture_home"
# The traps above, checked by interrupting a run of this suite (#413; the
# inner run stops at the line above). Part 1's, like the cases from the
# orphan check on.
if doctor_part 1; then
if check_suite_interrupt "${BASH_SOURCE[0]}" "$fixture_home"; then
  ok "test passed: a suite interrupted while background cases run stops their whole trees and removes its fixture"
else
  fail "test failed: an interrupted suite left processes behind or kept its fixture"
  status=1
fi
fi
host_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-doctor-host-stubs.XXXXXX")"
mkdir -p "$host_stub_dir/bin"
for host_tool in op herdr codex opencode brew npm; do
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
for host_tool in op herdr codex opencode brew npm; do
  if [[ "$(command -v "$host_tool")" != "$host_stub_dir/bin/$host_tool" ]]; then
    fail "test failed: the host-tool stub for $host_tool is not what PATH resolves first"
    exit 1
  fi
done

# ---- part 1 of 3 (TEST_DOCTOR_PART=1): from here to the herdr integration
# cases (HI) ----
if doctor_part 1; then

# doctor_expect LABEL ARGV... -- EXPECT... [! ABSENT_SUBSTRING...]
# One run of ARGV (a doctor command line, or a function that runs one) with
# stderr folded in. It must exit 0 (else doctor_exit_fail); every EXPECT is
# an exact line, or with a leading "~" a substring; after a "!" no
# ABSENT_SUBSTRING may appear (a further "!" only separates). A failure
# shows the output and every miss. Lists are expanded with the
# ${a[@]+"${a[@]}"} guard: bash 3.2 under set -u calls an empty "${a[@]}"
# unbound. Only part 1 uses it (B2 to G, K, M and the gi / hc / ur wrappers
# below), so it is defined here rather than in the shared setup.
doctor_expect() {
  local label="$1" run_args=() want=() absent=() mode=run arg missing="" out rc=0
  shift
  for arg in "$@"; do
    case "$mode:$arg" in
      run:--) mode=want ;;
      run:*) run_args+=("$arg") ;;
      want:! | absent:!) mode=absent ;;
      want:*) want+=("$arg") ;;
      absent:*) absent+=("$arg") ;;
    esac
  done
  out="$("${run_args[@]}" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    doctor_exit_fail "$label" "$rc" "$out"
    return
  fi
  for arg in ${want[@]+"${want[@]}"}; do
    case "$arg" in
      '~'*) grep -Fq -- "${arg#?}" <<< "$out" || missing="${missing}expected text: ${arg#?}"$'\n' ;;
      *) grep -Fxq -- "$arg" <<< "$out" || missing="${missing}expected line: $arg"$'\n' ;;
    esac
  done
  for arg in ${absent[@]+"${absent[@]}"}; do
    if grep -Fq -- "$arg" <<< "$out"; then missing="${missing}unexpected: $arg"$'\n'; fi
  done
  if [[ -z "$missing" ]]; then
    ok "test passed: $label"
  else
    printf '%s\n%s' "$out" "$missing" >&2
    fail "test failed: $label"
    status=1
  fi
}

# Opening fixture: a leftover enforce-mode .npmrc (as after switching
# personal -> work) and unrelated tool data under the ancestor directory of a
# declared file (~/.claude, which .chezmoiignore lets through only as the
# parent of ~/.claude/settings.json, #207) that merely quotes the header
# (Claude Code session logs, paste-cache; #174). Besides an empty standard
# agent root (~/src/agent) nothing is planted yet: no backup marker, no
# agent-tools checkout, no ~/src/personal. One work run and one personal run
# read it, and also carry the assertions that need exactly that empty state:
# the backup "never ran" line (#174), agent-tools absence (E / E2, #258) and
# the standard project roots (#134); the personal run also carries the
# committed SSH agent report (N, #17). Each run checks doctor's exit status
# on its own, so a doctor that exits non-zero shows its output instead of
# stopping the suite under set -e (#378).
printf '# Managed by chezmoi from kosako/dotfiles (npmHardeningMode=enforce).\nignore-scripts=true\n' \
  > "$fixture_home/.npmrc"
mkdir -p "$fixture_home/.claude/projects"
printf 'transcript quoting: Managed by chezmoi from kosako/dotfiles\n' \
  > "$fixture_home/.claude/projects/session.jsonl"
# An empty standard agent root, as E / E2 saw it once the checkout was
# removed: agent-tools absence must be read from the checkout itself, not
# from its parent directory.
mkdir -p "$fixture_home/src/agent"

orphan_marker="orphan from another profile"
agent_dir="$fixture_home/src/agent/agent-tools"

# work: does not manage .npmrc (npmHardeningMode=report) -> orphan; refuses
# backup by design (allowSecretsAccess=false) -> neutral backup item; does not
# deploy agent-tools (enableAgentToolsStatus=false) -> neutral absence item.
# Capture, then grep: `doctor | grep -Fq` dies of SIGPIPE under pipefail when
# grep matches early and the condition reads as "no match" (#143).
doctor_rc=0
output="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" work 2>&1)" || doctor_rc=$?
[[ "$doctor_rc" -eq 0 ]] || doctor_exit_fail "opening fixture, work" "$doctor_rc" "$output"
if grep -F "$orphan_marker" <<< "$output" | grep -Fq ".npmrc"; then
  ok "test passed: orphan .npmrc reported for work"
else
  printf '%s\n' "$output" >&2
  fail "test failed: orphan .npmrc not reported for work"
  status=1
fi
# Only declared file paths are inspected (#174).
if grep -Fq "projects/session.jsonl" <<< "$output"; then
  fail "test failed: work must not report session data under the ancestor directory of a declared file"
  status=1
else
  ok "test passed: session data under the ancestor directory of a declared file ignored (work)"
fi
# Backup "never ran" is an actionable warn only where backup can run (#174).
if grep -Fq "no backup recorded yet" <<< "$output"; then
  fail "test failed: work must not warn about a backup it is designed to refuse"
  status=1
elif grep -Fq "refused for profile work by design" <<< "$output"; then
  ok "test passed: work shows the neutral backup item"
else
  fail "test failed: work backup line missing entirely"
  status=1
fi
# E2) agent-tools absence on work (enableAiPolicy=true, enableAgentToolsStatus=
#     false) is the declared state: a neutral item, never a warning (#258).
if grep -Fxq "[info] - agent-tools not present at $agent_dir (not expected by this profile: enableAgentToolsStatus=false; not auto-cloned)" <<< "$output" \
  && ! grep -Fq "[warn] agent-tools not present" <<< "$output"; then
  ok "test passed: absent agent-tools on work is neutral (no warning)"
else
  printf '%s\n' "$output" >&2
  fail "test failed: absent agent-tools on work was not reported neutrally"
  status=1
fi

# personal: manages .npmrc (npmHardeningMode=enforce) -> not an orphan; may
# back up and has no marker -> the warn; opted in to the agent-tools status
# -> absence is a warn (E); no ~/src/personal -> a neutral item (#134);
# enable1PasswordSSH committed true -> the managed SSH agent (N).
doctor_rc=0
output="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" || doctor_rc=$?
[[ "$doctor_rc" -eq 0 ]] || doctor_exit_fail "opening fixture, personal" "$doctor_rc" "$output"
if grep -Fq "$orphan_marker" <<< "$output"; then
  printf '%s\n' "$output" >&2
  fail "test failed: personal must not report the fixture .npmrc as orphan"
  status=1
else
  ok "test passed: no orphan reported for personal"
fi
if grep -Fq "projects/session.jsonl" <<< "$output"; then
  fail "test failed: personal must not report session data under the ancestor directory of a declared file"
  status=1
else
  ok "test passed: session data under the ancestor directory of a declared file ignored (personal)"
fi
if grep -Fq "no backup recorded yet" <<< "$output"; then
  ok "test passed: personal keeps the no-backup warn"
else
  fail "test failed: personal must warn when no backup is recorded"
  status=1
fi
# E) agent-tools absence on a profile that opted in to its status.
if grep -Fxq "[warn] agent-tools not present at $agent_dir (not auto-cloned)" <<< "$output"; then
  ok "test passed: absent agent-tools warned on personal (opted in), doctor exit 0"
else
  printf '%s\n' "$output" >&2
  fail "test failed: absent agent-tools not warned on personal"
  status=1
fi
# project roots (#134): a missing STANDARD root is a neutral item, never a
# "missing: ..." warning, so repos kept outside ~/src are not nagged.
if grep -Fq "not present (standard root, optional): $fixture_home/src/personal" <<< "$output" \
  && ! grep -Fq "missing: $fixture_home/src/personal" <<< "$output"; then
  ok "test passed: missing standard project root reported neutrally, not as a warning (#134)"
else
  printf '%s\n' "$output" >&2
  fail "test failed: standard project root missing must be neutral (#134), not a warning"
  status=1
fi
# N) enable1PasswordSSH=true with the ssh-1password module active -> managed
#    agent (#17). personal's committed default is true + module present, so
#    no mutation is needed, and a change of that default fails here loudly.
#    The dangling case (O) runs on the signing copy below.
if grep -Fq "managed ~/.ssh/config carries the 1Password agent" <<< "$output"; then
  ok "test passed: enable1PasswordSSH=true reports the managed SSH agent"
else
  printf '%s\n' "$output" >&2
  fail "test failed: managed SSH agent not reported"
  status=1
fi

# A file without the managed-by header is never an orphan.
printf 'registry-noise=1\n' > "$fixture_home/.npmrc"
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

# agent-tools report-only section. Presence is always reported; running
# status.sh is opt-in via enableAgentToolsStatus. doctor must always
# exit 0 and never write. The fake status.sh records that it ran so the
# opt-in gate can be proven.
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
#     The fixture mixes tools and states (C replaces the fake next).
write_root_pinned_status_sh "$agent_scripts/status.sh" \
  '{"contract_version":3,"repo":{"present":true,"clean":true},"assets":{"total":1,"manifest_errors":0},"checks":{"manifest_validation":"pass","prompt_injection_static":"pass"},"generated":{"total":1,"stale":0},"register":{"catalog_present":true,"registered":1,"human_review_required":0,"unsupported":0},"sync_targets":[{"tool":"opencode","name":"p","state":"stale"},{"tool":"codex","name":"c","state":"ok"},{"tool":"claude-code","name":"a","state":"stale"},{"tool":"codex","name":"d","state":"conflict"},{"tool":"claude-code","name":"e","state":"deployed_but_inactive"}]}'
doctor_expect "sync targets are counted per tool (sorted) and each finding names only the tools in that state" \
  env HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal -- \
  "[info] - sync targets: 5 (claude-code 2, codex 2, opencode 1)" \
  "~[warn] agent-tools has stale sync targets (generated artifact newer than target; tools: claude-code, opencode)" \
  "~sync conflicts (unmanaged same-name targets; tools: codex)" \
  "~deployed-but-inactive sync targets (gated entries still on disk; tools: claude-code;"

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
doctor_expect "unknown contract version is not interpreted (exit 0)" \
  env HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal -- "~expected 3 (not interpreting fields)" \
  ! "agent-tools working tree clean" "sync conflicts" "deployed-but-inactive sync targets"

# D) Opt-in + missing status.sh: warning, still exit 0.
rm -f "$agent_scripts/status.sh"
doctor_expect "missing status.sh is a warning (exit 0)" \
  env HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal -- "~status.sh is missing or not executable"

# F) Opt-in + status.sh exits non-zero: warning, still exit 0.
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$agent_scripts/status.sh"
doctor_expect "status.sh failure is a warning (exit 0)" \
  env HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal -- "~no usable output"

# G) Opt-in + 壊れた status JSON: 契約の gate が未知の version と同じく拒否する
#    (yq が何も返さないので contract_version は unknown と読まれる) こと、field を
#    1 つも解釈しないこと、exit 0 を固定する (#332 F58)。C と同じ sentinel の不在も
#    assert する: 壊れた JSON では query が全部空になるので、解釈を続ける doctor は
#    "" を「0 でない」と読んで sync conflicts の warn を出す。
cat > "$agent_scripts/status.sh" <<'SH'
#!/bin/sh
json=0
for a in "$@"; do [ "$a" = "--json" ] && json=1; done
[ "$json" = 1 ] || exit 1
echo 'this is not json {{{'
SH
chmod +x "$agent_scripts/status.sh"
doctor_expect "malformed status JSON is refused as contract_version unknown and not interpreted (exit 0)" \
  env HOME="$fixture_home" "$optin_root/scripts/doctor.sh" personal -- \
  "[warn] agent-tools status contract_version=unknown, expected 3 (not interpreting fields)" \
  ! "agent-tools working tree clean" "sync conflicts" "deployed-but-inactive sync targets"

# E / E2 (agent-tools absent on personal / work) are asserted on the opening
# fixture above, before any checkout exists. Remove the default checkout here
# so the AT-override case below proves doctor read the overridden one.
rm -rf "$agent_dir"

# AT-override) AGENT_TOOLS overrides the expected path (issue #71). The
#    default ~/src/agent/agent-tools is absent (removed just above), so a v3
#    summary plus the run marker proves doctor read the overridden checkout.
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

# H) No marker yet ("no backup recorded yet", personal): asserted on the
#    opening fixture above.

# J) The local supplement is reported by existence only — never parsed or
#    its contents/count shown. A supplement with a recognisable secret-ish
#    line must not have that line (or an entry count) appear in output.
#    Planted here and asserted on I's run below; it stays for the rest.
mkdir -p "$fixture_home/.config/dotfiles"
printf 'backup_paths:\n  - { path: .secret-canary-zzz, type: file }\n' \
  > "$fixture_home/.config/dotfiles/backup-paths.local"

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
  fail "test failed: doctor must stay exit 0 with a backup marker and a local supplement"
  status=1
fi

# I2) capture_incomplete (#242): true -> an action (warn + next-actions step)
#     naming the re-run, exit 0. false -> "capture: complete" is asserted by
#     the three I3 runs below (all their markers carry
#     capture_incomplete:false); the pre-#242 marker in I gives capture:
#     unknown.
printf '{"schema_version":1,"last_success":"2026-06-19T00:00:00Z","archive":"backup.age","file_count":2,"capture_incomplete":true}\n' \
  > "$fixture_home/.local/state/dotfiles/private-backup.json"
if pb_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && grep -Fq "[warn] last backup: 2026-06-19T00:00:00Z (archive: backup.age, files: 2) was INCOMPLETE: a declared directory could not be fully enumerated or an existing file could not be read, so files are missing from that archive" <<< "$pb_out" \
  && grep -Fq "then run ./scripts/private-backup.sh backup again" <<< "$pb_out"; then
  ok "test passed: marker capture_incomplete=true -> INCOMPLETE action with the re-run step (exit 0)"
else
  printf '%s\n' "$pb_out" >&2
  fail "test failed: marker capture_incomplete=true not reported as an INCOMPLETE action"
  status=1
fi
# I3) An archive name that starts with "-" (#444): `private-backup.sh backup
#     --out ./-archive.age` records "-archive.age" (test-private-backup pins
#     that). doctor passed it to basename without "--", which read it as an
#     option and failed, and the failure ended doctor under set -e: exit 1,
#     no report after the backup section and no next actions. The name must
#     be shown as is and doctor must run to the end; the backup.age runs
#     above are the control. A value with directories (a hand-edited marker:
#     backup records the file name only) shows its last component and never
#     the directories, and a value that leaves no file name (ending in "/")
#     is unknown.
printf '{"schema_version":1,"last_success":"2026-06-19T00:00:00Z","archive":"-archive.age","file_count":2,"capture_incomplete":false}\n' \
  > "$fixture_home/.local/state/dotfiles/private-backup.json"
pb_rc=0
pb_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" || pb_rc=$?
if [[ "$pb_rc" -eq 0 ]] \
  && grep -Fq "[ok] last backup: 2026-06-19T00:00:00Z (archive: -archive.age, files: 2, capture: complete)" <<< "$pb_out" \
  && grep -Fq "[info] == next actions (" <<< "$pb_out"; then
  ok "test passed: a marker archive name that starts with \"-\" is shown as is and doctor runs to the next actions (exit 0, #444)"
else
  printf '%s\n' "$pb_out" >&2
  fail "test failed: a marker archive name that starts with \"-\" must not stop doctor (rc=$pb_rc, #444)"
  status=1
fi
printf '{"schema_version":1,"last_success":"2026-06-19T00:00:00Z","archive":"%s","file_count":2,"capture_incomplete":false}\n' \
  "$fixture_home/backups/2026/backup.age" > "$fixture_home/.local/state/dotfiles/private-backup.json"
pb_rc=0
pb_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" || pb_rc=$?
if [[ "$pb_rc" -eq 0 ]] \
  && grep -Fq "[ok] last backup: 2026-06-19T00:00:00Z (archive: backup.age, files: 2, capture: complete)" <<< "$pb_out" \
  && ! grep -Fq "backups/2026" <<< "$pb_out"; then
  ok "test passed: a marker archive value with directories shows only its file name (#444)"
else
  printf '%s\n' "$pb_out" >&2
  fail "test failed: a marker archive value with directories must show only its file name, not the directories (rc=$pb_rc, #444)"
  status=1
fi
printf '{"schema_version":1,"last_success":"2026-06-19T00:00:00Z","archive":"old/","file_count":2,"capture_incomplete":false}\n' \
  > "$fixture_home/.local/state/dotfiles/private-backup.json"
pb_rc=0
pb_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" || pb_rc=$?
if [[ "$pb_rc" -eq 0 ]] \
  && grep -Fq "[ok] last backup: 2026-06-19T00:00:00Z (archive: unknown, files: 2, capture: complete)" <<< "$pb_out"; then
  ok "test passed: a marker archive value that leaves no file name is shown as unknown (#444)"
else
  printf '%s\n' "$pb_out" >&2
  fail "test failed: a marker archive value ending in \"/\" must be shown as unknown (rc=$pb_rc, #444)"
  status=1
fi

# K) A malformed/null marker must not break doctor: report "unreadable"
#    and stay exit 0 (guards the set -euo pipefail paths in the section).
printf 'this is not valid json {{{\n' \
  > "$fixture_home/.local/state/dotfiles/private-backup.json"
doctor_expect "malformed backup marker reported unreadable (exit 0)" \
  env HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal -- "~backup marker present but unreadable"

# Git signing (enableGitSigning, #85) and SSH 1Password agent
# (enable1PasswordSSH, #17) reports. doctor stays report-only / exit 0 and
# must reflect the active and the dangling (capability true but module
# inactive) cases of each. One throwaway repo copy with both capabilities
# forced true, so the cases do not depend on the committed defaults and the
# edits do not touch the real data files. The active SSH agent (N) is
# asserted on the committed personal run of the opening fixture.
sign_root="$fixture_home/.dotfiles-signing"
copy_repo_fixture "$sign_root"
set_capability_all "$sign_root" enableGitSigning true
set_capability_all "$sign_root" enable1PasswordSSH true
# L + O) ssh-1password removed, git-signing kept: one run shows the managed
#        signing mechanism AND the dangling SSH agent. Each section must read
#        its own module: drop both before this run and a section that reads
#        the other's module would still pass.
remove_module_all "$sign_root" ssh-1password
if sg_out="$(HOME="$fixture_home" "$sign_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "SSH signing mechanism managed" <<< "$sg_out"; then
    ok "test passed: enableGitSigning=true reports the managed signing mechanism"
  else
    printf '%s\n' "$sg_out" >&2
    fail "test failed: managed signing mechanism not reported"
    status=1
  fi
  if grep -Fq "ssh-1password module is inactive" <<< "$sg_out"; then
    ok "test passed: enable1PasswordSSH=true with module inactive is reported as dangling"
  else
    printf '%s\n' "$sg_out" >&2
    fail "test failed: dangling enable1PasswordSSH not reported"
    status=1
  fi
else
  printf '%s\n' "$sg_out" >&2
  fail "test failed: doctor must stay exit 0 (enableGitSigning=true module active; enable1PasswordSSH dangling)"
  status=1
fi
# M) git-signing removed as well -> dangling signing warning, still exit 0.
remove_module_all "$sign_root" git-signing
doctor_expect "enableGitSigning=true with module inactive is reported as dangling" \
  env HOME="$fixture_home" "$sign_root/scripts/doctor.sh" personal -- "~git-signing module is inactive"

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
# gi_doctor PROFILE [VAR=value...] — one hermetic doctor run; extra env words
# for it, GIT_CONFIG_NOSYSTEM=1 when none are given.
gi_doctor() {
  local profile="$1"
  shift
  [[ $# -gt 0 ]] || set -- GIT_CONFIG_NOSYSTEM=1
  env -i PATH="$PATH" HOME="$gi_home" "$@" "$SCRIPT_DIR/doctor.sh" "$profile"
}
# gi_check PROFILE EXPECT_LINE LABEL [VAR=value...] — doctor_expect on one
# gi_doctor run.
gi_check() {
  doctor_expect "global gitignore $3" gi_doctor "$1" "${@:4}" -- "$2"
}
rm -rf "$gi_home"
mkdir -p "$gi_home/.config/git"
# GI-1) managed file present and read by git -> ok.
cp "$DOTFILES_ROOT/private_dot_config/git/ignore" "$gi_managed"
gi_check personal "[ok] global gitignore: managed $gi_managed is what git reads; excludes .agent-packets/ and **/.claude/settings.local.json in every repo" "managed file in effect -> ok"
# GI-2) missing -> action (mkdir then apply, %q-escaped like the identity
#       reset): the warn line and the two steps, consecutive, from one run.
rm -f "$gi_managed"
if out="$(env -i PATH="$PATH" HOME="$gi_home" GIT_CONFIG_NOSYSTEM=1 "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && grep -Fxq -- "[warn] global gitignore missing: $gi_managed (git-ignore module) — agent local-only files (.agent-packets/, .claude/settings.local.json) are excluded only where a repo's own .gitignore says so" <<< "$out" \
  && steps_consecutive "$out" "        \$ mkdir -p $(printf '%q' "$gi_home/.config")" \
    "        \$ chezmoi apply $(printf '%q' "$gi_home/.config/git") $(printf '%q' "$gi_managed")"; then
  ok "test passed: global gitignore missing -> action, steps mkdir then apply, consecutive and %q-escaped"
else
  printf '%s\n' "${out:-<no output>}" >&2
  fail "test failed: global gitignore missing -> expected the action line and the mkdir step immediately followed by the apply step"
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
#         symlink to ~/.config (-ef) — no false redirect warn (#309). doctor
#         compares only while the file exists, where -ef already matches the
#         slashed spelling, so the stripping is pinned on the helper itself.
gi_ok="[ok] global gitignore: managed $gi_managed is what git reads; excludes .agent-packets/ and **/.claude/settings.local.json in every repo"
if [[ "$(XDG_CONFIG_HOME="$gi_home/.config//" git_default_excludes_file)" == "$gi_managed" ]]; then
  ok "test passed: global gitignore XDG_CONFIG_HOME=~/.config// resolves to the managed path (every trailing slash stripped)"
else
  fail "test failed: global gitignore XDG_CONFIG_HOME=~/.config// must resolve to $gi_managed"
  status=1
fi
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
# ~/.config spelled with a trailing slash (pinned while the file is missing,
# where -ef cannot help) or through a symlink (pinned while it is present) is
# the same file, not a redirect; and the module-inactive profile (work).
# `herdr config check` comes from a PATH-front fake whose exit status the
# case sets (the real herdr may or may not be on PATH). Every run is
# hermetic (`env -i`), so the developer shell's HERDR_CONFIG_PATH /
# XDG_CONFIG_HOME cannot leak in.
hc_home="$fixture_home/hc"
hc_managed="$hc_home/.config/herdr/config.toml"
hc_fakebin="$fixture_home/hcfake"
mkdir -p "$hc_fakebin"
# write_fake_herdr_config_check RC [LINE] — `herdr config check` prints LINE
# (if given) and exits RC; anything else (the integration section's `herdr
# integration status`) exits 0 silently.
write_fake_herdr_config_check() {
  cat > "$hc_fakebin/herdr" <<SH
#!/bin/sh
if [ "\$1" = config ] && [ "\$2" = check ]; then [ -n "${2:-}" ] && printf '%s\n' "${2:-}"; exit $1; fi
exit 0
SH
  chmod +x "$hc_fakebin/herdr"
}
# hc_doctor PROFILE [VAR=value...] — one hermetic doctor run, the fake herdr
# first on PATH.
hc_doctor() {
  local profile="$1"
  shift
  env -i PATH="$hc_fakebin:$PATH" HOME="$hc_home" "$@" "$SCRIPT_DIR/doctor.sh" "$profile"
}
# hc_run PROFILE [VAR=value...] — doctor output in hc_out; returns doctor's status.
hc_run() {
  hc_out="$(hc_doctor "$@" 2>&1)"
}
# hc_expect LABEL PROFILE [VAR=value...] -- EXPECT_LINE... [! ABSENT_SUBSTRING...]
# doctor_expect on one hc_doctor run.
hc_expect() {
  doctor_expect "herdr config $1" hc_doctor "${@:2}"
}
# hc_check LABEL EXPECT_LINE PROFILE [VAR=value...]
hc_check() {
  hc_expect "$1" "${@:3}" -- "$2"
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
#       The fake prints `__rc=0` before its exit 1 (HC-2b).
write_fake_herdr_config_check 1 "__rc=0"
hc_expect "rejected (even after printing __rc=0) -> action with the herdr config check step in next actions" personal -- \
  "[warn] herdr config: herdr config check did not pass for the managed $hc_managed (exit 1) — on a parse error herdr runs on ALL defaults, so agent state changes raise no OS notification; read its diagnostics, then fix the managed file" \
  "        \$ herdr config check"
# HC-2b) the probed command cannot pass for its own exit status (#335): a
#        line it prints that looks like the probe's old status line is its
#        output, so `__rc=0` before exit 1 is still a failure (HC-2's fake),
#        and `__rc=` followed by a terminal escape is never shown as the
#        status.
write_fake_herdr_config_check 3 "__rc="$'\033'"[2J"
if hc_run personal \
  && grep -Fq "[warn] herdr config: herdr config check did not pass for the managed $hc_managed (exit 3)" <<< "$hc_out" \
  && ! grep -Fq $'\033' <<< "$hc_out"; then
  ok "test passed: a printed __rc= line with a terminal escape is not taken as the status (exit 3 shown, no raw escape)"
else
  printf '%s\n' "$hc_out" | LC_ALL=C cat -v >&2
  fail "test failed: a probed command's own __rc= line was taken as its exit status"
  status=1
fi
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
# HC-5) XDG_CONFIG_HOME through a symlink to ~/.config is the managed file
#       (-ef, #307): no redirect warning and the check runs. The
#       trailing-slash spelling is HC-3c: while the file exists, -ef matches
#       it too.
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
# ur_doctor_run PROFILE [VAR=value...] — one hermetic run of $ur_doctor (read
# at call time: UR-7 points it at the opt-out copy).
ur_doctor_run() {
  local profile="$1"
  shift
  env -i PATH="$PATH" HOME="$ur_home" "$@" "$ur_doctor" "$profile"
}
# ur_expect LABEL PROFILE [VAR=value...] -- EXPECT_LINE... [! ABSENT_SUBSTRING...]
# doctor_expect on one ur_doctor_run run; the canary never may appear.
ur_expect() {
  doctor_expect "usage reader $1" ur_doctor_run "${@:2}" ! "$ur_canary"
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
# UR-1a) missing with XDG_CONFIG_HOME naming ~/.config with a trailing slash:
#        the same location (no -ef possible while the file is missing), so no
#        redirect warn and the plain missing action.
ur_expect "missing + XDG_CONFIG_HOME=~/.config/ -> plain missing action, no redirect" \
  personal XDG_CONFIG_HOME="$ur_home/.config/" -- "$ur_missing" ! "points agent-tools at"
# UR-1b) missing while an absolute XDG_CONFIG_HOME points elsewhere: the
#        redirect is reported and the missing action does not claim the
#        "no usage reader" effect (the other file may hold one).
ur_expect "missing + XDG_CONFIG_HOME elsewhere -> redirect warn and redirect-aware missing action" \
  personal XDG_CONFIG_HOME="$ur_home/xdg" -- \
  "$(ur_redirect_line "$ur_home/xdg/agent-tools/usage-reader.json")" \
  "[warn] usage reader config missing: $ur_config (agent-tools-usage-reader module) — restoring it takes effect only once the redirect above is gone" \
  ! "assignment ignores the remaining budget"
# UR-2) --check accepts -> ok, values never shown; doctor adopts the
#       wrapper's verdict instead of judging the shape itself, so a file that
#       is not JSON but that --check accepts is ok (the canary-in-JSON ok runs
#       are UR-2c/2d).
ur_write "not json $ur_canary"
ur_fake 0 "$ur_usage" 0
ur_expect "--check exit 0 -> ok, whatever the file holds (the wrapper decides, not doctor)" personal -- "$ur_ok" ! "contract not checked"
ur_asked_check "--check exit 0 -> --check run" yes
ur_write "$ur_valid"
# UR-2c) a relative XDG_CONFIG_HOME is ignored (as the wrapper does).
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
# UR-3b) terminal control in the reason is shown as ? (another repo's output,
#        through display_safe, #335).
ur_fake 0 "$ur_usage" 2 "personal-usage-reader: bad"$'\033'"[31m value"$'\r'
ur_expect "--check reason with terminal control -> shown as ?" personal -- \
  "[warn] usage reader config $ur_config rejected by personal-usage-reader --check (bad?[31m value?) — personal-usage-reader fails (exit 2), so agent-tools reads no budget"
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

# GitHub injection guard report (gateGitHubMcp / enableGitHubIsolatedReader, #119).
# gateGitHubMcp is wired (PR2: MCP deny in managed settings.json); doctor must
# report it as enforced when active. enableGitHubIsolatedReader is wired too
# (#137: PreToolUse hook registration in managed settings.json); doctor reports
# the registration plus the agent-tools-deployed body's presence (absent ->
# fail-open no-op warn). doctor stays exit 0 (no dead capability).
# Throwaway repo copy so the flip does not touch the real data files.
gh_root="$fixture_home/.dotfiles-ghguard"
copy_repo_fixture "$gh_root"
gh_secret_floor_declared='[ok] secret floor declared: managed ~/.claude/settings.json denies SSH-key / credential-store / env-dump / gh-secret reads unconditionally (best-effort, not a boundary; live drift shows in "managed drift")'

# P) committed personal: gateGitHubMcp AND enableGitHubIsolatedReader are ON
#    (Phase 2 / #137) and claude-settings is active, so doctor reports the
#    github MCP server denied and the PreToolUse hook registered. The fixture
#    HOME has no agent-tools deployment, so the hook body is absent -> the
#    body-absent warn (fail-open no-op), and doctor stays exit 0 (report-only).
#    Check all so the section can't silently drop one (dead-capability guard).
#    The run stays in committed_out, which no later case overwrites: P1, P1b,
#    P2 and QL-a read the committed state from it.
if committed_out="$(HOME="$fixture_home" "$gh_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "denies the github MCP server" <<< "$committed_out" \
    && grep -Fq "hook registered in managed settings.json but the body is absent" <<< "$committed_out" \
    && grep -Fq "registered in managed ~/.codex/hooks.json but the body is absent" <<< "$committed_out" \
    && grep -Fxq "$gh_secret_floor_declared" <<< "$committed_out" \
    && ! grep -Fq "secret floor active" <<< "$committed_out" \
    && grep -Fq "human-legit write gate INERT" <<< "$committed_out"; then
    ok "test passed: MCP deny + secret floor declared + human-legit gate inert + Claude & Codex hooks registered with absent bodies warned (fail-open)"
  else
    printf '%s\n' "$committed_out" >&2
    fail "test failed: GitHub guard capability not reported"
    status=1
  fi
else
  printf '%s\n' "$committed_out" >&2
  fail "test failed: doctor must stay exit 0 (GitHub guard, default)"
  status=1
fi

# P1) Claude MCP exposure (#341): committed personal has gateUnusedClaudeMcp ON
#     with claude-settings active, so doctor reports the deny; flipped off (CO
#     below) it reports the declared-off state. Both stay exit 0 (report-only).
if grep -Fq "gateUnusedClaudeMcp=true; managed ~/.claude/settings.json denies the claude.ai Gmail" <<< "$committed_out"; then
  ok "test passed: gateUnusedClaudeMcp=true reported as wired in managed settings.json"
else
  fail "test failed: gateUnusedClaudeMcp=true not reported"
  status=1
fi

# P1b) tool call record hook (#353): committed personal has
#      enableToolCallRecordHook ON with claude-settings active, so doctor reports
#      the registration; flipped off (CO below) it reports the declared-off
#      state. Both stay exit 0 (report-only).
if grep -Fq "enableToolCallRecordHook=true; managed ~/.claude/settings.json registers personal-tool-call-record-hook" <<< "$committed_out"; then
  ok "test passed: enableToolCallRecordHook=true reported as wired in managed settings.json"
else
  fail "test failed: enableToolCallRecordHook=true not reported"
  status=1
fi

# CO) the capabilities whose off branch is one report line of its own section,
#     flipped off together in one copy for one doctor run (none is a module
#     `requires`, so the flips do not interact; each section reads only its
#     own capability). doctor stays exit 0 (report-only):
#     - gateUnusedClaudeMcp (P1) and enableToolCallRecordHook (P1b): the
#       declared-off state.
#     - enableDirenv (DR, #401): the report says the check is skipped and that
#       the shell hook still runs, not that direnv is off (the managed ~/.zshrc
#       registers the hook wherever direnv is installed).
#     - gateGitHubMcp: not active, and no github MCP deny claimed.
#     - enableQualityLoopHooks (QL-d): nothing lingers in the live files here,
#       so the not-wired ok line and none of the wired / dangling lines
#       (dead-capability guard in the other direction). Both live files are
#       absent under a home directory doctor can enter (~/.claude holds the
#       opening fixture's session data, ~/.codex is made here as QL-d had
#       it), so the absence is confirmed through the parent in both homes;
#       QL-f7 is the contrast with the parent missing or not a directory.
caps_off_root="$fixture_home/.dotfiles-caps-off"
copy_repo_fixture "$caps_off_root"
for caps_off_cap in gateUnusedClaudeMcp enableToolCallRecordHook enableDirenv gateGitHubMcp enableQualityLoopHooks; do
  set_capability_all "$caps_off_root" "$caps_off_cap" false
done
mkdir -p "$fixture_home/.codex"
caps_off_rc=0
caps_off_out="$(HOME="$fixture_home" "$caps_off_root/scripts/doctor.sh" personal 2>&1)" || caps_off_rc=$?
if [[ "$caps_off_rc" -ne 0 ]]; then
  doctor_exit_fail "capabilities flipped off" "$caps_off_rc" "$caps_off_out"
else
  if grep -Fq "gateUnusedClaudeMcp not active (false)" <<< "$caps_off_out"; then
    ok "test passed: gateUnusedClaudeMcp=false reported as not active"
  else
    printf '%s\n' "$caps_off_out" >&2
    fail "test failed: gateUnusedClaudeMcp=false not reported"
    status=1
  fi
  if grep -Fq "enableToolCallRecordHook not active (false)" <<< "$caps_off_out"; then
    ok "test passed: enableToolCallRecordHook=false reported as not active"
  else
    printf '%s\n' "$caps_off_out" >&2
    fail "test failed: enableToolCallRecordHook=false not reported"
    status=1
  fi
  if grep -Fxq "[info] - direnv check skipped for profile (enableDirenv=false selects the check only; the shell hook still loads an allowed .envrc wherever direnv is installed)" <<< "$caps_off_out" \
    && ! grep -Fq "direnv disabled" <<< "$caps_off_out"; then
    ok "test passed: enableDirenv=false reports the skipped check and the hook that still runs, not direnv off"
  else
    printf '%s\n' "$caps_off_out" >&2
    fail "test failed: enableDirenv=false must report the skipped check without saying direnv is off"
    status=1
  fi
  if grep -Fxq "[ok] gateGitHubMcp not active (false)" <<< "$caps_off_out" \
    && ! grep -Fq "denies the github MCP server" <<< "$caps_off_out"; then
    ok "test passed: gateGitHubMcp=false reported as not active, with no MCP deny claimed"
  else
    printf '%s\n' "$caps_off_out" >&2
    fail "test failed: gateGitHubMcp=false not reported, or the github MCP deny still claimed"
    status=1
  fi
  if grep -Fq "quality loop hooks not wired (enableQualityLoopHooks=false)" <<< "$caps_off_out" \
    && ! grep -Fq "enableQualityLoopHooks=true" <<< "$caps_off_out"; then
    ok "test passed: enableQualityLoopHooks=false reports not wired and nothing else"
  else
    printf '%s\n' "$caps_off_out" >&2
    fail "test failed: enableQualityLoopHooks=false state not reported cleanly"
    status=1
  fi
fi

# P2) trust list (#119 PR3): the injection-guard section points to the
#     non-committed trust list, and the private-backup section reports its
#     presence contents-blind (it is in backup-paths.yaml). The fixture HOME has
#     no trust list, so it must show as a baseline-absent target. Reads case
#     P's committed_out.
if grep -Fq "trust list: ~/.config/dotfiles/github-trust.local" <<< "$committed_out" \
  && grep -Fq "baseline absent: .config/dotfiles/github-trust.local" <<< "$committed_out"; then
  ok "test passed: trust list wired (injection-guard pointer + backup catalog presence, contents-blind)"
else
  printf '%s\n' "$committed_out" >&2
  fail "test failed: trust list pointer or backup-catalog presence not reported"
  status=1
fi

# P3 + Q) the trust list and both safe-gh hook bodies PRESENT, under the
#     committed personal capabilities (gateGitHubMcp and
#     enableGitHubIsolatedReader ON, case P). One run, because the two files
#     feed separate sections (the trust list the private-backup catalog, the
#     bodies the two hook lines). Clean up after so later cases see the
#     absent state again.
#     P3) doctor must report the trust list present via the backup catalog
#         but NEVER echo its contents (contents-blind even when the file
#         exists). A canary line catches a regression that read/leaked it.
#     Q) with each hook body present (executable), the isolated-reader line
#        flips from the body-absent warn (case P) to the wired ok. Presence
#        is reported contents-blind (doctor never reads the body).
mkdir -p "$fixture_home/.config/dotfiles"
printf 'trusted-login = CANARY_TRUST_LEAK_7f3a\n' \
  > "$fixture_home/.config/dotfiles/github-trust.local"
mkdir -p "$fixture_home/.claude/agent-tools/scripts"
printf '#!/bin/sh\nexit 0\n' > "$fixture_home/.claude/agent-tools/scripts/personal-safe-gh-hook"
chmod +x "$fixture_home/.claude/agent-tools/scripts/personal-safe-gh-hook"
# Codex parity (#181): deploy the Codex-home body too so the codex-settings line
# flips to its wired ok (present, contents-blind). Its stable path mirrors the
# Claude one under ~/.codex (agent-tools#146).
mkdir -p "$fixture_home/.codex/agent-tools/scripts"
printf '#!/bin/sh\nexit 0\n' > "$fixture_home/.codex/agent-tools/scripts/personal-safe-gh-hook"
chmod +x "$fixture_home/.codex/agent-tools/scripts/personal-safe-gh-hook"
present_rc=0
present_out="$(HOME="$fixture_home" "$gh_root/scripts/doctor.sh" personal 2>&1)" || present_rc=$?
if [[ "$present_rc" -ne 0 ]]; then
  doctor_exit_fail "trust list and hook bodies present" "$present_rc" "$present_out"
else
  if grep -Fq "baseline present: .config/dotfiles/github-trust.local" <<< "$present_out" \
    && ! grep -Fq "CANARY_TRUST_LEAK_7f3a" <<< "$present_out"; then
    ok "test passed: trust list present reported, contents never echoed (contents-blind)"
  else
    printf '%s\n' "$present_out" >&2
    fail "test failed: trust list present-state or contents-blind invariant not held"
    status=1
  fi
  if grep -Fq "managed settings.json registers the PreToolUse hook -> safe-gh steering (fail-open, not a boundary); hook body present" <<< "$present_out" \
    && grep -Fq "managed ~/.codex/hooks.json registers the PreToolUse hook -> safe-gh steering (fail-open, not a boundary); hook body present" <<< "$present_out"; then
    ok "test passed: Claude & Codex hook registration + present bodies reported as wired steering"
  else
    printf '%s\n' "$present_out" >&2
    fail "test failed: isolated-reader (Claude/Codex) wired state not reported with the bodies present"
    status=1
  fi
fi
rm -f "$fixture_home/.config/dotfiles/github-trust.local"
rm -f "$fixture_home/.claude/agent-tools/scripts/personal-safe-gh-hook"
rm -f "$fixture_home/.codex/agent-tools/scripts/personal-safe-gh-hook"

# R) enforceAiSandbox=true: the injection-guard section discloses the human-legit
#    write gate as ACTIVE (it rides on enforceAiSandbox), with the always-on secret
#    floor declared too. Covers the other branch; case P covered the inert
#    (enforceAiSandbox=false) branch. Its own run, so the flip never couples
#    to the cases above. exit 0.
set_capability_all "$gh_root" enforceAiSandbox true
if gh_out="$(HOME="$fixture_home" "$gh_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "human-legit write gate active" <<< "$gh_out" \
    && grep -Fxq "$gh_secret_floor_declared" <<< "$gh_out" \
    && ! grep -Fq "secret floor active" <<< "$gh_out"; then
    ok "test passed: enforceAiSandbox=true -> human-legit write gate active (secret floor declared too)"
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
#     commands the hooks run). Own fixture copy from QL-b on, so the flips
#     here never couple to the injection-guard cases above. doctor stays
#     exit 0 throughout (report-only).
ql_root="$fixture_home/.dotfiles-qlhooks"
copy_repo_fixture "$ql_root"
ql_claude="$fixture_home/.claude/agent-tools/scripts"
ql_codex="$fixture_home/.codex/agent-tools/scripts"
#     QL-a) no bodies deployed, no checks file -> both homes warn body-absent
#           (fail-open no-op) and the checks-absent item shows. That is the
#           committed state case P ran (its exit 0 is checked there), so
#           this reads committed_out instead of running doctor again; keep
#           it in case P's part.
if grep -Fq "managed ~/.claude/settings.json registers the quality-loop hooks but a body is absent or non-executable: personal-fast-edit-check personal-changed-scope-qa" <<< "$committed_out" \
  && grep -Fq "managed ~/.codex/hooks.json registers the quality-loop hooks but a body is absent or non-executable: personal-fast-edit-check personal-changed-scope-qa" <<< "$committed_out" \
  && grep -Fq "checks.local.json absent" <<< "$committed_out"; then
  ok "test passed: quality-loop hooks registered in both homes with absent bodies warned (fail-open) and no check declaration reported"
else
  printf '%s\n' "$committed_out" >&2
  fail "test failed: quality-loop hooks absent-body / absent-declaration state not reported"
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
#     QL-d) capability off from here on (its not-wired ok with nothing left
#           in the live files is checked in CO above).
set_capability_all "$ql_root" enableQualityLoopHooks false
#     QL-d2) capability off but a registration LINGERS in the live files (a
#            flip not yet applied here; after a profile switch, QL-f):
#            doctor must warn instead of the not-wired ok, naming the file
#            and, as codex-settings is active, the apply that removes it,
#            and must not echo the file's contents (canary). Codex review,
#            PR #200.
mkdir -p "$fixture_home/.claude" "$fixture_home/.codex"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/.codex/agent-tools/scripts/personal-changed-scope-qa"}]}]},"CANARY_LINGER_LEAK_9c2d":true}\n' \
  > "$fixture_home/.codex/hooks.json"
if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[warn] enableQualityLoopHooks=false but a quality-loop hook registration lingers in $fixture_home/.codex/hooks.json (this profile manages the file) — run chezmoi apply to remove it" <<< "$ql_out" \
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
#     QL-e2) the same run: the other Claude-side capabilities committed true
#            each report their own dangling warn (no managed settings.json
#            carries them), and the injection-guard tiers that describe the
#            managed file (secret floor, human-legit gate, main-push note)
#            are not reported.
for ql_dangling in \
  "gateUnusedClaudeMcp=true but the claude-settings module is inactive for this profile; no managed settings carry the MCP deny (dangling capability)" \
  "enableToolCallRecordHook=true but the claude-settings module is inactive for this profile; no managed settings carry the record hook (dangling capability)" \
  "gateGitHubMcp=true but the claude-settings module is inactive for this profile; no managed settings carry the MCP deny (dangling capability)" \
  "enableGitHubIsolatedReader=true but the claude-settings module is inactive for this profile; no managed settings carry the hook registration (dangling capability)"; do
  if grep -Fxq "[warn] $ql_dangling" <<< "$ql_out"; then
    ok "test passed: ${ql_dangling%% but *} with claude-settings inactive is reported as dangling"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: dangling ${ql_dangling%% but *} not reported (missing: [warn] $ql_dangling)"
    status=1
  fi
done
if ! grep -Fq "secret floor declared" <<< "$ql_out" \
  && ! grep -Fq "human-legit write gate" <<< "$ql_out" \
  && ! grep -Fq "main-push deny is leaky steering" <<< "$ql_out"; then
  ok "test passed: with claude-settings inactive the secret floor / human-legit gate / main-push note are not reported"
else
  printf '%s\n' "$ql_out" >&2
  fail "test failed: the injection-guard tiers of the managed settings.json are reported with claude-settings inactive"
  status=1
fi
#     QL-f) after a profile switch (#201): both hook capabilities off and
#           claude-settings inactive (still removed above), with the safe-gh
#           and quality-loop registrations left in both live files. Each
#           file gets one action per capability: the unmanaged Claude file
#           says apply will not remove it, the managed Codex file names the
#           apply; no not-wired / not-active ok, and no file contents
#           (canary). With the files gone both ok lines come back (QL-f7;
#           CO / QL-f4 for a file absent under its directory).
set_capability_all "$ql_root" enableQualityLoopHooks false
set_capability_all "$ql_root" enableGitHubIsolatedReader false
for ql_live in "$fixture_home/.claude/settings.json" "$fixture_home/.codex/hooks.json"; do
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/x/agent-tools/scripts/personal-safe-gh-hook"}]}],"Stop":[{"hooks":[{"type":"command","command":"/x/agent-tools/scripts/personal-changed-scope-qa"}]}]},"CANARY_SWITCH_LEAK_4e7a":true}\n' \
    > "$ql_live"
done
ql_unmanaged="(applied by another profile; this profile does not manage the file, so apply will not remove it) — remove the hooks or the file by hand"
ql_managed="(this profile manages the file) — run chezmoi apply to remove it"
if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[warn] enableGitHubIsolatedReader=false but a safe-gh hook registration lingers in $fixture_home/.claude/settings.json $ql_unmanaged" <<< "$ql_out" \
    && grep -Fxq "[warn] enableGitHubIsolatedReader=false but a safe-gh hook registration lingers in $fixture_home/.codex/hooks.json $ql_managed" <<< "$ql_out" \
    && grep -Fxq "[warn] enableQualityLoopHooks=false but a quality-loop hook registration lingers in $fixture_home/.claude/settings.json $ql_unmanaged" <<< "$ql_out" \
    && grep -Fxq "[warn] enableQualityLoopHooks=false but a quality-loop hook registration lingers in $fixture_home/.codex/hooks.json $ql_managed" <<< "$ql_out" \
    && ! grep -Fq "enableGitHubIsolatedReader not active (false)" <<< "$ql_out" \
    && ! grep -Fq "quality loop hooks not wired (enableQualityLoopHooks=false)" <<< "$ql_out" \
    && ! grep -Fq "CANARY_SWITCH_LEAK_4e7a" <<< "$ql_out"; then
    ok "test passed: hook registrations left by a profile switch warn per file and capability, naming apply only where this profile manages the file (contents never echoed)"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: hook registrations left by a profile switch not warned per file with the right remedy, or a file was echoed"
    status=1
  fi
else
  printf '%s\n' "$ql_out" >&2
  fail "test failed: doctor must stay exit 0 (hook registrations left by a profile switch)"
  status=1
fi
#     QL-f2) the same state under --actions-only: each lingering file is a
#            next action with its remedy (apply for the managed Codex file;
#            hand removal, quoted path and the herdr re-install note for the
#            Claude one), and nothing else is printed.
ql_claude_q="$(LC_ALL=C printf '%q' "$fixture_home/.claude/settings.json")"
if ql_only="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal --actions-only 2>&1)"; then
  if grep -Eq "^\[info\] [0-9]+\. enableGitHubIsolatedReader=false but a safe-gh hook registration lingers in " <<< "$ql_only" \
    && grep -Fq ". enableGitHubIsolatedReader=false but a safe-gh hook registration lingers in $fixture_home/.claude/settings.json $ql_unmanaged" <<< "$ql_only" \
    && grep -Fq ". enableQualityLoopHooks=false but a quality-loop hook registration lingers in $fixture_home/.codex/hooks.json $ql_managed" <<< "$ql_only" \
    && grep -Fxq "        edit $ql_claude_q and delete the hook entries that run personal-safe-gh-hook, keeping the rest of the file" <<< "$ql_only" \
    && grep -Fxq "        edit $ql_claude_q and delete the hook entries that run personal-fast-edit-check or personal-changed-scope-qa, keeping the rest of the file" <<< "$ql_only" \
    && grep -Fxq "        or remove the whole file: \$ rm -i $ql_claude_q   # then re-run herdr integration install claude if herdr's hook was registered there" <<< "$ql_only" \
    && grep -Fxq "        \$ chezmoi apply" <<< "$ql_only" \
    && ! grep -q -E '^\[(ok|warn)\]' <<< "$ql_only" \
    && ! grep -Fq "CANARY_SWITCH_LEAK_4e7a" <<< "$ql_only"; then
    ok "test passed: lingering hook registrations reach --actions-only as next actions with their remedies"
  else
    printf '%s\n' "$ql_only" >&2
    fail "test failed: lingering hook registrations missing from --actions-only, or their remedies wrong"
    status=1
  fi
else
  printf '%s\n' "$ql_only" >&2
  fail "test failed: doctor must stay exit 0 (lingering hook registrations, --actions-only)"
  status=1
fi
#     QL-f4) only the PostToolUse half of the quality loop left (fast-edit-
#            check, no Stop entry): still a lingering registration (Codex
#            review R2, #201), and the safe-gh hook is not reported.
rm -f "$fixture_home/.codex/hooks.json"
printf '{"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"/x/agent-tools/scripts/personal-fast-edit-check"}]}]}}\n' \
  > "$fixture_home/.claude/settings.json"
if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[warn] enableQualityLoopHooks=false but a quality-loop hook registration lingers in $fixture_home/.claude/settings.json $ql_unmanaged" <<< "$ql_out" \
    && grep -Fxq "[ok] enableGitHubIsolatedReader not active (false)" <<< "$ql_out" \
    && ! grep -Fq "quality loop hooks not wired (enableQualityLoopHooks=false)" <<< "$ql_out"; then
    ok "test passed: a lingering fast-edit-check registration alone counts as a lingering quality-loop hook"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: a lingering fast-edit-check registration alone was not reported"
    status=1
  fi
else
  printf '%s\n' "$ql_out" >&2
  fail "test failed: doctor must stay exit 0 (lingering fast-edit-check registration)"
  status=1
fi
#     QL-f3) a live file that is there but cannot be read: the registration is
#            unchecked, so doctor warns that per capability instead of either
#            ok line. Skipped as root (root reads mode 000).
ql_unchecked="is not a regular file or could not be read, so a lingering"
if [[ "$(id -u)" != "0" ]]; then
  chmod 000 "$fixture_home/.claude/settings.json"
  if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
    if grep -Fxq "[warn] enableGitHubIsolatedReader=false but $fixture_home/.claude/settings.json $ql_unchecked safe-gh hook registration there is unchecked" <<< "$ql_out" \
      && grep -Fxq "[warn] enableQualityLoopHooks=false but $fixture_home/.claude/settings.json $ql_unchecked quality-loop hook registration there is unchecked" <<< "$ql_out" \
      && ! grep -Fq "enableGitHubIsolatedReader not active (false)" <<< "$ql_out" \
      && ! grep -Fq "quality loop hooks not wired (enableQualityLoopHooks=false)" <<< "$ql_out"; then
      ok "test passed: an unreadable live file leaves the hook registrations unchecked (warned, no not-wired ok)"
    else
      printf '%s\n' "$ql_out" >&2
      fail "test failed: an unreadable live file was not reported as unchecked, or an ok line still showed"
      status=1
    fi
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: doctor must stay exit 0 (unreadable live hook file)"
    status=1
  fi
  chmod 600 "$fixture_home/.claude/settings.json"
fi
#     QL-f5) a FIFO in place of ~/.codex/hooks.json: not a regular file, so it
#            is never read (a grep on it would block for good) and both
#            registrations there are unchecked. The run has a deadline, so a
#            doctor that reads the FIFO fails the case instead of hanging the
#            suite (same as OCP-i10).
rm -f "$fixture_home/.claude/settings.json"
mkfifo "$fixture_home/.codex/hooks.json"
HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal > "$fixture_home/ql-fifo.out" 2>&1 &
ql_fifo_pid=$!
ql_fifo_waited=0
while kill -0 "$ql_fifo_pid" 2>/dev/null && [[ "$ql_fifo_waited" -lt 120 ]]; do
  sleep 1
  ql_fifo_waited=$((ql_fifo_waited + 1))
done
if kill -0 "$ql_fifo_pid" 2>/dev/null; then
  kill_tree "$ql_fifo_pid"
  wait "$ql_fifo_pid" 2>/dev/null || true
  fail "test failed: a FIFO in place of ~/.codex/hooks.json hung doctor (killed after 120s)"
  status=1
elif wait "$ql_fifo_pid"; then
  ql_out="$(cat "$fixture_home/ql-fifo.out")"
  if grep -Fxq "[warn] enableGitHubIsolatedReader=false but $fixture_home/.codex/hooks.json $ql_unchecked safe-gh hook registration there is unchecked" <<< "$ql_out" \
    && grep -Fxq "[warn] enableQualityLoopHooks=false but $fixture_home/.codex/hooks.json $ql_unchecked quality-loop hook registration there is unchecked" <<< "$ql_out" \
    && ! grep -Fq "enableGitHubIsolatedReader not active (false)" <<< "$ql_out" \
    && ! grep -Fq "quality loop hooks not wired (enableQualityLoopHooks=false)" <<< "$ql_out"; then
    ok "test passed: a FIFO in place of a live hook file is not read and leaves the registrations unchecked (no hang)"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: a FIFO in place of a live hook file was not reported as unchecked, or an ok line still showed"
    status=1
  fi
else
  ql_fifo_rc=$?
  doctor_exit_fail "a FIFO in place of ~/.codex/hooks.json" "$ql_fifo_rc" "$(cat "$fixture_home/ql-fifo.out")"
fi
rm -f "$fixture_home/.claude/settings.json" "$fixture_home/.codex/hooks.json" "$fixture_home/ql-fifo.out"
#     QL-f6) a live file whose absence cannot be confirmed (#439): ~/.claude
#            without search permission, holding both registrations
#            ([[ -e ]] is false for the file there), and ~/.codex a symlink
#            loop. Each file leaves both registrations unchecked (warned),
#            with no ok line and no lingering action (nothing was read).
#            Skipped as root (root searches a directory without x).
ql_unentered="exists cannot be told (a parent directory could not be entered), so a lingering"
if [[ "$(id -u)" != "0" ]]; then
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/x/agent-tools/scripts/personal-safe-gh-hook"}]}],"Stop":[{"hooks":[{"type":"command","command":"/x/agent-tools/scripts/personal-changed-scope-qa"}]}]}}\n' \
    > "$fixture_home/.claude/settings.json"
  chmod u-x "$fixture_home/.claude"
  mv "$fixture_home/.codex" "$fixture_home/.codex.aside"
  ln -s "$fixture_home/.codex" "$fixture_home/.codex"
  if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
    if grep -Fxq "[warn] enableGitHubIsolatedReader=false but whether $fixture_home/.claude/settings.json $ql_unentered safe-gh hook registration there is unchecked" <<< "$ql_out" \
      && grep -Fxq "[warn] enableQualityLoopHooks=false but whether $fixture_home/.claude/settings.json $ql_unentered quality-loop hook registration there is unchecked" <<< "$ql_out" \
      && grep -Fxq "[warn] enableGitHubIsolatedReader=false but whether $fixture_home/.codex/hooks.json $ql_unentered safe-gh hook registration there is unchecked" <<< "$ql_out" \
      && grep -Fxq "[warn] enableQualityLoopHooks=false but whether $fixture_home/.codex/hooks.json $ql_unentered quality-loop hook registration there is unchecked" <<< "$ql_out" \
      && ! grep -Fq "registration lingers" <<< "$ql_out" \
      && ! grep -Fq "enableGitHubIsolatedReader not active (false)" <<< "$ql_out" \
      && ! grep -Fq "quality loop hooks not wired (enableQualityLoopHooks=false)" <<< "$ql_out"; then
      ok "test passed: a live hook file under an unsearchable ~/.claude or a looping ~/.codex leaves the registrations unchecked (warned, no not-wired ok)"
    else
      printf '%s\n' "$ql_out" >&2
      fail "test failed: a live hook file whose absence cannot be confirmed was skipped as absent, or an ok line still showed"
      status=1
    fi
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: doctor must stay exit 0 (live hook file under an unsearchable parent)"
    status=1
  fi
  chmod u+x "$fixture_home/.claude"
  rm -f "$fixture_home/.claude/settings.json" "$fixture_home/.codex"
  mv "$fixture_home/.codex.aside" "$fixture_home/.codex"
fi
#     QL-f7) the contrast: absence confirmed through the parent (#439):
#            ~/.claude missing (ENOENT) and ~/.codex a regular file
#            (ENOTDIR). Neither live file can exist, so both capabilities
#            report not wired and nothing is unchecked.
mv "$fixture_home/.claude" "$fixture_home/.claude.aside"
mv "$fixture_home/.codex" "$fixture_home/.codex.aside"
: > "$fixture_home/.codex"
if ql_out="$(HOME="$fixture_home" "$ql_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[ok] enableGitHubIsolatedReader not active (false)" <<< "$ql_out" \
    && grep -Fxq "[ok] quality loop hooks not wired (enableQualityLoopHooks=false)" <<< "$ql_out" \
    && ! grep -Fq "registration there is unchecked" <<< "$ql_out" \
    && ! grep -Fq "registration lingers" <<< "$ql_out"; then
    ok "test passed: a live hook file whose parent is missing or not a directory is confirmed absent (not wired)"
  else
    printf '%s\n' "$ql_out" >&2
    fail "test failed: a missing or non-directory parent of a live hook file was not read as absent"
    status=1
  fi
else
  printf '%s\n' "$ql_out" >&2
  fail "test failed: doctor must stay exit 0 (live hook file with a missing or non-directory parent)"
  status=1
fi
rm -f "$fixture_home/.codex"
mv "$fixture_home/.claude.aside" "$fixture_home/.claude"
mv "$fixture_home/.codex.aside" "$fixture_home/.codex"

fi # end of part 1

# ---- part 2 of 3 (TEST_DOCTOR_PART=2): from the herdr integration cases
# (HI) to the AI policy cases (AIP) ----
if doctor_part 2; then

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
#           install command (fail-open no-op); the scope item shows. The
#           suite's PATH, whose host-stub herdr exits 1 (#306): the
#           body-absent branch does not depend on herdr's answer.
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
#           herdr reports current WITHOUT a trailing newline (fake mode
#           `ok-nonl`: the unterminated last status line must still be seen
#           and the answer adopted, no "unchecked") -> both ok lines (Codex
#           with its trust / config.toml honest-label). A newline-terminated
#           answer (mode `ok`) is adopted in HI-c, HI-e and HI-f.
mkdir -p "$(dirname "$hi_claude_body")" "$(dirname "$hi_codex_body")"
printf '#!/bin/sh\nexit 0\n' > "$hi_claude_body"
printf '#!/bin/sh\nexit 0\n' > "$hi_codex_body"
chmod 0644 "$hi_claude_body" "$hi_codex_body"
write_fake_herdr_status "current (v9)" "current (v8)" ok-nonl
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if grep -Fq "$hi_claude_ok and current per herdr integration status" <<< "$hi_out" \
    && grep -Fq "$hi_codex_ok and current per herdr integration status $hi_codex_note" <<< "$hi_out" \
    && ! grep -Fq "re-run: herdr integration install" <<< "$hi_out"; then
    ok "test passed: herdr integration reported wired and current in both homes with non-executable bodies and a status answer without a trailing newline (Codex line carries the trust + config.toml caveats)"
  else
    printf '%s\n' "$hi_out" >&2
    fail "test failed: current herdr integration (non-executable bodies, answer without a trailing newline) not reported as wired in both homes"
    status=1
  fi
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: doctor must stay exit 0 (herdr integration, current)"
  status=1
fi
#     HI-b2) a directory at the Claude body path must NOT count as present (a
#            bare -x/-e probe would pass it) although herdr answers current
#            for it, and the Codex home must stay current (an absent body in
#            one home must not cost the other its answer). Its own fake, not
#            HI-b's left in place. Each check fails with its own message: the
#            fake answers without a trailing newline as in HI-b, so a reader
#            that drops such an answer fails the Codex check here, not the
#            presence check.
rm -f "$hi_claude_body"
mkdir -p "$hi_claude_body"
write_fake_herdr_status "current (v9)" "current (v8)" ok-nonl
if hi_out="$(HOME="$fixture_home" PATH="$hi_fakebin:$PATH" "$hi_root/scripts/doctor.sh" personal 2>&1)"; then
  if ! grep -Fq "managed ~/.claude/settings.json registers the SessionStart hook but the body is absent or unreadable ($hi_claude_body;" <<< "$hi_out"; then
    printf '%s\n' "$hi_out" >&2
    fail "test failed: a directory at the herdr body path passed the presence check"
    status=1
  elif ! grep -Fq "$hi_codex_ok and current per herdr integration status" <<< "$hi_out"; then
    printf '%s\n' "$hi_out" >&2
    fail "test failed: the Codex home did not stay current next to a directory at the Claude body path (its status answer, without a trailing newline as in HI-b, was not adopted)"
    status=1
  else
    ok "test passed: a directory at the herdr body path is reported absent (regular-file check), Codex home unaffected"
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
#           not checked, never a "current". herdr absent from PATH leaves
#           the status empty the same way, by construction (not run here:
#           the host stub keeps herdr on PATH, #306; NA's herdr-absent case
#           covers the work profile's pointer).
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
#            afterwards (tree reap, not just the wrapper). With HI-d3 this is
#            also the op probe's check that a grandchild already running at
#            the deadline is reaped (the same bounded_probe): OP has no hang
#            case of its own and OP-e does not catch a kill_tree that skips
#            grandchildren, so changing HI-d2 or HI-d3 means bringing such a
#            case back to OP.
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
#     HI-e2b) the same run, for the isolated reader committed true: with
#             codex-settings inactive the Codex side is dangling too (the
#             Claude side is checked in QL-e2).
if grep -Fxq "[warn] enableGitHubIsolatedReader=true but the codex-settings module is inactive for this profile; no managed ~/.codex/hooks.json carries the hook registration (dangling capability on the Codex side)" <<< "$hi_out"; then
  ok "test passed: enableGitHubIsolatedReader=true with codex-settings inactive is reported as dangling on the Codex side"
else
  printf '%s\n' "$hi_out" >&2
  fail "test failed: dangling enableGitHubIsolatedReader (Codex side) not reported"
  status=1
fi
rm -rf "$hi_fakebin" "$hi_claude_body" "$hi_codex_body"

# OP) 1Password sign-in probe (#231): `op whoami` runs through the shared
#     bounded_probe, so a signed-out op blocking on the app's unlock prompt
#     cannot stall doctor. PATH-front fake op (same pattern as the fake herdr
#     above). MODE `ok` answers exit 0; `fail` exits 1 (signed out). Both
#     leave stdin-leaked when their stdin is NOT /dev/null (test -ef), so
#     OP-a, whose doctor stdin carries a line, proves the probe reads no
#     terminal input. The deadline (a probe with no answer) is OP-e's: its
#     fake op never answers on its own. Committed personal has
#     allowSecretsAccess=true; doctor stays exit 0 throughout.
op_fakebin="$fixture_home/opfake"
mkdir -p "$op_fakebin"
# write_fake_op MODE
write_fake_op() {
  cat > "$op_fakebin/op" <<SH
#!/bin/sh
[ "\$1" = whoami ] || exit 2
[ /dev/fd/0 -ef /dev/null ] || : > "$op_fakebin/stdin-leaked"
printf 'URL: https://example.1password.com\\n'
[ "$1" = ok ]
SH
  chmod +x "$op_fakebin/op"
}
op_signed_in="[ok] op signed in"
op_signed_out="[warn] op available but not signed in"
op_unchecked="[warn] op sign-in state not checked: op whoami gave no answer within 5s (waiting on an unlock / sign-in prompt, or stuck; the probe was killed) — unlock or sign in to 1Password, then re-run doctor"
#     OP-a) signed in -> ok, and no other verdict on the same run. doctor's
#           stdin is a pipe with a line in it, and the fake records a stdin
#           that is not /dev/null: the probe must read no terminal input.
write_fake_op ok
rm -f "$op_fakebin/stdin-leaked"
if op_out="$(printf 'typed input\n' | HOME="$fixture_home" PATH="$op_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if [[ -e "$op_fakebin/stdin-leaked" ]]; then
    printf '%s\n' "$op_out" >&2
    fail "test failed: the op probe did not run with stdin from /dev/null"
    status=1
  elif grep -Fxq "$op_signed_in" <<< "$op_out" \
    && ! grep -Fq "$op_signed_out" <<< "$op_out" && ! grep -Fq "$op_unchecked" <<< "$op_out"; then
    ok "test passed: a signed-in op is reported ok, and the probe reads /dev/null, not doctor's stdin"
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
#     OP-e) op gives no answer (#231), and is a probe that starts its next
#           command when the one before ends (#423): killed at the deadline,
#           reported as NOT CHECKED (never as signed in / out), doctor goes
#           on to the next section, and nothing is left behind. The fake op
#           waits (in its own process) until the listing of its children
#           has been taken, then starts its next command, a
#           `sleep 3000.<digits>` (C; pid in c.pid). A PATH-front pgrep shim
#           takes the real listing of the fake op's children, marks it taken
#           (held), then holds the answer until the fake op is stopped or C
#           has started. A cleanup that lists the children of a running
#           process and kills them before the process itself (the
#           kill_process_tree doctor had before) therefore leaves C behind
#           every time: C cannot start before the listing, and the listing
#           is returned only after it has started. The held answer is the
#           one of the moment pgrep was asked, as the real pgrep's would be.
#           The shim records how the hold ended; a timeout fails the case
#           (Codex review, PR #427: a fixed sleep let a slow run start C
#           before the listing, and the old cleanup passed).
op_real_pgrep="$(command -v pgrep)"
op_respawn_sleep="3000.${RANDOM}${RANDOM}"
cat > "$op_fakebin/op" <<SH
#!/bin/sh
[ "\$1" = whoami ] || exit 2
printf '%s\\n' "\$\$" > "$op_fakebin/op.pid"
while [ ! -e "$op_fakebin/held" ]; do sleep 0.05; done
sleep $op_respawn_sleep &
printf '%s\\n' "\$!" > "$op_fakebin/c.pid"
wait
SH
cat > "$op_fakebin/pgrep" <<SH
#!/bin/sh
if [ "\$#" -eq 2 ] && [ "\$1" = -P ] && [ -s "$op_fakebin/op.pid" ] && [ "\$2" = "\$(cat "$op_fakebin/op.pid")" ]; then
  listing="\$("$op_real_pgrep" -P "\$2")"
  rc=\$?
  : > "$op_fakebin/held"
  sync=timeout
  i=0
  while [ "\$i" -lt 150 ]; do
    case "\$(ps -o stat= -p "\$2" 2>/dev/null)" in *T*) sync=stopped; break ;; esac
    [ -s "$op_fakebin/c.pid" ] && { sync=started; break; }
    sleep 0.1
    i=\$((i + 1))
  done
  printf '%s\\n' "\$sync" >> "$op_fakebin/sync"
  [ -z "\$listing" ] || printf '%s\\n' "\$listing"
  exit "\$rc"
fi
exec "$op_real_pgrep" "\$@"
SH
chmod +x "$op_fakebin/op" "$op_fakebin/pgrep"
rm -f "$op_fakebin/op.pid" "$op_fakebin/c.pid" "$op_fakebin/held" "$op_fakebin/sync"
op_started=$SECONDS
op_rc=0
op_out="$(HOME="$fixture_home" PATH="$op_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" || op_rc=$?
op_elapsed=$((SECONDS - op_started))
sleep 0.5
op_left="$("$op_real_pgrep" -f "^sleep $op_respawn_sleep\$" || true)"
op_sync="$(cat "$op_fakebin/sync" 2>/dev/null || true)"
# Each condition that fails is named in the message, so a failure points at
# its own cause (an extra verdict, or doctor stopping after the deadline,
# is not read as a hold that did not end as stopped).
op_why=""
[[ "$op_rc" -eq 0 ]] || op_why+="; doctor exited $op_rc"
[[ -s "$op_fakebin/op.pid" ]] || op_why+="; the fake op never ran"
[[ "$op_sync" == stopped ]] || op_why+="; the hold ended as '${op_sync:-never asked}' instead of stopped"
[[ -z "$op_left" ]] || op_why+="; the respawning probe left a process behind ($op_left)"
(( op_elapsed < 45 )) || op_why+="; doctor took ${op_elapsed}s (45s or more)"
grep -Fxq "$op_unchecked" <<< "$op_out" || op_why+="; the not-checked verdict is missing"
grep -Fq "$op_signed_in" <<< "$op_out" && op_why+="; also reported as signed in"
grep -Fq "$op_signed_out" <<< "$op_out" && op_why+="; also reported as not signed in"
grep -Fq "== SSH (1Password agent) ==" <<< "$op_out" || op_why+="; doctor did not go on to the SSH section"
grep -Fq "kill_tree:" <<< "$op_out" && op_why+="; kill_tree warned"
if [[ -z "$op_why" ]]; then
  ok "test passed: an op whoami with no answer is killed at the deadline (${op_elapsed}s), reported as not checked, doctor continues, and a probe that starts its next command when one ends leaves nothing behind"
else
  printf '%s\n' "$op_out" >&2
  fail "test failed: an op whoami with no answer (rc=$op_rc, ${op_elapsed}s): ${op_why#; }"
  status=1
  [[ -z "$op_left" ]] || kill $op_left 2>/dev/null || true
  # A cleanup that never reached the fake op leaves it looping on the
  # held mark, which the rm -rf below removes for good: stop its tree too,
  # only while that pid is still the fake op (kill_tree stops and kills a
  # whole tree, so a reused pid must not be taken for it).
  op_pid="$(cat "$op_fakebin/op.pid" 2>/dev/null || true)"
  if [[ -n "$op_pid" ]] && ps -o command= -p "$op_pid" 2>/dev/null | grep -Fq "$op_fakebin/op"; then
    kill_tree "$op_pid"
  fi
fi
rm -rf "$op_fakebin"

# KT) kill_tree itself (lib-policy.sh, #440). OP-e and the suite interrupt
#     check catch a kill_tree that lists a process's children before it
#     stops the process, but not its wait for the stop: SIGSTOP is delivered
#     asynchronously, so kill_tree lists the children only once ps shows the
#     process stopped (or a zombie, or gone). Their pgrep shims hold the
#     listing until the process is stopped, so they pass without that wait
#     and without its warns. Here kill_tree runs in a bash of its own with a
#     PATH-front ps shim that answers for one process, the target (a `sh`
#     with two `sleep 3000.<digits>` children; any other question goes to the
#     real ps), and a pgrep shim. Both note each question about the target
#     in a log, in order.
#     KT-a) the stop shows late: ps answers "S" (not stopped) kt_late times,
#           then the real state. The children are listed only after ps
#           showed the target stopped, with no warn.
#     KT-b) ps fails every time while the target is there: a failed read,
#           not an exit. kill_tree asks again (at least kt_late times),
#           warns that it could not read the state, and still kills the
#           whole tree.
#     KT-c) ps answers "S" every time: kill_tree asks at least kt_late
#           times, warns that the target did not stop, and the whole tree
#           is still killed.
#     Each run must return 0 (callers are under set -e). KT-b and KT-c wait
#     out kill_tree's bound (5 s). kt_late (20 questions, about 0.4 s) is
#     well under that bound, so it does not pin it, but a wait cut to a few
#     tries fails all three cases.
kt_dir="$fixture_home/kill-tree"
kt_late=20
mkdir -p "$kt_dir/shim"
kt_real_ps="$(command -v ps)"
kt_real_pgrep="$(command -v pgrep)"
cat > "$kt_dir/shim/ps" <<'SH'
#!/bin/sh
# ps shim of KT (test-doctor.sh): see there.
if [ "$#" -eq 4 ] && [ "$1" = -o ] && [ "$2" = stat= ] && [ "$3" = -p ] && [ "$4" = "$KT_TARGET" ]; then
  case "$KT_MODE" in
    late)
      if [ "$(grep -c '^ps ' "$KT_LOG")" -lt "$KT_LATE" ]; then
        printf 'ps S\n' >> "$KT_LOG"
        printf 'S\n'
        exit 0
      fi
      st="$("$KT_PS" "$@")"
      rc=$?
      printf 'ps %s\n' "$(printf '%s' "$st" | tr -d ' ')" >> "$KT_LOG"
      [ -z "$st" ] || printf '%s\n' "$st"
      exit "$rc"
      ;;
    fail)
      printf 'ps fail\n' >> "$KT_LOG"
      exit 1
      ;;
    running)
      printf 'ps S\n' >> "$KT_LOG"
      printf 'S\n'
      exit 0
      ;;
  esac
fi
exec "$KT_PS" "$@"
SH
cat > "$kt_dir/shim/pgrep" <<'SH'
#!/bin/sh
# pgrep shim of KT (test-doctor.sh): see there.
if [ "$#" -eq 2 ] && [ "$1" = -P ] && [ "$2" = "$KT_TARGET" ]; then
  printf 'pgrep\n' >> "$KT_LOG"
fi
exec "$KT_PGREP" "$@"
SH
chmod +x "$kt_dir/shim/ps" "$kt_dir/shim/pgrep"
# kt_case MODE — start a target, run kill_tree on it with the ps shim in
# MODE, and set kt_target, kt_alive (how many of the target and its two
# children were alive before), kt_rc and kt_out (kill_tree's status and
# output), kt_seq (the log up to the first listing of the target's
# children, one line per space) and kt_left (what is still alive after:
# the target unless a zombie, and any of its sleeps). Whatever is left is
# killed here, so a failed case leaves nothing for the next one.
kt_case() {
  local mode="$1" t pid kids state strays digits="$RANDOM$RANDOM$RANDOM"
  : > "$kt_dir/log"
  rm -f "$kt_dir/kids"
  sh -c 'sleep "$2" & a=$!; sleep "$2" & printf "%s %s\n" "$a" "$!" > "$1.tmp"; mv "$1.tmp" "$1"; wait' \
    kill-tree "$kt_dir/kids" "3000.$digits" &
  kt_target=$!
  for ((t = 0; t < 100; t++)); do
    [[ -s "$kt_dir/kids" ]] && break
    sleep 0.05
  done
  kids="$(cat "$kt_dir/kids" 2>/dev/null || true)"
  kt_alive=0
  for pid in $kt_target $kids; do
    if kill -0 "$pid" 2>/dev/null; then kt_alive=$((kt_alive + 1)); fi
  done
  kt_rc=0
  kt_left=""
  # The target is this shell's child: KILLed, it stays a zombie until the
  # wait below (its sleeps go to init, which reaps them). bash reports a job
  # that a signal ended ("Killed: 9") on stderr when it reaps it, which may
  # be while kill_tree still runs; that is the expected end, so it is not
  # shown.
  {
    kt_out="$(KT_MODE="$mode" KT_LATE="$kt_late" KT_TARGET="$kt_target" KT_LOG="$kt_dir/log" KT_PS="$kt_real_ps" KT_PGREP="$kt_real_pgrep" \
      PATH="$kt_dir/shim:$PATH" "$BASH" -c 'set -euo pipefail; source "$1"; kill_tree "$2"' \
      kill-tree "$SCRIPT_DIR/lib-policy.sh" "$kt_target" 2>&1 < /dev/null)" || kt_rc=$?
    for ((t = 0; t < 50; t++)); do
      state="$(LC_ALL=C "$kt_real_ps" -o stat= -p "$kt_target" || true)"
      state="${state//[[:space:]]/}"
      [[ -z "$state" || "$state" == Z* ]] && break
      sleep 0.1
    done
    if [[ -n "$state" && "$state" != Z* ]]; then
      kt_left=" $kt_target($state)"
      kill -KILL "$kt_target" || true
    fi
    wait "$kt_target" || true
  } 2>/dev/null
  kt_seq="$(sed '/^pgrep$/q' "$kt_dir/log" | tr '\n' ' ')"
  for ((t = 0; t < 50; t++)); do
    strays="$("$kt_real_pgrep" -f "^sleep 3000[.]$digits\$" 2>/dev/null | tr '\n' ' ' || true)"
    [[ -z "${strays// /}" ]] && break
    sleep 0.1
  done
  if [[ -n "${strays// /}" ]]; then
    kt_left+=" sleeps: $strays"
    pkill -KILL -f "^sleep 3000[.]$digits\$" 2>/dev/null || true
  fi
}
# kt_failed LABEL — show what kt_case saw (the log with repeats counted),
# then fail.
kt_failed() {
  printf 'alive before: %s of 3, rc=%s, log to the first listing: %s left:%s\n%s\n' \
    "$kt_alive" "$kt_rc" "$(sed '/^pgrep$/q' "$kt_dir/log" | uniq -c | sed 's/^ *\([0-9]*\) \(.*\)/\2 x\1;/' | tr '\n' ' ')" \
    "${kt_left:- none}" "$kt_out" >&2
  fail "test failed: kill_tree ($1)"
  status=1
}
#     KT-a) the stop shows late.
kt_case late
kt_re="^(ps S ){$kt_late,}ps T[^ ]* pgrep \$"
if [[ "$kt_alive" -eq 3 && "$kt_rc" -eq 0 && "$kt_seq" =~ $kt_re && -z "$kt_left" ]] \
  && ! grep -Fq "kill_tree:" <<< "$kt_out"; then
  ok "test passed: kill_tree lists a process's children only after ps shows it stopped, and kills the whole tree"
else
  kt_failed "the children were listed before ps showed the process stopped, or a warn or a process was left"
fi
#     KT-b) ps fails while the target is there.
kt_case fail
kt_re="^(ps fail ){$kt_late,}pgrep \$"
if [[ "$kt_alive" -eq 3 && "$kt_rc" -eq 0 && "$kt_seq" =~ $kt_re && -z "$kt_left" ]] \
  && grep -Fxq "[warn] kill_tree: could not read the state of process $kt_target; a child it starts now may be missed" <<< "$kt_out"; then
  ok "test passed: kill_tree does not take a failed ps for a process that is gone: it waits, warns, and still kills the whole tree"
else
  kt_failed "a ps that failed while the process was there was taken as gone, kill_tree asked fewer than $kt_late times, the warn was missing, or a process was left"
fi
#     KT-c) the target never shows as stopped.
kt_case running
kt_re="^(ps S ){$kt_late,}pgrep \$"
if [[ "$kt_alive" -eq 3 && "$kt_rc" -eq 0 && "$kt_seq" =~ $kt_re && -z "$kt_left" ]] \
  && grep -Fxq "[warn] kill_tree: process $kt_target did not stop (state S); a child it starts now may be missed" <<< "$kt_out"; then
  ok "test passed: kill_tree warns when a process does not show as stopped, and still kills the whole tree"
else
  kt_failed "kill_tree asked fewer than $kt_late times, the did-not-stop warn was missing, or a process was left"
fi
rm -rf "$kt_dir"

# ID) Git identity contexts (#202): an existing identity file is checked for
#     completeness, presence-only; a missing one is reported when its project
#     root exists. doctor reports every context (personal / work / client /
#     sandbox / agent) on every run and each expected line names that
#     context's own file and root, so one run carries one state per context:
#     two runs with the identity reset present here and two without it in
#     ID-r, not one run per state. Several populated contexts in one run also
#     catch per-context state leaking from one loop iteration into the next.
#     The fixture name and email are canaries that must never appear in the
#     output (doctor reports key names only). doctor stays exit 0 throughout.
id_canary_email="canary-identity-9f2b@example.invalid"
id_canary_name="Canary Identity Name"
mkdir -p "$fixture_home/.config/git"
# The project roots this block finds (~/src/agent when part 1 ran, from the
# agent-tools cases; none under TEST_DOCTOR_PART=2) are kept by the cleanup
# below, the ones it makes are removed.
id_roots_before=" "
for id_ctx in personal work client sandbox agent; do
  [[ ! -d "$fixture_home/src/$id_ctx" ]] || id_roots_before+="$id_ctx "
done
# id_plant CONTEXT STATE — put CONTEXT's identity file in STATE. Its project
# root exists in every state, so "missing" reads as root-without-file.
id_plant() {
  local f="$fixture_home/.config/git/$1.gitconfig"
  mkdir -p "$fixture_home/src/$1"
  case "$2" in
    missing) rm -f "$f" ;;
    empty) : > "$f" ;;
    name-only) printf '[user]\n\tname = %s\n' "$id_canary_name" > "$f" ;;
    email-only) printf '[user]\n\temail = %s\n' "$id_canary_email" > "$f" ;;
    complete) printf '[user]\n\tname = %s\n\temail = %s\n' "$id_canary_name" "$id_canary_email" > "$f" ;;
    unparsable) printf '[user\n\tname = %s\n' "$id_canary_name" > "$f" ;;
    # Explicit EMPTY values (keys present, no value) — distinct from unset
    # keys once the identity reset is missing (#241 review F5).
    empty-values) printf '[user]\n\tname =\n\temail =\n' > "$f" ;;
    name-empty-email-unset) printf '[user]\n\tname =\n' > "$f" ;;
    # Keys with no `=` at all: git's boolean shorthand. `git config --get`
    # (untyped) prints an empty string with exit 0 for them, exactly like an
    # explicit empty value — but git's identity reader rejects them ("missing
    # value for 'user.email'", fatal; measured on git 2.50.1), so doctor must
    # diagnose them as their own state (#241 review F8 / F9).
    bare-keys) printf '[user]\n\tname\n\temail\n' > "$f" ;;
    email-bare) printf '[user]\n\tname = %s\n\temail\n' "$id_canary_name" > "$f" ;;
    # A large file with the bare key LAST: a `git config --list | grep -q`
    # pipe would stop reading at the first match and could lose the rest to
    # SIGPIPE under pipefail; doctor must read the whole listing.
    bare-large)
      {
        printf '[user]\n\tname = %s\n' "$id_canary_name"
        awk 'BEGIN { for (i = 1; i <= 20000; i++) printf "[alias]\n\tpadding%d = value%d\n", i, i }'
        printf '[user]\n\temail\n'
      } > "$f"
      ;;
  esac
}
# id_run LABEL — one doctor run into id_out. id_ok=0 (and one failure for the
# run) when doctor did not exit 0 or an identity value is in the output.
id_run() {
  local rc=0
  id_ok=1
  id_out="$(HOME="$fixture_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    doctor_exit_fail "identity files, $1" "$rc" "$id_out"
    id_ok=0
  elif grep -Fq "$id_canary_email" <<< "$id_out" || grep -Fq "$id_canary_name" <<< "$id_out"; then
    printf '%s\n' "$id_out" >&2
    fail "test failed: identity files, $1: an identity value is in the output"
    status=1
    id_ok=0
  fi
}
# id_expect CONTEXT STATE LINE LABEL — LINE is an exact line of the last run,
# with @F@ / @R@ standing for CONTEXT's identity file / project root. The
# assignment is unquoted with a quoted replacement: bash 3.2 keeps the quotes
# of a quoted replacement inside "...", and bash 5.2+ (patsub_replacement)
# turns an unquoted & of the replacement (a TMPDIR with &) into the match.
id_expect() {
  local f="$fixture_home/.config/git/$1.gitconfig" r="$fixture_home/src/$1" line="$3"
  [[ "$id_ok" -eq 1 ]] || return 0
  line=${line//@F@/"$f"}
  line=${line//@R@/"$r"}
  if grep -Fxq -- "$line" <<< "$id_out"; then
    ok "test passed: identity file $2 ($1) -> $4"
  else
    printf '%s\n' "$id_out" >&2
    fail "test failed: identity file $2 ($1): expected the exact line '$line'"
    status=1
  fi
}
# The next-actions steps are printf %q-escaped by doctor, so the expected
# lines are built the same way (a TMPDIR with a space would otherwise fail a
# correct output). ORDER is the contract: mkdir must come right before the
# apply within the same action, so the apply step must be a line that
# immediately follows a mkdir line (steps_consecutive). Other actions start
# with the same mkdir step (the global gitignore one, #248), so the pair is
# searched, not the first mkdir match.
# reset_steps_in OUTPUT HOME_DIR — OUTPUT has the reset apply steps of HOME_DIR.
reset_steps_in() {
  steps_consecutive "$1" "        \$ mkdir -p $(printf '%q' "$2/.config")" \
    "        \$ chezmoi apply $(printf '%q' "$2/.config/git-profile") $(printf '%q' "$2/.config/git-profile/identity-reset.gitconfig")"
}
id_partial_tail="— commits under @R@ get an empty ident (a missing name is refused; a missing email is accepted as <> and shows as no-identity in the prompt)"
id_bare_tail="— git rejects the whole identity (fatal: missing value), so commits under @R@ fail until it is fixed"
# The managed identity reset (#202) is present for the first two runs: it is
# what makes "identity file missing" mean "commits refused".
id_reset="$fixture_home/.config/git-profile/identity-reset.gitconfig"
mkdir -p "${id_reset%/*}"
cp "$DOTFILES_ROOT/private_dot_config/git-profile/identity-reset.gitconfig" "$id_reset"
id_plant work missing; id_plant client empty; id_plant sandbox name-only; id_plant agent email-only
id_run "reset present, run 1"
id_expect work missing "[ok] identity reset file present: $id_reset (non-personal contexts fail closed without a context file)" "reset present -> ok"
id_expect work missing "[warn] project root exists but identity file missing: @F@" "missing-file action (unchanged)"
id_expect client empty "[warn] identity file is partial: @F@ has no user.name user.email $id_partial_tail" "partial action naming both keys"
id_expect sandbox name-only "[warn] identity file is partial: @F@ has no user.email $id_partial_tail" "partial action naming user.email"
id_expect agent email-only "[warn] identity file is partial: @F@ has no user.name $id_partial_tail" "partial action naming user.name"
# The bare-key check comes before the reset logic, so bare-large reads the
# same with the reset present.
id_plant work complete; id_plant client unparsable; id_plant sandbox bare-large
id_run "reset present, run 2"
id_expect work complete "[ok] identity file exists: @F@" "ok"
id_expect client unparsable "[warn] identity file exists but git cannot parse it: @F@ (syntax error?) — commits under @R@ fail until it is fixed" "unparsable warn"
id_expect sandbox bare-large "[warn] identity file has a key without a value: @F@ (user.email) $id_bare_tail" "bare key at the end of a 40k-line file is still found (whole listing read)"

# ID-r) The identity reset itself is checked, presence-only (#241): a partial
#     apply (Quickstart with ~/.gitconfig alone) leaves it missing and Git
#     silently skips the include, so the personal fallback leaks into
#     non-personal repos. Present -> ok line (run 1 above); absent -> action
#     naming the apply, and the actions of a NON-personal context must then
#     say the fallback is in use rather than "refused". personal is the
#     fallback itself, so its wording does not change.
rm -f "$id_reset"
id_plant work missing; id_plant client empty; id_plant sandbox name-only; id_plant agent email-only
id_run "reset absent, run 1"
id_expect work missing "[warn] identity reset file missing: $id_reset — the fail-closed boundary of #202 is NOT in place: in a non-personal repo without its context file, a remote matching the personal patterns (hasconfig in ~/.gitconfig) inherits the personal identity instead of refusing to commit (other repos are still refused by useConfigOnly)" "reset absent -> action naming the apply"
if [[ "$id_ok" -eq 1 ]]; then
  if reset_steps_in "$id_out" "$fixture_home"; then
    ok "test passed: reset absent -> next-actions steps: doctor exit 0, steps are mkdir then apply, consecutive and %q-escaped"
  else
    printf '%s\n' "$id_out" >&2
    fail "test failed: reset absent -> next-actions steps: expected the mkdir step immediately followed by the apply step"
    status=1
  fi
fi
id_expect work missing "[warn] project root exists but identity file missing: @F@ (and the identity reset is missing too: a repo under @R@ whose remote matches the personal patterns inherits the personal identity instead of being refused; other repos are still refused)" "reset absent -> missing-identity action says conditional inheritance"
# Partial files: without the reset an UNSET key keeps the personal identity
# (mixed identity) in a personal-remote repo, but an explicitly EMPTY value
# still overrides it — so the wording depends on which keys are unset.
id_mixed_tail="inherits the personal identity in a repo under @R@ whose remote matches the personal patterns — a mixed identity that is not refused; an explicitly empty key stays empty)"
id_expect client empty "[warn] identity file is partial: @F@ has no user.name user.email (and the identity reset is missing: the unset user.name user.email $id_mixed_tail" "reset absent -> empty file: both keys unset -> mixed identity"
id_expect sandbox name-only "[warn] identity file is partial: @F@ has no user.email (and the identity reset is missing: the unset user.email $id_mixed_tail" "reset absent -> name-only: email unset -> mixed identity"
id_expect agent email-only "[warn] identity file is partial: @F@ has no user.name (and the identity reset is missing: the unset user.name $id_mixed_tail" "reset absent -> email-only: name unset -> mixed identity"
# Value-less keys are their own state: git refuses to read the identity at
# all, whatever the reset — the "empty email is accepted as <>" wording would
# be wrong for them. Inheritance and commit outcome are separate: with the
# name explicitly empty the email still inherits, but the commit is refused
# (empty name).
id_plant work empty-values; id_plant client bare-keys; id_plant sandbox email-bare
id_plant agent name-empty-email-unset; id_plant personal name-only
id_run "reset absent, run 2"
id_expect work empty-values "[warn] identity file is partial: @F@ has no user.name user.email $id_partial_tail" "reset absent -> explicit empty values still blank the ident (no inheritance)"
id_expect client bare-keys "[warn] identity file has a key without a value: @F@ (user.name user.email) $id_bare_tail" "bare keys (no =) -> own action: git rejects the identity"
id_expect sandbox email-bare "[warn] identity file has a key without a value: @F@ (user.email) $id_bare_tail" "name set + bare email -> action names user.email only, no value shown"
id_expect agent name-empty-email-unset "[warn] identity file is partial: @F@ has no user.name user.email (and the identity reset is missing: the unset user.email inherits the personal identity in a repo under @R@ whose remote matches the personal patterns — but the commit is still refused because user.name is explicitly empty; an explicitly empty key stays empty)" "reset absent -> empty name + unset email: email inherits, commit still refused"
id_expect personal name-only "[warn] identity file is partial: @F@ has no user.email $id_partial_tail" "reset absent -> personal keeps the empty-ident wording (personal is the fallback itself)"
# The steps on a fixture whose path contains a space: %q must make both the
# expectation and the output agree.
id_space_home="$fixture_home/id space home"
mkdir -p "$id_space_home/src/work" "$id_space_home/.config/git"
id_space_rc=0
id_space_out="$(HOME="$id_space_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" || id_space_rc=$?
if [[ "$id_space_rc" -eq 0 ]] && reset_steps_in "$id_space_out" "$id_space_home"; then
  ok "test passed: reset absent -> home path with a space: doctor exit 0, steps are mkdir then apply, consecutive and %q-escaped"
else
  printf '%s\n' "$id_space_out" >&2
  fail "test failed: reset absent -> home path with a space: expected exit 0 (got $id_space_rc) and the mkdir step immediately followed by the apply step"
  status=1
fi
rm -rf "$id_space_home"
# Every identity file goes, and the roots this block made.
for id_ctx in personal work client sandbox agent; do
  rm -f "$fixture_home/.config/git/$id_ctx.gitconfig"
  case "$id_roots_before" in
    *" $id_ctx "*) ;;
    *) rm -rf "$fixture_home/src/$id_ctx" ;;
  esac
done

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
    && grep -Fxq -- "        \$ chezmoi apply $(printf '%q' "${oc_floor%/*}") $(printf '%q' "$oc_floor")" <<< "$oc_out" \
    && grep -Fxq "[info] - opencode credential store present: $oc_auth (existence only; contents never read)" <<< "$oc_out" \
    && ! grep -Fq "$oc_canary_provider" <<< "$oc_out" && ! grep -Fq "$oc_canary_key" <<< "$oc_out"; then
    ok "test passed: OpenCode floor missing on personal is an action with the apply step for the directory and the file; credential store reported by existence only (canaries absent)"
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
#     unset except in CX-b (~/.codex spelled with a trailing slash: not
#     flagged) and CX-c (elsewhere: flagged, as agent-tools would look there
#     while chezmoi renders into ~/.codex). doctor stays exit 0.
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
# cx_unflagged LABEL OUTPUT — the run of LABEL did not flag CODEX_HOME.
cx_unflagged() {
  if grep -Fq "CODEX_HOME is set to" <<< "$2"; then
    printf '%s\n' "$2" >&2
    fail "test failed: $1: CODEX_HOME flagged"
    status=1
  else
    ok "test passed: $1: CODEX_HOME not flagged"
  fi
}
#     CX-a) committed personal (review=xhigh, worker=high), files missing ->
#           one action per file naming the apply target.
rm -f "$cx_review" "$cx_worker"
if cx_out="$(cx_run "$cx_root/scripts/doctor.sh" personal)"; then
  cx_expect "profile files missing on personal are actions" "$cx_out" \
    "[warn] codexReviewEffort=xhigh but $cx_review is missing — personal-codex-review falls back to the config.toml defaults" \
    "[warn] codexWorkerEffort=high but $cx_worker is missing — personal-codex-worker falls back to the config.toml defaults"
  cx_unflagged "CODEX_HOME unset" "$cx_out"
else
  doctor_exit_fail "Codex profiles, missing" "$?" "$cx_out"
fi
#     CX-b) files present -> ok, contents never printed. CODEX_HOME is the
#           default spelled with a trailing slash -> not flagged.
mkdir -p "$fixture_home/.codex"
printf 'model_reasoning_effort = "%s"\n' "$cx_canary" > "$cx_review"
printf 'model_reasoning_effort = "%s"\n' "$cx_canary" > "$cx_worker"
if cx_out="$(cx_run CODEX_HOME="$fixture_home/.codex/" "$cx_root/scripts/doctor.sh" personal)"; then
  cx_expect "profile files present on personal are ok (presence only)" "$cx_out" \
    "[ok] codexReviewEffort=xhigh; $cx_review present (read by personal-codex-review)" \
    "[ok] codexWorkerEffort=high; $cx_worker present (read by personal-codex-worker)"
  cx_unflagged "CODEX_HOME is ~/.codex with a trailing slash" "$cx_out"
else
  doctor_exit_fail "Codex profiles, present" "$?" "$cx_out"
fi
#     CX-c) codex-settings active but the capability off while a file
#           lingers -> action (agent-tools still reads it until apply).
#           CODEX_HOME elsewhere -> flagged.
set_capability_all "$cx_root" codexReviewEffort off
rm -f "$cx_worker"
set_capability_all "$cx_root" codexWorkerEffort off
if cx_out="$(cx_run CODEX_HOME="$fixture_home/elsewhere" "$cx_root/scripts/doctor.sh" personal)"; then
  cx_expect "capability off with a lingering file is an action; off without a file is ok; a diverging CODEX_HOME is flagged" "$cx_out" \
    "[warn] codexReviewEffort=off but $cx_review exists — agent-tools still reads it; chezmoi apply removes it (the managed target renders empty)" \
    "[ok] codexWorkerEffort=off; no worker profile file (personal-codex-worker uses the config.toml defaults)" \
    "[warn] CODEX_HOME is set to $fixture_home/elsewhere: agent-tools reads the review / worker profile files from there, but chezmoi renders them into ~/.codex"
else
  doctor_exit_fail "Codex profiles, off" "$?" "$cx_out"
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
  doctor_exit_fail "Codex profiles, work" "$?" "$cx_out"
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
  doctor_exit_fail "hook gates lingering, personal" "$?" "$hl_out"
fi
#     HL-b) work (module inactive) with the full managed wiring left by
#           personal: shims + hooks.gitconfig included from ~/.gitconfig, so
#           core.hooksPath is live -> hand removal of exactly the files that
#           exist, plus a confirmation step; never the apply action. The
#           steps here and in HL-e / HL-f are matched as whole summary lines
#           (8-space indent included), so the list must be exactly the files
#           that exist (#258), not a longer list that starts with them.
printf '#!/bin/sh\n' > "$hl_dir/hooks/commit-msg"
printf '[core]\n\thooksPath = ~/.config/git-hook-gates/hooks\n' > "$hl_dir/hooks.gitconfig"
printf '[include]\n\tpath = ~/.config/git-hook-gates/hooks.gitconfig\n' > "$hl_home/.gitconfig"
hl_rm_step="\$ rm -i $(printf '%q' "$hl_dir/hooks.gitconfig") $(printf '%q' "$hl_dir/hooks/pre-commit") $(printf '%q' "$hl_dir/hooks/commit-msg")"
hl_verify_step="\$ git config --global --includes --show-origin --get core.hooksPath   # must no longer point at ~/.config/git-hook-gates/hooks; if it still does, remove that line at the origin shown"
if hl_out="$(hl_run work)"; then
  if grep -Fxq "$hl_foreign_msg" <<< "$hl_out" && ! grep -Fq "$hl_apply_msg" <<< "$hl_out" \
    && grep -Fxq -- "        $hl_rm_step" <<< "$hl_out" && grep -Fxq -- "        $hl_verify_step" <<< "$hl_out"; then
    ok "test passed: lingering wiring on work (module inactive) names the files to remove, not apply"
  else
    printf '%s\n' "$hl_out" >&2
    fail "test failed: lingering wiring on work was not reported as hand removal of the existing files"
    status=1
  fi
else
  doctor_exit_fail "hook gates lingering, work" "$?" "$hl_out"
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
    && grep -Fxq -- "        $hl_rm_shims" <<< "$hl_out" && ! grep -Fq "hooks.gitconfig" <<< "$(grep -F -- "\$ rm -i" <<< "$hl_out")" \
    && grep -Fxq -- "        $hl_verify_step" <<< "$hl_out"; then
    ok "test passed: shims without hooks.gitconfig list only the shims and keep the hooksPath verification step"
  else
    printf '%s\n' "$hl_out" >&2
    fail "test failed: shims left with hooksPath set elsewhere were not reported as expected"
    status=1
  fi
else
  doctor_exit_fail "hook gates shims + stray hooksPath, work" "$?" "$hl_out"
fi
#     HL-f) work with only a pass-through shim left (#361: pre-push is one of
#           the declared stages beyond pre-commit / commit-msg) and no
#           hooksPath anywhere: still lingering, and rm names that shim.
rm -f "$hl_dir/hooks/pre-commit" "$hl_dir/hooks/commit-msg"
printf '#!/bin/sh\n' > "$hl_dir/hooks/pre-push"
: > "$hl_home/.gitconfig"
hl_rm_push="\$ rm -i $(printf '%q' "$hl_dir/hooks/pre-push")"
if hl_out="$(hl_run work)"; then
  if grep -Fxq "$hl_foreign_msg" <<< "$hl_out" && grep -Fxq -- "        $hl_rm_push" <<< "$hl_out"; then
    ok "test passed: a lingering pass-through shim alone (pre-push) is reported and named for removal"
  else
    printf '%s\n' "$hl_out" >&2
    fail "test failed: a lingering pre-push shim alone was not reported as hand removal"
    status=1
  fi
else
  doctor_exit_fail "hook gates pass-through shim lingering, work" "$?" "$hl_out"
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
  doctor_exit_fail "hook gates stray hooksPath, work" "$?" "$hl_out"
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
  doctor_exit_fail "hook gates clean, work" "$?" "$hl_out"
fi
rm -rf "$hl_home"

# GS) Git section (#307): user.useConfigOnly / transfer.credentialsInUrl come
#     from the global config and are warned while not set, and the remote URL
#     scan walks every documented root under ~/src: a repo with credential-like
#     userinfo in each of personal / work / client / sandbox / agent is
#     flagged, its URL (a canary) never shown. Hermetic (env -i, own HOME, no
#     system git config). The ok side of the two keys is checked in GS-2a
#     below (its global config sets both), so it is skipped as root.
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
  doctor_exit_fail "Git section" "$?" "$gs_out"
fi
rm -rf "$gs_home"

# GS-2) remote URL scan INCOMPLETE (#359): a remote config that cannot be
#       read and a root that cannot be listed completely are failures, not
#       clean repos — each is named (the URL, a canary, never shown), the
#       repos that could be read are still flagged and counted, the clean ok
#       is withheld, and doctor stays exit 0; a root that is a symlink is
#       followed, not read as empty. Run from a copy of the checkout so the
#       scanned count is the fixture's alone. Skipped as root (root reads
#       mode 000), and with it the ok side of GS's two Git keys (GS-2a).
if [[ "$(id -u)" != "0" ]]; then
  gs2_home="$fixture_home/gs2-home"
  gs2_copy="$fixture_home/gs2-dotfiles"
  gs2_canary="canary-remote-userinfo-359"
  rm -rf "$gs2_home" "$gs2_copy"
  copy_repo_fixture "$gs2_copy"
  mkdir -p "$gs2_home"
  printf '[user]\n\tuseConfigOnly = true\n[transfer]\n\tcredentialsInUrl = die\n' > "$gs2_home/.gitconfig"
  gs2_git() { env -i PATH="$PATH" HOME="$gs2_home" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
  gs2_run() { env -i PATH="$PATH" HOME="$gs2_home" GIT_CONFIG_NOSYSTEM=1 "$gs2_copy/scripts/doctor.sh" personal 2>&1; }
  #     GS-2a) a repo whose .git/config cannot be read, next to a repo with no
  #            remote: the former is INCOMPLETE, the latter scanned (count 1).
  gs2_git init -q --template= "$gs2_home/src/personal/locked"
  gs2_git -C "$gs2_home/src/personal/locked" remote add origin "https://user:$gs2_canary@example.invalid/x.git"
  gs2_git init -q --template= "$gs2_home/src/personal/clean"
  chmod 000 "$gs2_home/src/personal/locked/.git/config"
  if gs2_out="$(gs2_run)" \
    && grep -Fxq "[warn] remote URL scan INCOMPLETE: the remote config of repo=$gs2_home/src/personal/locked could not be read (permission denied, not a repository, a dangling gitdir pointer or an unparsable config?); its remotes not checked" <<< "$gs2_out" \
    && grep -Fxq "[warn] remote URL scan INCOMPLETE: 1 root(s) / repo(s) could not be listed or read (see above); do NOT read this as clean" <<< "$gs2_out" \
    && grep -Fxq "[ok] scanned repositories: 1" <<< "$gs2_out" \
    && ! grep -Fq "no credential-like userinfo in remote URLs" <<< "$gs2_out" \
    && ! grep -Fq "$gs2_canary" <<< "$gs2_out"; then
    ok "test passed: a remote config that cannot be read reports the scan INCOMPLETE (named, not counted, no false clean)"
  else
    printf '%s\n' "${gs2_out:-<no output>}" >&2
    fail "test failed: an unreadable remote config was read as clean"
    status=1
  fi
  #     GS-2a also has both Git keys set in the global config (#307): each
  #     is reported ok (GS above has them unset and warned).
  if grep -Fxq "[ok] user.useConfigOnly=true" <<< "$gs2_out" \
    && grep -Fxq "[ok] transfer.credentialsInUrl=die" <<< "$gs2_out"; then
    ok "test passed: Git section reports both keys ok once the global config sets them"
  else
    printf '%s\n' "${gs2_out:-<no output>}" >&2
    fail "test failed: Git section must report both keys ok when set"
    status=1
  fi
  chmod 644 "$gs2_home/src/personal/locked/.git/config"
  #     GS-2b) a root with a dir that cannot be opened (the listing fails
  #            partway) and a root that cannot be opened at all (the open
  #            probe fails): both are INCOMPLETE, while the repos the listing
  #            did print (and the now readable one) are flagged.
  gs2_git init -q --template= "$gs2_home/src/work/flagged"
  gs2_git -C "$gs2_home/src/work/flagged" remote add origin "https://user:$gs2_canary@example.invalid/y.git"
  mkdir -p "$gs2_home/src/work/locked-dir" "$gs2_home/src/client"
  chmod 000 "$gs2_home/src/work/locked-dir" "$gs2_home/src/client"
  if gs2_out="$(gs2_run)" \
    && grep -Fxq "[warn] credential-like userinfo in remote URL: repo=$gs2_home/src/personal/locked remote=origin (URL not shown)" <<< "$gs2_out" \
    && grep -Fxq "[warn] credential-like userinfo in remote URL: repo=$gs2_home/src/work/flagged remote=origin (URL not shown)" <<< "$gs2_out" \
    && grep -Fxq "[warn] remote URL scan INCOMPLETE: repositories under $gs2_home/src/work could not be listed completely (permission denied or a symlink loop?); the repos it did not list are not checked" <<< "$gs2_out" \
    && grep -Fxq "[warn] remote URL scan INCOMPLETE: root $gs2_home/src/client could not be opened (permission denied on it or on a parent, not a directory or a symlink loop?); the repos under it are not checked" <<< "$gs2_out" \
    && grep -Fxq "[warn] remotes with credential-like userinfo: 2" <<< "$gs2_out" \
    && grep -Fxq "[warn] remote URL scan INCOMPLETE: 2 root(s) / repo(s) could not be listed or read (see above); do NOT read this as clean" <<< "$gs2_out" \
    && grep -Fxq "[ok] scanned repositories: 3" <<< "$gs2_out" \
    && ! grep -Fq "no credential-like userinfo in remote URLs" <<< "$gs2_out" \
    && ! grep -Fq "$gs2_canary" <<< "$gs2_out"; then
    ok "test passed: a root that cannot be listed completely reports the scan INCOMPLETE while the repos it did list are still flagged"
  else
    printf '%s\n' "${gs2_out:-<no output>}" >&2
    fail "test failed: a root that cannot be listed completely was read as clean or its listed repos were dropped"
    status=1
  fi
  chmod 755 "$gs2_home/src/work/locked-dir" "$gs2_home/src/client"
  #     GS-2c) the parent of every standard root cannot be passed (~/src mode
  #            000): a `-d` test reads all five roots as absent and would skip
  #            them silently with the flagged repos under them, so each root
  #            is named as not openable, nothing under them is counted, and
  #            the clean ok is withheld.
  chmod 000 "$gs2_home/src"
  gs2_rc=0
  gs2_out="$(gs2_run)" || gs2_rc=$?
  gs2_roots_named=0
  for gs2_root in personal work client sandbox agent; do
    grep -Fxq "[warn] remote URL scan INCOMPLETE: root $gs2_home/src/$gs2_root could not be opened (permission denied on it or on a parent, not a directory or a symlink loop?); the repos under it are not checked" <<< "$gs2_out" \
      && gs2_roots_named=$((gs2_roots_named + 1))
  done
  if [[ "$gs2_rc" -eq 0 && "$gs2_roots_named" -eq 5 ]] \
    && grep -Fxq "[warn] remote URL scan INCOMPLETE: 5 root(s) / repo(s) could not be listed or read (see above); do NOT read this as clean" <<< "$gs2_out" \
    && grep -Fxq "[ok] scanned repositories: 0" <<< "$gs2_out" \
    && ! grep -Fq "credential-like userinfo" <<< "$gs2_out" \
    && ! grep -Fq "$gs2_canary" <<< "$gs2_out"; then
    ok "test passed: a parent that cannot be passed reports every root under it INCOMPLETE instead of skipping them as absent"
  else
    printf '%s\n' "${gs2_out:-<no output>}" >&2
    fail "test failed: roots behind a parent that cannot be passed were skipped as absent (rc=$gs2_rc, roots named=$gs2_roots_named)"
    status=1
  fi
  chmod 755 "$gs2_home/src"
  #     GS-2d) a root that is a symlink to a dir outside every root (Codex
  #            review R2): the open probe passes (cd -P opens the target),
  #            but a find without -H does not follow the root, prints
  #            nothing and exits 0 — with no other repo in this HOME, the
  #            flagged and the unreadable repo behind the link would both
  #            vanish into the clean ok. Followed, the flagged one is named
  #            under the root path, the unreadable one INCOMPLETE.
  rm -rf "$gs2_home/src"
  mkdir -p "$gs2_home/src"
  gs2_git init -q --template= "$gs2_home/elsewhere/sandbox/flagged"
  gs2_git -C "$gs2_home/elsewhere/sandbox/flagged" remote add origin "https://user:$gs2_canary@example.invalid/z.git"
  gs2_git init -q --template= "$gs2_home/elsewhere/sandbox/locked"
  gs2_git -C "$gs2_home/elsewhere/sandbox/locked" remote add origin "https://user:$gs2_canary@example.invalid/w.git"
  ln -s "$gs2_home/elsewhere/sandbox" "$gs2_home/src/sandbox"
  chmod 000 "$gs2_home/elsewhere/sandbox/locked/.git/config"
  if gs2_out="$(gs2_run)" \
    && grep -Fxq "[warn] credential-like userinfo in remote URL: repo=$gs2_home/src/sandbox/flagged remote=origin (URL not shown)" <<< "$gs2_out" \
    && grep -Fxq "[warn] remote URL scan INCOMPLETE: the remote config of repo=$gs2_home/src/sandbox/locked could not be read (permission denied, not a repository, a dangling gitdir pointer or an unparsable config?); its remotes not checked" <<< "$gs2_out" \
    && grep -Fxq "[warn] remotes with credential-like userinfo: 1" <<< "$gs2_out" \
    && grep -Fxq "[warn] remote URL scan INCOMPLETE: 1 root(s) / repo(s) could not be listed or read (see above); do NOT read this as clean" <<< "$gs2_out" \
    && grep -Fxq "[ok] scanned repositories: 1" <<< "$gs2_out" \
    && ! grep -Fq "no credential-like userinfo in remote URLs" <<< "$gs2_out" \
    && ! grep -Fq "$gs2_canary" <<< "$gs2_out"; then
    ok "test passed: a root that is a symlink is followed (the repos behind it are flagged or named INCOMPLETE, no false clean)"
  else
    printf '%s\n' "${gs2_out:-<no output>}" >&2
    fail "test failed: the repos behind a root that is a symlink were read as clean"
    status=1
  fi
  chmod 644 "$gs2_home/elsewhere/sandbox/locked/.git/config"
  rm -rf "$gs2_home" "$gs2_copy"
fi

# HG) git hook gates readiness on a module-active profile (#307): the
#     observer side of the two-key gate. Each case plants the agent-tools
#     deploy (all four scripts, a subset, or one not executable) and the
#     wiring (a shim for every declared stage + core.hooksPath at the
#     managed shim directory in its tilde or absolute form, with some shims
#     broken or the hooksPath foreign, or nothing) in an own HOME and pins
#     doctor's exact readiness lines — a deploy list cut short in doctor.sh
#     (e.g. the dispatcher alone) would report a partial deploy as complete
#     and fail here. Hermetic (env -i).
hg_home="$fixture_home/hg-home"
hg_deploy="$hg_home/.claude/agent-tools/scripts"
hg_shims="$hg_home/.config/git-hook-gates/hooks"
hg_all=(personal-git-hook-dispatcher personal-public-safety-gate personal-git-identity-gate personal-ai-trailer-gate)
hg_stages=()
while IFS= read -r hg_decl; do
  case "$hg_decl" in .config/git-hook-gates/hooks/*) hg_stages+=("${hg_decl##*/}") ;; esac
done < <(module_paths git-hook-gates)
# hg_setup WIRED SCRIPT... — a fresh HOME; WIRED=1 plants a shim for every
# stage modules.yaml declares (#361) and core.hooksPath; each SCRIPT is
# planted executable.
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
    for hg_script in "${hg_stages[@]}"; do
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
# HG-1) wired + all four deployed -> one ok for all 23 declared shims (#361),
#       hooksPath ok, deploy complete.
hg_setup 1 "${hg_all[@]}"
hg_expect "wired + complete deploy -> all ok" -- \
  "[ok] shims present and executable: all 23 declared stages in $hg_shims" \
  "[ok] global core.hooksPath -> managed shim directory" \
  "$hg_complete" ! "deploy INCOMPLETE" "deploy incomplete (" "shim missing"
# HG-1b) the same with one pass-through shim (pre-push) gone -> that shim is
#        named, and the all-present line is not claimed.
hg_setup 1 "${hg_all[@]}"
rm -f "$hg_shims/pre-push"
hg_expect "wired + one pass-through shim missing -> named" -- \
  "[warn] shim missing, not a regular file, or not executable: $hg_shims/pre-push (chezmoi apply arms it once the agent-tools deploy is complete)" \
  ! "shims present and executable: all" "shim missing, not a regular file, or not executable: $hg_shims/pre-commit"
# HG-2) wired + the pre-#281 deploy (identity gate missing) -> commits blocked.
hg_setup 1 personal-git-hook-dispatcher personal-public-safety-gate personal-ai-trailer-gate
hg_expect "wired + pre-#281 deploy (identity gate missing) -> BLOCKED warning" -- \
  "$hg_wired_incomplete" ! "$hg_complete"
# HG-3) wired + all four present but one gate not executable -> the same.
hg_setup 1 "${hg_all[@]}"
chmod 644 "$hg_deploy/personal-public-safety-gate"
hg_expect "wired + a non-executable gate -> BLOCKED warning" -- \
  "$hg_wired_incomplete" ! "$hg_complete"
# HG-3b) a searchable directory is not a deployed script, even with -x;
#        core.hooksPath in its absolute form is the managed directory too.
hg_setup 1 "${hg_all[@]}"
rm -f "$hg_deploy/personal-public-safety-gate"
mkdir "$hg_deploy/personal-public-safety-gate"
printf '[core]\n\thooksPath = %s\n' "$hg_shims" > "$hg_home/.gitconfig"
hg_expect "wired (absolute hooksPath) + a directory gate -> BLOCKED warning" -- \
  "[ok] global core.hooksPath -> managed shim directory" \
  "$hg_wired_incomplete" ! "$hg_complete"
# HG-3c) a directory at a shim path must not count as wired (searchable, so
#        -x alone would pass it), nor a shim without its execute bit; a
#        core.hooksPath that points elsewhere is warned, its value never shown.
hg_setup 1 "${hg_all[@]}"
rm -f "$hg_shims/pre-push"
mkdir "$hg_shims/pre-push"
chmod 644 "$hg_shims/post-merge"
hg_canary="canary-hookspath-5c2a"
printf '[core]\n\thooksPath = /elsewhere/%s/hooks\n' "$hg_canary" > "$hg_home/.gitconfig"
hg_expect "a directory shim, a non-executable shim and a foreign hooksPath -> each named" -- \
  "[warn] shim missing, not a regular file, or not executable: $hg_shims/pre-push (chezmoi apply arms it once the agent-tools deploy is complete)" \
  "[warn] shim missing, not a regular file, or not executable: $hg_shims/post-merge (chezmoi apply arms it once the agent-tools deploy is complete)" \
  "[warn] global core.hooksPath points somewhere else (value not shown); the managed gates are NOT on the commit path" \
  "$hg_complete" \
  ! "shims present and executable: all" "shim missing, not a regular file, or not executable: $hg_shims/pre-commit" "$hg_canary"
# HG-4) nothing wired + the dispatcher alone -> both halves incomplete.
hg_setup 0 personal-git-hook-dispatcher
hg_expect "not wired + dispatcher only -> deploy and wiring both incomplete" -- \
  "[warn] shim missing, not a regular file, or not executable: $hg_shims/pre-commit (chezmoi apply arms it once the agent-tools deploy is complete)" \
  "[warn] global core.hooksPath is not set (chezmoi apply arms it via the ~/.gitconfig include once the agent-tools deploy is complete)" \
  "$hg_both_incomplete" ! "$hg_complete"
rm -rf "$hg_home"

# OCP) OpenCode plugins, OPENCODE_CONFIG and herdr's OpenCode view (#263).
#      Static checks only: doctor must never run OpenCode (even `opencode
#      debug config` writes its database), so a PATH-front fake opencode
#      records any invocation and every case asserts it stayed unused. Config
#      files carry a canary "secret" (an MCP header) that must never reach the
#      report. A fake herdr answers `integration status`. Own HOME;
#      OPENCODE_CONFIG is unset unless a case sets it. doctor stays exit 0.
#      XDG_DATA_HOME too (the init marker's log, OCP-i).
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
#     OCP-b) the same plugin also listed in a config's plugin key -> double
#            load warning; the config's other values never show.
printf '{"mcp":{"x":{"headers":{"Authorization":"%s"}}},"plugin":["file:///elsewhere/personal-agent-tools.js","some-npm-plugin@1"]}\n' "$op_canary" > "$op_cfg/opencode.local.json"
if op_out="$(op_run OPENCODE_CONFIG="$op_cfg/opencode.local.json")"; then
  op_expect "a plugin also listed in the active config's plugin key is a double-load warning" "$op_out" \
    "[warn] agent-tools plugin personal-agent-tools is also listed in an OpenCode config's plugin key — OpenCode loads it twice"
else
  doctor_exit_fail "OpenCode plugin listed in config" "$?" "$op_out"
fi
#     OCP-b2) the same listing in opencode.local.json while OPENCODE_CONFIG
#             does not point at it: OpenCode does not read that file here, so
#             it is a note, never a double-load warning. ~/.zshrc.local does
#             not exist yet (OCP-g writes it), so this run is also the case of
#             a local config with OPENCODE_CONFIG unset and no export
#             anywhere -> an action (that check never reads the file).
if op_out="$(op_run)"; then
  op_expect "a listing in an opencode.local.json that is not read here is only a note; that local config with OPENCODE_CONFIG unset (no export anywhere) is an action" "$op_out" \
    "$op_ok_line" \
    "[info] - personal-agent-tools is also listed in opencode.local.json's plugin key, which OpenCode reads only when OPENCODE_CONFIG points at it" \
    "[warn] opencode.local.json exists but OPENCODE_CONFIG is not set — OpenCode ignores the local provider / model / mcp config"
  if grep -Fq "loads it twice" <<< "$op_out"; then
    fail "test failed: an inactive opencode.local.json listing was reported as a double load"
    status=1
  fi
else
  doctor_exit_fail "OpenCode inactive local listing" "$?" "$op_out"
fi
#     OCP-c) names are compared literally, neither as regexes nor as glob
#            patterns: personal-a.b.js and personal-a?b.js on disk do not
#            match personal-a-b.js in the config.
printf '//\n' > "$op_cfg/plugins/personal-a.b.js"
printf '//\n' > "$op_cfg/plugins/personal-a?b.js"
printf '{"plugin":["personal-a-b.js"]}\n' > "$op_cfg/opencode.local.json"
if op_out="$(op_run OPENCODE_CONFIG="$op_cfg/opencode.local.json")"; then
  op_expect "plugin names are matched literally (no regex or glob false positive)" "$op_out" \
    "[ok] agent-tools plugin personal-a.b.js in the global plugins dir" \
    "[ok] agent-tools plugin personal-a?b.js in the global plugins dir"
  if grep -Fq "is also listed in" <<< "$op_out"; then
    fail "test failed: personal-a.b.js or personal-a?b.js was matched against personal-a-b.js"
    status=1
  fi
else
  doctor_exit_fail "OpenCode literal names" "$?" "$op_out"
fi
rm -f "$op_cfg/plugins/personal-a.b.js" "$op_cfg/plugins/personal-a?b.js"
#     OCP-d) a config that is not JSON -> that check is reported as not done,
#            never guessed, never printed.
printf '{ "mcp": "%s", broken\n' "$op_canary" > "$op_cfg/opencode.local.json"
if op_out="$(op_run)"; then
  op_expect "an unreadable config reports the double-load check as not done" "$op_out" \
    "[info] - the plugin key of $op_cfg/opencode.local.json could not be read (not JSON?); double loading via config not checked (contents never shown)" \
    "$op_ok_line"
else
  doctor_exit_fail "OpenCode unreadable config" "$?" "$op_out"
fi
#     OCP-d2) the same broken file as the ACTIVE config (OPENCODE_CONFIG points
#             at it) -> the active branch also reports "not checked".
if op_out="$(op_run OPENCODE_CONFIG="$op_cfg/opencode.local.json")"; then
  op_expect "an unreadable active config reports the double-load check as not done" "$op_out" \
    "[info] - the plugin key of $op_cfg/opencode.local.json could not be read (not JSON?); double loading via config not checked (contents never shown)" \
    "$op_ok_line"
else
  doctor_exit_fail "OpenCode unreadable active config" "$?" "$op_out"
fi
rm -f "$op_cfg/opencode.local.json"
#     OCP-e) no agent-tools plugin -> neutral item.
mv "$op_cfg/plugins/personal-agent-tools.js" "$op_cfg/personal-agent-tools.js.off"
if op_out="$(op_run)"; then
  op_expect "no agent-tools plugin is neutral" "$op_out" \
    "[info] - no agent-tools plugin in ~/.config/opencode/plugins (agent-tools sync deploys personal-*.js there)"
else
  doctor_exit_fail "OpenCode no plugin" "$?" "$op_out"
fi
mv "$op_cfg/personal-agent-tools.js.off" "$op_cfg/plugins/personal-agent-tools.js"
#     OCP-f) extra copies that OpenCode may load twice (.ts next to .js,
#            singular plugin/ dir) -> one warning each. No config file is
#            here, and plugins/personal-agent-tools.js itself still gets the
#            ok line next to the copies (the baseline without a config, which
#            used to be a run of its own).
mkdir -p "$op_cfg/plugin"
printf '//\n' > "$op_cfg/plugins/personal-agent-tools.ts"
printf '//\n' > "$op_cfg/plugin/personal-agent-tools.js"
if op_out="$(op_run)"; then
  op_expect "extra plugin copies are warned; the plugin itself is still ok (no config)" "$op_out" \
    "[warn] agent-tools plugin copy that OpenCode may load twice: $op_cfg/plugins/personal-agent-tools.ts" \
    "[warn] agent-tools plugin copy that OpenCode may load twice: $op_cfg/plugin/personal-agent-tools.js" \
    "$op_ok_line"
else
  doctor_exit_fail "OpenCode extra copies" "$?" "$op_out"
fi
rm -rf "$op_cfg/plugin" "$op_cfg/plugins/personal-agent-tools.ts"
#     OCP-g) OPENCODE_CONFIG against a present opencode.local.json (unset
#            with no export anywhere -> the action, seen in OCP-b2's run).
printf '{}\n' > "$op_cfg/opencode.local.json"
printf 'export OPENCODE_CONFIG="$HOME/.config/opencode/opencode.local.json"\n' > "$op_home/.zshrc.local"
# This run also shows herdr's view of its OpenCode integration, on the
# fixture a run of its own had (other.json is not there yet, but it is not
# read while OPENCODE_CONFIG is unset): a neutral item that leaves
# installing to the user, never an action.
if op_out="$(op_run)"; then
  op_expect "an export in ~/.zshrc.local that this shell did not load is neutral; herdr's OpenCode integration state is shown as herdr's view" "$op_out" \
    "[info] - OPENCODE_CONFIG is exported in ~/.zshrc.local but not set in this shell" \
    "[info] - herdr's own view: opencode integration not installed"
  if grep -Fq "\$ herdr integration install opencode" <<< "$op_out"; then
    fail "test failed: herdr's OpenCode integration must not become an action"
    status=1
  fi
else
  doctor_exit_fail "OPENCODE_CONFIG exported elsewhere" "$?" "$op_out"
fi
if op_out="$(op_run OPENCODE_CONFIG="$op_cfg/opencode.local.json")"; then
  op_expect "OPENCODE_CONFIG pointing at opencode.local.json is ok" "$op_out" \
    "[ok] OPENCODE_CONFIG -> opencode.local.json (local provider / model / mcp config is read)"
else
  doctor_exit_fail "OPENCODE_CONFIG ok" "$?" "$op_out"
fi
printf '{}\n' > "$op_home/other.json"
if op_out="$(op_run OPENCODE_CONFIG="$op_home/other.json")"; then
  op_expect "OPENCODE_CONFIG pointing elsewhere is warned" "$op_out" \
    "[warn] OPENCODE_CONFIG points to a different file than opencode.local.json — that local config is not read"
else
  doctor_exit_fail "OPENCODE_CONFIG elsewhere" "$?" "$op_out"
fi
if op_out="$(op_run OPENCODE_CONFIG="$op_home/missing.json")"; then
  op_expect "OPENCODE_CONFIG pointing at a missing file is warned" "$op_out" \
    "[warn] OPENCODE_CONFIG points to a file that does not exist — OpenCode reads no local config"
else
  doctor_exit_fail "OPENCODE_CONFIG missing file" "$?" "$op_out"
fi
#     OCP-i) the init marker of personal-agent-tools (#311, agent-tools#343):
#            doctor reads OpenCode's existing log (never runs OpenCode) and
#            calls the init confirmed only when the newest marker line's
#            build_id equals the deployed file's marker; everything else is a
#            neutral "not confirmed" with a reason. Log lines carry the canary
#            in other fields and messages, so a line printed into the report
#            fails the case. The three end-to-end cases (OCP-i0) are doctor
#            runs with exactly one init line each; every other case runs the
#            reporter alone, extracted from doctor.sh: its whole output must
#            be the expected line (so no log line, no canary) and OpenCode is
#            never started.
op_log="$op_home/.local/share/opencode/log/opencode.log"
op_hex_a="$(printf '%064d' 0 | tr 0 a)"
op_hex_b="$(printf '%064d' 0 | tr 0 b)"
op_init="agent-tools plugin personal-agent-tools init"
op_deployed="deployed build_id sha256:$op_hex_a"
op_confirmed="[ok] $op_init confirmed by OpenCode's log (build_id sha256:$op_hex_a: some start of this build got through init, not necessarily the latest)"
op_no_marker="[info] - $op_init not confirmed: no init marker in OpenCode's log (not started since the plugin began logging it, started with --pure or a log level above INFO, a rotated log, or an init that threw; $op_deployed)"
op_not_v1="[info] - $op_init not confirmed: the newest init marker is not in the v=1 form this doctor reads ($op_deployed)"
op_no_log="[info] - $op_init not confirmed: no OpenCode log yet (not started here; $op_deployed)"
op_relative_xdg="[info] - $op_init not confirmed: XDG_DATA_HOME is a relative path here, so where OpenCode logs depends on the directory it starts in ($op_deployed)"
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
  local label="$1" expected="$2" out rc=0
  shift 2
  out="$(op_run "$@")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    doctor_exit_fail "OpenCode init: $label" "$rc" "$out"
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
op_not_marker="[info] - $op_init not confirmed: the deployed file's line 1 is not agent-tools' marker for this plugin with a sha256 build_id (agent-tools' doctor checks its marker)"
op_plugin_file() {
  printf '%s\n// personal-agent-tools\n' "$1" > "$op_cfg/plugins/personal-agent-tools.js"
}
op_marker_line() {
  printf '/* agent-tools:managed v=1 repo=agent-tools name=%s target=%s artifact_kind=plugin source=shared/plugins/personal-agent-tools.js build_id=sha256:%s */' "$1" "$2" "$op_hex_a"
}
#     OCP-i0) end to end: doctor hands the deployed file to the reporter and
#             prints its line, from the default log and from the log under
#             its own XDG_DATA_HOME, and a relative XDG_DATA_HOME reaches the
#             reporter as it is.
op_plugin_file "$(op_marker_line personal-agent-tools opencode)"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")"
op_init_case "doctor reports the confirmed init (end to end, the default log)" "$op_confirmed"
# The default log names another build, so only the log under doctor's own
# XDG_DATA_HOME can confirm: doctor passes its environment through.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_b")")"
mkdir -p "$op_home/xdg-e2e/opencode/log"
op_line "$(op_marker "sha256:$op_hex_a")" > "$op_home/xdg-e2e/opencode/log/opencode.log"
op_init_case "doctor reports the confirmed init (end to end, the log under XDG_DATA_HOME)" "$op_confirmed" XDG_DATA_HOME="$op_home/xdg-e2e"
rm -rf "$op_home/xdg-e2e"
# Made absolute on the way, the relative value would point at no log; dropped,
# the default log's other build would show.
op_init_case "doctor passes a relative XDG_DATA_HOME through (end to end) -> not confirmed" "$op_relative_xdg" XDG_DATA_HOME=rel/data
printf '// personal-agent-tools\n' > "$op_cfg/plugins/personal-agent-tools.js"
# From here on the reporter alone, the way CL-U runs the matcher: the
# function is extracted from doctor.sh, and op_init_case is redefined to
# call it in a bash of its own.
op_fn="$(sed -n '/^  opencode_plugin_init_report() {/,/^  }$/p' "$SCRIPT_DIR/doctor.sh")"
if [[ -z "$op_fn" || "$(printf '%s\n' "$op_fn" | tail -n 1)" != "  }" ]]; then
  fail "test failed: opencode_plugin_init_report not found in doctor.sh"
  status=1
fi
# op_init_case LABEL EXPECTED_LINE [VAR=value...] — the reporter on the
# deployed file, with the fake opencode first on PATH: it exits 0, its whole
# output is EXPECTED_LINE (nothing else, so no log line and no canary) and
# OpenCode stays unrun.
op_init_case() {
  local label="$1" expected="$2" out rc=0
  shift 2
  out="$(env -u XDG_DATA_HOME HOME="$op_home" PATH="$op_fakebin:$PATH" "$@" bash -c 'set -euo pipefail; source "$1"; eval "$2"; opencode_plugin_init_report "$3"' \
    _ "$SCRIPT_DIR/lib-policy.sh" "$op_fn" "$op_cfg/plugins/personal-agent-tools.js" 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 && "$out" == "$expected" && ! -e "$op_ran" ]]; then
    ok "test passed: OpenCode init: $label"
  else
    printf 'rc=%s\n%s\n' "$rc" "$out" >&2
    [[ ! -e "$op_ran" ]] || { printf 'ran opencode: %s\n' "$(head -n 1 "$op_ran")" >&2; rm -f "$op_ran"; }
    fail "test failed: OpenCode init: $label (expected exactly: $expected)"
    status=1
  fi
}
#     OCP-i1) line 1 is not agent-tools' marker for this plugin -> no build_id
#             to compare: no marker (the fixture so far), a plain comment that
#             merely carries a build_id, another plugin's marker, a marker for
#             another target (Codex review R1, PR #325). A matching log line is
#             in place, so a lax marker check would turn into "confirmed".
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
#     OCP-i2) no log at all -> not started.
op_init_case "no OpenCode log -> not confirmed (not started)" "$op_no_log"
#     OCP-i3) a log without the marker.
op_log_write
op_init_case "log without the marker -> not confirmed" "$op_no_marker"
#     OCP-i4) the newest marker matches, quoted (as 1.18.30 writes it) or bare.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")"
op_init_case "quoted marker with the deployed build_id -> confirmed" "$op_confirmed"
# A message with spaces is always quoted in OpenCode's key=value line, so an
# unquoted one is not the plugin's marker line.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")" bare)"
op_init_case "unquoted marker text -> no marker" "$op_no_marker"
#     OCP-i5) only the newest marker counts, whichever way round.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" "$(op_line "$(op_marker "sha256:$op_hex_b")")"
op_init_case "newest marker from another build -> not confirmed, naming both" \
  "[info] - $op_init not confirmed: the newest init marker is from build_id sha256:$op_hex_b, not the deployed sha256:$op_hex_a (OpenCode not started since the last sync, or a process still on the old build)"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_b")")" "$(op_line "$(op_marker "sha256:$op_hex_a")")"
op_init_case "an older marker from another build, newest matches -> confirmed" "$op_confirmed"
#     OCP-i6) build_id unknown.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" "$(op_line "$(op_marker unknown)")"
op_init_case "newest marker with build_id unknown -> not confirmed" \
  "[info] - $op_init not confirmed: the newest init marker carries build_id unknown (the plugin could not read its own marker; $op_deployed)"
#     OCP-i7) lines outside the v=1 form, each newest after a matching one: a
#             newer version, an extra token, 65 hex digits, uppercase hex.
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" \
  "$(op_line "agent-tools:plugin-init v=2 name=personal-agent-tools build_id=sha256:$op_hex_a")"
op_init_case "newest marker in v=2 -> not confirmed" "$op_not_v1"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" "$(op_line "$(op_marker "sha256:$op_hex_a") extra")"
op_init_case "newest marker with an extra token -> not confirmed" "$op_not_v1"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" "$(op_line "$(op_marker "sha256:${op_hex_a}a")")"
op_init_case "newest marker with 65 hex digits -> not confirmed" "$op_not_v1"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" "$(op_line "$(op_marker "sha256:$(printf '%064d' 0 | tr 0 A)")")"
op_init_case "newest marker with uppercase hex -> not confirmed" "$op_not_v1"
#     OCP-i8) marker text that does not open the message, or names another
#             plugin, is no marker at all.
op_log_write "$(op_line "grep $(op_marker "sha256:$op_hex_a")")" \
  "$(op_line "agent-tools:plugin-init v=1 name=personal-agent-tools-x build_id=sha256:$op_hex_a")"
op_init_case "marker text inside another message, or another plugin's marker -> no marker" "$op_no_marker"
#             ... and a message that only quotes the marker after other text,
#             even with its own quote, is not the marker: the line's first
#             message field decides (Codex review R1, PR #325).
op_log_write "$(op_line "copied message=\"$(op_marker "sha256:$op_hex_a")\" extra")"
op_init_case "a quoted marker inside another message -> no marker" "$op_no_marker"
#             ... nor does such a later line hide an earlier real marker: the
#             newest line is picked by its first message field too (Codex
#             review R2, PR #325).
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")" \
  "$(op_line "copied message=\"$(op_marker "sha256:$op_hex_b")\" extra")"
op_init_case "a real marker, then a line quoting another marker -> confirmed" "$op_confirmed"
#     OCP-i9) XDG_DATA_HOME moves the log: absolute -> read there; empty -> the
#             default; relative -> not confirmed (it depends on OpenCode's cwd).
op_log_write
mkdir -p "$op_home/xdg-data/opencode/log"
op_line "$(op_marker "sha256:$op_hex_a")" > "$op_home/xdg-data/opencode/log/opencode.log"
op_init_case "absolute XDG_DATA_HOME -> the log there" "$op_confirmed" XDG_DATA_HOME="$op_home/xdg-data/"
op_log_write "$(op_line "$(op_marker "sha256:$op_hex_a")")"
op_init_case "empty XDG_DATA_HOME -> the default log" "$op_confirmed" XDG_DATA_HOME=
op_init_case "absolute XDG_DATA_HOME without a log -> not started" "$op_no_log" XDG_DATA_HOME="$op_home/xdg-none"
op_init_case "relative XDG_DATA_HOME -> not confirmed" "$op_relative_xdg" XDG_DATA_HOME=rel/data
#     OCP-i10) a log that is not a regular file (a FIFO would block a read:
#              Codex review R1, PR #325) or cannot be read (skipped where
#              permissions do not bind, e.g. as root).
#              The FIFO case runs the reporter in the background with a
#              deadline of 30s: should it read the FIFO, it would block for
#              good, so it is killed (with what it started) and the case fails
#              instead of hanging the suite (Codex review R2, PR #325). Its
#              result reaches the suite's status through its output.
mv "$op_log" "$op_log.keep"
mkfifo "$op_log"
op_init_case "a FIFO in place of the log -> not confirmed, no hang" \
  "[info] - $op_init not confirmed: OpenCode's log is not a regular file ($op_deployed)" > "$fixture_home/op-fifo.out" 2>&1 &
op_fifo_pid=$!
op_fifo_waited=0
while kill -0 "$op_fifo_pid" 2>/dev/null && [[ "$op_fifo_waited" -lt 30 ]]; do
  sleep 1
  op_fifo_waited=$((op_fifo_waited + 1))
done
if kill -0 "$op_fifo_pid" 2>/dev/null; then
  kill_tree "$op_fifo_pid"
  wait "$op_fifo_pid" 2>/dev/null || true
  fail "test failed: OpenCode init: a FIFO in place of the log hung the reporter (killed after 30s)"
  status=1
else
  wait "$op_fifo_pid" || true
  cat "$fixture_home/op-fifo.out"
  grep -q '^\[ok\] test passed' "$fixture_home/op-fifo.out" || status=1
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
#     committed repo (personal) and a fake chezmoi on PATH whose status
#     reports two drifted targets — it always yields a few actions (identity
#     files, the two drift lines, ...); the assertions are structural
#     (count = numbered lines, each with >= 1 step line, the same list in
#     both modes), so they do not pin which host-side warnings a given
#     environment produces. The fake keeps the drift section the same with
#     or without a host chezmoi (the not-initialized / not-found skips are
#     DRIFT-B's).
na_home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-doctor-na.XXXXXX")"
mkdir -p "$na_home/src/personal"
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
#     NA-a) full run: summary section is last, count matches, steps present.
if na_out="$(HOME="$na_home" PATH="$na_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
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
if na_only="$(HOME="$na_home" PATH="$na_fakebin:$PATH" "$SCRIPT_DIR/doctor.sh" personal --actions-only 2>&1)"; then
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
  #     NA-b2) drift step path: a chezmoi status line with a single-column
  #            status (" M x") must yield "~/x", not "~/M x" (the path
  #            starts after the fixed two status columns + space).
  if grep -F -q -- "        \$ chezmoi diff $na_home/.gitconfig   #" <<< "$na_only" \
    && grep -F -q -- "        \$ chezmoi diff $na_home/.npmrc   #" <<< "$na_only" \
    && ! grep -F -q -- "/M .gitconfig" <<< "$na_only"; then
    ok "test passed: drift steps point at the path after the two status columns (' M x' -> ~/x)"
  else
    printf '%s\n' "$na_only" >&2
    fail "test failed: drift step path extraction wrong"
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
#     NA-c2) a second profile is a usage error too (exit 2, no report),
#            whichever side of --actions-only it sits: before #329 the last
#            one silently won, so `doctor.sh work personal` reported
#            personal as if it were the requested profile.
for na_args in "work personal" "work --actions-only personal"; do
  na_rc=0
  # shellcheck disable=SC2086 # split on purpose: each case is a word list
  na_bad="$(HOME="$na_home" "$SCRIPT_DIR/doctor.sh" $na_args 2>&1)" || na_rc=$?
  if [[ "$na_rc" -eq 2 ]] && grep -Fq "too many arguments (usage: doctor.sh [PROFILE] [--actions-only])" <<< "$na_bad" \
    && ! grep -Fq "doctor profile:" <<< "$na_bad" && ! grep -Fq "next actions" <<< "$na_bad"; then
    ok "test passed: a second profile ($na_args) -> usage error (exit 2) without running the report"
  else
    printf 'rc=%s\n%s\n' "$na_rc" "$na_bad" >&2
    fail "test failed: a second profile ($na_args) must be rejected with exit 2 and no report"
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
#     NA-d1) an action without steps (or ending in an empty one) recorded
#            last still leaves report_actions at status 0: doctor closes
#            with it under set -e, so a non-zero return would turn the
#            report-only run into exit 1 (#329).
na_nostep="$(bash -c 'set -euo pipefail; source "$1"
action "with a step" "\$ step one"
action "no step"
report_actions
action "empty last step" "\$ step two" ""
report_actions
printf "after\n"' _ "$SCRIPT_DIR/lib-policy.sh" 2>&1)" && na_nostep_rc=0 || na_nostep_rc=$?
if [[ "$na_nostep_rc" -eq 0 && "$na_nostep" == *$'[info] 2. no step\n[warn] empty last step\n[info] == next actions (3) =='* && "$na_nostep" == *$'        $ step two\nafter' ]]; then
  ok "test passed: report_actions returns 0 when the last action has no (or an empty last) step"
else
  printf 'rc=%s\n%s\n' "$na_nostep_rc" "$na_nostep" >&2
  fail "test failed: report_actions must return 0 when the last action has no (or an empty last) step"
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
#           op / codex / opencode / brew / npm stubs (this PATH replaces the
#           one carrying them, and a system dir can hold a real npm, #306,
#           #458). A herdr in the system dirs would make this case run the
#           real tool, so it fails up front instead of running doctor.
rm -f "$hi_fakebin/herdr"
ln -sf "$(command -v yq)" "$hi_fakebin/yq"
for host_tool in op codex opencode brew npm; do
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

fi # end of part 2

# ---- part 3 of 3 (TEST_DOCTOR_PART=3): from the AI policy cases (AIP) to
# the end ----
if doctor_part 3; then

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
# aip_run [VAR=VALUE...] — one personal doctor run on the fixture HOME with the
# fake codex in front of PATH and the given env (a later HOME= / PATH= wins):
# the output in aip_out, the exit status in aip_rc, so a run that does not
# exit 0 is reported with its status, not as a line missing (#378).
aip_run() {
  aip_rc=0
  aip_out="$(env HOME="$fixture_home" PATH="$codex_fakebin:$PATH" "$@" \
    "$DOTFILES_ROOT/scripts/doctor.sh" personal 2>&1)" || aip_rc=$?
}
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
# silently skip the home-trust warn. The real project's header carries a
# trailing comment with a canary (#292): the whole run must count that path
# and never echo the comment.
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

[projects."$fixture_home/real-project"] # CANARY_HEADER_COMMENT_292
trust_level = "trusted"
TOML
aip_run CODEX_FAKE_ALLOWS="git push,gh pr create,gh auth status --show-token,gh auth status -t,gh auth token,env,op read op://example/item/field,security -q find-generic-password -s example.invalid -w"
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "Codex permission surface" "$aip_rc" "$aip_out"
elif grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'git push'" <<< "$aip_out" \
  && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'gh pr create'" <<< "$aip_out" \
  && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'gh auth status --show-token'" <<< "$aip_out" \
  && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'gh auth status -t'" <<< "$aip_out" \
  && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'gh auth token'" <<< "$aip_out" \
  && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'env'" <<< "$aip_out" \
  && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'op read op://example/item/field'" <<< "$aip_out" \
  && grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'security -q find-generic-password -s example.invalid -w'" <<< "$aip_out" \
  && grep -Fq "Codex projects trust covers the WHOLE home directory" <<< "$aip_out" \
  && grep -Fxq "        edit ~/.codex/config.toml: remove the project entry for this path (or set its trust_level to untrusted)" <<< "$aip_out" \
  && grep -Fq "stale Codex projects trust (path no longer exists): $fixture_home/gone-project" <<< "$aip_out" \
  && grep -Fxq "        edit ~/.codex/config.toml: remove the project entry for this path" <<< "$aip_out" \
  && ! grep -Fq "gone-untrusted" <<< "$aip_out" \
  && grep -Fq "3 path(s) trusted" <<< "$aip_out" \
  && ! grep -Fq "CANARY_CODEX_ENV_LEAK_3b9d" <<< "$aip_out" \
  && ! grep -Fq "CANARY_HEADER_" <<< "$aip_out" \
  && ! grep -Fq "CANARY_RULES_LEAK_a71c" <<< "$aip_out"; then
  ok "test passed: allowed probes warned by name, trusted whole-home (compact TOML) + trusted stale (single-quoted) warned with their remedy steps, untrusted entry ignored, contents never echoed"
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: Codex permission-surface watch (probes/projects trust) not reported as expected"
  status=1
fi

# The scan reads config.toml with a TOML parser (yq, #309), so every valid
# spelling of a project table counts as TOML says — a [projects] table,
# inline tables, dotted / quoted / escaped keys, multi-line strings — and only
# what does not read as a map of project tables (a TOML error, projects as a
# string or an array, a trusted key with a control character) is INCOMPLETE,
# never "0 trusted". Each case writes the whole config line by line (printf
# '%s\n', so a TOML escape such as j stays literal), with a real trusted
# project and an MCP env canary that must never be printed. The cases run
# the watch alone: report_codex_projects_trust, taken from doctor.sh, in a
# bash of its own under set -euo pipefail (doctor runs it under errexit, so
# it must return 0 there too). The main AIP case and AIP-2 stay full doctor
# runs, which pin the watch's wiring into the personal report and the exit 0
# of the whole run.
aip_real_header="[projects.\"$fixture_home/real-project\"]"
aip_bs='\'   # one backslash: the escape cases spell TOML escapes (u006a = j) with it
aip_trust_fn="$(sed -n '/^report_codex_projects_trust() {/,/^}/p' "$SCRIPT_DIR/doctor.sh")"
if [[ -z "$aip_trust_fn" ]]; then
  fail "test failed: report_codex_projects_trust not found in doctor.sh"
  status=1
fi
# aip_fn_exit_fail FUNCTION LABEL RC OUTPUT — a watch function taken from
# doctor.sh did not return 0 in its own bash: show its output and status, then
# fail. Like doctor_exit_fail, but it names the function, since no doctor run
# happens in these cases (the trust forms here, the result shapes in AIP-4).
aip_fn_exit_fail() {
  printf '%s\n' "$4" >&2
  fail "test failed: $1 must return 0 under set -euo pipefail ($2): exited $3"
  status=1
}
# aip_trust_case LABEL EXPECT LINE... — EXPECT is "incomplete" or a count.
# Skipped (after the failure above) when the watch was not found.
aip_trust_case() {
  local label="$1" expect="$2"
  shift 2
  [[ -n "$aip_trust_fn" ]] || return 0
  printf '%s\n' "$@" '[mcp_servers.fake.env]' 'FAKE_TOKEN = "CANARY_FORM_ENV_309"' \
    > "$fixture_home/.codex/config.toml"
  aip_rc=0
  aip_out="$(HOME="$fixture_home" \
    bash -c 'set -euo pipefail; source "$1"; eval "$2"; report_codex_projects_trust' _ "$SCRIPT_DIR/lib-policy.sh" "$aip_trust_fn" 2>&1)" || aip_rc=$?
  if [[ "$aip_rc" -ne 0 ]]; then
    aip_fn_exit_fail report_codex_projects_trust "trust form: $label" "$aip_rc" "$aip_out"
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
  "$aip_real_header # C:${aip_bs}work CANARY_FORM_COMMENT" 'trust_level = "trusted"'
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
#        lines (with the probe count) name the managed baseline and say it is
#        holding (the counterpart of AIP-6b's NOT-in-effect case), no warns
#        from this watch. The shim log pins the EXACT probe set
#        (policy-derived contract): a probe silently dropped from doctor.sh
#        fails this test (coverage regression guard).
cat > "$fixture_home/.codex/config.toml" <<TOML
[projects."$fixture_home/real-project"]
trust_level = "trusted"
TOML
aip_probe_log="$fixture_home/.codex-probe-log"
: > "$aip_probe_log"
expected_probes=$'curl https://example.invalid\nenv\ngh api --method POST repos/o/r/issues\ngh auth login\ngh auth status --show-token\ngh auth status -t\ngh auth token\ngh issue close\ngh issue comment\ngh issue create\ngh issue delete\ngh issue edit\ngh issue transfer\ngh pr close\ngh pr comment\ngh pr create\ngh pr edit\ngh pr merge\ngh release create\ngh release delete\ngh release edit\ngh release upload\ngh repo archive\ngh repo delete\ngh repo edit\ngh repo rename\ngh secret set\ngit clone https://example.invalid/repo\ngit push\nop item get example\nop read op://example/item/field\nprintenv\nsecurity -q find-generic-password -s example.invalid -w\nsecurity dump-keychain\nsecurity export -k login.keychain\nsecurity find-generic-password -s example.invalid -w\nsecurity find-internet-password -s example.invalid -w\nsudo -v\nwget https://example.invalid'
aip_run CODEX_FAKE_ALLOWS="" CODEX_FAKE_LOG="$aip_probe_log"
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "Codex permission surface, clean" "$aip_rc" "$aip_out"
else
  if grep -Fxq "[ok] Codex approval-rules baseline managed: ~/.codex/rules/default.rules (accumulated grants show as drift; apply resets to the vetted read-only baseline)" <<< "$aip_out" \
    && grep -Fxq "[ok] no outward/escalation/credential-display probe is auto-allowed by the live Codex rules (39 probes over 1 rules file(s) via codex execpolicy; read-only baseline holding)" <<< "$aip_out" \
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
fi

# AIP-3) Engine-evaluation failure (codex execpolicy exits 1 — broken rules
#        file, incompatible codex): the scan must surface INCOMPLETE and must
#        NOT emit the clean ok (a failure that reads as clean is the fail-open
#        false-clean the review flagged). doctor stays exit 0 (report-only).
aip_run CODEX_FAKE_ALLOWS="" CODEX_FAKE_MODE="fail"
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "probe-evaluation failure" "$aip_rc" "$aip_out"
elif grep -Fq "rules-semantics scan INCOMPLETE" <<< "$aip_out" \
  && ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
  ok "test passed: probe-evaluation failure reports scan INCOMPLETE and suppresses the clean ok (no fail-open false-clean)"
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: probe-evaluation failure did not surface as INCOMPLETE (or still claimed clean)"
  status=1
fi
# AIP-4) Interpret the effective decision, not a nested rule match (#210).
# Invalid JSON and unknown result shapes must remain report-only INCOMPLETE.
# As with the trust forms, each result shape runs the probe loop alone:
# report_codex_rules_probes and the two probe lists it reads, taken from
# doctor.sh, in a bash of its own under set -euo pipefail with the fake codex
# in front of PATH (it must return 0 there too). AIP-2 keeps the full run
# that pins the probe set and the wiring. Skipped (after a failure) when one
# of the three is not found.
aip_probe_fns="$(sed -n '/^outward_probe_commands=(/,/^)$/p; /^secret_read_probe_commands=(/,/^)$/p; /^report_codex_rules_probes() {/,/^}/p' "$SCRIPT_DIR/doctor.sh")"
if [[ "$aip_probe_fns" != *"outward_probe_commands=("* \
  || "$aip_probe_fns" != *"secret_read_probe_commands=("* \
  || "$aip_probe_fns" != *"report_codex_rules_probes() {"* ]]; then
  fail "test failed: outward_probe_commands / secret_read_probe_commands / report_codex_rules_probes not found in doctor.sh"
  status=1
  aip_probe_fns=""
fi
aip_result="$fixture_home/.codex-result"
for aip_case in forbidden prompt pretty-allow malformed empty unknown missing null-decision non-object; do
  [[ -n "$aip_probe_fns" ]] || break
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
  aip_rc=0
  aip_out="$(HOME="$fixture_home" PATH="$codex_fakebin:$PATH" CODEX_FAKE_RESULT="$aip_result" \
    bash -c 'set -euo pipefail; source "$1"; eval "$2"; report_codex_rules_probes' _ "$SCRIPT_DIR/lib-policy.sh" "$aip_probe_fns" 2>&1)" || aip_rc=$?
  if [[ "$aip_rc" -ne 0 ]]; then
    aip_fn_exit_fail report_codex_rules_probes "Codex result $aip_case" "$aip_rc" "$aip_out"
  else
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
aip_run CODEX_FAKE_ALLOWS="git push" CODEX_FAKE_ALLOWS_IF_RULES="extra.rules" \
  CODEX_FAKE_RULES_LOG="$aip_rules_log"
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "unmanaged Codex rules files" "$aip_rc" "$aip_out"
else
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
fi
# Same tree, nothing allowed: the clean ok counts the files it probed.
aip_run CODEX_FAKE_ALLOWS=""
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "unmanaged Codex rules files, clean" "$aip_rc" "$aip_out"
elif grep -Fq "probes over 6 rules file(s) via codex execpolicy" <<< "$aip_out"; then
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
aip_run CODEX_FAKE_ALLOWS=""
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "symlinked default.rules" "$aip_rc" "$aip_out"
elif grep -Fq "Codex approval-rules baseline is a symlink" <<< "$aip_out" \
  && ! grep -Fq "Codex approval-rules baseline managed" <<< "$aip_out" \
  && ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
  ok "test passed: a symlinked default.rules is warned as not in effect and is not probed"
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: symlinked default.rules not reported as not in effect"
  status=1
fi
# Same symlinked baseline beside a (clean) sibling file: the sibling is still
# probed, and the clean ok must not claim the baseline is holding.
: > "$aip_rules_dir/extra.rules"
aip_run CODEX_FAKE_ALLOWS=""
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "symlinked default.rules beside a sibling" "$aip_rc" "$aip_out"
elif grep -Fq "probes over 1 rules file(s) via codex execpolicy; the managed baseline is NOT in effect)" <<< "$aip_out" \
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
  aip_run CODEX_FAKE_ALLOWS=""
  if [[ "$aip_rc" -ne 0 ]]; then
    doctor_exit_fail "unreadable rules dir" "$aip_rc" "$aip_out"
  elif grep -Fq "Codex rules dir could not be opened (~/.codex/rules" <<< "$aip_out" \
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
aip_run CODEX_FAKE_ALLOWS="git push" CODEX_FAKE_ALLOWS_IF_RULES="extra.rules" \
  CODEX_FAKE_RULES_LOG="$aip_rules_log"
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "symlinked rules dir" "$aip_rc" "$aip_out"
elif grep -Fq "outward/escalation/credential-display probe auto-allowed by live Codex rules: 'git push'" <<< "$aip_out" \
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
aip_run PATH="$aip_findbin:$codex_fakebin:$PATH" CODEX_FAKE_ALLOWS=""
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "rules listing failing after partial output" "$aip_rc" "$aip_out"
elif grep -Fq "Codex rules dir could not be listed completely (~/.codex/rules" <<< "$aip_out" \
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
aip_run CODEX_FAKE_ALLOWS=""
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "non-directory rules path" "$aip_rc" "$aip_out"
elif grep -Fq "Codex rules dir could not be opened (~/.codex/rules" <<< "$aip_out" \
  && ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
  ok "test passed: a non-directory rules path reports the scan INCOMPLETE"
else
  printf '%s\n' "$aip_out" >&2
  fail "test failed: a non-directory rules path was not reported as INCOMPLETE"
  status=1
fi
rm -f "$aip_rules_dir"
mv "$fixture_home/.codex/rules-real" "$aip_rules_dir"

# AIP-13) Only a confirmed absence is "no rules": ~/.codex/rules a symlink into
#         a parent without search permission is a read error for Codex, so it
#         must be INCOMPLETE — `test -e` alone would call it absent and report
#         only "not applied yet". The absence test matches the strerror at the
#         END of the message only, so the HOME here holds "No such file or
#         directory" in its path: that must not turn the permission error into
#         "absent" either. Skipped as root.
if [[ "$(id -u)" != "0" ]]; then
  aip_odd_home="$fixture_home/odd: No such file or directory"
  mkdir -p "$aip_odd_home/.codex" "$aip_odd_home/locked-parent/rules"
  : > "$aip_odd_home/locked-parent/rules/default.rules"
  ln -s "$aip_odd_home/locked-parent/rules" "$aip_odd_home/.codex/rules"
  chmod 000 "$aip_odd_home/locked-parent"
  aip_run HOME="$aip_odd_home" CODEX_FAKE_ALLOWS=""
  if [[ "$aip_rc" -ne 0 ]]; then
    doctor_exit_fail "rules dir behind an unsearchable parent, HOME holding the strerror words" "$aip_rc" "$aip_out"
  elif grep -Fq "Codex rules dir could not be opened (~/.codex/rules" <<< "$aip_out" \
    && ! grep -Fq "Codex approval-rules baseline not applied yet" <<< "$aip_out" \
    && ! grep -Fq "no outward/escalation/credential-display probe is auto-allowed" <<< "$aip_out"; then
    ok "test passed: a rules dir behind an unsearchable parent is INCOMPLETE, not absent (also under a HOME containing the strerror words)"
  else
    printf '%s\n' "$aip_out" >&2
    fail "test failed: an unresolvable rules dir was read as absent (HOME containing the strerror words)"
    status=1
  fi
  chmod 755 "$aip_odd_home/locked-parent"
  rm -rf "${aip_odd_home:?}"
fi

# AIP-12) A dangling ~/.codex/rules symlink IS a confirmed absence (Codex's
#         NotFound -> no rules): "not applied yet", not INCOMPLETE.
mv "$aip_rules_dir" "$fixture_home/.codex/rules-real"
ln -s "$fixture_home/.codex/rules-gone" "$aip_rules_dir"
aip_run CODEX_FAKE_ALLOWS=""
if [[ "$aip_rc" -ne 0 ]]; then
  doctor_exit_fail "dangling rules dir symlink" "$aip_rc" "$aip_out"
elif grep -Fq "Codex approval-rules baseline not applied yet" <<< "$aip_out" \
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
#     (and one org / client level down in work and client, #445) and
#     reports the ones no deny / ask stops (the live floor
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
# cl_run [PROFILE] — one doctor run on the CL HOME: the output in cl_out, the
# exit status in cl_rc (#378, as aip_run).
cl_run() {
  cl_rc=0
  cl_out="$(HOME="$cl_home" "$SCRIPT_DIR/doctor.sh" "${1:-personal}" 2>&1)" || cl_rc=$?
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
cl_w="$cl_home/src/work/acme/repo-w/.claude/settings.local.json"
cl_x="$cl_home/src/client/cli/repo-x/.claude/settings.local.json"
cl_o="$cl_home/src/client/cli/.claude/settings.local.json"
cl_y="$cl_home/src/client/cli/.repo-y/.claude/settings.local.json"
cl_deep_w="$cl_home/src/work/acme/repo-w/nested/.claude/settings.local.json"
cl_write "$cl_a" "{\"permissions\":{\"allow\":[\"Bash(git push:*)\",\"Bash(npm test:*)\",\"Bash(gh * create)\",\"Bash(sudo.*)\",\"Bash(gh *:*)\",\"Bash(git clone https://example.invalid/**/repo)\",\"Bash(curl -H \\\"x: $cl_canary\\\" *)\",\"Read(~/notes/**)\",42]}}"
cl_write "$cl_b" '{"permissions":{"allow":["Bash(gh auth token)","Bash(gh pr merge:*)","Bash(wget:*)"]}}'
cl_write "$cl_c" '{"permissions":{"allow":["Bash"]}}'
cl_write "$cl_d" "{\"permissions\":{\"allow\":[\"Bash($cl_canary)\""
cl_write "$cl_deep" '{"permissions":{"allow":["Bash"]}}'
cl_write "$cl_h" '{"permissions":{"allow":["Bash(sudo -v)"]}}'
cl_write "$cl_w" '{"permissions":{"allow":["Bash(git push:*)"]}}'
cl_write "$cl_x" '{"permissions":{"allow":["Bash(git push:*)"]}}'
cl_write "$cl_o" '{"permissions":{"allow":["Bash(gh pr create)"]}}'
env -i PATH="$PATH" HOME="$cl_home" GIT_CONFIG_NOSYSTEM=1 \
  git init -q --template= "$cl_home/src/client/cli"
cl_write "$cl_y" '{"permissions":{"allow":["Bash(git push:*)"]}}'
ln -s cli "$cl_home/src/client/mirror"
cl_write "$cl_deep_w" '{"permissions":{"allow":["Bash"]}}'
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
#       NBSP-led allow; this run uses LC_ALL=C), the repos one org / client
#       level down in work and client read as the convention places them
#       (#445; the repos directly under those roots stay read as before),
#       a dot-named repo there read too, an org directory that is itself a
#       git repo with its own .claude (client/cli) read once and still
#       listed, so the repos under it are read once too, the repos of an org
#       reached twice (client/mirror, a symlink to client/cli) read once,
#       and a checkout below such a repo not read.
LC_ALL=C cl_run
if [[ "$cl_rc" -ne 0 ]]; then
  doctor_exit_fail "Claude project-level allows" "$cl_rc" "$cl_out"
else
  if grep -Fxq "[warn] 4 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_a: 'git push', 'git clone https://example.invalid/repo', 'gh pr create', 'gh issue create' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "        edit $cl_a: remove the allow rules covering those commands (approve them per use instead)" <<< "$cl_out" \
    && grep -Fxq "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_b: 'wget https://example.invalid' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "[warn] 28 outward probe(s) auto-allowed for Claude by project-level allow rules in $(printf '%q' "$cl_c"): 'git push', 'git clone https://example.invalid/repo', 'gh pr create', 'gh pr comment', 'gh pr edit' and 23 more — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "[warn] 5 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_f: 'gh pr close', 'gh repo edit', 'gh repo archive', 'gh repo rename', 'sudo -v' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_h: 'sudo -v' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "[info] - the permission rules of $cl_d could not be read (not a regular file holding JSON of the expected shape?); not checked (contents never shown)" <<< "$cl_out" \
    && grep -Fxq "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_w: 'git push' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_x: 'git push' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && grep -Fxq "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_o: 'gh pr create' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && [[ "$(grep -F "[warn] " <<< "$cl_out" | grep -Fc "project-level allow rules in $cl_w: ")" -eq 1 ]] \
    && [[ "$(grep -F "[warn] " <<< "$cl_out" | grep -Fc "project-level allow rules in $cl_x: ")" -eq 1 ]] \
    && [[ "$(grep -F "[warn] " <<< "$cl_out" | grep -Fc "project-level allow rules in $cl_o: ")" -eq 1 ]] \
    && grep -Fxq "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_y: 'git push' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out" \
    && [[ "$(grep -F "[warn] " <<< "$cl_out" | grep -Fc "project-level allow rules in $cl_y: ")" -eq 1 ]] \
    && ! grep -Fq "$cl_home/src/client/mirror/" <<< "$cl_out" \
    && ! grep -Fq "$cl_deep_w" <<< "$cl_out" \
    && ! grep -Fq "$cl_deep" <<< "$cl_out" \
    && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out" \
    && ! grep -Fq "$cl_canary" <<< "$cl_out"; then
    ok "test passed: project-level Claude allows covering outward probes are reported per file, floor deny / ask respected, contents never shown"
  else
    printf '%s\n' "$cl_out" >&2
    fail "test failed: project-level Claude allow report drifted"
    status=1
  fi
fi

# CL-2) files whose allows the floor already stops (or that cover no probe)
#       -> the ok line, counting the files read.
rm -rf "$cl_home/src"
cl_write "$cl_b" '{"permissions":{"allow":["Bash(gh auth token)","Bash(gh  pr merge:*)","Bash(npm test *)"]}}'
cl_write "$cl_home/src/sandbox/repo-e/.claude/settings.local.json" '{"permissions":{"deny":["Bash"]}}'
cl_run
if [[ "$cl_rc" -ne 0 ]]; then
  doctor_exit_fail "floor-stopped project allows" "$cl_rc" "$cl_out"
elif grep -Fxq "[ok] no project-level Claude allow rule covers an outward probe (30 probes over 2 settings file(s) in this repo, the repos directly under the standard project roots and those one org (client) level down in work and client)" <<< "$cl_out" \
  && ! grep -Fq "auto-allowed for Claude" <<< "$cl_out"; then
  ok "test passed: allows the floor stops are not reported; the ok line counts the files read"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: floor-covered project allows must leave the ok line"
  status=1
fi

# CL-2b) a file that cannot be read keeps the result from being clean: no ok
#        line, an item saying so (here the only other files are clean). An
#        allow list of the wrong shape counts as unreadable too, and so does
#        a settings path that is not a regular file (only a confirmed absence
#        counts as "no settings", Codex review R7, PR #340): each is counted.
cl_write "$cl_d" '{"permissions":{"allow":"Bash"}}'
mkdir -p "$cl_home/src/personal/repo-g/.claude/settings.local.json"
cl_run
if [[ "$cl_rc" -ne 0 ]]; then
  doctor_exit_fail "unreadable project files" "$cl_rc" "$cl_out"
elif grep -Fxq "[info] - the permission rules of $cl_d could not be read (not a regular file holding JSON of the expected shape?); not checked (contents never shown)" <<< "$cl_out" \
  && grep -Fxq "[info] - the permission rules of $cl_home/src/personal/repo-g/.claude/settings.local.json could not be read (not a regular file holding JSON of the expected shape?); not checked (contents never shown)" <<< "$cl_out" \
  && grep -Fxq "[info] - Claude project-level allows partly checked: no outward probe auto-allowed in the 2 file(s) read, but 2 could not be read — not a clean result" <<< "$cl_out" \
  && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
  ok "test passed: an unreadable project file and a settings path that is not a regular file keep the Claude allow check from reporting clean"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: an unreadable project file or a settings path that is not a regular file must not leave the clean ok"
  status=1
fi
rm -rf "$cl_home/src/client" "$cl_home/src/personal"

# CL-6) this repo under a standard root is read once: a minimal repo copy at
#       ~/src/personal/dotfiles runs doctor from there, so it is both "this
#       repo" and a repo under the root -> one action, not two (counted
#       whatever the path spelling: the fixture HOME may hold a doubled
#       slash from TMPDIR, which `pwd` drops from the repo's own path). The
#       same for a copy one org level down in work (~/src/work/org-s/dotfiles,
#       #445).
for cl_self_rel in src/personal/dotfiles src/work/org-s/dotfiles; do
  copy_repo_fixture "$cl_home/$cl_self_rel"
  cl_write "$cl_home/$cl_self_rel/.claude/settings.local.json" '{"permissions":{"allow":["Bash(sudo -v)"]}}'
  cl_rc=0
  cl_out="$(HOME="$cl_home" "$cl_home/$cl_self_rel/scripts/doctor.sh" personal 2>&1)" || cl_rc=$?
  if [[ "$cl_rc" -ne 0 ]]; then
    doctor_exit_fail "this repo at ~/$cl_self_rel" "$cl_rc" "$cl_out"
  elif [[ "$(grep -F "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in " <<< "$cl_out" | grep -Fc "/$cl_self_rel/.claude/settings.local.json: 'sudo -v'")" -eq 1 ]]; then
    ok "test passed: this repo at ~/$cl_self_rel is read once (one action)"
  else
    printf '%s\n' "$cl_out" >&2
    fail "test failed: this repo at ~/$cl_self_rel must be read once"
    status=1
  fi
  rm -rf "${cl_home:?}/$cl_self_rel"
done
rm -rf "$cl_home/src/work"

# CL-7) this repo under HOME but outside the standard roots is read only as
#       "this repo", and HOME is compared in normalized form: the copy at
#       ~/dotfiles runs with a HOME spelled with a doubled slash (Codex review
#       R4, PR #340) -> its action appears.
copy_repo_fixture "$cl_home/dotfiles"
cl_write "$cl_home/dotfiles/.claude/settings.local.json" '{"permissions":{"allow":["Bash(sudo -v)"]}}'
cl_home_dbl="${cl_home%/*}//${cl_home##*/}"
cl_rc=0
cl_out="$(HOME="$cl_home_dbl" "$cl_home/dotfiles/scripts/doctor.sh" personal 2>&1)" || cl_rc=$?
if [[ "$cl_rc" -ne 0 ]]; then
  doctor_exit_fail "this repo under HOME outside the standard roots" "$cl_rc" "$cl_out"
elif [[ "$(grep -F "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in " <<< "$cl_out" | grep -Fc "/cl-home/dotfiles/.claude/settings.local.json: 'sudo -v'")" -eq 1 ]]; then
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
cl_run
if [[ "$cl_rc" -ne 0 ]]; then
  doctor_exit_fail "no live floor" "$cl_rc" "$cl_out"
elif grep -Fxq "[warn] 2 outward probe(s) auto-allowed for Claude by project-level allow rules in $cl_b: 'gh pr merge', 'gh auth token' — no deny / ask of the managed floor or the project stops these, so they run without approval in that project" <<< "$cl_out"; then
  ok "test passed: without a live floor every covered probe is reported"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: allows without a live floor were not all reported"
  status=1
fi

# CL-4) a live floor that cannot be read decides nothing -> an item, neither
#       the ok line nor a warn.
cl_write "$cl_home/.claude/settings.json" '{"permissions":'
cl_run
if [[ "$cl_rc" -ne 0 ]]; then
  doctor_exit_fail "an unreadable live floor" "$cl_rc" "$cl_out"
elif grep -Fxq "[info] - Claude project-level allows not checked: the live ~/.claude/settings.json could not be read (its deny / ask decide which allows matter)" <<< "$cl_out" \
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
cl_run
if [[ "$cl_rc" -ne 0 ]]; then
  doctor_exit_fail "a floor of two JSON documents" "$cl_rc" "$cl_out"
elif grep -Fxq "[info] - Claude project-level allows not checked: the live ~/.claude/settings.json could not be read (its deny / ask decide which allows matter)" <<< "$cl_out" \
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
cl_run
if [[ "$cl_rc" -ne 0 ]]; then
  doctor_exit_fail "a floor repeating a key" "$cl_rc" "$cl_out"
elif grep -Fxq "[info] - Claude project-level allows not checked: the live ~/.claude/settings.json could not be read (its deny / ask decide which allows matter)" <<< "$cl_out" \
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
cl_run work
if [[ "$cl_rc" -ne 0 ]]; then
  doctor_exit_fail "work profile, Claude project-level allows" "$cl_rc" "$cl_out"
elif grep -Fxq "[info] - Claude project-level allows not watched for this profile (claude-settings module inactive)" <<< "$cl_out" \
  && ! grep -Fq "auto-allowed for Claude" <<< "$cl_out"; then
  ok "test passed: work does not watch Claude project-level allows"
else
  printf '%s\n' "$cl_out" >&2
  fail "test failed: work must not watch Claude project-level allows"
  status=1
fi

# CL-8) only a confirmed absence counts as "no settings" (Codex review R7,
#       PR #340): a .claude dir that cannot be searched is unreadable (an
#       item, no clean ok), and so is a floor dir that cannot be searched, a
#       project root or an org directory of work or client that cannot be
#       listed (the .claude and .git of a repo directly under work are not
#       repos, so they add no item of their own). Each item names its path,
#       so dirs whose states do not depend on each other share a run, and
#       the count of files not read pins each one. The rest of the HOME is
#       clean here (repo-b's allows are all stopped by the floor, and its
#       file is the only one read). Skipped as root (root searches the dir).
rm -rf "$cl_home/src/work" "$cl_home/src/sandbox"
cl_g="$cl_home/src/personal/repo-g/.claude"
cl_write "$cl_g/settings.local.json" '{"permissions":{"allow":["Bash(npm test)"]}}'
if [[ "$(id -u)" != "0" ]]; then
  chmod 000 "$cl_home/.claude"
  cl_run
  if [[ "$cl_rc" -ne 0 ]]; then
    doctor_exit_fail "a floor dir that cannot be searched" "$cl_rc" "$cl_out"
  elif grep -Fxq "[info] - Claude project-level allows not checked: the live ~/.claude/settings.json could not be read (its deny / ask decide which allows matter)" <<< "$cl_out" \
    && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
    ok "test passed: a floor dir that cannot be searched leaves the check not done (no false clean)"
  else
    printf '%s\n' "$cl_out" >&2
    fail "test failed: a floor dir that cannot be searched must not read as no floor"
    status=1
  fi
  chmod 755 "$cl_home/.claude"
  # The project root and an org (client) directory of work and of client
  # (#445: the repos one level down there are where the convention puts
  # them) that cannot be listed, each through mode 000 and mode 111 across
  # two runs. A 000 org dir also leaves its own .claude unopenable, so each
  # run counts 4 not read.
  mkdir -p "$cl_home/src/work/org-l/repo-l" "$cl_home/src/client/org-l/repo-l"
  for cl_modes in "000 000 111" "111 111 000"; do
    read -r cl_mode_p cl_mode_w cl_mode_c <<< "$cl_modes"
    chmod "$cl_mode_p" "$cl_home/src/personal"
    chmod "$cl_mode_w" "$cl_home/src/work/org-l"
    chmod "$cl_mode_c" "$cl_home/src/client/org-l"
    cl_run
    if [[ "$cl_rc" -ne 0 ]]; then
      doctor_exit_fail "a project root and org dirs that cannot be listed, modes $cl_modes" "$cl_rc" "$cl_out"
    else
      cl_bad=0
      if grep -Fxq "[info] - the project root $cl_home/src/personal could not be listed (permission denied, not a directory or a symlink loop); the repos under it not checked" <<< "$cl_out"; then
        ok "test passed: a project root that cannot be listed (mode $cl_mode_p) is unreadable, not empty"
      else
        fail "test failed: a project root that cannot be listed (mode $cl_mode_p) must not read as empty"
        cl_bad=1
      fi
      for cl_root in work client; do
        cl_mode="$cl_mode_w"
        [[ "$cl_root" == work ]] || cl_mode="$cl_mode_c"
        if grep -Fxq "[info] - the directory $cl_home/src/$cl_root/org-l under the project root could not be listed (permission denied, not a directory or a symlink loop); the repos under it not checked" <<< "$cl_out"; then
          ok "test passed: an org directory of $cl_root that cannot be listed (mode $cl_mode) is unreadable, not empty"
        else
          fail "test failed: an org directory of $cl_root that cannot be listed (mode $cl_mode) must not read as empty"
          cl_bad=1
        fi
      done
      if ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
        ok "test passed: dirs that cannot be listed leave no clean ok (modes $cl_modes)"
      else
        fail "test failed: dirs that cannot be listed must not leave the clean ok (modes $cl_modes)"
        cl_bad=1
      fi
      if grep -Fxq "[info] - Claude project-level allows partly checked: no outward probe auto-allowed in the 1 file(s) read, but 4 could not be read — not a clean result" <<< "$cl_out"; then
        ok "test passed: each dir that cannot be listed is counted as not read (modes $cl_modes)"
      else
        fail "test failed: each dir that cannot be listed must be counted as not read (modes $cl_modes)"
        cl_bad=1
      fi
      [[ "$cl_bad" -eq 0 ]] || { printf '%s\n' "$cl_out" >&2; status=1; }
    fi
    chmod 755 "$cl_home/src/personal" "$cl_home/src/work/org-l" "$cl_home/src/client/org-l"
  done
  rm -rf "$cl_home/src/work" "$cl_home/src/client"
  # ... and so is a root under a ~/src that cannot be searched (`-d` would
  # read that as no root at all).
  chmod 000 "$cl_home/src"
  cl_run
  if [[ "$cl_rc" -ne 0 ]]; then
    doctor_exit_fail "a ~/src that cannot be searched" "$cl_rc" "$cl_out"
  elif grep -Fxq "[info] - the project root $cl_home/src/personal could not be listed (permission denied, not a directory or a symlink loop); the repos under it not checked" <<< "$cl_out" \
    && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
    ok "test passed: the roots under a ~/src that cannot be searched are unreadable, not absent"
  else
    printf '%s\n' "$cl_out" >&2
    fail "test failed: the roots under a ~/src that cannot be searched must not read as absent"
    status=1
  fi
  chmod 755 "$cl_home/src"
  # repo-g's .claude cannot be searched, nor can the .claude and .git of a
  # repo placed directly under work. That repo is listed as an org too, but
  # its own .claude and .git are not read as repos (#445): only its .claude
  # is reported, once, so 2 are not read in all.
  mkdir -p "$cl_home/src/work/repo-k/.claude" "$cl_home/src/work/repo-k/.git"
  chmod 000 "$cl_g" "$cl_home/src/work/repo-k/.claude" "$cl_home/src/work/repo-k/.git"
  cl_run
  if [[ "$cl_rc" -ne 0 ]]; then
    doctor_exit_fail "the .claude dirs of repo-g and repo-k that cannot be searched" "$cl_rc" "$cl_out"
  elif grep -Fxq "[info] - the .claude directory of $cl_home/src/personal/repo-g could not be opened (permission denied, not a directory or a symlink loop); its settings not checked" <<< "$cl_out" \
    && grep -Fxq "[info] - the .claude directory of $cl_home/src/work/repo-k could not be opened (permission denied, not a directory or a symlink loop); its settings not checked" <<< "$cl_out" \
    && grep -Fxq "[info] - Claude project-level allows partly checked: no outward probe auto-allowed in the 1 file(s) read, but 2 could not be read — not a clean result" <<< "$cl_out" \
    && ! grep -Fq "the .claude directory of $cl_home/src/work/repo-k/." <<< "$cl_out" \
    && ! grep -Fq "no project-level Claude allow rule covers" <<< "$cl_out"; then
    ok "test passed: a .claude dir that cannot be searched is unreadable, not absent, and the .claude and .git of a repo directly under work are not read as repos"
  else
    printf '%s\n' "$cl_out" >&2
    fail "test failed: a .claude dir that cannot be searched must not read as absent, and the .claude and .git of a repo directly under work must not be read as repos"
    status=1
  fi
  chmod 755 "$cl_g" "$cl_home/src/work/repo-k/.claude" "$cl_home/src/work/repo-k/.git"
  rm -rf "$cl_home/src/work"
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
for go_case in default-gopath elsewhere no-path query-fails query-fails-no-path trailing-slash-home gobin-trailing-slash gobin-double-slash gobin-symlink; do
  go_gobin=""
  go_gopath="$fixture_home/go"
  go_path="$go_fakebin:$fixture_home/go/bin:$PATH"
  go_fail=""
  go_home="$fixture_home"
  case "$go_case" in
    elsewhere) go_gobin="$fixture_home/toolchain/bin" ;;
    no-path) go_path="$go_fakebin:$PATH" ;;
    query-fails) go_fail=1 ;;
    query-fails-no-path) go_fail=1; go_path="$go_fakebin:$PATH" ;;
    # .zshenv appends ${HOME%/}/go/bin, so a trailing-slash HOME still matches.
    trailing-slash-home) go_home="$fixture_home/" ;;
    # go env returns GOBIN as spelled (#329): the same ~/go/bin with a
    # trailing `/` or a doubled `//` is matched by its spelling (no
    # directory exists for these two), a symlink to it as the same dir.
    gobin-trailing-slash) go_gobin="$fixture_home/go/bin/" ;;
    gobin-double-slash) go_gobin="$fixture_home//go//bin" ;;
    gobin-symlink)
      mkdir -p "$fixture_home/go/bin"
      ln -s "$fixture_home/go/bin" "$fixture_home/gobin-link"
      go_gobin="$fixture_home/gobin-link"
      ;;
  esac
  if go_out="$(HOME="$go_home" PATH="$go_path" FAKE_GOBIN="$go_gobin" FAKE_GOPATH="$go_gopath" \
      FAKE_GO_FAIL="$go_fail" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
    go_ok=0
    case "$go_case" in
      default-gopath|trailing-slash-home|gobin-trailing-slash|gobin-double-slash|gobin-symlink)
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
rm -rf "${go_fakebin:?}" "${fixture_home:?}/gobin-link" "${fixture_home:?}/go"
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
# env-driven so each run pins one state of each check (the 7-day wait and
# the exclude count, see npm_wait_case); doctor stays exit 0 throughout.
# By default the fake answers as the older npm form (11.10, min-release-age
# null as npm dropped the key); the #443 cases below set the current form.
# `config get`, `config list --long=false` (the keys a source sets, as npm
# prints them) and `config list --json` (the merged config with typed values)
# read the same FAKE_NPM_* env. FAKE_NPM_EXCLUDE_JSON is the JSON value of
# min-release-age-exclude (`[]` by default, `absent` for an npm that does not
# know the key; an NBSP in it is written as the JSON escape \u00a0, so it
# stays visible); FAKE_NPM_BEFORE_SET lists `before = null` in the env source,
# as an explicit null does; FAKE_NPM_LONG sets long=true in the user source,
# which makes a listing without --long=false add npm's defaults (`before =
# null` among them); FAKE_NPM_JSON sets json=true there, which makes a
# listing without --json=false print the JSON listing instead of the source
# lines; FAKE_NPM_LIST_EXTRA adds one line to the listing;
# FAKE_NPM_LIST_JSON replaces the whole JSON listing. FAKE_NPM_FAIL makes the
# one call whose arguments it spells (e.g. `config get before`) exit 1 with
# no output, as a failing read.
cat > "$npm_fakebin/npm" <<'SH'
#!/bin/sh
if [ -n "${FAKE_NPM_FAIL:-}" ] && [ "$*" = "$FAKE_NPM_FAIL" ]; then
  exit 1
fi
age="${FAKE_NPM_MIN_RELEASE_AGE:-null}"
before="${FAKE_NPM_BEFORE:-null}"
exclude="${FAKE_NPM_EXCLUDE_JSON:-[]}"
case "$1" in
  --version) printf '%s\n' "${FAKE_NPM_VERSION:-11.10.0}" ;;
  config)
    case "$2" in
      get)
        case "$3" in
          ignore-scripts) printf '%s\n' "${FAKE_NPM_IGNORE_SCRIPTS:-true}" ;;
          save-exact) printf 'true\n' ;;
          fund) printf 'false\n' ;;
          audit) printf 'true\n' ;;
          before) printf '%s\n' "$before" ;;
          min-release-age) printf '%s\n' "$age" ;;
          *) printf 'null\n' ;;
        esac ;;
      list)
        json=false long=true
        [ -z "${FAKE_NPM_JSON:-}" ] || json=true
        [ -n "${FAKE_NPM_LONG:-}" ] || long=false
        shift 2
        for arg in "$@"; do
          case "$arg" in
            --json) json=true ;;
            --json=false) json=false ;;
            --long=false) long=false ;;
          esac
        done
        if [ "$json" = true ]; then
          if [ -n "${FAKE_NPM_LIST_JSON:-}" ]; then
            printf '%s\n' "$FAKE_NPM_LIST_JSON"
            exit 0
          fi
          printf '{\n  "audit": true,\n'
          if [ "$before" = null ]; then printf '  "before": null,\n'; else printf '  "before": "%s",\n' "$before"; fi
          printf '  "ignore-scripts": %s,\n' "${FAKE_NPM_IGNORE_SCRIPTS:-true}"
          [ "$exclude" = absent ] || printf '  "min-release-age-exclude": %s,\n' "$exclude"
          printf '  "registry": "https://registry.npmjs.org/"\n}\n'
        else
          if [ "$long" = true ]; then
            printf '; "default" config from default values\n\nbefore = null\n; long = false ; overridden by user\n\n'
          fi
          printf '; "user" config from %s/.npmrc\n\n' "$HOME"
          [ -z "${FAKE_NPM_LONG:-}" ] || printf 'long = true\n'
          [ -z "${FAKE_NPM_JSON:-}" ] || printf 'json = true\n'
          [ "$age" = null ] || printf 'min-release-age = %s\n' "$age"
          [ "$before" = null ] || printf 'before = "%s"\n' "$before"
          printf '\n; "env" config from environment\n\n'
          [ -z "${FAKE_NPM_BEFORE_SET:-}" ] || printf 'before = null\n'
          [ "$exclude" = "[]" ] || [ "$exclude" = absent ] || printf 'min-release-age-exclude = %s\n' "$exclude"
          [ -z "${FAKE_NPM_LIST_EXTRA:-}" ] || printf '%s\n' "$FAKE_NPM_LIST_EXTRA"
          printf '\n; npm version = %s\n; Run `npm config ls -l` to show all defaults.\n' "${FAKE_NPM_VERSION:-11.10.0}"
        fi ;;
    esac ;;
esac
exit 0
SH
# doctor counts min-release-age-exclude with a node script, which is the code
# under test, so that one call runs on the real node (linked as node-real;
# FAKE_NODE_FAIL_COUNT makes it fail instead). Every other node call is the
# Date.parse of `before` and prints FAKE_NODE_EPOCH.
cat > "$npm_fakebin/node" <<'SH'
#!/bin/sh
case "${2:-}" in
  *min-release-age-exclude*)
    [ -z "${FAKE_NODE_FAIL_COUNT:-}" ] || exit 1
    # The count fails when the listing (marked by FAKE_NODE_ARGV_CANARY)
    # reaches node as an argument instead of on stdin.
    if [ -n "${FAKE_NODE_ARGV_CANARY:-}" ]; then
      for arg in "$@"; do
        case "$arg" in *"$FAKE_NODE_ARGV_CANARY"*) exit 1 ;; esac
      done
    fi
    exec "${0%/*}/node-real" "$@" ;;
esac
printf '%s' "${FAKE_NODE_EPOCH:-}"
exit 0
SH
chmod +x "$npm_fakebin/npm" "$npm_fakebin/node"
npm_real_node="$(node -e 'process.stdout.write(process.execPath)' 2>/dev/null || true)"
if [[ -n "$npm_real_node" && -x "$npm_real_node" ]]; then
  ln -s "$npm_real_node" "$npm_fakebin/node-real"
else
  fail "test failed: the npm cases need a real node on PATH to run doctor's min-release-age-exclude count (#443)"
  status=1
fi
now_epoch="$(date +%s)"

# NPM-E..Y) The 7-day wait on current npm (#443): npm 11.19 keeps
# min-release-age as its own key and leaves `before` null, so that form is
# honored besides the older before-cutoff one (NPM-C, and with
# min-release-age=7 beside it); a different age, a set `before` outside the
# window (it can replace the wait), a ~7-day `before` beside a different age
# (that age in a higher source replaces it), a `before` that cannot be read,
# a `before` a source sets to null (it replaces the wait, yet reads null like
# an unset one), an `npm config list` that cannot be read (an explicit null
# cannot be ruled out), an npm older than 11.10 (it does not know the key)
# and any min-release-age-exclude entry warn. A `before = ` that is not at
# the start of a listing line (another key's value) is not a set `before`,
# nor is the `before = null` npm lists among its defaults when a source sets
# long=true (doctor lists with --long=false), and a json=true in a source
# does not hide a set `before` (doctor lists with --json=false).
# The exclude warn carries the count only, never the names, counted from the
# JSON listing as npm flattens the key (comma-split, JavaScript-trimmed, so
# CR and NBSP too, empty and repeated names dropped). Entries named undefined
# or null count; a key absent from the listing (an npm without it) counts as
# empty; a value that is not a list, a listing that does not parse or is
# not a JSON object, an npm error object (a config key named error, a
# string, is none), a failing count and a failing listing warn with doctor
# still exit 0. The count reads the listing on stdin: one in node's
# arguments fails it.
# npm_wait_case LABEL WANT DONT_WANT [VAR=VALUE ...] — one personal (enforce)
# doctor run with the fakes above and the given env: every line of WANT must
# be in the report, no line of DONT_WANT may be. The 7-day wait (`before` /
# min-release-age, from `npm config get` and the source listing) and the
# min-release-age-exclude count (from `npm config list --json`) read separate
# fake answers, so one run pins one state of each.
npm_wait_case() {
  local label="$1" want="$2" dont_want="$3" out rc=0 line missing="" unexpected=""
  shift 3
  out="$(env HOME="$fixture_home" PATH="$npm_fakebin:$PATH" "$@" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    doctor_exit_fail "$label" "$rc" "$out"
    return 0
  fi
  while IFS= read -r line; do
    grep -Fq -- "$line" <<< "$out" || missing+="  $line"$'\n'
  done <<< "$want"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ! grep -Fq -- "$line" <<< "$out" || unexpected+="  $line"$'\n'
  done <<< "$dont_want"
  if [[ -z "$missing" && -z "$unexpected" ]]; then
    ok "test passed: $label"
  else
    printf '%s\n' "$out" >&2
    printf 'missing:\n%sunexpected:\n%s' "$missing" "$unexpected" >&2
    fail "test failed: $label"
    status=1
  fi
}
npm_wait_warn="[warn] enforce expects npm min-release-age=7 with before unset (or before ~= now-7d), current:"
npm_honored_unset="[ok] npm min-release-age=7 honored (before unset)"
npm_exclude_empty="[ok] npm min-release-age-exclude empty"
npm_exclude_warn="[warn] enforce expects npm min-release-age-exclude empty, current:"
npm_exclude_uncounted="[warn] npm min-release-age-exclude could not be counted; cannot confirm no package skips the 7-day wait"
npm_wait_case "enforce mismatch warned while a good before-cutoff is honored; a count that fails to run is warned (#150, #443)" \
  "enforce expects npm ignore-scripts=true, current: false"$'\n'"[ok] npm min-release-age=7 honored (before=fake-date)"$'\n'"$npm_exclude_uncounted" \
  "$npm_wait_warn"$'\n'"$npm_exclude_empty" \
  FAKE_NPM_IGNORE_SCRIPTS=false FAKE_NPM_BEFORE="fake-date" FAKE_NODE_EPOCH="$(( now_epoch - 7*86400 ))" FAKE_NODE_FAIL_COUNT=1
npm_wait_case "a too-recent before cutoff is warned; a JSON listing that cannot be read is warned (#150, #443)" \
  "$npm_wait_warn min-release-age=null before=fake-date (apply pending?)"$'\n'"[warn] npm min-release-age-exclude could not be read; cannot confirm no package skips the 7-day wait" \
  "npm min-release-age=7 honored"$'\n'"$npm_exclude_empty" \
  FAKE_NPM_BEFORE="fake-date" FAKE_NODE_EPOCH="$(( now_epoch - 86400 ))" FAKE_NPM_FAIL="config list --json"
npm_wait_case "current npm form (min-release-age=7, before null, no exclude) is honored (#443)" \
  "[info] - npm min-release-age=7"$'\n'"$npm_honored_unset"$'\n'"$npm_exclude_empty" \
  "enforce expects npm min-release-age" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=7
npm_wait_case "a loosened age (min-release-age=1, before null) is warned; an exclude that is not a list cannot be counted (#443)" \
  "$npm_wait_warn min-release-age=1 before=null (apply pending?)"$'\n'"$npm_exclude_uncounted" \
  "npm min-release-age=7 honored"$'\n'"$npm_exclude_empty" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=1 FAKE_NPM_EXCLUDE_JSON='"npmx-canary-pkg"'
npm_wait_case "a set before outside the window (it can replace the wait) is warned; a JSON listing that does not parse cannot be counted (#443)" \
  "$npm_wait_warn min-release-age=7 before=fake-date (a set before replaces the wait when in the same or a higher config source)"$'\n'"$npm_exclude_uncounted" \
  "npm min-release-age=7 honored"$'\n'"$npm_exclude_empty" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=7 FAKE_NPM_BEFORE=fake-date \
  FAKE_NODE_EPOCH="$(( now_epoch - 400*86400 ))" FAKE_NPM_LIST_JSON='{"min-release-age-exclude": ['
npm_wait_case "min-release-age=7 on an npm older than 11.10 is not honored; an exclude key absent from the listing counts as empty (#443)" \
  "$npm_wait_warn min-release-age=7 before=null (npm version not confirmed to enforce it, see above)"$'\n'"$npm_exclude_empty" \
  "npm min-release-age=7 honored"$'\n'"enforce expects npm min-release-age-exclude" \
  FAKE_NPM_VERSION=11.9.0 FAKE_NPM_MIN_RELEASE_AGE=7 FAKE_NPM_EXCLUDE_JSON=absent
npm_wait_case "a ~7-day before beside min-release-age=7 is honored; a non-empty exclude is warned by count, names not shown (#443)" \
  "[ok] npm min-release-age=7 honored (before=fake-date)"$'\n'"$npm_exclude_warn 3 entry(ies) skip the 7-day wait (names not shown)" \
  "$npm_wait_warn"$'\n'"npmx-canary" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=7 FAKE_NPM_BEFORE=fake-date \
  FAKE_NODE_EPOCH="$(( now_epoch - 7*86400 ))" \
  FAKE_NPM_EXCLUDE_JSON='["@npmx-canary-scope/*, ,npmx-canary-pkg","@npmx-canary-scope/*","npmx-canary-other","\u00a0npmx-canary-pkg\r"]'
npm_wait_case "a ~7-day before beside a different age is warned; exclude entries named undefined and null are counted (#443)" \
  "$npm_wait_warn min-release-age=1 before=fake-date (apply pending?)"$'\n'"$npm_exclude_warn 2 entry(ies) skip the 7-day wait (names not shown)" \
  "npm min-release-age=7 honored"$'\n'"$npm_exclude_empty" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=1 FAKE_NPM_BEFORE=fake-date \
  FAKE_NODE_EPOCH="$(( now_epoch - 7*86400 ))" FAKE_NPM_EXCLUDE_JSON='["undefined",null]'
npm_wait_case "a before that cannot be read is not taken as unset; whitespace-only exclude entries (CR, NBSP, tab) are empty as JavaScript trims them (#443)" \
  "$npm_wait_warn min-release-age=7 before=(no value) (apply pending?)"$'\n'"$npm_exclude_empty" \
  "npm min-release-age=7 honored"$'\n'"enforce expects npm min-release-age-exclude" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=7 FAKE_NPM_FAIL="config get before" FAKE_NPM_EXCLUDE_JSON='[",\r, \u00a0 ,\t"," ",""]'
npm_wait_case "a before a source sets to null is warned; an npm error object as the JSON listing cannot be counted (#443)" \
  "$npm_wait_warn min-release-age=7 before=null (a config source sets before explicitly, and a set before replaces the wait when in the same or a higher source, even as null)"$'\n'"$npm_exclude_uncounted" \
  "npm min-release-age=7 honored"$'\n'"$npm_exclude_empty" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=7 FAKE_NPM_BEFORE_SET=1 FAKE_NPM_LIST_JSON='{"error": {"summary": "x", "detail": ""}}'
npm_wait_case "an npm config list that cannot be read leaves an explicit null before open, warned with doctor exit 0 (#443)" \
  "$npm_wait_warn min-release-age=7 before=null (npm config list could not be read, so a before set explicitly to null cannot be ruled out)"$'\n'"$npm_exclude_empty" \
  "npm min-release-age=7 honored" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=7 FAKE_NPM_FAIL="config list --long=false --json=false"
npm_wait_case "a long=true in a config source does not make npm's listed defaults a set before; a JSON listing that is an array cannot be counted (#443)" \
  "$npm_honored_unset"$'\n'"$npm_exclude_uncounted" \
  "enforce expects npm min-release-age"$'\n'"$npm_exclude_empty" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=7 FAKE_NPM_LONG=1 FAKE_NPM_LIST_JSON='[]'
npm_wait_case "a json=true in a config source does not hide a before a source sets to null; a JSON listing that is a number cannot be counted (#443)" \
  "$npm_wait_warn min-release-age=7 before=null (a config source sets before explicitly, and a set before replaces the wait when in the same or a higher source, even as null)"$'\n'"$npm_exclude_uncounted" \
  "npm min-release-age=7 honored"$'\n'"$npm_exclude_empty" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=7 FAKE_NPM_JSON=1 FAKE_NPM_BEFORE_SET=1 FAKE_NPM_LIST_JSON='5'
npm_wait_case "a 'before = ' inside another key's listed value is not a set before; a config key named error (a string) is no npm error object, and the listing reaches the count on stdin, not as an argument (#443)" \
  "$npm_honored_unset"$'\n'"$npm_exclude_empty" \
  "enforce expects npm min-release-age"$'\n'"$npm_exclude_uncounted" \
  FAKE_NPM_VERSION=11.19.1 FAKE_NPM_MIN_RELEASE_AGE=7 FAKE_NPM_LIST_EXTRA='init-author-name = "before = x"' \
  FAKE_NODE_ARGV_CANARY=npmx-canary-listing \
  FAKE_NPM_LIST_JSON='{"error": "x", "init-author-name": "npmx-canary-listing", "min-release-age-exclude": []}'

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
# never appears in the output), doctor stays exit 0 (#148); the managed-by
# header on its line 1 is ok'd. The status check itself must skip — as
# not-initialized when chezmoi exists (fixture homes carry no chezmoi
# state), as not-found where it does not (the CI validate job has no
# chezmoi).
if command -v chezmoi >/dev/null 2>&1; then
  drift_skip="chezmoi not initialized for this home; skipping drift check"
else
  drift_skip="chezmoi not found; skipping drift check"
fi
dr_home="$fixture_home/drift"
mkdir -p "$dr_home"
printf '# Managed by chezmoi from kosako/dotfiles (npmHardeningMode=enforce).\nignore-scripts=true\n//registry.npmjs.org/:_authToken=secret-placeholder-value\n' \
  > "$dr_home/.npmrc"
if dr_out="$(HOME="$dr_home" XDG_CONFIG_HOME='' "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fq "npmrc contains 1 _authToken line" <<< "$dr_out" \
    && ! grep -Fq "secret-placeholder-value" <<< "$dr_out" \
    && grep -Fxq "[ok] npmrc managed-by header present" <<< "$dr_out" \
    && grep -Fq "$drift_skip" <<< "$dr_out"; then
    ok "test passed: npmrc token line warned by count, value never echoed; header ok; uninitialized home skips the status check"
  else
    printf '%s\n' "$dr_out" >&2
    fail "test failed: token line not warned, the value leaked into output, the header ok or the skip line missing"
    status=1
  fi
else
  printf '%s\n' "$dr_out" >&2
  fail "test failed: doctor must stay exit 0 with a token line present"
  status=1
fi

# DRIFT-B) A managed .npmrc missing the managed-by header is warned: the
# headerless file is planted here and checked by DRIFT-C's clean-status run
# below (same home), which needs no doctor run of its own.
printf 'ignore-scripts=true\n' > "$dr_home/.npmrc"

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
  if grep -Fq "no drift: managed files match the source state" <<< "$dr_out" \
    && grep -Fq "npmrc lacks the managed-by header" <<< "$dr_out" \
    && grep -Fxq "[ok] npmrc carries no _authToken line" <<< "$dr_out"; then
    ok "test passed: an empty chezmoi status reports no drift; the headerless npmrc is warned; no token line is ok"
  else
    printf '%s\n' "$dr_out" >&2
    fail "test failed: empty status should report no drift, the headerless npmrc must be warned, and the npmrc without a token line must be ok"
    status=1
  fi
else
  printf '%s\n' "$dr_out" >&2
  fail "test failed: doctor must stay exit 0 with a clean status and a headerless npmrc"
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
# ... and when TMPDIR is not a writable directory, the action names it too:
# chezmoi writes the modify script there before running it, so status fails
# with a correct config as well (#446). TMPDIR is a path under a regular
# file, so no tool doctor runs can create it on the way.
printf 'not a directory\n' > "$dr_home/tmp-file"
if dr_out="$(HOME="$dr_home" PATH="$cz_fakebin:$PATH" TMPDIR="$dr_home/tmp-file/tmp" \
  FAKE_CHEZMOI_STATUS='' FAKE_CHEZMOI_RC=1 XDG_CONFIG_HOME='' \
  "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[warn] chezmoi status failed although this home has a chezmoi config, and TMPDIR is not a writable directory — chezmoi writes the modify scripts there before running them unless its config sets scriptTempDir, which breaks chezmoi status, diff and apply as a config or template error does; drift is not checked until it is fixed" <<< "$dr_out" \
    && grep -Fxq "        \$ chezmoi status   # if the error names a file under TMPDIR, point TMPDIR (or scriptTempDir) at a writable directory; otherwise fix the config or the template" <<< "$dr_out" \
    && ! grep -Fq "a config or template error (e.g. an unknown profile)" <<< "$dr_out" \
    && ! grep -Fq "chezmoi not initialized for this home" <<< "$dr_out"; then
    ok "test passed: a failing chezmoi status with a config present and TMPDIR not a directory names TMPDIR in the action"
  else
    printf '%s\n' "$dr_out" >&2
    fail "test failed: a failing status with a chezmoi config and TMPDIR not a directory must name TMPDIR in the action"
    status=1
  fi
else
  printf '%s\n' "$dr_out" >&2
  fail "test failed: doctor must stay exit 0 when chezmoi status fails with TMPDIR not a directory"
  status=1
fi
rm -rf "$dr_home/.config/chezmoi" "$dr_home/tmp-file"

# DS) display_safe (#335): values doctor did not make itself reach a report
#     line only through display_safe. DS-U checks the helper itself
#     (extracted from lib-policy.sh, run under LC_ALL=C and the inherited
#     locale); DS-1 plants a terminal escape, a BEL, a C1 control, a bidi
#     override and an invalid byte in every such source at once — another
#     tool's output (agent-tools status.sh, herdr, npm, git, chezmoi,
#     corepack, go, brew, as doctor and its catalog drift read them) and
#     names others can shape (a repo directory, OpenCode plugin files, the
#     backup marker, a Codex project key, core.excludesFile, a go binary) —
#     and expects each shown with `?` in its place and not one raw byte of
#     them anywhere in the report. The usage reader's reason and the Codex
#     rules file names are pinned in their own sections (UR-3b, AIP-5).
ds_fns="$(sed -n '/^shell_quote_safe() {/,/^}/p; /^display_safe_into() {/,/^}/p; /^display_safe() {/,/^}/p' "$SCRIPT_DIR/lib-policy.sh")"
# ds_misses LOCALE — run the helper cases under LC_ALL=LOCALE ('' keeps the
# inherited locale), each in a bash of its own under set -euo pipefail (the
# helper must return 0 and survive errexit); print each miss.
ds_misses() {
  (
    [[ -z "$1" ]] || export LC_ALL="$1"
    ds_case() {
      local got rc=0
      got="$(bash -c 'set -euo pipefail; eval "$1"; display_safe "$2"; printf x' _ "$ds_fns" "$1")" || rc=$?
      if [[ "$rc" -ne 0 || "$got" != *x ]]; then
        printf '  [LC_ALL=%s] %q -> exit %s under set -euo pipefail\n' "${3:-inherited}" "$1" "$rc"
        return 0
      fi
      got="${got%x}"
      [[ "$got" == "$2" ]] || printf '  [LC_ALL=%s] %q -> %q (expected %q)\n' "${3:-inherited}" "$1" "$got" "$2"
    }
    eval "$ds_fns"
    # shell_quote_safe: ASCII only, and pasted back it is the value again.
    local q path=$'/r/re\xe2\x80\xaepo/\xe4\xb8\x80/'"it's"$'\033[1m x\xff'
    q="$(shell_quote_safe "$path")"
    if [[ "$q" == *[![:print:]]* ]] || LC_ALL=C grep -q $'[\x80-\xff]' <<< "$q"; then
      printf '  [LC_ALL=%s] shell_quote_safe left a raw byte: %s\n' "${1:-inherited}" "$(printf '%s' "$q" | LC_ALL=C od -c | head -2 | tr -s ' ')"
    elif [[ "$(eval "printf '%s' $q")" != "$path" ]]; then
      printf '  [LC_ALL=%s] shell_quote_safe does not round-trip\n' "${1:-inherited}"
    fi
    ds_case 'plain ascii 1.2-3_x' 'plain ascii 1.2-3_x' "$1"
    ds_case "a"$'\033'"[31mb" 'a?[31mb' "$1"
    ds_case "x"$'\r'"y"$'\n'"z"$'\t'"w"$'\177' 'x?y?z?w?' "$1"
    ds_case '設定 file がありません' '設定 file がありません' "$1"
    ds_case "c1"$'\xc2\x9b'"x" 'c1?x' "$1"
    ds_case "nbsp"$'\xc2\xa0'"ok" "nbsp"$'\xc2\xa0'"ok" "$1"
    ds_case "rlo"$'\xe2\x80\xae'"x lri"$'\xe2\x81\xa6'"y" 'rlo?x lri?y' "$1"
    ds_case "zwsp"$'\xe2\x80\x8b'"ok" "zwsp"$'\xe2\x80\x8b'"ok" "$1"
    ds_case "bad"$'\xff'"x lone"$'\x9b'"y" 'bad?x lone?y' "$1"
    ds_case "trunc"$'\xe3\x81' 'trunc??' "$1"
    ds_case "overlong"$'\xc0\xaf'" "$'\xe0\x80\xaf' 'overlong?? ???' "$1"
    ds_case "surrogate"$'\xed\xa0\x80' 'surrogate???' "$1"
    ds_case "emoji"$'\xf0\x9f\x98\x80' "emoji"$'\xf0\x9f\x98\x80' "$1"
    ds_case "min4"$'\xf0\x90\x80\x80'" max"$'\xf4\x8f\xbf\xbf' "min4"$'\xf0\x90\x80\x80'" max"$'\xf4\x8f\xbf\xbf' "$1"
    ds_case "overlong4"$'\xf0\x80\x80\x80' 'overlong4????' "$1"
    ds_case "toohigh"$'\xf4\x90\x80\x80' 'toohigh????' "$1"
    ds_case "q'and\"dq" "q'and\"dq" "$1"
    ds_case '' '' "$1"
  )
}
if [[ -z "$ds_fns" ]]; then
  fail "test failed: display_safe / shell_quote_safe not found in lib-policy.sh"
  status=1
elif ds_out="$(ds_misses C; ds_misses '')" && [[ -z "$ds_out" ]]; then
  ok "test passed: display_safe keeps valid UTF-8 and turns controls, bidi overrides and invalid bytes into ? (locale-independent, exit 0 under set -euo pipefail); shell_quote_safe is ASCII-only and round-trips"
else
  fail "test failed: display_safe drifted:"
  printf '%s\n' "$ds_out" >&2
  status=1
fi

# DS-S) the sink: every report helper (ok / info / section / item / warn /
#       fail) and the next-actions summary pass the whole line through
#       display_safe, whatever site built it — checked with lib-policy.sh
#       sourced in a bash of its own, under the inherited locale.
ds_sink_out="$(bash -c 'set -euo pipefail; SCRIPT_DIR="$1"; source "$SCRIPT_DIR/lib-policy.sh"
  v=$'"'"'e\033[2Jb\xe2\x80\xaex\xff'"'"'
  ok "o $v"; info "i $v"; section "s $v"; item "t $v"; warn "w $v"; fail "f $v"
  action "a $v" "step $v"; report_actions' _ "$SCRIPT_DIR" 2>&1)" || true
ds_sink_missing=""
for ds_line in "[ok] o e?[2Jb?x?" "[info] i e?[2Jb?x?" "[info] == s e?[2Jb?x? ==" "[info] - t e?[2Jb?x?" \
  "[warn] w e?[2Jb?x?" "[fail] f e?[2Jb?x?" "[warn] a e?[2Jb?x?" "[info] 1. a e?[2Jb?x?" "        step e?[2Jb?x?"; do
  grep -Fxq -- "$ds_line" <<< "$ds_sink_out" || ds_sink_missing+="  $ds_line"$'\n'
done
if [[ -z "$ds_sink_missing" ]] && ! LC_ALL=C grep -q $'[\033\x80-\xff]' <<< "$ds_sink_out"; then
  ok "test passed: every report helper and the next-actions summary show the whole line through display_safe"
else
  printf '%s\nmissing:\n%s' "$ds_sink_out" "$ds_sink_missing" | LC_ALL=C od -c | head -40 >&2
  fail "test failed: a report helper printed a line without display_safe"
  status=1
fi

ds_home="$fixture_home/ds-home"
ds_bin="$fixture_home/ds-bin"
ds_esc=$'\033'
ds_bel=$'\007'
ds_c1=$'\xc2\x9b'
ds_rlo=$'\xe2\x80\xae'
ds_ff=$'\xff'
ds_real_git="$(command -v git)"
mkdir -p "$ds_home/.config/opencode/plugins" "$ds_home/.local/state/dotfiles" "$ds_home/.codex" "$ds_bin" "$ds_home/at/scripts"
# another tool's output: agent-tools status.sh, herdr, npm
write_root_pinned_status_sh "$ds_home/at/scripts/status.sh" \
  '{"contract_version":3,"repo":{"present":true,"clean":true},"assets":{"total":1,"manifest_errors":0},"checks":{"manifest_validation":"fail\u001b[2J","prompt_injection_static":"pass"},"generated":{"total":1,"stale":0},"register":{"catalog_present":false},"sync_targets":[{"tool":"co\u001b]0;x\u0007dex","name":"d","state":"conflict"}]}'
cat > "$ds_bin/herdr" <<SH
#!/bin/sh
[ "\$1" = integration ] && [ "\$2" = status ] || exit 2
printf '%s\n' "claude: not installed (x)" "codex: not installed (y)" "opencode: not${ds_esc}[2J installed (z)"
SH
cat > "$ds_bin/opencode" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$ds_bin/npm" <<SH
#!/bin/sh
case "\$1" in
  --version) printf '%s\n' "1${ds_esc}[2J" ;;
  config) [ "\$3" = userconfig ] && printf '%s\n' "/x${ds_c1}y${ds_ff}z/.npmrc" || printf 'true\n' ;;
  root) printf '%s\n' "/r${ds_esc}[1moot" ;;
  ls) printf '%s\n' '{"dependencies":{"ev\\u001b[31mil":{}}}' ;;
esac
exit 0
SH
# The fake git also writes an escape to stderr (a shim's or a config error's
# text): doctor must not pass a command's stderr through either.
cat > "$ds_bin/git" <<SH
#!/bin/sh
if [ "\$1" = --version ]; then printf '%s\n' "git version 2${ds_esc}[2J"; printf '%s\n' "shim${ds_esc}]0;x${ds_bel}" >&2; exit 0; fi
if [ "\$1" = config ] && [ "\$2" = --global ]; then printf '%s\n' "warn${ds_esc}[5m" >&2; fi
exec "$ds_real_git" "\$@"
SH
cat > "$ds_bin/chezmoi" <<SH
#!/bin/sh
if [ "\$1" = --version ]; then printf '%s\n' "chezmoi version v2${ds_bel}x"; exit 0; fi
exit 1
SH
cat > "$ds_bin/corepack" <<SH
#!/bin/sh
printf '%s\n' "0.3${ds_rlo}1"
SH
cat > "$ds_bin/brew" <<SH
#!/bin/sh
case "\$*" in
  leaves*) printf '%s\n' "le${ds_esc}[31maf" ;;
  "list --cask"*) printf '%s\n' "ca${ds_c1}sk" ;;
esac
exit 0
SH
# A bidi override, not a control: go_bin_dir refuses a path with a control
# character, and under a UTF-8 locale macOS counts U+202E as one too, so the
# run is in the C locale (display_safe does not depend on it; DS-U checks).
ds_gobin="$ds_home/g${ds_rlo}o/bin"
mkdir -p "$ds_gobin"
: > "$ds_gobin/b${ds_esc}[31min"
chmod +x "$ds_gobin/b${ds_esc}[31min"
cat > "$ds_bin/go" <<SH
#!/bin/sh
[ "\$1" = env ] || exit 2
case "\$2" in
  GOBIN) printf '%s\n' "$ds_gobin" ;;
  GOPATH) printf '%s\n' "$ds_home/go" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$ds_bin/herdr" "$ds_bin/opencode" "$ds_bin/npm" "$ds_bin/git" "$ds_bin/chezmoi" "$ds_bin/corepack" "$ds_bin/brew" "$ds_bin/go"
printf '[core]\n\texcludesFile = /ex%scl%sudes\n' "$ds_esc" "$ds_rlo" > "$ds_home/.gitconfig"
mkdir -p "$ds_home/.config/git"
: > "$ds_home/.config/git/ignore"
# names others can shape: a repo directory, plugin files, the marker, a
# Codex project key
ds_repo="$ds_home/src/personal/re${ds_esc}[31mpo"
env -i PATH="$PATH" HOME="$ds_home" GIT_CONFIG_NOSYSTEM=1 git init -q --template= "$ds_repo"
env -i PATH="$PATH" HOME="$ds_home" GIT_CONFIG_NOSYSTEM=1 \
  git -C "$ds_repo" remote add origin "https://user:canary-ds-335@example.invalid/x.git"
env -i PATH="$PATH" HOME="$ds_home" GIT_CONFIG_NOSYSTEM=1 \
  git -C "$ds_repo" remote add "ev${ds_rlo}il" "https://user:canary-ds-335@example.invalid/y.git"
printf '// personal\n' > "$ds_home/.config/opencode/plugins/personal-x${ds_esc}[31m.js"
printf '// copy\n' > "$ds_home/.config/opencode/plugins/personal-y${ds_rlo}z.ts"
printf '// listed\n' > "$ds_home/.config/opencode/plugins/personal-w${ds_esc}[1m.js"
printf '{"plugin":["personal-w\\u001b[1m"]}\n' > "$ds_home/.config/opencode/opencode.json"
printf '{"schema_version":1,"last_success":"2026%s[2J","archive":"a%sb.age","file_count":2,"capture_incomplete":false}\n' "$ds_esc" "$ds_rlo" \
  > "$ds_home/.local/state/dotfiles/private-backup.json"
printf '[projects."/gone\\u202eproj"]\ntrust_level = "trusted"\n' > "$ds_home/.codex/config.toml"
# doctor itself runs from a repo copy whose directory name carries an escape
# (the checkout's own path is a name someone chose too).
ds_repo_copy="$fixture_home/do${ds_esc}[7mtfiles"
copy_repo_fixture "$ds_repo_copy"
ds_repo_shown="$(cd "$ds_repo_copy" && pwd)"
ds_repo_shown="${ds_repo_shown//$ds_esc/?}"
if ds_out="$(env -u OPENCODE_CONFIG -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL HOME="$ds_home" AGENT_TOOLS="$ds_home/at" \
    GIT_CONFIG_NOSYSTEM=1 LC_ALL=C PATH="$ds_bin:$PATH" "$ds_repo_copy/scripts/doctor.sh" personal 2>&1)"; then
  ds_missing=""
  for ds_line in \
    "[warn] check manifest_validation: fail?[2J" \
    "[warn] agent-tools sync conflicts (unmanaged same-name targets; tools: co?]0;x?dex); sync must not change them" \
    "[info] - herdr's own view: opencode integration not?[2J installed (" \
    "[ok] source directory: $ds_repo_shown" \
    "[info] - npm userconfig=/x?y?z/.npmrc" \
    "[ok] git: git version 2?[2J" \
    "[ok] chezmoi: chezmoi version v2?x" \
    "[ok] corepack: 0.3?1" \
    "[warn] global gitignore: git reads /ex?cl?udes, not the managed" \
    "[warn] go install target is $ds_home/g?o/bin, not ~/go/bin" \
    "[info] - go bin: $ds_home/g?o/bin" \
    "[warn] undeclared: b?[31min (go binary not in catalog)" \
    "(global root: /r?[1moot)" \
    "[warn] undeclared: ev?[31mil (npm global not in catalog)" \
    "[warn] undeclared: le?[31maf (brew_formula leaf not in catalog)" \
    "[warn] undeclared: ca?sk (brew_cask not in catalog)" \
    "[warn] credential-like userinfo in remote URL: repo=$ds_home/src/personal/re?[31mpo remote=origin (URL not shown)" \
    "[warn] credential-like userinfo in remote URL: repo=$ds_home/src/personal/re?[31mpo remote=ev?il (URL not shown)" \
    "[ok] agent-tools plugin personal-x?[31m.js in the global plugins dir" \
    "[warn] agent-tools plugin personal-w?[1m is also listed in an OpenCode config's plugin key" \
    "[ok] npm: 1?[2J" \
    "[warn] npm version '1?[2J' not recognized" \
    "[warn] agent-tools plugin copy that OpenCode may load twice: $ds_home/.config/opencode/plugins/personal-y?z.ts (" \
    "[ok] last backup: 2026?[2J (archive: a?b.age, files: 2, capture: complete)" \
    "[warn] stale Codex projects trust (path no longer exists): /gone?proj — leftover grant"; do
    grep -Fq -- "$ds_line" <<< "$ds_out" || ds_missing+="  $ds_line"$'\n'
  done
  ds_raw=""
  for ds_byte in "$ds_esc" "$ds_bel" "$ds_c1" "$ds_rlo" "$ds_ff"; do
    LC_ALL=C grep -Fq -- "$ds_byte" <<< "$ds_out" && ds_raw+=" $(printf '%q' "$ds_byte")"
  done
  if [[ -z "$ds_missing" && -z "$ds_raw" ]] && ! grep -Fq "canary-ds-335" <<< "$ds_out"; then
    ok "test passed: every value doctor did not make itself is shown through display_safe (no raw control, C1 or bidi byte in the report)"
  else
    printf '%s\n' "$ds_out" | LC_ALL=C cat -v >&2
    printf 'missing:\n%sraw bytes in the report:%s\n' "$ds_missing" "${ds_raw:- none}" >&2
    fail "test failed: an outside value reached the report without display_safe"
    status=1
  fi
else
  printf '%s\n' "$ds_out" | LC_ALL=C cat -v >&2
  fail "test failed: doctor must stay exit 0 (display_safe sources)"
  status=1
fi
rm -rf "${ds_home:?}" "${ds_bin:?}" "${ds_repo_copy:?}"

# DS-2) a repo directory with a bidi override, in the inherited locale (where
#       bash 3.2's %q leaves bytes raw): the Claude allow watcher names its
#       settings file in the warn line and in the next-actions step through
#       shell_quote_safe, so the report holds no raw byte of it (an ordinary
#       non-ASCII character in the name too: the quoting is ASCII-only).
ds2_home="$fixture_home/ds2-home"
ds2_file="$ds2_home/src/personal/rl${ds_rlo}o"$'\xe4\xb8\x80'"/.claude/settings.local.json"
mkdir -p "${ds2_file%/*}"
printf '{"permissions":{"allow":["Bash(sudo -v)"]}}\n' > "$ds2_file"
ds2_quoted="$(shell_quote_safe "$ds2_file")"
if ds_out="$(HOME="$ds2_home" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && grep -Fq "[warn] 1 outward probe(s) auto-allowed for Claude by project-level allow rules in $ds2_quoted: 'sudo -v'" <<< "$ds_out" \
  && grep -Fq "        edit $ds2_quoted: remove the allow rules" <<< "$ds_out" \
  && ! LC_ALL=C grep -Fq -- "$ds_rlo" <<< "$ds_out"; then
  ok "test passed: a Claude project path with a bidi override is quoted ASCII-only in the warn and the step"
else
  printf '%s\n' "$ds_out" | LC_ALL=C cat -v >&2
  fail "test failed: a Claude project path with a bidi override reached the report raw"
  status=1
fi
rm -rf "${ds2_home:?}"

# DS-3) the policy validation's failure path names the checkout's data files:
#       a checkout whose directory name carries an escape, with a data file
#       missing, still fails (exit 1) and shows the path with `?`.
ds3_copy="$fixture_home/mi${ds_esc}[1mss"
copy_repo_fixture "$ds3_copy"
rm -f "$ds3_copy/.chezmoidata/modules.yaml"
ds3_rc=0
ds_out="$(HOME="$fixture_home" "$ds3_copy/scripts/doctor.sh" personal 2>&1)" || ds3_rc=$?
if [[ "$ds3_rc" -ne 0 ]] && grep -Fq "[fail] missing data file:" <<< "$ds_out" \
  && grep -Fq "mi?[1mss/" <<< "$ds_out" && ! grep -Fq "$ds_esc" <<< "$ds_out"; then
  ok "test passed: a failing policy validation in a checkout named with an escape fails and shows the path with ?"
else
  printf '%s\n' "$ds_out" | LC_ALL=C cat -v >&2
  fail "test failed: the policy validation's failure path reached the report raw (exit $ds3_rc)"
  status=1
fi
rm -rf "${ds3_copy:?}"

# DS-4) text tools that parse another tool's output run in the C locale with
#       stderr discarded: under a UTF-8 locale awk / cut / grep report an
#       invalid byte with the input quoted, past every report helper. A
#       remote URL, npm's version and herdr's answer carry an invalid byte and
#       an escape; the run keeps the inherited locale, the remote is still
#       flagged, and no raw byte of them reaches the report.
ds4_home="$fixture_home/ds4-home"
ds4_bin="$fixture_home/ds4-bin"
mkdir -p "$ds4_bin"
ds4_repo="$ds4_home/src/personal/repo"
env -i PATH="$PATH" HOME="$ds4_home" GIT_CONFIG_NOSYSTEM=1 git init -q --template= "$ds4_repo"
env -i PATH="$PATH" HOME="$ds4_home" GIT_CONFIG_NOSYSTEM=1 \
  git -C "$ds4_repo" remote add origin "https://user:pw${ds_ff}${ds_esc}[2J@example.invalid/x.git"
cat > "$ds4_bin/npm" <<SH
#!/bin/sh
case "\$1" in
  --version) printf '%s\n' "1${ds_ff}.2${ds_esc}[2J" ;;
esac
exit 0
SH
cat > "$ds4_bin/herdr" <<SH
#!/bin/sh
[ "\$1" = integration ] && [ "\$2" = status ] || exit 0
printf '%s\n' "claude: no${ds_ff}t${ds_esc}[2J (x)" "codex: not installed (y)" "opencode: not installed (z)"
SH
chmod +x "$ds4_bin/npm" "$ds4_bin/herdr"
if ds_out="$(env -u LC_ALL HOME="$ds4_home" GIT_CONFIG_NOSYSTEM=1 PATH="$ds4_bin:$PATH" "$SCRIPT_DIR/doctor.sh" personal 2>&1)" \
  && grep -Fq "[warn] credential-like userinfo in remote URL: repo=$ds4_repo remote=origin (URL not shown)" <<< "$ds_out" \
  && ! LC_ALL=C grep -Fq -- "$ds_esc" <<< "$ds_out" && ! LC_ALL=C grep -Fq -- "$ds_ff" <<< "$ds_out"; then
  ok "test passed: another tool's output with an invalid byte is parsed in the C locale, its tools' stderr discarded (no raw byte in the report)"
else
  printf '%s\n' "$ds_out" | LC_ALL=C cat -v >&2
  fail "test failed: a text tool's stderr or an invalid byte from another tool's output reached the report"
  status=1
fi
rm -rf "${ds4_home:?}" "${ds4_bin:?}"

# NT) network tunnels (#333 F34): PATH 上の tunnel tool の報告は allowNetworkTunnels
#     だけで決まる (work = false は warn、personal = true は中立の item)。PATH に
#     無ければその旨の ok。doctor は tool を探すだけで実行しない: fake は呼び出しを
#     記録するので、記録 (marker) の不在で「実行しない」を pin する。PATH は fake dir
#     (fake の tailscale、yq と op / herdr / codex / opencode / brew / npm の stub の
#     link。system dir には本物の npm が在りうるので、stub を先に置く。#458) と
#     system dir の写し (/usr/bin と /bin の全 entry への symlink から tunnel tool の
#     名前だけを除いた dir) に固定する。tunnel tool の有無は fake dir だけで決まり、
#     開発機や CI の runner に入っている tailscale / cloudflared / ngrok /
#     zerotier-cli (apt の package は /usr/bin に置く) はどの run にも届かない
#     (Codex review, PR #368)。
nt_home="$fixture_home/nt-home"
nt_fakebin="$fixture_home/nt-bin"
nt_sysbin="$fixture_home/nt-sysbin"
nt_calls="$fixture_home/nt-calls"
mkdir -p "$nt_home" "$nt_fakebin" "$nt_sysbin"
ln -sf "$(command -v yq)" "$nt_fakebin/yq"
for host_tool in op herdr codex opencode brew npm; do
  ln -sf "$host_stub_dir/bin/$host_tool" "$nt_fakebin/$host_tool"
done
# /bin を先に link し /usr/bin を -f で上書きする: 同名は /usr/bin が勝つ (PATH
# "/usr/bin:/bin" と同じ順。merged-usr の Linux では /bin と /usr/bin は同じ entry)。
ln -s /bin/* "$nt_sysbin/"
ln -sf /usr/bin/* "$nt_sysbin/"
rm -f "$nt_sysbin/tailscale" "$nt_sysbin/cloudflared" "$nt_sysbin/ngrok" "$nt_sysbin/zerotier-cli"
nt_path="$nt_fakebin:$nt_sysbin"
printf '#!/bin/sh\nprintf "%%s\\n" tailscale >> %q\nexit 1\n' "$nt_calls" > "$nt_fakebin/tailscale"
chmod +x "$nt_fakebin/tailscale"
# NT-1) work (allowNetworkTunnels=false): warn が出て、item と「無い」の行は出ない。
if nt_out="$(HOME="$nt_home" PATH="$nt_path" "$SCRIPT_DIR/doctor.sh" work 2>&1)"; then
  if grep -Fxq "[ok] allowNetworkTunnels=false" <<< "$nt_out" \
    && grep -Fxq "[warn] tunnel tool present but allowNetworkTunnels=false: tailscale (not removed automatically)" <<< "$nt_out" \
    && ! grep -Fq "tunnel tool present: tailscale" <<< "$nt_out" \
    && ! grep -Fq "no tunnel tools found" <<< "$nt_out" && [[ ! -e "$nt_calls" ]]; then
    ok "test passed: a tunnel tool on PATH warns under allowNetworkTunnels=false (work) and is never run"
  else
    printf '%s\n' "$nt_out" >&2
    fail "test failed: tunnel tool under allowNetworkTunnels=false (work) not reported as a warn, or the fake was run"
    status=1
  fi
else
  printf '%s\n' "$nt_out" >&2
  fail "test failed: doctor must stay exit 0 (tunnel tool present, work)"
  status=1
fi
# NT-2) personal (allowNetworkTunnels=true): 中立の item が出て、warn は出ない。
if nt_out="$(HOME="$nt_home" PATH="$nt_path" "$SCRIPT_DIR/doctor.sh" personal 2>&1)"; then
  if grep -Fxq "[ok] allowNetworkTunnels=true" <<< "$nt_out" \
    && grep -Fxq "[info] - tunnel tool present: tailscale" <<< "$nt_out" \
    && ! grep -Fq "tunnel tool present but allowNetworkTunnels=false" <<< "$nt_out" \
    && ! grep -Fq "no tunnel tools found" <<< "$nt_out" && [[ ! -e "$nt_calls" ]]; then
    ok "test passed: a tunnel tool on PATH is a neutral item under allowNetworkTunnels=true (personal) and is never run"
  else
    printf '%s\n' "$nt_out" >&2
    fail "test failed: tunnel tool under allowNetworkTunnels=true (personal) not reported as an item, or the fake was run"
    status=1
  fi
else
  printf '%s\n' "$nt_out" >&2
  fail "test failed: doctor must stay exit 0 (tunnel tool present, personal)"
  status=1
fi
# NT-3) PATH に tunnel tool が無い: 「無い」の ok が出て、warn も item も出ない。
rm -f "$nt_fakebin/tailscale"
if nt_out="$(HOME="$nt_home" PATH="$nt_path" "$SCRIPT_DIR/doctor.sh" work 2>&1)"; then
  if grep -Fxq "[ok] no tunnel tools found" <<< "$nt_out" \
    && ! grep -Fq "tunnel tool present" <<< "$nt_out"; then
    ok "test passed: no tunnel tool on PATH reports none found"
  else
    printf '%s\n' "$nt_out" >&2
    fail "test failed: absent tunnel tools not reported as none found"
    status=1
  fi
else
  printf '%s\n' "$nt_out" >&2
  fail "test failed: doctor must stay exit 0 (no tunnel tools)"
  status=1
fi
rm -rf "${nt_home:?}" "${nt_fakebin:?}" "${nt_sysbin:?}" "$nt_calls"

fi # end of part 3

if [[ "$status" -eq 0 ]]; then
  ok "doctor tests passed${TEST_DOCTOR_PART:+ (part $TEST_DOCTOR_PART of $doctor_parts)}"
fi
exit "$status"
