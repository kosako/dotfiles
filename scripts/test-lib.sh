# shellcheck shell=bash
# Shared helpers for the scripts/test-*.sh suite. Source this AFTER
# lib-policy.sh (it uses the ok/fail reporters). Source-only, not executable.
#
# Why these exist (#149): capability flips previously used raw
# `awk '$0 == "      cap: false" ...'` full-line matching copied into each
# test. Unlike insert_once/replace_once, those copies had no
# `END { if (!done) exit 1 }` guard, so any change to the profiles.yaml line
# shape (indent, key rename) silently turned the flip into a no-op — and the
# following assertion kept passing against the UNFLIPPED fixture (vacuous
# pass). Notably the "must not be forbidden" polarity regressions for
# enforceAiSandbox / gateGitHubMcp were in that fail-open shape. These
# helpers edit the YAML structurally via yq and fail closed when the target
# does not exist.

# set_capability_all ROOT CAP VALUE
# Set CAP to VALUE for every profile in ROOT/.chezmoidata/profiles.yaml.
# All-profiles on purpose: the flip sites want fixtures independent of any
# profile's real default (and of which profile is listed first). VALUE is
# parsed as YAML, so true/false stay booleans and enum values stay strings.
# Fails when any profile does not declare CAP (a typo'd capability would
# otherwise no-op silently — the exact failure mode this replaces).
set_capability_all() {
  local root="$1" cap="$2" value="$3"
  local file="$root/.chezmoidata/profiles.yaml"
  if [[ ! -f "$file" ]]; then
    fail "set_capability_all: missing $file"
    return 1
  fi
  # Two separate probes on purpose: combining them with yq's `and` mis-parses
  # (pipe binds loosest, the has-check leaks out of the conjunction). The
  # count probe guards the vacuous-true case — `[] | all` is true, so an
  # empty/missing profiles map would otherwise pass the has-check and the
  # assignment below would silently no-op, the same failure mode this helper
  # exists to prevent (Codex review, #149).
  local count declared
  count="$(yq '.profiles // {} | length' "$file")"
  declared="$(C="$cap" yq '[.profiles[].capabilities | has(strenv(C))] | all' "$file")"
  if [[ -z "$count" || "$count" == "0" || "$declared" != "true" ]]; then
    fail "set_capability_all: capability '$cap' is not declared by every profile in $file"
    return 1
  fi
  C="$cap" V="$value" yq -i '.profiles[].capabilities[strenv(C)] = env(V)' "$file"
}

# remove_module_all ROOT MODULE
# Remove MODULE from every profile's modules list in
# ROOT/.chezmoidata/profiles.yaml. Fails when no profile lists MODULE (a
# typo would otherwise no-op silently).
remove_module_all() {
  local root="$1" module="$2"
  local file="$root/.chezmoidata/profiles.yaml"
  if [[ ! -f "$file" ]]; then
    fail "remove_module_all: missing $file"
    return 1
  fi
  local count
  count="$(M="$module" yq '[.profiles[].modules[] | select(. == strenv(M))] | length' "$file")"
  if [[ -z "$count" || "$count" == "0" ]]; then
    fail "remove_module_all: module '$module' is not listed by any profile in $file"
    return 1
  fi
  M="$module" yq -i 'del(.profiles[].modules[] | select(. == strenv(M)))' "$file"
}

