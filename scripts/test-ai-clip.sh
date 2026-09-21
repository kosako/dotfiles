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
awk '/^_ai_clip_strip_ansi\(\) \{$/ { on = 1 } /^# Ctrl-O widget:/ { on = 0 } on' \
  "$ZSHRC_SOURCE" > "$fixture/helpers.zsh"
if ! grep -q '^_ai_clip_run() {$' "$fixture/helpers.zsh"; then
  fail "could not extract _ai_clip_run from $ZSHRC_SOURCE (layout changed? update the awk markers)"
  exit 1
fi
ok "extracted the ai-clip helpers from dot_zshrc"

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
#    zsh — the path a real Ctrl-C takes. First the control: the old body
#    must leave the file behind (otherwise this case proves nothing); then
#    the managed body must not. The zsh's own exit status is irrelevant.
find "$fixture/tmp" -name 'ai-clip.*' -delete
run_zsh "$with_clip" "-i" "_ai_clip_run_old 'echo audit-output; kill -INT \$\$'" >/dev/null 2>&1 || true
control_left="$(leftovers)"
find "$fixture/tmp" -name 'ai-clip.*' -delete
run_zsh "$with_clip" "-i" "_ai_clip_run 'echo audit-output; kill -INT \$\$'" >/dev/null 2>&1 || true
fixed_left="$(leftovers)"
if [[ "$control_left" == 1 && "$fixed_left" == 0 ]]; then
  ok "test passed: SIGINT mid-command (interactive zsh) -> old body leaves the temp (control), always-block body removes it"
else
  find "$fixture/tmp" -name 'ai-clip.*' >&2
  fail "test failed: interrupt case (control leftovers=$control_left, fixed leftovers=$fixed_left; expected 1 and 0)"
  status=1
fi
find "$fixture/tmp" -name 'ai-clip.*' -delete

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
