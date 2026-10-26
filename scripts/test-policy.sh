#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

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
  copy_repo_fixture "$fixture"
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
run_ok_contains "lists profiles" "work" "$fixture/scripts/validate-policy.sh" --list-profiles

# #329: validate-policy holds its lists in variables, so a run writes no temp
# file that a Ctrl-C could leave behind (bash 3.2 runs no EXIT trap then).
# A normal run used to clean its files up, so an empty TMPDIR alone proves
# nothing: a PATH-front mktemp leaves a marker and fails, and TMPDIR (an
# empty fixture dir) must stay empty too.
mkdir "$fixture/tmpdir" "$fixture/no-mktemp"
printf '#!/bin/sh\n: > "%s/mktemp-called"\nexit 1\n' "$fixture" > "$fixture/no-mktemp/mktemp"
chmod +x "$fixture/no-mktemp/mktemp"
run_ok "validates all profiles without mktemp" \
  env PATH="$fixture/no-mktemp:$PATH" TMPDIR="$fixture/tmpdir" "$fixture/scripts/validate-policy.sh" --all
if [[ -e "$fixture/mktemp-called" || -n "$(ls -A "$fixture/tmpdir")" ]]; then
  ls -A "$fixture/tmpdir" >&2
  fail "test failed: validate-policy --all called mktemp or left files in TMPDIR"
  exit 1
fi
ok "test passed: validate-policy --all writes no temp file"

make_fixture
replace_once "$fixture/.chezmoidata/profiles.yaml" "      corepackMode: report" "      corepackMode: off"
run_ok "accepts first enum capability value" "$fixture/scripts/validate-policy.sh" personal

make_fixture
run_fail_contains \
  "rejects unknown profile" \
  "unknown profile: unknown-profile" \
  "$fixture/scripts/validate-policy.sh" unknown-profile

# environmentKind は後段の cross-check を駆動するので、無い profile や表に無い kind は
# 「制約なし」として通さず fail closed にする。yq の del は key が無いと no-op になるが、
# その場合は validate が通って run_fail_contains が落ちるので、変異の検証は assertion
# 自身が担う (#151 の capability registry case と同じ論理)。
make_fixture
yq -i 'del(.profiles.personal.environmentKind)' "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects a profile without environmentKind" \
  "profile has no environmentKind: personal" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
replace_once "$fixture/.chezmoidata/profiles.yaml" "    environmentKind: personal" "    environmentKind: bogus"
run_fail_contains \
  "rejects unknown environmentKind" \
  "unknown environmentKind for personal: bogus" \
  "$fixture/scripts/validate-policy.sh" personal

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
insert_once "$fixture/.chezmoidata/profiles.yaml" "      - base" "      - base"
run_fail_contains \
  "rejects duplicate module" \
  "duplicate module in personal: base" \
  "$fixture/scripts/validate-policy.sh" personal

# schema が宣言する capability は全 profile が明示的に持つ。key の欠落は暗黙の既定値ではなく
# hard fail (del が no-op なら validate が通って test が落ちる)。
make_fixture
yq -i 'del(.profiles.personal.capabilities.enableDirenv)' "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects a profile missing a declared capability" \
  "missing capability in personal: enableDirenv" \
  "$fixture/scripts/validate-policy.sh" personal

# #391: the requires container is a map, not a boolean capability value.
# Pin exit 1 as well as the diagnostic, and test the runtime gate directly.
for invalid_requires in false true '"yes"' 42 '[]' '[true]'; do
  make_fixture
  V="$invalid_requires" yq -i '.modules.runtime.requires = env(V)' "$fixture/.chezmoidata/modules.yaml"
  requires_rc=0
  requires_output="$("$fixture/scripts/validate-policy.sh" personal 2>&1)" || requires_rc=$?
  if [[ "$requires_rc" -ne 1 ]] ||
    ! grep -Fq 'module requires must be a map or null: runtime' <<< "$requires_output"; then
    printf '%s\n' "$requires_output" >&2
    fail "test failed: requires=$invalid_requires must fail validation with exit 1 (got $requires_rc)"
    exit 1
  fi
  ok "test passed: rejects requires=$invalid_requires with exit 1 and module diagnostic"
  run_ok "requires=$invalid_requires cannot activate runtime" \
    env FIXTURE_LIB="$fixture/scripts/lib-policy.sh" bash -c '
      source "$FIXTURE_LIB"
      ! module_active_for_profile personal runtime
    '
done

for empty_requires in absent null '{}'; do
  make_fixture
  if [[ "$empty_requires" == absent ]]; then
    yq -i 'del(.modules.runtime.requires)' "$fixture/.chezmoidata/modules.yaml"
  else
    V="$empty_requires" yq -i '.modules.runtime.requires = env(V)' "$fixture/.chezmoidata/modules.yaml"
  fi
  run_ok_contains "accepts requires=$empty_requires" "module validation passed" \
    "$fixture/scripts/validate-policy.sh" personal
  run_ok "requires=$empty_requires keeps runtime active" \
    env FIXTURE_LIB="$fixture/scripts/lib-policy.sh" bash -c '
      source "$FIXTURE_LIB"
      module_active_for_profile personal runtime
    '
done

# A yq failure must propagate even when the container is a valid map and
# the failed enumeration prints a matching condition before exiting.
make_fixture
cat >> "$fixture/scripts/lib-policy.sh" <<'SH'
yq() {
  case "$*" in
    *'.modules[strenv(m)].requires'*'to_entries'*)
      printf 'enableRuntimeManagement true\n'
      return 1
      ;;
  esac
  command yq "$@"
}
SH
run_fail_contains "rejects failed requires enumeration with partial output" \
  "cannot enumerate module requires: runtime" "$fixture/scripts/validate-policy.sh" personal
run_ok "failed requires enumeration cannot activate runtime" \
  env FIXTURE_LIB="$fixture/scripts/lib-policy.sh" bash -c '
    source "$FIXTURE_LIB"
    ! module_active_for_profile personal runtime
  '

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
  "module requires enum invalid: supply-chain-npm: npmHardeningMode=strict" \
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

# Module paths become literal "!<path>" allowlist lines (#207): anything
# that would read as a pattern, or match nothing, must fail closed. The
# tilde is a deliberate literal (a home-relative path never starts with ~).
# shellcheck disable=SC2088
for bad_path in '.config/*.toml' '.config/mise/' "'!.zshrc'" '.config/my dir' '~/.zshrc'; do
  make_fixture
  insert_once "$fixture/.chezmoidata/modules.yaml" "      - .npmrc" "      - $bad_path"
  run_fail_contains \
    "rejects non-literal module path $bad_path" \
    "module path must be a literal path (no pattern characters, whitespace, or trailing slash): supply-chain-npm: " \
    "$fixture/scripts/validate-policy.sh" personal
done

# A module path must stay under the home (#207): an absolute path or a ".."
# would let its "!<path>" allowlist line admit a file outside the home or
# above the declared directory. The literal-path check above catches
# neither, so both pin the message, and the module check must fail as a
# whole.
make_fixture
yq -i '.modules["supply-chain-npm"].paths += ["/etc/passwd", ".config/../x"]' "$fixture/.chezmoidata/modules.yaml"
home_rc=0
home_output="$("$fixture/scripts/validate-policy.sh" personal 2>&1)" || home_rc=$?
home_missing=""
for home_want in \
  "module path must be home-relative: supply-chain-npm: /etc/passwd" \
  "module path must be home-relative: supply-chain-npm: .config/../x" \
  "module validation failed"; do
  grep -Fq -- "$home_want" <<< "$home_output" || home_missing="$home_missing [$home_want]"
done
if [[ "$home_rc" -eq 0 || -n "$home_missing" ]]; then
  printf '%s\n' "$home_output" >&2
  fail "test failed: rejects a module path that is not home-relative (exit $home_rc, missing:$home_missing)"
  exit 1
fi
ok "test passed: rejects a module path that is not home-relative"

# A capability type that is neither boolean nor enum (a typo in the schema)
# must fail closed, not skip the value check. git-signing requires
# enableGitSigning, so the module check and the profile check each read the
# type and each must fail on it.
make_fixture
yq -i '.capabilities.enableGitSigning.type = "bogus"' "$fixture/.chezmoidata/capabilities.schema.yaml"
type_rc=0
type_output="$("$fixture/scripts/validate-policy.sh" personal 2>&1)" || type_rc=$?
type_missing=""
for type_want in \
  "unknown capability type for enableGitSigning: bogus" \
  "module validation failed" \
  "policy validation failed for profile: personal"; do
  grep -Fq -- "$type_want" <<< "$type_output" || type_missing="$type_missing [$type_want]"
done
if [[ "$type_rc" -eq 0 || -n "$type_missing" ]]; then
  printf '%s\n' "$type_output" >&2
  fail "test failed: rejects an unknown capability type (exit $type_rc, missing:$type_missing)"
  exit 1
fi
ok "test passed: rejects an unknown capability type"