# render_profile_into SOURCE_DIR ROOT PROFILE
# render_personal_into SOURCE_DIR ROOT (the same with PROFILE personal)
# Apply PROFILE from SOURCE_DIR into ROOT/home (writes ROOT/chezmoi.toml;
# requires chezmoi — render tests check for it upfront).
# ROOT is created by the CALLER and registered in tmp_roots there: a helper
# that mktemps and returns via command substitution would append to
# tmp_roots only inside the substitution subshell, so the cleanup trap
# would never see it and the render roots would leak (Codex review, #150).
# ROOT/home may be pre-seeded by the caller (mkdir -p, never recreated), so
# a test can check that apply leaves the files next to a target alone.
# chezmoi's home directory (.chezmoi.homeDir) follows HOME: a caller that
# needs another one writes `HOME=... render_profile_into ...`.
render_profile_into() {
  local source_dir="$1" root="$2" profile="$3"
  mkdir -p "$root/home"
  printf '[data]\nprofile = "%s"\n' "$profile" > "$root/chezmoi.toml"
  chezmoi --config "$root/chezmoi.toml" \
    --source "$source_dir" --destination "$root/home" apply >/dev/null 2>&1
}
render_personal_into() { render_profile_into "$1" "$2" personal; }

# make_flipped_source DEST_PARENT
# Copy the committed source into DEST_PARENT/src (dropping .git) so a test
# can flip capabilities without touching the real data files. DEST_PARENT
# is created and registered for cleanup by the caller. Call as a plain
# statement, never inside $(...) (the subshell would hide caller-side
# cleanup registration — same trap as render_personal_into).
make_flipped_source() {
  local dest_parent="$1"
  cp -R "$DOTFILES_ROOT" "$dest_parent/src"
  rm -rf "$dest_parent/src/.git"
}

# flip_personal_capability SRC CAP VALUE
# Set CAP to VALUE for the personal profile only, in
# SRC/.chezmoidata/profiles.yaml (SRC is a make_flipped_source copy).
# Boolean capabilities only: env(V) parses true/false into booleans; an
# enum-valued capability would need strenv. Personal-only on purpose —
# set_capability_all (above) is the all-profile variant with a different
# contract. Fails when the personal profile does not declare CAP (#332): a
# typo'd capability would otherwise add a new key and the following
# assertion would pass against an effectively unflipped render — the same
# fail-closed rule as set_capability_all (test-policy.sh pins both). The
# `// {}` keeps has() from erroring when the profile or its capabilities
# map is missing, so those cases fail here instead of in yq.
flip_personal_capability() {
  local src="$1" cap="$2" value="$3"
  local file="$src/.chezmoidata/profiles.yaml"
  if [[ ! -f "$file" ]]; then
    fail "flip_personal_capability: missing $file"
    return 1
  fi
  local declared
  declared="$(C="$cap" yq '.profiles.personal.capabilities // {} | has(strenv(C))' "$file")"
  if [[ "$declared" != "true" ]]; then
    fail "flip_personal_capability: capability '$cap' is not declared by the personal profile in $file"
    return 1
  fi
  C="$cap" V="$value" yq -i \
    '.profiles.personal.capabilities[strenv(C)] = env(V)' \
    "$file"
}

# copy_repo_fixture DEST
# Minimal repo-copy fixture: scripts/ plus the .chezmoidata data files —
# just enough for doctor / preflight / validate-policy to run against
# DEST. mktemp, cleanup registration, and any per-case fixture mutation
# (capability flips, extra files) stay with the caller. No output.
copy_repo_fixture() {
  local dest="$1"
  mkdir -p "$dest/.chezmoidata"
  cp -R "$DOTFILES_ROOT/scripts" "$dest/scripts"
  cp "$DOTFILES_ROOT/.chezmoidata/"*.yaml "$dest/.chezmoidata/"
}

# shell_single_quote VALUE — VALUE in single quotes, each ' written as '\''.
# shell_word VALUE — VALUE as .chezmoitemplates/shell-word renders a path into
# a command string: unchanged when it holds only plain characters, else
# single-quoted (#329). For expected command strings built from the host's
# $HOME, so a home with a space or a quote does not break the comparison.
# sed, not ${VALUE//...}: bash 3.2 keeps quotes and backslashes of the
# replacement string literally.
shell_single_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
shell_word() {
  local re='^[A-Za-z0-9_@%+=:,./-]+$'
  if [[ "$1" =~ $re ]]; then
    printf '%s' "$1"
  else
    shell_single_quote "$1"
  fi
}

