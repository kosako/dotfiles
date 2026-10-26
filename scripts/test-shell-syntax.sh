#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

require_yq
command -v zsh >/dev/null || { fail "zsh is required for syntax gate tests"; exit 1; }

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-shell-syntax.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts"

# Exercise the actual CI commands: multiple operands to shell -n parse only
# the first file, and a valid final file must not hide an earlier failure.
# The bash32 job keeps its own copy of the bash check (the only place the
# 3.2 parser reads every script), so it is pinned the same way.
workflow="$DOTFILES_ROOT/.github/workflows/validate.yml"
for gate in bash zsh bash32; do
  case "$gate" in
    bash)
      job=validate
      step="bash syntax check"
      files=(scripts/a.sh scripts/b.sh scripts/c.sh)
      ;;
    zsh)
      job=validate
      step="zsh syntax check (managed shell files)"
      files=(dot_zshenv dot_zshrc dot_zprofile)
      ;;
    bash32)
      job=bash32
      step="bash syntax check (bash 3.2)"
      files=(scripts/a.sh scripts/b.sh scripts/c.sh)
      ;;
  esac
  check="$(JOB="$job" STEP="$step" yq -r '.jobs[strenv(JOB)].steps[] | select(.name == strenv(STEP)) | .run' "$workflow")"
  [[ -n "$check" && "$check" != "null" ]] || { fail "missing CI syntax step: $job / $step"; exit 1; }
  for file in "${files[@]}"; do
    printf ':\n' > "$fixture/$file"
  done
  if ! (cd "$fixture" && bash -e -c "$check"); then
    fail "$gate syntax gate rejected valid files"
    exit 1
  fi
  for file in "${files[@]}"; do
    printf 'if then\n' > "$fixture/$file"
    if (cd "$fixture" && bash -e -c "$check") >/dev/null 2>&1; then
      fail "$gate syntax gate missed invalid $file"
      exit 1
    fi
    printf ':\n' > "$fixture/$file"
    ok "$gate syntax gate rejects invalid $file"
  done
done

# CI wiring: the suite list is kept by hand in the validate and render jobs'
# steps, the bash32 job's matrix, docs/github-workflow.md and scripts/. A
# suite left out of the bash32 matrix silently loses its /bin/bash 3.2 run
# (the contract in scripts/README.md), so the lists must stay equal. Per job,
# not as one union: test-npmrc runs in both jobs (and in both bash32
# groups), and dropping it from one of them must still show.
wiring="$fixture/wiring"
mkdir -p "$wiring"
wiring_failed=0

# suites_of_job JOB — the ./scripts/test-*.sh the job's run steps call.
suites_of_job() {
  J="$1" yq -r '.jobs[strenv(J)].steps[].run // ""' "$workflow" \
    | { grep -oE '\./scripts/test-[a-z0-9-]+\.sh' || true; } \
    | sed 's|^\./scripts/||' | LC_ALL=C sort -u
}

# suites_of_bash32 render|others — the suites of the bash32 render group, or
# of every other group.
suites_of_bash32() {
  G="$1" yq -r '.jobs.bash32.strategy.matrix.include[]
      | select((.group == "render") == (strenv(G) == "render")) | .suites' "$workflow" \
    | tr ' ' '\n' | { grep -v '^$' || true; } | LC_ALL=C sort -u
}

# same_list NAME A B — the sorted lists in files A and B must be equal and
# not empty: a renamed job, group or heading must not compare two empty
# lists as equal.
same_list() {
  local name="$1" a="$2" b="$3"
  if [[ ! -s "$a" || ! -s "$b" ]]; then
    fail "CI wiring: $name: a list is empty (a job, group or heading renamed?)"
    wiring_failed=1
  elif ! diff "$a" "$b" > "$wiring/diff"; then
    fail "CI wiring: $name differ (< the first, > the second):"
    cat "$wiring/diff" >&2
    wiring_failed=1
  else
    ok "CI wiring: $name match"
  fi
}

