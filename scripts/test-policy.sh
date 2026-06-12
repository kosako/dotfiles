#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

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

make_fixture() {
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-policy-test.XXXXXX")"
  tmp_roots+=("$fixture")
  mkdir -p "$fixture/.chezmoidata"
  cp -R "$DOTFILES_ROOT/scripts" "$fixture/scripts"
  cp "$DOTFILES_ROOT/.chezmoidata/"*.yaml "$fixture/.chezmoidata/"
}

insert_once() {
  local file="$1"
  local target="$2"
  local insert="$3"
  local tmp="$file.tmp"

  if ! awk -v target="$target" -v insert="$insert" '
    {
      print
      if ($0 == target && !done) {
        print insert
        done = 1
      }
    }
    END { if (!done) exit 1 }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    fail "insert_once: target line not found in $file: $target"
    return 1
  fi
  mv "$tmp" "$file"
}

replace_once() {
  local file="$1"
  local target="$2"
  local replacement="$3"
  local tmp="$file.tmp"

  if ! awk -v target="$target" -v replacement="$replacement" '
    $0 == target && !done {
      print replacement
      done = 1
      next
    }
    { print }
    END { if (!done) exit 1 }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    fail "replace_once: target line not found in $file: $target"
    return 1
  fi
  mv "$tmp" "$file"
}

run_ok() {
  local name="$1"
  shift
  local output

  if output="$("$@" 2>&1)"; then
    ok "test passed: $name"
  else
    printf '%s\n' "$output" >&2
    fail "test failed: $name"
    return 1
  fi
}

run_ok_contains() {
  local name="$1"
  local expected="$2"
  shift 2
  local output

  if ! output="$("$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "test failed: $name"
    return 1
  fi

  if grep -Fq "$expected" <<< "$output"; then
    ok "test passed: $name"
  else
    printf '%s\n' "$output" >&2
    fail "missing expected output for $name: $expected"
    return 1
  fi
}

run_fail_contains() {
  local name="$1"
  local expected="$2"
  shift 2
  local output

  if output="$("$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "test unexpectedly passed: $name"
    return 1
  fi

  if grep -Fq "$expected" <<< "$output"; then
    ok "test passed: $name"
  else
    printf '%s\n' "$output" >&2
    fail "missing expected failure for $name: $expected"
    return 1
  fi
}

fixture=""
make_fixture
run_ok "validates all profiles" "$fixture/scripts/validate-policy.sh" --all
run_ok_contains "lists profiles" "work-dev" "$fixture/scripts/validate-policy.sh" --list-profiles

make_fixture
replace_once "$fixture/.chezmoidata/profiles.yaml" "      corepackMode: report" "      corepackMode: off"
run_ok "accepts first enum capability value" "$fixture/scripts/validate-policy.sh" personal

make_fixture
run_fail_contains \
  "rejects unknown profile" \
  "unknown profile: unknown-profile" \
  "$fixture/scripts/validate-policy.sh" unknown-profile

make_fixture
insert_once "$fixture/.chezmoidata/profiles.yaml" "      - base" "      - missing-module"
run_fail_contains \
  "rejects unknown module" \
  "unknown module in personal: missing-module" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/profiles.yaml" "      installPackages: true" "      missingCapability: true"
run_fail_contains \
  "rejects unknown capability" \
  "unknown capability in personal: missingCapability" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
replace_once "$fixture/.chezmoidata/profiles.yaml" "      npmHardeningMode: enforce" "      npmHardeningMode: strict"
run_fail_contains \
  "rejects invalid enum capability" \
  "capability enum invalid: npmHardeningMode=strict" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
replace_once "$fixture/.chezmoidata/profiles.yaml" "      npmHardeningMode: enforce" "      npmHardeningMode: strict"
run_fail_contains \
  "all profiles rejects invalid enum capability" \
  "policy validation failed for profile: personal" \
  "$fixture/scripts/validate-policy.sh" --all

make_fixture
insert_once "$fixture/.chezmoidata/profiles.yaml" "      installPackages: true" "      bad-cap: true"
run_fail_contains \
  "rejects unknown kebab-case capability" \
  "unknown capability in personal: bad-cap" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/profiles.yaml" "      installPackages: true" "      installPackages: true"
run_fail_contains \
  "rejects duplicate capability" \
  "duplicate capability in personal: installPackages" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/modules.yaml" "      enableRuntimeManagement: true" "      notACapability: true"
run_fail_contains \
  "rejects unknown capability in module requires" \
  "unknown capability in runtime requires: notACapability" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
replace_once "$fixture/.chezmoidata/modules.yaml" "      npmHardeningMode: enforce" "      npmHardeningMode: strict"
run_fail_contains \
  "rejects invalid enum in module requires" \
  "module requires enum invalid: supply-chain/npm: npmHardeningMode=strict" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/modules.yaml" "      - .npmrc" "      - .gitconfig"
run_fail_contains \
  "rejects path declared by multiple modules" \
  "path declared by multiple modules: .gitconfig" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/modules.yaml" "    description: 全環境共通の最小設定。" "    requires:"
insert_once "$fixture/.chezmoidata/modules.yaml" "    requires:" "      enableDirenv: true"
run_fail_contains \
  "rejects module requires without paths" \
  "module has requires but no paths: base" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/profiles.yaml" "      enableAiPolicy: true" "    extraSection:"
insert_once "$fixture/.chezmoidata/profiles.yaml" "    extraSection:" "      sneakyKey: true"
run_ok \
  "ignores sections after capabilities" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
: > "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "fails closed on empty profiles for --list-profiles" \
  "no profiles parsed" \
  "$fixture/scripts/validate-policy.sh" --list-profiles

make_fixture
: > "$fixture/.chezmoidata/capabilities.schema.yaml"
run_fail_contains \
  "fails closed on empty capability schema" \
  "no capabilities parsed" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
run_fail_contains \
  "rejects single-dash option as usage error" \
  "unknown option: -x" \
  "$fixture/scripts/validate-policy.sh" -x

ok "policy tests passed"
