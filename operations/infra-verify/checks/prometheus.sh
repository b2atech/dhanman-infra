#!/usr/bin/env bash
#
# prometheus.sh — PM family checks (Prometheus verification).
# This is a LIBRARY: source it, do not execute it directly.
#
# PM-01 runtime/readiness         PM-02 per-target health
# PM-03 missing/unexpected/duplicate target comparison
# PM-04 metric staleness (per service)  PM-05 exporter sweep
# PM-06 config reload + rule freshness  PM-07 key metric availability
#
# Confirmed facts from discovery.md / prometheus.yml.j2, used directly:
#   Prometheus URL: http://127.0.0.1:9090, container name: prometheus
#   --web.enable-lifecycle is enabled on the real server — this module
#   NEVER calls POST /-/reload or any other write/lifecycle endpoint;
#   every request here is a GET. Reload is a human-run repair script
#   (operations/repairs/prometheus/reload-prometheus.sh), not implemented
#   in this phase.
#   Exporter job names (from prometheus.yml.j2, same in qa and prod):
#   node, postgres, rabbitmq, nginx, redis (also blackbox_http,
#   blackbox_ssl, vault, minio, dhanman_services — used for the PM-03
#   "known job" allowlist, not as exporters to sweep).
#
# QUERY SAFETY: validate_prometheus_query is a narrow, regex-based
# allowlist — it accepts only the exact instant-query shapes this module
# issues (a bare metric name, metric{label="val"[,label="val"...]} with
# = or =~, or PM-04's fixed time()-timestamp(...) template) and rejects
# everything else, including any bracketed range-vector syntax (no range
# query is needed anywhere in Phase 4). Label/metric-name values
# themselves are never taken from free-form input — every value is
# either a hardcoded constant in this file or a value read from the
# generated inventory.<env>.yaml.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "prometheus.sh is a library — source it, do not execute it directly." >&2
  exit 1
fi

_PM_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly _PM_SCRIPT_DIR
PM_CONFIG_DIR="$(realpath -m "${_PM_SCRIPT_DIR}/../config")"
readonly PM_CONFIG_DIR

# shellcheck source=SCRIPTDIR/../lib/result.sh
source "${_PM_SCRIPT_DIR}/../lib/result.sh"

readonly _PM_BASE_URL="http://127.0.0.1:9090"
readonly _PM_CONTAINER_NAME="prometheus"
readonly _PM_CURL_TIMEOUT=10
readonly _PM_RESTART_WARN_THRESHOLD=5

# Environment-overridable thresholds (clearly named, documented defaults —
# no unexplained hardcoded production values). Export PM_STALENESS_WARN_
# SECONDS etc. before sourcing this file to override.
readonly _PM_STALENESS_WARN_SECONDS="${PM_STALENESS_WARN_SECONDS:-60}"
readonly _PM_STALENESS_CRIT_SECONDS="${PM_STALENESS_CRIT_SECONDS:-180}"
readonly _PM_SCRAPE_DURATION_WARN_SECONDS="${PM_SCRAPE_DURATION_WARN_SECONDS:-5}"
readonly _PM_RULE_STALE_SECONDS="${PM_RULE_STALE_SECONDS:-300}"

readonly _PM_TARGET_REPAIR="operations/repairs/prometheus/verify-prometheus-target.sh"
readonly _PM_CONFIG_VALIDATE_REPAIR="operations/repairs/prometheus/validate-prometheus-config.sh"
# _PM_RELOAD_REPAIR is documented for evidence text only — never invoked,
# and reload is only ever a manually-run script after validation, per
# discovery.md's Prometheus lifecycle-endpoint security note.
readonly _PM_RELOAD_REPAIR="operations/repairs/prometheus/reload-prometheus.sh"

readonly _PM_EXPECTED_EXPORTER_JOBS=(node postgres rabbitmq nginx redis)
readonly _PM_KNOWN_JOBS=(dhanman_services node postgres rabbitmq nginx redis blackbox_http blackbox_ssl vault minio)

readonly _PM_APP_METRIC_CANDIDATES=(
  http_server_request_duration_seconds_count
  http_requests_received_total
  http_request_duration_seconds_count
)
readonly _PM_NODE_METRIC_CANDIDATES=(node_cpu_seconds_total node_memory_MemAvailable_bytes node_filesystem_avail_bytes)
readonly _PM_POSTGRES_METRIC="pg_up"
readonly _PM_RABBITMQ_METRIC="rabbitmq_up"

PM_YAML_TOOL=""

# ---------------------------------------------------------------------------
# Inventory reading — same dual yq / python3+PyYAML convention as the
# other check families; independent (only depends on lib/result.sh).
# ---------------------------------------------------------------------------
_pm_detect_yaml_tool() {
  if [[ -n "$PM_YAML_TOOL" ]]; then
    return 0
  fi
  if command -v yq >/dev/null 2>&1; then
    PM_YAML_TOOL="yq"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    PM_YAML_TOOL="python3"
    return 0
  fi
  _result_log ERROR "Neither 'yq' nor 'python3 (with PyYAML)' is available for inventory read"
  return 1
}

