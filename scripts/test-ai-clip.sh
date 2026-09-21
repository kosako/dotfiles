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
#   - the command runs in the CURRENT shell (cd / export persist);
#   - the copied text is "$ <command>", the output, "[exit status: N]".
#
# Interrupt semantics (measured, zsh 5.9): in a NON-interactive zsh SIGINT
# kills the process outright — no cleanup of any kind can run, and that is
# not how a terminal session behaves. An INTERACTIVE zsh (what Ctrl-C hits)
# aborts the current command and runs `always` blocks, so the interrupt case
# runs under `zsh -i`. A control run with the pre-#243 body (trailing rm)
# must leave the file behind under the same conditions, proving the case
# really exercises the interrupt path rather than a fast exit.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

zsh_bin="$(command -v zsh || true)"
[[ -n "$zsh_bin" ]] || { fail "zsh is required for the ai-clip tests"; exit 1; }

ZSHRC_SOURCE="$DOTFILES_ROOT/dot_zshrc"
status=0
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-ai-clip.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/tmp" "$fixture/bin" "$fixture/nobin" "$fixture/home"

# Extract exactly the helper functions (strip / copy / run) from the managed
# zshrc: from the first helper's definition up to the widget section. An
# empty extraction fails loudly rather than testing nothing.
start_markers="$(grep -c '^_ai_clip_strip_ansi() {$' "$ZSHRC_SOURCE" || true)"
end_markers="$(grep -c '^# Ctrl-O widget:' "$ZSHRC_SOURCE" || true)"
if [[ "$start_markers" != 1 || "$end_markers" != 1 ]]; then
  fail "extraction markers must appear exactly once in $ZSHRC_SOURCE (start x$start_markers, end x$end_markers) — a moved or dropped marker would source the wrong block"
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

# The pre-#243 body, as a control for the interrupt case: identical except
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

# run_zsh PATH_VALUE ZSH_FLAGS SNIPPET -> runs the snippet in an isolated zsh
# after sourcing the helpers; prints the snippet's stdout (stderr merged
# unless the snippet redirects it); exit status is the zsh's.
run_zsh() {
  local path_value="$1" flags="$2" snippet="$3"
  # shellcheck disable=SC2086 # flags are intentionally word-split (empty or -i)
  env -i HOME="$fixture/home" TMPDIR="$fixture/tmp" CLIP_FILE="$fixture/clip.txt" \
    PATH="$path_value" \
    "$zsh_bin" -f $flags -c "source '$fixture/helpers.zsh'; source '$fixture/old.zsh'; $snippet"
}

leftovers() {
  find "$fixture/tmp" -name 'ai-clip.*' | wc -l | tr -d ' '
}

# run_pty ZSH_SCRIPT -> runs the zsh script under a pseudo-terminal (script(1),
# BSD or util-linux flavour) as an interactive zsh and sends a real Ctrl-C
# (^C byte) to the terminal after 1 s, so the tty driver delivers SIGINT to
# the foreground process group exactly as a keyboard Ctrl-C does. Output is
# discarded; only side effects (markers, leftovers) are inspected.
script_bin="$(command -v script || true)"
if [[ -n "$script_bin" ]] && "$script_bin" --version >/dev/null 2>&1; then
  script_flavour=util-linux
else
  script_flavour=bsd
fi
run_pty() {
  local zsh_script="$1"
  case "$script_flavour" in
    bsd)
      ( sleep 1; printf '\003' ) | env -i HOME="$fixture/home" TMPDIR="$fixture/tmp" CLIP_FILE="$fixture/clip.txt" \
        PATH="$with_clip" "$script_bin" -q /dev/null "$zsh_bin" -f -i "$zsh_script" >/dev/null 2>&1 || true
      ;;
    util-linux)
      ( sleep 1; printf '\003' ) | env -i HOME="$fixture/home" TMPDIR="$fixture/tmp" CLIP_FILE="$fixture/clip.txt" \
        PATH="$with_clip" "$script_bin" -q -e -c "'$zsh_bin' -f -i '$zsh_script'" /dev/null >/dev/null 2>&1 || true
      ;;
  esac
}

with_clip="$fixture/bin:$fixture/nobin"
no_clip="$fixture/nobin"

section "ai-clip: temp file is removed on every exit path (#243)"

# 1) Normal exit: status 0, clipboard has command + output + status, no temp.
rm -f "$fixture/clip.txt"
if out="$(run_zsh "$with_clip" "" "_ai_clip_run 'echo hello'; print -r -- \"rc=\$?\"" 2>&1)" \
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
if out="$(run_zsh "$with_clip" "" "_ai_clip_run 'echo err; false'; print -r -- \"rc=\$?\"" 2>&1)" \
  && [[ "$out" == $'err\nrc=1' ]] \
  && grep -Fxq '[exit status: 1]' "$fixture/clip.txt" \
  && [[ "$(leftovers)" == 0 ]]; then
  ok "test passed: non-zero exit -> status 1 preserved, temp removed"
else
  printf 'out=%s\nleftovers=%s\n' "$out" "$(leftovers)" >&2
  fail "test failed: non-zero exit contract"
  status=1
fi

