#!/usr/bin/env bash
set -euo pipefail

# Behaviour tests for the Ctrl-O "AI clip" helpers in dot_zshrc (#243). The
# helpers are extracted from the managed file and sourced into an isolated
# zsh with a fixture TMPDIR, a PATH that holds ONLY the tools the helpers
# need (symlinks — never the real pbcopy) plus a fake `pbcopy`, so no real
# clipboard, home, or network is touched. Contract under test:
#   - the plain-text temp file (mktemp ai-clip.*) is removed after a normal
#     exit, a non-zero exit, AND an interrupt (Ctrl-C) mid-command — the
#     audit found it left behind on Ctrl-C (#243);
#   - the command's own exit status is returned, and a clipboard failure
#     does not change it;
#   - the command runs in the CURRENT shell (cd / export / source persist);
#   - the copied text is "$ <command>", the output, "[exit status: N]".
#   - assignments to wrapper variable names cannot redirect cleanup or
#     corrupt the copied command/status; ordinary assignments persist (#280).
#
# Interrupt semantics (measured, zsh 5.9): in a NON-interactive zsh SIGINT
# kills the process outright — no cleanup of any kind can run, and that is
# not how a terminal session behaves. An INTERACTIVE zsh (what Ctrl-C hits)
# aborts the current command and runs `always` blocks, so the interrupt
# cases run under `zsh -i`: once with SIGINT sent to the shell itself, once
# with a real Ctrl-C written to a pseudo-terminal while an external command
# runs. Each has a control run with the pre-#243 body (trailing rm) that
# must leave the file behind, proving the case exercises the interrupt path.
#
# Every case is a zsh script FILE in the fixture, run as `zsh -f [-i] FILE`;
# values reach the scripts through environment variables (AI_CLIP_FIXTURE,
# AI_CLIP_FUNC), never by embedding paths into a `-c` string, so a fixture
# path containing a quote cannot break the quoting.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

zsh_bin="$(command -v zsh || true)"
[[ -n "$zsh_bin" ]] || { fail "zsh is required for the ai-clip tests"; exit 1; }

ZSHRC_SOURCE="$DOTFILES_ROOT/dot_zshrc"
status=0
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-ai-clip.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/tmp" "$fixture/bin" "$fixture/nobin" "$fixture/home" "$fixture/cases"

# Extract exactly the helper functions (strip / copy / run) from the managed
# zshrc: from the first helper's definition up to the widget section. Each
# marker must exist exactly once (a moved or dropped marker would source the
# wrong block), and an empty extraction fails loudly rather than testing
# nothing.
start_markers="$(grep -c '^_ai_clip_strip_ansi() {$' "$ZSHRC_SOURCE" || true)"
end_markers="$(grep -c '^# Ctrl-O widget:' "$ZSHRC_SOURCE" || true)"
if [[ "$start_markers" != 1 || "$end_markers" != 1 ]]; then
  fail "extraction markers must appear exactly once in $ZSHRC_SOURCE (start x$start_markers, end x$end_markers)"
  exit 1
fi
awk '/^_ai_clip_strip_ansi\(\) \{$/ { on = 1 } /^# Ctrl-O widget:/ { on = 0 } on' \
  "$ZSHRC_SOURCE" > "$fixture/helpers.zsh"
if ! grep -q '^_ai_clip_run() {$' "$fixture/helpers.zsh"; then
  fail "could not extract _ai_clip_run from $ZSHRC_SOURCE (layout changed? update the awk markers)"
  exit 1
fi
ok "extracted the ai-clip helpers from dot_zshrc (markers present exactly once)"

# Tool-only PATH: the helpers use mktemp / cat / rm / perl / base64 / tr.
# Resolved from THIS bash (no aliases), symlinked so the real pbcopy is never
# reachable from the isolated zsh.
for tool in mktemp cat rm perl base64 tr sleep; do
  tool_path="$(command -v "$tool" || true)"
  [[ -n "$tool_path" ]] || { fail "required tool not found: $tool"; exit 1; }
  ln -s "$tool_path" "$fixture/nobin/$tool"
