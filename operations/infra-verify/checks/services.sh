#!/usr/bin/env bash
#
# services.sh — SVC family checks (service availability + journal capture).
# This is a LIBRARY: source it, do not execute it directly.
#
# SVC-01 systemd state       SVC-02 port listening      SVC-03 internal HTTP
# SVC-04 public HTTPS (deferred to Phase 5)              SVC-05 verdict synthesis
# SVC-06 is not a standalone check — it is the journal capture performed
# automatically by SVC-01 (via result_add_with_journal) when systemd state
# is CRITICAL. journalctl requires the invoking user to be a member of the
# systemd-journal group; that is provisioned by the Ansible infra_verify
# role in Phase 7 and is not implemented or enforced here.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "services.sh is a library — source it, do not execute it directly." >&2
  exit 1
fi

_SVC_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly _SVC_SCRIPT_DIR
SVC_CONFIG_DIR="$(realpath -m "${_SVC_SCRIPT_DIR}/../config")"
readonly SVC_CONFIG_DIR

# shellcheck source=SCRIPTDIR/../lib/result.sh
source "${_SVC_SCRIPT_DIR}/../lib/result.sh"

readonly _SVC_RESTART_WARN_THRESHOLD=3
readonly _SVC_SLOW_THRESHOLD_SECONDS=2
readonly _SVC_RESTART_REPAIR="operations/repairs/service/restart-one-specific-service.sh"

SVC_YAML_TOOL=""

# ---------------------------------------------------------------------------
# Inventory reading — dual yq / python3+PyYAML path, same convention as
# config/generate-inventory.sh. The generated inventory.<env>.yaml already
# has all defaults resolved, so no has_metrics-style special-casing is
# needed here.
# ---------------------------------------------------------------------------
_svc_detect_yaml_tool() {
  if [[ -n "$SVC_YAML_TOOL" ]]; then
    return 0
  fi
  if command -v yq >/dev/null 2>&1; then
    SVC_YAML_TOOL="yq"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    SVC_YAML_TOOL="python3"
    return 0
  fi
  _result_log ERROR "Neither 'yq' nor 'python3 (with PyYAML)' is available for inventory read"
  return 1
}

_svc_count() {
  local file="$1"
  if [[ "$SVC_YAML_TOOL" == "yq" ]]; then
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

_svc_field() {
  local file="$1" index="$2" field="$3"
  if [[ "$SVC_YAML_TOOL" == "yq" ]]; then
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
_svc_status_rank() {
  case "$1" in
    CRITICAL) echo 4 ;;
    WARNING) echo 3 ;;
    UNKNOWN) echo 2 ;;
    NOT_CONFIGURED|NOT_APPLICABLE) echo 1 ;;
    *) echo 0 ;;
  esac
}

_svc_worse_status() {
  local a="$1" b="$2"
  local ra rb
  ra="$(_svc_status_rank "$a")"
  rb="$(_svc_status_rank "$b")"
  if [[ "$rb" -gt "$ra" ]]; then
    printf '%s' "$b"
  else
    printf '%s' "$a"
  fi
}

