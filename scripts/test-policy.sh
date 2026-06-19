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

# environmentKind cross-check. Every deny entry for work/client/agent
# must actually fire: retag personal (already elevated) to work and force
# the two caps it leaves false to true, then assert all six are flagged.
make_fixture
replace_once "$fixture/.chezmoidata/profiles.yaml" "    environmentKind: personal" "    environmentKind: work"
replace_once "$fixture/.chezmoidata/profiles.yaml" "      enableMacOSDefaults: false" "      enableMacOSDefaults: true"
replace_once "$fixture/.chezmoidata/profiles.yaml" "      enableAiTools: false" "      enableAiTools: true"
ek_output="$("$fixture/scripts/validate-policy.sh" personal 2>&1 || true)"
ek_missing=""
for cap in installPackages installGuiApps enableMacOSDefaults allowSecretsAccess allowNetworkTunnels enableAiTools; do
  grep -Fq "environmentKind work forbids $cap=true" <<< "$ek_output" || ek_missing="$ek_missing $cap"
done
if [[ -z "$ek_missing" ]]; then
  ok "test passed: every work deny capability is enforced"
else
  printf '%s\n' "$ek_output" >&2
  fail "test failed: work deny not enforced for:$ek_missing"
  exit 1
fi

# client / sandbox / agent have no profile yet; retag personal (which has
# elevated capabilities) to prove each row's constraint fires.
make_fixture
replace_once "$fixture/.chezmoidata/profiles.yaml" "    environmentKind: personal" "    environmentKind: client"
run_fail_contains \
  "client environmentKind forbids elevated capabilities" \
  "environmentKind client forbids" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
replace_once "$fixture/.chezmoidata/profiles.yaml" "    environmentKind: personal" "    environmentKind: sandbox"
run_fail_contains \
  "sandbox environmentKind forbids allowSecretsAccess" \
  "environmentKind sandbox forbids allowSecretsAccess=true" \
  "$fixture/scripts/validate-policy.sh" personal

make_fixture
replace_once "$fixture/.chezmoidata/profiles.yaml" "    environmentKind: personal" "    environmentKind: agent"
run_fail_contains \
  "agent environmentKind forbids elevated capabilities" \
  "environmentKind agent forbids" \
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
  # yq is the one real tool the function needs; symlink it so the minimal
  # PATH can still satisfy require_yq without pulling in the host's bin dir.
  ln -s "$(command -v yq)" "$drift_fakebin/yq"

  # Default inventory == the reality-seed catalog (drift-free baseline).
  printf '%s\n' chezmoi gh mise tmux yq > "$drift_dir/brew_formulae"
  printf '%s\n' chezmoi gh mise tmux yq > "$drift_dir/brew_leaves"
  printf '%s\n' copilot-cli iterm2 swiftbar > "$drift_dir/brew_casks"
  # npm and corepack are node-bundled; including them proves they are
  # filtered out and never reported as undeclared.
  printf '%s' '{"dependencies":{"@anthropic-ai/claude-code":{},"@openai/codex":{},"npm":{},"corepack":{}}}' \
    > "$drift_dir/npm.json"
  touch "$drift_dir/go/bin/goreleaser" "$drift_dir/go/bin/tacho"
  chmod +x "$drift_dir/go/bin/goreleaser" "$drift_dir/go/bin/tacho"
}

run_drift() {
  local name="$1"
  local expected="$2"
  run_ok_contains "$name" "$expected" \
    env "PATH=$drift_fakebin:/usr/bin:/bin" \
        "DRIFT_DIR=$drift_dir" \
        "FAKE_GOPATH=$drift_dir/go" \
        "LIBPOLICY=$fixture/scripts/lib-policy.sh" \
        bash -c 'set -euo pipefail; source "$LIBPOLICY"; report_catalog_drift'
}

setup_drift
run_drift "catalog drift: clean when reality matches the catalog" "no catalog drift"

setup_drift
printf 'librsvg\n' >> "$drift_dir/brew_leaves"
run_drift "catalog drift: flags an undeclared brew leaf" \
  "undeclared: librsvg (brew_formula leaf not in catalog)"

setup_drift
printf '%s\n' gh mise tmux yq > "$drift_dir/brew_formulae"
printf '%s\n' gh mise tmux yq > "$drift_dir/brew_leaves"
run_drift "catalog drift: flags a declared package that is not installed" \
  "not installed: chezmoi (brew_formula)"

setup_drift
# Declared via brew but absent from brew, while the command resolves on
# PATH -> source drift (info), not "not installed".
printf '%s\n' chezmoi mise tmux yq > "$drift_dir/brew_formulae"
printf '%s\n' chezmoi mise tmux yq > "$drift_dir/brew_leaves"
printf '#!/bin/sh\nexit 0\n' > "$drift_fakebin/gh"
chmod +x "$drift_fakebin/gh"
run_drift "catalog drift: source mismatch is info when the command is on PATH" \
  "source drift: gh declared brew_formula"

setup_drift
touch "$drift_dir/go/bin/stray-tool"
chmod +x "$drift_dir/go/bin/stray-tool"
run_drift "catalog drift: flags an undeclared go binary" \
  "undeclared: stray-tool (go binary not in catalog)"

setup_drift
rm -f "$drift_fakebin/brew"
run_drift "catalog drift: skips a missing package manager (report-only)" \
  "brew: not found (brew sources skipped)"

ok "policy tests passed"
