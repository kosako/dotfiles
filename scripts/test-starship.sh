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

# Prefer a full TOML parser (available in both CI jobs). Older Python/macOS
# can still exercise the current multiline-literal `when` blocks with awk.
has_tomllib=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
  has_tomllib=1
  if python3 - "$STARSHIP_SRC" <<'PY'
import sys
import tomllib
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
  warn "python3/tomllib not found; skipping TOML parse check (fixtures use awk)"
fi

section "fixture checks: git identity classification"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-starship-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fixture="$(cd "$fixture" && pwd -P)"
mkdir -p "$fixture/home/.config/git" "$fixture/empty-template" "$fixture/outside"

# Clear inherited Git identity/config overrides as well as shell startup vars.
# The ceiling also keeps the outside case outside any enclosing checkout.
run_isolated() {
  env -i PATH="$PATH" HOME="$fixture/home" \
    XDG_CONFIG_HOME="$fixture/home/.config" LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CEILING_DIRECTORIES="$fixture" "$@"
}

cat > "$fixture/home/.config/git/personal.gitconfig" <<'EOF'
[user]
  email = dotfiles-test@example.invalid
EOF

for context in personal other none; do
  mkdir -p "$fixture/$context"
  run_isolated git -C "$fixture/$context" init --quiet --template="$fixture/empty-template"
  run_isolated git -C "$fixture/$context" config user.useConfigOnly true
  run_isolated git -C "$fixture/$context" config user.name 'Dotfiles Test'
done
run_isolated git -C "$fixture/personal" config user.email dotfiles-test@example.invalid
run_isolated git -C "$fixture/other" config user.email dotfiles-other@example.invalid

extract_when() {
  local module="$1"
  if [[ "$has_tomllib" -eq 1 ]]; then
    python3 - "$STARSHIP_SRC" "$module" "$fixture" <<'PY'
import pathlib
import sys
import tomllib

source, module, fixture = sys.argv[1:]
with open(source, "rb") as f:
    config = tomllib.load(f)["custom"][module]
when = config["when"]
shell = config.get("shell", ["sh"])
if not isinstance(when, str) or not when.strip():
    sys.exit(f"custom.{module}.when must be a nonempty script")
if (not isinstance(shell, list) or not shell
        or any(not isinstance(arg, str) or not arg or "\0" in arg for arg in shell)):
    sys.exit(f"custom.{module}.shell must be a nonempty string array")
pathlib.Path(fixture, module + ".when").write_text(when)
pathlib.Path(fixture, module + ".shell").write_bytes(
    b"\0".join(arg.encode() for arg in shell) + b"\0")
PY
  else
    # This fallback deliberately accepts only the source's current literal
    # blocks and default shell. A configured shell needs tomllib, never a
    # silent substitution with sh. Do not interpret TOML with shell eval.
    if ! awk -v header="[custom.$module]" -v quote="'''" '
      $0 == header { active = 1; next }
      active && reading {
        if ($0 == quote) { reading = 0; closed++; next }
        print
        next
      }
      /^\[/ { active = 0 }
      active && /^[[:space:]]*shell[[:space:]]*=/ { unsupported = 1 }
      active && $0 == "when = " quote { reading = 1; opened++ }
      END { exit (unsupported || reading || opened != 1 || closed != 1) }
    ' "$STARSHIP_SRC" > "$fixture/$module.when"; then
      fail "cannot extract custom.$module; install Python with tomllib for other TOML/shell syntax"
      return 1
    fi
    printf 'sh\0' > "$fixture/$module.shell"
  fi
}

for module in git_ctx_personal git_ctx_other git_ctx_none; do
  if ! extract_when "$module"; then
    fail "test failed: extracting custom.$module"
    exit 1
  fi
  shell_args=()
  while IFS= read -r -d '' arg; do
    shell_args+=("$arg")
  done < "$fixture/$module.shell"

  for context in personal other none outside; do
    expected=1
    [[ "$module" == "git_ctx_$context" ]] && expected=0
    # Starship feeds the script to the configured shell's stdin. Keep the
    # script itself out of any generated shell command string.
    if (cd "$fixture/$context" && run_isolated "${shell_args[@]}" < "$fixture/$module.when"); then
      actual=0
    else
      actual=$?
    fi
    if [[ "$actual" -eq "$expected" ]]; then
      ok "test passed: $context / $module (exit $actual)"
    else
      fail "test failed: $context / $module (expected exit $expected, got $actual)"
      status=1
    fi
  done
done

if [[ "$status" -eq 0 ]]; then
  ok "starship tests passed"
fi
exit "$status"
