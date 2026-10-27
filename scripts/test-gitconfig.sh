#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

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

# The include ORDER is the contract (#202): includeIf is last-match-wins, so
# the three personal hasconfig rules come first, then the personal gitdir
# rule, then for EACH non-personal context the managed identity reset
# immediately followed by that context's local file, then the unconditional
# mechanism includes (signing, #196's git hook gates; a missing file is a
# silent no-op). A presence grep would also pass on a commented-out line and
# cannot catch a reordering or a reset that drifted away from its context, so
# the exact sequence is pinned: "<condition>|<path>" per include, in source
# order. This pin is the static check for every include line: header at
# column 0, uncommented path.
expected_include_order="$(printf '%s\n' \
  'hasconfig:remote.*.url:https://github.com/kosako/**|~/.config/git/personal.gitconfig' \
  'hasconfig:remote.*.url:git@github.com:kosako/**|~/.config/git/personal.gitconfig' \
  'hasconfig:remote.*.url:ssh://git@github.com/kosako/**|~/.config/git/personal.gitconfig' \
  'gitdir:~/src/personal/|~/.config/git/personal.gitconfig' \
  'gitdir:~/src/work/|~/.config/git-profile/identity-reset.gitconfig' \
  'gitdir:~/src/work/|~/.config/git/work.gitconfig' \
  'gitdir:~/src/client/|~/.config/git-profile/identity-reset.gitconfig' \
  'gitdir:~/src/client/|~/.config/git/client.gitconfig' \
  'gitdir:~/src/sandbox/|~/.config/git-profile/identity-reset.gitconfig' \
  'gitdir:~/src/sandbox/|~/.config/git/sandbox.gitconfig' \
  'gitdir:~/src/agent/|~/.config/git-profile/identity-reset.gitconfig' \
  'gitdir:~/src/agent/|~/.config/git/agent.gitconfig' \
  'include|~/.config/git/signing.gitconfig' \
  'include|~/.config/git-hook-gates/hooks.gitconfig')"
