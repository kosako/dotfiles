#!/usr/bin/env bash
set -euo pipefail

# Inventory regressions (#205/#209/#213), reached by test-install-packages.sh.
# Only fake managers are on PATH and HOME is an empty fixture dir. Installs and
# attempted toolchain downloads become fixture markers; no real manager or user
# configuration is consulted.
# installer 本体の経路 (track-only / manager 不在 / install 失敗。#333) も末尾で通す。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-inventory-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/repo/scripts" "$fixture/repo/.chezmoidata" \
  "$fixture/gobin" "$fixture/gopath/bin" "$fixture/caller" "$fixture/home"
cp "$SCRIPT_DIR/lib-policy.sh" "$SCRIPT_DIR/install-packages.sh" "$fixture/repo/scripts/"
cp "$PROFILES_FILE" "$fixture/repo/.chezmoidata/profiles.yaml"
cat > "$fixture/repo/.chezmoidata/packages.yaml" <<'YAML'
packages:
  - {name: fixture-formula, source: brew_formula}
  - {name: fixture-cask, source: brew_cask}
  - {name: fixture-npm, source: npm_global}
  - {name: fixture-go, source: go_install, pkg: example.invalid/fixture/cli}
  - {name: fixture-mas, source: mas, pkg: "10101010"}
YAML
cat > "$fixture/caller/go.mod" <<'MOD'
module example.invalid/caller

go 99.0.0
toolchain go99.0.0
MOD
cat > "$fixture/caller/go.work" <<'WORK'
go 99.0.0
toolchain go99.0.0
use .
WORK
printf '#!/bin/sh\nexit 0\n' > "$fixture/gobin/fixture-go"
chmod +x "$fixture/gobin/fixture-go"

cat > "$fixture/bin/chezmoi" <<'FAKE'
#!/bin/sh
printf '{"profile":"personal"}\n'
FAKE
for manager in brew npm mas; do
  cat > "$fixture/bin/$manager" <<'FAKE'
#!/bin/sh
# A manager that reads its stdin to the end (#329) must find no catalog rows
# there (INVENTORY_TEST_READ_STDIN; the test's own stdin is /dev/null).
[ -z "${INVENTORY_TEST_READ_STDIN:-}" ] || cat > /dev/null
manager="${0##*/}"
if [ "$1" = install ]; then
  printf '%s %s\n' "$manager" "$*" >> "$INVENTORY_TEST_ROOT/installs"
  # INVENTORY_TEST_INSTALL_FAIL で名指しした manager の install は、記録してから失敗する (#333)。
  [ "${INVENTORY_TEST_INSTALL_FAIL:-}" != "$manager" ] || exit 1
  exit 0
fi
if [ "${INVENTORY_TEST_STATE:-present}" = fail ]; then
  # A partially printed inventory with a failure is still unknown.
  if [ "$manager" = npm ]; then
    printf '{"dependencies":{"partial-entry":{}}}\n'
    printf 'FIXTURE_NPM_PRIVATE_DIAGNOSTIC\n' >&2
    exit 42
  fi
  exit 1
fi
case "${INVENTORY_TEST_STATE:-present}:$manager:$*" in
  partial:brew:list\ --formula*) exit 1 ;;
esac
case "$manager:$*" in
  npm:root*) printf '%s/npm-root\n' "$INVENTORY_TEST_ROOT"; exit 0 ;;
  npm:ls*)
    case "${INVENTORY_TEST_STATE:-present}" in
      malformed) printf 'invalid-json\n' ;;
      wrong-shape) printf '{"dependencies":[]}\n' ;;
      empty|partial) printf '{}\n' ;;
      *) printf '{"dependencies":{"fixture-npm":{}}}\n' ;;
    esac
    exit 0 ;;
esac
[ "${INVENTORY_TEST_STATE:-present}" = empty ] && exit 0
case "$manager:$*" in
  brew:list\ --formula*) printf 'fixture-formula\n' ;;
  brew:leaves) printf 'fixture-formula\n' ;;
  brew:list\ --cask*) printf 'fixture-cask\n' ;;
  mas:list) printf '10101010 Fixture App (1.0)\n' ;;
  *) exit 97 ;;
esac
FAKE
  chmod +x "$fixture/bin/$manager"
done
cat > "$fixture/bin/go" <<'FAKE'
#!/bin/sh
# A manager that reads its stdin to the end (#329) must find no catalog rows
# there (INVENTORY_TEST_READ_STDIN; the test's own stdin is /dev/null).
[ -z "${INVENTORY_TEST_READ_STDIN:-}" ] || cat > /dev/null
if [ "$1" = install ]; then
  printf 'go %s\n' "$*" >> "$INVENTORY_TEST_ROOT/installs"
  exit 0