done

# Fake clipboard: pbcopy writes what it receives to CLIP_FILE.
cat > "$fixture/bin/pbcopy" <<'SH'
#!/bin/sh
cat > "$CLIP_FILE"
SH
chmod +x "$fixture/bin/pbcopy"

# The pre-#243 body, as a control for the interrupt cases: identical except
# that the cleanup is a trailing `rm` instead of an `always` block.
cat > "$fixture/old.zsh" <<'ZSH'
_ai_clip_run_old() {
  local cmd="$1" raw rc
  raw="$(mktemp "${TMPDIR:-/tmp}/ai-clip.XXXXXX")" || return 1
  eval "$cmd" > "$raw" 2>&1
  rc=$?
  cat -- "$raw"
  {
    print -r -- "\$ $cmd"
    _ai_clip_strip_ansi < "$raw"
    print -r -- "[exit status: $rc]"
  } | _ai_clip_copy || print -u2 -- "ai-clip: no clipboard target"
  rm -f -- "$raw"
  return "$rc"
}
ZSH

# Case scripts. They are sourced-helper zsh scripts that read AI_CLIP_FIXTURE
# (this fixture) and AI_CLIP_FUNC (which body to call) from the environment.
cat > "$fixture/cases/prelude.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/helpers.zsh"
source "$AI_CLIP_FIXTURE/old.zsh"
ZSH
cat > "$fixture/cases/normal.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
_ai_clip_run 'echo hello'
print -r -- "rc=$?"
ZSH
cat > "$fixture/cases/nonzero.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
_ai_clip_run 'echo err; false'
print -r -- "rc=$?"
ZSH
cat > "$fixture/cases/assign.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
_ai_clip_run "$(< "$AI_CLIP_FIXTURE/command.txt")"
print -r -- "rc=$?"
[[ "$raw" == "$AI_CLIP_FIXTURE/keep.txt" && "$cmd" == changed && "$rc" == 99 ]] \
  && print assignments-persist
ZSH
# Interrupt to the shell itself: the reach marker is written INSIDE the
# command (so the call demonstrably started), then SIGINT; the statement
# after the call must not run.
cat > "$fixture/cases/interrupt.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
"$AI_CLIP_FUNC" 'print reached > "$AI_CLIP_FIXTURE/before"; kill -INT $$'
print x > "$AI_CLIP_FIXTURE/after"
ZSH
# Real Ctrl-C through a pty: the command writes the reach marker (the
# sender waits for it), then blocks in an external sleep that the tty's
# SIGINT must cut short.
cat > "$fixture/cases/pty.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
"$AI_CLIP_FUNC" 'print reached > "$AI_CLIP_FIXTURE/before"; sleep 8'
print x > "$AI_CLIP_FIXTURE/after"
ZSH
cat > "$fixture/cases/interrupt_assign.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
_ai_clip_run 'raw="$AI_CLIP_FIXTURE/keep.txt"; cmd=changed; rc=99; argv=(changed); print reached > "$AI_CLIP_FIXTURE/before"; kill -INT $$'
print x > "$AI_CLIP_FIXTURE/after"
ZSH
cat > "$fixture/cases/pty_assign.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
_ai_clip_run 'raw="$AI_CLIP_FIXTURE/keep.txt"; cmd=changed; rc=99; set -- changed; print reached > "$AI_CLIP_FIXTURE/before"; sleep 8'
print x > "$AI_CLIP_FIXTURE/after"
ZSH
cat > "$fixture/cases/persist.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
cd "$AI_CLIP_FIXTURE/home"
_ai_clip_run 'cd /; export AI_CLIP_TEST=set; source "$AI_CLIP_FIXTURE/sourced.zsh"'
print -r -- "$PWD $AI_CLIP_TEST $AI_CLIP_SOURCED"
ZSH
cat > "$fixture/sourced.zsh" <<'ZSH'
export AI_CLIP_SOURCED=set
ZSH
cat > "$fixture/cases/mktemp_failure.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
mktemp() { return 1; }
_ai_clip_run 'print reached > "$AI_CLIP_FIXTURE/before"'
print -r -- "rc=$?"
ZSH
cat > "$fixture/cases/noclip.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
_ai_clip_run 'echo x; false' 2> "$AI_CLIP_FIXTURE/stderr.txt"
print -r -- "rc=$?"
ZSH