# set_environment_kind ROOT PROFILE KIND
# Retag PROFILE in ROOT/.chezmoidata/profiles.yaml to environmentKind KIND,
# for the rows of the forbidden table that have no profile of their own
# (client / sandbox / agent) and for an unknown kind (#357). Fails, leaving
# the file as it was, when PROFILE is not defined or carries no
# environmentKind: a typo would otherwise add a new profile, and the
# assertion would run against the untouched one (the same fail-closed rule
# as set_capability_all; test-secrets-gate.sh pins it). KIND is written as a
# string.
set_environment_kind() {
  local root="$1" profile="$2" kind="$3"
  local file="$root/.chezmoidata/profiles.yaml"
  if [[ ! -f "$file" ]]; then
    fail "set_environment_kind: missing $file"
    return 1
  fi
  if [[ "$(P="$profile" yq '.profiles // {} | has(strenv(P))' "$file")" != "true" ]] ||
    [[ "$(P="$profile" yq '.profiles[strenv(P)] | has("environmentKind")' "$file")" != "true" ]]; then
    fail "set_environment_kind: profile '$profile' with an environmentKind is not defined in $file"
    return 1
  fi
  P="$profile" K="$kind" yq -i '.profiles[strenv(P)].environmentKind = strenv(K)' "$file"
}

# kill_tree (KILL a PID and its descendants, stopping each before listing
# its children) lives in lib-policy.sh, shared with doctor's probe cleanup
# (#423).

# stop_child_trees — KILL every process this shell started and has not
# reaped, with its descendants, then reap them. For a suite's cleanup (#413):
# a background case (a `set -m` job sits in its own process group, and a
# background job of a non-interactive shell ignores INT) does not get the
# signal that interrupts the suite, and would go on using the fixture the
# cleanup removes. All children, not a PID a case registered: a case that
# forgot to register was the gap.
stop_child_trees() {
  local child children
  children="$(pgrep -P "$$" 2>/dev/null || true)"
  for child in $children; do
    kill_tree "$child"
  done
  for child in $children; do
    wait "$child" 2>/dev/null || true
  done
}

