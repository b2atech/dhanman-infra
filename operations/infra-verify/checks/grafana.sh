#!/usr/bin/env bash
#
# grafana.sh — GF family checks (Grafana health & datasource verification).
# This is a LIBRARY: source it, do not execute it directly.
#
# GF-01 endpoint reachability   GF-02 database state (from GF-01's body)
# GF-03 datasource existence (token-gated)
# GF-04 Prometheus query-through (token-gated)
# GF-05 Loki query-through (token-gated)
# GF-06 overall verdict         GF-07 end-to-end visibility matrix (synthesizer)
#
# Confirmed facts from discovery.md, used directly:
#   Grafana URL (both envs): http://127.0.0.1:3000
#   Datasources (provisioned, editable: false): prometheus (uid: prometheus),
#   loki (uid: loki)
#   No authentication required for /api/health
#
# TOKEN GAP (Phase 0 finding, never resolved in this session): a Grafana
# Viewer service-account token was flagged as needed but was never created
# in Vault — creating one requires Vault access this session never had.
# GF-03/04/05 therefore read GRAFANA_VERIFY_TOKEN_<ENV> from the
# environment; when absent they report NOT_CONFIGURED (not a failure —
# expected and documented) rather than guessing or failing loudly. The
# token is used only in a per-request Authorization header — it is never
# interpolated into an evidence string, logged, or stored in any result
# object.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "grafana.sh is a library — source it, do not execute it directly." >&2
  exit 1
fi

_GF_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly _GF_SCRIPT_DIR

# shellcheck source=SCRIPTDIR/../lib/result.sh
source "${_GF_SCRIPT_DIR}/../lib/result.sh"

readonly _GF_BASE_URL="http://127.0.0.1:3000"
readonly _GF_CURL_TIMEOUT=10

# ---------------------------------------------------------------------------
# Status severity ranking, used to compute the worst status across checks
# ---------------------------------------------------------------------------
_gf_status_rank() {
  case "$1" in
    CRITICAL) echo 4 ;;
    WARNING) echo 3 ;;
    UNKNOWN) echo 2 ;;
    NOT_CONFIGURED|NOT_APPLICABLE) echo 1 ;;
    *) echo 0 ;;
  esac
}

_gf_worse_status() {
  local a="$1" b="$2"
  local ra rb
  ra="$(_gf_status_rank "$a")"
  rb="$(_gf_status_rank "$b")"
  if [[ "$rb" -gt "$ra" ]]; then
    printf '%s' "$b"
  else
    printf '%s' "$a"
  fi
}

# ---------------------------------------------------------------------------
# _gf_get_token <env> — reads GRAFANA_VERIFY_TOKEN_<ENV> (uppercased) from
# the environment via indirect expansion. Never echoed, never logged.
# ---------------------------------------------------------------------------
_gf_get_token() {
  local env="$1"
  local var_name
  var_name="GRAFANA_VERIFY_TOKEN_$(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')"
  printf '%s' "${!var_name:-}"
}

_gf_token_missing_message() {
  local env="$1"
  local env_upper env_lower
  env_upper="$(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')"
  env_lower="$(printf '%s' "$env" | tr '[:upper:]' '[:lower:]')"
  printf 'Grafana Viewer service-account token not configured. Set GRAFANA_VERIFY_TOKEN_%s environment variable or create secret/shared/global#grafana_verify_token_%s in Vault.' "$env_upper" "$env_lower"
}

# ---------------------------------------------------------------------------
# Embedded python3 helpers
# ---------------------------------------------------------------------------

# _GF_DB_STATE_PY: argv[1] = raw /api/health body. Prints the
# database.state value, or empty string if absent/unparsable.
read -r -d '' _GF_DB_STATE_PY <<'PYEOF' || true
import json
import sys

try:
    obj = json.loads(sys.argv[1])
except Exception:
    print("")
    sys.exit(0)

print(obj.get("database", {}).get("state", "") or "")
PYEOF

# _GF_DATASOURCE_CHECK_PY: argv[1] = raw /api/datasources body. Prints
# OK, MISSING:<uids>, or EDITABLE:<uids>.
read -r -d '' _GF_DATASOURCE_CHECK_PY <<'PYEOF' || true
import json
import sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    print("ERROR")
    sys.exit(0)

