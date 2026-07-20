#!/bin/bash
# operations/repairs/lib/repair-common.sh
#
# Shared library for Phase 8 repair scripts. This file is sourced, never
# executed directly. It provides the confirm/backup/rollback/audit
# machinery every repair script must use.
#
# Exit codes used across the repair library:
#   0 success
#   1 precondition fail
#   2 user abort
#   3 verify-fail + rollback-ok (or verify-fail with nothing to roll back)
#   4 rollback-failed (CRITICAL)

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "repair-common.sh is a library and must be sourced, not executed." >&2
  exit 1
fi

REPAIR_BACKUP_ROOT="${REPAIR_BACKUP_ROOT:-/opt/repairs/backups}"
REPAIR_AUDIT_LOG="${REPAIR_AUDIT_LOG:-/var/log/dhanman/infra-audit/repairs.jsonl}"
REPAIR_ENV_FILE="${REPAIR_ENV_FILE:-/etc/dhanman-env}"

# ---------------------------------------------------------------------------
# repair_init <script_name> <target> <scope>
# ---------------------------------------------------------------------------
repair_init() {
  local script_name="$1"
  local target="$2"
  local scope="$3"

  REPAIR_SCRIPT_NAME="$script_name"
  REPAIR_TARGET="$target"
  # shellcheck disable=SC2034  # exported public state (like REPAIR_TARGET), not read within this file
  REPAIR_SCOPE="$scope"
  REPAIR_ID="$(date +%Y%m%d-%H%M%S)-${script_name}-${target}"
  REPAIR_BACKUP_DIR="${REPAIR_BACKUP_ROOT}/${script_name}/${REPAIR_ID}/"
  REPAIR_BACKUP_FILE=""
  REPAIR_BACKUP_SOURCE=""
  REPAIR_BACKUP_SHA256=""
  REPAIR_ENV=""

  mkdir -p "$REPAIR_BACKUP_DIR"

  echo "═══════════════════════════════════════════════════════" >&2
  echo "REPAIR SCRIPT: ${script_name}" >&2
  echo "TARGET: ${target}" >&2
  echo "SCOPE: ${scope}" >&2
  echo "REPAIR_ID: ${REPAIR_ID}" >&2
  echo "═══════════════════════════════════════════════════════" >&2

  return 0
}

# ---------------------------------------------------------------------------
# repair_env_check <env>
# ---------------------------------------------------------------------------
repair_env_check() {
  local env="$1"
  local actual_env=""
  local actual_host

  actual_host="$(hostname)"

  if [[ ! -f "$REPAIR_ENV_FILE" ]]; then
    echo "ABORT: ${REPAIR_ENV_FILE} not found; cannot verify environment" >&2
    exit 1
  fi

  actual_env="$(cat "$REPAIR_ENV_FILE")"

  if [[ "$actual_env" != "$env" ]]; then
    echo "ABORT: Expected env=${env} but running on ${actual_env} host ${actual_host}" >&2
    exit 1
  fi

  REPAIR_ENV="$env"
  return 0
}

