#!/usr/bin/env bash
#
# loki.sh — LK family checks (Loki verification).
# This is a LIBRARY: source it, do not execute it directly.
#
# LK-01 container/readiness   LK-02 recent logs per service
# LK-03 latest timestamp per service   LK-04 label presence
# LK-05 ingestion error detection      LK-06 log volume sanity (per env)
# LK-07 cross-family layer verdict
#
# Confirmed facts from discovery.md, used directly:
#   Loki URL: http://127.0.0.1:3100 (auth_enabled: false)
#   Retention: 744h (31 days), schema tsdb v13 from 2024-01-01
#   No per-stream rate limits configured
#   Container name: loki
#   Labels: env, service_name (SHORT name, e.g. "purchase" not
#   "dhanman-purchase")
#
# SAFETY RULE (hard constraint, enforced by validate_loki_query — not a
# guideline): every query must carry a non-empty {label=...} filter, and
# every bracketed range must be <= 30 minutes, with exactly one hardcoded
# exception (LK-06's [1h] volume query, passed explicitly as an allowed
# max — never derived from user input).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "loki.sh is a library — source it, do not execute it directly." >&2
  exit 1
fi

_LK_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly _LK_SCRIPT_DIR
LK_CONFIG_DIR="$(realpath -m "${_LK_SCRIPT_DIR}/../config")"
readonly LK_CONFIG_DIR

# shellcheck source=SCRIPTDIR/../lib/result.sh
source "${_LK_SCRIPT_DIR}/../lib/result.sh"

readonly _LK_BASE_URL="http://127.0.0.1:3100"
readonly _LK_CONTAINER_NAME="loki"
readonly _LK_CURL_TIMEOUT=10
readonly _LK_FRESH_MINUTES=30
readonly _LK_STALE_MINUTES=60
readonly _LK_ERROR_CRITICAL_THRESHOLD=10
readonly _LK_MAX_QUERY_MINUTES=30
readonly _LK_RESTART_REPAIR="operations/repairs/promtail/restart-promtail.sh"
readonly _LK_CONFIG_REPAIR="operations/repairs/promtail/restore-approved-promtail-config.sh"

LK_YAML_TOOL=""

# ---------------------------------------------------------------------------
# Inventory reading — same dual yq / python3+PyYAML convention as the
# other check families; independent (only depends on lib/result.sh).
# ---------------------------------------------------------------------------
_lk_detect_yaml_tool() {
  if [[ -n "$LK_YAML_TOOL" ]]; then
    return 0
  fi
  if command -v yq >/dev/null 2>&1; then
    LK_YAML_TOOL="yq"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    LK_YAML_TOOL="python3"
    return 0
  fi
  _result_log ERROR "Neither 'yq' nor 'python3 (with PyYAML)' is available for inventory read"
  return 1
}

_lk_count() {
  local file="$1"
  if [[ "$LK_YAML_TOOL" == "yq" ]]; then
    yq eval '.services | length' "$file"
  else
    python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(len(data.get("services", [])))
' "$file"
  fi
}

_lk_field() {
  local file="$1" index="$2" field="$3"
  if [[ "$LK_YAML_TOOL" == "yq" ]]; then
    yq eval ".services[${index}].${field}" "$file"
  else
    python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
svc = data["services"][int(sys.argv[2])]
val = svc.get(sys.argv[3])
print(val if val is not None else "")
' "$file" "$index" "$field"
  fi
}

# ---------------------------------------------------------------------------
# Status severity ranking, used to compute the worst status across checks
# ---------------------------------------------------------------------------
_lk_status_rank() {
  case "$1" in
    CRITICAL) echo 4 ;;
    WARNING) echo 3 ;;
    UNKNOWN) echo 2 ;;
    NOT_CONFIGURED|NOT_APPLICABLE) echo 1 ;;
    *) echo 0 ;;
  esac
}

_lk_worse_status() {
  local a="$1" b="$2"
  local ra rb
  ra="$(_lk_status_rank "$a")"
  rb="$(_lk_status_rank "$b")"
  if [[ "$rb" -gt "$ra" ]]; then
    printf '%s' "$b"
  else
    printf '%s' "$a"
  fi
}