# A profile's modules: and a module's paths: must be absent / null or a list
# of strings (#412). The readers enumerate with `[]?`, so a scalar listed as
# nothing and a map listed its values; both passed before the shape check.
# claude-settings has no requires:, so "requires but no paths" cannot catch
# its paths.
for bad_list in '"base"' false 42 '{entry: base}' '[base, 1]' '[base, ~]'; do
  make_fixture
  V="$bad_list" yq -i '.profiles.personal.modules = env(V)' "$fixture/.chezmoidata/profiles.yaml"
  run_fail_contains \
    "rejects profile modules=$bad_list" \
    "profile modules must be a list of module names (non-empty strings without control characters): personal" \
    "$fixture/scripts/validate-policy.sh" personal
done
for bad_list in '".claude/settings.json"' true 7 '{p: .claude/settings.json}' '[.claude/settings.json, true]'; do
  make_fixture
  V="$bad_list" yq -i '.modules["claude-settings"].paths = env(V)' "$fixture/.chezmoidata/modules.yaml"
  run_fail_contains \
    "rejects module paths=$bad_list" \
    "module paths must be a list of paths (non-empty strings without control characters): claude-settings" \
    "$fixture/scripts/validate-policy.sh" personal
done
# An element must not hold a control character (#422): the listing prints one
# line per element, so a newline split one entry into two names that each
# passed, while .chezmoiignore matches the element itself (`has`) and enables
# neither. The joined element replaces two valid entries, so without the
# check the run passes; the tab case has no such twin and fails as unknown.
make_fixture
V=$'git-profile\nsupply-chain-git' yq -i '
  (.profiles.personal.modules[] | select(. == "git-profile")) = strenv(V) |
  del(.profiles.personal.modules[] | select(. == "supply-chain-git"))' \
  "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects a profile module name holding a newline" \
  "profile modules must be a list of module names (non-empty strings without control characters): personal" \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
V=$'base\tx' yq -i '(.profiles.personal.modules[] | select(. == "base")) = strenv(V)' \
  "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects a profile module name holding a tab" \
  "profile modules must be a list of module names (non-empty strings without control characters): personal" \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
V=$'.gitconfig\n.config/git-profile/identity-reset.gitconfig' yq -i '.modules["git-profile"].paths = [strenv(V)]' \
  "$fixture/.chezmoidata/modules.yaml"
run_fail_contains \
  "rejects a module path holding a newline" \
  "module paths must be a list of paths (non-empty strings without control characters): git-profile" \
  "$fixture/scripts/validate-policy.sh" personal
# A C1 control character (U+009B, CSI) passes ASCII's [[:cntrl:]] and the
# literal path check (Codex review, PR #425); the control is a non-ASCII
# name, which the shape check still takes (the names are checked later).
make_fixture
V='[".config/\u009bfile"]' yq -i '.modules["claude-settings"].paths = env(V)' "$fixture/.chezmoidata/modules.yaml"
run_fail_contains \
  "rejects a module path holding a C1 control character" \
  "module paths must be a list of paths (non-empty strings without control characters): claude-settings" \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
V='["ü-名前", "base"]' yq -n '.list = env(V)' > "$fixture/non-ascii.yaml"
run_ok "yaml_string_list takes non-ASCII strings (only control characters are refused)" \
  env FIXTURE_LIB="$fixture/scripts/lib-policy.sh" FIXTURE_YAML="$fixture/non-ascii.yaml" bash -c '
    source "$FIXTURE_LIB"
    yaml_string_list ".list" "$FIXTURE_YAML"
  '

# A failed read is reported, not taken as an empty list: of the shape, and of
# the listing after a valid shape. Each case fails only its own read, so the
# run cannot fail through another branch.
# fail_fixture_yq_on TEXT — the fixture's yq exits 1 with no output for the
# calls whose arguments contain TEXT (a literal without a single quote).
fail_fixture_yq_on() {
  printf "yq() {\n  case \"\$*\" in\n    *'%s'*) return 1 ;;\n  esac\n  command yq \"\$@\"\n}\n" "$1" \
    >> "$fixture/scripts/lib-policy.sh"
}
# expect_read_failure NAME TEXT MESSAGE — in a fresh fixture whose yq fails
# only on TEXT, validate-policy must exit non-zero with MESSAGE.
expect_read_failure() {
  make_fixture
  fail_fixture_yq_on "$2"
  run_fail_contains "rejects a failed read of the $1" "$3" "$fixture/scripts/validate-policy.sh" personal
}
expect_read_failure "profile modules shape" '.profiles[strenv(p)].modules | ' \
  "cannot read the modules of profile personal"
expect_read_failure "profile modules listing" '.profiles[strenv(p)].modules[]?' \
  "cannot read the modules of profile personal"
expect_read_failure "module paths shape" '.modules[strenv(m)].paths | ' \
  "cannot read the paths of module claude-settings"
expect_read_failure "module paths listing" '.modules[strenv(m)].paths[]?' \
  "cannot read the paths of module claude-settings"

# The keys of the profile, module and capability maps, the keys and values of
# a module's requires, and an enum's values are also listed one per line
# (#428). A newline in one of them read as two names or conditions, and each
# case below passed before the check (the joined name stands for names or
# values that exist); the C1 and tab cases have no such twin and failed for
# another reason, so they pin the message.
make_fixture
V='"enforce\ncorepackMode report"' yq -i '.modules["supply-chain-npm"].requires.npmHardeningMode = env(V)' \
  "$fixture/.chezmoidata/modules.yaml"
run_fail_contains \
  "rejects a module requires value holding a newline" \
  "module requires must map non-empty capability names to values without control characters: supply-chain-npm" \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
V='"enforce\u009b"' yq -i '.modules["supply-chain-npm"].requires.npmHardeningMode = env(V)' \
  "$fixture/.chezmoidata/modules.yaml"
run_fail_contains \
  "rejects a module requires value holding a C1 control character" \
  "module requires must map non-empty capability names to values without control characters: supply-chain-npm" \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
V='{"corepackMode report\nnpmHardeningMode": enforce}' yq -i '.modules["supply-chain-npm"].requires = env(V)' \
  "$fixture/.chezmoidata/modules.yaml"
run_fail_contains \
  "rejects a module requires key holding a newline" \
  "module requires must map non-empty capability names to values without control characters: supply-chain-npm" \
  "$fixture/scripts/validate-policy.sh" personal
# A map under values: listed its values as the allowed ones, the shape hole
# #412 closed for modules and paths.
for bad_values in '[off, "report\nenforce"]' '{a: off, b: report, c: enforce}' '[off, "report\tx", enforce]'; do
  make_fixture
  V="$bad_values" yq -i '.capabilities.npmHardeningMode.values = env(V)' \
    "$fixture/.chezmoidata/capabilities.schema.yaml"
  run_fail_contains \
    "rejects capability values=$bad_values" \
    "capability registry: npmHardeningMode values must be a list of non-empty strings without control characters" \
    "$fixture/scripts/validate-policy.sh" personal
done
make_fixture
yq -i '.modules["base\nzz-extra"] = .modules.base' "$fixture/.chezmoidata/modules.yaml"
run_fail_contains \
  "rejects a module name holding a newline" \
  "modules must be a map keyed by names (non-empty strings without control characters): " \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
yq -i '.capabilities["corepackMode\nnpmHardeningMode"] = .capabilities.corepackMode' \
  "$fixture/.chezmoidata/capabilities.schema.yaml"
run_fail_contains \
  "rejects a capability name holding a newline" \
  "capabilities must be a map keyed by names (non-empty strings without control characters): " \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
yq -i '.profiles["work\npersonal"] = .profiles.work' "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects a profile name holding a newline" \
  "profiles must be a map keyed by names (non-empty strings without control characters): " \
  "$fixture/scripts/validate-policy.sh" --all
run_fail_contains \
  "--list-profiles refuses a profile name holding a newline" \
  "profiles must be a map keyed by names (non-empty strings without control characters): " \
  "$fixture/scripts/validate-policy.sh" --list-profiles
make_fixture
V='"corepackMode\tzz"' yq -i '.profiles.personal.capabilities[env(V)] = "report"' "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects a profile capability name holding a tab" \
  "profile capabilities must be a map keyed by capability names (non-empty strings without control characters): personal" \
  "$fixture/scripts/validate-policy.sh" personal
# A profile value is read through a command substitution, which drops a
# trailing newline, so "enforce\n" passed as enforce (Codex review, PR #429).
for bad_value in '"enforce\n"' '"enforce\u009b"'; do
  make_fixture
  V="$bad_value" yq -i '.profiles.personal.capabilities.npmHardeningMode = env(V)' "$fixture/.chezmoidata/profiles.yaml"
  run_fail_contains \
    "rejects a profile capability value $bad_value" \
    "profile capability values must not hold control characters: personal" \
    "$fixture/scripts/validate-policy.sh" personal
done
make_fixture
yq -i '.profiles.personal.capabilities = ["installPackages"]' "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects profile capabilities that are a list" \
  "profile capabilities must be a map keyed by capability names (non-empty strings without control characters): personal" \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