# ---------------------------------------------------------------------------
# repair_target_allowlist <target_file> <allowed_prefixes...>
# ---------------------------------------------------------------------------
repair_target_allowlist() {
  local target_file="$1"
  shift
  local real_path real_prefix prefix

  real_path="$(realpath -m -- "$target_file" 2>/dev/null)" || {
    echo "ABORT: unable to resolve realpath for ${target_file}" >&2
    exit 1
  }

  for prefix in "$@"; do
    real_prefix="$(realpath -m -- "$prefix" 2>/dev/null)" || continue
    if [[ "$real_path" == "$real_prefix" || "$real_path" == "${real_prefix}/"* ]]; then
      return 0
    fi
  done

  echo "ABORT: target_file ${target_file} is outside allowlist" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# repair_show_current_state <target>
# ---------------------------------------------------------------------------
repair_show_current_state() {
  local target="$1"
  local load_state

  if [[ -f "$target" ]]; then
    echo "--- Current content of ${target} (first 500 lines) ---" >&2
    # `|| true`: under set -e + pipefail, head closing the pipe early on a
    # long/wide file sends nl a SIGPIPE, which would otherwise abort the
    # caller even though this is purely informational output.
    { nl -ba -- "$target" 2>/dev/null | head -n 500 >&2; } || true
    return 0
  fi

  # `systemctl show <anything>` exits 0 even for a unit that doesn't exist
  # (it just returns LoadState=not-found), so existence must be checked via
  # LoadState rather than the command's exit code.
  load_state="$(systemctl show "$target" -p LoadState --value 2>/dev/null)" || load_state=""

  if [[ -n "$load_state" && "$load_state" != "not-found" ]]; then
    echo "--- Current systemd state of ${target} ---" >&2
    systemctl show "$target" -p ControlGroup,ExecMainPID,State,Restart >&2
  else
    echo "--- ${target} is not a file and not a known systemd unit; nothing to show ---" >&2
  fi

  return 0
}

# ---------------------------------------------------------------------------
# repair_backup_with_checksum <target_file>
# ---------------------------------------------------------------------------
repair_backup_with_checksum() {
  local target_file="$1"
  local checksum short_hash base backup_file

  if [[ ! -f "$target_file" ]]; then
    echo "ABORT: cannot back up; ${target_file} does not exist or is not a file" >&2
    exit 1
  fi

  checksum="$(sha256sum -- "$target_file" | cut -d' ' -f1)"
  short_hash="${checksum:0:8}"
  base="$(basename -- "$target_file")"
  backup_file="${REPAIR_BACKUP_DIR}${base}.$(date +%s).${short_hash}.bak"

  cp -p -- "$target_file" "$backup_file"

  REPAIR_BACKUP_FILE="$backup_file"
  REPAIR_BACKUP_SOURCE="$target_file"
  REPAIR_BACKUP_SHA256="$checksum"

  echo "Backed up to ${REPAIR_BACKUP_FILE}" >&2

  return 0
}

# ---------------------------------------------------------------------------
# repair_confirm <action_description> <env>
# ---------------------------------------------------------------------------
repair_confirm() {
  local action_description="$1"
  local env="$2"
  local reply today expected_phrase

  if [[ "$env" == "prod" ]]; then
    today="$(date +%Y%m%d)"
    expected_phrase="PROD REPAIR ${REPAIR_TARGET} ${today}"
    echo -n "Do you want to ${action_description}? (${expected_phrase}): " >&2
    # `|| reply=""`: under set -e, a closed/EOF stdin makes `read` fail and
    # would abort the script here with exit 1 instead of the documented
    # exit 2 "cancelled by operator" — an empty reply correctly falls
    # through to the mismatch branch below instead.
    read -r reply || reply=""
    if [[ "$reply" != "$expected_phrase" ]]; then
      echo "Repair cancelled by operator" >&2
      exit 2
    fi
  else
    echo -n "Do you want to ${action_description}? (yes/no): " >&2
    # `|| reply=""`: under set -e, a closed/EOF stdin makes `read` fail and
    # would abort the script here with exit 1 instead of the documented
    # exit 2 "cancelled by operator" — an empty reply correctly falls
    # through to the mismatch branch below instead.
    read -r reply || reply=""
    if [[ "$reply" != "yes" ]]; then
      echo "Repair cancelled by operator" >&2
      exit 2
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# repair_apply_change <command> <description>
# ---------------------------------------------------------------------------
repair_apply_change() {
  local command="$1"
  local description="$2"

  if ! bash -c "$command"; then
    echo "✗ ${description} FAILED" >&2
    repair_rollback_and_exit 3
  fi

  echo "✓ ${description} completed" >&2
  return 0
}

# ---------------------------------------------------------------------------
# repair_postcheck <command> <expected_state>
# ---------------------------------------------------------------------------
repair_postcheck() {
  local command="$1"
  local expected_state="$2"
  local actual_output

  actual_output="$(bash -c "$command" 2>&1)" || true

  if [[ "$actual_output" == "$expected_state" ]]; then
    echo "✓ Postcheck passed: ${expected_state}" >&2
    return 0
  fi

  echo "✗ Postcheck FAILED: expected ${expected_state}, got ${actual_output}" >&2
  repair_rollback_and_exit 3
}

# ---------------------------------------------------------------------------
# repair_tripwire_check <file_allowlist>
# ---------------------------------------------------------------------------
repair_tripwire_check() {
  local file_allowlist="$1"
  local threshold=5
  local scan_root="${REPAIR_TRIPWIRE_ROOT:-/}"
  local f count

  for f in $file_allowlist; do
    if [[ -e "$f" ]]; then
      # `find` routinely exits non-zero on a live host (files vanishing
      # mid-traversal under /proc, /run, etc.) even when it printed valid
      # results; under the caller's set -e + pipefail that would abort this
      # advisory, warning-only check — and everything after it, including
      # the success audit record. `|| count=0` keeps this non-fatal.
      count="$(find "$scan_root" -newer "$f" -type f 2>/dev/null | wc -l)" || count=0
      if (( count > threshold )); then
        echo "⚠ WARNING: ${count} files newer than ${f} (threshold: ${threshold}); review for unintended side effects" >&2
      fi
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# _repair_json_escape <string>
# ---------------------------------------------------------------------------
_repair_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# repair_audit_record <status> <precheck> <postcheck> <files_modified>
# ---------------------------------------------------------------------------
repair_audit_record() {
  local status="$1"
  local precheck="$2"
  local postcheck="$3"
  local files_modified="$4"
  local ts actor exit_code
  local esc_precheck esc_postcheck esc_files

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  actor="${SUDO_USER:-infraverify}"

  case "$status" in
    succeeded) exit_code=0 ;;
    failed) exit_code=1 ;;
    verify-failed) exit_code=3 ;;
    rollback-succeeded) exit_code=3 ;;
    rollback-failed) exit_code=4 ;;
    *) exit_code=1 ;;
  esac

  esc_precheck="$(_repair_json_escape "${precheck:0:2000}")"
  esc_postcheck="$(_repair_json_escape "${postcheck:0:2000}")"
  esc_files="$(_repair_json_escape "$files_modified")"

  mkdir -p "$(dirname -- "$REPAIR_AUDIT_LOG")" 2>/dev/null || true

  printf '{"ts":"%s","repair_id":"%s","script":"%s","target":"%s","status":"%s","env":"%s","actor":"%s","precheck":"%s","postcheck":"%s","files_modified":"%s","backup_path":"%s","backup_sha256":"%s","exit_code":%s}\n' \
    "$ts" "$REPAIR_ID" "$REPAIR_SCRIPT_NAME" "$REPAIR_TARGET" "$status" "${REPAIR_ENV:-unknown}" "$actor" \
    "$esc_precheck" "$esc_postcheck" "$esc_files" "$REPAIR_BACKUP_FILE" "$REPAIR_BACKUP_SHA256" "$exit_code" \
    >> "$REPAIR_AUDIT_LOG"

  return 0
}

