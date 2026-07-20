#!/usr/bin/env bats
# Tests for operations/repairs/service/restart-one-specific-service.sh

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/restart-one-specific-service.sh"
  export REPAIR_BACKUP_ROOT="${BATS_TEST_TMPDIR}/backups"
  export REPAIR_AUDIT_LOG="${BATS_TEST_TMPDIR}/audit/repairs.jsonl"
  export REPAIR_ENV_FILE="${BATS_TEST_TMPDIR}/dhanman-env"
  # repair_tripwire_check's default `find /` is far too slow across WSL's
  # mounted Windows drives; scope it to an empty dir for these tests.
  export REPAIR_TRIPWIRE_ROOT="${BATS_TEST_TMPDIR}/tripwire-root"
  mkdir -p "$REPAIR_BACKUP_ROOT" "${BATS_TEST_TMPDIR}/stub" "$REPAIR_TRIPWIRE_ROOT"

  # Stub systemctl so tests never touch the real system.
  cat > "${BATS_TEST_TMPDIR}/stub/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
  show) echo "ActiveState=active" ;;
  is-active) echo "active" ;;
  restart) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${BATS_TEST_TMPDIR}/stub/systemctl"
}

@test "exits 1 with usage message when no unit name given" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits 1 when unit name doesn't match the dhanman-*-qa/prod.service pattern" {
  run bash "$SCRIPT" "not-a-valid-unit"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT: unit name must match pattern"* ]]
}

@test "rejects a unit name with shell metacharacters even though the regex would otherwise pass nearby text" {
  run bash "$SCRIPT" "dhanman-purchase-prod.service; rm -rf /"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT: unit name must match pattern"* ]]
}

@test "aborts when the running host's env doesn't match the unit's env suffix" {
  echo -n "prod" > "$REPAIR_ENV_FILE"
  run bash "$SCRIPT" "dhanman-purchase-qa.service"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT: Expected env=qa but running on prod host"* ]]
}

@test "cancels cleanly (exit 2) when operator declines confirmation on QA" {
  echo -n "qa" > "$REPAIR_ENV_FILE"
  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    echo "no" | bash "'"$SCRIPT"'" "dhanman-purchase-qa.service"
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"Repair cancelled by operator"* ]]
}

@test "restarts the unit and records a succeeded audit entry when confirmed on QA" {
  echo -n "qa" > "$REPAIR_ENV_FILE"
  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    echo "yes" | bash "'"$SCRIPT"'" "dhanman-purchase-qa.service"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ Repair succeeded: dhanman-purchase-qa.service restarted"* ]]
  [ -f "$REPAIR_AUDIT_LOG" ]
  grep -q '"status":"succeeded"' "$REPAIR_AUDIT_LOG"
  grep -q '"target":"dhanman-purchase-qa.service"' "$REPAIR_AUDIT_LOG"
}

@test "requires the exact dated PROD phrase, not a plain yes" {
  echo -n "prod" > "$REPAIR_ENV_FILE"
  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    echo "yes" | bash "'"$SCRIPT"'" "dhanman-purchase-prod.service"
  '
  [ "$status" -eq 2 ]
}

@test "restarts on PROD when the exact dated phrase is given" {
  echo -n "prod" > "$REPAIR_ENV_FILE"
  today="$(date +%Y%m%d)"
  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    echo "PROD REPAIR dhanman-purchase-prod.service '"$today"'" | bash "'"$SCRIPT"'" "dhanman-purchase-prod.service"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ Repair succeeded"* ]]
}

@test "postcheck failure rolls back (no file backup) and exits 3 when unit never becomes active" {
  echo -n "qa" > "$REPAIR_ENV_FILE"
  cat > "${BATS_TEST_TMPDIR}/stub/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
  show) echo "ActiveState=failed" ;;
  is-active) echo "failed" ;;
  restart) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${BATS_TEST_TMPDIR}/stub/systemctl"
  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    echo "yes" | bash "'"$SCRIPT"'" "dhanman-purchase-qa.service"
  '
  [ "$status" -eq 3 ]
  [[ "$output" == *"✗ Postcheck FAILED"* ]]
  grep -q '"status":"verify-failed"' "$REPAIR_AUDIT_LOG"
}