V='{"ü-名前": "値", "base": true, "n": 1}' yq -n '.map = env(V)' > "$fixture/non-ascii-map.yaml"
run_ok "yaml_name_map and yaml_plain_string_values take non-ASCII keys and values" \
  env FIXTURE_LIB="$fixture/scripts/lib-policy.sh" FIXTURE_YAML="$fixture/non-ascii-map.yaml" bash -c '
    source "$FIXTURE_LIB"
    yaml_name_map ".map" "$FIXTURE_YAML" && yaml_plain_string_values ".map" "$FIXTURE_YAML"
  '
# A key that is not a string (a number, a boolean) lists as text that names
# nothing chezmoi reads by that name; the shape check refuses it with 1.
V='{1: a, true: b}' yq -n '.map = env(V)' > "$fixture/non-string-keys.yaml"
run_ok "yaml_name_map refuses keys that are not strings" \
  env FIXTURE_LIB="$fixture/scripts/lib-policy.sh" FIXTURE_YAML="$fixture/non-string-keys.yaml" bash -c '
    source "$FIXTURE_LIB"
    rc=0
    yaml_name_map ".map" "$FIXTURE_YAML" || rc=$?
    [[ "$rc" -eq 1 ]]
  '
expect_read_failure "module requires keys" '.modules[strenv(m)].requires | ((tag' \
  "cannot read the requires of module supply-chain-npm"
expect_read_failure "module requires values" '.modules[strenv(m)].requires | (([.[]' \
  "cannot read the requires of module supply-chain-npm"
expect_read_failure "capability values" '.capabilities[strenv(c)].values | ' \
  "cannot read the values of capability npmHardeningMode"
expect_read_failure "profile capabilities keys" '.profiles[strenv(p)].capabilities | ((tag' \
  "cannot read the capabilities of profile personal"
expect_read_failure "profile capability values" '.profiles[strenv(p)].capabilities | (([' \
  "cannot read the capability values of profile personal"
# The top-level reads are picked by the start of the expression: the
# profile-level reads of modules: and capabilities: hold the same text after
# a prefix, and failing them too would fail the run another way.
# expect_name_read_failure NAME MAP MESSAGE — the fixture yq fails only on an
# expression that starts with "MAP | ((".
expect_name_read_failure() {
  make_fixture
  printf "yq() {\n  case \"\$1\" in\n    '%s'*) return 1 ;;\n  esac\n  command yq \"\$@\"\n}\n" "$2 | ((" \
    >> "$fixture/scripts/lib-policy.sh"
  run_fail_contains "rejects a failed read of the $1" "$3" "$fixture/scripts/validate-policy.sh" personal
}
expect_name_read_failure "profile names" .profiles "cannot read the profiles in "
expect_name_read_failure "module names" .modules "cannot read the modules in "
expect_name_read_failure "capability names" .capabilities "cannot read the capabilities in "

# A requires line also splits at its first run of whitespace, and `read`
# drops what pads it, so each of these passed as npmHardeningMode=enforce
# while .chezmoiignore, comparing the key and the value themselves, left the
# module off (#430). The empty keys (Codex review, PR #432) now meet the
# name check first and are pinned with the other empty names below (#438).
for bad_requires in '{npmHardeningMode: "enforce "}' '{npmHardeningMode: " enforce"}' \
  '{"npmHardeningMode ": enforce}' '{" npmHardeningMode": enforce}' '{"npmHardeningMode enforce": ""}'; do
  make_fixture
  V="$bad_requires" yq -i '.modules["supply-chain-npm"].requires = env(V)' "$fixture/.chezmoidata/modules.yaml"
  run_fail_contains \
    "rejects module requires=$bad_requires" \
    "module requires must map non-empty capability names without whitespace to values without leading or trailing whitespace: supply-chain-npm" \
    "$fixture/scripts/validate-policy.sh" personal
done
# Whitespace inside a value survives the split; non-string values and an
# absent map have nothing to pad.
V='{a: "x y", b: true, c: 1}' yq -n '.map = env(V)' > "$fixture/inner-space-map.yaml"
run_ok "yaml_read_safe_entries takes inner whitespace, non-string values and an absent map" \
  env FIXTURE_LIB="$fixture/scripts/lib-policy.sh" FIXTURE_YAML="$fixture/inner-space-map.yaml" bash -c '
    source "$FIXTURE_LIB"
    yaml_read_safe_entries ".map" "$FIXTURE_YAML" && yaml_read_safe_entries ".absent" "$FIXTURE_YAML"
  '
expect_read_failure "module requires entries" '.modules[strenv(m)].requires | (([to_entries' \
  "cannot read the requires of module supply-chain-npm"

# An empty name, element or key lists as a blank line, which every loop skips
# like the blank line of an empty listing, so each case below passed (#438).
# A module named "" skipped its paths and requires checks while
# .chezmoiignore, matching the name itself with `has`, enabled it: with
# paths ["**"] every file of the repo became managed. Its non-empty twin
# fails on that path, so the empty name is what let it through. An empty path
# rendered a bare "!" line that chezmoi refuses; the empty profile,
# capability, profile capability and enum value checked nothing.
make_fixture
yq -i '.modules["zz"] = {"description": "x", "paths": ["**"]}' "$fixture/.chezmoidata/modules.yaml"
yq -i '.profiles.personal.modules += ["zz"]' "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects the non-empty twin of the empty module name on its path" \
  "module path must be a literal path (no pattern characters, whitespace, or trailing slash): zz: **" \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
yq -i '.modules[""] = {"description": "x", "paths": ["**"]}' "$fixture/.chezmoidata/modules.yaml"
yq -i '.profiles.personal.modules += [""]' "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects an empty module name" \
  "modules must be a map keyed by names (non-empty strings without control characters): " \
  "$fixture/scripts/validate-policy.sh" personal
for bad_paths in '[""]' '[.claude/settings.json, ""]'; do
  make_fixture
  V="$bad_paths" yq -i '.modules["claude-settings"].paths = env(V)' "$fixture/.chezmoidata/modules.yaml"
  run_fail_contains \
    "rejects module paths=$bad_paths" \
    "module paths must be a list of paths (non-empty strings without control characters): claude-settings" \
    "$fixture/scripts/validate-policy.sh" personal
done
make_fixture
yq -i '.profiles.personal.modules += [""]' "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects an empty profile module name" \
  "profile modules must be a list of module names (non-empty strings without control characters): personal" \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
yq -i '.profiles[""] = .profiles.personal' "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects an empty profile name" \
  "profiles must be a map keyed by names (non-empty strings without control characters): " \
  "$fixture/scripts/validate-policy.sh" --all
run_fail_contains \
  "--list-profiles refuses an empty profile name" \
  "profiles must be a map keyed by names (non-empty strings without control characters): " \
  "$fixture/scripts/validate-policy.sh" --list-profiles
make_fixture
yq -i '.capabilities[""] = .capabilities.enableDirenv' "$fixture/.chezmoidata/capabilities.schema.yaml"
run_fail_contains \
  "rejects an empty capability name" \
  "capabilities must be a map keyed by names (non-empty strings without control characters): " \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
yq -i '.profiles.personal.capabilities[""] = false' "$fixture/.chezmoidata/profiles.yaml"
run_fail_contains \
  "rejects an empty profile capability name" \
  "profile capabilities must be a map keyed by capability names (non-empty strings without control characters): personal" \
  "$fixture/scripts/validate-policy.sh" personal
make_fixture
yq -i '.capabilities.npmHardeningMode.values += [""]' "$fixture/.chezmoidata/capabilities.schema.yaml"
run_fail_contains \
  "rejects an empty capability value" \
  "capability registry: npmHardeningMode values must be a list of non-empty strings without control characters" \
  "$fixture/scripts/validate-policy.sh" personal
for bad_requires in '{"": "npmHardeningMode enforce"}' '{"": ""}'; do
  make_fixture
  V="$bad_requires" yq -i '.modules["supply-chain-npm"].requires = env(V)' "$fixture/.chezmoidata/modules.yaml"
  run_fail_contains \
    "rejects module requires=$bad_requires" \
    "module requires must map non-empty capability names to values without control characters: supply-chain-npm" \
    "$fixture/scripts/validate-policy.sh" personal
done
# yaml_read_safe_entries keeps refusing the empty key on its own, now that
# validate-policy meets it in yaml_name_map first.
V='{"": x}' yq -n '.map = env(V)' > "$fixture/empty-key-map.yaml"
run_ok "yaml_read_safe_entries refuses an empty key on its own" \
  env FIXTURE_LIB="$fixture/scripts/lib-policy.sh" FIXTURE_YAML="$fixture/empty-key-map.yaml" bash -c '
    source "$FIXTURE_LIB"
    rc=0
    yaml_read_safe_entries ".map" "$FIXTURE_YAML" || rc=$?
    [[ "$rc" -eq 1 ]]
  '