_pm_count() {
  local file="$1"
  if [[ "$PM_YAML_TOOL" == "yq" ]]; then
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

_pm_field() {
  local file="$1" index="$2" field="$3"
  if [[ "$PM_YAML_TOOL" == "yq" ]]; then
    yq eval ".services[${index}].${field}" "$file"
  else
    python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
svc = data["services"][int(sys.argv[2])]
val = svc.get(sys.argv[3])
if val is None:
    print("null")
elif isinstance(val, bool):
    print("true" if val else "false")
else:
    print(val)
' "$file" "$index" "$field"
  fi
}

# ---------------------------------------------------------------------------
# Status severity ranking, used to compute the worst status across checks
# ---------------------------------------------------------------------------
_pm_status_rank() {
  case "$1" in
    CRITICAL) echo 4 ;;
    WARNING) echo 3 ;;
    UNKNOWN) echo 2 ;;
    NOT_CONFIGURED|NOT_APPLICABLE) echo 1 ;;
    *) echo 0 ;;
  esac
}

_pm_worse_status() {
  local a="$1" b="$2"
  local ra rb
  ra="$(_pm_status_rank "$a")"
  rb="$(_pm_status_rank "$b")"
  if [[ "$rb" -gt "$ra" ]]; then
    printf '%s' "$b"
  else
    printf '%s' "$a"
  fi
}

