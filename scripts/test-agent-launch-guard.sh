#!/usr/bin/env bash
# shellcheck disable=SC2088 # the guard shows paths under HOME with a literal ~/
set -euo pipefail

# Behavior tests for the agent launch guard in dot_zshrc (#491). The block is
# extracted by its begin/end markers and run under `zsh -f` in a fixture HOME
# whose claude / codex / opencode are call recorders, so no real agent CLI
# starts. Contract under test: the wrappers start the command (each argument,
# an empty one included, and the exit status intact) only when the physical
# current directory is a launch
# root or under one; the default roots (~/src, ~/dotfiles); the roots file
# (~/ and absolute lines, comments, a last line without a newline, ignored
# relative lines, no usable root refuses everywhere, and so does a file that
# cannot be told apart from absent: an unsearchable directory on its way, or
# a symlink on its way that does not reach a directory); a
# symlink under a root
# that points outside is refused, and so is a directory whose name ends in a
# newline next to a root; a root reached through a symlink still covers its
# real directory; the one-line refusal; `command NAME` bypasses.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

if ! command -v zsh >/dev/null 2>&1; then
  fail "zsh not found; agent launch guard tests require it (CI installs it, #150)"
  exit 1
fi

status=0

# A fixture path with whitespace and a quote, made physical (cd -P): macOS's
# TMPDIR sits under the /var symlink, and the guard compares physical paths.
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-agent-guard-test space's.XXXXXX")"
# Case 7 makes a directory unsearchable: open the modes again first, or
# rm -rf could not enter it.
trap 'chmod -R u+rwX "$fixture_root" 2>/dev/null || true; rm -rf "$fixture_root"' EXIT
fixture_root="$(cd -P "$fixture_root" && pwd)"
h="$fixture_root/home"
outside="$fixture_root/outside"
mkdir -p "$h/src/personal/repo" "$h/src/work/org/repo" "$h/dotfiles/scripts" \
  "$h/Downloads/site" "$h/srcx" "$h/realroot/proj" "$h/elsewhere/proj" \
  "$h/.config/dotfiles" "$outside/proj"
# A directory that looks like it is under ~/src, but its real path is not.
ln -s "$h/Downloads/site" "$h/src/personal/planted"
ln -s "$h/realroot" "$h/linkroot"
# A sibling of ~/src whose name is "src" and a newline: a command substitution
# that drops trailing newlines would read it as ~/src (Codex review R1, PR #496).
mkdir "$h/src"$'\n'
roots_file="$h/.config/dotfiles/agent-launch-roots.local"

# Extract exactly one marker-delimited block; a missing end marker would sweep
# the rest of the file in.
begin_count="$(grep -c '^# --- agent-launch-guard begin ---$' "$DOTFILES_ROOT/dot_zshrc")" || true
end_count="$(grep -c '^# --- agent-launch-guard end ---$' "$DOTFILES_ROOT/dot_zshrc")" || true
if [[ "$begin_count" != "1" || "$end_count" != "1" ]]; then
  fail "expected exactly one agent-launch-guard marker pair in dot_zshrc (begin=$begin_count end=$end_count)"
  exit 1
fi
fn_file="$fixture_root/guard.zsh"
awk '/^# --- agent-launch-guard begin ---$/,/^# --- agent-launch-guard end ---$/' \
  "$DOTFILES_ROOT/dot_zshrc" > "$fn_file"
for fn in codex opencode; do
  if ! grep -q "^function $fn { _agent_launch_guard $fn || return; command $fn \"\$@\" }\$" "$fn_file"; then
    fail "agent-launch-guard extraction broke (the $fn wrapper is missing)"
    exit 1
  fi
done
if [[ "$(tail -n 1 "$fn_file")" != "# --- agent-launch-guard end ---" ]]; then
  fail "agent-launch-guard extraction broke (end marker missing)"
  exit 1
fi