# Require both the YAML boolean type and canonical lowercase spelling (#206).
# Quoted "false" is truthy in templates; uppercase booleans bypass lowercase
# comparisons in registry disclosure and environmentKind checks.
for invalid_bool in '"true"' '"false"' 0 null '[]' '{}' True TRUE False FALSE; do
  make_fixture
  V="$invalid_bool" yq -i '.profiles.personal.capabilities.enableQualityLoopHooks = env(V)' \
    "$fixture/.chezmoidata/profiles.yaml"
  run_fail_contains \
    "rejects profile boolean with YAML value $invalid_bool" \
    "capability must be boolean: enableQualityLoopHooks=" \
    "$fixture/scripts/validate-policy.sh" personal

  make_fixture
  V="$invalid_bool" yq -i '.modules.runtime.requires.enableRuntimeManagement = env(V)' \
    "$fixture/.chezmoidata/modules.yaml"
  run_fail_contains \
    "rejects module requirement with YAML value $invalid_bool" \
    "module requires must be boolean: runtime: enableRuntimeManagement=" \
    "$fixture/scripts/validate-policy.sh" personal

  make_fixture
  V="$invalid_bool" yq -i '.capabilities.enableQualityLoopHooks.implemented = env(V)' \
    "$fixture/.chezmoidata/capabilities.schema.yaml"
  run_fail_contains \
    "rejects registry implemented with YAML value $invalid_bool" \
    "enableQualityLoopHooks lacks implemented: true|false" \
    "$fixture/scripts/validate-policy.sh" personal

  make_fixture
  V="$invalid_bool" yq -i '
    .profiles.personal.capabilities.installPackages = env(V) |
    .profiles.personal.capabilities.installGuiApps = env(V) |
    .profiles.personal.capabilities.allowSecretsAccess = env(V)' \
    "$fixture/.chezmoidata/profiles.yaml"
  run_ok "runtime gates refuse YAML value $invalid_bool without prior validation" \
    env FIXTURE_LIB="$fixture/scripts/lib-policy.sh" bash -c '
      source "$FIXTURE_LIB"
      for source in brew_formula npm_global go_install brew_cask mas; do
        if profile_installs_source personal "$source"; then
          fail "invalid boolean granted $source install"; exit 1
        fi
      done
      if profile_allows_secrets_access personal; then
        fail "invalid boolean granted secret access"; exit 1
      fi
    '
done

for invalid_true in True TRUE; do
  make_fixture
  V="$invalid_true" yq -i '.profiles.work.capabilities.enableAiTools = env(V)' \
    "$fixture/.chezmoidata/profiles.yaml"
  run_fail_contains \
    "uppercase $invalid_true cannot bypass work environmentKind restrictions" \
    "capability must be boolean: enableAiTools=$invalid_true" \
    "$fixture/scripts/validate-policy.sh" work
done

make_fixture
run_ok "runtime gates grant boolean true and refuse boolean false" \
  env FIXTURE_LIB="$fixture/scripts/lib-policy.sh" bash -c '
    source "$FIXTURE_LIB"
    for source in brew_formula npm_global go_install brew_cask mas; do
      profile_installs_source personal "$source" || exit 1
      if profile_installs_source work "$source"; then exit 1; fi
    done
    profile_allows_secrets_access personal || exit 1
    ! profile_allows_secrets_access work
  '
yq -i '.modules.runtime.requires.enableRuntimeManagement = false' \
  "$fixture/.chezmoidata/modules.yaml"
run_ok "accepts a boolean false module requirement" "$fixture/scripts/validate-policy.sh" --all

# Software catalog (packages.yaml) validation.
make_fixture
replace_once "$fixture/.chezmoidata/packages.yaml" \
  "  - { name: chezmoi, source: brew_formula }" \
  "  - { name: chezmoi, source: bogus_source }"
run_fail_contains \
  "rejects unknown package source" \
  "unknown package source: chezmoi: bogus_source" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
replace_once "$fixture/.chezmoidata/packages.yaml" \
  '  - { name: tacho, source: go_install, pkg: "github.com/kosako/tachograph/cmd/tacho" }' \
  "  - { name: tacho, source: go_install }"
run_fail_contains \
  "rejects go_install package without a canonical pkg" \
  "go_install package needs an explicit pkg (canonical id): tacho" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/packages.yaml" \
  "  - { name: chezmoi, source: brew_formula }" \
  "  - { name: chezmoi, source: brew_cask }"
run_fail_contains \
  "rejects duplicate package name" \
  "duplicate package name: chezmoi" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
replace_once "$fixture/.chezmoidata/packages.yaml" \
  "  - { name: chezmoi, source: brew_formula }" \
  "  - { name: chezmoi, source: brew_formula, track_only: tru }"
run_fail_contains \
  "rejects invalid track_only value" \
  "package track_only must be true or false: chezmoi: tru" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
: > "$fixture/.chezmoidata/packages.yaml"
run_fail_contains \
  "fails closed on empty packages catalog" \
  "no packages parsed" \
  "$fixture/scripts/validate-policy.sh" personal

# Private-backup catalog (backup-paths.yaml) validation.
make_fixture
insert_once "$fixture/.chezmoidata/backup-paths.yaml" \
  "  - { path: .zshrc.local, type: file, category: shell }" \
  "  - { path: /etc/passwd, type: file }"
run_fail_contains \
  "rejects an absolute backup path" \
  "backup path must be home-relative (no leading /): /etc/passwd" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/backup-paths.yaml" \
  "  - { path: .zshrc.local, type: file, category: shell }" \
  "  - { path: ../evil, type: file }"
run_fail_contains \
  "rejects a backup path with .." \
  "backup path must not contain ..: ../evil" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/backup-paths.yaml" \
  "  - { path: .zshrc.local, type: file, category: shell }" \
  '  - { path: ".config/x*", type: file }'
run_fail_contains \
  "rejects a backup path with glob metacharacters" \
  "backup path must not contain glob metacharacters: .config/x*" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/backup-paths.yaml" \
  "  - { path: .zshrc.local, type: file, category: shell }" \
  "  - { path: somefile, type: socket }"
run_fail_contains \
  "rejects an unknown backup path type" \
  "unknown backup path type: somefile: socket" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/backup-paths.yaml" \
  "  - { path: .zshrc.local, type: file, category: shell }" \
  "  - { path: .zshrc.local, type: file }"
run_fail_contains \
  "rejects a duplicate backup path" \
  "duplicate backup path: .zshrc.local" \
  "$fixture/scripts/validate-policy.sh" personal

# Distinct paths must stay distinct, including a single trailing pipe (#390).
make_fixture
printf 'backup_paths:\n  - { path: cfg, type: file }\n  - { path: "cfg|", type: file }\n' \
  > "$fixture/.chezmoidata/backup-paths.yaml"
run_ok_contains \
  "preserves a trailing pipe without a false duplicate" \
  "[ok] backup path: cfg|" \
  "$fixture/scripts/validate-policy.sh" personal
printf '  - { path: "cfg|", type: file }\n' >> "$fixture/.chezmoidata/backup-paths.yaml"
run_fail_contains \
  "reports the full duplicate path including its trailing pipe" \
  "duplicate backup path: cfg|" \
  "$fixture/scripts/validate-policy.sh" personal

# Structural validation happens in the shared parser before any row is
# emitted (#246): a missing path, a "|" in a free-form label (which would
# shift the fields and corrupt the path), or a control character in any
# field (a newline in a path would split into two plausible rows) are all
# rejected with one message — for the baseline here and, through the same
# function, for the local supplement at backup time.
make_fixture
insert_once "$fixture/.chezmoidata/backup-paths.yaml" \
  "  - { path: .zshrc.local, type: file, category: shell }" \
  "  - {}"
run_fail_contains \
  "rejects an empty backup path entry (no vacuous pass)" \
  "backup-paths entry invalid in" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/backup-paths.yaml" \
  "  - { path: .zshrc.local, type: file, category: shell }" \
  '  - { path: only-in-supplement, type: file, category: "shell|override" }'
run_fail_contains \
  "rejects a backup path category containing the field delimiter |" \
  "backup-paths entry invalid in" \
  "$fixture/scripts/validate-policy.sh" personal

# awk -v (insert_once) processes backslash escapes, so the YAML escape must
# arrive as the two characters \n (hence \\n here), not as a real newline —
# a real newline inside a double-quoted YAML scalar folds into a space and
# the entry would be valid.
make_fixture
insert_once "$fixture/.chezmoidata/backup-paths.yaml" \
  "  - { path: .zshrc.local, type: file, category: shell }" \
  '  - { path: "one\\nfile|other|two", type: file }'
run_fail_contains \
  "rejects a backup path containing a newline (would split into two rows)" \
  "backup-paths entry invalid in" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
insert_once "$fixture/.chezmoidata/backup-paths.yaml" \
  "  - { path: .zshrc.local, type: file, category: shell }" \
  "  - { path: somefile, type: 1 }"
run_fail_contains \
  "rejects a non-string backup path type" \
  "backup-paths entry invalid in" \
  "$fixture/scripts/validate-policy.sh" personal

# A scalar in place of the list: yq's `// []` would turn `false` into an
# empty list and every per-entry rule would pass vacuously, so the sequence
# check must not go through `//` (Codex review, PR #254).
make_fixture
printf 'backup_paths: false\n' > "$fixture/.chezmoidata/backup-paths.yaml"
run_fail_contains \
  "rejects a scalar false in place of the backup path list" \
  "backup-paths entry invalid in" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
