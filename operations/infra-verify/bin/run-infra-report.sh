#!/usr/bin/env bash
#
# run-infra-report.sh — COO Infrastructure Verification entrypoint (skeleton).
# Phase 1 / T1.1: argument parsing, locking, global timeout, logging, and
# check-stub wiring only. No checks are implemented yet (see T1.3/T1.4).

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly SCRIPT_DIR
readonly VERSION="0.1.0"
readonly LOCK_FILE="/var/lock/infra-verify.lock"
HISTORY_DIR="$(realpath -m "${SCRIPT_DIR}/../history")"
readonly HISTORY_DIR
readonly AUDIT_LOG="/var/log/dhanman/infra-audit"
readonly DEFAULT_TIMEOUT=5
readonly GLOBAL_TIMEOUT=600

readonly ALLOWED_ENVIRONMENTS=(qa prod)
readonly ALLOWED_COMPONENTS=(services health logging promtail loki prometheus grafana)
readonly ALLOWED_SERVICES=(
  dhanman-common
  dhanman-community
  dhanman-inventory
  dhanman-payroll
  dhanman-purchase
  dhanman-sales
  dhanman-payment
  dhanman-document
  dhanman-agent
  dhanman-einvoice
)

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
ALL_FLAG=false
ENVIRONMENT=""
SERVICE=""
COMPONENT=""
DRY_RUN=false
RUN_ID=""
declare -a CHECK_RESULTS=()