actual_include_order="$(awk '
  /^\[includeIf "/ { cond = $0; sub(/^\[includeIf "/, "", cond); sub(/"\]$/, "", cond); next }
  /^\[include\]/   { cond = "include"; next }
  /^\[/            { cond = "" }
  cond != "" && /^[[:space:]]*path[[:space:]]*=/ {
    p = $0; sub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*/, "", p); print cond "|" p; cond = ""
  }
' "$GITCONFIG_SOURCE")"
if [[ "$actual_include_order" == "$expected_include_order" ]]; then
  ok "test passed: include order pinned (hasconfig x3, personal, then reset+context per non-personal context, then mechanism includes)"
else
  fail "test failed: include order drifted from the pinned sequence"
  diff <(printf '%s\n' "$expected_include_order") <(printf '%s\n' "$actual_include_order") >&2 || true
  status=1
fi

# Commit/tag signing defaults off (unattended commits never block on the signer
# prompt); opt-in is per-repo/context. The managed file must carry the false
# default and must NEVER force signing on globally: a global `gpgsign = true`
# would break key-less contexts (work/client), the exact failure the design
# avoids.
# commit and tag both default off — assert section-aware so dropping either
# block fails (a plain `gpgsign = false` grep would still pass on just one).
for sect in commit tag; do
  if awk -v s="[$sect]" '
      $0 == s { ins = 1; next }
      /^\[/   { ins = 0 }
      ins && /^[[:space:]]*gpgsign[[:space:]]*=[[:space:]]*false/ { found = 1 }
      END { exit !found }
    ' "$GITCONFIG_SOURCE"; then
    ok "test passed: $sect.gpgsign = false (section-aware)"
  else
    fail "test failed: [$sect] section missing gpgsign = false"
    status=1
  fi
done
if grep -Eq '^[[:space:]]*gpgsign[[:space:]]*=[[:space:]]*true' "$GITCONFIG_SOURCE"; then
  fail "test failed: managed source must not force gpgsign = true (breaks key-less contexts)"
  status=1
else
  ok "test passed: managed source never forces signing on"
fi

# Public-safety: the ONLY hasconfig rules allowed are the three public personal
# patterns pinned in the include order above; work/client must never have one
# (their org URLs are confidential). Match against the exact allowlist (not a
# loose "contains kosako", which would also accept e.g. github.com/work-kosako):
# any other hasconfig line, commented or not, is a confidential org leaking
# into this public file.
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

# Keep both direct Git calls and the library probe in this same environment.
run_fixture() {
  fixture_git_env "$fixture" "$GITCONFIG_SOURCE" -- "$@"
}

run_git() {
  local repo="$1"
  shift
  run_fixture git -C "$repo" "$@"
}

fixture_remotes_with_credentials() {
  run_fixture bash -c 'source "$1"; git_remotes_with_credentials "$2"' \
    fixture-remotes "$SCRIPT_DIR/lib-policy.sh" "$1"
}

mkdir -p "$fixture/src/personal/demo" "$fixture/outside/demo" "$fixture/.config/git"

cat > "$fixture/.config/git/personal.gitconfig" <<'EOF'
[user]
	name = Dotfiles Test
	email = dotfiles-test@example.invalid
EOF

# The #389 self-check (test-lib.sh) of run_git, so of run_fixture: under a
# hook's inherited Git environment the fixture calls stay in the fixture.
# test-git-hook-gates.sh runs it on its own run_git; each guards its wrapper.
check_git_env_isolation run_git "$fixture" || status=1

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

# Git prints the same "uses plaintext credentials" message for warn and die
# (#413): with warn it goes on to connect and fails for another reason, so a
# non-zero exit plus that text cannot tell them apart. Only die stops with a
# fatal: line before connecting, so that line is the pass condition. The warn
# control shows that the condition rejects warn. Both point at a closed
# localhost port: a regression to warn then fails fast, with no name lookup
# and nothing sent off the machine.
credential_url="http://user:secret-placeholder@127.0.0.1:1/repo.git"
if output="$(run_git "$fixture/src/personal/demo" ls-remote "$credential_url" 2>&1)"; then
  fail "test failed: credential URL was not rejected"
  status=1
elif grep -Eq '^fatal: .*plaintext credentials' <<< "$output"; then
  ok "test passed: credential URL rejected before connecting (fatal, die)"
else
  printf '%s\n' "$output" >&2
  fail "test failed: credential URL was not refused with a fatal: plaintext-credentials line"
  status=1
fi
output="$(run_git "$fixture/src/personal/demo" -c transfer.credentialsInUrl=warn \
  ls-remote "$credential_url" 2>&1 || true)"
if grep -Eq '^fatal: .*plaintext credentials' <<< "$output"; then
  fail "test failed: transfer.credentialsInUrl=warn also printed the fatal line, so the check above cannot tell warn from die"
  status=1
elif grep -q 'plaintext credentials' <<< "$output"; then
  ok "test passed: control: warn prints the same message without the fatal line"
else
  printf '%s\n' "$output" >&2
  fail "test failed: control: warn did not print the plaintext-credentials warning"
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
# This runs before the identity reset is copied into the fixture HOME (#202
# section below), the state of a home with ~/.gitconfig but no reset file
# (Git skips a missing include), which the reset matrix does not cover.
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

flagged="$(fixture_remotes_with_credentials "$fixture/src/personal/demo")"
if [[ -z "$flagged" ]]; then
  ok "test passed: clean and username-only remotes are not flagged"
else
  fail "test failed: unexpected flagged remotes: $flagged"
  status=1
fi

mkdir -p "$fixture/src/personal/remote-demo"
run_git "$fixture/src/personal/remote-demo" init --quiet --initial-branch=main
run_git "$fixture/src/personal/remote-demo" config remote.origin.url "https://user:secret-placeholder@invalid.example/repo.git"

flagged="$(fixture_remotes_with_credentials "$fixture/src/personal/remote-demo")"
if [[ "$flagged" == "origin" ]]; then
  ok "test passed: credential-like remote URL detected"
else
  fail "test failed: expected flagged remote 'origin', got: ${flagged:-<none>}"
  status=1
fi

# A credential hiding in pushurl with a clean fetch url must be flagged too
# (#144: the scan matched only remote.*.url and pushurl slipped through).
mkdir -p "$fixture/src/personal/pushurl-demo"
run_git "$fixture/src/personal/pushurl-demo" init --quiet --initial-branch=main
run_git "$fixture/src/personal/pushurl-demo" config remote.origin.url "https://invalid.example/repo.git"
run_git "$fixture/src/personal/pushurl-demo" config remote.origin.pushurl "https://user:secret-placeholder@invalid.example/repo.git"

flagged="$(fixture_remotes_with_credentials "$fixture/src/personal/pushurl-demo")"
if [[ "$flagged" == "origin" ]]; then
  ok "test passed: credential-like pushurl detected (clean fetch url)"
else
  fail "test failed: expected flagged remote 'origin' via pushurl, got: ${flagged:-<none>}"
  status=1
fi

# Both url and pushurl carrying credentials still report the remote once.
run_git "$fixture/src/personal/pushurl-demo" config remote.origin.url "https://user:secret-placeholder@invalid.example/repo.git"

flagged="$(fixture_remotes_with_credentials "$fixture/src/personal/pushurl-demo")"
if [[ "$flagged" == "origin" ]]; then
  ok "test passed: url+pushurl credentials report the remote once"
else
  fail "test failed: expected single 'origin', got: ${flagged:-<none>}"
  status=1
fi

# A URL kept only in a file the repo config includes is read too (#401):
# `git config --local` leaves include.path off unless --includes is given.
# The relative include path resolves next to .git/config.
include_repo="$fixture/src/personal/include-demo"
mkdir -p "$include_repo"
run_git "$include_repo" init --quiet --initial-branch=main
run_fixture git config --file "$include_repo/.git/remotes.inc" \
  remote.origin.url "https://user:secret-placeholder@invalid.example/repo.git"
run_git "$include_repo" config include.path remotes.inc

flagged="$(fixture_remotes_with_credentials "$include_repo")"
if [[ "$flagged" == "origin" ]]; then
  ok "test passed: credential-like remote URL in an included file detected"
else
  fail "test failed: expected flagged remote 'origin' from the included file, got: ${flagged:-<none>}"
  status=1
fi

section "fixture checks: identity reset per non-personal context (#202)"

# The managed reset file has to exist in the fixture HOME: GIT_CONFIG_GLOBAL is
# the source ~/.gitconfig, but its include paths resolve under HOME=$fixture.
mkdir -p "$fixture/.config/git-profile"
cp "$DOTFILES_ROOT/private_dot_config/git-profile/identity-reset.gitconfig" \
  "$fixture/.config/git-profile/identity-reset.gitconfig"

# write_identity FILE STATE CTX — put the context identity file into one of
# the states the reset has to handle: absent, empty (0 bytes), name-only,
# email-only, complete.
write_identity() {
  local file="$1" state="$2" ctx="$3"
  case "$state" in
    absent) rm -f "$file" ;;
    empty) : > "$file" ;;
    name-only) printf '[user]\n\tname = Dotfiles %s Test\n' "$ctx" > "$file" ;;
    email-only) printf '[user]\n\temail = dotfiles-%s@example.invalid\n' "$ctx" > "$file" ;;
    complete) printf '[user]\n\tname = Dotfiles %s Test\n\temail = dotfiles-%s@example.invalid\n' "$ctx" "$ctx" > "$file" ;;
  esac
}

