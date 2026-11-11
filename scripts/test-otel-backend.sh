#!/usr/bin/env bash
set -euo pipefail

# Gating and content tests for the otel-backend module (#514, #517): the
# managed files under ~/.config/otel-lgtm that define the local
# OpenTelemetry backend (grafana/otel-lgtm): the compose file, the extra
# Collector config that archives the raw telemetry, and the Grafana
# dashboard provider and dashboard. They must (1) be applied for personal
# and not for work, (2) carry the managed-by header (the doctor orphan scan
# keys on it; the dashboard, strict JSON, carries it in its description),
# (3) parse with exactly the pinned compose definition, (4) keep the
# properties the compose definition is trusted for whatever the pin says —
# the image fixed by version AND digest, every port published on 127.0.0.1
# only (Grafana answers its API without a login, and Colima forwards a port
# published without an address to every interface of the host), host paths
# reaching the container only through the allowlisted binds (read-only
# ones from the compose file's own directory, and the one writable archive
# directory), every bind failing instead of being created in the VM, and
# none of the keys that widen what the container can touch — (5) keep the
# archive config to added */archive pipelines writing replayable files
# kept for one year, (6) keep the dashboard provider pointed at the bound
# dashboards and closed to UI edits, (7) keep the dashboard on the bundled
# datasources, and (8) land 0644 in 0755 directories. Renders into
# throwaway destinations; never touches the real home and never talks to a
# container runtime.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

require_yq || exit 1

if ! command -v chezmoi >/dev/null 2>&1; then
  fail "chezmoi not found; otel-backend tests require it"
  exit 1
fi

# chezmoi creates targets under the umask of the process that applies.
# Section 5's 0644 / 0755 is what a stock umask gives; pin it so the result
# does not depend on the shell that runs this test (#332 F38).
umask 022

status=0
tmp_roots=()

cleanup() {
  local dir
  for dir in "${tmp_roots[@]:-}"; do
    [[ -n "$dir" ]] && rm -rf "$dir"
  done
}
trap cleanup EXIT

managed_rel=".config/otel-lgtm/compose.yaml"
archive_rel=".config/otel-lgtm/otelcol/archive.yaml"
provider_rel=".config/otel-lgtm/grafana/provisioning/agents.yaml"
dashboard_rel=".config/otel-lgtm/grafana/dashboards/agents.json"
expected_definition='{"name":"otel-lgtm","services":{"lgtm":{"container_name":"otel-lgtm","environment":{"LOKI_EXTRA_ARGS":"-store.retention=365d -compactor.retention-enabled=true -compactor.delete-request-store=filesystem","OTELCOL_EXTRA_ARGS":"--config=file:/otel-lgtm/otelcol-archive.yaml","PROMETHEUS_EXTRA_ARGS":"--enable-feature=otlp-deltatocumulative --storage.tsdb.retention.time=365d","TEMPO_EXTRA_ARGS":"-backend-scheduler.provider.work.compaction.block-retention=8760h -backend-worker.compaction.block-retention=8760h"},"image":"grafana/otel-lgtm:0.39.0@sha256:4c8056c9c05fcb3c8fd93800e85334bfd79b4d0271b47a54a121a64af41fe1fe","ports":["127.0.0.1:3000:3000","127.0.0.1:4317:4317","127.0.0.1:4318:4318"],"restart":"unless-stopped","volumes":["data:/data",{"bind":{"create_host_path":false},"read_only":true,"source":"./otelcol/archive.yaml","target":"/otel-lgtm/otelcol-archive.yaml","type":"bind"},{"bind":{"create_host_path":false},"read_only":true,"source":"./grafana/provisioning/agents.yaml","target":"/otel-lgtm/grafana/conf/provisioning/dashboards/agents.yaml","type":"bind"},{"bind":{"create_host_path":false},"read_only":true,"source":"./grafana/dashboards","target":"/otel-lgtm/agent-dashboards","type":"bind"},{"bind":{"create_host_path":false},"source":"${HOME}/.local/share/otel-lgtm/archive","target":"/archive","type":"bind"}]}},"volumes":{"data":null}}'

