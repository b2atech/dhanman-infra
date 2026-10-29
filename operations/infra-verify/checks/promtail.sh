#!/usr/bin/env bash
#
# promtail.sh — PT family checks (Promtail verification).
# This is a LIBRARY: source it, do not execute it directly.
#
# PT-01 container state        PT-02 readiness (container has no wget/curl,
# so readiness is checked via host-side curl against the container's IP,
# discovered with `docker inspect`; port 9080 is not published to the host
# but is reachable via the bridge-network IP)
# PT-03 config file exists      PT-04 config-path-vs-real-files cross-check
# PT-05 positions file freshness (ephemeral /tmp/positions.yaml — ships
# no volume, so every restart wipes it; see discovery.md §4)
# PT-06 push error detection    PT-07 layer verdict
#
# Confirmed facts from discovery.md, used directly:
#   Container name: promtail
#   Config file on host: /opt/monitoring/promtail/promtail-config.yml on
#     prod (unverified live, preserved as the default); QA's real config
#     lives at /home/ubuntu/loki-stack/promtail-config.yaml instead — see
#     environment.promtail_config_path in inventory.<env>.yaml, generated
#     by promtail_config_path_for in generate-inventory.sh.
#   Positions file inside container: /tmp/positions.yaml
#   Listen port inside container: 9080 (NOT published to host)
#   Push target: http://loki:3100/loki/api/v1/push
#   Log path glob: /var/www/<env>/logs/dhanman-*.log

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "promtail.sh is a library — source it, do not execute it directly." >&2
  exit 1
fi

_PT_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly _PT_SCRIPT_DIR
PT_CONFIG_DIR="$(realpath -m "${_PT_SCRIPT_DIR}/../config")"
readonly PT_CONFIG_DIR

# shellcheck source=SCRIPTDIR/../lib/result.sh
source "${_PT_SCRIPT_DIR}/../lib/result.sh"

readonly _PT_CONTAINER_NAME="promtail"
readonly _PT_DEFAULT_CONFIG_PATH="/opt/monitoring/promtail/promtail-config.yml"
readonly _PT_POSITIONS_PATH="/tmp/positions.yaml"
readonly _PT_POSITIONS_FRESHNESS_MINUTES=30
readonly _PT_RESTART_WARN_THRESHOLD=5
readonly _PT_ERROR_WARN_MAX=5
readonly _PT_READY_TIMEOUT_SECONDS=10
readonly _PT_RESTART_REPAIR="operations/repairs/promtail/restart-promtail.sh"
readonly _PT_CONFIG_REPAIR="operations/repairs/promtail/restore-approved-promtail-config.sh"
readonly _PT_ERROR_PATTERNS=(
  "error sending batch"
  "429"
  "entry too far behind"
  "failed to flush"
  "connection refused"
)

PT_YAML_TOOL=""

# ---------------------------------------------------------------------------
# Inventory reading — same dual yq / python3+PyYAML convention as the
# other check families; independent (only depends on lib/result.sh).
# Used only to derive a default env log_dir when run_pt_checks isn't
# given one explicitly.
# ---------------------------------------------------------------------------
_pt_detect_yaml_tool() {
  if [[ -n "$PT_YAML_TOOL" ]]; then
    return 0
  fi
  if command -v yq >/dev/null 2>&1; then
    PT_YAML_TOOL="yq"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    PT_YAML_TOOL="python3"
    return 0
  fi
  _result_log ERROR "Neither 'yq' nor 'python3 (with PyYAML)' is available for inventory read"
  return 1
}

_pt_env_field() {
  local file="$1" field="$2"
  if [[ "$PT_YAML_TOOL" == "yq" ]]; then
    yq eval ".environment.${field}" "$file"
  else
    python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
val = data.get("environment", {}).get(sys.argv[2])
print(val if val is not None else "")
' "$file" "$field"
  fi
}