if not isinstance(data, list):
    print("ERROR")
    sys.exit(0)

by_uid = {}
for ds in data:
    uid = ds.get("uid")
    if uid:
        by_uid[uid] = ds

expected = ("prometheus", "loki")
missing = [u for u in expected if u not in by_uid]
if missing:
    print("MISSING:" + ",".join(missing))
    sys.exit(0)

editable_bad = [u for u in expected if by_uid[u].get("editable", False) is True]
if editable_bad:
    print("EDITABLE:" + ",".join(editable_bad))
    sys.exit(0)

print("OK")
PYEOF

# _GF_QUERY_RESULT_PY: argv[1] = raw /api/ds/query response body. Prints
# OK if results.A exists with no "error" key (empty result sets still
# count as OK — "HEALTHY even if empty" per spec), ERROR otherwise.
read -r -d '' _GF_QUERY_RESULT_PY <<'PYEOF' || true
import json
import sys

try:
    obj = json.loads(sys.argv[1])
except Exception:
    print("ERROR")
    sys.exit(0)

a = obj.get("results", {}).get("A")
if a is None or "error" in a:
    print("ERROR")
    sys.exit(0)

print("OK")
PYEOF

# ---------------------------------------------------------------------------
# GF-01: Grafana endpoint reachability. Prints two lines: status, then
# base64-encoded response body (for GF-02 to inspect without a second
# network call) — same body-transport pattern as checks/health.sh HLT-01.
# ---------------------------------------------------------------------------
gf_check_01_reachability() {
  local env="$1"

  local curl_out http_code body
  curl_out="$(curl --silent --max-time "$_GF_CURL_TIMEOUT" --write-out $'\n%{http_code}' "${_GF_BASE_URL}/api/health" 2>/dev/null || true)"
  http_code="$(printf '%s\n' "$curl_out" | tail -n 1)"
  body="$(printf '%s\n' "$curl_out" | sed '$d')"

  local status evidence layer repair
  if [[ "$http_code" == "200" && ( "$body" == *"ok"* || "$body" == *"database"* ) ]]; then
    status="HEALTHY"
    evidence="grafana /api/health responded 200"
    layer="none"
    repair="none"
  elif [[ -z "$http_code" || "$http_code" == "000" ]]; then
    status="CRITICAL"
    evidence="grafana /api/health connection failed or timed out"
    layer="grafana-process"
    repair="none"
  else
    status="CRITICAL"
    evidence="grafana /api/health returned http_code=${http_code}"
    layer="grafana-process"
    repair="none"
  fi

  result_add "GF-01" "${env}/grafana" "$status" "$evidence" "$layer" "$repair"

  printf '%s\n' "$status"
  printf '%s\n' "$(printf '%s' "$body" | base64 -w0)"
}