fi
[ "$1" = env ] || exit 97
if [ "${GOTOOLCHAIN:-}" != local ] || [ "${GO111MODULE:-}" != off ] || [ "${GOWORK:-}" != off ]; then
  : > "$INVENTORY_TEST_ROOT/toolchain-download-attempt"
  exit 98
fi
[ "${INVENTORY_TEST_STATE:-present}" = fail ] && exit 1
case "$2:${INVENTORY_TEST_GO_STATE:-gobin}" in
  GOBIN:failure) exit 1 ;;
  GOBIN:gobin) printf '%s/gobin\n' "$INVENTORY_TEST_ROOT" ;;
  GOBIN:relative) printf 'relative/bin\n' ;;
  GOBIN:*) printf '\n' ;;
  GOPATH:gopath-failure) exit 1 ;;
  GOPATH:empty-gopath) printf '\n' ;;
  GOPATH:relative-gopath) printf 'relative\n' ;;
  GOPATH:*) printf '%s/gopath:%s/other-gopath\n' "$INVENTORY_TEST_ROOT" "$INVENTORY_TEST_ROOT" ;;
  *) exit 97 ;;
esac
FAKE
chmod +x "$fixture/bin/go" "$fixture/bin/chezmoi"
for tool in bash sh dirname cat grep find basename awk mktemp rm yq; do
  ln -s "$(command -v "$tool")" "$fixture/bin/$tool"
done

run_fixture() {
  (
    cd "$fixture/caller"
    env PATH="$fixture/bin" HOME="$fixture/home" INVENTORY_TEST_ROOT="$fixture" \
      GOTOOLCHAIN=go99.0.0 GO111MODULE=on GOWORK="$fixture/caller/go.work" "$@"
  )
}
probe_go() {
  run_fixture bash -c 'source "$1"; go_bin_dir' _ "$fixture/repo/scripts/lib-policy.sh"
}
installer="$fixture/repo/scripts/install-packages.sh"

if [[ "$(probe_go)" != "$fixture/gobin" ]] || [[ -e "$fixture/toolchain-download-attempt" ]]; then
  fail "Go inventory must ignore caller toolchain requests without downloading"
  exit 1
fi
ok "Go probe suppresses toolchain/module/workspace selection from the caller"
if [[ "$(INVENTORY_TEST_GO_STATE=gopath probe_go)" != "$fixture/gopath/bin" ]]; then
  fail "empty GOBIN must use the first valid GOPATH entry"
  exit 1
fi
for state in failure gopath-failure empty-gopath relative relative-gopath; do
  if result="$(INVENTORY_TEST_GO_STATE="$state" probe_go)" || [[ -n "$result" ]]; then
    fail "Go probe must fail without a guessed path: $state"
    exit 1
  fi
done
ok "failed or invalid Go env never falls back to /bin"

: > "$fixture/installs"
output="$(run_fixture "$installer" --apply 2>&1)"
if ! grep -Fq 'already installed: fixture-go' <<< "$output" || [[ -s "$fixture/installs" ]]; then
  fail "GOBIN executable outside PATH must be skipped without reinstalling"
  printf '%s\n' "$output" >&2
  exit 1
fi
ok "installed Go executable outside PATH is not reinstalled"
cp "$fixture/gobin/fixture-go" "$fixture/gopath/bin/fixture-go"
output="$(INVENTORY_TEST_GO_STATE=gopath run_fixture "$installer" --apply 2>&1)"
if ! grep -Fq 'already installed: fixture-go' <<< "$output" || [[ -s "$fixture/installs" ]]; then
  fail "GOPATH executable outside PATH must also be skipped"
  exit 1
fi
mv "$fixture/gobin" "$fixture/saved-gobin"
: > "$fixture/gobin"
if output="$(run_fixture "$installer" --apply 2>&1)" || [[ -s "$fixture/installs" ]] \
  || ! grep -Fq 'go_install inventory unavailable' <<< "$output"; then
  fail "an uninspectable Go bin location must not trigger installation"
  exit 1
fi
rm "$fixture/gobin"
mv "$fixture/saved-gobin" "$fixture/gobin"
ok "GOPATH presence and uninspectable Go bin locations are handled safely"

# #305: a copy only on PATH (e.g. in a toolchain dir that used to be GOBIN)
# is not "installed": the Go bin dir is, so the installer puts it there.
mv "$fixture/gobin/fixture-go" "$fixture/saved-fixture-go"
printf '#!/bin/sh\nexit 0\n' > "$fixture/bin/fixture-go"
chmod +x "$fixture/bin/fixture-go"
: > "$fixture/installs"
output="$(run_fixture "$installer" --apply 2>&1)"
if ! grep -Fxq 'go install example.invalid/fixture/cli@latest' "$fixture/installs" \
  || grep -Fq 'already installed: fixture-go' <<< "$output"; then
  fail "a Go executable only on PATH (outside the Go bin dir) must be installed into the Go bin dir"
  printf '%s\n' "$output" >&2
  exit 1