: > "$fixture/.chezmoidata/backup-paths.yaml"
run_fail_contains \
  "fails closed on empty backup-paths catalog" \
  "no backup paths parsed" \
  "$fixture/scripts/validate-policy.sh" personal

# environmentKind cross-check. work / client / agent の deny 表 (lib-policy の
# environment_kind_forbidden_capabilities) の 5 つが kind ごとに全部発火することを
# 確かめる: personal (元から elevated) を各 kind に付け替え、唯一 false の enableAiTools
# も true にして、5 つすべての文言を assert する。client / agent に profile はまだ無い
# ので、この付け替えが表の行の証明になる。cap 名は表から導かず test に固定する (表から
# 行が落ちる退行を検出するため)。docs/policy-model.md の契約は hard fail なので、
# 文言だけでなく exit code も pin する。
for ek_kind in work client agent; do
  make_fixture
  replace_once "$fixture/.chezmoidata/profiles.yaml" "    environmentKind: personal" "    environmentKind: $ek_kind"
  replace_once "$fixture/.chezmoidata/profiles.yaml" "      enableAiTools: false" "      enableAiTools: true"
  ek_rc=0
  ek_output="$("$fixture/scripts/validate-policy.sh" personal 2>&1)" || ek_rc=$?
  if [[ "$ek_rc" -eq 0 ]]; then
    printf '%s\n' "$ek_output" >&2
    fail "test unexpectedly passed: $ek_kind deny must hard-fail"
    exit 1
  fi
  ek_missing=""
  for cap in installPackages installGuiApps allowSecretsAccess allowNetworkTunnels enableAiTools; do
    grep -Fq "environmentKind $ek_kind forbids $cap=true" <<< "$ek_output" || ek_missing="$ek_missing $cap"
  done
  if [[ -z "$ek_missing" ]]; then
    ok "test passed: every $ek_kind deny capability is enforced"
  else
    printf '%s\n' "$ek_output" >&2
    fail "test failed: $ek_kind deny not enforced for:$ek_missing"
    exit 1
  fi
done

# sandbox が禁止するのは allowSecretsAccess だけ。sandbox にも profile はまだ無いので、
# personal (elevated) を付け替えてこの行が発火することを証明する。
make_fixture
replace_once "$fixture/.chezmoidata/profiles.yaml" "    environmentKind: personal" "    environmentKind: sandbox"
run_fail_contains \
  "sandbox environmentKind forbids allowSecretsAccess" \
  "environmentKind sandbox forbids allowSecretsAccess=true" \
  "$fixture/scripts/validate-policy.sh" personal

# enum cross-check (#45): work / client / agent forbid npmHardeningMode=off
# (report is the floor; off drops the install-script defenses). Retag the
# committed work profile (npmHardeningMode: report, every forbidden boolean
# false) to each kind and force off: the enum row is then the only
# violation, so the hard fail (exit code), not just the message, is pinned
# for every constrained kind. personal would not do for that: its forbidden
# booleans are true, and those rows alone already exit 1. personal is still
# retagged to each kind with off, to pin that the enum row is reported
# alongside the boolean rows (every violation is reported, the check does
# not stop at the first).
for ek_kind in work client agent; do
  make_fixture
  replace_once "$fixture/.chezmoidata/profiles.yaml" "    environmentKind: work" "    environmentKind: $ek_kind"
  replace_once "$fixture/.chezmoidata/profiles.yaml" "      npmHardeningMode: report" "      npmHardeningMode: off"
  run_fail_contains \
    "$ek_kind environmentKind forbids npmHardeningMode=off" \
    "environmentKind $ek_kind forbids npmHardeningMode=off" \
    "$fixture/scripts/validate-policy.sh" work

  make_fixture
  replace_once "$fixture/.chezmoidata/profiles.yaml" "    environmentKind: personal" "    environmentKind: $ek_kind"
  replace_once "$fixture/.chezmoidata/profiles.yaml" "      npmHardeningMode: enforce" "      npmHardeningMode: off"
  run_fail_contains \
    "$ek_kind environmentKind reports npmHardeningMode=off alongside the boolean rows" \
    "environmentKind $ek_kind forbids npmHardeningMode=off" \
    "$fixture/scripts/validate-policy.sh" personal
done

# Only the off value is forbidden — a required value ("work must be enforce")
# is deliberately not modeled (the committed work profile runs report for
# company-npm reasons and must keep validating). enforce must also pass for
# every kind: flip all profiles to enforce and assert --all still validates.
make_fixture
set_capability_all "$fixture" npmHardeningMode enforce
run_ok \
  "npmHardeningMode=enforce is allowed for every environmentKind (only off is forbidden)" \
  "$fixture/scripts/validate-policy.sh" --all

# The forbidden-enum table itself is validated fail-closed: a row naming a
# value the schema does not declare (a typo would otherwise be a silently
# dead constraint) and a row without '=' both hard-fail. Mutate the fixture's
# lib-policy table to prove each branch fires.
make_fixture
replace_once "$fixture/scripts/lib-policy.sh" \
  "      printf '%s\\\\n' 'npmHardeningMode=off'" \
  "      printf '%s\\\\n' 'npmHardeningMode=typo'"
run_fail_contains \
  "a forbidden-enum row with an undeclared value fails closed" \
  "forbidden-enum row invalid" \
  "$fixture/scripts/validate-policy.sh" work

make_fixture
replace_once "$fixture/scripts/lib-policy.sh" \
  "      printf '%s\\\\n' 'npmHardeningMode=off'" \
  "      printf '%s\\\\n' 'npmHardeningMode off'"
run_fail_contains \
  "a forbidden-enum row without = fails closed" \
  "forbidden-enum row malformed" \
  "$fixture/scripts/validate-policy.sh" work

# enforceAiSandbox is a safety-hardening capability (opposite polarity to the
# install / secret / network / AI-tool capabilities), so it must NOT be in the
# environmentKind forbidden table: a restrictive kind (work) may set it true.
# Flip every profile's value to true and assert --all (personal + both work
# profiles) still validates; a regression that forbade it would hard-fail the
# work profiles here.
make_fixture
set_capability_all "$fixture" enforceAiSandbox true
run_ok \
  "enforceAiSandbox=true is allowed for every environmentKind (not forbidden)" \
  "$fixture/scripts/validate-policy.sh" --all

# gateGitHubMcp / enableGitHubIsolatedReader (#119 Phase 1) are also
# safety-hardening capabilities, so they must NOT be in the forbidden table
# either: a restrictive kind (work) may set them true. Flip both across every
# profile and assert --all still validates.
make_fixture
set_capability_all "$fixture" gateGitHubMcp true
set_capability_all "$fixture" enableGitHubIsolatedReader true
run_ok \
  "GitHub guard capabilities are allowed for every environmentKind (not forbidden)" \
  "$fixture/scripts/validate-policy.sh" --all

# gateUnusedClaudeMcp (#341) only removes MCP exposure from Claude Code (a
# deny), so it must NOT be in the forbidden table either.
make_fixture
set_capability_all "$fixture" gateUnusedClaudeMcp true
run_ok \
  "gateUnusedClaudeMcp=true is allowed for every environmentKind (not forbidden)" \
  "$fixture/scripts/validate-policy.sh" --all

# enableQualityLoopHooks (#199) only adds gates on the agent (a lint steer and
# a once-per-scope Stop block) and grants no install / secret / network
# privilege, so it must NOT be in the forbidden table either.
make_fixture
set_capability_all "$fixture" enableQualityLoopHooks true
run_ok \
  "enableQualityLoopHooks=true is allowed for every environmentKind (not forbidden)" \
  "$fixture/scripts/validate-policy.sh" --all

# enableHerdrIntegration (#225) only registers herdr's session-report hook and
# grants no install / secret / network privilege, so it must NOT be in the
# forbidden table either.
make_fixture
set_capability_all "$fixture" enableHerdrIntegration true
run_ok \
  "enableHerdrIntegration=true is allowed for every environmentKind (not forbidden)" \
  "$fixture/scripts/validate-policy.sh" --all

# enableToolCallRecordHook (#353) only registers agent-tools' tool-call record
# hook (a local JSONL of argument keys) and grants no install / secret /
# network privilege, so it must NOT be in the forbidden table either.
make_fixture
set_capability_all "$fixture" enableToolCallRecordHook true
run_ok \
  "enableToolCallRecordHook=true is allowed for every environmentKind (not forbidden)" \
  "$fixture/scripts/validate-policy.sh" --all

# codexReviewEffort / codexWorkerEffort (#264) only pick the reasoning effort
# agent-tools' Codex review / worker run with and grant no install / secret /
# network privilege, so no value is forbidden for any environmentKind.
make_fixture
set_capability_all "$fixture" codexReviewEffort xhigh
set_capability_all "$fixture" codexWorkerEffort xhigh
run_ok \
  "codexReviewEffort / codexWorkerEffort are allowed at any value for every environmentKind (not forbidden)" \
  "$fixture/scripts/validate-policy.sh" --all