# ---------------------------------------------------------------------------
# GF-02: database state, parsed from GF-01's already-fetched body (no
# second network call).
#
# Note: GF-02 produces only HEALTHY or CRITICAL (never WARNING).
# The brief's GF-06 section lists "GF-02 WARNING" but GF-02's own
# specification defines only HEALTHY (database ok) or CRITICAL
# (database error or missing key). GF-06's verdict treats GF-02
# CRITICAL as part of the grafana-process layer alongside GF-01.
# ---------------------------------------------------------------------------
gf_check_02_database_state() {
  local env="$1" gf01_status="$2" body="$3"

  if [[ "$gf01_status" == "CRITICAL" ]]; then
    result_add "GF-02" "${env}/grafana" "NOT_APPLICABLE" "Grafana not reachable (GF-01 critical)" "none" "none"
    printf '%s' "NOT_APPLICABLE"
    return 0
  fi

  local db_state
  db_state="$(python3 -c "$_GF_DB_STATE_PY" "$body" 2>/dev/null || echo '')"

  local status evidence layer repair
  if [[ -z "$db_state" ]]; then
    status="CRITICAL"
    evidence="grafana health response missing database.state or not valid JSON"
    layer="grafana-database"
    repair="none"
  elif [[ "$db_state" == "ok" ]]; then
    status="HEALTHY"
    evidence="grafana database state=ok"
    layer="none"
    repair="none"
  else
    status="CRITICAL"
    evidence="grafana database state=${db_state}"
    layer="grafana-database"
    repair="none"
  fi

  result_add "GF-02" "${env}/grafana" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# GF-03: datasource existence (token-gated). No token -> NOT_CONFIGURED,
# never CRITICAL. Invalid token (401) -> UNKNOWN (an auth problem, not
# proof the datasource is actually missing).
# ---------------------------------------------------------------------------
gf_check_03_datasource_existence() {
  local env="$1" token="$2"

  if [[ -z "$token" ]]; then
    result_add "GF-03" "${env}/grafana" "NOT_CONFIGURED" "$(_gf_token_missing_message "$env")" "none" "none"
    printf '%s' "NOT_CONFIGURED"
    return 0
  fi

  local curl_out http_code body
  curl_out="$(curl --silent --max-time "$_GF_CURL_TIMEOUT" --write-out $'\n%{http_code}' \
    -H "Authorization: Bearer ${token}" "${_GF_BASE_URL}/api/datasources" 2>/dev/null || true)"
  http_code="$(printf '%s\n' "$curl_out" | tail -n 1)"
  body="$(printf '%s\n' "$curl_out" | sed '$d')"

  local status evidence layer repair
  if [[ "$http_code" == "401" ]]; then
    status="UNKNOWN"
    evidence="grafana /api/datasources returned 401 — token invalid or expired"
    layer="none"
    repair="none"
  elif [[ "$http_code" != "200" ]]; then
    status="CRITICAL"
    evidence="grafana /api/datasources returned http_code=${http_code:-none}"
    layer="grafana-configuration"
    repair="none"
  else
    local parsed
    parsed="$(python3 -c "$_GF_DATASOURCE_CHECK_PY" "$body" 2>/dev/null || echo 'ERROR')"
    case "$parsed" in
      ERROR)
        status="CRITICAL"
        evidence="could not parse /api/datasources response"
        layer="grafana-configuration"
        repair="none"
        ;;
      MISSING:*)
        status="CRITICAL"
        evidence="expected datasource(s) missing: ${parsed#MISSING:}"
        layer="grafana-configuration"
        repair="none"
        ;;
      EDITABLE:*)
        status="WARNING"
        evidence="datasource(s) present but editable=true (expected false): ${parsed#EDITABLE:}"
        layer="grafana-configuration"
        repair="none"
        ;;
      OK)
        status="HEALTHY"
        evidence="prometheus and loki datasources present, editable=false"
        layer="none"
        repair="none"
        ;;
      *)
        status="UNKNOWN"
        evidence="unexpected datasource check result"
        layer="none"
        repair="none"
        ;;
    esac
  fi

  result_add "GF-03" "${env}/grafana" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# Shared query-through implementation for GF-04/GF-05. Uses POST
