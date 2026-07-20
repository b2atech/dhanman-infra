#!/usr/bin/env bats
# Unit tests for operations/repairs/lib/repair-common.sh
#
# Each function that calls `exit` is invoked via a `run bash -c '...'`
# subshell so a call to exit() ends the subshell, not the bats process.
# State (REPAIR_ID, REPAIR_BACKUP_FILE, etc.) only persists within one
# `run bash -c` invocation, so any test that needs multiple library calls
# to share state chains them inside a single subshell script.

setup() {
  LIB="${BATS_TEST_DIRNAME}/repair-common.sh"
  export REPAIR_BACKUP_ROOT="${BATS_TEST_TMPDIR}/backups"
  export REPAIR_AUDIT_LOG="${BATS_TEST_TMPDIR}/audit/repairs.jsonl"
  export REPAIR_ENV_FILE="${BATS_TEST_TMPDIR}/dhanman-env"
  mkdir -p "$REPAIR_BACKUP_ROOT"
}

# ---------------------------------------------------------------------------
# repair_init
# ---------------------------------------------------------------------------

@test "repair_init sets REPAIR_ID, REPAIR_BACKUP_DIR and creates the backup dir" {
  run bash -c '
    source "'"$LIB"'"
    repair_init "myscript" "mytarget" "do the thing"
    echo "ID=$REPAIR_ID"
    echo "DIR=$REPAIR_BACKUP_DIR"
    [[ -d "$REPAIR_BACKUP_DIR" ]] && echo "DIR_EXISTS=yes"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"REPAIR SCRIPT: myscript"* ]]
  [[ "$output" == *"TARGET: mytarget"* ]]
  [[ "$output" == *"SCOPE: do the thing"* ]]
  [[ "$output" =~ ID=[0-9]{8}-[0-9]{6}-myscript-mytarget ]]
  [[ "$output" == *"DIR_EXISTS=yes"* ]]
}

# ---------------------------------------------------------------------------
# repair_env_check
# ---------------------------------------------------------------------------

@test "repair_env_check succeeds and sets REPAIR_ENV when env matches" {
  echo -n "qa" > "$REPAIR_ENV_FILE"
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_env_check "qa"
    echo "ENV=$REPAIR_ENV"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENV=qa"* ]]
}

@test "repair_env_check exits 1 with ABORT message when env mismatches" {
  echo -n "prod" > "$REPAIR_ENV_FILE"
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_env_check "qa"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT: Expected env=qa but running on prod host"* ]]
}

@test "repair_env_check exits 1 when the env file is missing" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_env_check "qa"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT:"*"not found"* ]]
}

# ---------------------------------------------------------------------------
# repair_target_allowlist
# ---------------------------------------------------------------------------

@test "repair_target_allowlist accepts a path under an allowed prefix" {
  mkdir -p "${BATS_TEST_TMPDIR}/etc/nginx/sites-enabled"
  touch "${BATS_TEST_TMPDIR}/etc/nginx/sites-enabled/service.conf"
  run bash -c '
    source "'"$LIB"'"
    repair_target_allowlist "'"${BATS_TEST_TMPDIR}"'/etc/nginx/sites-enabled/service.conf" "'"${BATS_TEST_TMPDIR}"'/etc/nginx"
    echo "OK"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "repair_target_allowlist rejects a path outside all allowed prefixes" {
  run bash -c '
    source "'"$LIB"'"
    repair_target_allowlist "/evil/path" "/etc/nginx" "/opt/infra-verify"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT: target_file /evil/path is outside allowlist"* ]]
}

@test "repair_target_allowlist rejects a sibling directory that merely shares a prefix string" {
  mkdir -p "${BATS_TEST_TMPDIR}/etc/nginx-evil"
  touch "${BATS_TEST_TMPDIR}/etc/nginx-evil/file"
  run bash -c '
    source "'"$LIB"'"
    repair_target_allowlist "'"${BATS_TEST_TMPDIR}"'/etc/nginx-evil/file" "'"${BATS_TEST_TMPDIR}"'/etc/nginx"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"is outside allowlist"* ]]
}

@test "repair_target_allowlist rejects a path that escapes via .." {
  mkdir -p "${BATS_TEST_TMPDIR}/etc/nginx"
  run bash -c '
    source "'"$LIB"'"
    repair_target_allowlist "'"${BATS_TEST_TMPDIR}"'/etc/nginx/../../etc/passwd" "'"${BATS_TEST_TMPDIR}"'/etc/nginx"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"is outside allowlist"* ]]
}

# ---------------------------------------------------------------------------
# repair_show_current_state
# ---------------------------------------------------------------------------

@test "repair_show_current_state prints file content for a real file" {
  echo "hello world" > "${BATS_TEST_TMPDIR}/somefile.txt"
  run bash -c '
    source "'"$LIB"'"
    repair_show_current_state "'"${BATS_TEST_TMPDIR}"'/somefile.txt"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello world"* ]]
}