stub_bin="$fixture_root/bin"
calls="$fixture_root/calls"
mkdir -p "$stub_bin"
# Stubs that record the name and each argument in brackets, one call per
# line, and exit 3: "-p" "a b" and "-p a b" (or a dropped empty argument)
# record differently (Codex review R1). Not write_call_recorders, which
# records "$*".
for name in claude codex opencode; do
  printf '#!/bin/sh\nprintf %%s %s >> %s\nfor a in "$@"; do printf " [%%s]" "$a" >> %s; done\necho >> %s\nexit 3\n' \
    "$(shell_single_quote "$name")" "$(shell_single_quote "$calls")" \
    "$(shell_single_quote "$calls")" "$(shell_single_quote "$calls")" > "$stub_bin/$name"
  chmod +x "$stub_bin/$name"
done

# guard_run DIR WORD... — run WORD... in DIR (a zsh `cd`, so a symlink in DIR
# stays in the logical path) with the block loaded. Sets run_rc, run_out
# (stdout), run_err (stderr), run_calls (the recorder log, then cleared).
guard_run() {
  local dir="$1"
  shift
  run_rc=0
  run_out="$(HOME="$h" PATH="$stub_bin:$PATH" zsh -f -c \
    'source "$1" || exit 90; cd -- "$2" || exit 91; shift 2; "$@"' \
    guard "$fn_file" "$dir" "$@" </dev/null 2>"$fixture_root/err")" || run_rc=$?
  run_err="$(cat "$fixture_root/err")"
  run_calls=""
  if [[ -f "$calls" ]]; then
    run_calls="$(cat "$calls")"
    rm -f "$calls"
  fi
}

# expect_started LABEL DIR NAME — NAME starts in DIR with its arguments (one
# with a space, an empty one) and exit status intact, and the guard says
# nothing.
expect_started() {
  local label="$1" dir="$2" name="$3"
  guard_run "$dir" "$name" -p "a b" ""
  if [[ "$run_rc" == 3 && "$run_calls" == "$name [-p] [a b] []" && -z "$run_err" && -z "$run_out" ]]; then
    pass "$label"
  else
    miss "$label (rc=$run_rc calls=$run_calls err=$run_err)"
  fi
}

# expect_refused LABEL DIR NAME LINE — NAME does not start in DIR: status 1,
# nothing recorded, and stderr is exactly LINE.
expect_refused() {
  local label="$1" dir="$2" name="$3" line="$4"
  guard_run "$dir" "$name" -p "a b"
  if [[ "$run_rc" == 1 && -z "$run_calls" && "$run_err" == "$line" && -z "$run_out" ]]; then
    pass "$label"
  else
    miss "$label (rc=$run_rc calls=$run_calls err=$run_err)"
  fi
}

# refused_line NAME SHOWN_CWD SHOWN_ROOTS — the guard's one-line refusal.
refused_line() {
  printf '%s: not started in %s: outside the agent launch roots (%s); cd into a project under them, or run `command %s` to start it once (docs/shell.md)' \
    "$1" "$2" "$3" "$1"
}
default_roots="~/src, ~/dotfiles"
unusable_line() {
  printf '%s: not started: ~/.config/dotfiles/agent-launch-roots.local names no usable root, so every directory is refused (one absolute or ~/ path per line; docs/shell.md)' "$1"
}

# 1. Default roots: each root itself and anything under it starts, all three
#    commands.
for name in claude codex opencode; do
  expect_started "default roots: $name starts in a repo under ~/src" "$h/src/personal/repo" "$name"
done
expect_started "default roots: claude starts in ~/src itself" "$h/src" claude
expect_started "default roots: claude starts deeper under ~/src" "$h/src/work/org/repo" claude
expect_started "default roots: claude starts in ~/dotfiles" "$h/dotfiles" claude
expect_started "default roots: claude starts under ~/dotfiles" "$h/dotfiles/scripts" claude

# 2. Default roots: outside them nothing starts, and the refusal names the
#    command, the directory, and the roots.
for name in claude codex opencode; do
  expect_refused "default roots: $name refused in ~/Downloads" "$h/Downloads/site" "$name" \
    "$(refused_line "$name" "~/Downloads/site" "$default_roots")"
done
expect_refused "default roots: refused in HOME itself (shown as the full path)" "$h" claude \
  "$(refused_line claude "$h" "$default_roots")"
expect_refused "default roots: a sibling sharing the prefix (~/srcx) is refused" "$h/srcx" claude \
  "$(refused_line claude "~/srcx" "$default_roots")"