# Suite interrupt check (#413). check_suite_interrupt SUITE DIR [NAME=VALUE...]
# re-runs SUITE (with the extra env) and SUITE_INTERRUPT_CUE naming a cue
# file. The suite calls suite_interrupt_inner right after it sets its traps
# when SUITE_INTERRUPT_CUE is set: that starts two trees the way the
# background cases start theirs, lists each process as "pid PID ROLE" in the
# cue, and waits.
# - A `set -m` job: `sh` (job) with a `sleep` (job-sleep) under it.
# - A plain background job: a wrapper with two `sleep`s (a, b) that starts a
#   third (c) when a ends and lists it. A pgrep shim first on the run's PATH
#   makes that race certain instead of timing-dependent: it lists the
#   wrapper's children a first, and before it answers for b's children it
#   waits (up to 5 s) until the wrapper is stopped or c is listed, and notes
#   in the cue which of the two it saw ("sync ok") or that it gave up ("sync
#   timeout"). A cleanup that lets the wrapper run while the tree is walked
#   therefore always leaves c behind; one that stops it first never sees c;
#   a run that never reached the point, or gave up there, fails the check.
# Every `sleep` runs for a duration unique to the check (matched whole, the
# dot literal), so one that was started but never listed is found too
# (pgrep -f). Before the trees, the inner run's fixture gets a directory
# without any permission that holds a file, as a case that takes a
# permission away (a mode-000 file or directory, a directory without search
# permission; both suites have such cases) leaves it when the run is
# interrupted inside that window (#440): rm -rf alone cannot remove it, so
# the fixture goes only when the cleanup opens the modes first. It is listed
# ("locked PATH") only where the mode binds (the file cannot be seen through
# it); as root it does not, and that part is skipped. check_suite_interrupt then sends the run TERM and succeeds
# when five different listed processes were alive before it, the run ended
# by TERM, the sync point was passed, the locked directory was listed (unless
# root), no process of the check is left and the fixture dir is gone;
# otherwise it prints what it saw and fails. Everything it makes, the inner
# run's fixture included (its TMPDIR), is under DIR, the calling suite's
# fixture, so an interrupt of the calling suite removes it too.
suite_interrupt_inner() {
  local cue="$1" t
  printf 'fixture %s\n' "$2" >> "$cue"
  mkdir "$2/suite-interrupt-locked"
  printf 'locked\n' > "$2/suite-interrupt-locked/file"
  chmod 000 "$2/suite-interrupt-locked"
  [[ -e "$2/suite-interrupt-locked/file" ]] || printf 'locked %s\n' "$2/suite-interrupt-locked" >> "$cue"
  set -m
  sh -c 'sleep "$2" & printf "pid %s job-sleep\n" "$!" >> "$1"; wait' suite-interrupt "$cue" "$SUITE_INTERRUPT_SLEEP" &
  printf 'pid %s job\n' "$!" >> "$cue"
  set +m
  sh -c '
    sleep "$2" & a=$!
    sleep "$2" & b=$!
    printf "pid %s a\npid %s b\n" "$a" "$b" >> "$1"
    wait "$a"
    sleep "$2" &
    printf "pid %s c\n" "$!" >> "$1"
    wait' suite-interrupt "$cue" "$SUITE_INTERRUPT_SLEEP" &
  printf 'pid %s wrapper\n' "$!" >> "$cue"
  for ((t = 0; t < 600; t++)); do
    if [[ "$(grep -c '^pid ' "$cue")" -ge 5 ]]; then
      printf 'ready\n' >> "$cue"
      break
    fi
    sleep 0.05
  done
  wait
  exit 1
}

check_suite_interrupt() {
  local suite="$1" dir pid t rc=0 kind value role fixture="" listed="" distinct=0 dead_before="" left="" ready=0 locked=""
  local sleep_digits="$RANDOM$RANDOM$RANDOM$RANDOM" sleep_for sleep_match strays line sync=""
  sleep_for="3000.$sleep_digits"
  sleep_match="^sleep 3000[.]$sleep_digits\$"
  dir="$(mktemp -d "$2/suite-interrupt.XXXXXX")"
  shift 2
  mkdir "$dir/tmp" "$dir/shim"
  cat > "$dir/shim/pgrep" <<'SH'
#!/bin/sh
# pgrep shim of the suite interrupt check (test-lib.sh): see there.
role() { sed -n "s/^pid \([0-9]*\) $1\$/\1/p" "$SUITE_INTERRUPT_CUE"; }
if [ "$1" = -P ] && [ "$#" -eq 2 ]; then
  w="$(role wrapper)" a="$(role a)" b="$(role b)"
  if [ -n "$w" ] && [ "$2" = "$w" ]; then
    kids="$("$SUITE_INTERRUPT_PGREP" -P "$2")"
    for k in $kids; do [ "$k" = "$a" ] && printf '%s\n' "$k"; done
    for k in $kids; do [ "$k" != "$a" ] && printf '%s\n' "$k"; done
    exit 0
  fi
  if [ -n "$b" ] && [ "$2" = "$b" ]; then
    i=0
    sync=timeout
    while [ "$i" -lt 100 ]; do
      st="$(LC_ALL=C ps -o stat= -p "$w" 2>/dev/null | tr -d ' ')"
      case "$st" in
        T* | Z*) sync=ok; break ;;
      esac
      if [ -z "$st" ] && ! kill -0 "$w" 2>/dev/null; then sync=ok; break; fi
      if [ -n "$(role c)" ]; then sync=ok; break; fi
      sleep 0.05
      i=$((i + 1))
    done
    printf 'sync %s\n' "$sync" >> "$SUITE_INTERRUPT_CUE"
  fi