@test "repair_show_current_state falls back gracefully for a nonexistent target" {
  run bash -c '
    source "'"$LIB"'"
    repair_show_current_state "/no/such/file/or/unit"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a file and not a known systemd unit"* ]]
}

# ---------------------------------------------------------------------------
# repair_backup_with_checksum
# ---------------------------------------------------------------------------

@test "repair_backup_with_checksum copies the file and records its checksum" {
  echo "original content" > "${BATS_TEST_TMPDIR}/target.conf"
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_backup_with_checksum "'"${BATS_TEST_TMPDIR}"'/target.conf"
    echo "BACKUP_FILE=$REPAIR_BACKUP_FILE"
    echo "BACKUP_SHA=$REPAIR_BACKUP_SHA256"
    diff "'"${BATS_TEST_TMPDIR}"'/target.conf" "$REPAIR_BACKUP_FILE" && echo "CONTENT_MATCHES=yes"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backed up to"* ]]
  [[ "$output" =~ BACKUP_SHA=[0-9a-f]{64} ]]
  [[ "$output" == *"CONTENT_MATCHES=yes"* ]]
}

@test "repair_backup_with_checksum exits 1 when the source file does not exist" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_backup_with_checksum "'"${BATS_TEST_TMPDIR}"'/does-not-exist.conf"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT: cannot back up"* ]]
}

# ---------------------------------------------------------------------------
# repair_confirm
# ---------------------------------------------------------------------------

@test "repair_confirm succeeds on QA when the operator types yes" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s mytarget "scope"
    echo "yes" | repair_confirm "do the thing" "qa"
    echo "CONFIRMED"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFIRMED"* ]]
}

@test "repair_confirm exits 2 on QA when the operator does not type yes" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s mytarget "scope"
    echo "no" | repair_confirm "do the thing" "qa"
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"Repair cancelled by operator"* ]]
}

@test "repair_confirm succeeds on PROD only with the exact dated phrase" {
  today="$(date +%Y%m%d)"
  run bash -c '
    source "'"$LIB"'"
    repair_init s "myunit.service" "scope"
    echo "PROD REPAIR myunit.service '"$today"'" | repair_confirm "restart myunit.service" "prod"
    echo "CONFIRMED"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFIRMED"* ]]
}

@test "repair_confirm exits 2 on PROD when the phrase is wrong" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s "myunit.service" "scope"
    echo "yes" | repair_confirm "restart myunit.service" "prod"
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"Repair cancelled by operator"* ]]
}

@test "repair_confirm exits 2 on PROD when the date is stale" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s "myunit.service" "scope"
    echo "PROD REPAIR myunit.service 20200101" | repair_confirm "restart myunit.service" "prod"
  '
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# repair_apply_change
# ---------------------------------------------------------------------------

@test "repair_apply_change returns 0 and prints success on a passing command" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_apply_change "true" "no-op"
    echo "AFTER"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ no-op completed"* ]]
  [[ "$output" == *"AFTER"* ]]
}

@test "repair_apply_change on a failing command with no backup exits 3 (nothing to roll back)" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_apply_change "false" "always fails"
  '
  [ "$status" -eq 3 ]
  [[ "$output" == *"✗ always fails FAILED"* ]]
  [[ "$output" == *"No file backup to restore"* ]]
}

@test "repair_apply_change on a failing command with a backup rolls back and exits 3" {
  echo "original" > "${BATS_TEST_TMPDIR}/target.conf"
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_backup_with_checksum "'"${BATS_TEST_TMPDIR}"'/target.conf"
    echo "corrupted" > "'"${BATS_TEST_TMPDIR}"'/target.conf"
    repair_apply_change "false" "always fails"
  '
  [ "$status" -eq 3 ]
  [[ "$output" == *"Rollback completed"* ]]
  run cat "${BATS_TEST_TMPDIR}/target.conf"
  [[ "$output" == "original" ]]
}

# ---------------------------------------------------------------------------
# repair_postcheck
# ---------------------------------------------------------------------------

@test "repair_postcheck returns 0 when output matches expected_state" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_postcheck "echo active" "active"
    echo "AFTER"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ Postcheck passed: active"* ]]
  [[ "$output" == *"AFTER"* ]]
}

@test "repair_postcheck rolls back and exits 3 when output does not match" {
  echo "original" > "${BATS_TEST_TMPDIR}/target.conf"
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_backup_with_checksum "'"${BATS_TEST_TMPDIR}"'/target.conf"
    repair_postcheck "echo failed" "active"
  '
  [ "$status" -eq 3 ]
  [[ "$output" == *"✗ Postcheck FAILED: expected active, got failed"* ]]
  [[ "$output" == *"Rollback completed"* ]]
}

# ---------------------------------------------------------------------------
# repair_tripwire_check
# ---------------------------------------------------------------------------

