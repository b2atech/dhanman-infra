#!/usr/bin/env bash
#
# health.sh — HLT family checks (health endpoint verification).
# This is a LIBRARY: source it, do not execute it directly.
#
# HLT-01 endpoint reachability/latency   HLT-02 body parse (plain-text-first,
# JSON fallback)   HLT-03 dependency extraction (JSON only)   HLT-04 verdict
#
# Confirmed baseline (discovery.md, owner-verified via SSH on QA):
# dhanman-common QA (port 5200) returns plain text "Healthy" — no JSON, no
# per-dependency entries. HLT-02 therefore tries the plain-text match FIRST
# and only falls back to JSON parsing when that doesn't match, and never
# treats an absent JSON body as an error.
#
# JSON parsing uses python3 exclusively (never eval, never grep-based
# parsing of JSON structure) per the T1.4 constraint.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "health.sh is a library — source it, do not execute it directly." >&2
  exit 1
fi

_HLT_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly _HLT_SCRIPT_DIR
HLT_CONFIG_DIR="$(realpath -m "${_HLT_SCRIPT_DIR}/../config")"
readonly HLT_CONFIG_DIR

# shellcheck source=SCRIPTDIR/../lib/result.sh
source "${_HLT_SCRIPT_DIR}/../lib/result.sh"

readonly _HLT_SLOW_THRESHOLD_SECONDS=2
readonly _HLT_EVIDENCE_EXCERPT_MAX=200
readonly _HLT_RESTART_REPAIR="operations/repairs/service/restart-one-specific-service.sh"

HLT_YAML_TOOL=""

# ---------------------------------------------------------------------------
# Inventory reading — same dual yq / python3+PyYAML convention as
# checks/services.sh, kept independent so health.sh has no dependency on
# services.sh (only on lib/result.sh, per the T1.4 spec).
# ---------------------------------------------------------------------------
_hlt_detect_yaml_tool() {
  if [[ -n "$HLT_YAML_TOOL" ]]; then
    return 0
  fi
  if command -v yq >/dev/null 2>&1; then
    HLT_YAML_TOOL="yq"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    HLT_YAML_TOOL="python3"
    return 0
  fi
  _result_log ERROR "Neither 'yq' nor 'python3 (with PyYAML)' is available for inventory read"
  return 1
}

_hlt_count() {
  local file="$1"
  if [[ "$HLT_YAML_TOOL" == "yq" ]]; then
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

_hlt_field() {
  local file="$1" index="$2" field="$3"
  if [[ "$HLT_YAML_TOOL" == "yq" ]]; then
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
# Status severity ranking, used to compute the worst status across services
# ---------------------------------------------------------------------------
_hlt_status_rank() {
  case "$1" in
    CRITICAL) echo 4 ;;
    WARNING) echo 3 ;;
    UNKNOWN) echo 2 ;;
    NOT_CONFIGURED|NOT_APPLICABLE) echo 1 ;;
    *) echo 0 ;;
  esac
}

_hlt_worse_status() {
  local a="$1" b="$2"
  local ra rb
  ra="$(_hlt_status_rank "$a")"
  rb="$(_hlt_status_rank "$b")"
  if [[ "$rb" -gt "$ra" ]]; then
    printf '%s' "$b"
  else
    printf '%s' "$a"
  fi
}

# ---------------------------------------------------------------------------
# Embedded python3 helpers
# ---------------------------------------------------------------------------

# _HLT_PARSE_BODY_PY: argv[1] = raw (unredacted) response body.
# Prints two lines: status (HEALTHY/WARNING/CRITICAL/UNKNOWN), then the
# JSON "entries" object as compact JSON (or an empty line if absent).
# Plain-text match is tried first and is an exact match after trimming —
# a JSON body (starts with "{") will never satisfy it, so it always falls
# through to the JSON attempt correctly.
read -r -d '' _HLT_PARSE_BODY_PY <<'PYEOF' || true
import json
import sys

body = sys.argv[1]
trimmed = body.strip()
lowered = trimmed.lower()

plain_map = {"healthy": "HEALTHY", "degraded": "WARNING", "unhealthy": "CRITICAL"}
if lowered in plain_map:
    print(plain_map[lowered])
    print("")
    sys.exit(0)

try:
    obj = json.loads(trimmed)
except (json.JSONDecodeError, ValueError):
    print("UNKNOWN")
    print("")
    sys.exit(0)

if not isinstance(obj, dict) or "status" not in obj:
    print("UNKNOWN")
    print("")
    sys.exit(0)

status_val = str(obj["status"]).strip().lower()
mapped = plain_map.get(status_val, "UNKNOWN")
print(mapped)

entries = obj.get("entries")
if isinstance(entries, dict):
    print(json.dumps(entries))
else:
    print("")
PYEOF

# _HLT_DEPS_PY: argv[1] = entries JSON object (compact). Prints a
# comma-separated list of dependency names whose status != "Healthy".
read -r -d '' _HLT_DEPS_PY <<'PYEOF' || true
import json
import sys