with_clip="$fixture/bin:$fixture/nobin"
no_clip="$fixture/nobin"

# run_case PATH_VALUE ZSH_FLAGS CASE FUNC -> runs cases/CASE.zsh in an
# isolated zsh; prints the case's stdout; exit status is the zsh's.
run_case() {
  local path_value="$1" flags="$2" case_name="$3" func="$4"
  # shellcheck disable=SC2086 # flags are intentionally word-split (empty or -i)
  env -i HOME="$fixture/home" TMPDIR="$fixture/tmp" CLIP_FILE="$fixture/clip.txt" \
    AI_CLIP_FIXTURE="$fixture" AI_CLIP_FUNC="$func" PATH="$path_value" \
    "$zsh_bin" -f $flags "$fixture/cases/$case_name.zsh"
}

# sq VALUE -> VALUE as a single-quoted shell literal (for the one place a
# command string is unavoidable: util-linux script -c).
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# run_pty CASE FUNC -> runs cases/CASE.zsh as an INTERACTIVE zsh under a
# pseudo-terminal (script(1), BSD or util-linux flavour). A sender waits for
# the case's reach marker (up to 10 s), then writes a ^C byte to the pty, so
# the tty driver delivers SIGINT to the foreground process group exactly as
# a keyboard Ctrl-C does. Output is discarded; only side effects are read.
script_bin="$(command -v script || true)"
if [[ -n "$script_bin" ]] && "$script_bin" --version >/dev/null 2>&1; then
  script_flavour=util-linux
else
  script_flavour=bsd
fi
# The moment the marker is seen is recorded (reached_at), so the case can
# time only what happens AFTER the command started — script(1) start-up and
# the marker wait are excluded from the early-interruption bound.
send_ctrl_c_when_reached() {
  local _tick
  for _tick in $(seq 1 100); do
    [[ -e "$fixture/before" ]] && break
    sleep 0.1
  done
  : "$_tick"
  date +%s > "$fixture/reached_at"
  sleep 0.2
  printf '\003'
}
run_pty() {
  local case_name="$1" func="$2"
  case "$script_flavour" in
    bsd)
      send_ctrl_c_when_reached | env -i HOME="$fixture/home" TMPDIR="$fixture/tmp" CLIP_FILE="$fixture/clip.txt" \
        AI_CLIP_FIXTURE="$fixture" AI_CLIP_FUNC="$func" PATH="$with_clip" \
        "$script_bin" -q /dev/null "$zsh_bin" -f -i "$fixture/cases/$case_name.zsh" >/dev/null 2>&1 || true
      ;;
    util-linux)
      send_ctrl_c_when_reached | env -i HOME="$fixture/home" TMPDIR="$fixture/tmp" CLIP_FILE="$fixture/clip.txt" \
        AI_CLIP_FIXTURE="$fixture" AI_CLIP_FUNC="$func" PATH="$with_clip" \
        "$script_bin" -q -e -c "$(sq "$zsh_bin") -f -i $(sq "$fixture/cases/$case_name.zsh")" /dev/null >/dev/null 2>&1 || true
      ;;
  esac
}

leftovers() {
  find "$fixture/tmp" -name 'ai-clip.*' | wc -l | tr -d ' '
}
reset_markers() {
  find "$fixture/tmp" -name 'ai-clip.*' -delete
  rm -f "$fixture/before" "$fixture/after" "$fixture/reached_at"
}
marker_state() {
  printf 'before=%s after=%s leftovers=%s' \
    "$([[ -e "$fixture/before" ]] && echo yes || echo no)" \
    "$([[ -e "$fixture/after" ]] && echo yes || echo no)" "$(leftovers)"
}

section "ai-clip: temp file is removed on every exit path (#243)"