# The fixture helpers themselves must fail closed: a typo'd capability or
# module silently no-oped in the old awk shape, leaving the following
# assertion to pass against an unflipped fixture (#149). flip_personal_capability
# had no guard until #332: a typo'd capability added a new key instead.
make_fixture
if set_capability_all "$fixture" noSuchCapability true 2>/dev/null; then
  fail "test failed: set_capability_all must reject an undeclared capability"
  exit 1
fi
ok "test passed: set_capability_all fails closed on an undeclared capability"
if remove_module_all "$fixture" no-such-module 2>/dev/null; then
  fail "test failed: remove_module_all must reject an unlisted module"
  exit 1
fi
ok "test passed: remove_module_all fails closed on an unlisted module"
if flip_personal_capability "$fixture" noSuchCapability true 2>/dev/null; then
  fail "test failed: flip_personal_capability must reject a capability the personal profile does not declare"
  exit 1
fi
ok "test passed: flip_personal_capability fails closed on an undeclared capability"
# An empty profiles map must fail too: `[] | all` is vacuously true in yq,
# so without the length guard the helper would "succeed" while setting
# nothing (Codex review, #149).
printf 'profiles: {}\n' > "$fixture/.chezmoidata/profiles.yaml"
if set_capability_all "$fixture" enforceAiSandbox true 2>/dev/null; then
  fail "test failed: set_capability_all must reject an empty profiles map"
  exit 1
fi
ok "test passed: set_capability_all fails closed on an empty profiles map"
if flip_personal_capability "$fixture" enforceAiSandbox true 2>/dev/null; then
  fail "test failed: flip_personal_capability must reject a profiles map without personal"
  exit 1
fi
ok "test passed: flip_personal_capability fails closed when the personal profile is absent"

# Capability registry (#151): a capability without implemented: true|false
# fails closed, and implemented: false without a doctor disclosure (the
# static proxy: doctor.sh mentions the name) fails. The mutations are
# verified by the failure assertions themselves — a no-op mutation would
# make validate pass and the test fail loudly.
make_fixture
yq -i 'del(.capabilities.enableGitSigning.implemented)' \
  "$fixture/.chezmoidata/capabilities.schema.yaml"
run_fail_contains \
  "capability without an implemented flag fails closed" \
  "enableGitSigning lacks implemented" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
yq -i '.capabilities.installGuiApps.implemented = false' \
  "$fixture/.chezmoidata/capabilities.schema.yaml"
run_fail_contains \
  "implemented=false without a doctor mention fails (undisclosed dormant)" \
  "installGuiApps is implemented=false but doctor.sh never mentions it" \
  "$fixture/scripts/validate-policy.sh" personal

# Anchor on the LAST capability line so the bogus section lands after the whole
# capabilities block (update this if a later capability is added below). That
# line belongs to the last profile (work), so validate that profile — checking
# another one would not see the inserted section at all (Codex review, PR #272).
make_fixture
insert_once "$fixture/.chezmoidata/profiles.yaml" "      codexWorkerEffort: off" "    extraSection:"
insert_once "$fixture/.chezmoidata/profiles.yaml" "    extraSection:" "      sneakyKey: true"
run_ok \
  "ignores sections after capabilities" \
  "$fixture/scripts/validate-policy.sh" work

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

# require_yq must reject a wrong yq, not just a missing one. Shadow yq
# with a fake earlier in PATH so the test is independent of whatever yq
# the host has (CI runners ship one in /usr/bin).
make_fixture
mkdir -p "$fixture/fakebin"
printf '#!/bin/sh\necho "yq 3.4.3 (python)"\n' > "$fixture/fakebin/yq"
chmod +x "$fixture/fakebin/yq"
run_fail_contains \
  "fails closed on a non-mikefarah yq" \
  "wrong yq variant" \
  env PATH="$fixture/fakebin:$PATH" "$fixture/scripts/validate-policy.sh" personal

make_fixture
mkdir -p "$fixture/fakebin"
printf '#!/bin/sh\necho "yq (https://github.com/mikefarah/yq/) version v3.4.0"\n' > "$fixture/fakebin/yq"
chmod +x "$fixture/fakebin/yq"
run_fail_contains \
  "fails closed on yq older than v4" \
  "yq v4+ required" \
  env PATH="$fixture/fakebin:$PATH" "$fixture/scripts/validate-policy.sh" personal

# The version text is another tool's output: shown through display_safe
# (#335), so a terminal escape in it is a `?`, never a raw byte.
for yq_case in variant old; do
  make_fixture
  mkdir -p "$fixture/fakebin"
  if [[ "$yq_case" == variant ]]; then
    printf '#!/bin/sh\nprintf "yq 3\\033[2J (python)\\n"\n' > "$fixture/fakebin/yq"
    yq_want="wrong yq variant: need mikefarah/yq v4, got: yq 3?[2J (python)"
  else
    printf '#!/bin/sh\nprintf "yq (https://github.com/mikefarah/yq/) version v3\\033[2J\\n"\n' > "$fixture/fakebin/yq"
    yq_want="yq v4+ required, got: yq (https://github.com/mikefarah/yq/) version v3?[2J"
  fi
  chmod +x "$fixture/fakebin/yq"
  yq_rc=0
  yq_out="$(env PATH="$fixture/fakebin:$PATH" "$fixture/scripts/validate-policy.sh" personal 2>&1)" || yq_rc=$?
  if [[ "$yq_rc" -ne 0 ]] && grep -Fq -- "$yq_want" <<< "$yq_out" && ! grep -Fq $'\033' <<< "$yq_out"; then
    ok "test passed: a yq version with a terminal escape is shown with ? ($yq_case)"
  else
    printf '%s\n' "$yq_out" | LC_ALL=C cat -v >&2
    fail "test failed: a yq version with a terminal escape reached the output raw ($yq_case)"
    exit 1
  fi
done

# ---- Software catalog drift (report_catalog_drift) ----
# report_catalog_drift probes real package managers, so tests run it against
# fake brew / npm / go on a minimal PATH (only the fakes, a symlinked yq,
# and coreutils). This keeps the inventory fully controlled and independent
# of whatever is installed on the host or CI runner. Every assertion also
# proves the report-only contract: run_ok_contains requires exit 0, so the
# drift cases confirm drift never changes the exit code.

# Globals set by setup_drift: drift_dir (fake inventory + go bin),
# drift_fakebin (fake managers + yq symlink). Reuses `fixture` from
# make_fixture for the sourced lib-policy.sh and packages.yaml.
#
# shell_env_formulae mirrors the #96 interactive-shell brew formulae now in the
# catalog so the reality-seed stays drift-free; reused by the override cases
# below so each still introduces exactly one drift.
shell_env_formulae=(starship zoxide fzf fzf-tab zsh-autosuggestions \
  zsh-syntax-highlighting zsh-completions ripgrep fd eza bat direnv)
setup_drift() {
  make_fixture
  drift_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-drift.XXXXXX")"
  tmp_roots+=("$drift_dir")
  drift_fakebin="$drift_dir/bin"
  mkdir -p "$drift_fakebin" "$drift_dir/go/bin"

  cat > "$drift_fakebin/brew" <<'EOF'
#!/bin/sh
case "$*" in
  "list --formula"*) cat "$DRIFT_DIR/brew_formulae" 2>/dev/null ;;
  "leaves"*) cat "$DRIFT_DIR/brew_leaves" 2>/dev/null ;;
  "list --cask"*) cat "$DRIFT_DIR/brew_casks" 2>/dev/null ;;
esac
exit 0
EOF
  cat > "$drift_fakebin/npm" <<'EOF'
#!/bin/sh
case "$*" in
  "ls -g"*) cat "$DRIFT_DIR/npm.json" 2>/dev/null ;;
  "root -g") echo "$DRIFT_DIR/npm-global" ;;
esac
exit 0
EOF
  cat > "$drift_fakebin/go" <<'EOF'
#!/bin/sh
if [ "$1" = "env" ] && [ "$2" = "GOBIN" ]; then echo ""; exit 0; fi
if [ "$1" = "env" ] && [ "$2" = "GOPATH" ]; then echo "$FAKE_GOPATH"; exit 0; fi
exit 0
EOF
  chmod +x "$drift_fakebin/brew" "$drift_fakebin/npm" "$drift_fakebin/go"
  # Make the fake bin fully self-contained so report_catalog_drift runs with
  # PATH=$drift_fakebin only. A minimal PATH that still included /usr/bin
  # would leak host tools: GitHub's ubuntu runner ships a real `go` in
  # /usr/bin, which would defeat the go-absent test. Symlinking the few real
  # tools the function needs keeps manager presence controlled by the fakes
  # alone (and host-independent).
  local tool
  for tool in bash sh cat dirname mktemp sort grep find basename awk rm yq; do
    ln -s "$(command -v "$tool")" "$drift_fakebin/$tool"
  done

  # Default inventory == the reality-seed catalog (drift-free baseline).
  printf '%s\n' age chezmoi gh herdr mise opencode shellcheck tmux yq "${shell_env_formulae[@]}" \
    > "$drift_dir/brew_formulae"
  printf '%s\n' age chezmoi gh herdr mise opencode shellcheck tmux yq "${shell_env_formulae[@]}" \
    > "$drift_dir/brew_leaves"
  printf '%s\n' 1password-cli iterm2 swiftbar > "$drift_dir/brew_casks"
  # npm and corepack are node-bundled; including them proves they are
  # filtered out and never reported as undeclared.
  printf '%s' '{"dependencies":{"@openai/codex":{},"npm":{},"corepack":{}}}' \
    > "$drift_dir/npm.json"
  touch "$drift_dir/go/bin/goreleaser" "$drift_dir/go/bin/tacho"
  chmod +x "$drift_dir/go/bin/goreleaser" "$drift_dir/go/bin/tacho"
}

