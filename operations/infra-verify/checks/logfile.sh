#!/usr/bin/env bash
#
# logfile.sh — LOG family checks (local log file verification).
# This is a LIBRARY: source it, do not execute it directly.
#
# LOG-01 dir exists/traversable   LOG-02 today's file exists
# LOG-03 readable/non-empty       LOG-04 freshness
# LOG-05 ownership                LOG-06 wrong-location
# LOG-07 disk/inode space (per env)  LOG-08 rotation sanity
#
# Confirmed facts from discovery.md (used directly, not assumed):
#   Log dir: /var/www/<env>/logs
#   Log pattern: dhanman-<service>-YYYYMMDD.log
#   Dir permissions: mode 0775, owner www-data:www-data
#   /health and /metrics requests do NOT appear in logs (Serilog filter) —
#   irrelevant to this module directly, but confirms no synthetic-ping
#   shortcut exists for freshness checking; only real traffic moves mtime.
#
# Permission-check design note: LOG-01 and LOG-03 determine
# traversability/readability from stat-reported mode bits (owner|group|other
# read or execute bits present) rather than bash's -r/-x builtins. Under
# root, -r/-x always report true regardless of a file's actual mode bits
# (root bypasses the kernel's permission enforcement), which would make
# "permission broken" scenarios untestable and — more importantly — would
# make the check itself silently useless if this engine ever runs with
# elevated privileges. Reading mode bits via stat sidesteps that: it
# reports the truth regardless of who is asking, and is the same
# mechanism already required for LOG-05's ownership check.
#
# No temp files are created anywhere in this module (every check is a
# read-only stat/find/df/date query against existing paths), so no EXIT
# trap is needed here — unlike checks/health.sh, which does create one.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "logfile.sh is a library — source it, do not execute it directly." >&2
  exit 1
fi

_LOG_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly _LOG_SCRIPT_DIR
LOG_CONFIG_DIR="$(realpath -m "${_LOG_SCRIPT_DIR}/../config")"
readonly LOG_CONFIG_DIR

# shellcheck source=SCRIPTDIR/../lib/result.sh
source "${_LOG_SCRIPT_DIR}/../lib/result.sh"

readonly _LOG_EXPECTED_OWNER="www-data"
readonly _LOG_EXPECTED_GROUP="www-data"
readonly _LOG_ROTATION_MAX_FILES=35
readonly _LOG_DISK_WARN_PCT=80
readonly _LOG_DISK_CRIT_PCT=90
readonly _LOG_WRONG_LOCATION_EXCERPT_MAX=5
readonly _LOG_PERMISSIONS_REPAIR="operations/repairs/permissions/fix-specific-service-log-permissions.sh"

LOG_YAML_TOOL=""

# ---------------------------------------------------------------------------
# Inventory reading — same dual yq / python3+PyYAML convention as
# checks/services.sh and checks/health.sh; independent of both (only
# depends on lib/result.sh).
# ---------------------------------------------------------------------------
_log_detect_yaml_tool() {
  if [[ -n "$LOG_YAML_TOOL" ]]; then
    return 0
  fi
  if command -v yq >/dev/null 2>&1; then
    LOG_YAML_TOOL="yq"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    LOG_YAML_TOOL="python3"
    return 0
  fi
  _result_log ERROR "Neither 'yq' nor 'python3 (with PyYAML)' is available for inventory read"
  return 1
}

_log_count() {
  local file="$1"
  if [[ "$LOG_YAML_TOOL" == "yq" ]]; then
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

_log_field() {
  local file="$1" index="$2" field="$3"
  if [[ "$LOG_YAML_TOOL" == "yq" ]]; then
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

_log_env_field() {
  local file="$1" field="$2"
  if [[ "$LOG_YAML_TOOL" == "yq" ]]; then
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
# Status severity ranking, used to compute the worst status across services
# ---------------------------------------------------------------------------
_log_status_rank() {
  case "$1" in
    CRITICAL) echo 4 ;;
    WARNING) echo 3 ;;
    UNKNOWN) echo 2 ;;
    NOT_CONFIGURED|NOT_APPLICABLE) echo 1 ;;
    *) echo 0 ;;
  esac
}

_log_worse_status() {
  local a="$1" b="$2"
  local ra rb
  ra="$(_log_status_rank "$a")"
  rb="$(_log_status_rank "$b")"
  if [[ "$rb" -gt "$ra" ]]; then
    printf '%s' "$b"
  else
    printf '%s' "$a"
  fi
}