# 1) Normal exit: status 0, clipboard has command + output + status, no temp.
rm -f "$fixture/clip.txt"
if out="$(run_case "$with_clip" "" normal _ai_clip_run 2>&1)" \
  && [[ "$out" == $'hello\nrc=0' ]] \
  && [[ "$(cat "$fixture/clip.txt")" == $'$ echo hello\nhello\n[exit status: 0]' ]] \
  && [[ "$(leftovers)" == 0 ]]; then
  ok "test passed: normal exit -> status 0, clipboard = command + output + status, temp removed"
else
  printf 'out=%s\nclip=%s\nleftovers=%s\n' "$out" "$(cat "$fixture/clip.txt" 2>/dev/null)" "$(leftovers)" >&2
  fail "test failed: normal exit contract"
  status=1
fi

# 2) Non-zero exit: the command's status is returned; temp removed.
rm -f "$fixture/clip.txt"
if out="$(run_case "$with_clip" "" nonzero _ai_clip_run 2>&1)" \
  && [[ "$out" == $'err\nrc=1' ]] \
  && grep -Fxq '[exit status: 1]' "$fixture/clip.txt" \
  && [[ "$(leftovers)" == 0 ]]; then
  ok "test passed: non-zero exit -> status 1 preserved, temp removed"
else
  printf 'out=%s\nleftovers=%s\n' "$out" "$(leftovers)" >&2
  fail "test failed: non-zero exit contract"
  status=1
fi

# 3) SIGINT to the shell mid-command (the audit's reproduction), under an
#    INTERACTIVE zsh. Reach markers pin that the command ran up to the
#    interrupt (before) and that nothing after the call ran (after) — a body
#    that returned early (e.g. mktemp failure) would leave no temp either, so
#    leftovers alone prove nothing. Control first: the old body must leave
#    the file behind; then the managed body must not.
reset_markers
run_case "$with_clip" "-i" interrupt _ai_clip_run_old >/dev/null 2>&1 || true
control_result="$(marker_state)"
reset_markers
run_case "$with_clip" "-i" interrupt _ai_clip_run >/dev/null 2>&1 || true
fixed_result="$(marker_state)"
if [[ "$control_result" == "before=yes after=no leftovers=1" && "$fixed_result" == "before=yes after=no leftovers=0" ]]; then
  ok "test passed: SIGINT to the shell mid-command (interactive zsh) -> reached the command, nothing after it ran; old body leaves the temp (control), always-block body removes it"
else
  printf 'control: %s\nfixed:   %s\n' "$control_result" "$fixed_result" >&2
  fail "test failed: interrupt case (expected control 'before=yes after=no leftovers=1', fixed 'before=yes after=no leftovers=0')"
  status=1
fi
reset_markers

# Assignments must not change the cleanup path, command line, or real status.
# Include argv / set -- so positional-parameter implementations also have to
# isolate the eval scope. Check display (ANSI intact) and copy (ANSI removed).
for command_status in 0 7; do
  reset_markers
  printf 'keep me\n' > "$fixture/keep.txt"
  rm -f "$fixture/clip.txt"
  command_line='raw="$AI_CLIP_FIXTURE/keep.txt"; cmd=changed; rc=99; argv=(changed); set -- changed-again; printf "\033[31mpayload\033[0m\n"'
  command_line+="; (exit $command_status)"
  printf '%s\n' "$command_line" > "$fixture/command.txt"
  expected_clip="\$ $command_line"$'\npayload\n'"[exit status: $command_status]"
  expected_out=$'\033[31mpayload\033[0m\n'"rc=$command_status"$'\nassignments-persist'
  if out="$(run_case "$with_clip" "" assign _ai_clip_run 2>&1)" \
    && [[ "$out" == "$expected_out" ]] \
    && [[ "$(cat "$fixture/clip.txt")" == "$expected_clip" ]] \
    && [[ "$(cat "$fixture/keep.txt" 2>/dev/null)" == 'keep me' ]] \
    && [[ "$(leftovers)" == 0 ]]; then
    ok "test passed: wrapper-name assignments, status $command_status -> existing file intact, temp removed, display/copy/status correct, assignments persist"
  else
    printf 'out=%s\nclip=%s\nexisting=%s\nleftovers=%s\n' "$out" \
      "$(cat "$fixture/clip.txt" 2>/dev/null)" "$(cat "$fixture/keep.txt" 2>/dev/null)" "$(leftovers)" >&2
    fail "test failed: wrapper-name assignments with status $command_status"
    status=1
  fi