suites_of_job validate > "$wiring/validate"
suites_of_job render > "$wiring/render"
suites_of_bash32 others > "$wiring/bash32-others"
suites_of_bash32 render > "$wiring/bash32-render"
LC_ALL=C sort -u "$wiring/validate" "$wiring/render" > "$wiring/ci"
# Only the first ```sh block after the heading is the list: a later block of
# per-change commands repeats test-gitconfig.sh.
awk '$0 == "## 最低限の validation" { s = 1; next } s && $0 == "```sh" { b = 1; next } b && $0 == "```" { exit } b' \
  "$DOTFILES_ROOT/docs/github-workflow.md" \
  | { grep -oE '^\./scripts/test-[a-z0-9-]+\.sh$' || true; } \
  | sed 's|^\./scripts/||' | LC_ALL=C sort -u > "$wiring/docs"
# test-lib.sh is source-only; test-inventory.sh runs inside
# test-install-packages.sh (checked below).
for suite in "$DOTFILES_ROOT"/scripts/test-*.sh; do
  suite="${suite##*/}"
  case "$suite" in
    test-lib.sh | test-inventory.sh) ;;
    *) printf '%s\n' "$suite" ;;
  esac
done | LC_ALL=C sort -u > "$wiring/files"

same_list "validate job and bash32 groups other than render" "$wiring/validate" "$wiring/bash32-others"
same_list "render job and bash32 render group" "$wiring/render" "$wiring/bash32-render"
same_list "CI jobs and docs/github-workflow.md" "$wiring/ci" "$wiring/docs"
same_list "CI jobs and scripts/test-*.sh" "$wiring/ci" "$wiring/files"

# test-doctor runs in bash32 as its parts (TEST_DOCTOR_PART, #456): every
# part from 1 to doctor_parts exactly once.
doctor_parts="$(sed -n 's/^doctor_parts=\([0-9][0-9]*\)$/\1/p' "$DOTFILES_ROOT/scripts/test-doctor.sh")"
want_parts=""
if [[ -n "$doctor_parts" ]]; then
  for ((part = 1; part <= doctor_parts; part++)); do
    want_parts+="$part "
  done
fi
got_parts="$(yq -r '.jobs.bash32.strategy.matrix.include[] | select(.suites == "test-doctor.sh") | .part' "$workflow" \
  | LC_ALL=C sort -n | tr '\n' ' ')"
if [[ -n "$want_parts" && "$got_parts" == "$want_parts" ]]; then
  ok "CI wiring: bash32 runs test-doctor parts ${want_parts% }"
else
  fail "CI wiring: bash32 runs test-doctor parts '${got_parts% }', want '${want_parts% }' (doctor_parts=${doctor_parts:-<none>})"
  wiring_failed=1
fi

# A bash32 step gated on one group (`if: matrix.group == '<group>'`) runs in
# no group once that group is renamed, and the compares above only tell the
# render group from the others: the bash 3.2 parse of every script and
# validate-policy run in the others group alone. Every group a step names
# must be in the matrix.
yq -r '.jobs.bash32.steps[].if // ""' "$workflow" \
  | { grep -oE "matrix\.group == '[a-z0-9-]+'" || true; } \
  | sed "s/^matrix\.group == '\(.*\)'\$/\1/" | LC_ALL=C sort -u > "$wiring/step-groups"
yq -r '.jobs.bash32.strategy.matrix.include[].group' "$workflow" | LC_ALL=C sort -u > "$wiring/groups"
unknown_groups="$(LC_ALL=C comm -23 "$wiring/step-groups" "$wiring/groups" | tr '\n' ' ')"
if [[ ! -s "$wiring/step-groups" || ! -s "$wiring/groups" ]]; then
  fail "CI wiring: no bash32 step is gated on a matrix group, or the matrix has no group (renamed?)"
  wiring_failed=1
elif [[ -n "$unknown_groups" ]]; then
  fail "CI wiring: bash32 steps are gated on groups the matrix does not have: ${unknown_groups% }"
  wiring_failed=1
else
  ok "CI wiring: every group a bash32 step is gated on is in the matrix"
fi

if grep -Fq '"$SCRIPT_DIR/test-inventory.sh"' "$DOTFILES_ROOT/scripts/test-install-packages.sh"; then
  ok "CI wiring: test-install-packages.sh runs test-inventory.sh"
else
  fail "CI wiring: test-install-packages.sh no longer runs test-inventory.sh; wire it into CI and the docs"
  wiring_failed=1
fi

if [[ "$wiring_failed" -ne 0 ]]; then
  exit 1
fi

ok "shell syntax gate tests passed"