expect_refused "default roots: a directory outside HOME is refused" "$outside/proj" claude \
  "$(refused_line claude "$outside/proj" "$default_roots")"
# The logical path is under ~/src, the physical one is ~/Downloads/site.
expect_refused "default roots: a symlink under ~/src pointing outside is refused" "$h/src/personal/planted" claude \
  "$(refused_line claude "~/Downloads/site" "$default_roots")"
# Refused, and the newline is shown as \n so the refusal stays one line.
expect_refused "default roots: a sibling named src and a newline is refused, shown on one line" "$h/src"$'\n' claude \
  "$(refused_line claude '~/src\n' "$default_roots")"

# 3. `command NAME` bypasses the wrapper (the documented way to start once).
guard_run "$h/Downloads/site" command claude --version
if [[ "$run_rc" == 3 && "$run_calls" == "claude [--version]" && -z "$run_err" ]]; then
  pass "command claude starts outside the roots (bypass)"
else
  miss "command claude starts outside the roots (bypass) (rc=$run_rc calls=$run_calls err=$run_err)"
fi

# 4. A roots file replaces the default: ~/ and absolute lines, surrounding
#    whitespace, comments, blank lines, a relative line (ignored), and a last
#    line without a newline.
printf '# machine roots\n\n  ~/elsewhere  \nrelative/dir\n%s' "$outside" > "$roots_file"
expect_started "roots file: a ~/ root starts" "$h/elsewhere/proj" claude
expect_started "roots file: an absolute root on a last line without a newline starts" "$outside/proj" codex
file_roots="~/elsewhere, $outside"
expect_refused "roots file: ~/src is no longer a root" "$h/src/personal/repo" claude \
  "$(refused_line claude "~/src/personal/repo" "$file_roots")"
# The relative line names this directory if read relative to HOME.
mkdir -p "$h/relative/dir"
expect_refused "roots file: a relative line is not a root" "$h/relative/dir" opencode \
  "$(refused_line opencode "~/relative/dir" "$file_roots")"

# 5. A root reached through a symlink covers its real directory, from either
#    path.
printf '~/linkroot\n' > "$roots_file"
expect_started "roots file: a symlinked root covers its real directory" "$h/realroot/proj" claude
expect_started "roots file: a symlinked root covers its link path" "$h/linkroot/proj" claude
expect_refused "roots file: the symlinked root is shown resolved" "$h/srcx" claude \
  "$(refused_line claude "~/srcx" "~/realroot")"

# 6. A root of / covers everything (the file's choice), and ~ alone is HOME.
printf '/\n' > "$roots_file"
expect_started "roots file: / covers a directory outside HOME" "$outside/proj" claude
printf '~\n' > "$roots_file"
expect_started "roots file: ~ covers ~/Downloads" "$h/Downloads/site" claude

# 7. A roots file with no usable root refuses everywhere, ~/src included.
printf '# nothing yet\nsrc\n~someone/src\n' > "$roots_file"
expect_refused "roots file without a usable root: refused under ~/src" "$h/src/personal/repo" claude \
  "$(unusable_line claude)"
: > "$roots_file"
expect_refused "empty roots file: refused under ~/src" "$h/src/personal/repo" codex \
  "$(unusable_line codex)"
rm -f "$roots_file"
mkdir "$roots_file"
expect_refused "roots file that is a directory: refused under ~/src" "$h/src/personal/repo" opencode \
  "$(unusable_line opencode)"
rmdir "$roots_file"
ln -s "$h/missing-roots" "$roots_file"
expect_refused "roots file that is a dangling symlink: refused under ~/src" "$h/src/personal/repo" claude \
  "$(unusable_line claude)"
rm -f "$roots_file"
# A roots file that leaves ~/src out, behind a directory that cannot be
# searched: -e reads it as absent, which must not bring the default (and
# ~/src) back (Codex review R2, PR #496). Root reads through any mode.
if [[ "$(id -u)" == 0 ]]; then
  ok "skipped (running as root): unsearchable directories before the roots file"