section "otel-backend: managed set per profile"

# 1) personal applies the file; work does not, and a file of its own at the
#    same path stays byte-identical.
personal_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-otel-backend-personal.XXXXXX")"
tmp_roots+=("$personal_root")
if ! render_profile_into "$DOTFILES_ROOT" "$personal_root" personal; then
  fail "test failed: personal apply did not render"
  exit 1
fi
managed="$personal_root/home/$managed_rel"
archive_cfg="$personal_root/home/$archive_rel"
provider_cfg="$personal_root/home/$provider_rel"
dashboard_json="$personal_root/home/$dashboard_rel"
for rel in "$managed_rel" "$archive_rel" "$provider_rel" "$dashboard_rel"; do
  if [[ -f "$personal_root/home/$rel" ]]; then
    ok "test passed: personal applies $rel"
  else
    fail "test failed: personal did not apply $rel"
    exit 1
  fi
done

work_root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-otel-backend-work.XXXXXX")"
tmp_roots+=("$work_root")
mkdir -p "$work_root/home/.config/otel-lgtm"
printf 'services: {}\n' > "$work_root/work-own.yaml"
cp "$work_root/work-own.yaml" "$work_root/home/$managed_rel"
if ! render_profile_into "$DOTFILES_ROOT" "$work_root" work; then
  fail "test failed: work apply did not render"
  exit 1
fi
if cmp -s "$work_root/work-own.yaml" "$work_root/home/$managed_rel" \
  && [[ ! -e "$work_root/home/.config/otel-lgtm/otelcol" && ! -e "$work_root/home/.config/otel-lgtm/grafana" ]]; then
  ok "test passed: work leaves a compose file of its own untouched and applies none of the module's files"
else
  fail "test failed: work apply changed an unmanaged compose file or applied otel-backend files although it does not list the module"
  status=1
fi

section "otel-backend: managed content"

# 2) Header on line 1 (doctor's managed-path orphan scan keys on it). The
#    dashboard is strict JSON, so it carries the header in its description
#    (the scan searches the whole file).
for f in "$managed" "$archive_cfg" "$provider_cfg"; do
  if head -n 1 "$f" | grep -Fq "Managed by chezmoi"; then
    ok "test passed: line 1 of ${f#"$personal_root/home/"} carries the managed-by header"
  else
    fail "test failed: line 1 of ${f#"$personal_root/home/"} must carry the managed-by header (doctor orphan scan)"
    status=1
  fi
done
if [[ "$(yq -p json -r '.description // ""' "$dashboard_json" 2>/dev/null)" == "Managed by chezmoi"* ]]; then
  ok "test passed: the dashboard description carries the managed-by header"
else
  fail "test failed: the dashboard description must start with the managed-by header (doctor orphan scan)"
  status=1
fi

# 3) Parses as YAML and is exactly the pinned definition (keys sorted, so
#    only a value or key change trips it). An image update changes the
#    version and the digest here on purpose, in the same PR as the file.
if definition="$(yq -o json -I0 'sort_keys(..)' "$managed" 2>&1)" \
  && [[ "$definition" == "$expected_definition" ]]; then
  ok "test passed: parses as YAML with exactly the pinned definition"
else
  printf 'expected:\n%s\nactual:\n%s\n' "$expected_definition" "${definition:-<no output>}" >&2
  fail "test failed: compose file does not parse or drifted from the pinned definition"
  status=1
fi

# 4) The properties the definition is trusted for, checked on their own so
#    that a careless update of the pin above still fails here.
# every_line_matches REGEX — stdin has at least one line and each matches.
every_line_matches() {
  local re="$1" line seen=0
  while IFS= read -r line; do
    seen=1
    [[ "$line" =~ $re ]] || return 1
  done
  [[ "$seen" -eq 1 ]]
}

# 4a) Each image is name:version@sha256:<64 hex>: a tag alone can be moved
#     upstream, and a digest alone does not say which release it is.
image_re='^[a-z0-9][a-z0-9./-]*:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'
if yq -r '.services[] | .image // ""' "$managed" | every_line_matches "$image_re"; then
  ok "test passed: every image is pinned by version and sha256 digest"