# expect_ident REPO EXPECT LABEL — EXPECT is `refused` (the commit must fail on
# the empty / unresolved ident), or `NAME|EMAIL` that BOTH author and committer
# of the real commit object must carry (EMAIL may be empty: the visibly broken
# name-only case). In every outcome the personal test identity must be absent
# from the result — that inheritance is the bug. Prints only on failure.
expect_ident() {
  local repo="$1" expect="$2" label="$3" output ident
  if output="$(run_git "$repo" commit --allow-empty -m test 2>&1)"; then
    ident="$(run_git "$repo" log -1 --format='%an|%ae|%cn|%ce')"
    if [[ "$expect" == refused ]]; then
      fail "test failed: $label: commit succeeded ($ident), expected refusal"
      return 1
    fi
    if [[ "$ident" != "$expect|$expect" ]]; then
      fail "test failed: $label: author|committer = $ident, expected $expect|$expect"
      return 1
    fi
    # Belt and braces for the non-personal contexts: even a matching-looking
    # result must not carry the personal test identity anywhere.
    if [[ "$expect" != "Dotfiles Test|dotfiles-test@example.invalid" ]] \
      && [[ "$ident" == *dotfiles-test@example.invalid* || "$ident" == *"Dotfiles Test"* ]]; then
      fail "test failed: $label: personal identity leaked into the commit ($ident)"
      return 1
    fi
    return 0
  fi
  if [[ "$expect" != refused ]]; then
    printf '%s\n' "$output" >&2
    fail "test failed: $label: commit refused, expected $expect"
    return 1
  fi
  if grep -Eqi 'empty ident name|no (email|name) was given|user\.useConfigOnly' <<< "$output"; then
    return 0
  fi
  printf '%s\n' "$output" >&2
  fail "test failed: $label: commit failed for another reason"
  return 1
}