run_drift() {
  local name="$1"
  local expected="$2"
  run_ok_contains "$name" "$expected" \
    env "PATH=$drift_fakebin" \
        "DRIFT_DIR=$drift_dir" \
        "FAKE_GOPATH=$drift_dir/go" \
        "LIBPOLICY=$fixture/scripts/lib-policy.sh" \
        bash -c 'set -euo pipefail; source "$LIBPOLICY"; report_catalog_drift'
}

# Drop one entry from the seeded brew inventory to simulate a declared-but-
# absent package. Mutating the seed (rather than re-listing it) keeps each
# override case inheriting the full reality-seed, so it introduces exactly one
# drift and can never silently diverge from shell_env_formulae.
drift_seed_remove() {
  local entry="$1" f
  for f in brew_formulae brew_leaves; do
    grep -vx "$entry" "$drift_dir/$f" > "$drift_dir/$f.tmp"
    mv "$drift_dir/$f.tmp" "$drift_dir/$f"
  done
}

setup_drift
run_drift "catalog drift: clean when reality matches the catalog" "no catalog drift"

setup_drift
printf 'librsvg\n' >> "$drift_dir/brew_leaves"
run_drift "catalog drift: flags an undeclared brew leaf" \
  "undeclared: librsvg (brew_formula leaf not in catalog)"

setup_drift
drift_seed_remove chezmoi
run_drift "catalog drift: flags a declared package that is not installed" \
  "not installed: chezmoi (brew_formula)"

setup_drift
# Declared via brew but absent from brew, while the command resolves on
# PATH -> source drift (info), not "not installed".
drift_seed_remove gh
printf '#!/bin/sh\nexit 0\n' > "$drift_fakebin/gh"
chmod +x "$drift_fakebin/gh"
run_drift "catalog drift: source mismatch is info when the command is on PATH" \
  "source drift: gh declared brew_formula"

setup_drift
touch "$drift_dir/go/bin/stray-tool"
chmod +x "$drift_dir/go/bin/stray-tool"
run_drift "catalog drift: flags an undeclared go binary" \
  "undeclared: stray-tool (go binary not in catalog)"

# The Go toolchain's own binaries (go, gofmt) sit in the scanned bin dir when
# the toolchain manager points GOBIN at $GOROOT/bin (mise does). They are not
# catalog-managed go_install packages, so they must not surface as undeclared
# sprawl -- the seed already declares goreleaser/tacho, so adding only go/gofmt
# must leave the catalog drift-free.
setup_drift
touch "$drift_dir/go/bin/go" "$drift_dir/go/bin/gofmt"
chmod +x "$drift_dir/go/bin/go" "$drift_dir/go/bin/gofmt"
run_drift "catalog drift: go toolchain binaries are not undeclared sprawl" \
  "no catalog drift"

setup_drift
rm -f "$drift_fakebin/brew"
run_drift "catalog drift: skips a missing package manager (report-only)" \
  "brew: not found (brew sources skipped)"

setup_drift
# go absent must be a skip, not "not installed": a go-built binary can linger
# in GOPATH/bin without go, but the contract treats an absent manager as skip.
rm -f "$drift_fakebin/go"
run_drift "catalog drift: skips go_install when go is absent" \
  "skip goreleaser: go not available"

# Report writes survive EINTR (#378). bash 3.2 installs its SIGCHLD handler
# without SA_RESTART: a child that exits while a report write to a full pipe
# is blocked failed the printf builtin with EINTR, and under set -e the
# script stopped half-way (doctor on the macOS bash32 CI job). The scripts
# run under this suite's bash ($BASH). Each step waits on a cue, not on a
# clock (#378 review): the reader reads only once the test releases it; the
# writer notes the index of each line before writing it, and an index that
# has stood still for a second with the writer unfinished is a writer
# blocked on the full pipe (the lines far outgrow any pipe, and nothing
# reads them yet). Only then are the writer's children let go; they end
# over a second, so even a writer that stood still for another reason is
# blocked when the later ones end, and the index must not have moved by the
# time all have ended. The reader is released after that. Every [info] /
# [warn] line — some longer than any stdio buffer — must then arrive exactly
# once and in order. A control run writes the same lines with the bare
# builtin: under bash 3.2 it must stop short, or the fixture did not
# reproduce the condition and the case would pass vacuously (bash 4+
# restarts the write by itself, so there the control is only reported).
# Every process these cases leave waiting also stops waiting once the temp
# dir is gone, so an interrupted suite (whose EXIT trap removes it) leaves
# none behind (#378 review).
eintr_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-policy-eintr.XXXXXX")"
tmp_roots+=("$eintr_dir")
cat > "$eintr_dir/writer.sh" <<'SH'
set -euo pipefail
source "$EINTR_LIB"
emit() {
  if [[ "$EINTR_MODE" == bare ]]; then
    if (($1 % 2)); then printf '[warn] %s\n' "$2" >&2; else printf '[info] - %s\n' "$2"; fi
  elif (($1 % 2)); then
    warn "$2"
  else
    item "$2"
  fi
}
for delay in 0 0.25 0.5 0.75 1; do
  (
    until [[ -e "$EINTR_DIR/go" || ! -d "$EINTR_DIR" || "$SECONDS" -ge 120 ]]; do sleep 0.05; done
    sleep "$delay"
  ) &
  printf '%s\n' "$!" >> "$EINTR_DIR/kids"
done
for ((i = 0; i < 3000; i++)); do
  if ((i % 500 == 250)); then printf -v line '%070000d' "$i"; else printf -v line '%095d' "$i"; fi
  printf '%s\n' "$i" > "$EINTR_DIR/at"
  emit "$i" "$line"
done
wait
printf 'writer finished\n' > "$EINTR_DIR/done"
SH
for ((i = 0; i < 3000; i++)); do
  if ((i % 500 == 250)); then printf -v line '%070000d' "$i"; else printf -v line '%095d' "$i"; fi
  if ((i % 2)); then printf '[warn] %s\n' "$line"; else printf '[info] - %s\n' "$line"; fi
done > "$eintr_dir/want"
# eintr_hold FILE — wait until FILE exists, its dir is gone, or two minutes
# pass: how the readers below wait for their release.
eintr_hold() {
  local t
  for ((t = 0; t < 2400; t++)); do
    [[ ! -e "$1" && -d "${1%/*}" ]] || return 0
    sleep 0.05
  done
}
# eintr_wait_blocked — wait (up to 30 s) until the writer's line index has
# stood still for a second with the writer unfinished. Returns 1 at the
# deadline, or when the writer finished (it cannot have blocked).
eintr_wait_blocked() {
  local last="" now still=0 tries
  for ((tries = 0; tries < 300; tries++)); do
    sleep 0.1
    [[ ! -e "$eintr_dir/done" ]] || return 1
    now="$(cat "$eintr_dir/at" 2>/dev/null || true)"
    if [[ -n "$now" && "$now" == "$last" ]]; then
      still=$((still + 1))
      [[ "$still" -lt 10 ]] || return 0
    else
      still=0
      last="$now"
    fi
  done
  return 1
}
# eintr_wait_gone FILE TENTHS — wait (up to TENTHS tenths of a second) until
# no pid listed in FILE is alive. Returns 1 at the deadline, or when FILE
# lists no pid.
eintr_wait_gone() {
  local pid alive listed tries
  for ((tries = 0; tries < $2; tries++)); do
    alive=0 listed=0
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      listed=1
      if kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done < "$1"
    [[ "$listed" -eq 1 ]] || return 1
    [[ "$alive" -eq 1 ]] || return 0
    sleep 0.1
  done
  return 1
}
# eintr_run MODE — run the writer through the cued steps; leaves got / done,
# and eintr_cued=0 when a cue was not met (the run then proves nothing).
# The children and the reader are let go whatever happened, so the run
# always ends.
eintr_run() {
  local pipeline at
  rm -f "$eintr_dir/got" "$eintr_dir/done" "$eintr_dir/at" "$eintr_dir/kids" \
    "$eintr_dir/go" "$eintr_dir/release"
  EINTR_LIB="$SCRIPT_DIR/lib-policy.sh" EINTR_DIR="$eintr_dir" EINTR_MODE="$1" \
    "$BASH" "$eintr_dir/writer.sh" 2>&1 \
    | { eintr_hold "$eintr_dir/release"; cat; } > "$eintr_dir/got" &
  pipeline=$!
  eintr_cued=0
  if eintr_wait_blocked; then
    at="$(cat "$eintr_dir/at")"
    : > "$eintr_dir/go"
    if eintr_wait_gone "$eintr_dir/kids" 100 && [[ "$(cat "$eintr_dir/at")" == "$at" ]]; then
      eintr_cued=1
    fi
  fi
  : > "$eintr_dir/go"
  : > "$eintr_dir/release"
  wait "$pipeline" || true
}
# The control's failure shows as a writer that did not finish (set -e ends it
# at the failed write), not as bash's "write error" message: that message is
# written to the same blocked pipe, and the next child's SIGCHLD can cut it
# too.
eintr_run bare
if [[ "$eintr_cued" -ne 1 ]]; then
  fail "test failed: in the EINTR fixture's control run the writer did not stay blocked on the full pipe until its children had ended, within the deadline"
  exit 1
