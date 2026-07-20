#!/usr/bin/env bats
# Tests for operations/repairs/promtail/validate-promtail-config.sh
#
# docker is stubbed out — this is a unit test of the script's control flow
# (missing config, pass-through of docker's exit code, audit recording),
# not an integration test against a real Promtail container. Real container
# behavior is exercised manually per PHASE-8-REPAIR-RUNBOOK.md.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/validate-promtail-config.sh"
  export REPAIR_BACKUP_ROOT="${BATS_TEST_TMPDIR}/backups"
  export REPAIR_AUDIT_LOG="${BATS_TEST_TMPDIR}/audit/repairs.jsonl"
  export PROMTAIL_CONFIG_FILE="${BATS_TEST_TMPDIR}/promtail-config.yml"
  mkdir -p "$REPAIR_BACKUP_ROOT" "${BATS_TEST_TMPDIR}/stub"
}

@test "aborts with exit 1 when the config file doesn't exist" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT: config file not found"* ]]
}

@test "reports success and records an audit entry when docker validation passes" {
  echo "server: {}" > "$PROMTAIL_CONFIG_FILE"
  cat > "${BATS_TEST_TMPDIR}/stub/docker" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "${BATS_TEST_TMPDIR}/stub/docker"

  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    bash "'"$SCRIPT"'"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ Promtail config is valid"* ]]
  grep -q '"status":"succeeded"' "$REPAIR_AUDIT_LOG"
}

@test "propagates failure and records a failed audit entry when docker validation fails" {
  echo "server: {}" > "$PROMTAIL_CONFIG_FILE"
  cat > "${BATS_TEST_TMPDIR}/stub/docker" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "${BATS_TEST_TMPDIR}/stub/docker"

  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    bash "'"$SCRIPT"'"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ Promtail config validation FAILED"* ]]
  grep -q '"status":"failed"' "$REPAIR_AUDIT_LOG"
}
