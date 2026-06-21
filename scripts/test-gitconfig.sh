#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

GITCONFIG_SOURCE="$DOTFILES_ROOT/dot_gitconfig"

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
  if grep -Fq "$needle" "$GITCONFIG_SOURCE"; then
    ok "test passed: $name"
  else
    fail "test failed: $name (missing: $needle)"
    status=1
  fi
}

section "static checks: dot_gitconfig"

if [[ ! -f "$GITCONFIG_SOURCE" ]]; then
  fail "missing source: $GITCONFIG_SOURCE"
  exit 1
fi

check_contains "user.useConfigOnly enabled" "useConfigOnly = true"
check_contains "transfer.credentialsInUrl die" "credentialsInUrl = die"

for context in personal work client sandbox agent; do
  check_contains "includeIf for $context" "[includeIf \"gitdir:~/src/$context/\"]"
  check_contains "include path for $context" "path = ~/.config/git/$context.gitconfig"
done

# Personal also has remote-URL (hasconfig) rules covering all three URL
# spellings; work/client must never (their org URLs are confidential).
for pattern in \
  'hasconfig:remote.*.url:https://github.com/kosako/**' \
  'hasconfig:remote.*.url:git@github.com:kosako/**' \
  'hasconfig:remote.*.url:ssh://git@github.com/kosako/**'; do
  check_contains "hasconfig personal pattern: $pattern" "[includeIf \"$pattern\"]"
done

# The git-signing module's mechanism is pulled in via an unconditional include
# (a no-op when the file is absent / signing off).
check_contains "git-signing include directive" "[include]"
check_contains "git-signing include path" "path = ~/.config/git/signing.gitconfig"

# Public-safety: the ONLY hasconfig rules allowed are the three public personal
# patterns asserted above. Match against the exact allowlist (not a loose
# "contains kosako", which would also accept e.g. github.com/work-kosako): any
# other hasconfig line is a confidential org leaking into this public file.
unexpected_hasconfig="$(grep -F 'hasconfig:remote' "$GITCONFIG_SOURCE" \
  | grep -vF 'hasconfig:remote.*.url:https://github.com/kosako/**' \
  | grep -vF 'hasconfig:remote.*.url:git@github.com:kosako/**' \
  | grep -vF 'hasconfig:remote.*.url:ssh://git@github.com/kosako/**' || true)"
if [[ -n "$unexpected_hasconfig" ]]; then
  fail "test failed: unexpected hasconfig rule(s) in source (only the 3 public personal patterns allowed):"
  printf '%s\n' "$unexpected_hasconfig" >&2
  status=1
else
  ok "test passed: hasconfig rules are exactly the 3 public personal patterns"
fi

if grep -Eq '^[[:space:]]*(name|email)[[:space:]]*=' "$GITCONFIG_SOURCE"; then
  fail "test failed: source contains an identity assignment"
  status=1
else
  ok "test passed: no identity assignment in source"
fi

# An '@' is allowed only inside the SSH remote-URL patterns of the hasconfig
# includeIf headers (git@... / ssh://git@...); anywhere else it likely
# indicates a leaked email value.
if grep -F '@' "$GITCONFIG_SOURCE" | grep -vqF 'hasconfig:remote.*.url'; then
  fail "test failed: source contains an @ outside hasconfig URL patterns (possible email value)"
  status=1
else
  ok "test passed: no email-like value in source"
fi

# The fixture checks below feed the source file to git via
# GIT_CONFIG_GLOBAL, which only works while it is a plain gitconfig.
# dot_gitconfig is intentionally not a .tmpl; if templating becomes
# necessary, rename it back and render before the fixtures use it.
if grep -q '{{' "$GITCONFIG_SOURCE"; then
  fail "test failed: source contains template directives; fixtures assume plain gitconfig"
  status=1
else
  ok "test passed: source is directive-free"
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
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL="$GITCONFIG_SOURCE" \
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
elif grep -Eqi 'no (email|name) was given|user\.useConfigOnly' <<< "$output"; then
  ok "test passed: commit fails outside known roots (identity unresolved)"
else
  printf '%s\n' "$output" >&2
  fail "test failed: commit failed outside known roots for another reason"
  status=1
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

section "fixture checks: remote-URL identity (hasconfig)"