fi
eintr_bare_lines="$(wc -l < "$eintr_dir/got" | tr -d ' ')"
if [[ "$(cat "$eintr_dir/done" 2>/dev/null)" == "writer finished" ]] && cmp -s "$eintr_dir/want" "$eintr_dir/got"; then
  eintr_bare_whole=1
else
  eintr_bare_whole=0
fi
if [[ "${BASH_VERSINFO[0]}" -lt 4 && "$eintr_bare_whole" -eq 1 ]]; then
  fail "test failed: the EINTR fixture did not reproduce under bash $BASH_VERSION (the bare builtin wrote every line), so the report case below would pass vacuously"
  exit 1
fi
info "EINTR fixture: the bare builtin wrote $eintr_bare_lines of 3000 lines under bash $BASH_VERSION (finished whole: $eintr_bare_whole)"
eintr_run report
if [[ "$eintr_cued" -ne 1 ]]; then
  fail "test failed: in the EINTR fixture's report run the writer did not stay blocked on the full pipe until its children had ended, within the deadline"
  exit 1
fi
if [[ "$(cat "$eintr_dir/done" 2>/dev/null)" == "writer finished" ]] && cmp -s "$eintr_dir/want" "$eintr_dir/got"; then
  ok "test passed: report lines survive an EINTR on a blocked write (each line once, in order, long lines whole, no write error)"
else
  fail "test failed: a report write interrupted by SIGCHLD lost, repeated or broke the output, or stopped the script (got $(wc -l < "$eintr_dir/got" | tr -d ' ') of 3000 lines; $(grep -c 'write error' "$eintr_dir/got" || true) write error(s))"
  exit 1
fi
# A write that cannot be made at all still fails (it is not turned into a
# success): stdout or stderr closed.
if (source "$SCRIPT_DIR/lib-policy.sh"; report_write 1 'x') >&- 2>/dev/null \
  || (source "$SCRIPT_DIR/lib-policy.sh"; report_write 2 'x' 2>&-) 2>/dev/null; then
  fail "test failed: report_write must fail when its fd is closed"
  exit 1
fi
ok "test passed: report_write still fails when its fd is closed"
# A TERM sent to the script alone while a report write is blocked (the
# reader stopped reading) runs the script's trap at once (#378 review):
# waiting on the write in the foreground would hold the trap — doctor's
# probe cleanup, private-backup's removal of its plaintext temps — until the
# reader came back. The trap ends the writer in flight with
# report_write_stop, as the reporting scripts' traps do, so no writer is
# left behind on the pipe. The reader is released only after both are
# judged, so a trap held until the reader came back cannot pass, and the
# line being written when the TERM landed must not have arrived: a write
# that was not blocked would have finished it, and the case would prove
# nothing. A second run lands another signal (HUP) on the script while its
# TERM trap is inside report_write_stop (from a pgrep shim), whose own trap
# must still find and end the writer (#378 review). Only the bash 3.2 path
# (the background writer) is held to this: bash 4+ writes with the builtin
# in place and restarts the write after the trap's signal, as it always
# did, so the cases are skipped there.
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  info "skipped the blocked-write TERM cases under bash $BASH_VERSION (the builtin write is restarted; unchanged by #378)"
else
cat > "$eintr_dir/term.sh" <<'SH'
set -euo pipefail
source "$EINTR_LIB"
trap 'printf "trapped\n" > "$EINTR_DIR/trapped"; report_write_stop; trap - TERM; kill -TERM $$' TERM
trap 'report_write_stop; trap - HUP; kill -HUP $$' HUP
printf '%s\n' "$$" > "$EINTR_DIR/term.pid"
for ((i = 0; i < 3000; i++)); do
  printf -v line '%095d' "$i"
  printf '%s\n' "$i" > "$EINTR_DIR/at"
  item "$line"
done
SH
mkdir "$eintr_dir/shim"
cat > "$eintr_dir/shim/pgrep" <<'SH'
#!/bin/sh
# The first call lands a HUP on the script, then answers as pgrep does.
if [ ! -e "$EINTR_DIR/second" ]; then
  : > "$EINTR_DIR/second"
  kill -HUP "$(cat "$EINTR_DIR/term.pid")"
fi
exec "$EINTR_PGREP" "$@"
SH
chmod +x "$eintr_dir/shim/pgrep"
eintr_pgrep="$(command -v pgrep)"
# term_case MODE — run the TERM case (MODE plain, or reenter for the second
# signal); sets term_failure, empty when it passed.
term_case() {
  local pipeline at path="$PATH" line
  rm -f "$eintr_dir/done" "$eintr_dir/at" "$eintr_dir/release" "$eintr_dir/term.pid" \
    "$eintr_dir/term.writer" "$eintr_dir/term.got" "$eintr_dir/trapped" "$eintr_dir/second"
  [[ "$1" != reenter ]] || path="$eintr_dir/shim:$PATH"
  PATH="$path" EINTR_LIB="$SCRIPT_DIR/lib-policy.sh" EINTR_DIR="$eintr_dir" EINTR_PGREP="$eintr_pgrep" \
    "$BASH" "$eintr_dir/term.sh" \
    | { eintr_hold "$eintr_dir/release"; cat; } > "$eintr_dir/term.got" &
  pipeline=$!
  term_failure=""
  if eintr_wait_blocked; then
    at="$(cat "$eintr_dir/at")"
    # The writer blocked on the pipe is term.sh's one child.
    pgrep -P "$(cat "$eintr_dir/term.pid")" > "$eintr_dir/term.writer" 2>/dev/null || true
    kill -TERM "$(cat "$eintr_dir/term.pid")" 2>/dev/null || true
    term_trapped=0
    for ((i = 0; i < 30; i++)); do
      if [[ -s "$eintr_dir/trapped" ]]; then
        term_trapped=1
        break
      fi
      sleep 0.1
    done
    if [[ "$term_trapped" -ne 1 ]]; then
      term_failure="a TERM to the script while a report write was blocked did not run its trap within 3 seconds (the trap waited for the reader)"
    elif ! eintr_wait_gone "$eintr_dir/term.writer" 30; then
      term_failure="the blocked report writer was still alive 3 seconds after the trap, or none was found (report_write_stop did not end it)"
    elif [[ "$1" == reenter && ! -e "$eintr_dir/second" ]]; then
      term_failure="the pgrep shim did not land the second signal (the case proves nothing)"
    fi
  else
    term_failure="the writer did not block on the full pipe within the deadline"
  fi
  : > "$eintr_dir/release"
  wait "$pipeline" || true
  if [[ -z "$term_failure" ]]; then
    printf -v line '[info] - %095d' "$at"
    if grep -Fqx -- "$line" "$eintr_dir/term.got"; then
      term_failure="the line being written when the TERM landed arrived whole: the write was not blocked (the case proves nothing) or the trap waited for it"
    elif [[ "$(cat "$eintr_dir/at")" != "$at" ]]; then
      term_failure="the script went on writing after the TERM"
    fi
  fi
}
term_case plain
if [[ -n "$term_failure" ]]; then
  fail "test failed: $term_failure"
  exit 1
fi
ok "test passed: a TERM to the script while a report write is blocked runs its trap at once, and the trap leaves no writer behind"
term_case reenter
if [[ -n "$term_failure" ]]; then
  fail "test failed (second signal inside report_write_stop): $term_failure"
  exit 1
fi
ok "test passed: a second signal landing inside report_write_stop still ends the writer"
fi
# Every script that reports ends a report write in flight from its EXIT trap
# (doctor and private-backup from their INT / TERM traps too), the call the
# TERM cases above hold to its effect (#378 review).
for script in doctor preflight validate-policy install-packages private-backup; do
  for sig in EXIT INT TERM; do
    case "$script:$sig" in
      doctor:* | private-backup:* | *:EXIT) ;;
      *) continue ;;
    esac
    if ! grep -Eq "^[[:space:]]*trap .*report_write_stop.* $sig\$" "$SCRIPT_DIR/$script.sh"; then
      fail "test failed: $script.sh must call report_write_stop from its $sig trap"
      exit 1
    fi
  done
done
ok "test passed: the reporting scripts end a report write in flight from their traps"

ok "policy tests passed"