# ---------------------------------------------------------------------------
# Logging — stderr only; stdout is reserved for JSON report output (later phases)
# ---------------------------------------------------------------------------
log() {
  local level="$1"
  shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s [%s] %s\n' "$ts" "$level" "$*" >&2
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
print_usage() {
  cat <<'EOF'
Usage: run-infra-report.sh [OPTIONS]

Options:
  --all                    Run checks for both qa and prod environments
  --environment <env>      Run checks for a single environment (qa or prod)
  --service <name>         Filter checks to a single service (requires --environment)
  --component <name>       Filter checks to one component family
                            (services|health|logging|promtail|loki|prometheus|grafana)
                            (requires --environment)
  --dry-run                Print what would run without executing any checks
  --help                   Show this help message and exit

Notes:
  --all and --environment are mutually exclusive.
  --service and --component both require --environment (not valid with --all).
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        ALL_FLAG=true
        shift
        ;;
      --environment)
        if [[ $# -lt 2 ]]; then
          log ERROR "--environment requires a value"
          exit 1
        fi
        ENVIRONMENT="$2"
        shift 2
        ;;
      --service)
        if [[ $# -lt 2 ]]; then
          log ERROR "--service requires a value"
          exit 1
        fi
        SERVICE="$2"
        shift 2
        ;;
      --component)
        if [[ $# -lt 2 ]]; then
          log ERROR "--component requires a value"
          exit 1
        fi
        COMPONENT="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help)
        print_usage
        exit 0
        ;;
      *)
        log ERROR "Unrecognised argument: $1"
        print_usage >&2
        exit 1
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
is_in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$needle" == "$item" ]]; then
      return 0
    fi
  done
  return 1
}

validate_args() {
  if $ALL_FLAG && [[ -n "$ENVIRONMENT" ]]; then
    log ERROR "--all and --environment are mutually exclusive"
    exit 1
  fi

  if ! $ALL_FLAG && [[ -z "$ENVIRONMENT" ]]; then
    log ERROR "Either --all or --environment must be specified"
    print_usage >&2
    exit 1
  fi

  if [[ -n "$ENVIRONMENT" ]] && ! is_in_list "$ENVIRONMENT" "${ALLOWED_ENVIRONMENTS[@]}"; then
    log ERROR "Invalid --environment value: '${ENVIRONMENT}' (must be exactly 'qa' or 'prod')"
    exit 1
  fi

  if [[ -n "$SERVICE" ]]; then
    if $ALL_FLAG || [[ -z "$ENVIRONMENT" ]]; then
      log ERROR "--service requires --environment and is not valid with --all"
      exit 1
    fi
    if ! is_in_list "$SERVICE" "${ALLOWED_SERVICES[@]}"; then
      log ERROR "Invalid --service value: '${SERVICE}' (not in inventory allowlist)"
      exit 1
    fi
  fi

  if [[ -n "$COMPONENT" ]]; then
    if $ALL_FLAG || [[ -z "$ENVIRONMENT" ]]; then
      log ERROR "--component requires --environment and is not valid with --all"
      exit 1
    fi
    if ! is_in_list "$COMPONENT" "${ALLOWED_COMPONENTS[@]}"; then
      log ERROR "Invalid --component value: '${COMPONENT}' (must be one of: ${ALLOWED_COMPONENTS[*]})"
      exit 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Run ID
# ---------------------------------------------------------------------------
generate_run_id() {
  local env_label="${ENVIRONMENT:-all}"
  RUN_ID="$(date +%Y%m%d-%H%M%S)-${env_label}"
}

# ---------------------------------------------------------------------------
# Lock (flock on LOCK_FILE, fd 200)
# ---------------------------------------------------------------------------
acquire_lock() {
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    log ERROR "Another infra-verify run is already in progress (lock: ${LOCK_FILE}). Exiting."
    exit 75
  fi
}

release_lock() {
  exec 200>&- 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Check stubs — implemented in T1.3 (SVC/HLT) and later phases
# ---------------------------------------------------------------------------
check_services_stub()   { :; }
check_health_stub()     { :; }
check_logging_stub()    { :; }
check_promtail_stub()   { :; }
check_loki_stub()       { :; }
check_prometheus_stub() { :; }
check_grafana_stub()    { :; }

run_checks() {
  check_services_stub
  check_health_stub
  check_logging_stub
  check_promtail_stub
  check_loki_stub
  check_prometheus_stub
  check_grafana_stub
}

# ---------------------------------------------------------------------------
# Generic timeout wrapper — backgrounds a command with a watchdog that sends
# SIGTERM after the given number of seconds.
# ---------------------------------------------------------------------------
run_with_timeout() {
  local timeout_secs="$1"
  shift

  "$@" &
  local pid=$!

  (
    sleep "$timeout_secs"
    kill -TERM "$pid" 2>/dev/null || true
  ) &
  local watchdog_pid=$!

  local exit_code=0
  wait "$pid" || exit_code=$?

  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  return "$exit_code"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log INFO "run-infra-report.sh v${VERSION} | lock=${LOCK_FILE} | history_dir=${HISTORY_DIR} | audit_log=${AUDIT_LOG} | default_timeout=${DEFAULT_TIMEOUT}s | global_timeout=${GLOBAL_TIMEOUT}s"

  parse_args "$@"
  validate_args
  generate_run_id

  log INFO "Starting infra-verify run_id=${RUN_ID} environment=${ENVIRONMENT:-all} component=${COMPONENT:-all} service=${SERVICE:-all} dry_run=${DRY_RUN} (result collector initialised with ${#CHECK_RESULTS[@]} results)"

  if $DRY_RUN; then
    log INFO "[dry-run] would execute checks for environment=${ENVIRONMENT:-all} component=${COMPONENT:-all} service=${SERVICE:-all}"
    log INFO "Completed infra-verify run_id=${RUN_ID} (dry-run)"
    return 0
  fi

  acquire_lock

  local rc=0
  run_with_timeout "$GLOBAL_TIMEOUT" run_checks || rc=$?

  if [[ $rc -eq 143 ]]; then
    log ERROR "Run exceeded global timeout of ${GLOBAL_TIMEOUT}s — aborting"
    exit 3
  elif [[ $rc -ne 0 ]]; then
    exit "$rc"
  fi

  log INFO "Completed infra-verify run_id=${RUN_ID}"
  return 0
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
trap release_lock EXIT
main "$@"