# ---------------------------------------------------------------------------
# repair_rollback_and_exit <exit_code>
# ---------------------------------------------------------------------------
repair_rollback_and_exit() {
  local exit_code="$1"
  local restored_sha

  if [[ -z "$REPAIR_BACKUP_FILE" ]]; then
    # No file backup exists for this repair (e.g. a service/container restart
    # that never modified a file) — there is nothing to restore. This is
    # recorded as "verify-failed", not "failed": the mutation already
    # happened (the service/container WAS restarted) and only the postcheck
    # failed, which is a materially different situation from a precondition
    # failure where nothing was touched — and its exit_code (3) matches what
    # the process actually exits with, unlike a plain "failed" record would.
    echo "No file backup to restore for this repair (target is not a file)." >&2
    repair_audit_record "verify-failed" "" "" "$REPAIR_TARGET"
    exit "$exit_code"
  fi

  if [[ -f "$REPAIR_BACKUP_FILE" ]] && cp -p -- "$REPAIR_BACKUP_FILE" "$REPAIR_BACKUP_SOURCE"; then
    restored_sha="$(sha256sum -- "$REPAIR_BACKUP_SOURCE" | cut -d' ' -f1)"
    if [[ "$restored_sha" == "$REPAIR_BACKUP_SHA256" ]]; then
      echo "Rollback completed: ${REPAIR_BACKUP_SOURCE} restored from ${REPAIR_BACKUP_FILE}" >&2
      repair_audit_record "rollback-succeeded" "" "" "$REPAIR_BACKUP_SOURCE"
      exit 3
    fi
  fi

  echo "CRITICAL: Rollback FAILED. Manual intervention required." >&2
  echo "Backup is preserved at: ${REPAIR_BACKUP_FILE}" >&2
  repair_audit_record "rollback-failed" "" "" "$REPAIR_BACKUP_SOURCE"
  # TODO(Phase 10): send immediate email to infra_lead@dhanman.com
  exit 4
}