fi
exec "$SUITE_INTERRUPT_PGREP" "$@"
SH
  chmod +x "$dir/shim/pgrep"
  env "$@" TMPDIR="$dir/tmp" SUITE_INTERRUPT_CUE="$dir/cue" SUITE_INTERRUPT_SLEEP="$sleep_for" \
    SUITE_INTERRUPT_PGREP="$(command -v pgrep)" PATH="$dir/shim:$PATH" \
    "$BASH" "$suite" > "$dir/log" 2>&1 < /dev/null &
  pid=$!
  for ((t = 0; t < 600; t++)); do
    grep -qx ready "$dir/cue" 2>/dev/null && { ready=1; break; }
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if [[ "$ready" -eq 1 ]]; then
    distinct="$(sed -n 's/^pid \([0-9]*\) .*/\1/p' "$dir/cue" | sort -u | grep -c .)"
    for value in $(sed -n 's/^pid \([0-9]*\) .*/\1/p' "$dir/cue"); do
      kill -0 "$value" 2>/dev/null || dead_before+=" $value"
    done
  fi
  # bash 3.2 reports a job that a signal ended ("Terminated: 15") on stderr
  # when it reaps it; that is the expected end here, so it is not shown.
  {
    kill -TERM "$pid" || true
    for ((t = 0; t < 300; t++)); do
      kill -0 "$pid" || break
      sleep 0.1
    done
    kill -0 "$pid" && kill_tree "$pid"
    wait "$pid" || rc=$?
  } 2>/dev/null
  while IFS= read -r line; do
    case "$line" in
      'pid '*)
        read -r kind value role <<< "$line"
        listed+=" $value:$role"
        ;;
      'fixture '*) fixture="${line#fixture }" ;;
      'locked '*) locked="${line#locked }" ;;
      'sync '*) sync+="${line#sync } " ;;
    esac
  done < <(cat "$dir/cue" 2>/dev/null || true)
  # A KILLed process is a zombie until its parent (or init, once the parent
  # is gone) reaps it, and kill -0 still finds a zombie: give that a moment.
  for ((t = 0; t < 50; t++)); do
    left=""
    for value in $listed; do
      kill -0 "${value%%:*}" 2>/dev/null && left+=" $value"
    done
    strays="$(pgrep -f "$sleep_match" 2>/dev/null | tr '\n' ' ' || true)"
    [[ -n "$left" || -n "${strays// /}" ]] || break
    sleep 0.1
  done
  for value in $left; do
    kill_tree "${value%%:*}"
  done
  pkill -KILL -f "$sleep_match" 2>/dev/null || true
  if [[ "$ready" -eq 1 && "$distinct" -eq 5 && -z "$dead_before" && "$rc" -eq 143 && "$sync" == "ok " && -z "$left" \
    && -z "${strays// /}" && -n "$fixture" && ! -e "$fixture" ]] && [[ -n "$locked" || "$(id -u)" == 0 ]]; then
    rm -rf "$dir"
    return 0
  fi
  printf 'ready=%s distinct=%s dead before TERM:%s rc=%s sync=%s listed:%s left:%s strays: %s fixture=%s (exists: %s) locked=%s\n' \
    "$ready" "$distinct" "${dead_before:- none}" "$rc" "${sync:-<none>}" "$listed" "${left:- none}" "${strays:-none}" "${fixture:-<none>}" \
    "$([[ -n "$fixture" && -e "$fixture" ]] && echo yes || echo no)" "${locked:-<none>}" >&2
  cat "$dir/log" >&2 2>/dev/null || true
  chmod -R u+rwX "$dir" 2>/dev/null || true
  rm -rf "$dir"
  return 1
}
