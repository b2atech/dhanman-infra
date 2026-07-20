#!/usr/bin/env bats
#
# test-promtail.bats — unit tests for checks/promtail.sh.
# Uses a mock docker fixture under fixtures/bin — no real docker calls.

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FIXTURES_BIN="${BATS_TEST_DIRNAME}/fixtures/bin"
  PATH="${FIXTURES_BIN}:${PATH}"
  export PATH

  # shellcheck source=../lib/result.sh
  source "${ROOT_DIR}/lib/result.sh"
  # shellcheck source=../checks/promtail.sh
  source "${ROOT_DIR}/checks/promtail.sh"

  TEST_TMP="$(mktemp -d)"

  unset MOCK_DOCKER_STATUS MOCK_DOCKER_RESTARTCOUNT MOCK_DOCKER_STARTEDAT
  unset MOCK_DOCKER_READY MOCK_DOCKER_POSITIONS_MTIME MOCK_DOCKER_LOGS
}

teardown() {
  if [[ -n "${RESULT_FILE:-}" && -f "${RESULT_FILE:-}" ]]; then
    rm -f "$RESULT_FILE"
  fi
  if [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP:-}" ]]; then
    rm -rf "$TEST_TMP"
  fi
}

# ---------------------------------------------------------------------------
# Test 1
# ---------------------------------------------------------------------------
@test "PT-01: running with low restarts yields HEALTHY" {
  result_init "test-p1" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_DOCKER_RESTARTCOUNT="1"

  run pt_check_01_container_state
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 2
# ---------------------------------------------------------------------------
@test "PT-01: running with RestartCount >= 5 yields WARNING" {
  result_init "test-p2" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_DOCKER_RESTARTCOUNT="5"

  run pt_check_01_container_state
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

# ---------------------------------------------------------------------------
# Test 3
# ---------------------------------------------------------------------------
@test "PT-01: container not running yields CRITICAL" {
  result_init "test-p3" "qa"
  export MOCK_DOCKER_STATUS="exited"

  run pt_check_01_container_state
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 4
# ---------------------------------------------------------------------------
@test "PT-02: ready response yields HEALTHY" {
  result_init "test-p4" "qa"
  export MOCK_DOCKER_READY="Ready"

  run pt_check_02_readiness "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 5
# ---------------------------------------------------------------------------
@test "PT-02: not ready yields CRITICAL" {
  result_init "test-p5" "qa"
  export MOCK_DOCKER_READY=""

  run pt_check_02_readiness "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 6
# ---------------------------------------------------------------------------
@test "PT-02: NOT_APPLICABLE when PT-01 CRITICAL" {
  result_init "test-p6" "qa"

  run pt_check_02_readiness "CRITICAL"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

# ---------------------------------------------------------------------------
# Test 7
# ---------------------------------------------------------------------------
@test "PT-03: config file exists yields HEALTHY" {
  result_init "test-p7" "qa"
  local f="${TEST_TMP}/promtail-config.yml"
  echo "server: {}" > "$f"

  run pt_check_03_config_exists "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 8
# ---------------------------------------------------------------------------
@test "PT-03: config file missing yields CRITICAL" {
  result_init "test-p8" "qa"
  local f="${TEST_TMP}/does-not-exist.yml"

  run pt_check_03_config_exists "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 9
# ---------------------------------------------------------------------------
@test "PT-04: glob matches real files yields HEALTHY" {
  result_init "test-p9" "qa"
  local logdir="${TEST_TMP}/logs9"
  mkdir -p "$logdir"
  touch "${logdir}/dhanman-common-20260718.log"

  local cfg="${TEST_TMP}/promtail-config9.yml"
  cat > "$cfg" <<EOF
scrape_configs:
  - job_name: dhanman-logs
    static_configs:
      - targets: [localhost]
        labels:
          __path__: "${logdir}/dhanman-*.log"
EOF

  run pt_check_04_path_cross_check "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 10
# ---------------------------------------------------------------------------
@test "PT-04: glob matches no files yields WARNING with glob in evidence" {
  result_init "test-p10" "qa"
  local logdir="${TEST_TMP}/logs10-empty"
  mkdir -p "$logdir"

  local cfg="${TEST_TMP}/promtail-config10.yml"
  cat > "$cfg" <<EOF
scrape_configs:
  - job_name: dhanman-logs
    static_configs:
      - targets: [localhost]
        labels:
          __path__: "${logdir}/dhanman-*.log"
EOF

  run pt_check_04_path_cross_check "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'WARNING'
assert '${logdir}/dhanman-*.log' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 11
# ---------------------------------------------------------------------------
@test "PT-05: positions file fresh yields HEALTHY" {
  result_init "test-p11" "qa"
  export MOCK_DOCKER_POSITIONS_MTIME
  MOCK_DOCKER_POSITIONS_MTIME="$(date +%s)"

  run pt_check_05_positions "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 12
# ---------------------------------------------------------------------------
@test "PT-05: positions file missing yields CRITICAL with ephemeral-positions warning" {
  result_init "test-p12" "qa"
  unset MOCK_DOCKER_POSITIONS_MTIME

  run pt_check_05_positions "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'CRITICAL'
assert 'container was restarted' in obj['evidence']
assert 'duplicate entries' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 13
# ---------------------------------------------------------------------------
@test "PT-05: NOT_APPLICABLE when PT-01 CRITICAL" {
  result_init "test-p13" "qa"

  run pt_check_05_positions "CRITICAL"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

# ---------------------------------------------------------------------------
# Test 14
# ---------------------------------------------------------------------------
@test "PT-06: no errors in logs yields HEALTHY" {
  result_init "test-p14" "qa"
  export MOCK_DOCKER_LOGS="level=info msg=\"batch sent successfully\""

  run pt_check_06_push_errors
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 15
# ---------------------------------------------------------------------------
@test "PT-06: push errors found yield WARNING or CRITICAL by count" {
  result_init "test-p15" "qa"
  export MOCK_DOCKER_LOGS=$'error sending batch\nerror sending batch\nconnection refused'

  run pt_check_06_push_errors
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  result_init "test-p15b" "qa"
  local many
  many="$(for _ in $(seq 1 6); do printf 'error sending batch\n'; done)"
  export MOCK_DOCKER_LOGS="$many"

  run pt_check_06_push_errors
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 16
# ---------------------------------------------------------------------------
@test "PT-06: log content is redacted before storage" {
  result_init "test-p16" "qa"
  export MOCK_DOCKER_LOGS=$'connecting with password=hunter2\nconnection refused'

  run pt_check_06_push_errors
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'password=hunter2' not in obj['evidence']
assert 'hunter2' not in json.dumps(obj)
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 17
# ---------------------------------------------------------------------------
@test "PT-07: layer verdict wrong path detected yields promtail-misconfiguration" {
  result_init "test-p17" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_DOCKER_RESTARTCOUNT="0"
  export MOCK_DOCKER_READY="Ready"
  export MOCK_DOCKER_POSITIONS_MTIME
  MOCK_DOCKER_POSITIONS_MTIME="$(date +%s)"
  export MOCK_DOCKER_LOGS=""

  local logdir="${TEST_TMP}/logs17-empty"
  mkdir -p "$logdir"
  local cfg="${TEST_TMP}/promtail-config17.yml"
  cat > "$cfg" <<EOF
scrape_configs:
  - static_configs:
      - labels:
          __path__: "${logdir}/dhanman-*.log"
EOF

  run run_pt_checks "qa" "$logdir" "HEALTHY" "$cfg"
  [ "$status" -eq 0 ]
  local layer
  layer="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$layer" = "promtail-misconfiguration" ]
}

# ---------------------------------------------------------------------------
# Test 18
# ---------------------------------------------------------------------------
@test "PT-07: layer verdict push errors yields promtail-to-loki-delivery" {
  result_init "test-p18" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_DOCKER_RESTARTCOUNT="0"
  export MOCK_DOCKER_READY="Ready"
  export MOCK_DOCKER_POSITIONS_MTIME
  MOCK_DOCKER_POSITIONS_MTIME="$(date +%s)"
  export MOCK_DOCKER_LOGS="error sending batch"

  local logdir="${TEST_TMP}/logs18"
  mkdir -p "$logdir"
  touch "${logdir}/dhanman-common-20260718.log"
  local cfg="${TEST_TMP}/promtail-config18.yml"
  cat > "$cfg" <<EOF
scrape_configs:
  - static_configs:
      - labels:
          __path__: "${logdir}/dhanman-*.log"
EOF

  run run_pt_checks "qa" "$logdir" "HEALTHY" "$cfg"
  [ "$status" -eq 0 ]
  local layer
  layer="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$layer" = "promtail-to-loki-delivery" ]
}

# ---------------------------------------------------------------------------
# Test 19
# ---------------------------------------------------------------------------
@test "PT-07: layer verdict container down yields promtail-process" {
  result_init "test-p19" "qa"
  export MOCK_DOCKER_STATUS="exited"
  export MOCK_DOCKER_LOGS=""

  local logdir="${TEST_TMP}/logs19"
  mkdir -p "$logdir"
  touch "${logdir}/dhanman-common-20260718.log"
  local cfg="${TEST_TMP}/promtail-config19.yml"
  cat > "$cfg" <<EOF
scrape_configs:
  - static_configs:
      - labels:
          __path__: "${logdir}/dhanman-*.log"
EOF

  run run_pt_checks "qa" "$logdir" "HEALTHY" "$cfg"
  [ "$status" -eq 0 ]
  local worst layer
  worst="$(printf '%s\n' "$output" | sed -n '1p')"
  layer="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$worst" = "CRITICAL" ]
  [ "$layer" = "promtail-process" ]
}

# ---------------------------------------------------------------------------
# Test 20
# ---------------------------------------------------------------------------
@test "repair mapping: PT-01 CRITICAL includes restart-promtail.sh" {
  result_init "test-p20" "qa"
  export MOCK_DOCKER_STATUS="dead"

  run pt_check_01_container_state
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'restart-promtail.sh' in obj['recommended_repair']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 21
# ---------------------------------------------------------------------------
@test "repair mapping: PT-04 WARNING includes restore-approved-promtail-config.sh" {
  result_init "test-p21" "qa"
  local logdir="${TEST_TMP}/logs21-empty"
  mkdir -p "$logdir"
  local cfg="${TEST_TMP}/promtail-config21.yml"
  cat > "$cfg" <<EOF
scrape_configs:
  - static_configs:
      - labels:
          __path__: "${logdir}/dhanman-*.log"
EOF

  run pt_check_04_path_cross_check "$cfg"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'restore-approved-promtail-config.sh' in obj['recommended_repair']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