else
  printf '~/elsewhere\n' > "$roots_file"
  chmod 000 "$h/.config/dotfiles"
  expect_refused "roots file behind an unsearchable ~/.config/dotfiles: refused under ~/src" "$h/src/personal/repo" claude \
    "$(unusable_line claude)"
  chmod 755 "$h/.config/dotfiles"
  chmod 000 "$h/.config"
  expect_refused "roots file behind an unsearchable ~/.config: refused under ~/src" "$h/src/personal/repo" codex \
    "$(unusable_line codex)"
  chmod 755 "$h/.config"
  rm -f "$roots_file"
  # Absent for sure: ~/.config/dotfiles is there and searchable, or missing
  # under a searchable ~/.config -> the default roots.
  expect_started "no roots file in a searchable ~/.config/dotfiles: the default roots" "$h/src/personal/repo" claude
  rmdir "$h/.config/dotfiles"
  expect_started "no ~/.config/dotfiles under a searchable ~/.config: the default roots" "$h/src/personal/repo" opencode
  # ~/.config/dotfiles a symlink into a directory that cannot be searched
  # (the roots file is behind it), then a dangling one: neither can be told
  # apart from absent, so neither brings the default back (Codex review R3).
  mkdir -p "$h/locked/dotfiles"
  printf '~/elsewhere\n' > "$h/locked/dotfiles/agent-launch-roots.local"
  ln -s "$h/locked/dotfiles" "$h/.config/dotfiles"
  chmod 000 "$h/locked"
  expect_refused "~/.config/dotfiles a symlink into an unsearchable directory: refused under ~/src" "$h/src/personal/repo" claude \
    "$(unusable_line claude)"
  chmod 755 "$h/locked"
  expect_started "~/.config/dotfiles a symlink into a searchable directory: the file's roots" "$h/elsewhere/proj" claude
  rm -f "$h/.config/dotfiles"
  ln -s "$h/no-such-dir" "$h/.config/dotfiles"
  expect_refused "~/.config/dotfiles a dangling symlink: refused under ~/src" "$h/src/personal/repo" codex \
    "$(unusable_line codex)"
  rm -f "$h/.config/dotfiles"
  mkdir "$h/.config/dotfiles"
fi

# 8. _agent_launch_allowed (what doctor calls): a relative directory is not
#    allowed, an absolute one is judged like the current directory.
probe_out="$(HOME="$h" zsh -f -c 'source "$1" || exit 90; shift
for d in "$@"; do if _agent_launch_allowed "$d"; then print -r -- "allowed $REPLY"; else print -r -- "refused $REPLY"; fi; done' \
  guard "$fn_file" "$h/src/personal/repo" "src/personal/repo" "$h/Downloads/site" "$h/src/personal/planted" </dev/null 2>&1)" || true
if [[ "$probe_out" == $'allowed default\nrefused default\nrefused default\nrefused default' ]]; then
  pass "_agent_launch_allowed judges absolute directories physically and refuses a relative one"
else
  miss "_agent_launch_allowed judges absolute directories physically and refuses a relative one (got: $probe_out)"
fi

# 9. Claude fresh-session baseline. Assertions inspect actual stub argv and
# exit status; the real CLI is never run.
baseline_file="$h/.config/dotfiles/claude-launch-baseline"
printf 'opus[1m]\nxhigh\n' > "$baseline_file"
expect_claude_args() {
  local label="$1" expected="$2"
  shift 2
  guard_run "$h/src/personal/repo" claude "$@"
  if [[ "$run_rc" == 3 && "$run_calls" == "claude$expected" && -z "$run_err" && -z "$run_out" ]]; then
    pass "$label"
  else
    miss "$label (rc=$run_rc calls=$run_calls err=$run_err)"
  fi
}
base=' [--model] [opus[1m]] [--effort] [xhigh]'
both="$base [--advisor] [fable]"
expect_claude_args "new session" "$both"
expect_claude_args "model override" ' [--effort] [xhigh] [--advisor] [fable] [--model] [sonnet]' --model sonnet
expect_claude_args "effort override" ' [--model] [opus[1m]] [--advisor] [fable] [--effort] [low]' --effort low
expect_claude_args "both overrides" ' [--advisor] [fable] [--model] [sonnet] [--effort] [low]' --model sonnet --effort low
expect_claude_args "model equals override" ' [--effort] [xhigh] [--advisor] [fable] [--model=sonnet]' --model=sonnet
expect_claude_args "effort equals override" ' [--model] [opus[1m]] [--advisor] [fable] [--effort=low]' --effort=low
expect_claude_args "both equals overrides" ' [--advisor] [fable] [--model=sonnet] [--effort=low]' --model=sonnet --effort=low
for flag in -r --resume --resume=session -c --continue --from-pr --from-pr=123 --teleport --teleport=session; do
  expect_claude_args "resume $flag" " [$flag]" "$flag"
