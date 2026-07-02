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
