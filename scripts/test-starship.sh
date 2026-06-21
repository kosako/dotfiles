#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

STARSHIP_SRC="$DOTFILES_ROOT/private_dot_config/starship.toml"

status=0

check_contains() {
  local name="$1" needle="$2"
  if grep -Fq "$needle" "$STARSHIP_SRC"; then
    ok "test passed: $name"
  else
    fail "test failed: $name (missing: $needle)"
    status=1
  fi
}

section "static checks: starship.toml"

if [[ ! -f "$STARSHIP_SRC" ]]; then
  fail "missing source: $STARSHIP_SRC"
  exit 1
fi

# Public-safety: the managed prompt config must carry NO identity values. The
# git-identity segment classifies the context by reading the LOCAL
# personal.gitconfig at runtime, never by hard-coding name/email here
# (docs/git-identity.md). Mirrors the dot_gitconfig guards.
if grep -Eq '^[[:space:]]*(name|email)[[:space:]]*=' "$STARSHIP_SRC"; then
  fail "test failed: starship.toml contains a name/email identity assignment"
  status=1
else
  ok "test passed: no identity assignment in starship.toml"
fi

# An '@' would indicate a leaked email value (the file legitimately needs none).
if grep -Fq '@' "$STARSHIP_SRC"; then
  fail "test failed: starship.toml contains an '@' (possible email value)"
  status=1
else
  ok "test passed: no email-like value in starship.toml"
fi

# The identity segment must classify by reading the local personal.gitconfig
# (a runtime, value-free comparison), and define all three context modules.
check_contains "classifies via local personal.gitconfig" '.config/git/personal.gitconfig'
for module in git_ctx_personal git_ctx_other git_ctx_none; do
  check_contains "defines custom.$module" "[custom.$module]"
done

# Parse the TOML so a malformed prompt config fails here, not on first shell.
# Guarded on python3 (present in CI); skipped otherwise.
if command -v python3 >/dev/null 2>&1; then
  if python3 - "$STARSHIP_SRC" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(0)  # older python without tomllib: skip, not fail
with open(sys.argv[1], "rb") as f:
    tomllib.load(f)
PY
  then
    ok "test passed: starship.toml is valid TOML"
  else
    fail "test failed: starship.toml is not valid TOML"
    status=1
  fi
else
  warn "python3 not found; skipping TOML parse check"
fi

if [[ "$status" -eq 0 ]]; then
  ok "starship tests passed"
fi
exit "$status"
