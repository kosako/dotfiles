#!/usr/bin/env bash
set -euo pipefail

# Behaviour tests for the compinit daily cache in dot_zshrc (#329). The block
# from `autoload -Uz compinit` up to the fzf-tab section is extracted from the
# managed file and sourced into an isolated `zsh -f` whose HOME is a fixture
# dir, so the real ~/.zcompdump is never read or written. The contract:
#   - a missing dump, or one older than 24h, takes the slow path (compinit -u)
#     and leaves a dump that the next 24h of shells treat as recent;
#   - a recent dump takes the fast path (compinit -C) and is left untouched.
# compinit rewrites an existing dump only when the set of completion files
# changed, so without the mtime refresh a day-old dump stayed old and every
# shell kept taking the slow path. `zsh -n` in CI cannot see that.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

command -v zsh >/dev/null || { fail "zsh is required for the compinit tests"; exit 1; }

ZSHRC_SOURCE="$DOTFILES_ROOT/dot_zshrc"
status=0
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-zshrc-compinit.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home"

# Each marker must exist exactly once, and the extraction must hold both
# compinit calls, so a moved block fails loudly instead of testing nothing.
start_markers="$(grep -c '^autoload -Uz compinit$' "$ZSHRC_SOURCE" || true)"
end_markers="$(grep -c '^# fzf-tab: ' "$ZSHRC_SOURCE" || true)"
if [[ "$start_markers" != 1 || "$end_markers" != 1 ]]; then
  fail "extraction markers must appear exactly once in $ZSHRC_SOURCE (start x$start_markers, end x$end_markers)"
  exit 1
fi
awk '/^autoload -Uz compinit$/ { on = 1 } /^# fzf-tab: / { on = 0 } on' \
  "$ZSHRC_SOURCE" > "$fixture/compinit.zsh"
if ! grep -q 'compinit -u' "$fixture/compinit.zsh" || ! grep -q 'compinit -C' "$fixture/compinit.zsh"; then
  fail "could not extract the compinit block from $ZSHRC_SOURCE (layout changed? update the awk markers)"
  exit 1
fi
ok "extracted the compinit block from dot_zshrc (markers present exactly once)"

dump="$fixture/home/.zcompdump"

# zsh helpers, so the mtime arithmetic is the same on macOS and Linux.
# set_age SECONDS — set the dump's mtime that many seconds in the past.
set_age() {
  HOME="$fixture/home" zsh -f -c 'zmodload zsh/datetime
strftime -s ts "%Y%m%d%H%M.%S" $(( EPOCHSECONDS - $1 ))
touch -t "$ts" -- "$2"' zsh "$1" "$dump"
}
# age — print the dump's age in seconds.
age() {
  HOME="$fixture/home" zsh -f -c 'zmodload zsh/datetime zsh/stat
print -r -- $(( EPOCHSECONDS - $(zstat +mtime -- "$1") ))' zsh "$dump"
}
# open_shell — source the extracted block the way an interactive shell does.
open_shell() {
  env -u ZDOTDIR HOME="$fixture/home" zsh -f -c 'source "$1"' zsh "$fixture/compinit.zsh" </dev/null
}

# 1. No dump yet: the slow path writes one, recent enough for the fast path.
if open_shell && [[ -s "$dump" ]] && (( $(age) < 3600 )); then
  ok "test passed: a missing dump is created and is recent"
else
  fail "test failed: a missing dump must be created by the slow path"
  status=1
fi

# 2. A valid dump older than 24h (fpath unchanged, so compinit itself does
#    not rewrite it): the slow path must leave it recent, or every later
#    shell takes the slow path again.
set_age $((5 * 86400))
if open_shell && (( $(age) < 3600 )); then
  ok "test passed: a day-old dump is refreshed by the slow path"
else
  fail "test failed: a dump older than 24h must be refreshed by the slow path (age now $(age)s)"
  status=1
fi

# 3. A recent dump takes the fast path: it is left untouched (an hour old
#    stays an hour old; the slow path would have refreshed it).
set_age 3600
if open_shell && (( $(age) >= 3600 )); then
  ok "test passed: a recent dump takes the fast path and is left as is"
else
  fail "test failed: a dump younger than 24h must take the fast path (age now $(age)s)"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "zshrc compinit tests passed"
fi
exit "$status"