# ---------------------------------------------------------------------------
# LOG-01: log directory exists and is traversable
# ---------------------------------------------------------------------------
log_check_01_dir_exists() {
  local log_dir="$1" name="$2"

  local status evidence layer repair
  if [[ ! -d "$log_dir" ]]; then
    status="CRITICAL"
    evidence="log directory missing: ${log_dir}"
    layer="filesystem"
    repair="none"
  else
    local mode
    mode="$(stat --format=%a "$log_dir" 2>/dev/null || echo '')"
    if [[ -z "$mode" || $(( (8#$mode) & 8#111 )) -eq 0 ]]; then
      status="WARNING"
      evidence="log directory exists but not traversable (mode ${mode:-unknown}): ${log_dir}"
      layer="filesystem"
      repair="$_LOG_PERMISSIONS_REPAIR"
    else
      status="HEALTHY"
      evidence="log directory OK (mode ${mode}): ${log_dir}"
      layer="none"
      repair="none"
    fi
  fi

  result_add "LOG-01" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LOG-02: today's log file exists. Prints two lines: status, then the file
# to use for downstream checks (today's if present, else yesterday's if
# present, else empty).
# ---------------------------------------------------------------------------
log_check_02_today_file() {
  local log_dir="$1" name="$2"

  local today yesterday
  today="$(date +%Y%m%d)"
  yesterday="$(date -d 'yesterday' +%Y%m%d)"

  local today_file="${log_dir}/${name}-${today}.log"
  local yesterday_file="${log_dir}/${name}-${yesterday}.log"

  local status evidence layer repair target_file=""
  if [[ -f "$today_file" ]]; then
    status="HEALTHY"
    evidence="today's log file exists: ${today_file}"
    layer="none"
    repair="none"
    target_file="$today_file"
  elif [[ -f "$yesterday_file" ]]; then
    status="WARNING"
    evidence="today's log file missing but yesterday's exists (may not have logged yet today): ${yesterday_file}"
    layer="application"
    repair="none"
    target_file="$yesterday_file"
  else
    status="CRITICAL"
    evidence="neither today's nor yesterday's log file exists: ${today_file}"
    layer="application"
    repair="none"
  fi

  result_add "LOG-02" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s\n' "$status"
  printf '%s\n' "$target_file"
}

# ---------------------------------------------------------------------------
# LOG-03: file is readable and non-empty.
# svc01_status/svc03_status are optional — when both are supplied as
# HEALTHY and the file is empty, the result is reframed as a confirmed
# idle service (see the module-level integration note in run_log_checks).
# ---------------------------------------------------------------------------
log_check_03_readable() {
  local name="$1" target_file="$2" log02_status="$3"
  local svc01_status="${4:-}" svc03_status="${5:-}"

  if [[ "$log02_status" == "CRITICAL" ]]; then
    result_add "LOG-03" "$name" "NOT_APPLICABLE" "no log file to check (LOG-02 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local status evidence layer repair
  local mode
  mode="$(stat --format=%a "$target_file" 2>/dev/null || echo '')"

  if [[ -z "$mode" ]]; then
    status="CRITICAL"
    evidence="log file exists but could not be inspected: ${target_file}"
    layer="filesystem"
    repair="$_LOG_PERMISSIONS_REPAIR"
  elif [[ $(( (8#$mode) & 8#444 )) -eq 0 ]]; then
    status="CRITICAL"
    evidence="log file exists but not readable (mode ${mode}): ${target_file}"
    layer="filesystem"
    repair="$_LOG_PERMISSIONS_REPAIR"
  else
    local size
    size="$(stat --format=%s "$target_file" 2>/dev/null || echo 0)"
    if [[ "$size" -eq 0 ]]; then
      status="WARNING"
      repair="none"
      if [[ "$svc01_status" == "HEALTHY" && "$svc03_status" == "HEALTHY" ]]; then
        evidence="service appears idle (no recent traffic)"
        layer="application-idle"
      else
        evidence="log file readable but empty: ${target_file} (service may be inactive — check SVC result)"
        layer="application"
      fi
    else
      status="HEALTHY"
      evidence="log file readable, size ${size} bytes: ${target_file}"
      layer="none"
      repair="none"
    fi
  fi

  result_add "LOG-03" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LOG-04: freshness. Staleness alone is capped at WARNING — never CRITICAL —
# per spec: an idle low-traffic service is not an outage. svc01/svc03
# handling mirrors LOG-03 (see module-level integration note).
# ---------------------------------------------------------------------------
log_check_04_freshness() {
  local name="$1" target_file="$2" log02_status="$3" freshness_minutes="$4"
  local svc01_status="${5:-}" svc03_status="${6:-}"

  if [[ "$log02_status" == "CRITICAL" ]]; then
    result_add "LOG-04" "$name" "NOT_APPLICABLE" "no log file to check (LOG-02 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local mtime now threshold_seconds age_seconds
  mtime="$(stat --format=%Y "$target_file" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  threshold_seconds=$(( freshness_minutes * 60 ))
  age_seconds=$(( now - mtime ))

  local status evidence layer repair
  if [[ "$age_seconds" -le "$threshold_seconds" ]]; then
    status="HEALTHY"
    evidence="log file fresh: last modified ${age_seconds}s ago (threshold ${threshold_seconds}s)"
    layer="none"
    repair="none"
  else
    status="WARNING"
    repair="none"
    if [[ "$svc01_status" == "HEALTHY" && "$svc03_status" == "HEALTHY" ]]; then
      evidence="service appears idle (no recent traffic)"
      layer="application-idle"
    else
      evidence="log file stale (${age_seconds}s ago, threshold ${threshold_seconds}s) — service running but not logging (suspicious)"
      layer="application"
    fi
  fi

  result_add "LOG-04" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LOG-05: ownership check
# ---------------------------------------------------------------------------
log_check_05_ownership() {
  local name="$1" target_file="$2" log02_status="$3"

  if [[ "$log02_status" == "CRITICAL" ]]; then
    result_add "LOG-05" "$name" "NOT_APPLICABLE" "no log file to check (LOG-02 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local owner_group
  owner_group="$(stat --format="%U %G" "$target_file" 2>/dev/null || echo '')"

  local status evidence layer repair
  if [[ "$owner_group" == "${_LOG_EXPECTED_OWNER} ${_LOG_EXPECTED_GROUP}" ]]; then
    status="HEALTHY"
    evidence="ownership OK: ${owner_group}"
    layer="none"
    repair="none"
  else
    status="WARNING"
    evidence="unexpected ownership: '${owner_group}' (expected '${_LOG_EXPECTED_OWNER} ${_LOG_EXPECTED_GROUP}')"
    layer="filesystem"
    repair="$_LOG_PERMISSIONS_REPAIR"
  fi

  result_add "LOG-05" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LOG-06: wrong-location check — files matching this service's log pattern
# found outside its expected log_dir, modified in the last hour.
# ---------------------------------------------------------------------------
log_check_06_wrong_location() {
  local name="$1" base_dir="$2" log_dir="$3"

  local -a found=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    found+=("$line")
  done < <(find "$base_dir" -name "${name}-*.log" -not -path "${log_dir}/*" -mmin -60 2>/dev/null || true)

  local status evidence layer repair
  if [[ ${#found[@]} -eq 0 ]]; then
    status="HEALTHY"
    evidence="no ${name} log files found outside ${log_dir}"
    layer="none"
    repair="none"
  else
    local excerpt
    excerpt="$(printf '%s, ' "${found[@]:0:$_LOG_WRONG_LOCATION_EXCERPT_MAX}")"
    excerpt="${excerpt%, }"
    status="WARNING"
    evidence="log files found outside expected location: ${excerpt}"
    layer="application"
    repair="none"
  fi

  result_add "LOG-06" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LOG-07: disk and inode space — run once per environment, not per service.
# target is "<env>/logs-filesystem" per spec.
# ---------------------------------------------------------------------------
log_check_07_disk_space() {
  local env="$1" log_dir="$2"

  local disk_pct inode_pct
  disk_pct="$(df --output=pcent "$log_dir" 2>/dev/null | tail -n 1 | tr -dc '0-9')"
  inode_pct="$(df --output=ipcent "$log_dir" 2>/dev/null | tail -n 1 | tr -dc '0-9')"
  [[ -z "$disk_pct" ]] && disk_pct=0
  [[ -z "$inode_pct" ]] && inode_pct=0

  local status evidence layer repair
  if [[ "$disk_pct" -gt "$_LOG_DISK_CRIT_PCT" || "$inode_pct" -gt "$_LOG_DISK_CRIT_PCT" ]]; then
    status="CRITICAL"
    evidence="disk ${disk_pct}% used, inodes ${inode_pct}% used"
    layer="filesystem"
    repair="none"
  elif [[ "$disk_pct" -ge "$_LOG_DISK_WARN_PCT" || "$inode_pct" -ge "$_LOG_DISK_WARN_PCT" ]]; then
    status="WARNING"
    evidence="disk ${disk_pct}% used, inodes ${inode_pct}% used"
    layer="filesystem"
    repair="none"
  else
    status="HEALTHY"
    evidence="disk ${disk_pct}% used, inodes ${inode_pct}% used"
    layer="none"
    repair="none"
  fi

  result_add "LOG-07" "${env}/logs-filesystem" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# LOG-08: rotation sanity — file count in the expected 1..35 range
# (roughly monthly rotation at daily granularity).
# ---------------------------------------------------------------------------
log_check_08_rotation() {
  local name="$1" log_dir="$2" log02_status="$3"

  if [[ "$log02_status" == "CRITICAL" ]]; then
    result_add "LOG-08" "$name" "NOT_APPLICABLE" "no log file to check (LOG-02 critical)" "none" "none"
    printf 'NOT_APPLICABLE'
    return 0
  fi

  local count
  count="$(find "$log_dir" -maxdepth 1 -name "${name}-*.log" 2>/dev/null | wc -l | tr -d ' ')"

  local status evidence layer repair
  if [[ "$count" -ge 1 && "$count" -le "$_LOG_ROTATION_MAX_FILES" ]]; then
    status="HEALTHY"
    evidence="${count} log files present (expected 1-${_LOG_ROTATION_MAX_FILES})"
    layer="none"
    repair="none"
  elif [[ "$count" -gt "$_LOG_ROTATION_MAX_FILES" ]]; then
    status="WARNING"
    evidence="${count} log files present (> ${_LOG_ROTATION_MAX_FILES} — rotation may have stopped)"
    layer="filesystem"
    repair="none"
  else
    status="WARNING"
    evidence="0 log files present"
    layer="application"
    repair="none"
  fi

  result_add "LOG-08" "$name" "$status" "$evidence" "$layer" "$repair"
  printf '%s' "$status"
}

# ---------------------------------------------------------------------------
# run_log_checks <env> — runs LOG-07 once, then LOG-01/02/03/04/05/06/08
# for every service in inventory.<env>.yaml. Returns the worst status.
#
# Integration note: LOG-03/04's optional svc01/svc03 parameters (the
# "confirmed idle" refinement) are not populated here, since this
# function only has LOG-family context — it does not re-derive or import
# SVC-family results. Wiring cross-family context through is an
# orchestration-level concern for whichever later phase assembles
# run-infra-report.sh's full per-service pass across all check families.
# Called standalone (as here), the idle refinement simply never triggers;
# LOG-03/04 still correctly cap severity at WARNING regardless.
# ---------------------------------------------------------------------------
run_log_checks() {
  local env="$1"
  local inventory_file="${LOG_CONFIG_DIR}/inventory.${env}.yaml"

  if [[ ! -f "$inventory_file" ]]; then
    _result_log ERROR "Inventory file not found: ${inventory_file}"
    return 1
  fi

  _log_detect_yaml_tool || return 1

  local services_base_dir
  services_base_dir="$(_log_env_field "$inventory_file" services_base_dir)"

  local worst="HEALTHY"

  local log07
  log07="$(log_check_07_disk_space "$env" "${services_base_dir}/logs")"
  worst="$(_log_worse_status "$worst" "$log07")"

  local count
  count="$(_log_count "$inventory_file")"

  local i
  for (( i = 0; i < count; i++ )); do
    local name log_dir freshness_minutes
    name="$(_log_field "$inventory_file" "$i" name)"
    log_dir="$(_log_field "$inventory_file" "$i" log_dir)"
    freshness_minutes="$(_log_field "$inventory_file" "$i" freshness_threshold_minutes)"

    local log01
    log01="$(log_check_01_dir_exists "$log_dir" "$name")"

    local log02_out log02 target_file
    log02_out="$(log_check_02_today_file "$log_dir" "$name")"
    log02="$(printf '%s\n' "$log02_out" | sed -n '1p')"
    target_file="$(printf '%s\n' "$log02_out" | sed -n '2p')"

    local log03
    log03="$(log_check_03_readable "$name" "$target_file" "$log02")"

    local log04
    log04="$(log_check_04_freshness "$name" "$target_file" "$log02" "$freshness_minutes")"

    local log05
    log05="$(log_check_05_ownership "$name" "$target_file" "$log02")"

    local log06
    log06="$(log_check_06_wrong_location "$name" "$services_base_dir" "$log_dir")"

    local log08
    log08="$(log_check_08_rotation "$name" "$log_dir" "$log02")"

    local s
    for s in "$log01" "$log02" "$log03" "$log04" "$log05" "$log06" "$log08"; do
      worst="$(_log_worse_status "$worst" "$s")"
    done
  done

  printf '%s' "$worst"
}