done
reset_markers
printf 'keep me\n' > "$fixture/keep.txt"
run_case "$with_clip" "-i" interrupt_assign _ai_clip_run >/dev/null 2>&1 || true
if [[ "$(marker_state)" == 'before=yes after=no leftovers=0' \
  && "$(cat "$fixture/keep.txt" 2>/dev/null)" == 'keep me' ]]; then
  ok "test passed: wrapper-name assignments then SIGINT -> existing file intact, temp removed"
else
  printf '%s\n' "$(marker_state)" >&2
  fail "test failed: wrapper-name assignments then SIGINT"
  status=1
fi
reset_markers

# 3b) A real Ctrl-C through a pseudo-terminal while an EXTERNAL command
#     (sleep 8) runs under the helper: the tty delivers SIGINT to the
#     foreground process group, sleep dies, and the interactive zsh aborts
#     the call — the exact keyboard scenario. The sender waits for the reach
#     marker, so a slow start cannot make the ^C arrive too early, and the
#     early-interruption bound counts only from that moment: the 8 s sleep
#     must end in under 8 s AFTER the command started (start-up time is
#     excluded), otherwise the ^C never interrupted it.
if [[ -z "$script_bin" ]]; then
  fail "script(1) not found; the pty Ctrl-C case cannot run"
  status=1
else
  pty_case() {
    local func="$1" case_name="${2:-pty}" ended reached_at
    reset_markers
    run_pty "$case_name" "$func"
    ended="$(date +%s)"
    reached_at="$(cat "$fixture/reached_at" 2>/dev/null || echo 0)"
    printf '%s after_reach_seconds=%s' "$(marker_state)" "$((ended - reached_at))"
  }
  control_result="$(pty_case _ai_clip_run_old)"
  fixed_result="$(pty_case _ai_clip_run)"
  if [[ "$control_result" == before=yes\ after=no\ leftovers=1\ after_reach_seconds=[0-7] \
    && "$fixed_result" == before=yes\ after=no\ leftovers=0\ after_reach_seconds=[0-7] ]]; then
    ok "test passed: real Ctrl-C via pty ($script_flavour script) while sleep runs -> reached, interrupted within 8 s of starting, nothing after ran; old body leaves the temp (control), always-block body removes it"
  else
    printf 'control: %s\nfixed:   %s\n' "$control_result" "$fixed_result" >&2
    fail "test failed: pty Ctrl-C case (expected control 'before=yes after=no leftovers=1 after_reach_seconds<8', fixed 'before=yes after=no leftovers=0 after_reach_seconds<8')"
    status=1
  fi
  reset_markers
  printf 'keep me\n' > "$fixture/keep.txt"
  fixed_result="$(pty_case _ai_clip_run pty_assign)"
  if [[ "$fixed_result" == before=yes\ after=no\ leftovers=0\ after_reach_seconds=[0-7] \
    && "$(cat "$fixture/keep.txt" 2>/dev/null)" == 'keep me' ]]; then
    ok "test passed: wrapper-name assignments then real Ctrl-C -> existing file intact, temp removed"
  else
    printf '%s\n' "$fixed_result" >&2
    fail "test failed: wrapper-name assignments then pty Ctrl-C"
    status=1
  fi
  reset_markers
fi

# 4) The command runs in the current shell: cd, export, and source persist.
if out="$(run_case "$with_clip" "" persist _ai_clip_run 2>&1)" \
  && [[ "$out" == "/ set set" ]]; then
  ok "test passed: cd / export / source inside the command persist in the current shell"
else
  printf 'out=%s\n' "$out" >&2
  fail "test failed: cd / export / source did not persist"
  status=1