# ---------------------------------------------------------------------------
# Status severity ranking, used to compute the worst status across checks
# ---------------------------------------------------------------------------
_pt_status_rank() {
  case "$1" in
    CRITICAL) echo 4 ;;
    WARNING) echo 3 ;;
    UNKNOWN) echo 2 ;;
    NOT_CONFIGURED|NOT_APPLICABLE) echo 1 ;;
    *) echo 0 ;;
  esac
}

_pt_worse_status() {
  local a="$1" b="$2"
  local ra rb
  ra="$(_pt_status_rank "$a")"
  rb="$(_pt_status_rank "$b")"
  if [[ "$rb" -gt "$ra" ]]; then
    printf '%s' "$b"
  else
    printf '%s' "$a"
  fi
}

# ---------------------------------------------------------------------------
# PT-01: container state.
#
# Inspect format uses {{.RestartCount}}, not {{.State.RestartCount}} —
# RestartCount is a top-level docker-inspect field, not nested under
# .State. The nested path isn't just wrong data: on the Docker version
# running on QA it's a hard template-parsing error (exit != 0, no stdout),
# which the previous `2>/dev/null || true` swallowed — turning a real
# "docker inspect is broken" condition into silent empty output that read
# as container_status="" and fell through to a misleading CRITICAL
# "status=unknown" even though promtail was actually running fine.
#
# stderr is merged into inspect_out (2>&1) instead of discarded, and the
# exit code is captured explicitly (no `|| true`), so a failed invocation
# is detected and reported as "docker inspect failed", distinct from a
# successful inspect that legitimately reports the container not running.
# RestartCount is also validated as purely numeric before use — any other
# docker-inspect output shape is reported as unparseable rather than
# silently defaulting to a RestartCount of 0 indistinguishable from a
# genuinely healthy container.
# ---------------------------------------------------------------------------
pt_check_01_container_state() {
  local inspect_out inspect_rc
  inspect_out="$(docker inspect "$_PT_CONTAINER_NAME" --format '{{.State.Status}} {{.RestartCount}} {{.State.StartedAt}}' 2>&1)"
  inspect_rc=$?

  local status evidence layer repair

  if [[ $inspect_rc -ne 0 || -z "$inspect_out" ]]; then
    status="CRITICAL"
    evidence="docker inspect failed for promtail (exit=${inspect_rc}): ${inspect_out:-no output}"
    layer="promtail-process"
    repair="$_PT_RESTART_REPAIR"
    result_add "PT-01" "promtail" "$status" "$evidence" "$layer" "$repair"
    printf '%s' "$status"
    return 0
  fi

  local container_status restart_count started_at
  container_status="$(printf '%s' "$inspect_out" | awk '{print $1}')"
  restart_count="$(printf '%s' "$inspect_out" | awk '{print $2}')"
  started_at="$(printf '%s' "$inspect_out" | awk '{print $3}')"

  if [[ -z "$container_status" || ! "$restart_count" =~ ^[0-9]+$ ]]; then
    status="CRITICAL"
    evidence="docker inspect returned unparseable output for promtail: '${inspect_out}'"
    layer="promtail-process"
    repair="$_PT_RESTART_REPAIR"
    result_add "PT-01" "promtail" "$status" "$evidence" "$layer" "$repair"
    printf '%s' "$status"
    return 0
  fi

  if [[ "$container_status" != "running" ]]; then
    status="CRITICAL"
    evidence="promtail container status=${container_status}, RestartCount=${restart_count}, StartedAt=${started_at:-unknown}"
    layer="promtail-process"
    repair="$_PT_RESTART_REPAIR"
  elif [[ "$restart_count" -ge "$_PT_RESTART_WARN_THRESHOLD" ]]; then
    status="WARNING"
    evidence="promtail container status=running, RestartCount=${restart_count} (>= ${_PT_RESTART_WARN_THRESHOLD} — possible loop), StartedAt=${started_at:-unknown}"
    layer="promtail-process"
    repair="none"
  else
    status="HEALTHY"
    evidence="promtail container status=running, RestartCount=${restart_count}, StartedAt=${started_at:-unknown}"
    layer="none"
    repair="none"
  fi

  result_add "PT-01" "promtail" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# PT-02: readiness endpoint. The Promtail image has no wget/curl inside the
# container, so readiness is checked from the host instead: discover the
# container's IP on its Docker network via `docker inspect`, then curl
# http://<ip>:9080/ready directly (port 9080 is not published to the host,
# but it is reachable from the host over the bridge network's IP).
# ---------------------------------------------------------------------------
pt_check_02_readiness() {
  local pt01_status="$1"

  if [[ "$pt01_status" == "CRITICAL" ]]; then
    result_add "PT-02" "promtail" "NOT_APPLICABLE" "container not running (PT-01 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local container_ip
  container_ip="$(docker inspect "$_PT_CONTAINER_NAME" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || true)"
  container_ip="$(printf '%s' "$container_ip" | xargs || true)"

  local status evidence layer repair
  if [[ -z "$container_ip" ]]; then
    status="CRITICAL"
    evidence="could not determine promtail container IP via docker inspect — cannot reach readiness endpoint"
    layer="promtail-process"
    repair="$_PT_RESTART_REPAIR"
    result_add "PT-02" "promtail" "$status" "$evidence" "$layer" "$repair"
    printf '%s' "$status"
    return 0
  fi

  local ready_out
  ready_out="$(timeout "$_PT_READY_TIMEOUT_SECONDS" curl -s "http://${container_ip}:9080/ready" 2>/dev/null || true)"

  if [[ "$ready_out" == *"Ready"* ]]; then
    status="HEALTHY"
    evidence="readiness endpoint (http://${container_ip}:9080/ready) responded: ${ready_out}"
    layer="none"
    repair="none"
  else
    status="CRITICAL"
    evidence="readiness endpoint (http://${container_ip}:9080/ready) did not respond with Ready (got: '${ready_out}')"
    layer="promtail-process"
    repair="$_PT_RESTART_REPAIR"
  fi

  result_add "PT-02" "promtail" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# PT-03: config file exists on host — read-only metadata check, does not
# parse the file.
# ---------------------------------------------------------------------------
pt_check_03_config_exists() {
  local config_path="$1"

  local status evidence layer repair
  if [[ -f "$config_path" && -r "$config_path" ]]; then
    status="HEALTHY"
    evidence="config file present: ${config_path}"
    layer="none"
    repair="none"
  else
    status="CRITICAL"
    evidence="config file missing or unreadable: ${config_path}"
    layer="promtail-process"
    repair="$_PT_CONFIG_REPAIR"
  fi

  result_add "PT-03" "promtail" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# PT-04: config path vs actual log files — the "watching the wrong path"
# detector. Extracts the __path__ glob and expands it against the real
# filesystem; a glob with zero matches is exactly the confirmed positions/
# path-mismatch failure mode from discovery.md.
# ---------------------------------------------------------------------------
pt_check_04_path_cross_check() {
  local config_path="$1"

  if [[ ! -f "$config_path" || ! -r "$config_path" ]]; then
    result_add "PT-04" "promtail" "CRITICAL" "config file unreadable, cannot extract glob: ${config_path}" "promtail-process" "$_PT_CONFIG_REPAIR"
    printf 'CRITICAL'
    return 0
  fi

  local raw_line glob
  raw_line="$(grep '__path__' "$config_path" | head -n 1 || true)"
  glob="${raw_line#*__path__:}"
  glob="$(printf '%s' "$glob" | xargs)"
  glob="${glob//\"/}"
  glob="${glob//\'/}"

  if [[ -z "$glob" ]]; then
    result_add "PT-04" "promtail" "CRITICAL" "could not extract __path__ glob from config: ${config_path}" "promtail-process" "$_PT_CONFIG_REPAIR"
    printf 'CRITICAL'
    return 0
  fi

  local match_count=0
  if compgen -G "$glob" >/dev/null 2>&1; then
    local -a matches=()
    while IFS= read -r f; do
      matches+=("$f")
    done < <(compgen -G "$glob")
    match_count=${#matches[@]}
  fi

  local status evidence layer repair
  if [[ "$match_count" -gt 0 ]]; then
    status="HEALTHY"
    evidence="configured glob '${glob}' matched ${match_count} file(s)"
    layer="none"
    repair="none"
  else
    status="WARNING"
    evidence="configured glob '${glob}' matched no files (Promtail may be watching the wrong path, or the log directory is empty — cross-check against LOG results)"
    layer="promtail-misconfiguration"
    repair="$_PT_CONFIG_REPAIR"
  fi

  result_add "PT-04" "promtail" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# PT-05: positions file freshness. Uses `stat --format=%Y` (epoch seconds)
# rather than parsing human-readable stat output, for a robust, unambiguous
# comparison — same mtime-comparison approach as LOG-04.
# ---------------------------------------------------------------------------
pt_check_05_positions() {
  local pt01_status="$1"

  if [[ "$pt01_status" == "CRITICAL" ]]; then
    result_add "PT-05" "promtail" "NOT_APPLICABLE" "container not running (PT-01 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local mtime
  mtime="$(docker exec "$_PT_CONTAINER_NAME" stat --format=%Y "$_PT_POSITIONS_PATH" 2>/dev/null || true)"

  local status evidence layer repair
  if [[ -z "$mtime" ]]; then
    status="CRITICAL"
    evidence="Promtail positions file absent — container was restarted. Logs will be re-ingested from beginning. Expect duplicate entries in Loki and possible timestamp-rejection errors."
    layer="promtail-process"
    repair="none"
  else
    local now age_seconds threshold_seconds
    now="$(date +%s)"
    age_seconds=$(( now - mtime ))
    threshold_seconds=$(( _PT_POSITIONS_FRESHNESS_MINUTES * 60 ))
    if [[ "$age_seconds" -le "$threshold_seconds" ]]; then
      status="HEALTHY"
      evidence="positions file fresh: last modified ${age_seconds}s ago (threshold ${threshold_seconds}s)"
      layer="none"
      repair="none"
    else
      status="WARNING"
      evidence="positions file stale: last modified ${age_seconds}s ago (threshold ${threshold_seconds}s) — Promtail may be stalled"
      layer="promtail-process"
      repair="none"
    fi
  fi

  result_add "PT-05" "promtail" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# PT-06: push error detection. Log content is redacted BEFORE any pattern
# matching or storage — the only exception is that a single log line
# containing both a credential and an error pattern will have the whole
# line replaced by the redaction marker (redact() operates per-line), so
# that specific occurrence will not be counted. Safety (never store/leak
# a credential) takes priority over perfect error-count completeness;
# this is an intentional, documented tradeoff.
# ---------------------------------------------------------------------------
pt_check_06_push_errors() {
  local raw_logs
  raw_logs="$(docker logs "$_PT_CONTAINER_NAME" --since 1h --tail 200 2>&1 || true)"

  local redacted_logs
  redacted_logs="$(redact "$raw_logs")"

  local total=0
  local -a pattern_evidence=()
  local pat count
  for pat in "${_PT_ERROR_PATTERNS[@]}"; do
    count="$(printf '%s\n' "$redacted_logs" | grep -ic -- "$pat" || true)"
    [[ -z "$count" ]] && count=0
    if [[ "$count" -gt 0 ]]; then
      pattern_evidence+=("${pat}: ${count}")
      total=$(( total + count ))
    fi
  done

  local status evidence layer repair
  if [[ "$total" -eq 0 ]]; then
    status="HEALTHY"
    evidence="no push error patterns found in last 1h (up to 200 lines)"
    layer="none"
    repair="none"
  else
    local joined
    joined="$(printf '%s; ' "${pattern_evidence[@]}")"
    joined="${joined%; }"
    if [[ "$total" -le "$_PT_ERROR_WARN_MAX" ]]; then
      status="WARNING"
      evidence="push error patterns found: ${joined}"
      layer="promtail-to-loki-delivery"
      repair="none"
    else
      status="CRITICAL"
      evidence="push error patterns found: ${joined}"
      layer="promtail-to-loki-delivery"
      repair="$_PT_RESTART_REPAIR"
    fi
  fi

  result_add "PT-06" "promtail" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# run_pt_checks <env> [log_dir] [log04_status] [config_path]
#
# Runs PT-01 through PT-06, then synthesizes the PT-07 layer verdict.
# log_dir/log04_status are optional cross-family inputs from the LOG
# family (same integration boundary documented in checks/logfile.sh);
# when omitted, log_dir is derived from inventory.<env>.yaml and the
# LOG-04-dependent verdict branches simply never fire. config_path, when
# explicitly passed (4th positional arg), always wins — this is how tests
# pin an exact path. When omitted, it's read from inventory.<env>.yaml's
# environment.promtail_config_path (set by generate-inventory.sh; QA's
# real Promtail config lives outside the ansible-managed path — see
# promtail_config_path_for in generate-inventory.sh), falling back to
# _PT_DEFAULT_CONFIG_PATH only if that inventory field is absent too.
# ---------------------------------------------------------------------------
run_pt_checks() {
  local env="$1"
  local log_dir="${2:-}"
  local log04_status="${3:-}"
  local config_path="${4:-}"

  local inventory_file="${PT_CONFIG_DIR}/inventory.${env}.yaml"
  local have_inventory=false
  if [[ -f "$inventory_file" ]] && _pt_detect_yaml_tool; then
    have_inventory=true
  fi

  if [[ -z "$log_dir" ]] && $have_inventory; then
    local services_base_dir
    services_base_dir="$(_pt_env_field "$inventory_file" services_base_dir)"
    [[ -n "$services_base_dir" ]] && log_dir="${services_base_dir}/logs"
  fi

  if [[ -z "$config_path" ]]; then
    if $have_inventory; then
      config_path="$(_pt_env_field "$inventory_file" promtail_config_path)"
    fi
    [[ -z "$config_path" ]] && config_path="$_PT_DEFAULT_CONFIG_PATH"
  fi

  local pt01
  pt01="$(pt_check_01_container_state)"

  local pt02
  pt02="$(pt_check_02_readiness "$pt01")"

  local pt03
  pt03="$(pt_check_03_config_exists "$config_path")"

  local pt04
  pt04="$(pt_check_04_path_cross_check "$config_path")"

  local pt05
  pt05="$(pt_check_05_positions "$pt01")"

  local pt06
  pt06="$(pt_check_06_push_errors)"

  local layer="none"
  local repair="none"
  local verdict_evidence="all promtail checks passing"

  if [[ "$pt01" == "CRITICAL" ]]; then
    layer="promtail-process"
    repair="$_PT_RESTART_REPAIR"
    verdict_evidence="promtail container is not running"
  elif [[ "$log04_status" == "HEALTHY" && "$pt01" == "HEALTHY" && "$pt02" == "HEALTHY" && "$pt06" != "HEALTHY" ]]; then
    layer="promtail-to-loki-delivery"
    repair="none"
    verdict_evidence="fresh application logs exist and Promtail is healthy, but push errors were detected — delivery to Loki is the suspect layer"
  elif [[ "$log04_status" == "HEALTHY" && "$pt01" == "HEALTHY" && "$pt04" == "WARNING" ]]; then
    layer="promtail-misconfiguration"
    repair="$_PT_CONFIG_REPAIR"
    verdict_evidence="Promtail is running but watching wrong path"
  fi

  local worst="HEALTHY"
  local s
  for s in "$pt01" "$pt02" "$pt03" "$pt04" "$pt05" "$pt06"; do
    worst="$(_pt_worse_status "$worst" "$s")"
  done

  result_add "PT-07" "promtail" "$worst" "$verdict_evidence" "$layer" "$repair"

  printf '%s\n' "$worst"
  printf '%s\n' "$layer"
  printf '%s\n' "$repair"
}
