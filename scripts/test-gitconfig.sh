#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

GITCONFIG_TEMPLATE="$DOTFILES_ROOT/dot_gitconfig.tmpl"

status=0
tmp_roots=()

cleanup() {
  local dir
  if [[ "${#tmp_roots[@]}" -eq 0 ]]; then
    return 0
  fi
  for dir in "${tmp_roots[@]}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

check_contains() {
  local name="$1"
  local needle="$2"
  if grep -Fq "$needle" "$GITCONFIG_TEMPLATE"; then
    ok "test passed: $name"
  else
    fail "test failed: $name (missing: $needle)"
    status=1
  fi
}

section "static checks: dot_gitconfig.tmpl"

if [[ ! -f "$GITCONFIG_TEMPLATE" ]]; then
  fail "missing template: $GITCONFIG_TEMPLATE"
  exit 1
fi

check_contains "user.useConfigOnly enabled" "useConfigOnly = true"
check_contains "transfer.credentialsInUrl die" "credentialsInUrl = die"

for context in personal work client sandbox agent; do
  check_contains "includeIf for $context" "[includeIf \"gitdir:~/src/$context/\"]"
  check_contains "include path for $context" "path = ~/.config/git/$context.gitconfig"
done

if grep -Eq '^[[:space:]]*(name|email)[[:space:]]*=' "$GITCONFIG_TEMPLATE"; then
  fail "test failed: template contains an identity assignment"
  status=1
else
  ok "test passed: no identity assignment in template"
fi

if grep -q '@' "$GITCONFIG_TEMPLATE"; then
  fail "test failed: template contains an @ (possible email value)"
  status=1
else
  ok "test passed: no email-like value in template"
fi

section "fixture checks: identity resolution"

if ! command -v git >/dev/null 2>&1; then
  warn "git not found, skipping fixture checks"
  exit "$status"
fi

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-gitconfig-test.XXXXXX")"
tmp_roots+=("$fixture")
# includeIf "gitdir:~/..." compares against the physical git dir path,
# so HOME must be the physical path too.
fixture="$(cd "$fixture" && pwd -P)"

run_git() {
  local repo="$1"
  shift
  env -u EMAIL -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    HOME="$fixture" \
    XDG_CONFIG_HOME="$fixture/.config" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL="$GITCONFIG_TEMPLATE" \
    git -C "$repo" "$@"
}

mkdir -p "$fixture/src/personal/demo" "$fixture/outside/demo" "$fixture/.config/git"

cat > "$fixture/.config/git/personal.gitconfig" <<'EOF'
[user]
	name = Dotfiles Test
	email = dotfiles-test@example.invalid
EOF

run_git "$fixture/outside/demo" init --quiet --initial-branch=main
if output="$(run_git "$fixture/outside/demo" commit --allow-empty -m test 2>&1)"; then
  printf '%s\n' "$output" >&2
  fail "test failed: commit succeeded outside known roots"
  status=1
else
  ok "test passed: commit fails outside known roots"
fi

run_git "$fixture/src/personal/demo" init --quiet --initial-branch=main
if output="$(run_git "$fixture/src/personal/demo" commit --allow-empty -m test 2>&1)"; then
  author="$(run_git "$fixture/src/personal/demo" log -1 --format='%ae')"
  if [[ "$author" == "dotfiles-test@example.invalid" ]]; then
    ok "test passed: personal context resolves test identity"
  else
    fail "test failed: unexpected author email: $author"
    status=1
  fi
else
  printf '%s\n' "$output" >&2
  fail "test failed: commit failed in personal context"
  status=1
fi

if output="$(run_git "$fixture/src/personal/demo" ls-remote https://user:secret-placeholder@invalid.example/repo.git 2>&1)"; then
  fail "test failed: credential URL was not rejected"
  status=1
elif grep -qi "credential" <<< "$output"; then
  ok "test passed: credential URL rejected"
else
  printf '%s\n' "$output" >&2
  fail "test failed: credential URL failed for another reason"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "gitconfig tests passed"
fi
exit "$status"