fi

# 5) No clipboard target (no pbcopy on PATH, OSC 52 not opted in): warning
#    on stderr, command status unchanged, temp removed, nothing copied.
rm -f "$fixture/clip.txt" "$fixture/stderr.txt"
if out="$(run_case "$no_clip" "" noclip _ai_clip_run)" \
  && [[ "$out" == $'x\nrc=1' ]] \
  && grep -Fq 'ai-clip: no clipboard target' "$fixture/stderr.txt" \
  && [[ ! -e "$fixture/clip.txt" && "$(leftovers)" == 0 ]]; then
  ok "test passed: clipboard failure is reported on stderr and does not change the exit status; temp removed"
else
  printf 'out=%s\nstderr=%s\nleftovers=%s\n' "$out" "$(cat "$fixture/stderr.txt" 2>/dev/null)" "$(leftovers)" >&2
  fail "test failed: clipboard-failure contract"
  status=1
fi

# 6) A failed temp allocation must stop before eval or clipboard access.
reset_markers
rm -f "$fixture/clip.txt"
if out="$(run_case "$with_clip" "" mktemp_failure _ai_clip_run 2>&1)" \
  && [[ "$out" == 'rc=1' && ! -e "$fixture/before" && ! -e "$fixture/clip.txt" ]] \
  && [[ "$(leftovers)" == 0 ]]; then
  ok "test passed: mktemp failure -> status 1, no command execution or copy"
else
  printf 'out=%s\n%s\n' "$out" "$(marker_state)" >&2
  fail "test failed: mktemp-failure contract"
  status=1
fi

# 7) The Ctrl-O widget itself (#307): extract _ai_clip_accept_line from the
#    managed zshrc and run it in an isolated zsh with zle and `print -s`
#    stubbed. A non-blank line is saved to history as typed, BUFFER becomes a
#    space-prefixed wrapper call, and evaluating that wrapper hands the
#    original line to _ai_clip_run as ONE argument without expanding it (a
#    command substitution in the line must not run); a space-prefixed line is
#    not saved; an empty line only accepts. The (qq) quoting and the history
#    save are what this pins.
widget_markers="$(grep -c '^_ai_clip_accept_line() {$' "$ZSHRC_SOURCE" || true)"
if [[ "$widget_markers" != 1 ]]; then
  fail "widget marker must appear exactly once in $ZSHRC_SOURCE (x$widget_markers)"
  status=1
else
  awk '/^_ai_clip_accept_line\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' \
    "$ZSHRC_SOURCE" > "$fixture/widget.zsh"
  cat > "$fixture/cases/widget.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/widget.zsh"