# ---------------------------------------------------------------------------
# validate_loki_query <query> [max_minutes]
#
# Hard safety guard, not a guideline — rejects:
#   - an empty {} selector
#   - a query with no {label=...} filter at all
#   - a bracketed range duration exceeding max_minutes (default 30)
# max_minutes exists solely for LK-06's single, hardcoded [1h] exception;
# it is never derived from user input or query content.
# Prints "OK" and returns 0 on success; prints "REJECTED: <reason>" and
# returns 1 on failure.
# ---------------------------------------------------------------------------
validate_loki_query() {
  local query="$1"
  local max_minutes="${2:-$_LK_MAX_QUERY_MINUTES}"

  if [[ "$query" == *'{}'* ]]; then
    printf 'REJECTED: empty {} selector'
    return 1
  fi

  if [[ ! "$query" =~ \{[^}]+\} ]]; then
    printf 'REJECTED: no label filter present'
    return 1
  fi

  if [[ "$query" =~ \[([0-9]+)([smhd])\] ]]; then
    local num="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    local minutes
    case "$unit" in
      s) minutes=$(( num / 60 )) ;;
      m) minutes=$num ;;
      h) minutes=$(( num * 60 )) ;;
      d) minutes=$(( num * 60 * 24 )) ;;
      *) minutes=999999 ;;
    esac
    if [[ "$minutes" -gt "$max_minutes" ]]; then
      printf 'REJECTED: time window exceeds %sm (%s%s)' "$max_minutes" "$num" "$unit"
      return 1
    fi
  fi

  printf 'OK'
  return 0
}