# Matrix: context x identity-file state x remote shape. The remotes are the
# three public personal URL spellings (each one is a hasconfig hit) plus a
# multi-remote repo whose origin is foreign and whose upstream is personal
# (hasconfig fires on ANY remote, not just origin). Expected: absent / empty /
# email-only -> refused (blank name); name-only -> the context name with an
# EMPTY email (Git accepts it; visibly broken, never personal); complete ->
# the context identity. One report line per context x state.
personal_remotes=(
  "https://github.com/kosako/x.git"
  "git@github.com:kosako/x.git"
  "ssh://git@github.com/kosako/x.git"
)
for ctx in work client sandbox agent; do
  for state in absent empty name-only email-only complete; do
    write_identity "$fixture/.config/git/$ctx.gitconfig" "$state" "$ctx"
    case "$state" in
      absent|empty|email-only) expect=refused; expect_desc="commit refused (blank name)" ;;
      name-only) expect="Dotfiles $ctx Test|"; expect_desc="context name with an EMPTY email (visibly broken, not personal)" ;;
      complete) expect="Dotfiles $ctx Test|dotfiles-$ctx@example.invalid"; expect_desc="the $ctx identity" ;;
    esac
    matrix_ok=1
    remote_i=0
    for remote in "${personal_remotes[@]}" multi; do
      remote_i=$((remote_i + 1))
      repo="$fixture/src/$ctx/reset-$state-$remote_i"
      mkdir -p "$repo"
      run_git "$repo" init --quiet --initial-branch=main
      if [[ "$remote" == multi ]]; then
        run_git "$repo" config remote.origin.url "https://github.com/someorg/x.git"
        run_git "$repo" config remote.upstream.url "https://github.com/kosako/x.git"
      else
        run_git "$repo" config remote.origin.url "$remote"
      fi
      expect_ident "$repo" "$expect" "$ctx / $state / $remote" || matrix_ok=0
    done
    if [[ "$matrix_ok" -eq 1 ]]; then
      ok "test passed: $ctx dir + personal remote (3 spellings + multi-remote) with $state identity file -> $expect_desc"
    else
      status=1
    fi
  done
done

# Signing (#399): personal.gitconfig may opt into signing (docs/git-identity.md
# lets a context's local file hold user.signingkey and commit.gpgsign = true).
# A non-personal dir whose remote is personal reads it through the hasconfig
# fallback, so the reset must put signing back to the defaults (no key,
# commit / tag gpgsign false) and the commit must go through unsigned. A
# context that opts in in its own file still wins, and a repo in the personal
# dir keeps the personal opt-in (controls).
cp "$fixture/.config/git/personal.gitconfig" "$fixture/personal-before-signing.gitconfig"
printf '[user]\n\tsigningkey = dotfiles-personal-signing-key\n[commit]\n\tgpgsign = true\n[tag]\n\tgpgsign = true\n' \
  >> "$fixture/.config/git/personal.gitconfig"
write_identity "$fixture/.config/git/work.gitconfig" complete work
# signing_state REPO -> "KEY|COMMIT_GPGSIGN|TAG_GPGSIGN" as Git resolves them.
signing_state() {
  local key commit_sign tag_sign
  key="$(run_git "$1" config --get user.signingkey || true)"
  commit_sign="$(run_git "$1" config --get commit.gpgsign || true)"
  tag_sign="$(run_git "$1" config --get tag.gpgsign || true)"
  printf '%s|%s|%s\n' "$key" "$commit_sign" "$tag_sign"
}
sign_work="$fixture/src/work/signing-reset"
sign_personal="$fixture/src/personal/signing-control"
mkdir -p "$sign_work" "$sign_personal"
run_git "$sign_work" init --quiet --initial-branch=main
run_git "$sign_work" config remote.origin.url "https://github.com/kosako/x.git"
run_git "$sign_personal" init --quiet --initial-branch=main
if [[ "$(signing_state "$sign_work")" == "|false|false" ]] \
  && expect_ident "$sign_work" "Dotfiles work Test|dotfiles-work@example.invalid" "work / personal remote / personal signing opt-in"; then
  ok "test passed: work dir + personal remote does not inherit the personal signing key or opt-in (commit goes through unsigned)"