typeset -ga ZLE_CALLS HIST_SAVED
zle() { ZLE_CALLS+=("$*") }
print() {
  if [[ "$1" == -s ]]; then
    shift
    [[ "$1" == -- ]] && shift
    HIST_SAVED+=("$*")
  else
    builtin print "$@"
  fi
}
_ai_clip_run() { builtin print -r -- "args=$# arg1=$1" }
BUFFER="$AI_CLIP_BUFFER"
_ai_clip_accept_line
builtin print -r -- "buffer=$BUFFER"
builtin print -r -- "hist=${#HIST_SAVED} ${HIST_SAVED[1]-}"
builtin print -r -- "zle=${(j:,:)ZLE_CALLS}"
if [[ -n "$BUFFER" ]]; then eval "$BUFFER"; fi
ZSH
  # widget_case BUFFER -> the case's output for that command line.
  widget_case() {
    env -i HOME="$fixture/home" PATH="$no_clip" AI_CLIP_FIXTURE="$fixture" AI_CLIP_BUFFER="$1" \
      "$zsh_bin" -f "$fixture/cases/widget.zsh"
  }
  # shellcheck disable=SC2016 # the line is literal: it must reach the wrapper unexpanded
  widget_line='echo a; echo "b c" '\''d'\'' $(builtin print -r -- expanded > "$AI_CLIP_FIXTURE/expanded")'
  rm -f "$fixture/expanded"
  if out="$(widget_case "$widget_line")" \
    && [[ "$out" == *$'\n'"hist=1 $widget_line"$'\n'* ]] \
    && [[ "$out" == *$'\n'"zle=accept-line"$'\n'* ]] \
    && [[ "$out" == *$'\n'"args=1 arg1=$widget_line" ]] \
    && [[ "$(head -n 1 <<< "$out")" == "buffer= _ai_clip_run "* ]] \
    && [[ ! -e "$fixture/expanded" ]]; then
    ok "test passed: widget saves the line to history, wraps it space-prefixed, and the wrapper gets it as one unexpanded argument"
  else
    printf 'out=%s\nexpanded=%s\n' "$out" "$([[ -e "$fixture/expanded" ]] && echo yes || echo no)" >&2
    fail "test failed: widget quoting / history contract"
    status=1
  fi
  if out="$(widget_case ' echo secret')" \
    && [[ "$out" == *$'\n'"hist=0 "$'\n'* ]] \
    && [[ "$out" == *$'\n'"args=1 arg1= echo secret" ]]; then
    ok "test passed: a space-prefixed line is run through the wrapper but not saved to history"
  else
    printf 'out=%s\n' "$out" >&2
    fail "test failed: space-prefixed line must not be saved to history"
    status=1
  fi
  if out="$(widget_case '')" \
    && [[ "$out" == $'buffer=\nhist=0 \nzle=accept-line' ]]; then
    ok "test passed: an empty line only accepts (no wrapper, nothing saved)"
  else
    printf 'out=%s\n' "$out" >&2
    fail "test failed: empty line contract"
    status=1
  fi
fi

# 8) OSC 52 (#307): with no pbcopy on PATH and AI_CLIPBOARD_OSC52=1, the copy
#    goes to the terminal as ESC ] 52 ; c ; <base64> BEL on /dev/tty — read
#    back from script(1)'s typescript of a pseudo-terminal session.
cat > "$fixture/cases/osc52.zsh" <<'ZSH'
source "$AI_CLIP_FIXTURE/cases/prelude.zsh"
print -rn -- 'osc payload' | _ai_clip_copy
print -r -- "rc=$?"
ZSH
osc_expected="$(printf '\033]52;c;%s\007' "$(printf '%s' 'osc payload' | base64 | tr -d '\n')")"
if [[ -z "$script_bin" ]]; then
  fail "script(1) not found; the OSC 52 case cannot run"
  status=1
else
  osc_ts="$fixture/osc52.typescript"
  rm -f "$osc_ts"
  case "$script_flavour" in
    bsd)
      env -i HOME="$fixture/home" TMPDIR="$fixture/tmp" AI_CLIPBOARD_OSC52=1 AI_CLIP_FIXTURE="$fixture" \
        PATH="$no_clip" "$script_bin" -q "$osc_ts" "$zsh_bin" -f "$fixture/cases/osc52.zsh" </dev/null >/dev/null 2>&1 || true
      ;;
    util-linux)
      env -i HOME="$fixture/home" TMPDIR="$fixture/tmp" AI_CLIPBOARD_OSC52=1 AI_CLIP_FIXTURE="$fixture" \
        PATH="$no_clip" "$script_bin" -q -e -c "$(sq "$zsh_bin") -f $(sq "$fixture/cases/osc52.zsh")" "$osc_ts" </dev/null >/dev/null 2>&1 || true
      ;;
  esac
  if [[ -s "$osc_ts" ]] && LC_ALL=C grep -Fq -- "$osc_expected" "$osc_ts" && LC_ALL=C grep -q 'rc=0' "$osc_ts"; then
    ok "test passed: with OSC 52 opted in and no pbcopy, the copy reaches the terminal as an OSC 52 sequence"
  else
    printf 'typescript:\n' >&2
    LC_ALL=C od -c "$osc_ts" 2>/dev/null | head -20 >&2
    fail "test failed: OSC 52 copy did not reach the terminal"
    status=1
  fi
fi

if [[ "$status" -eq 0 ]]; then
  ok "ai-clip tests passed"
fi
exit "$status"