# ---------------------------------------------------------------------------
# SVC-01: systemd state
#
# NOTE (scope decision for T1.3): the spec's "NRestarts same as last run"
# comparison requires cross-run state persistence that does not exist yet
# (history/ has no baseline writer/reader in this phase). This
# implementation uses a simpler, self-contained absolute threshold:
# NRestarts >= _SVC_RESTART_WARN_THRESHOLD -> WARNING. True since-last-run
# comparison is deferred until state persistence is built.
# ---------------------------------------------------------------------------
svc_check_01_systemd_state() {
  local unit="$1" name="$2"

  local state
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"

  local show_output
  show_output="$(systemctl show "$unit" -p NRestarts,ActiveEnterTimestamp 2>/dev/null || true)"

  local nrestarts
  nrestarts="$(printf '%s\n' "$show_output" | sed -n 's/^NRestarts=//p')"
  [[ -z "$nrestarts" ]] && nrestarts=0

  local status evidence layer repair
  if [[ "$state" == "active" ]]; then
    if [[ "$nrestarts" -ge "$_SVC_RESTART_WARN_THRESHOLD" ]]; then
      status="WARNING"
      evidence="systemd state: active, NRestarts=${nrestarts} (>= ${_SVC_RESTART_WARN_THRESHOLD})"
      layer="process"
      repair="none"
    else
      status="HEALTHY"
      evidence="systemd state: active, NRestarts=${nrestarts}"
      layer="none"
      repair="none"
    fi
  else
    status="CRITICAL"
    evidence="systemd state: ${state:-unknown}"
    layer="process"
    repair="$_SVC_RESTART_REPAIR"
  fi

  if [[ "$status" == "CRITICAL" ]]; then
    result_add_with_journal "SVC-01" "$name" "$status" "$evidence" "$layer" "$repair" "$unit"
  else
    result_add "SVC-01" "$name" "$status" "$evidence" "$layer" "$repair"
  fi

  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# SVC-02: port listening — skipped entirely (no result emitted) when SVC-01
# is already CRITICAL, to avoid duplicate alerts for the same root cause.
# ---------------------------------------------------------------------------
svc_check_02_port() {
  local port="$1" name="$2" svc01_status="$3"

  if [[ "$svc01_status" == "CRITICAL" ]]; then
    printf 'SKIPPED'
    return 0
  fi

  local listening="false"
  if ss -ltn 2>/dev/null | grep -q ":${port} "; then
    listening="true"
  fi

  local status evidence layer repair
  if [[ "$listening" == "true" ]]; then
    status="HEALTHY"
    evidence="port ${port}: listening"
    layer="none"
    repair="none"
  else
    status="CRITICAL"
    evidence="port ${port}: not listening"
    layer="process"
    repair="$_SVC_RESTART_REPAIR"
  fi

  result_add "SVC-02" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# SVC-03: internal HTTP
# ---------------------------------------------------------------------------
svc_check_03_internal_http() {
  local port="$1" name="$2" timeout_s="$3"

  local curl_out
  curl_out="$(curl --silent --max-time "$timeout_s" \
    --write-out '%{http_code} %{time_total}' --output /dev/null \
    "http://127.0.0.1:${port}/health" 2>/dev/null || true)"

  local http_code time_total
  http_code="$(printf '%s' "$curl_out" | awk '{print $1}')"
  time_total="$(printf '%s' "$curl_out" | awk '{print $2}')"

  local status evidence layer repair
  if [[ -z "$http_code" || "$http_code" == "000" ]]; then
    status="CRITICAL"
    evidence="internal http://127.0.0.1:${port}/health: connection failed or timed out"
    layer="application"
    repair="$_SVC_RESTART_REPAIR"
  elif [[ "$http_code" =~ ^5 ]]; then
    status="CRITICAL"
    evidence="internal http://127.0.0.1:${port}/health: HTTP ${http_code} in ${time_total}s"
    layer="application"
    repair="$_SVC_RESTART_REPAIR"
  elif [[ "$http_code" =~ ^2 ]]; then
    local slow
    slow="$(awk -v t="$time_total" -v lim="$_SVC_SLOW_THRESHOLD_SECONDS" 'BEGIN { print (t > lim) ? "1" : "0" }')"
    if [[ "$slow" == "1" ]]; then
      status="WARNING"
      evidence="internal http://127.0.0.1:${port}/health: HTTP ${http_code} in ${time_total}s (> ${_SVC_SLOW_THRESHOLD_SECONDS}s)"
      layer="application"
      repair="none"
    else
      status="HEALTHY"
      evidence="internal http://127.0.0.1:${port}/health: HTTP ${http_code} in ${time_total}s"
      layer="none"
      repair="none"
    fi
  else
    status="WARNING"
    evidence="internal http://127.0.0.1:${port}/health: HTTP ${http_code} in ${time_total}s (unexpected status)"
    layer="application"
    repair="none"
  fi

  result_add "SVC-03" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# SVC-04: public HTTPS — deferred to Phase 5 (domain state unconfirmed
# per discovery.md §9; the check engine cannot reach public domains yet).
# ---------------------------------------------------------------------------
svc_check_04_public_https() {
  local name="$1"
  result_add "SVC-04" "$name" "NOT_CONFIGURED" "public HTTPS check deferred to Phase 5" "none" "none"
  printf 'NOT_CONFIGURED'
}

# ---------------------------------------------------------------------------
# SVC-05: verdict synthesis
# ---------------------------------------------------------------------------
svc_check_05_verdict() {
  local name="$1" svc01="$2" svc02="$3" svc03="$4"

  local status evidence layer repair
  if [[ "$svc01" == "CRITICAL" ]]; then
    status="CRITICAL"
    layer="process"
    evidence="process down (systemd state critical)"
    repair="$_SVC_RESTART_REPAIR"
  elif [[ "$svc02" == "CRITICAL" ]]; then
    status="CRITICAL"
    layer="process"
    evidence="process up but port not listening"
    repair="$_SVC_RESTART_REPAIR"
  elif [[ "$svc03" == "CRITICAL" ]]; then
    status="CRITICAL"
    layer="application"
    evidence="process up but internal health check unhealthy"
    repair="$_SVC_RESTART_REPAIR"
  elif [[ "$svc03" == "WARNING" ]]; then
    status="WARNING"
    layer="application"
    evidence="process up but internal health check slow"
    repair="none"
  elif [[ "$svc01" == "WARNING" ]]; then
    status="WARNING"
    layer="process"
    evidence="process up but restart count elevated"
    repair="none"
  else
    status="HEALTHY"
    layer="none"
    evidence="all service-layer checks passing"
    repair="none"
  fi

  result_add "SVC-05" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# run_svc_checks <env> — loops every service in inventory.<env>.yaml,
# returns the worst verdict across all services.
# ---------------------------------------------------------------------------
run_svc_checks() {
  local env="$1"
  local inventory_file="${SVC_CONFIG_DIR}/inventory.${env}.yaml"

  if [[ ! -f "$inventory_file" ]]; then
    _result_log ERROR "Inventory file not found: ${inventory_file}"
    return 1
  fi

  _svc_detect_yaml_tool || return 1

  local count
  count="$(_svc_count "$inventory_file")"

  local worst="HEALTHY"
  local i
  for (( i = 0; i < count; i++ )); do
    local name port unit timeout_s
    name="$(_svc_field "$inventory_file" "$i" name)"
    port="$(_svc_field "$inventory_file" "$i" port)"
    unit="$(_svc_field "$inventory_file" "$i" systemd_unit)"
    timeout_s="$(_svc_field "$inventory_file" "$i" timeout_seconds)"

    local s01 s02 s03 s05
    s01="$(svc_check_01_systemd_state "$unit" "$name")"
    s02="$(svc_check_02_port "$port" "$name" "$s01")"
    s03="$(svc_check_03_internal_http "$port" "$name" "$timeout_s")"
    svc_check_04_public_https "$name" >/dev/null
    s05="$(svc_check_05_verdict "$name" "$s01" "$s02" "$s03")"

    worst="$(_svc_worse_status "$worst" "$s05")"
  done

  printf '%s' "$worst"
}
