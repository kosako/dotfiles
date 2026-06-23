#!/usr/bin/env bash
set -euo pipefail

# Gating + safety test for the ssh-1password module (issue #17). The managed
# ~/.ssh/config is applied for the personal profile (module membership), and the
# 1Password SSH agent setting inside it is gated by enable1PasswordSSH. Both the
# on and off capability states are exercised (off is forced in a throwaway
# source copy so the test is independent of the committed default). The test
# also fixes the safety contract: the managed config carries no host names, no
# keys, and never an agent/forwarding setting on Host * (machine-specific hosts
# live in the Include'd ~/.ssh/config.local; see docs/ssh.md).
# Renders into throwaway destinations; never touches the real home directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

require_yq || exit 1

if ! command -v chezmoi >/dev/null 2>&1; then
  fail "chezmoi not found; render tests require it"
  exit 1
fi

status=0

# One throwaway base dir holds every source copy and rendered home, so cleanup
# is a single rm and nothing leaks. Created in this (parent) scope on purpose:
# mktemp inside a $(...) helper would run in a subshell and never be cleaned.
base="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-ssh.XXXXXX")"
cleanup() {
  rm -rf "$base"
}
trap cleanup EXIT

# Apply the personal profile from $1 into a fresh home under root $2, and echo
# the rendered home path. Each call gets its own root (config + home) under base.
apply_personal() {
  local source_dir="$1" root="$2"
  mkdir -p "$root/home"
  printf '[data]\nprofile = "personal"\n' > "$root/chezmoi.toml"
  chezmoi --config "$root/chezmoi.toml" \
    --source "$source_dir" --destination "$root/home" apply >/dev/null 2>&1
}

section "ssh-1password gating"

# 1) enable1PasswordSSH=true: managed config carries the 1Password agent for
#    github.com (scoped) and the local Include. personal's committed default is
#    true, so render from the real source.
on_root="$base/on"
if ! apply_personal "$DOTFILES_ROOT" "$on_root"; then
  fail "test failed: personal apply (enable1PasswordSSH=true) did not render"
  exit 1
fi
on_cfg="$on_root/home/.ssh/config"
if [[ ! -f "$on_cfg" ]]; then
  fail "test failed: ~/.ssh/config not applied for personal (module membership)"
  status=1
elif grep -q '^Host github.com$' "$on_cfg" \
  && grep -Fqx '    IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"' "$on_cfg" \
  && grep -q '^Match all$' "$on_cfg" \
  && grep -q '^Include config.local$' "$on_cfg"; then
  ok "test passed: enable1PasswordSSH=true emits scoped github.com agent + Match all + Include config.local"
else
  fail "test failed: enable1PasswordSSH=true config missing github.com agent or Include"
  status=1
fi

# 2) enable1PasswordSSH=false: the config is still applied (module membership),
#    but the agent setting is NOT emitted; the Include escape hatch remains.
#    Force the value in a copy so the test is independent of the committed default.
off_src="$base/off-src"
cp -R "$DOTFILES_ROOT" "$off_src"
rm -rf "$off_src/.git"
yq -i '.profiles.personal.capabilities.enable1PasswordSSH = false' \
  "$off_src/.chezmoidata/profiles.yaml"
off_root="$base/off"
if ! apply_personal "$off_src" "$off_root"; then
  fail "test failed: personal apply (enable1PasswordSSH=false) did not render"
  exit 1
fi
off_cfg="$off_root/home/.ssh/config"
if [[ ! -f "$off_cfg" ]]; then
  fail "test failed: ~/.ssh/config not applied when enable1PasswordSSH=false"
  status=1
elif grep -q 'IdentityAgent' "$off_cfg" || grep -q 'github.com' "$off_cfg"; then
  fail "test failed: agent setting emitted while enable1PasswordSSH=false"
  status=1
elif grep -q '^Include config.local$' "$off_cfg"; then
  ok "test passed: enable1PasswordSSH=false emits no agent setting, keeps Include config.local"
else
  fail "test failed: enable1PasswordSSH=false config missing Include config.local"
  status=1
fi

section "ssh safety contract"

# 3) The managed config must never carry host names, keys, or a broad
#    agent/forwarding setting on Host *. github.com (a public host) is the only
#    allowed Host; everything machine-specific belongs in ~/.ssh/config.local.
if [[ -f "$on_cfg" ]]; then
  host_lines="$(grep -c '^Host ' "$on_cfg" || true)"
  if grep -qE '^Host \*' "$on_cfg"; then
    fail "test failed: managed config has a Host * block (agent/forwarding must not be broad)"
    status=1
  elif grep -q 'ForwardAgent' "$on_cfg"; then
    fail "test failed: managed config sets ForwardAgent (out of scope; never broadly enabled)"
    status=1
  elif grep -q 'IdentityFile' "$on_cfg"; then
    fail "test failed: managed config references a key file (keys are never managed)"
    status=1
  elif [[ "$host_lines" -ne 1 ]]; then
    fail "test failed: managed config has $host_lines Host blocks; only Host github.com is allowed"
    status=1
  else
    ok "test passed: managed config carries no Host *, no keys, only the public github.com host"
  fi
fi

section "ssh -G resolution (Include is global, managed-wins)"

# 4) Behavioral check with the real ssh parser. A text match alone missed the
#    bug where `Include config.local` sat inside the Host github.com block and
#    was only read when connecting to github.com (#121). Point the Include at a
#    throwaway config.local that defines a host the managed config does NOT, and
#    assert ssh resolves it (proves the Include is global) and that github.com
#    still gets the managed agent (proves managed-wins). Relative Include paths
#    resolve under ~/.ssh, so rewrite to an absolute path for an isolated test.
if ! command -v ssh >/dev/null 2>&1; then
  item "ssh not found; skipping ssh -G resolution check"
elif [[ -f "$on_cfg" ]]; then
  probe_local="$base/config.local"
  cat > "$probe_local" <<EOF
Host probe-vm
  HostName 10.9.8.7
  User probeuser
Host *
  IdentityAgent /tmp/probe-local.sock
EOF
  probe_cfg="$base/probe-config"
  sed "s#^Include config.local\$#Include $probe_local#" "$on_cfg" > "$probe_cfg"

  # IdentityAgent paths contain a space ("Group Containers"), so capture the
  # whole value after the keyword rather than a single field.
  probe_host="$(ssh -G -F "$probe_cfg" probe-vm 2>/dev/null | sed -n 's/^hostname //p')"
  gh_agent="$(ssh -G -F "$probe_cfg" github.com 2>/dev/null | sed -n 's/^identityagent //p')"

  if [[ "$probe_host" != "10.9.8.7" ]]; then
    fail "test failed: config.local host not resolved (Include is not global): hostname=$probe_host"
    status=1
  elif [[ "$gh_agent" != *"1password/t/agent.sock" ]]; then
    fail "test failed: github.com did not keep the managed agent (managed-wins broken): identityagent=$gh_agent"
    status=1
  else
    ok "test passed: ssh resolves a config.local-only host (global Include) and github.com keeps the managed agent (managed-wins)"
  fi
fi

if [[ "$status" -eq 0 ]]; then
  ok "ssh tests passed"
fi
exit "$status"