fi
rm "$fixture/bin/fixture-go"
mv "$fixture/saved-fixture-go" "$fixture/gobin/fixture-go"
: > "$fixture/installs"
ok "a Go executable only on PATH (outside the Go bin dir) is installed into the Go bin dir"

for mode in dry-run apply; do
  args=("$installer")
  [[ "$mode" = apply ]] && args+=(--apply)
  if output="$(INVENTORY_TEST_STATE=fail run_fixture "${args[@]}" 2>&1)"; then
    fail "inventory errors must fail the installer ($mode)"
    exit 1
  else
    inventory_exit=$?
  fi
  if [[ "$inventory_exit" -ne 1 ]] || ! grep -Fq 'query failed (exit 42)' <<< "$output" \
    || ! grep -Fq "run 'npm ls -g --depth=0' manually" <<< "$output" \
    || grep -Fq 'FIXTURE_NPM_PRIVATE_DIAGNOSTIC' <<< "$output"; then
    fail "npm failure must report its exit code and fixed hint without raw diagnostics ($mode)"
    exit 1
  fi
  if [[ -s "$fixture/installs" ]] || ! grep -Fq '0 skipped, 5 failed' <<< "$output" \
    || grep -Fq 'would install:' <<< "$output"; then
    fail "unknown inventory must never plan or perform installs ($mode)"
    printf '%s\n' "$output" >&2
    exit 1
  fi
done
ok "failed inventories prevent dry-run plans and --apply installs for all sources"
for state in malformed wrong-shape; do
  if output="$(INVENTORY_TEST_STATE="$state" run_fixture "$installer" --apply 2>&1)" \
    || [[ -s "$fixture/installs" ]] || ! grep -Fq 'npm_global inventory unavailable' <<< "$output"; then
    fail "invalid npm inventory must not trigger an install ($state)"
    exit 1
  fi
done
ok "npm parse and shape errors remain unknown"

output="$(INVENTORY_TEST_STATE=fail run_fixture bash -c \
  'set -euo pipefail; source "$1"; report_catalog_drift' _ "$fixture/repo/scripts/lib-policy.sh" 2>&1)"
for source in brew_formula brew_leaves brew_cask npm_global go_install mas; do
  if ! grep -Fq "catalog inventory INCOMPLETE: $source" <<< "$output"; then
    fail "drift must disclose the failed $source inventory"
    exit 1
  fi
done
if grep -Eq 'no catalog drift|not installed:|undeclared:' <<< "$output"; then
  fail "failed inventory must not become a clean or absent/sprawl report"
  exit 1
fi
ok "catalog drift stays exit 0 and reports INCOMPLETE for failed sources"
output="$(INVENTORY_TEST_STATE=partial run_fixture bash -c \
  'set -euo pipefail; source "$1"; report_catalog_drift' _ "$fixture/repo/scripts/lib-policy.sh" 2>&1)"
if ! grep -Fq 'catalog inventory INCOMPLETE: brew_formula' <<< "$output" \
  || ! grep -Fq 'not installed: fixture-npm' <<< "$output" \
  || grep -Eq 'not installed: fixture-formula|no catalog drift' <<< "$output"; then
  fail "a failed source must not suppress successful sources or become clean"
  exit 1
fi
ok "catalog drift continues inspecting successful sources after a probe failure"
# #329: the inventories and declared sets live in variables, so a run creates
# no temp file an interrupt (Ctrl-C while brew / npm answer) could leave
# behind. A normal run used to clean its files up, so the fixture's mktemp
# is swapped for one that leaves a marker and fails, and TMPDIR (an empty
# fixture dir) must stay empty; the drift report must still see every
# source.
mkdir "$fixture/tmpdir"
rm "$fixture/bin/mktemp"
printf '#!/bin/sh\n: > "$INVENTORY_TEST_ROOT/mktemp-called"\nexit 1\n' > "$fixture/bin/mktemp"
chmod +x "$fixture/bin/mktemp"
output="$(TMPDIR="$fixture/tmpdir" run_fixture bash -c \
  'set -euo pipefail; source "$1"; report_catalog_drift' _ "$fixture/repo/scripts/lib-policy.sh" 2>&1)" || true
rm "$fixture/bin/mktemp"
ln -s "$(command -v mktemp)" "$fixture/bin/mktemp"
for drift_name in fixture-formula:brew_formula fixture-cask:brew_cask fixture-npm:npm_global fixture-go:go_install fixture-mas:mas; do
  if ! grep -Fxq "[ok] installed: ${drift_name%%:*} (${drift_name#*:})" <<< "$output"; then
    printf '%s\n' "$output" >&2
    fail "catalog drift must report ${drift_name%%:*} installed from the fixture inventories"
    exit 1
  fi