else
  fail "test failed: every service image must be name:X.Y.Z@sha256:<64 hex>"
  status=1
fi

# 4b) Each published port is a string starting with 127.0.0.1: (the long
#     map syntax and a missing address both fail: the tag is printed first
#     and only !!str passes).
port_re='^!!str 127\.0\.0\.1:[0-9]+:[0-9]+$'
if yq -r '.services[] | .ports[] | (tag + " " + (. | tostring))' "$managed" 2>/dev/null | every_line_matches "$port_re"; then
  ok "test passed: every port is published on 127.0.0.1 only"
else
  fail "test failed: every port must be the string 127.0.0.1:<host port>:<container port>"
  status=1
fi

# 4c) Host paths reach the container only through the allowlisted binds.
#     A short-syntax entry must be a named volume declared at the top level
#     with an empty declaration (null or {}): one with driver_opts (type:
#     none, o: bind, device: /...) binds a path under a name that still
#     reads as a named volume, and external / name point at a volume
#     defined elsewhere (Codex review, PR #516). A long-syntax entry must be
#     a bind with create_host_path false (a source the VM does not mount
#     then fails the start instead of being created inside the VM) and only
#     the keys below, and its source is either a path under the compose
#     file's own directory (./..., no ..), mounted read-only, or exactly the
#     archive directory on /archive — the one writable bind (#517).
volume_re='^str\|[a-z][a-z0-9_-]*:/[^:]*$'
archive_source='${HOME}/.local/share/otel-lgtm/archive'
mounts_ok=1
writable_binds=0
# A top-level volumes that is not a map makes yq fail: no declared names
# then, so every named mount below is undeclared and the check fails with
# its own message instead of the script stopping here.
declared_volumes="$(yq -r '.volumes // {} | keys | .[]' "$managed" 2>/dev/null)" || declared_volumes=""
if ! nonempty_volume_decls="$(yq -r '.volumes // {} | to_entries | .[]
    | select((.value | tag) != "!!null" and ((.value | tag) != "!!map" or (.value | length) != 0)) | .key' "$managed" 2>/dev/null)" \
  || [[ -n "$nonempty_volume_decls" ]]; then
  mounts_ok=0