# 3) Interrupt mid-command (the audit's reproduction), under an INTERACTIVE
#    zsh — the path a real Ctrl-C takes. Reach markers pin that the command
#    ran up to the interrupt (before) and that nothing after the interrupted
#    call ran (after) — a body that returned early (e.g. mktemp failure)
#    would leave no temp either, so leftovers alone prove nothing. First the
#    control: the old body must leave the file behind; then the managed body
#    must not. The zsh's own exit status is irrelevant.
# interrupt_case FUNC -> prints "before=<yes|no> after=<yes|no> leftovers=N"
interrupt_case() {
  local func="$1"
  find "$fixture/tmp" -name 'ai-clip.*' -delete
  rm -f "$fixture/before" "$fixture/after"
  run_zsh "$with_clip" "-i" "$func 'print reached > \"$fixture/before\"; kill -INT \$\$'; print x > '$fixture/after'" >/dev/null 2>&1 || true
  printf 'before=%s after=%s leftovers=%s\n' \
    "$([[ -e "$fixture/before" ]] && echo yes || echo no)" \
    "$([[ -e "$fixture/after" ]] && echo yes || echo no)" "$(leftovers)"
}
control_result="$(interrupt_case _ai_clip_run_old)"
fixed_result="$(interrupt_case _ai_clip_run)"
if [[ "$control_result" == "before=yes after=no leftovers=1" && "$fixed_result" == "before=yes after=no leftovers=0" ]]; then
  ok "test passed: SIGINT to the shell mid-command (interactive zsh) -> reached the command, nothing after it ran; old body leaves the temp (control), always-block body removes it"
else
  printf 'control: %s\nfixed:   %s\n' "$control_result" "$fixed_result" >&2
  fail "test failed: interrupt case (expected control 'before=yes after=no leftovers=1', fixed 'before=yes after=no leftovers=0')"
  status=1
fi
find "$fixture/tmp" -name 'ai-clip.*' -delete

# 3b) A real Ctrl-C through a pseudo-terminal while an EXTERNAL command
#     (sleep) runs under the helper: the tty delivers SIGINT to the
#     foreground process group, sleep dies, and the interactive zsh aborts
#     the call — the exact keyboard scenario. Same control / reach markers.
if [[ -z "$script_bin" ]]; then
  fail "script(1) not found; the pty Ctrl-C case cannot run"
  status=1
else
  # pty_case FUNC -> prints "before=<yes|no> after=<yes|no> leftovers=N seconds=S"
  pty_case() {
    local func="$1" started ended
    find "$fixture/tmp" -name 'ai-clip.*' -delete
    rm -f "$fixture/before" "$fixture/after"
    printf "source '%s'; source '%s'; print reached > '%s'; %s 'sleep 5'; print x > '%s'\n" \
      "$fixture/helpers.zsh" "$fixture/old.zsh" "$fixture/before" "$func" "$fixture/after" > "$fixture/pty-case.zsh"
    started="$(date +%s)"
    run_pty "$fixture/pty-case.zsh"
    ended="$(date +%s)"
    printf 'before=%s after=%s leftovers=%s seconds=%s\n' \
      "$([[ -e "$fixture/before" ]] && echo yes || echo no)" \
      "$([[ -e "$fixture/after" ]] && echo yes || echo no)" "$(leftovers)" "$((ended - started))"
  }
  control_result="$(pty_case _ai_clip_run_old)"
  fixed_result="$(pty_case _ai_clip_run)"
  # seconds < 5 proves sleep was interrupted rather than run to completion.
  if [[ "$control_result" == before=yes\ after=no\ leftovers=1\ seconds=[0-4] \
    && "$fixed_result" == before=yes\ after=no\ leftovers=0\ seconds=[0-4] ]]; then
    ok "test passed: real Ctrl-C via pty ($script_flavour script) while sleep runs -> interrupted early, nothing after ran; old body leaves the temp (control), always-block body removes it"
  else
    printf 'control: %s\nfixed:   %s\n' "$control_result" "$fixed_result" >&2
    fail "test failed: pty Ctrl-C case (expected control 'before=yes after=no leftovers=1 seconds<5', fixed 'before=yes after=no leftovers=0 seconds<5')"
    status=1
  fi
  find "$fixture/tmp" -name 'ai-clip.*' -delete
fi

# 4) The command runs in the current shell: cd and export persist.
if out="$(run_zsh "$with_clip" "" "cd '$fixture/home'; _ai_clip_run 'cd /; export AI_CLIP_TEST=set'; print -r -- \"\$PWD \$AI_CLIP_TEST\"" 2>&1)" \
  && [[ "$out" == "/ set" ]]; then
  ok "test passed: cd / export inside the command persist in the current shell"
else
  printf 'out=%s\n' "$out" >&2
  fail "test failed: cd / export did not persist"
  status=1
fi

# 5) No clipboard target (no pbcopy on PATH, OSC 52 not opted in): warning
#    on stderr, command status unchanged, temp removed, nothing copied.
rm -f "$fixture/clip.txt"
if out="$(run_zsh "$no_clip" "" "_ai_clip_run 'echo x; false' 2>'$fixture/stderr.txt'; print -r -- \"rc=\$?\"")" \
  && [[ "$out" == $'x\nrc=1' ]] \
  && grep -Fq 'ai-clip: no clipboard target' "$fixture/stderr.txt" \
  && [[ ! -e "$fixture/clip.txt" && "$(leftovers)" == 0 ]]; then
  ok "test passed: clipboard failure is reported on stderr and does not change the exit status; temp removed"
else
  printf 'out=%s\nstderr=%s\nleftovers=%s\n' "$out" "$(cat "$fixture/stderr.txt" 2>/dev/null)" "$(leftovers)" >&2
  fail "test failed: clipboard-failure contract"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "ai-clip tests passed"
fi
exit "$status"