@test "repair_tripwire_check never fails the repair (warning-only)" {
  touch "${BATS_TEST_TMPDIR}/marker"
  run bash -c '
    source "'"$LIB"'"
    export REPAIR_TRIPWIRE_ROOT="'"${BATS_TEST_TMPDIR}"'"
    repair_init s t "scope"
    repair_tripwire_check "'"${BATS_TEST_TMPDIR}"'/marker /no/such/path"
    echo "SURVIVED"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"SURVIVED"* ]]
}

@test "repair_tripwire_check warns when more than the threshold of files changed since the marker" {
  mkdir -p "${BATS_TEST_TMPDIR}/scan"
  touch "${BATS_TEST_TMPDIR}/scan/marker"
  sleep 1
  for i in 1 2 3 4 5 6; do touch "${BATS_TEST_TMPDIR}/scan/newfile$i"; done
  run bash -c '
    source "'"$LIB"'"
    export REPAIR_TRIPWIRE_ROOT="'"${BATS_TEST_TMPDIR}"'/scan"
    repair_init s t "scope"
    repair_tripwire_check "'"${BATS_TEST_TMPDIR}"'/scan/marker"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
}

# ---------------------------------------------------------------------------
# repair_audit_record
# ---------------------------------------------------------------------------

@test "repair_audit_record appends a valid JSONL line with the expected fields" {
  echo -n "qa" > "$REPAIR_ENV_FILE"
  run bash -c '
    source "'"$LIB"'"
    repair_init "svc-restart" "myunit.service" "scope"
    repair_env_check "qa"
    repair_audit_record "succeeded" "precheck out" "postcheck out" "myunit.service"
  '
  [ "$status" -eq 0 ]
  [ -f "$REPAIR_AUDIT_LOG" ]
  run cat "$REPAIR_AUDIT_LOG"
  [[ "$output" == *'"status":"succeeded"'* ]]
  [[ "$output" == *'"script":"svc-restart"'* ]]
  [[ "$output" == *'"target":"myunit.service"'* ]]
  [[ "$output" == *'"env":"qa"'* ]]
  [[ "$output" == *'"exit_code":0'* ]]
  # Each line must be independently parseable JSON.
  run python3 -c "import json; json.loads(open('${REPAIR_AUDIT_LOG}').readline())"
  [ "$status" -eq 0 ]
}

@test "repair_audit_record escapes quotes and newlines so each line stays valid JSON" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_audit_record "succeeded" "line with \"quotes\" and
a newline" "post" "files"
  '
  [ "$status" -eq 0 ]
  # The escaped line must still be exactly one line in the JSONL file.
  lines="$(wc -l < "$REPAIR_AUDIT_LOG")"
  [ "$lines" -eq 1 ]
  grep -q '\\"quotes\\"' "$REPAIR_AUDIT_LOG"
  grep -q '\\n' "$REPAIR_AUDIT_LOG"
}

@test "repair_audit_record maps status to the documented exit_code" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_audit_record "rollback-succeeded" "" "" ""
  '
  grep -q '"exit_code":3' "$REPAIR_AUDIT_LOG"
}

# ---------------------------------------------------------------------------
# repair_rollback_and_exit
# ---------------------------------------------------------------------------

@test "repair_rollback_and_exit with no backup exits with the requested code and records verify-failed" {
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_rollback_and_exit 3
  '
  [ "$status" -eq 3 ]
  [[ "$output" == *"No file backup to restore"* ]]
  grep -q '"status":"verify-failed"' "$REPAIR_AUDIT_LOG"
  grep -q '"exit_code":3' "$REPAIR_AUDIT_LOG"
}

@test "repair_rollback_and_exit restores the backup and exits 3 on checksum match" {
  echo "original" > "${BATS_TEST_TMPDIR}/target.conf"
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_backup_with_checksum "'"${BATS_TEST_TMPDIR}"'/target.conf"
    echo "mutated" > "'"${BATS_TEST_TMPDIR}"'/target.conf"
    repair_rollback_and_exit 3
  '
  [ "$status" -eq 3 ]
  [[ "$output" == *"Rollback completed"* ]]
  run cat "${BATS_TEST_TMPDIR}/target.conf"
  [[ "$output" == "original" ]]
  grep -q '"status":"rollback-succeeded"' "$REPAIR_AUDIT_LOG"
}

@test "repair_rollback_and_exit exits 4 CRITICAL when the backup file has vanished" {
  echo "original" > "${BATS_TEST_TMPDIR}/target.conf"
  run bash -c '
    source "'"$LIB"'"
    repair_init s t "scope"
    repair_backup_with_checksum "'"${BATS_TEST_TMPDIR}"'/target.conf"
    rm -f "$REPAIR_BACKUP_FILE"
    repair_rollback_and_exit 3
  '
  [ "$status" -eq 4 ]
  [[ "$output" == *"CRITICAL: Rollback FAILED"* ]]
  grep -q '"status":"rollback-failed"' "$REPAIR_AUDIT_LOG"
}

# ---------------------------------------------------------------------------
# Sourcing guard
# ---------------------------------------------------------------------------

@test "repair-common.sh refuses to run when executed directly instead of sourced" {
  run bash "${LIB}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be sourced"* ]]
}