try:
    entries = json.loads(sys.argv[1]) if sys.argv[1] else {}
except (json.JSONDecodeError, ValueError):
    entries = {}

failed = []
if isinstance(entries, dict):
    for dep_name, dep_info in entries.items():
        dep_status = ""
        if isinstance(dep_info, dict):
            dep_status = str(dep_info.get("status", "")).strip().lower()
        if dep_status and dep_status != "healthy":
            failed.append(dep_name)

print(",".join(failed))
PYEOF

# ---------------------------------------------------------------------------
# _hlt_fetch <url> <timeout_seconds>
#
# Runs in a subshell so its `trap ... EXIT` is scoped to the subshell only
# and can never clobber an EXIT trap set by the calling script (e.g.
# run-infra-report.sh's lock-release trap). Prints one line:
#   "<http_code> <time_total> <base64-encoded body>"
# Base64 avoids any issue with embedded newlines/spaces in the body when
# passed back through command substitution.
# ---------------------------------------------------------------------------
_hlt_fetch() {
  local url="$1" timeout_s="$2"
  (
    local tmpfile
    tmpfile="$(mktemp)"
    trap 'rm -f "$tmpfile"' EXIT

    local curl_out
    curl_out="$(curl --silent --max-time "$timeout_s" \
      --write-out $'%{http_code}\n%{time_total}' \
      --output "$tmpfile" "$url" 2>/dev/null || true)"

    local http_code time_total
    http_code="$(printf '%s\n' "$curl_out" | sed -n '1p')"
    time_total="$(printf '%s\n' "$curl_out" | sed -n '2p')"

    local body_b64
    body_b64="$(base64 -w0 "$tmpfile" 2>/dev/null || true)"

    printf '%s %s %s\n' "$http_code" "$time_total" "$body_b64"
  )
}

# ---------------------------------------------------------------------------
# HLT-01: endpoint exists and responds within timeout
# Prints two lines: status, then base64-encoded body (for the caller to
# forward into HLT-02 without a second network call).
# ---------------------------------------------------------------------------
hlt_check_01_endpoint() {
  local port="$1" name="$2" timeout_s="$3"
  local url="http://127.0.0.1:${port}/health"

  local fetch_out
  fetch_out="$(_hlt_fetch "$url" "$timeout_s")"

  local http_code time_total body_b64
  read -r http_code time_total body_b64 <<< "$fetch_out"

  local status evidence layer repair
  if [[ -z "$http_code" || "$http_code" == "000" ]]; then
    status="CRITICAL"
    evidence="${url}: connection failed or timed out"
    layer="network"
    repair="none"
  elif [[ ! "$http_code" =~ ^2 ]]; then
    status="CRITICAL"
    evidence="${url}: HTTP ${http_code} in ${time_total}s"
    layer="network"
    repair="none"
  else
    local slow
    slow="$(awk -v t="$time_total" -v lim="$_HLT_SLOW_THRESHOLD_SECONDS" 'BEGIN { print (t > lim) ? "1" : "0" }')"
    if [[ "$slow" == "1" ]]; then
      status="WARNING"
      evidence="${url}: HTTP ${http_code} in ${time_total}s (> ${_HLT_SLOW_THRESHOLD_SECONDS}s)"
      layer="performance"
      repair="none"
    else
      status="HEALTHY"
      evidence="${url}: HTTP ${http_code} in ${time_total}s"
      layer="none"
      repair="none"
    fi
  fi

  result_add "HLT-01" "$name" "$status" "$evidence" "$layer" "$repair"

  printf '%s\n' "$status"
  printf '%s\n' "$body_b64"
}

# ---------------------------------------------------------------------------
# HLT-02: body parse — tolerant, plain-text-first.
#
# The RAW (unredacted) body is used for status determination and JSON
# parsing — redaction must never run before JSON parsing, since HTML-
# escaping quote characters would corrupt valid JSON syntax. redact() is
# applied only to the excerpt that goes into the stored evidence string.
#
# Prints two lines: status, then the entries JSON (or empty line).
# ---------------------------------------------------------------------------
hlt_check_02_body_parse() {
  local name="$1" body="$2"

  local parse_out
  parse_out="$(python3 -c "$_HLT_PARSE_BODY_PY" "$body")"

  local status entries_json
  status="$(printf '%s\n' "$parse_out" | sed -n '1p')"
  entries_json="$(printf '%s\n' "$parse_out" | sed -n '2p')"

  local redacted_excerpt
  redacted_excerpt="$(redact "$body")"
  if [[ ${#redacted_excerpt} -gt $_HLT_EVIDENCE_EXCERPT_MAX ]]; then
    redacted_excerpt="${redacted_excerpt:0:$_HLT_EVIDENCE_EXCERPT_MAX}"
  fi

  local evidence layer repair
  case "$status" in
    HEALTHY)
      evidence="body: ${redacted_excerpt}"
      layer="none"
      repair="none"
      ;;
    WARNING)
      evidence="body indicates Degraded: ${redacted_excerpt}"
      layer="application"
      repair="none"
      ;;
    CRITICAL)
      evidence="body indicates Unhealthy: ${redacted_excerpt}"
      layer="application"
      repair="$_HLT_RESTART_REPAIR"
      ;;
    *)
      status="UNKNOWN"
      evidence="unrecognised health response body: ${redacted_excerpt}"
      layer="none"
      repair="none"
      ;;
  esac

  result_add "HLT-02" "$name" "$status" "$evidence" "$layer" "$repair"

  printf '%s\n' "$status"
  printf '%s\n' "$entries_json"
}