# /api/ds/query — Grafana's own datasource query-proxy API, which is a
# read-only query operation despite the HTTP verb (the query body doesn't
# fit in a GET query string); this is unrelated to, and does not weaken,
# the "never POST /-/reload"-style constraints on the Loki/Prometheus
# modules, which govern their write/lifecycle endpoints specifically.
# Only response time is stored in evidence — never the query result body.
# ---------------------------------------------------------------------------
_gf_query_through() {
  local check_id="$1" env="$2" token="$3" datasource_uid="$4" expr="$5"

  if [[ -z "$token" ]]; then
    result_add "$check_id" "${env}/grafana" "NOT_CONFIGURED" "$(_gf_token_missing_message "$env")" "none" "none"
    printf '%s' "NOT_CONFIGURED"
    return 0
  fi

  local query_body
  query_body="$(python3 -c '
import json, sys
print(json.dumps({"queries": [{"refId": "A", "datasourceUid": sys.argv[1], "expr": sys.argv[2]}]}))
' "$datasource_uid" "$expr")"

  local curl_out
  curl_out="$(curl --silent --max-time "$_GF_CURL_TIMEOUT" --write-out $'\x1e%{http_code}\x1e%{time_total}' \
    -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    -X POST --data "$query_body" "${_GF_BASE_URL}/api/ds/query" 2>/dev/null || true)"

  local body rest http_code time_total
  body="${curl_out%%$'\x1e'*}"
  rest="${curl_out#*$'\x1e'}"
  http_code="${rest%%$'\x1e'*}"
  time_total="${rest#*$'\x1e'}"

  local status evidence layer repair
  if [[ "$http_code" == "401" ]]; then
    status="UNKNOWN"
    evidence="grafana /api/ds/query (${datasource_uid}) returned 401 — token invalid or expired"
    layer="none"
    repair="none"
  elif [[ -z "$http_code" || "$http_code" == "000" ]]; then
    status="CRITICAL"
    evidence="grafana /api/ds/query (${datasource_uid}) connection failed or timed out"
    layer="grafana-datasource"
    repair="none"
  elif [[ ! "$http_code" =~ ^2 ]]; then
    status="CRITICAL"
    evidence="grafana /api/ds/query (${datasource_uid}) returned http_code=${http_code} in ${time_total}s"
    layer="grafana-datasource"
    repair="none"
  else
    local parsed
    parsed="$(python3 -c "$_GF_QUERY_RESULT_PY" "$body" 2>/dev/null || echo 'ERROR')"
    if [[ "$parsed" == "OK" ]]; then
      status="HEALTHY"
      evidence="grafana query-through (${datasource_uid}) succeeded in ${time_total}s"
      layer="none"
      repair="none"
    else
      status="CRITICAL"
      evidence="grafana query-through (${datasource_uid}) returned an error result in ${time_total}s"
      layer="grafana-datasource"
      repair="none"
    fi
  fi

  result_add "$check_id" "${env}/grafana" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# GF-04: Prometheus query-through (token-gated).
# ---------------------------------------------------------------------------
gf_check_04_prometheus_query_through() {
  local env="$1" token="$2"
  _gf_query_through "GF-04" "$env" "$token" "prometheus" "vector(1)"
}

# ---------------------------------------------------------------------------
# GF-05: Loki query-through (token-gated). "limit=1" is the exact query
# shape given in the brief for Loki's simpler query syntax.
# ---------------------------------------------------------------------------
gf_check_05_loki_query_through() {
  local env="$1" token="$2"
  _gf_query_through "GF-05" "$env" "$token" "loki" "limit=1"
}

# ---------------------------------------------------------------------------
# GF-06: overall Grafana verdict
# ---------------------------------------------------------------------------
gf_check_06_verdict() {
  local env="$1" gf01="$2" gf02="$3" gf03="$4" gf04="$5" gf05="$6"

  local status layer evidence repair="none"

  if [[ "$gf01" == "CRITICAL" || "$gf02" == "CRITICAL" ]]; then
    status="CRITICAL"
    layer="grafana-process"
    evidence="Grafana process or database unhealthy (GF-01/GF-02)"
  elif [[ "$gf03" == "CRITICAL" ]]; then
    status="CRITICAL"
    layer="grafana-configuration"
    evidence="expected datasource missing or misconfigured (GF-03)"
  elif [[ "$gf04" == "CRITICAL" || "$gf05" == "CRITICAL" ]]; then
    status="CRITICAL"
    layer="grafana-datasource"
    evidence="Grafana query-through failed (GF-04/GF-05) — network, auth, or datasource config issue"
  else
    local worst="HEALTHY"
    local s
    for s in "$gf01" "$gf02" "$gf03" "$gf04" "$gf05"; do
      worst="$(_gf_worse_status "$worst" "$s")"
    done
    status="$worst"
    layer="none"
    if [[ "$status" == "HEALTHY" ]]; then
      evidence="all Grafana checks passing"
    else
      evidence="one or more Grafana checks reported ${status} (non-critical)"
    fi
  fi

  result_add "GF-06" "${env}/grafana" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# GF-07: end-to-end visibility matrix. Not a standalone probe — a pure
# synthesizer over already-computed statuses from this and prior phases.
# Logs chain: local file -> Promtail -> Loki -> Grafana.
# Metrics chain: exporter -> Prometheus -> Grafana.
# Each chain reports VISIBLE (all stages HEALTHY) or BROKEN at the first
# non-HEALTHY stage. target may be a service name (per-service) or an
# env-level aggregate label, per the caller's choice.
# ---------------------------------------------------------------------------
gf_check_07_e2e_matrix() {
  local target="$1"
  local log_status="$2" pt_status="$3" lk_status="$4" gf_logs_status="$5"
  local exporter_status="$6" prom_status="$7" gf_metrics_status="$8"

  local logs_chain logs_evidence
  if [[ "$log_status" != "HEALTHY" ]]; then
    logs_chain="BROKEN"
    logs_evidence="Logs BROKEN at local-file (log file not fresh)"
  elif [[ "$pt_status" != "HEALTHY" ]]; then
    logs_chain="BROKEN"
    logs_evidence="Logs BROKEN at Promtail (not running/ready)"
  elif [[ "$lk_status" != "HEALTHY" ]]; then
    logs_chain="BROKEN"
    logs_evidence="Logs BROKEN at promtail-to-loki (Loki has no data)"
  elif [[ "$gf_logs_status" != "HEALTHY" ]]; then
    logs_chain="BROKEN"
    logs_evidence="Logs BROKEN at Grafana (query-through failed)"
  else
    logs_chain="VISIBLE"
    logs_evidence="Logs VISIBLE from service to Grafana"
  fi

  local metrics_chain metrics_evidence
  if [[ "$exporter_status" != "HEALTHY" ]]; then
    metrics_chain="BROKEN"
    metrics_evidence="Metrics BROKEN at exporter (not up)"
  elif [[ "$prom_status" != "HEALTHY" ]]; then
    metrics_chain="BROKEN"
    metrics_evidence="Metrics BROKEN at prometheus (not scraping)"
  elif [[ "$gf_metrics_status" != "HEALTHY" ]]; then
    metrics_chain="BROKEN"
    metrics_evidence="Metrics BROKEN at Grafana (query-through failed)"
  else
    metrics_chain="VISIBLE"
    metrics_evidence="Metrics VISIBLE from exporter to Grafana"
  fi

  local overall_status="HEALTHY"
  if [[ "$logs_chain" == "BROKEN" || "$metrics_chain" == "BROKEN" ]]; then
    overall_status="WARNING"
  fi

  result_add "GF-07" "$target" "$overall_status" "${logs_evidence}; ${metrics_evidence}" "none" "none"

  printf '%s\n' "$logs_chain"
  printf '%s\n' "$metrics_chain"
}

# ---------------------------------------------------------------------------
# run_grafana_checks <env> [token]
#
# token defaults to GRAFANA_VERIFY_TOKEN_<ENV> from the environment when
# not supplied. Runs GF-01 first and gates GF-02 on it; GF-03/04/05 each
# independently report NOT_CONFIGURED when no token is available. Returns
# three lines: worst-of status, GF-06's likely_layer, token_status
# ("configured" | "not_configured").
# ---------------------------------------------------------------------------
run_grafana_checks() {
  local env="$1"
  local token="${2:-}"
  [[ -z "$token" ]] && token="$(_gf_get_token "$env")"

  local gf01_out gf01 body_b64 body
  gf01_out="$(gf_check_01_reachability "$env")"
  gf01="$(printf '%s\n' "$gf01_out" | sed -n '1p')"
  body_b64="$(printf '%s\n' "$gf01_out" | sed -n '2p')"
  body=""
  [[ -n "$body_b64" ]] && body="$(printf '%s' "$body_b64" | base64 -d 2>/dev/null || true)"

  local gf02
  gf02="$(gf_check_02_database_state "$env" "$gf01" "$body")"

  local gf03
  gf03="$(gf_check_03_datasource_existence "$env" "$token")"

  local gf04
  gf04="$(gf_check_04_prometheus_query_through "$env" "$token")"

  local gf05
  gf05="$(gf_check_05_loki_query_through "$env" "$token")"

  local gf06
  gf06="$(gf_check_06_verdict "$env" "$gf01" "$gf02" "$gf03" "$gf04" "$gf05")"

  local layer
  layer="$(python3 -c "
import json, sys
try:
    print(json.loads(sys.argv[1]).get('likely_layer', 'none'))
except Exception:
    print('none')
" "$(tail -n 1 "$RESULT_FILE" 2>/dev/null || echo '{}')" 2>/dev/null || echo 'none')"

  local token_status="not_configured"
  [[ -n "$token" ]] && token_status="configured"

  printf '%s\n' "$gf06"
  printf '%s\n' "$layer"
  printf '%s\n' "$token_status"
}
