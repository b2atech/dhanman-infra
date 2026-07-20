#!/usr/bin/env bats
# Tests for operations/repairs/prometheus/validate-prometheus-config.sh
#
# docker is stubbed out — this is a unit test of the script's control flow,
# not an integration test against real promtool. Real behavior is exercised
# manually per PHASE-8-REPAIR-RUNBOOK.md.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/validate-prometheus-config.sh"
  export REPAIR_BACKUP_ROOT="${BATS_TEST_TMPDIR}/backups"
  export REPAIR_AUDIT_LOG="${BATS_TEST_TMPDIR}/audit/repairs.jsonl"
  export PROMETHEUS_CONFIG_FILE="${BATS_TEST_TMPDIR}/prometheus.yml"
  export PROMETHEUS_RULES_DIR="${BATS_TEST_TMPDIR}/rules"
  mkdir -p "$REPAIR_BACKUP_ROOT" "${BATS_TEST_TMPDIR}/stub" "$PROMETHEUS_RULES_DIR"
}

@test "aborts with exit 1 when the config file doesn't exist" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT: config file not found"* ]]
}

@test "reports success and records an audit entry when promtool validation passes" {
  echo "global: {}" > "$PROMETHEUS_CONFIG_FILE"
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
  [[ "$output" == *"✓ Prometheus config is valid"* ]]
  grep -q '"status":"succeeded"' "$REPAIR_AUDIT_LOG"
}

@test "propagates failure and records a failed audit entry when promtool validation fails" {
  echo "global: {}" > "$PROMETHEUS_CONFIG_FILE"
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
  [[ "$output" == *"✗ Prometheus config validation FAILED"* ]]
  grep -q '"status":"failed"' "$REPAIR_AUDIT_LOG"
}

@test "invokes docker with --entrypoint promtool rather than relying on the image default" {
  echo "global: {}" > "$PROMETHEUS_CONFIG_FILE"
  cat > "${BATS_TEST_TMPDIR}/stub/docker" <<'EOF'
#!/bin/bash
echo "ARGS: $*" >&2
exit 0
EOF
  chmod +x "${BATS_TEST_TMPDIR}/stub/docker"

  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    bash "'"$SCRIPT"'"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"--entrypoint promtool"* ]]
}