else
  fail "test failed: work dir + personal remote inherited personal signing ($(signing_state "$sign_work"))"
  status=1
fi
printf '[user]\n\tsigningkey = dotfiles-work-signing-key\n[commit]\n\tgpgsign = true\n' >> "$fixture/.config/git/work.gitconfig"
if [[ "$(signing_state "$sign_work")" == "dotfiles-work-signing-key|true|false" ]]; then
  ok "test passed: a context that opts into signing in its own file still wins over the reset"
else
  fail "test failed: the work context's own signing opt-in must win over the reset (got $(signing_state "$sign_work"))"
  status=1
fi
if [[ "$(signing_state "$sign_personal")" == "dotfiles-personal-signing-key|true|true" ]]; then
  ok "test passed: the personal dir keeps the personal signing opt-in (the reset is for non-personal contexts only)"
else
  fail "test failed: the personal dir must keep the personal signing opt-in (got $(signing_state "$sign_personal"))"
  status=1
fi
cp "$fixture/personal-before-signing.gitconfig" "$fixture/.config/git/personal.gitconfig"
write_identity "$fixture/.config/git/work.gitconfig" complete work

# Outside ~/src/ the reset never applies (it is gitdir-keyed), so the personal
# fallback still resolves for a personal remote and a foreign remote stays
# fail-closed — asserted above in the hasconfig section; re-checked here after
# the matrix touched the context files, with the real commit object.
repo="$fixture/outside/after-reset"
mkdir -p "$repo"
run_git "$repo" init --quiet --initial-branch=main
run_git "$repo" config remote.origin.url "https://github.com/kosako/x.git"
if expect_ident "$repo" "Dotfiles Test|dotfiles-test@example.invalid" "outside / personal remote"; then
  ok "test passed: outside ~/src/ the personal remote fallback is untouched by the reset"
else
  status=1
fi

# Linked worktrees follow the .git directory of their MAIN repo: includeIf
# gitdir matches the resolved .git location, not the checkout path. Placement
# cannot re-context a worktree and neither can the reset — a personal repo's
# worktree under ~/src/work/ still commits as personal. Documented limitation
# (docs/git-identity.md), pinned so a change in Git or in the rules is noticed.
wt_main="$fixture/src/personal/wt-main"
mkdir -p "$wt_main"
run_git "$wt_main" init --quiet --initial-branch=main
run_git "$wt_main" commit --quiet --allow-empty -m base
run_git "$wt_main" worktree add --quiet "$fixture/src/work/wt-linked" -b linked
if expect_ident "$fixture/src/work/wt-linked" "Dotfiles Test|dotfiles-test@example.invalid" "linked worktree under work dir"; then
  ok "test passed: a linked worktree keeps its main repo's context (documented: placement and reset do not apply)"
else
  status=1
fi

# The static check above only sees dot_gitconfig; an include read after its
# [transfer] section could weaken the value (#413). Resolve it as Git does in
# every context, with the managed include files in place (the identity reset
# is already in the fixture HOME; the signing mechanism is copied here, at
# the end, so the cases above do not see it). The hook-gates include is a
# template, so its source is checked for the key instead, ignoring case like
# Git does for key names (Codex review R2, PR #417).
cp "$DOTFILES_ROOT/private_dot_config/git/signing.gitconfig" "$fixture/.config/git/signing.gitconfig"
for context_dir in src/personal src/work src/client src/sandbox src/agent outside; do
  repo="$fixture/$context_dir/credentials-in-url"
  mkdir -p "$repo"
  run_git "$repo" init --quiet --initial-branch=main
  value="$(run_git "$repo" config --get transfer.credentialsInUrl || true)"
  if [[ "$value" == die ]]; then
    ok "test passed: transfer.credentialsInUrl resolves to die in $context_dir"
  else
    fail "test failed: transfer.credentialsInUrl must resolve to die in $context_dir (got ${value:-<unset>})"
    status=1
  fi
done
if grep -qi 'credentialsInUrl' "$DOTFILES_ROOT/private_dot_config/git-hook-gates/hooks.gitconfig.tmpl"; then
  fail "test failed: the git-hook-gates include must not set transfer.credentialsInUrl"
  status=1
else
  ok "test passed: the git-hook-gates include does not set transfer.credentialsInUrl"
fi

if [[ "$status" -eq 0 ]]; then
  ok "gitconfig tests passed"
fi
exit "$status"