fi
# One line per mount: str|<entry>, or map|type|source|target|read_only|
# create_host_path|keys|bind keys (keys sorted: yq lists them in document
# order). The separator is not whitespace, so an empty field stays a field
# for `read` (a tab would be folded). tostring keeps false apart from an
# absent key, which prints as an empty field (the // operator would fold
# false into the default). A value holding "|" shifts the fields and fails.
if ! mount_lines="$(yq -r '.services[] | .volumes[] |
    (tag) as $t |
    if $t == "!!str" then "str|" + .
    elif $t == "!!map" then "map|" + (.type | tostring) + "|" + (.source | tostring) + "|" + (.target | tostring) + "|" + (.read_only | tostring) + "|" + (.bind.create_host_path | tostring) + "|" + (keys | sort | join(",")) + "|" + ((.bind // {}) | keys | sort | join(","))
    else "other|" + $t end' "$managed" 2>/dev/null)" || [[ -z "$mount_lines" ]]; then
  mounts_ok=0
fi
while IFS= read -r mount_line; do
  [[ -n "$mount_line" ]] || continue
  case "$mount_line" in
    str\|*)
      [[ "$mount_line" =~ $volume_re ]] || { mounts_ok=0; continue; }
      mount_source="${mount_line#str|}"
      mount_source="${mount_source%%:*}"
      grep -Fxq -- "$mount_source" <<< "$declared_volumes" || mounts_ok=0
      ;;
    map\|*)
      IFS='|' read -r _ m_type m_source m_target m_ro m_chp m_keys m_bind_keys <<< "$mount_line"
      [[ "$m_type" == "bind" && "$m_chp" == "false" && "$m_bind_keys" == "create_host_path" ]] || { mounts_ok=0; continue; }
      if [[ "$m_source" == "$archive_source" ]]; then
        [[ "$m_target" == "/archive" && "$m_ro" != "true" && "$m_keys" == "bind,source,target,type" ]] || { mounts_ok=0; continue; }
        writable_binds=$((writable_binds + 1))
      elif [[ "$m_source" =~ ^\./[A-Za-z0-9._/-]+$ && "/$m_source/" != */../* ]]; then
        [[ "$m_ro" == "true" && "$m_keys" == "bind,read_only,source,target,type" ]] || mounts_ok=0
      else
        mounts_ok=0
      fi
      ;;
    *) mounts_ok=0 ;;
  esac
done <<< "$mount_lines"
# Exactly one writable bind, the archive one: without it the raw telemetry
# never reaches the host (Codex review, PR #519).
[[ "$writable_binds" -eq 1 ]] || mounts_ok=0
if [[ "$mounts_ok" -eq 1 ]]; then
  ok "test passed: host paths reach the container only through the allowlisted binds (read-only from the compose directory, the archive directory writable), every bind with create_host_path false"
else
  printf '%s\n' "${mount_lines:-<no mounts read>}" >&2
  fail "test failed: every mount must be a declared named volume with an empty declaration, a read-only ./ bind, or the archive bind on /archive (exactly once), each bind with create_host_path false and no other key"
  status=1
fi

# 4d) None of the keys that hand the container more of the VM or the
#     network than a published loopback port.
widening="$(yq -r '.services[] | keys | .[] | select(. == "privileged" or . == "network_mode" or . == "pid" or . == "ipc" or . == "cap_add" or . == "devices" or . == "extra_hosts" or . == "security_opt")' "$managed")"
if [[ -z "$widening" ]]; then
  ok "test passed: no privileged / host-namespace / capability keys"
else
  fail "test failed: the definition must not use: $(tr '\n' ' ' <<< "$widening")"
  status=1
fi

# 4e) The restart policy that brings the container back with the daemon
#     (docs/otel-backend.md relies on it for the always-on setup).
if [[ "$(yq -r '[.services[] | .restart // ""] | unique | join(",")' "$managed")" == "unless-stopped" ]]; then
  ok "test passed: restart policy is unless-stopped"
else
  fail "test failed: every service must use restart: unless-stopped"
  status=1
fi

# 4f) Prometheus converts delta metrics on OTLP ingestion. Codex sends every
#     metric as delta, which Prometheus rejects without this flag ("invalid
#     temporality and type combination", #517), so dropping it loses all of
#     Codex's metrics while logs and traces keep arriving. The value is
#     split as the image's run-prometheus.sh does (on whitespace), and the
#     feature must be one of the comma-separated names of an
#     --enable-feature= argument exactly: a substring match would take
#     otlp-deltatocumulative-typo for it (Codex review, PR #518).
# extra_args_of VAR — set extra_args to the arguments the image's run-*.sh
# scripts make of VAR: they read the value with `read -ra`, which splits on
# whitespace and keeps the FIRST LINE only. So VAR must be one string on
# one line: a YAML list, or a multi-line string whose later lines the image
# would drop, returns 1 with no arguments (Codex review, PR #522).
extra_args=()
extra_args_of() {
  local value
  extra_args=()
  [[ "$(V="$1" yq -r '.services.lgtm.environment[strenv(V)] | tag' "$managed" 2>/dev/null)" == "!!str" ]] || return 1
  value="$(V="$1" yq -r '.services.lgtm.environment[strenv(V)]' "$managed" 2>/dev/null)" || return 1
  [[ "$value" != *$'\n'* ]] || return 1
  read -ra extra_args <<< "$value"
}
delta_feature=0
prom_args=()
if extra_args_of PROMETHEUS_EXTRA_ARGS; then
  prom_args=(${extra_args[@]+"${extra_args[@]}"})
fi
for prom_arg in ${prom_args[@]+"${prom_args[@]}"}; do
  case "$prom_arg" in
    --enable-feature=*)
      prom_features=()
      IFS=',' read -ra prom_features <<< "${prom_arg#--enable-feature=}"
      for prom_feature in ${prom_features[@]+"${prom_features[@]}"}; do
        [[ "$prom_feature" == "otlp-deltatocumulative" ]] && delta_feature=1
      done
      ;;
  esac
done
if [[ "$delta_feature" -eq 1 ]]; then
  ok "test passed: Prometheus converts delta metrics on OTLP ingestion"
else
  fail "test failed: PROMETHEUS_EXTRA_ARGS must carry --enable-feature=otlp-deltatocumulative (Codex sends delta metrics)"
  status=1
fi

# 4h) Every backend keeps one year of data (#520), checked per argument the
#     way the image's run-*.sh scripts split each *_EXTRA_ARGS (on
#     whitespace), so a value that only contains the flag as a substring
#     does not pass. Prometheus: its retention flag (deprecated in 3.15 in
#     favour of the config file, but honoured). Loki: retention needs the
#     compactor's retention switched on and a delete-request store, and the
#     period. Tempo: the block retention of both the backend scheduler and
#     the backend worker (both are set rather than guessing which one
#     prunes). The archive's max_days (section 5) is the same year.
# extra_args_have VAR NAME=VALUE... — VAR is one one-line string
# (extra_args_of), and each option NAME appears in it exactly once, as
# exactly NAME=VALUE. An option is matched by its name however it is
# spelled (one or two leading dashes, `=value` or the value in the next
# argument, which both Prometheus' kingpin and Go's flag package accept),
# so a second, conflicting spelling (-store.retention=1d after
# -store.retention=365d, or --store.retention 1d) fails instead of being
# ignored (Codex review, PR #522).
extra_args_have() {
  local var="$1" want want_name have have_name count matched
  shift
  extra_args_of "$var" || return 1
  for want in "$@"; do
    want_name="${want%%=*}"
    want_name="${want_name#-}"
    want_name="${want_name#-}"
    count=0
    matched=0
    for have in ${extra_args[@]+"${extra_args[@]}"}; do
      [[ "$have" == -* ]] || continue
      have_name="${have%%=*}"
      have_name="${have_name#-}"
      have_name="${have_name#-}"
      [[ "$have_name" == "$want_name" ]] || continue
      count=$((count + 1))
      [[ "$have" == "$want" ]] && matched=1
    done
    [[ "$count" -eq 1 && "$matched" -eq 1 ]] || return 1
  done
}
if extra_args_have PROMETHEUS_EXTRA_ARGS --storage.tsdb.retention.time=365d \
  && extra_args_have LOKI_EXTRA_ARGS -store.retention=365d -compactor.retention-enabled=true -compactor.delete-request-store=filesystem \
  && extra_args_have TEMPO_EXTRA_ARGS -backend-scheduler.provider.work.compaction.block-retention=8760h -backend-worker.compaction.block-retention=8760h; then
  ok "test passed: Prometheus, Loki and Tempo keep one year of data"
else
  fail "test failed: the backends must keep one year: PROMETHEUS_EXTRA_ARGS --storage.tsdb.retention.time=365d, LOKI_EXTRA_ARGS -store.retention=365d -compactor.retention-enabled=true -compactor.delete-request-store=filesystem, TEMPO_EXTRA_ARGS both block-retention=8760h flags"
  status=1
fi

# 4g) The Collector reads the archive config from the read-only bind of
#     ./otelcol/archive.yaml: OTELCOL_EXTRA_ARGS names exactly that bind's
#     target (another path would start the Collector without the archive
#     pipelines, or not at all).
collector_cfg_target="$(yq -r '.services.lgtm.volumes[] | select(tag == "!!map" and .source == "./otelcol/archive.yaml") | .target' "$managed" 2>/dev/null | head -n 1)"
if [[ -n "$collector_cfg_target" \
  && "$(yq -r '.services.lgtm.environment.OTELCOL_EXTRA_ARGS // ""' "$managed")" == "--config=file:$collector_cfg_target" ]]; then
  ok "test passed: OTELCOL_EXTRA_ARGS layers the bound archive config on the Collector"
else
  fail "test failed: OTELCOL_EXTRA_ARGS must be --config=file:<the target of the ./otelcol/archive.yaml bind>"
  status=1
fi

section "otel-backend: archive config"

# 5) The archive config only ADDS */archive pipelines (it must not replace
#    the image's own traces / metrics / logs ones), one per signal, each
#    taking the otlp receiver's data unprocessed into a file exporter.
#    Every exporter writes uncompressed newline-delimited OTLP JSON under
#    /archive (what a later Collector's otlpjsonfile receiver reads back),
#    keeps one year (#520): max_days 365, the same year as the backends,
#    and max_backups 0, which keeps every rotated file on this image's
#    Collector (measured, #517; any other count deletes the oldest ones
#    sooner), and max_megabytes an integer in 1..1024. receivers and exporters must be real lists: a string "[otlp]"
#    is not one (Codex review, PR #519).
archive_ok=1
# yq lists keys (and unique values) in document order, so every list is
# sorted before it is compared.
[[ "$(yq -r 'keys | sort | join(",")' "$archive_cfg" 2>/dev/null)" == "exporters,service" ]] || archive_ok=0
[[ "$(yq -r '.service | keys | sort | join(",")' "$archive_cfg" 2>/dev/null)" == "pipelines" ]] || archive_ok=0
[[ "$(yq -r '.service.pipelines | keys | sort | join(",")' "$archive_cfg" 2>/dev/null)" == "logs/archive,metrics/archive,traces/archive" ]] || archive_ok=0
if ! bad_pipelines="$(yq -r '.service.pipelines | to_entries | .[]
    | select((.value | keys | sort | join(",")) != "exporters,receivers"
      or (.value.receivers | tag) != "!!seq" or (.value.receivers | length) != 1
      or (.value.receivers[0] | tag) != "!!str" or .value.receivers[0] != "otlp"
      or (.value.exporters | tag) != "!!seq" or (.value.exporters | length) != 1
      or (.value.exporters[0] | tag) != "!!str"
      or (.value.exporters[0] | test("^file/") | not)) | .key' "$archive_cfg" 2>/dev/null)" || [[ -n "$bad_pipelines" ]]; then
  archive_ok=0
fi
used_exporters="$(yq -r '[.service.pipelines[].exporters[]] | unique | sort | join(",")' "$archive_cfg" 2>/dev/null || true)"
[[ -n "$used_exporters" && "$(yq -r '.exporters | keys | sort | join(",")' "$archive_cfg" 2>/dev/null)" == "$used_exporters" ]] || archive_ok=0
if ! bad_exporters="$(yq -r '.exporters | to_entries | .[]
    | select((.key | test("^file/") | not)
      or (.value | keys | sort | join(",")) != "format,path,rotation"
      or .value.format != "json"
      or (.value.path | test("^/archive/[a-z]+\\.jsonl$") | not)
      or (.value.rotation | keys | sort | join(",")) != "max_backups,max_days,max_megabytes"
      or (.value.rotation.max_days | tag) != "!!int" or .value.rotation.max_days != 365
      or (.value.rotation.max_megabytes | tag) != "!!int"
      or .value.rotation.max_megabytes < 1 or .value.rotation.max_megabytes > 1024
      or (.value.rotation.max_backups | tag) != "!!int" or .value.rotation.max_backups != 0) | .key' "$archive_cfg" 2>/dev/null)" || [[ -n "$bad_exporters" ]]; then
  archive_ok=0
fi
[[ "$(yq -r '[.exporters[].path] | unique | length' "$archive_cfg" 2>/dev/null)" == "3" ]] || archive_ok=0
if [[ "$archive_ok" -eq 1 ]]; then
  ok "test passed: the archive config adds one unprocessed */archive pipeline per signal, each to its own JSON file under /archive kept for one year"
else
  fail "test failed: the archive config must hold only exporters and three */archive pipelines (otlp -> one file exporter each, as lists), with json files under /archive, rotation by size (max_megabytes an integer in 1..1024), max_days 365 and max_backups 0"
  status=1
fi

section "otel-backend: Grafana dashboards"

# 6) The provider serves the bound dashboards directory and refuses UI
#    edits (the JSON in dotfiles is the source of truth). providers must be
#    a list of exactly one object: a map of the same entries enumerates the
#    same values under .providers[] (Codex review, PR #519).
dash_target="$(yq -r '.services.lgtm.volumes[] | select(tag == "!!map" and .source == "./grafana/dashboards") | .target' "$managed" 2>/dev/null | head -n 1)"
provider_target="$(yq -r '.services.lgtm.volumes[] | select(tag == "!!map" and .source == "./grafana/provisioning/agents.yaml") | .target' "$managed" 2>/dev/null | head -n 1)"
if [[ -n "$dash_target" && "$provider_target" == /otel-lgtm/grafana/conf/provisioning/dashboards/*.yaml \
  && "$(yq -r '(.providers | tag) + "|" + (.providers | length | tostring) + "|" + ([.providers[] | tag] | unique | join(","))' "$provider_cfg" 2>/dev/null)" == "!!seq|1|!!map" \
  && "$(yq -r '[.providers[] | .options.path] | join(",")' "$provider_cfg" 2>/dev/null)" == "$dash_target" \
  && "$(yq -r '[.providers[] | (.allowUiUpdates | tostring)] | unique | join(",")' "$provider_cfg" 2>/dev/null)" == "false" ]]; then
  ok "test passed: the dashboard provider is bound into Grafana's provisioning, serves the bound dashboards and refuses UI edits"
else
  fail "test failed: the provider must be bound into /otel-lgtm/grafana/conf/provisioning/dashboards/, be a list of one object, point at the ./grafana/dashboards bind target and set allowUiUpdates: false"
  status=1
fi

# 7) The dashboard is one JSON object (jq, as strict_json_object: yq's JSON
#    reader accepts a trailing comma), keeps its uid (links and bookmarks
#    use it), and every datasource reference anywhere in it (panels,
#    queries, variables) is an object naming one of the bundled datasources
#    by its provisioned uid: a bare string (a datasource name) is refused,
#    not skipped (Codex review, PR #519). Every non-row panel names one.
if strict_json_object "$dashboard_json" \
  && [[ "$(jq -r '.uid' "$dashboard_json")" == "ai-agents-codex" ]] \
  && [[ "$(jq -r '[.. | objects | select(has("datasource")) | .datasource | if type == "object" then (.uid // "<none>") else "<\(type)>" end] | map(select(. != "loki" and . != "prometheus" and . != "tempo")) | length' "$dashboard_json")" == "0" ]] \
  && [[ "$(jq -r '[.panels[] | select(.type != "row") | .datasource.uid] | map(select(. == null)) | length' "$dashboard_json")" == "0" ]]; then
  ok "test passed: the dashboard is a strict JSON object with its uid, on the loki / prometheus / tempo datasources only"
else
  fail "test failed: the dashboard must be one strict JSON object with uid ai-agents-codex whose every datasource is an object with uid loki, prometheus or tempo"
  status=1
fi

# 8) Modes under the stock umask pinned above: files 0644 in 0755 directories.
modes_ok=1
for rel in "$managed_rel" "$archive_rel" "$provider_rel" "$dashboard_rel"; do
  [[ "$(file_mode "$personal_root/home/$rel")" == "644" ]] || modes_ok=0
done
for rel in .config/otel-lgtm .config/otel-lgtm/otelcol .config/otel-lgtm/grafana .config/otel-lgtm/grafana/provisioning .config/otel-lgtm/grafana/dashboards; do
  [[ "$(file_mode "$personal_root/home/$rel")" == "755" ]] || modes_ok=0
done
if [[ "$modes_ok" -eq 1 ]]; then
  ok "test passed: the module's files are 0644 in 0755 directories"
else
  fail "test failed: expected the module's files 0644 and their directories 0755"
  status=1
fi

exit "$status"