done
for flag in -p --print; do
  expect_claude_args "new session $flag preserves arguments and adds no advisor" "$base [$flag] [a b] []" "$flag" 'a b' ''
done
expect_claude_args "new session --bg preserves arguments" "$both [--bg] [a b] []" --bg 'a b' ''
expect_claude_args "advisor override" "$base [--advisor] [opus]" --advisor opus
expect_claude_args "advisor equals override" "$base [--advisor=off]" --advisor=off
for subcommand in agents attach auth auto-mode doctor gateway import install logs mcp plugin plugins purge respawn rm setup-token stop kill ultrareview update upgrade; do
  expect_claude_args "subcommand $subcommand" " [$subcommand]" "$subcommand"
done
for flag in --version -v --help -h; do
  expect_claude_args "info $flag" " [$flag]" "$flag"
done
expect_claude_args "subcommand only in first argument" "$base [-p] [doctor]" -p doctor
expect_claude_args "stop parsing at double dash" "$both [--] [--resume] [--model=sonnet] [--effort] [low] [--help]" -- --resume --model=sonnet --effort low --help
expect_claude_args "print after double dash does not suppress advisor" "$both [--] [-p]" -- -p
# An option with a required value takes the next argument even when it looks
# like a flag or `--` (Codex review R1, PR #563).
expect_claude_args "option value -p is not print" "$both [--system-prompt] [-p]" --system-prompt -p
expect_claude_args "option value --advisor=off is not an override" "$both [--system-prompt] [--advisor=off]" --system-prompt --advisor=off
expect_claude_args "option value --model is not an override" "$both [--append-system-prompt] [--model]" --append-system-prompt --model
expect_claude_args "option value --resume is not a resume" "$both [-n] [--resume]" -n --resume
expect_claude_args "option value -- does not stop parsing" "$base [--system-prompt] [--] [-p] [q]" --system-prompt -- -p q
expect_claude_args "equals value does not take the next argument" "$base [--system-prompt=x] [-p]" --system-prompt=x -p
expect_claude_args "variadic option value then print" "$base [--add-dir] [a] [-p]" --add-dir a -p
expect_claude_args "hidden option value -- does not stop parsing" "$base [--prefill] [--] [-p] [q]" --prefill -- -p q
expect_claude_args "hidden option value -p is not print" "$both [--plan-mode-instructions] [-p]" --plan-mode-instructions -p
expect_claude_args "model value -p is not print" ' [--effort] [xhigh] [--advisor] [fable] [--model] [-p]' --model -p
expect_refused "baseline does not bypass guard" "$h/Downloads/site" claude "$(refused_line claude "~/Downloads/site" "$default_roots")"
printf 'sonnet\nlow\n' > "$baseline_file"
expect_claude_args "read changed baseline on each launch" ' [--model] [sonnet] [--effort] [low] [--advisor] [fable]'
for contents in '' $'opus[1m]\n' $'\nxhigh\n' $'opus[1m]\n\n' $'opus[1m]\nxhigh\nextra' $'opus[1m]\nxhigh\n\n' $'opus[1m]\nxhigh\r\n'; do
  printf '%s' "$contents" > "$baseline_file"
  expect_claude_args "empty or malformed baseline" ' [-p] [a b]' -p 'a b'
done
chmod 000 "$baseline_file"
if [[ ! -r "$baseline_file" ]]; then
  expect_claude_args "unreadable baseline" ' [-p]' -p
fi
chmod 600 "$baseline_file"
rm "$baseline_file"
expect_claude_args "absent baseline" ' [-p]' -p
mkdir "$baseline_file"
expect_claude_args "baseline is a directory" ' [-p]' -p
rmdir "$baseline_file"

exit "$status"
