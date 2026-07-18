#!/usr/bin/env bats
#
# test-loki.bats — unit tests for checks/loki.sh.
# Uses mock curl and docker fixtures under fixtures/bin — no real Loki
# or Docker calls.

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FIXTURES_BIN="${BATS_TEST_DIRNAME}/fixtures/bin"
  PATH="${FIXTURES_BIN}:${PATH}"
  export PATH

  # shellcheck source=../lib/result.sh
  source "${ROOT_DIR}/lib/result.sh"
  # shellcheck source=../checks/loki.sh
  source "${ROOT_DIR}/checks/loki.sh"

  unset MOCK_DOCKER_STATUS MOCK_DOCKER_RESTARTCOUNT
  unset MOCK_LOKI_BODY MOCK_LOKI_READY_BODY MOCK_LOKI_HTTP_CODE
  unset MOCK_CURL_BODY MOCK_CURL_HTTP_CODE MOCK_CURL_FAIL
}

teardown() {
  if [[ -n "${RESULT_FILE:-}" && -f "${RESULT_FILE:-}" ]]; then
    rm -f "$RESULT_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Test 1
# ---------------------------------------------------------------------------
@test "LK-01: container running + /ready 200 yields HEALTHY" {
  result_init "test-lk1" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_LOKI_READY_BODY="ready"
  export MOCK_LOKI_HTTP_CODE="200"

  run lk_check_01_container_ready
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 2
# ---------------------------------------------------------------------------
@test "LK-01: container not running yields CRITICAL" {
  result_init "test-lk2" "qa"
  export MOCK_DOCKER_STATUS="exited"

  run lk_check_01_container_ready
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 3
# ---------------------------------------------------------------------------
@test "LK-01: container running + /ready non-200 yields CRITICAL" {
  result_init "test-lk3" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_LOKI_HTTP_CODE="503"
  export MOCK_LOKI_READY_BODY="not ready"

  run lk_check_01_container_ready
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 4
# ---------------------------------------------------------------------------
@test "LK-02: result array non-empty yields HEALTHY" {
  result_init "test-lk4" "qa"
  export MOCK_LOKI_BODY='{"status":"success","data":{"resultType":"streams","result":[{"stream":{},"values":[["1700000000000000000","log line"]]}]}}'

  run lk_check_02_recent_logs "qa" "dhanman-purchase" "purchase" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 5
# ---------------------------------------------------------------------------
@test "LK-02: result array empty yields WARNING with evidence" {
  result_init "test-lk5" "qa"
  export MOCK_LOKI_BODY='{"status":"success","data":{"resultType":"streams","result":[]}}'

  run lk_check_02_recent_logs "qa" "dhanman-purchase" "purchase" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'WARNING'
assert 'service_name=purchase' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 6
# ---------------------------------------------------------------------------
@test "LK-02: NOT_APPLICABLE when LK-01 CRITICAL" {
  result_init "test-lk6" "qa"

  run lk_check_02_recent_logs "qa" "dhanman-purchase" "purchase" "CRITICAL"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

# ---------------------------------------------------------------------------
# Test 7
# ---------------------------------------------------------------------------
@test "LK-03: recent timestamp (<30min) yields HEALTHY" {
  result_init "test-lk7" "qa"
  local ts_ns
  ts_ns=$(( ($(date +%s) - 300) * 1000000000 ))
  export MOCK_LOKI_BODY
  MOCK_LOKI_BODY="{\"status\":\"success\",\"data\":{\"resultType\":\"streams\",\"result\":[{\"stream\":{},\"values\":[[\"${ts_ns}\",\"log line\"]]}]}}"

  run lk_check_03_latest_timestamp "qa" "dhanman-purchase" "purchase" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 8
# ---------------------------------------------------------------------------
@test "LK-03: timestamp 31-60min ago yields WARNING" {
  result_init "test-lk8" "qa"
  local ts_ns
  ts_ns=$(( ($(date +%s) - (45 * 60)) * 1000000000 ))
  export MOCK_LOKI_BODY
  MOCK_LOKI_BODY="{\"status\":\"success\",\"data\":{\"resultType\":\"streams\",\"result\":[{\"stream\":{},\"values\":[[\"${ts_ns}\",\"log line\"]]}]}}"

  run lk_check_03_latest_timestamp "qa" "dhanman-purchase" "purchase" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

# ---------------------------------------------------------------------------
# Test 9
# ---------------------------------------------------------------------------
@test "LK-03: timestamp >60min ago yields CRITICAL" {
  result_init "test-lk9" "qa"
  local ts_ns
  ts_ns=$(( ($(date +%s) - (90 * 60)) * 1000000000 ))
  export MOCK_LOKI_BODY
  MOCK_LOKI_BODY="{\"status\":\"success\",\"data\":{\"resultType\":\"streams\",\"result\":[{\"stream\":{},\"values\":[[\"${ts_ns}\",\"log line\"]]}]}}"

  run lk_check_03_latest_timestamp "qa" "dhanman-purchase" "purchase" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 10
# ---------------------------------------------------------------------------
@test "LK-03: NOT_APPLICABLE when LK-02 WARNING" {
  result_init "test-lk10" "qa"

  run lk_check_03_latest_timestamp "qa" "dhanman-purchase" "purchase" "WARNING"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

# ---------------------------------------------------------------------------
# Test 11
# ---------------------------------------------------------------------------
@test "LK-04: all services present in label values yields HEALTHY" {
  result_init "test-lk11" "qa"
  export MOCK_LOKI_BODY='{"status":"success","data":["purchase","sales","common"]}'

  run lk_check_04_label_presence "qa" "HEALTHY" "purchase" "sales" "common"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 12
# ---------------------------------------------------------------------------
@test "LK-04: one service missing from labels yields WARNING with name in evidence" {
  result_init "test-lk12" "qa"
  export MOCK_LOKI_BODY='{"status":"success","data":["purchase","common"]}'

  run lk_check_04_label_presence "qa" "HEALTHY" "purchase" "sales" "common"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'WARNING'
assert 'sales' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 13
# ---------------------------------------------------------------------------
@test "LK-05: all counters zero yields HEALTHY" {
  result_init "test-lk13" "qa"
  export MOCK_LOKI_BODY='loki_discarded_samples_total{reason="rate_limited"} 0'

  run lk_check_05_ingestion_errors
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 14
# ---------------------------------------------------------------------------
@test "LK-05: discarded_samples counter > 0 yields WARNING or CRITICAL by count" {
  result_init "test-lk14" "qa"
  export MOCK_LOKI_BODY='loki_discarded_samples_total{reason="rate_limited"} 3'

  run lk_check_05_ingestion_errors
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  result_init "test-lk14b" "qa"
  export MOCK_LOKI_BODY='loki_discarded_samples_total{reason="rate_limited"} 15'

  run lk_check_05_ingestion_errors
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 15
# ---------------------------------------------------------------------------
@test "LK-06: count > 0 yields HEALTHY" {
  result_init "test-lk15" "qa"
  export MOCK_LOKI_BODY='{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1700000000,"42"]}]}}'

  run lk_check_06_volume_sanity "qa" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 16
# ---------------------------------------------------------------------------
@test "LK-06: count = 0 yields WARNING" {
  result_init "test-lk16" "qa"
  export MOCK_LOKI_BODY='{"status":"success","data":{"resultType":"vector","result":[]}}'

  run lk_check_06_volume_sanity "qa" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

# ---------------------------------------------------------------------------
# Test 17
# ---------------------------------------------------------------------------
@test "LK-07: local log fresh + Promtail ok + Loki empty yields promtail-to-loki-delivery" {
  result_init "test-lk17" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_LOKI_READY_BODY="ready"
  export MOCK_LOKI_HTTP_CODE="200"
  export MOCK_LOKI_BODY='{"status":"success","data":{"resultType":"streams","result":[]}}'

  run run_loki_checks "qa" "HEALTHY" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  local layer
  layer="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$layer" = "promtail-to-loki-delivery" ]
}

# ---------------------------------------------------------------------------
# Test 18
# ---------------------------------------------------------------------------
@test "LK-07: PT-04 wrong path + Loki empty yields promtail-misconfiguration" {
  result_init "test-lk18" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_LOKI_READY_BODY="ready"
  export MOCK_LOKI_HTTP_CODE="200"
  export MOCK_LOKI_BODY='{"status":"success","data":{"resultType":"streams","result":[]}}'

  run run_loki_checks "qa" "HEALTHY" "WARNING" "HEALTHY"
  [ "$status" -eq 0 ]
  local layer
  layer="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$layer" = "promtail-misconfiguration" ]
}

# ---------------------------------------------------------------------------
# Test 19
# ---------------------------------------------------------------------------
@test "LK-07: LK-01 CRITICAL yields loki-process" {
  result_init "test-lk19" "qa"
  export MOCK_DOCKER_STATUS="exited"

  run run_loki_checks "qa" "HEALTHY" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  local worst layer
  worst="$(printf '%s\n' "$output" | sed -n '1p')"
  layer="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$worst" = "CRITICAL" ]
  [ "$layer" = "loki-process" ]
}

# ---------------------------------------------------------------------------
# Test 20
# ---------------------------------------------------------------------------
@test "validate_loki_query rejects empty {} selector" {
  run validate_loki_query '{}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"REJECTED"* ]]
}

# ---------------------------------------------------------------------------
# Test 21
# ---------------------------------------------------------------------------
@test "validate_loki_query rejects [2h] time window" {
  run validate_loki_query 'count_over_time({env="qa"}[2h])'
  [ "$status" -eq 1 ]
  [[ "$output" == *"REJECTED"* ]]
}

# ---------------------------------------------------------------------------
# Test 22
# ---------------------------------------------------------------------------
@test "validate_loki_query accepts valid bounded query" {
  run validate_loki_query '{env="qa",service_name="purchase"}'
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 23
# ---------------------------------------------------------------------------
@test "LK-05: response content is redacted before storage" {
  result_init "test-lk23" "qa"
  export MOCK_LOKI_BODY='loki_discarded_samples_total{reason="rate_limited",tenant="secret=hunter2"} 3'

  run lk_check_05_ingestion_errors
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'hunter2' not in json.dumps(obj)
assert '[REDACTED' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