# ---------------------------------------------------------------------------
# LK-01: container state and readiness. Both the container status AND the
# /ready HTTP check must pass for LK-01 = HEALTHY.
# ---------------------------------------------------------------------------
lk_check_01_container_ready() {
  local inspect_out
  inspect_out="$(docker inspect "$_LK_CONTAINER_NAME" --format '{{.State.Status}} {{.State.RestartCount}}' 2>/dev/null || true)"

  local container_status restart_count
  container_status="$(printf '%s' "$inspect_out" | awk '{print $1}')"
  restart_count="$(printf '%s' "$inspect_out" | awk '{print $2}')"
  [[ -z "$restart_count" ]] && restart_count=0

  local status evidence layer repair
  if [[ "$container_status" != "running" ]]; then
    status="CRITICAL"
    evidence="loki container status=${container_status:-unknown}, RestartCount=${restart_count}"
    layer="loki-process"
    repair="none"
    result_add "LK-01" "loki" "$status" "$evidence" "$layer" "$repair"
    printf '%s' "$status"
    return 0
  fi

  local curl_out http_code ready_body
  curl_out="$(curl --silent --max-time "$_LK_CURL_TIMEOUT" --write-out $'\n%{http_code}' "${_LK_BASE_URL}/ready" 2>/dev/null || true)"
  http_code="$(printf '%s\n' "$curl_out" | tail -n 1)"
  ready_body="$(printf '%s\n' "$curl_out" | sed '$d')"

  if [[ "$http_code" == "200" && "$ready_body" == *"ready"* ]]; then
    status="HEALTHY"
    evidence="loki container running, /ready responded 200: ${ready_body}"
    layer="none"
    repair="none"
  else
    status="CRITICAL"
    evidence="loki container running but /ready check failed (http_code=${http_code:-none}, body='${ready_body}')"
    layer="loki-process"
    repair="none"
  fi

  result_add "LK-01" "loki" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LK-02: recent logs per service
# ---------------------------------------------------------------------------
lk_check_02_recent_logs() {
  local env="$1" name="$2" short_name="$3" lk01_status="$4"

  if [[ "$lk01_status" == "CRITICAL" ]]; then
    result_add "LK-02" "$name" "NOT_APPLICABLE" "Loki not available (LK-01 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local query="{env=\"${env}\",service_name=\"${short_name}\"}"
  local rc=0
  local validation
  validation="$(validate_loki_query "$query")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    result_add "LK-02" "$name" "NOT_CONFIGURED" "query safety violation — query rejected (${validation})" "none" "none"
    printf 'NOT_CONFIGURED'
    return 0
  fi

  local now_ns
  now_ns=$(( $(date +%s) * 1000000000 ))

  local response
  response="$(curl --silent --max-time "$_LK_CURL_TIMEOUT" -G "${_LK_BASE_URL}/loki/api/v1/query" \
    --data-urlencode "query=${query}" \
    --data-urlencode "time=${now_ns}" \
    --data-urlencode "limit=1" 2>/dev/null || true)"

  local has_results
  has_results="$(python3 -c "
import json, sys
try:
    obj = json.loads(sys.argv[1])
    result = obj.get('data', {}).get('result', [])
    print('1' if len(result) > 0 else '0')
except Exception:
    print('0')
" "$response" 2>/dev/null || echo '0')"

  local status evidence layer repair
  if [[ "$has_results" == "1" ]]; then
    status="HEALTHY"
    evidence="log entries found in Loki for {env=\"${env}\",service_name=\"${short_name}\"}"
    layer="none"
    repair="none"
  else
    status="WARNING"
    evidence="No log entries found in Loki for {env=${env}, service_name=${short_name}} — check Promtail pipeline"
    layer="promtail-to-loki-delivery"
    repair="none"
  fi

  result_add "LK-02" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LK-03: latest log timestamp per service
# ---------------------------------------------------------------------------
lk_check_03_latest_timestamp() {
  local env="$1" name="$2" short_name="$3" lk02_status="$4"

  if [[ "$lk02_status" == "WARNING" ]]; then
    result_add "LK-03" "$name" "NOT_APPLICABLE" "no data in Loki to check timestamp (LK-02 warning)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local query="{env=\"${env}\",service_name=\"${short_name}\"}"
  local rc=0
  local validation
  validation="$(validate_loki_query "$query")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    result_add "LK-03" "$name" "NOT_CONFIGURED" "query safety violation — query rejected (${validation})" "none" "none"
    printf 'NOT_CONFIGURED'
    return 0
  fi

  local now_s now_ns start_ns
  now_s="$(date +%s)"
  now_ns=$(( now_s * 1000000000 ))
  start_ns=$(( now_ns - (5 * 60 * 1000000000) ))

  local response
  response="$(curl --silent --max-time "$_LK_CURL_TIMEOUT" -G "${_LK_BASE_URL}/loki/api/v1/query_range" \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${start_ns}" \
    --data-urlencode "end=${now_ns}" \
    --data-urlencode "limit=1" \
    --data-urlencode "direction=backward" 2>/dev/null || true)"

  local latest_ns
  latest_ns="$(python3 -c "
import json, sys
try:
    obj = json.loads(sys.argv[1])
    result = obj.get('data', {}).get('result', [])
    if not result:
        print('')
    else:
        values = result[0].get('values', [])
        print(values[0][0] if values else '')
except Exception:
    print('')
" "$response" 2>/dev/null || echo '')"

  local status evidence layer repair
  if [[ -z "$latest_ns" ]]; then
    status="UNKNOWN"
    evidence="could not determine latest log timestamp from Loki response"
    layer="none"
    repair="none"
  else
    local latest_s age_seconds age_minutes
    latest_s=$(( latest_ns / 1000000000 ))
    age_seconds=$(( now_s - latest_s ))
    age_minutes=$(( age_seconds / 60 ))

    if [[ "$age_minutes" -lt "$_LK_FRESH_MINUTES" ]]; then
      status="HEALTHY"
      evidence="most recent Loki entry ${age_minutes}m ago"
      layer="none"
      repair="none"
    elif [[ "$age_minutes" -le "$_LK_STALE_MINUTES" ]]; then
      status="WARNING"
      evidence="most recent Loki entry ${age_minutes}m ago (${_LK_FRESH_MINUTES}-${_LK_STALE_MINUTES}m)"
      layer="promtail-to-loki-delivery"
      repair="none"
    else
      status="CRITICAL"
      evidence="most recent Loki entry ${age_minutes}m ago (> ${_LK_STALE_MINUTES}m)"
      layer="promtail-to-loki-delivery"
      repair="none"
    fi
  fi

  result_add "LK-03" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LK-04: label presence check (env-level, all services at once)
# ---------------------------------------------------------------------------
lk_check_04_label_presence() {
  local env="$1" lk01_status="$2"
  shift 2
  local -a expected_short_names=("$@")

  if [[ "$lk01_status" == "CRITICAL" ]]; then
    result_add "LK-04" "loki" "NOT_APPLICABLE" "Loki not available (LK-01 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local response
  response="$(curl --silent --max-time "$_LK_CURL_TIMEOUT" -G "${_LK_BASE_URL}/loki/api/v1/label/service_name/values" \
    --data-urlencode "since=24h" 2>/dev/null || true)"

  local present_csv
  present_csv="$(python3 -c "
import json, sys
try:
    obj = json.loads(sys.argv[1])
    data = obj.get('data', [])
    if isinstance(data, list):
        print(','.join(str(x) for x in data))
    else:
        print('')
except Exception:
    print('')
" "$response" 2>/dev/null || echo '')"

  local -a present=()
  IFS=',' read -r -a present <<< "$present_csv"

  local -a missing=()
  local svc found item
  for svc in "${expected_short_names[@]}"; do
    found=false
    for item in "${present[@]}"; do
      if [[ "$item" == "$svc" ]]; then
        found=true
        break
      fi
    done
    if ! $found; then
      missing+=("$svc")
    fi
  done

  local status evidence layer repair
  if [[ ${#missing[@]} -eq 0 ]]; then
    status="HEALTHY"
    evidence="all ${#expected_short_names[@]} inventory services present in Loki service_name label values"
    layer="none"
    repair="none"
  else
    local joined
    joined="$(printf '%s, ' "${missing[@]}")"
    joined="${joined%, }"
    status="WARNING"
    evidence="services missing from Loki labels: ${joined}"
    layer="promtail-to-loki-delivery"
    repair="none"
  fi

  result_add "LK-04" "loki" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LK-05: ingestion error detection. /metrics is plain Prometheus text.
# Matching happens against the RAW text (grep needs the real
# "loki_..._total" prefix intact — redacting first would make a
# credential-bearing line invisible to grep, silently dropping a real
# counter from the count instead of just anonymising it). Each matched
# line is redacted individually before being stored/displayed, so the
# value is still counted correctly and the raw content never leaks —
# both safety and completeness hold, unlike a redact-then-grep ordering.
# ---------------------------------------------------------------------------
lk_check_05_ingestion_errors() {
  local raw_metrics
  raw_metrics="$(curl --silent --max-time "$_LK_CURL_TIMEOUT" "${_LK_BASE_URL}/metrics" 2>/dev/null || true)"

  local -a findings=()
  local max_value=0

  local line value redacted_line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    value="$(printf '%s' "$line" | awk '{print $NF}')"
    value="${value%%.*}"
    [[ "$value" =~ ^[0-9]+$ ]] || continue
    [[ "$value" -eq 0 ]] && continue
    redacted_line="$(redact "$line")"
    findings+=("$redacted_line")
    [[ "$value" -gt "$max_value" ]] && max_value="$value"
  done < <(printf '%s\n' "$raw_metrics" | grep '^loki_discarded_samples_total' || true)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    value="$(printf '%s' "$line" | awk '{print $NF}')"
    value="${value%%.*}"
    [[ "$value" =~ ^[0-9]+$ ]] || continue
    [[ "$value" -eq 0 ]] && continue
    redacted_line="$(redact "$line")"
    findings+=("$redacted_line")
    [[ "$value" -gt "$max_value" ]] && max_value="$value"
  done < <(printf '%s\n' "$raw_metrics" | grep '^loki_request_duration_seconds_count' | grep -E 'status_code="(4|5)[0-9]{2}"' || true)

  local status evidence layer repair
  if [[ ${#findings[@]} -eq 0 ]]; then
    status="HEALTHY"
    evidence="no ingestion error counters found (all zero or absent)"
    layer="none"
    repair="none"
  else
    local joined
    joined="$(printf '%s; ' "${findings[@]}")"
    joined="${joined%; }"
    if [[ "$max_value" -ge "$_LK_ERROR_CRITICAL_THRESHOLD" ]]; then
      status="CRITICAL"
    else
      status="WARNING"
    fi
    evidence="${joined} (counters are cumulative since Loki restart)"
    layer="loki-process"
    repair="none"
  fi

  result_add "LK-05" "loki" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LK-06: log volume sanity — env-level only, run once, never per service.
# The [1h] window here is the one sanctioned, hardcoded exception to the
# 30-minute query safety rule (passed explicitly, never derived from
# user input).
# ---------------------------------------------------------------------------
lk_check_06_volume_sanity() {
  local env="$1" lk01_status="$2"

  if [[ "$lk01_status" == "CRITICAL" ]]; then
    result_add "LK-06" "${env}/loki-volume" "NOT_APPLICABLE" "Loki not available (LK-01 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local query="count_over_time({env=\"${env}\"}[1h])"
  local rc=0
  local validation
  validation="$(validate_loki_query "$query" 60)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    result_add "LK-06" "${env}/loki-volume" "NOT_CONFIGURED" "query safety violation — query rejected (${validation})" "none" "none"
    printf 'NOT_CONFIGURED'
    return 0
  fi

  local now_ns
  now_ns=$(( $(date +%s) * 1000000000 ))

  local response
  response="$(curl --silent --max-time "$_LK_CURL_TIMEOUT" -G "${_LK_BASE_URL}/loki/api/v1/query" \
    --data-urlencode "query=${query}" \
    --data-urlencode "time=${now_ns}" \
    --data-urlencode "limit=1" 2>/dev/null || true)"

  local count
  count="$(python3 -c "
import json, sys
try:
    obj = json.loads(sys.argv[1])
    result = obj.get('data', {}).get('result', [])
    if not result:
        print('0')
    else:
        val = result[0].get('value', [None, '0'])
        print(val[1])
except Exception:
    print('0')
" "$response" 2>/dev/null || echo '0')"

  count="${count%%.*}"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0

  local status evidence layer repair
  if [[ "$count" -gt 0 ]]; then
    status="HEALTHY"
    evidence="log volume in last 1h: ${count} entries across all services"
    layer="none"
    repair="none"
  else
    status="WARNING"
    evidence="no logs from any service in Loki in the last 1h (count=0)"
    layer="promtail-to-loki-delivery"
    repair="none"
  fi

  result_add "LK-06" "${env}/loki-volume" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# run_loki_checks <env> [pt_status] [pt04_status] [log04_status]
#
# Runs LK-01 first and gates LK-02/03 per service on it; LK-06 once per
# env; LK-04 and LK-05 once per env. Synthesizes the LK-07 layer verdict
# from the optional cross-family inputs (same integration boundary
# documented in checks/logfile.sh and checks/promtail.sh): pt_status is
# the caller's combined PT-01+PT-02 health signal, pt04_status is PT-04's
# own status, log04_status is the LOG family's freshness verdict. When
# omitted, the LK-07 layer-specific branches simply never fire and the
# worst-of status is still correct on its own.
# ---------------------------------------------------------------------------
run_loki_checks() {
  local env="$1"
  local pt_status="${2:-}"
  local pt04_status="${3:-}"
  local log04_status="${4:-}"

  local lk01
  lk01="$(lk_check_01_container_ready)"

  local worst="HEALTHY"
  worst="$(_lk_worse_status "$worst" "$lk01")"

  local lk06
  lk06="$(lk_check_06_volume_sanity "$env" "$lk01")"
  worst="$(_lk_worse_status "$worst" "$lk06")"

  local any_lk02_warning=false
  local -a short_names=()
  local inventory_file="${LK_CONFIG_DIR}/inventory.${env}.yaml"

  if [[ -f "$inventory_file" ]] && _lk_detect_yaml_tool; then
    local count
    count="$(_lk_count "$inventory_file")"
    local i
    for (( i = 0; i < count; i++ )); do
      local name short_name
      name="$(_lk_field "$inventory_file" "$i" name)"
      short_name="${name#dhanman-}"
      short_names+=("$short_name")

      local lk02
      lk02="$(lk_check_02_recent_logs "$env" "$name" "$short_name" "$lk01")"
      worst="$(_lk_worse_status "$worst" "$lk02")"
      [[ "$lk02" == "WARNING" ]] && any_lk02_warning=true

      local lk03
      lk03="$(lk_check_03_latest_timestamp "$env" "$name" "$short_name" "$lk02")"
      worst="$(_lk_worse_status "$worst" "$lk03")"
    done
  fi

  local lk04
  lk04="$(lk_check_04_label_presence "$env" "$lk01" "${short_names[@]}")"
  worst="$(_lk_worse_status "$worst" "$lk04")"

  local lk05
  lk05="$(lk_check_05_ingestion_errors)"
  worst="$(_lk_worse_status "$worst" "$lk05")"

  local layer="none"
  local repair="none"
  local verdict_evidence="all Loki checks passing"

  if [[ "$lk01" == "CRITICAL" ]]; then
    layer="loki-process"
    repair="none"
    verdict_evidence="Loki container/readiness check failed — no automated repair script exists yet (flag for Phase 8)"
  elif [[ "$pt04_status" == "WARNING" && "$any_lk02_warning" == true ]]; then
    layer="promtail-misconfiguration"
    repair="$_LK_CONFIG_REPAIR"
    verdict_evidence="Promtail watching wrong path — logs not reaching Loki"
  elif [[ "$log04_status" == "HEALTHY" && "$pt_status" == "HEALTHY" && "$any_lk02_warning" == true ]]; then
    layer="promtail-to-loki-delivery"
    repair="$_LK_RESTART_REPAIR"
    verdict_evidence="Local log file fresh, Promtail running, but no recent data in Loki. Likely broken: Promtail push to Loki."
  fi

  result_add "LK-07" "${env}/loki-verdict" "$worst" "$verdict_evidence" "$layer" "$repair"

  printf '%s\n' "$worst"
  printf '%s\n' "$layer"
}