# A work identity file + ~/src/work/ so the ordering test below (placement
# stays authoritative) can resolve a work identity.
cat > "$fixture/.config/git/work.gitconfig" <<'EOF'
[user]
	name = Dotfiles Work Test
	email = dotfiles-work@example.invalid
EOF
mkdir -p "$fixture/src/work/demo"

# A personal repo cloned OUTSIDE ~/src/ still resolves the personal identity
# from its remote URL, for each of the three URL spellings.
has_i=0
for url in \
  "https://github.com/kosako/x.git" \
  "git@github.com:kosako/x.git" \
  "ssh://git@github.com/kosako/x.git"; do
  has_i=$((has_i + 1))
  repo="$fixture/outside/has-$has_i"
  mkdir -p "$repo"
  run_git "$repo" init --quiet --initial-branch=main
  run_git "$repo" config remote.origin.url "$url"
  if output="$(run_git "$repo" commit --allow-empty -m test 2>&1)"; then
    author="$(run_git "$repo" log -1 --format='%ae')"
    if [[ "$author" == "dotfiles-test@example.invalid" ]]; then
      ok "test passed: outside-root repo with personal remote resolves personal identity ($url)"
    else
      fail "test failed: outside-root repo resolved unexpected author: $author ($url)"
      status=1
    fi
  else
    printf '%s\n' "$output" >&2
    fail "test failed: commit failed for outside-root personal remote ($url)"
    status=1
  fi
done

# A non-personal remote outside ~/src/ must NOT match: the hasconfig patterns
# are exact to github.com/kosako, never a catch-all (fail-closed).
repo="$fixture/outside/has-other"
mkdir -p "$repo"
run_git "$repo" init --quiet --initial-branch=main
run_git "$repo" config remote.origin.url "https://github.com/someorg/x.git"
if output="$(run_git "$repo" commit --allow-empty -m test 2>&1)"; then
  printf '%s\n' "$output" >&2
  fail "test failed: non-personal remote outside roots resolved an identity"
  status=1
elif grep -Eqi 'no (email|name) was given|user\.useConfigOnly' <<< "$output"; then
  ok "test passed: non-personal remote outside roots stays fail-closed"
else
  printf '%s\n' "$output" >&2
  fail "test failed: non-personal remote failed for another reason"
  status=1
fi

# Placement stays authoritative: a repo IN ~/src/work/ keeps the work identity
# even when its remote is a personal (github.com/kosako) URL, because the
# gitdir rule is listed after the hasconfig rules and wins when both match.
repo="$fixture/src/work/demo"
run_git "$repo" init --quiet --initial-branch=main
run_git "$repo" config remote.origin.url "https://github.com/kosako/x.git"
if output="$(run_git "$repo" commit --allow-empty -m test 2>&1)"; then
  author="$(run_git "$repo" log -1 --format='%ae')"
  if [[ "$author" == "dotfiles-work@example.invalid" ]]; then
    ok "test passed: gitdir placement overrides remote (work dir + personal remote -> work)"
  else
    fail "test failed: placement did not override remote; author: $author"
    status=1
  fi
else
  printf '%s\n' "$output" >&2
  fail "test failed: commit failed in work context with personal remote"
  status=1
fi

section "fixture checks: remote URL credentials"

# Write remote URLs via `git config` so the check never depends on
# transport behavior. Values stay inside the fixture.
run_git "$fixture/src/personal/demo" config remote.origin.url "https://invalid.example/repo.git"
run_git "$fixture/src/personal/demo" config remote.upstream.url "https://user@invalid.example/repo.git"

flagged="$(git_remotes_with_credentials "$fixture/src/personal/demo")"
if [[ -z "$flagged" ]]; then
  ok "test passed: clean and username-only remotes are not flagged"
else
  fail "test failed: unexpected flagged remotes: $flagged"
  status=1
fi

mkdir -p "$fixture/src/personal/remote-demo"
run_git "$fixture/src/personal/remote-demo" init --quiet --initial-branch=main
run_git "$fixture/src/personal/remote-demo" config remote.origin.url "https://user:secret-placeholder@invalid.example/repo.git"

flagged="$(git_remotes_with_credentials "$fixture/src/personal/remote-demo")"
if [[ "$flagged" == "origin" ]]; then
  ok "test passed: credential-like remote URL detected"
else
  fail "test failed: expected flagged remote 'origin', got: ${flagged:-<none>}"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  ok "gitconfig tests passed"
fi
exit "$status"
