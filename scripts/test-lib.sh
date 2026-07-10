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
# set_capability_all (above) is the all-profile, fail-closed variant with
# a different contract (test-policy.sh pins that contract).
flip_personal_capability() {
  local src="$1" cap="$2" value="$3"
  C="$cap" V="$value" yq -i \
    '.profiles.personal.capabilities[strenv(C)] = env(V)' \
    "$src/.chezmoidata/profiles.yaml"
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
