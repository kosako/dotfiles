#!/usr/bin/env bash
set -euo pipefail

# Inventory regressions (#205/#209/#213), reached by test-install-packages.sh.
# Only fake managers are on PATH. Installs and attempted toolchain downloads
# become fixture markers; no real manager or user configuration is consulted.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-inventory-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/repo/scripts" "$fixture/repo/.chezmoidata" \
  "$fixture/gobin" "$fixture/gopath/bin" "$fixture/caller"
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
manager="${0##*/}"
if [ "$1" = install ]; then
  printf '%s %s\n' "$manager" "$*" >> "$INVENTORY_TEST_ROOT/installs"
  exit 0
fi
if [ "${INVENTORY_TEST_STATE:-present}" = fail ]; then
  # A partially printed inventory with a failure is still unknown.
  [ "$manager" = npm ] && printf '{"dependencies":{"partial-entry":{}}}\n'
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
    env PATH="$fixture/bin" INVENTORY_TEST_ROOT="$fixture" \
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

for mode in dry-run apply; do
  args=("$installer")
  [[ "$mode" = apply ]] && args+=(--apply)
  if output="$(INVENTORY_TEST_STATE=fail run_fixture "${args[@]}" 2>&1)"; then
    fail "inventory errors must fail the installer ($mode)"
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
