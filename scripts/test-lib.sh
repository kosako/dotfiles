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

# render_personal_into SOURCE_DIR ROOT
# Apply the personal profile from SOURCE_DIR into ROOT/home (writes
# ROOT/chezmoi.toml; requires chezmoi — render tests check for it upfront).
# ROOT is created by the CALLER and registered in tmp_roots there: a helper
# that mktemps and returns via command substitution would append to
# tmp_roots only inside the substitution subshell, so the cleanup trap
# would never see it and the render roots would leak (Codex review, #150).
render_personal_into() {
  local source_dir="$1" root="$2"
  mkdir -p "$root/home"
  printf '[data]\nprofile = "personal"\n' > "$root/chezmoi.toml"
  chezmoi --config "$root/chezmoi.toml" \
    --source "$source_dir" --destination "$root/home" apply >/dev/null 2>&1
}

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

# kill_tree PID — KILL PID and its descendants. Each process is stopped
# (SIGSTOP) before its children are listed, so it cannot start another one
# while the tree is walked (a wrapper that starts a new child when one ends
# would otherwise get past the listing; Codex review R1, PR #419); the kill
# then goes bottom-up.
kill_tree() {
  local child
  kill -STOP "$1" 2>/dev/null || true
  for child in $(pgrep -P "$1" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill -KILL "$1" 2>/dev/null || true
}

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
# background cases start theirs, lists their PIDs and the fixture dir in the
# cue, and waits. One is a `set -m` job (`sh` with a `sleep` under it); the
# other a plain background job: a wrapper with two `sleep`s that starts a
# third when the first ends, so a cleanup that lets it run while the tree is
# walked leaves the new one behind. check_suite_interrupt then sends the run
# TERM and succeeds when all five listed processes were alive before it, the
# run ended by TERM, none is left (nor a sixth one) and the fixture dir is
# gone; otherwise it prints what it saw and fails. Everything it makes,
# the inner run's fixture included (its TMPDIR), is under DIR, the calling
# suite's fixture, so an interrupt of the calling suite removes it too
# (Codex review R2, PR #419).
suite_interrupt_inner() {
  local cue="$1" t
  printf 'fixture %s\n' "$2" >> "$cue"
  set -m
  sh -c 'sleep 300 & printf "pid %s\n" "$!" >> "$1"; wait' suite-interrupt "$cue" &
  printf 'pid %s\n' "$!" >> "$cue"
  set +m
  sh -c '
    sleep 300 & a=$!
    sleep 300 & b=$!
    printf "pid %s\npid %s\n" "$a" "$b" >> "$1"
    wait "$a"
    sleep 300 &
    printf "pid %s\n" "$!" >> "$1"
    wait' suite-interrupt "$cue" &
  printf 'pid %s\n' "$!" >> "$cue"
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
  local suite="$1" dir pid t rc=0 kind value fixture="" listed="" count=0 dead_before="" left="" ready=0
  dir="$(mktemp -d "$2/suite-interrupt.XXXXXX")"
  shift 2
  mkdir "$dir/tmp"
  env "$@" TMPDIR="$dir/tmp" SUITE_INTERRUPT_CUE="$dir/cue" "$BASH" "$suite" > "$dir/log" 2>&1 < /dev/null &
  pid=$!
  for ((t = 0; t < 600; t++)); do
    grep -qx ready "$dir/cue" 2>/dev/null && { ready=1; break; }
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if [[ "$ready" -eq 1 ]]; then
    for value in $(sed -n 's/^pid //p' "$dir/cue"); do
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
  while read -r kind value; do
    case "$kind" in
      pid) listed+=" $value"; count=$((count + 1)) ;;
      fixture) fixture="$value" ;;
    esac
  done < <(cat "$dir/cue" 2>/dev/null || true)
  # A KILLed process is a zombie until its parent (or init, once the parent
  # is gone) reaps it, and kill -0 still finds a zombie: give that a moment.
  for ((t = 0; t < 50; t++)); do
    left=""
    for value in $listed; do
      kill -0 "$value" 2>/dev/null && left+=" $value"
    done
    [[ -n "$left" ]] || break
    sleep 0.1
  done
  for value in $left; do
    kill_tree "$value"
  done
  if [[ "$ready" -eq 1 && -z "$dead_before" && "$rc" -eq 143 && "$count" -eq 5 && -z "$left" \
    && -n "$fixture" && ! -e "$fixture" ]]; then
    rm -rf "$dir"
    return 0
  fi
  printf 'ready=%s dead before TERM:%s rc=%s listed (%s):%s left:%s fixture=%s (exists: %s)\n' \
    "$ready" "${dead_before:- none}" "$rc" "$count" "$listed" "${left:- none}" "${fixture:-<none>}" \
    "$([[ -n "$fixture" && -e "$fixture" ]] && echo yes || echo no)" >&2
  cat "$dir/log" >&2 2>/dev/null || true
  chmod -R u+rwX "$dir" 2>/dev/null || true
  rm -rf "$dir"
  return 1
}