# ---------------------------------------------------------------------------
# validate_prometheus_query <query>
#
# Narrow allowlist, not a general-purpose guard: accepts only
#   - PM-04's fixed template: time() - timestamp(metric{label="val",...})
#   - a bare metric name, optionally followed by exactly one
#     {label=OP"value"[,label=OP"value"...]} selector (OP is = or =~)
# Rejects everything else, including any [range] syntax (no range query
# is used anywhere in this module) and empty {} selectors. The regex is
# anchored (^...$) so trailing/leading extra text — e.g. an injected
# " or other_metric" — cannot slip through.
# Prints "OK" and returns 0 on success; prints "REJECTED: <reason>" and
# returns 1 on failure.
# ---------------------------------------------------------------------------
validate_prometheus_query() {
  local query="$1"

  if [[ "$query" == *'['*']'* ]]; then
    printf 'REJECTED: range vector syntax not permitted'
    return 1
  fi

  if [[ "$query" == *'{}'* ]]; then
    printf 'REJECTED: empty {} selector'
    return 1
  fi

  if [[ "$query" =~ ^time\(\)\ -\ timestamp\([A-Za-z_][A-Za-z0-9_]*\{[^}]+\}\)$ ]]; then
    printf 'OK'
    return 0
  fi

  if [[ "$query" =~ ^[A-Za-z_][A-Za-z0-9_]*(\{[A-Za-z_][A-Za-z0-9_]*=~?\"[^\"]*\"(,[A-Za-z_][A-Za-z0-9_]*=~?\"[^\"]*\")*\})?$ ]]; then
    printf 'OK'
    return 0
  fi

  printf 'REJECTED: query does not match an approved template'
  return 1
}

# ---------------------------------------------------------------------------
# Embedded python3 helper: extracts a single scalar sample value from a
# Prometheus instant-query vector response. Distinguishes API/parse
# failure (ERROR), an empty result set (EMPTY — metric absent, not a
# failure), and a non-numeric sample (NOTNUMERIC — NaN/Inf) from a real
# numeric value (printed as-is).
# ---------------------------------------------------------------------------
read -r -d '' _PM_SCALAR_VALUE_PY <<'PYEOF' || true
import json
import sys

try:
    obj = json.loads(sys.argv[1])
except Exception:
    print("ERROR")
    sys.exit(0)

if obj.get("status") != "success":
    print("ERROR")
    sys.exit(0)

result = obj.get("data", {}).get("result", [])
if not result:
    print("EMPTY")
    sys.exit(0)

val = result[0].get("value", [None, None])
raw = val[1] if len(val) > 1 else None
if raw is None:
    print("EMPTY")
    sys.exit(0)

s = str(raw).strip().lower()
if s in ("nan", "inf", "+inf", "-inf"):
    print("NOTNUMERIC")
    sys.exit(0)

try:
    float(raw)
except Exception:
    print("NOTNUMERIC")
    sys.exit(0)

print(raw)
PYEOF

# ---------------------------------------------------------------------------
# PM-01: Prometheus runtime and readiness. Both container state AND the
# /-/ready HTTP check must pass for HEALTHY. 401/403 (auth) is classified
# distinctly from "down" — not expected on localhost today, but must
# never be misreported as an outage.
# ---------------------------------------------------------------------------
pm_check_01_ready() {
  local inspect_out
  inspect_out="$(docker inspect "$_PM_CONTAINER_NAME" --format '{{.State.Status}} {{.State.RestartCount}}' 2>/dev/null || true)"

  local container_status restart_count
  container_status="$(printf '%s' "$inspect_out" | awk '{print $1}')"
  restart_count="$(printf '%s' "$inspect_out" | awk '{print $2}')"
  [[ -z "$restart_count" ]] && restart_count=0

  local status evidence layer repair
  if [[ "$container_status" != "running" ]]; then
    status="CRITICAL"
    evidence="prometheus container status=${container_status:-unknown}, RestartCount=${restart_count}"
    layer="prometheus_runtime"
    repair="$_PM_TARGET_REPAIR"
    result_add "PM-01" "prometheus" "$status" "$evidence" "$layer" "$repair"
    printf '%s' "$status"
    return 0
  fi

  local curl_out http_code body
  curl_out="$(curl --silent --max-time "$_PM_CURL_TIMEOUT" --write-out $'\n%{http_code}' "${_PM_BASE_URL}/-/ready" 2>/dev/null || true)"
  http_code="$(printf '%s\n' "$curl_out" | tail -n 1)"
  body="$(printf '%s\n' "$curl_out" | sed '$d')"

  if [[ "$http_code" == "200" ]]; then
    status="HEALTHY"
    evidence="prometheus container running, /-/ready responded 200"
    layer="none"
    repair="none"
  elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    status="UNKNOWN"
    evidence="prometheus /-/ready returned ${http_code} (authentication) — not expected on localhost today; classified distinctly rather than reported as down"
    layer="prometheus_readiness"
    repair="none"
  elif [[ -z "$http_code" || "$http_code" == "000" ]]; then
    status="CRITICAL"
    evidence="prometheus container running but /-/ready connection failed or timed out"
    layer="prometheus_readiness"
    repair="$_PM_TARGET_REPAIR"
  else
    status="CRITICAL"
    evidence="prometheus container running but /-/ready returned http_code=${http_code} (body='${body}')"
    layer="prometheus_readiness"
    repair="$_PM_TARGET_REPAIR"
  fi

  if [[ "$status" == "HEALTHY" && "$restart_count" -ge "$_PM_RESTART_WARN_THRESHOLD" ]]; then
    status="WARNING"
    evidence="${evidence}; RestartCount=${restart_count} (>= ${_PM_RESTART_WARN_THRESHOLD} — possible restart loop)"
    layer="prometheus_runtime"
  fi

  result_add "PM-01" "prometheus" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# PM-02: per-target health for one dhanman_services target (job+instance).
# scrapeUrl and lastError are redacted before entering evidence — the
# full targets response is never stored.
# ---------------------------------------------------------------------------
pm_check_02_target_health() {
  local name="$1" job="$2" instance="$3" has_metrics="$4" pm01_status="$5"

  if [[ "$has_metrics" == "false" ]]; then
    result_add "PM-02" "$name" "NOT_APPLICABLE" "service has_metrics=false — metrics endpoint intentionally not scraped" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  if [[ "$pm01_status" == "CRITICAL" ]]; then
    result_add "PM-02" "$name" "NOT_APPLICABLE" "Prometheus not available (PM-01 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local response
  response="$(curl --silent --max-time "$_PM_CURL_TIMEOUT" "${_PM_BASE_URL}/api/v1/targets" 2>/dev/null || true)"

  local parsed
  parsed="$(python3 -c "$_PM_FIND_TARGET_PY" "$response" "$job" "$instance" 2>/dev/null || echo 'ERROR')"

  # NOTE: the field delimiter must NOT be tab/space/newline — bash's read
  # collapses consecutive whitespace-class IFS separators, which silently
  # shifts every field left whenever an empty field (e.g. lastError="")
  # appears before the end. \x1f (unit separator) is not whitespace, so
  # empty fields are preserved correctly.
  local found_flag health age_seconds scrape_duration last_error scrape_url
  IFS=$'\x1f' read -r found_flag health age_seconds scrape_duration last_error scrape_url <<< "$parsed"

  local status evidence layer repair
  if [[ "$found_flag" == "ERROR" ]]; then
    status="UNKNOWN"
    evidence="could not parse Prometheus targets response"
    layer="none"
    repair="none"
  elif [[ "$found_flag" == "MISSING" ]]; then
    status="CRITICAL"
    evidence="target job=${job} instance=${instance} not found in Prometheus active targets"
    layer="prometheus_targets"
    repair="$_PM_TARGET_REPAIR"
  else
    local sanitized_url sanitized_error
    sanitized_url="$(redact "$scrape_url")"
    sanitized_error="$(redact "$last_error")"

    if [[ "$health" != "up" ]]; then
      status="CRITICAL"
      evidence="target job=${job} instance=${instance} health=${health}"
      [[ -n "$last_error" ]] && evidence="${evidence}, lastError=${sanitized_error}"
      layer="prometheus_targets"
      repair="$_PM_TARGET_REPAIR"
    elif [[ "$age_seconds" -lt 0 ]]; then
      status="UNKNOWN"
      evidence="target job=${job} instance=${instance} health=up but lastScrape timestamp unparsable"
      layer="none"
      repair="none"
    elif [[ "$age_seconds" -gt "$_PM_STALENESS_CRIT_SECONDS" ]]; then
      status="CRITICAL"
      evidence="target job=${job} instance=${instance} lastScrape ${age_seconds}s ago (> ${_PM_STALENESS_CRIT_SECONDS}s)"
      layer="prometheus_targets"
      repair="$_PM_TARGET_REPAIR"
    elif [[ "$age_seconds" -gt "$_PM_STALENESS_WARN_SECONDS" ]]; then
      status="WARNING"
      evidence="target job=${job} instance=${instance} lastScrape ${age_seconds}s ago (> ${_PM_STALENESS_WARN_SECONDS}s)"
      layer="prometheus_targets"
      repair="none"
    else
      local slow
      slow="$(awk -v d="$scrape_duration" -v lim="$_PM_SCRAPE_DURATION_WARN_SECONDS" 'BEGIN{print (d+0>lim)?"1":"0"}' 2>/dev/null || echo 0)"
      if [[ "$slow" == "1" ]]; then
        status="WARNING"
        evidence="target job=${job} instance=${instance} healthy but scrapeDuration=${scrape_duration}s (> ${_PM_SCRAPE_DURATION_WARN_SECONDS}s)"
        layer="prometheus_targets"
        repair="none"
      else
        status="HEALTHY"
        evidence="target job=${job} instance=${instance} health=up, lastScrape ${age_seconds}s ago, scrapeDuration=${scrape_duration}s"
        layer="none"
        repair="none"
      fi
    fi
    evidence="${evidence} scrapeUrl=${sanitized_url}"
  fi

  result_add "PM-02" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

read -r -d '' _PM_FIND_TARGET_PY <<'PYEOF' || true
import json
import sys
from datetime import datetime, timezone

resp, job, instance = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    obj = json.loads(resp)
except Exception:
    print("ERROR")
    sys.exit(0)

if obj.get("status") != "success":
    print("ERROR")
    sys.exit(0)

targets = obj.get("data", {}).get("activeTargets", [])
found = None
for t in targets:
    labels = t.get("labels", {})
    if labels.get("job") == job and labels.get("instance") == instance:
        found = t
        break

if found is None:
    print("MISSING")
    sys.exit(0)

health = found.get("health", "unknown")
last_scrape = found.get("lastScrape", "") or ""
scrape_duration = found.get("lastScrapeDuration", 0)
last_error = (found.get("lastError", "") or "").replace("\t", " ").replace("\n", " ")
scrape_url = found.get("scrapeUrl", "") or ""

age_seconds = -1
if last_scrape:
    try:
        ts = last_scrape.replace("Z", "+00:00")
        dt = datetime.fromisoformat(ts)
        age_seconds = int((datetime.now(timezone.utc) - dt).total_seconds())
    except Exception:
        age_seconds = -1

print(f"FOUND\x1f{health}\x1f{age_seconds}\x1f{scrape_duration}\x1f{last_error}\x1f{scrape_url}")
PYEOF

# ---------------------------------------------------------------------------
# PM-03: missing / unexpected / duplicate dhanman_services target
# comparison, env-wide (one result per run, not per service). Callers
# must exclude has_metrics=false services from expected_pairs — they are
# never "missing" by design.
# ---------------------------------------------------------------------------
pm_check_03_target_comparison() {
  local env="$1"
  shift
  local -a expected_pairs=("$@")

  local response
  response="$(curl --silent --max-time "$_PM_CURL_TIMEOUT" "${_PM_BASE_URL}/api/v1/targets" 2>/dev/null || true)"

  local expected_json
  if [[ ${#expected_pairs[@]} -eq 0 ]]; then
    expected_json="[]"
  else
    expected_json="$(python3 -c '
import json, sys
pairs = sys.argv[1:]
out = []
for p in pairs:
    name, port = p.split(":", 1)
    out.append({"name": name, "instance": f"127.0.0.1:{port}"})
print(json.dumps(out))
' "${expected_pairs[@]}" 2>/dev/null || echo '[]')"
  fi

  local known_jobs_json
  known_jobs_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${_PM_KNOWN_JOBS[@]}")"

  local parsed
  parsed="$(python3 -c "$_PM_COMPARE_TARGETS_PY" "$response" "$expected_json" "$known_jobs_json" 2>/dev/null || echo 'ERROR')"

  if [[ "$parsed" == "ERROR" ]]; then
    result_add "PM-03" "${env}/targets" "UNKNOWN" "could not parse Prometheus targets response" "none" "none"
    printf 'UNKNOWN'
    return 0
  fi

  local missing unexpected_svc duplicates unexpected_jobs
  missing="$(printf '%s\n' "$parsed" | sed -n '1p')"; missing="${missing#missing=}"
  unexpected_svc="$(printf '%s\n' "$parsed" | sed -n '2p')"; unexpected_svc="${unexpected_svc#unexpected=}"
  duplicates="$(printf '%s\n' "$parsed" | sed -n '3p')"; duplicates="${duplicates#duplicates=}"
  unexpected_jobs="$(printf '%s\n' "$parsed" | sed -n '4p')"; unexpected_jobs="${unexpected_jobs#unexpected_jobs=}"

  local status evidence layer repair
  if [[ -n "$missing" ]]; then
    status="CRITICAL"
    evidence="expected service targets missing from Prometheus: ${missing}"
    layer="prometheus_targets"
    repair="$_PM_TARGET_REPAIR"
  elif [[ -n "$duplicates" ]]; then
    status="WARNING"
    evidence="duplicate active targets detected (possible config drift): ${duplicates}"
    layer="prometheus_targets"
    repair="$_PM_TARGET_REPAIR"
  elif [[ -n "$unexpected_svc" || -n "$unexpected_jobs" ]]; then
    status="WARNING"
    evidence="unexpected targets present in Prometheus"
    [[ -n "$unexpected_svc" ]] && evidence="${evidence}; unexpected service instances: ${unexpected_svc}"
    [[ -n "$unexpected_jobs" ]] && evidence="${evidence}; unexpected job names: ${unexpected_jobs}"
    layer="prometheus_targets"
    repair="none"
  else
    status="HEALTHY"
    evidence="all expected service targets present, no unexpected or duplicate targets"
    layer="none"
    repair="none"
  fi

  result_add "PM-03" "${env}/targets" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

read -r -d '' _PM_COMPARE_TARGETS_PY <<'PYEOF' || true
import json
import sys
from collections import Counter

resp, expected_json, known_jobs_json = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    obj = json.loads(resp)
    targets = obj.get("data", {}).get("activeTargets", [])
except Exception:
    print("ERROR")
    sys.exit(0)

expected = json.loads(expected_json)
known_jobs = set(json.loads(known_jobs_json))

svc_instances = []
all_jobs = set()
for t in targets:
    labels = t.get("labels", {})
    job = labels.get("job", "")
    all_jobs.add(job)
    if job == "dhanman_services":
        svc_instances.append(labels.get("instance", ""))

expected_by_instance = {e["instance"]: e["name"] for e in expected}

missing = [name for inst, name in expected_by_instance.items() if inst not in svc_instances]
unexpected = [inst for inst in svc_instances if inst not in expected_by_instance]

counts = Counter(svc_instances)
duplicates = sorted(set(inst for inst, c in counts.items() if c > 1))

unexpected_jobs = sorted(j for j in all_jobs if j and j not in known_jobs)

print("missing=" + ",".join(missing))
print("unexpected=" + ",".join(unexpected))
print("duplicates=" + ",".join(duplicates))
print("unexpected_jobs=" + ",".join(unexpected_jobs))
PYEOF

# ---------------------------------------------------------------------------
# PM-04: metric staleness, per service — time()-timestamp(up{job=...,
# instance=...}) refined from the brief's env-wide concept into a
# per-service instantiation (the brief explicitly asks for "per-service
# evaluation using validated inventory-derived label values", which a
# bare job-only selector can't provide since it returns a vector with one
# series per instance, not a single value).
# ---------------------------------------------------------------------------
pm_check_04_metric_staleness() {
  local name="$1" job="$2" instance="$3" has_metrics="$4" pm01_status="$5"

  if [[ "$has_metrics" == "false" ]]; then
    result_add "PM-04" "$name" "NOT_APPLICABLE" "service has_metrics=false" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  if [[ "$pm01_status" == "CRITICAL" ]]; then
    result_add "PM-04" "$name" "NOT_APPLICABLE" "Prometheus not available (PM-01 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  # job/instance are always supplied by run_pm_checks from the generated
  # inventory file, never from free-form input; validated here anyway as
  # defense in depth against a future caller change.
  local query="time() - timestamp(up{job=\"${job}\",instance=\"${instance}\"})"
  local rc=0
  local validation
  validation="$(validate_prometheus_query "$query")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    result_add "PM-04" "$name" "NOT_CONFIGURED" "query safety violation — query rejected (${validation})" "none" "none"
    printf 'NOT_CONFIGURED'
    return 0
  fi

  local response
  response="$(curl --silent --max-time "$_PM_CURL_TIMEOUT" -G "${_PM_BASE_URL}/api/v1/query" \
    --data-urlencode "query=${query}" 2>/dev/null || true)"

  local parsed
  parsed="$(python3 -c "$_PM_SCALAR_VALUE_PY" "$response" 2>/dev/null || echo 'ERROR')"

  local status evidence layer repair
  if [[ "$parsed" == "ERROR" ]]; then
    status="UNKNOWN"
    evidence="could not parse Prometheus query response for job=${job} instance=${instance}"
    layer="none"
    repair="none"
  elif [[ "$parsed" == "EMPTY" ]]; then
    status="UNKNOWN"
    evidence="no series returned for job=${job} instance=${instance} (metric absent, not a query failure)"
    layer="none"
    repair="none"
  elif [[ "$parsed" == "NOTNUMERIC" ]]; then
    status="UNKNOWN"
    evidence="Prometheus returned a non-numeric sample (NaN/Inf) for job=${job} instance=${instance}"
    layer="none"
    repair="none"
  else
    local age="${parsed%%.*}"
    if [[ ! "$age" =~ ^-?[0-9]+$ ]]; then
      status="UNKNOWN"
      evidence="unexpected staleness value '${parsed}' for job=${job} instance=${instance}"
      layer="none"
      repair="none"
    elif [[ "$age" -lt 0 ]]; then
      status="UNKNOWN"
      evidence="negative staleness value (clock skew?) for job=${job} instance=${instance}: ${parsed}s"
      layer="none"
      repair="none"
    elif [[ "$age" -gt "$_PM_STALENESS_CRIT_SECONDS" ]]; then
      status="CRITICAL"
      evidence="metric staleness ${age}s for job=${job} instance=${instance} (> ${_PM_STALENESS_CRIT_SECONDS}s)"
      layer="prometheus_targets"
      repair="$_PM_TARGET_REPAIR"
    elif [[ "$age" -gt "$_PM_STALENESS_WARN_SECONDS" ]]; then
      status="WARNING"
      evidence="metric staleness ${age}s for job=${job} instance=${instance} (> ${_PM_STALENESS_WARN_SECONDS}s)"
      layer="prometheus_targets"
      repair="none"
    else
      status="HEALTHY"
      evidence="metric fresh: staleness ${age}s for job=${job} instance=${instance}"
      layer="none"
      repair="none"
    fi
  fi

  result_add "PM-04" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# PM-05: exporter sweep. expected_jobs defaults to _PM_EXPECTED_EXPORTER_
# JOBS; callers may override for testing (a single empty-string element
# signals "no exporters configured for this environment" -> NOT_CONFIGURED
# — a documented test-only scenario, since the real prometheus.yml.j2
# always configures the same five exporters in both qa and prod).
# ---------------------------------------------------------------------------
pm_check_05_exporter_sweep() {
  local pm01_status="$1"
  shift
  local -a expected_jobs=("$@")

  if [[ "$pm01_status" == "CRITICAL" ]]; then
    result_add "PM-05" "prometheus/exporters" "NOT_APPLICABLE" "Prometheus not available (PM-01 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  if [[ ${#expected_jobs[@]} -eq 0 ]]; then
    expected_jobs=("${_PM_EXPECTED_EXPORTER_JOBS[@]}")
  elif [[ ${#expected_jobs[@]} -eq 1 && -z "${expected_jobs[0]}" ]]; then
    result_add "PM-05" "prometheus/exporters" "NOT_CONFIGURED" "no exporter jobs configured for this environment" "none" "none"
    printf 'NOT_CONFIGURED'
    return 0
  fi

  local regex
  regex="$(printf '%s|' "${expected_jobs[@]}")"
  regex="${regex%|}"
  local query="up{job=~\"${regex}\"}"

  local rc=0
  local validation
  validation="$(validate_prometheus_query "$query")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    result_add "PM-05" "prometheus/exporters" "NOT_CONFIGURED" "query safety violation — query rejected (${validation})" "none" "none"
    printf 'NOT_CONFIGURED'
    return 0
  fi

  local response
  response="$(curl --silent --max-time "$_PM_CURL_TIMEOUT" -G "${_PM_BASE_URL}/api/v1/query" \
    --data-urlencode "query=${query}" 2>/dev/null || true)"

  local expected_json
  expected_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${expected_jobs[@]}")"

  local parsed
  parsed="$(python3 -c "$_PM_EXPORTER_SWEEP_PY" "$response" "$expected_json" 2>/dev/null || echo 'ERROR')"

  if [[ "$parsed" == "ERROR" ]]; then
    result_add "PM-05" "prometheus/exporters" "UNKNOWN" "could not parse Prometheus exporter query response" "none" "none"
    printf 'UNKNOWN'
    return 0
  fi

  local down missing dup
  down="$(printf '%s\n' "$parsed" | sed -n '1p')"; down="${down#down=}"
  missing="$(printf '%s\n' "$parsed" | sed -n '2p')"; missing="${missing#missing=}"
  dup="$(printf '%s\n' "$parsed" | sed -n '3p')"; dup="${dup#duplicates=}"

  local status evidence layer repair
  if [[ -n "$down" ]]; then
    status="CRITICAL"
    evidence="exporter(s) down (job present but up=0): ${down}"
    layer="prometheus_targets"
    repair="$_PM_TARGET_REPAIR"
  elif [[ -n "$missing" ]]; then
    status="WARNING"
    evidence="expected exporter job(s) not present in Prometheus: ${missing}"
    layer="prometheus_targets"
    repair="$_PM_TARGET_REPAIR"
  elif [[ -n "$dup" ]]; then
    status="WARNING"
    evidence="duplicate exporter target(s) detected: ${dup}"
    layer="prometheus_targets"
    repair="none"
  else
    status="HEALTHY"
    evidence="all expected exporters present and up: ${expected_jobs[*]}"
    layer="none"
    repair="none"
  fi

  result_add "PM-05" "prometheus/exporters" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

read -r -d '' _PM_EXPORTER_SWEEP_PY <<'PYEOF' || true
import json
import sys
from collections import Counter

resp, expected_json = sys.argv[1], sys.argv[2]
expected_jobs = json.loads(expected_json)

try:
    obj = json.loads(resp)
    result = obj.get("data", {}).get("result", [])
except Exception:
    print("ERROR")
    sys.exit(0)

seen_jobs = []
down_jobs = []
for series in result:
    metric = series.get("metric", {})
    job = metric.get("job", "")
    val = series.get("value", [None, "0"])
    v = val[1] if len(val) > 1 else "0"
    seen_jobs.append(job)
    try:
        if float(v) == 0:
            down_jobs.append(job)
    except Exception:
        pass

missing = [j for j in expected_jobs if j not in seen_jobs]
counts = Counter(seen_jobs)
duplicates = sorted(set(j for j, c in counts.items() if c > 1))
down = sorted(set(j for j in down_jobs if j not in missing))

print("down=" + ",".join(down))
print("missing=" + ",".join(missing))
print("duplicates=" + ",".join(duplicates))
PYEOF

# ---------------------------------------------------------------------------
# PM-06: config reload success + rule-group evaluation freshness.
# Read-only: never calls POST /-/reload. rules_expected controls whether
# the rule-freshness sub-check runs at all (this repo's alert-rules.yml.j2
# always configures rules, so it defaults to true).
# ---------------------------------------------------------------------------
pm_check_06_config_and_rules() {
  local pm01_status="$1"
  local rules_expected="${2:-true}"

  if [[ "$pm01_status" == "CRITICAL" ]]; then
    result_add "PM-06" "prometheus/config" "NOT_APPLICABLE" "Prometheus not available (PM-01 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local reload_query="prometheus_config_last_reload_successful"
  local rc=0
  local validation
  validation="$(validate_prometheus_query "$reload_query")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    result_add "PM-06" "prometheus/config" "NOT_CONFIGURED" "query safety violation — query rejected (${validation})" "none" "none"
    printf 'NOT_CONFIGURED'
    return 0
  fi

  local reload_response
  reload_response="$(curl --silent --max-time "$_PM_CURL_TIMEOUT" -G "${_PM_BASE_URL}/api/v1/query" \
    --data-urlencode "query=${reload_query}" 2>/dev/null || true)"

  local reload_value
  reload_value="$(python3 -c "$_PM_SCALAR_VALUE_PY" "$reload_response" 2>/dev/null || echo 'ERROR')"

  local status evidence layer repair
  if [[ "$reload_value" == "ERROR" ]]; then
    status="UNKNOWN"; evidence="could not query prometheus_config_last_reload_successful"; layer="none"; repair="none"
  elif [[ "$reload_value" == "EMPTY" ]]; then
    status="UNKNOWN"; evidence="prometheus_config_last_reload_successful metric absent"; layer="none"; repair="none"
  elif [[ "$reload_value" == "NOTNUMERIC" ]]; then
    status="UNKNOWN"; evidence="prometheus_config_last_reload_successful returned a non-numeric value"; layer="none"; repair="none"
  elif awk -v v="$reload_value" 'BEGIN{exit !(v==1)}' 2>/dev/null; then
    status="HEALTHY"; evidence="prometheus_config_last_reload_successful=1"; layer="none"; repair="none"
  else
    status="CRITICAL"
    evidence="prometheus_config_last_reload_successful=${reload_value} (expected 1) — validate config before any reload (${_PM_RELOAD_REPAIR} is manual-only, never auto-invoked)"
    layer="prometheus_configuration"
    repair="$_PM_CONFIG_VALIDATE_REPAIR"
  fi

  if [[ "$rules_expected" == "true" && "$status" == "HEALTHY" ]]; then
    local rule_query="prometheus_rule_group_last_evaluation_timestamp_seconds"
    local rrc=0
    local rvalidation
    rvalidation="$(validate_prometheus_query "$rule_query")" || rrc=$?
    if [[ $rrc -ne 0 ]]; then
      status="NOT_CONFIGURED"
      evidence="${evidence}; rule query safety violation (${rvalidation})"
    else
      local rule_response
      rule_response="$(curl --silent --max-time "$_PM_CURL_TIMEOUT" -G "${_PM_BASE_URL}/api/v1/query" \
        --data-urlencode "query=${rule_query}" 2>/dev/null || true)"

      local rule_ts
      rule_ts="$(python3 -c "$_PM_SCALAR_VALUE_PY" "$rule_response" 2>/dev/null || echo 'ERROR')"

      if [[ "$rule_ts" == "ERROR" ]]; then
        status="UNKNOWN"
        evidence="${evidence}; could not query rule evaluation timestamp"
      elif [[ "$rule_ts" == "EMPTY" ]]; then
        status="WARNING"
        evidence="${evidence}; rules expected but prometheus_rule_group_last_evaluation_timestamp_seconds metric absent"
        layer="prometheus_rules"
      elif [[ "$rule_ts" == "NOTNUMERIC" ]]; then
        status="UNKNOWN"
        evidence="${evidence}; rule evaluation timestamp metric returned a non-numeric value"
      else
        local now rule_age
        now="$(date +%s)"
        rule_age=$(( now - ${rule_ts%%.*} ))
        if [[ "$rule_age" -gt "$_PM_RULE_STALE_SECONDS" ]]; then
          status="WARNING"
          evidence="${evidence}; rule evaluation stale: ${rule_age}s ago (> ${_PM_RULE_STALE_SECONDS}s)"
          layer="prometheus_rules"
        else
          evidence="${evidence}; rule evaluation fresh: ${rule_age}s ago"
        fi
      fi
    fi
  elif [[ "$rules_expected" != "true" ]]; then
    evidence="${evidence}; rules not configured for this environment (skipped)"
  fi

  result_add "PM-06" "prometheus/config" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# PM-07: key metric availability. target_type selects the candidate
# metric-name list; the first candidate that returns a non-empty result
# is reported as the present metric. Never invents success for an
# unsupported metric family, and defers to PM-02/PM-05 for "target down"
# so a down target doesn't also produce a duplicate CRITICAL here.
# ---------------------------------------------------------------------------
pm_check_07_key_metrics() {
  local target_type="$1" target_name="$2"
  local instance="${3:-}"
  local has_metrics="${4:-true}"
  local target_up_status="${5:-}"

  if [[ "$has_metrics" == "false" ]]; then
    result_add "PM-07" "$target_name" "NOT_APPLICABLE" "metrics intentionally unsupported for this target" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  if [[ "$target_up_status" == "CRITICAL" ]]; then
    result_add "PM-07" "$target_name" "NOT_APPLICABLE" "target already reported down (PM-02/PM-05 owns that failure) — not duplicating as a metrics-exposure issue" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local -a candidates=()
  case "$target_type" in
    app) candidates=("${_PM_APP_METRIC_CANDIDATES[@]}") ;;
    node) candidates=("${_PM_NODE_METRIC_CANDIDATES[@]}") ;;
    postgres) candidates=("$_PM_POSTGRES_METRIC") ;;
    rabbitmq) candidates=("$_PM_RABBITMQ_METRIC") ;;
    *)
      result_add "PM-07" "$target_name" "UNKNOWN" "unsupported target_type '${target_type}'" "none" "none"
      printf 'UNKNOWN'
      return 0
      ;;
  esac

  local found_metric=""
  local metric
  for metric in "${candidates[@]}"; do
    local query="$metric"
    [[ -n "$instance" ]] && query="${metric}{instance=\"${instance}\"}"

    local rc=0
    local validation
    validation="$(validate_prometheus_query "$query")" || rc=$?
    [[ $rc -ne 0 ]] && continue

    local response
    response="$(curl --silent --max-time "$_PM_CURL_TIMEOUT" -G "${_PM_BASE_URL}/api/v1/query" \
      --data-urlencode "query=${query}" 2>/dev/null || true)"

    local val
    val="$(python3 -c "$_PM_SCALAR_VALUE_PY" "$response" 2>/dev/null || echo 'ERROR')"

    if [[ "$val" != "EMPTY" && "$val" != "ERROR" ]]; then
      found_metric="$metric"
      break
    fi
  done

  local status evidence layer repair
  if [[ -n "$found_metric" ]]; then
    status="HEALTHY"
    evidence="key metric present: ${found_metric}"
    layer="none"
    repair="none"
  else
    status="WARNING"
    evidence="none of the expected key metrics were queryable: ${candidates[*]}"
    layer="metrics_exposure_or_scrape_configuration"
    repair="none"
  fi

  result_add "PM-07" "$target_name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# run_pm_checks <env> — loops every service in inventory.<env>.yaml for
# PM-02/04/07(app); runs PM-01/03/05/06/07(node,postgres,rabbitmq) once.
# Returns the worst status across all PM checks.
# ---------------------------------------------------------------------------
run_pm_checks() {
  local env="$1"
  local inventory_file="${PM_CONFIG_DIR}/inventory.${env}.yaml"

  local pm01
  pm01="$(pm_check_01_ready)"

  local worst="HEALTHY"
  worst="$(_pm_worse_status "$worst" "$pm01")"

  local -a expected_pairs=()

  if [[ -f "$inventory_file" ]] && _pm_detect_yaml_tool; then
    local count
    count="$(_pm_count "$inventory_file")"
    local i
    for (( i = 0; i < count; i++ )); do
      local name port has_metrics instance
      name="$(_pm_field "$inventory_file" "$i" name)"
      port="$(_pm_field "$inventory_file" "$i" port)"
      has_metrics="$(_pm_field "$inventory_file" "$i" has_metrics)"
      instance="127.0.0.1:${port}"

      [[ "$has_metrics" != "false" ]] && expected_pairs+=("${name}:${port}")

      local pm02
      pm02="$(pm_check_02_target_health "$name" "dhanman_services" "$instance" "$has_metrics" "$pm01")"
      worst="$(_pm_worse_status "$worst" "$pm02")"

      local pm04
      pm04="$(pm_check_04_metric_staleness "$name" "dhanman_services" "$instance" "$has_metrics" "$pm01")"
      worst="$(_pm_worse_status "$worst" "$pm04")"

      local pm07
      pm07="$(pm_check_07_key_metrics "app" "$name" "$instance" "$has_metrics" "$pm02")"
      worst="$(_pm_worse_status "$worst" "$pm07")"
    done
  fi

  local pm03
  pm03="$(pm_check_03_target_comparison "$env" "${expected_pairs[@]}")"
  worst="$(_pm_worse_status "$worst" "$pm03")"

  local pm05
  pm05="$(pm_check_05_exporter_sweep "$pm01")"
  worst="$(_pm_worse_status "$worst" "$pm05")"

  local pm06
  pm06="$(pm_check_06_config_and_rules "$pm01" "true")"
  worst="$(_pm_worse_status "$worst" "$pm06")"

  local pm07_node
  pm07_node="$(pm_check_07_key_metrics "node" "${env}/node" "127.0.0.1:9100" "true" "$pm05")"
  worst="$(_pm_worse_status "$worst" "$pm07_node")"

  local pm07_pg
  pm07_pg="$(pm_check_07_key_metrics "postgres" "${env}/postgres" "127.0.0.1:9187" "true" "$pm05")"
  worst="$(_pm_worse_status "$worst" "$pm07_pg")"

  local pm07_rmq
  pm07_rmq="$(pm_check_07_key_metrics "rabbitmq" "${env}/rabbitmq" "127.0.0.1:15692" "true" "$pm05")"
  worst="$(_pm_worse_status "$worst" "$pm07_rmq")"

  printf '%s' "$worst"
}