# ---------------------------------------------------------------------------
# HLT-03: dependency extraction (JSON only). Absent entries is
# NOT_APPLICABLE, never an error — this covers every current service
# (plain text only) as well as future JSON-emitting ones.
# Prints the comma-separated list of failed dependency names (may be empty).
# ---------------------------------------------------------------------------
hlt_check_03_dependencies() {
  local name="$1" entries_json="$2"

  if [[ -z "$entries_json" ]]; then
    result_add "HLT-03" "$name" "NOT_APPLICABLE" "no dependency entries in health response" "none" "none"
    printf ''
    return 0
  fi

  local failed_deps
  failed_deps="$(python3 -c "$_HLT_DEPS_PY" "$entries_json")"

  if [[ -z "$failed_deps" ]]; then
    result_add "HLT-03" "$name" "HEALTHY" "all dependencies healthy" "none" "none"
    printf ''
    return 0
  fi

  result_add "HLT-03" "$name" "CRITICAL" "Failed dependency: ${failed_deps}" "application" "none"
  printf '%s' "$failed_deps"
}

# ---------------------------------------------------------------------------
# HLT-04: overall health verdict per service
# ---------------------------------------------------------------------------
hlt_check_04_verdict() {
  local name="$1" hlt01="$2" hlt02="$3" failed_deps="$4"

  local status layer evidence repair
  if [[ "$hlt01" == "CRITICAL" ]]; then
    status="CRITICAL"
    layer="network"
    evidence="no response from health endpoint"
    repair="$_HLT_RESTART_REPAIR"
  elif [[ "$hlt02" == "CRITICAL" ]]; then
    status="CRITICAL"
    layer="application"
    evidence="health endpoint reachable but body reports Unhealthy"
    repair="$_HLT_RESTART_REPAIR"
  elif [[ "$hlt02" == "WARNING" ]]; then
    status="WARNING"
    layer="application"
    evidence="health endpoint reachable but body reports Degraded"
    repair="none"
  elif [[ "$hlt01" == "WARNING" ]]; then
    status="WARNING"
    layer="performance"
    evidence="health endpoint slow to respond"
    repair="none"
  else
    status="HEALTHY"
    layer="none"
    evidence="health endpoint healthy"
    repair="none"
  fi

  if [[ -n "$failed_deps" ]]; then
    evidence="${evidence} — Failed dependency: ${failed_deps}"
  fi

  result_add "HLT-04" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# run_hlt_checks <env> — loops every service in inventory.<env>.yaml,
# returns the worst verdict across all services.
# ---------------------------------------------------------------------------
run_hlt_checks() {
  local env="$1"
  local inventory_file="${HLT_CONFIG_DIR}/inventory.${env}.yaml"

  if [[ ! -f "$inventory_file" ]]; then
    _result_log ERROR "Inventory file not found: ${inventory_file}"
    return 1
  fi

  _hlt_detect_yaml_tool || return 1

  local count
  count="$(_hlt_count "$inventory_file")"

  local worst="HEALTHY"
  local i
  for (( i = 0; i < count; i++ )); do
    local name port timeout_s
    name="$(_hlt_field "$inventory_file" "$i" name)"
    port="$(_hlt_field "$inventory_file" "$i" port)"
    timeout_s="$(_hlt_field "$inventory_file" "$i" timeout_seconds)"

    local hlt01_out hlt01 body_b64 body
    hlt01_out="$(hlt_check_01_endpoint "$port" "$name" "$timeout_s")"
    hlt01="$(printf '%s\n' "$hlt01_out" | sed -n '1p')"
    body_b64="$(printf '%s\n' "$hlt01_out" | sed -n '2p')"
    body=""
    if [[ -n "$body_b64" ]]; then
      body="$(printf '%s' "$body_b64" | base64 -d 2>/dev/null || true)"
    fi

    local hlt02_out hlt02 entries_json
    hlt02_out="$(hlt_check_02_body_parse "$name" "$body")"
    hlt02="$(printf '%s\n' "$hlt02_out" | sed -n '1p')"
    entries_json="$(printf '%s\n' "$hlt02_out" | sed -n '2p')"

    local failed_deps
    failed_deps="$(hlt_check_03_dependencies "$name" "$entries_json")"

    local hlt04
    hlt04="$(hlt_check_04_verdict "$name" "$hlt01" "$hlt02" "$failed_deps")"

    worst="$(_hlt_worse_status "$worst" "$hlt04")"
  done

  printf '%s' "$worst"
}