done
if ! grep -Fxq '[ok] no catalog drift' <<< "$output" || [[ -e "$fixture/mktemp-called" ]] \
  || [[ -n "$(ls -A "$fixture/tmpdir")" ]]; then
  printf '%s\n' "$output" >&2
  ls -A "$fixture/tmpdir" >&2
  fail "catalog drift must not call mktemp, must leave TMPDIR empty and report no drift for a matching inventory"
  exit 1
fi
ok "catalog drift writes no temp file (inventories held in variables)"

rm "$fixture/gobin/fixture-go"
output="$(INVENTORY_TEST_STATE=empty run_fixture "$installer" 2>&1)"
if ! grep -Fq '5 would be installed' <<< "$output" || [[ -s "$fixture/installs" ]]; then
  fail "successful empty inventories must plan installs without side effects"
  exit 1
fi
output="$(INVENTORY_TEST_STATE=empty run_fixture "$installer" --apply 2>&1)"
if ! grep -Fq '5 installed, 0 skipped, 0 failed' <<< "$output" \
  || [[ "$(awk 'END { print NR }' "$fixture/installs")" != 5 ]]; then
  fail "successful empty inventories must reach all five fake installers"
  exit 1
fi
ok "confirmed absence still permits installation (fake managers only)"
# #329: the catalog rows are not the probes' and installers' stdin. With
# fakes that read their stdin to the end on every call, all five entries are
# still probed and installed; before, the first call swallowed the remaining
# rows and the run closed as "1 installed, 0 skipped, 0 failed".
: > "$fixture/installs"
output="$(INVENTORY_TEST_STATE=empty INVENTORY_TEST_READ_STDIN=1 run_fixture "$installer" --apply 2>&1 </dev/null)"
if ! grep -Fq '5 installed, 0 skipped, 0 failed' <<< "$output" \
  || [[ "$(awk 'END { print NR }' "$fixture/installs")" != 5 ]]; then
  printf '%s\n' "$output" >&2
  fail "a probe or installer that reads its stdin must not swallow the remaining catalog rows"
  exit 1
fi
ok "catalog rows reach every entry even when the managers read their stdin"

# #333: docs が約束する installer の契約を、installer 本体の経路で固定する:
# track-only / manual の entry は inventory のみで install しない、manager が PATH に
# 無い source は warn して skip (exit 0)、install の失敗は計上・報告して run を exit 1
# にする (他の entry は install される)。ここから先の fixture catalog は track-only の
# 2 entry を足した 7 entry。npm は最初の run の間だけ fixture の PATH から外す。
cat >> "$fixture/repo/.chezmoidata/packages.yaml" <<'YAML'
  - {name: fixture-tracked, source: brew_formula, track_only: true}
  - {name: fixture-manual, source: manual}
YAML
mv "$fixture/bin/npm" "$fixture/saved-npm"
: > "$fixture/installs"
if ! output="$(INVENTORY_TEST_STATE=empty run_fixture "$installer" --apply 2>&1)" \
  || ! grep -Fxq '[info] - skip fixture-tracked: track-only (brew_formula)' <<< "$output" \
  || ! grep -Fxq '[info] - skip fixture-manual: track-only (manual)' <<< "$output" \
  || ! grep -Fxq '[warn] skip fixture-npm: manager for npm_global not on PATH (runtime not ready?)' <<< "$output" \
  || ! grep -Fxq '[ok] done: 4 installed, 3 skipped, 0 failed' <<< "$output" \
  || grep -Eq 'fixture-tracked|fixture-manual|^npm ' "$fixture/installs" \
  || [[ "$(awk 'END { print NR }' "$fixture/installs")" != 4 ]]; then
  printf '%s\n' "$output" >&2
  fail "track-only / manual entries and a source without its manager must be skipped (exit 0) while the rest install"
  exit 1
fi
mv "$fixture/saved-npm" "$fixture/bin/npm"
ok "track-only / manual entries and a manager-less source are skipped, never installed"
: > "$fixture/installs"
if output="$(INVENTORY_TEST_STATE=empty INVENTORY_TEST_INSTALL_FAIL=mas run_fixture "$installer" --apply 2>&1)"; then
  fail "a failed install must fail the installer"
  exit 1
else
  install_exit=$?
fi
if [[ "$install_exit" -ne 1 ]] || ! grep -Fxq '[warn] install failed: fixture-mas (mas)' <<< "$output" \
  || ! grep -Fxq '[ok] done: 4 installed, 2 skipped, 1 failed' <<< "$output" \
  || [[ "$(awk 'END { print NR }' "$fixture/installs")" != 5 ]]; then
  printf '%s\n' "$output" >&2
  fail "a failed install must be counted, reported and exit 1 while the other entries still install"
  exit 1
fi
ok "a failed install is reported, counted and fails the run after the other entries install"
