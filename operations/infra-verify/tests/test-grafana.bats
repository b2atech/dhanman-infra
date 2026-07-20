#!/usr/bin/env bats
#
# test-grafana.bats — unit tests for checks/grafana.sh.
# Uses mock curl fixture under fixtures/bin — no real Grafana calls.

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FIXTURES_BIN="${BATS_TEST_DIRNAME}/fixtures/bin"
  PATH="${FIXTURES_BIN}:${PATH}"
  export PATH

  # shellcheck source=../lib/result.sh
  source "${ROOT_DIR}/lib/result.sh"
  # shellcheck source=../checks/grafana.sh
  source "${ROOT_DIR}/checks/grafana.sh"

  unset MOCK_GRAFANA_HEALTH_BODY MOCK_GRAFANA_HEALTH_HTTP_CODE
  unset MOCK_GRAFANA_DATASOURCES_BODY MOCK_GRAFANA_DATASOURCES_HTTP_CODE
  unset MOCK_GRAFANA_QUERY_PROM_BODY MOCK_GRAFANA_QUERY_PROM_HTTP_CODE
  unset MOCK_GRAFANA_QUERY_LOKI_BODY MOCK_GRAFANA_QUERY_LOKI_HTTP_CODE
  unset MOCK_CURL_BODY MOCK_CURL_HTTP_CODE MOCK_CURL_FAIL
  unset GRAFANA_VERIFY_TOKEN_QA GRAFANA_VERIFY_TOKEN_PROD
}

teardown() {
  if [[ -n "${RESULT_FILE:-}" && -f "${RESULT_FILE:-}" ]]; then
    rm -f "$RESULT_FILE"
  fi
}

# ===========================================================================
# GF-01
# ===========================================================================

@test "GF-01: /api/health 200 yields HEALTHY" {
  result_init "test-gf1" "qa"
  export MOCK_GRAFANA_HEALTH_BODY='{"status":"ok","database":{"state":"ok"}}'
  export MOCK_GRAFANA_HEALTH_HTTP_CODE="200"

  run gf_check_01_reachability "qa"
  [ "$status" -eq 0 ]
  local gf01_status
  gf01_status="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$gf01_status" = "HEALTHY" ]
}

@test "GF-01: connection refused yields CRITICAL" {
  result_init "test-gf2" "qa"
  export MOCK_CURL_FAIL="1"

  run gf_check_01_reachability "qa"
  [ "$status" -eq 0 ]
  local gf01_status
  gf01_status="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$gf01_status" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['likely_layer'] == 'grafana-process'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "GF-01: timeout (empty http_code) yields CRITICAL" {
  result_init "test-gf3" "qa"
  export MOCK_GRAFANA_HEALTH_HTTP_CODE="000"

  run gf_check_01_reachability "qa"
  [ "$status" -eq 0 ]
  local gf01_status
  gf01_status="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$gf01_status" = "CRITICAL" ]
}

# ===========================================================================
# GF-02
# ===========================================================================

@test "GF-02: database ok yields HEALTHY" {
  result_init "test-gf4" "qa"

  run gf_check_02_database_state "qa" "HEALTHY" '{"status":"ok","database":{"state":"ok"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "GF-02: database error yields CRITICAL" {
  result_init "test-gf5" "qa"

  run gf_check_02_database_state "qa" "HEALTHY" '{"status":"ok","database":{"state":"error"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

@test "GF-02: NOT_APPLICABLE when GF-01 CRITICAL" {
  result_init "test-gf6" "qa"

  run gf_check_02_database_state "qa" "CRITICAL" ""
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

# ===========================================================================
# GF-03
# ===========================================================================

@test "GF-03: token not set yields NOT_CONFIGURED with message" {
  result_init "test-gf7" "qa"

  run gf_check_03_datasource_existence "qa" ""
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_CONFIGURED" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'GRAFANA_VERIFY_TOKEN_QA' in obj['evidence']
assert 'grafana_verify_token_qa' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "GF-03: token set, both datasources present editable:false yields HEALTHY" {
  result_init "test-gf8" "qa"
  export MOCK_GRAFANA_DATASOURCES_BODY='[{"uid":"prometheus","editable":false},{"uid":"loki","editable":false}]'
  export MOCK_GRAFANA_DATASOURCES_HTTP_CODE="200"

  run gf_check_03_datasource_existence "qa" "fake-token-value"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "GF-03: token invalid (401) yields UNKNOWN with auth message" {
  result_init "test-gf9" "qa"
  export MOCK_GRAFANA_DATASOURCES_HTTP_CODE="401"

  run gf_check_03_datasource_existence "qa" "bad-token"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'invalid or expired' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "GF-03: prometheus datasource missing yields CRITICAL" {
  result_init "test-gf10" "qa"
  export MOCK_GRAFANA_DATASOURCES_BODY='[{"uid":"loki","editable":false}]'
  export MOCK_GRAFANA_DATASOURCES_HTTP_CODE="200"

  run gf_check_03_datasource_existence "qa" "fake-token-value"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'prometheus' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "GF-03: loki editable:true yields WARNING" {
  result_init "test-gf11" "qa"
  export MOCK_GRAFANA_DATASOURCES_BODY='[{"uid":"prometheus","editable":false},{"uid":"loki","editable":true}]'
  export MOCK_GRAFANA_DATASOURCES_HTTP_CODE="200"

  run gf_check_03_datasource_existence "qa" "fake-token-value"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

# ===========================================================================
# GF-04
# ===========================================================================

@test "GF-04: token not set yields NOT_CONFIGURED" {
  result_init "test-gf12" "qa"

  run gf_check_04_prometheus_query_through "qa" ""
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_CONFIGURED" ]
}

@test "GF-04: token set, query succeeds yields HEALTHY with time recorded" {
  result_init "test-gf13" "qa"
  export MOCK_GRAFANA_QUERY_PROM_BODY='{"results":{"A":{"frames":[]}}}'
  export MOCK_GRAFANA_QUERY_PROM_HTTP_CODE="200"
  export MOCK_CURL_TIME_TOTAL="0.045"

  run gf_check_04_prometheus_query_through "qa" "fake-token-value"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert '0.045' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "GF-04: token invalid yields UNKNOWN" {
  result_init "test-gf14" "qa"
  export MOCK_GRAFANA_QUERY_PROM_HTTP_CODE="401"

  run gf_check_04_prometheus_query_through "qa" "bad-token"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

@test "GF-04: query error response yields CRITICAL" {
  result_init "test-gf15" "qa"
  export MOCK_GRAFANA_QUERY_PROM_BODY='{"results":{"A":{"error":"datasource unreachable"}}}'
  export MOCK_GRAFANA_QUERY_PROM_HTTP_CODE="200"

  run gf_check_04_prometheus_query_through "qa" "fake-token-value"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ===========================================================================
# GF-05
# ===========================================================================

@test "GF-05: Loki query with token yields HEALTHY" {
  result_init "test-gf16" "qa"
  export MOCK_GRAFANA_QUERY_LOKI_BODY='{"results":{"A":{"frames":[{"data":{"values":[["ts"],["line"]]}}]}}}'
  export MOCK_GRAFANA_QUERY_LOKI_HTTP_CODE="200"

  run gf_check_05_loki_query_through "qa" "fake-token-value"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "GF-05: Loki query empty result still yields HEALTHY" {
  result_init "test-gf17" "qa"
  export MOCK_GRAFANA_QUERY_LOKI_BODY='{"results":{"A":{"frames":[]}}}'
  export MOCK_GRAFANA_QUERY_LOKI_HTTP_CODE="200"

  run gf_check_05_loki_query_through "qa" "fake-token-value"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "GF-05: Loki query error yields CRITICAL" {
  result_init "test-gf18" "qa"
  export MOCK_GRAFANA_QUERY_LOKI_BODY='{"results":{"A":{"error":"loki unreachable"}}}'
  export MOCK_GRAFANA_QUERY_LOKI_HTTP_CODE="200"

  run gf_check_05_loki_query_through "qa" "fake-token-value"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ===========================================================================
# GF-06
# ===========================================================================

@test "GF-06: process down yields layer grafana-process" {
  result_init "test-gf19" "qa"

  run gf_check_06_verdict "qa" "CRITICAL" "NOT_APPLICABLE" "NOT_CONFIGURED" "NOT_CONFIGURED" "NOT_CONFIGURED"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['likely_layer'] == 'grafana-process'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "GF-06: datasource missing yields layer grafana-configuration" {
  result_init "test-gf20" "qa"

  run gf_check_06_verdict "qa" "HEALTHY" "HEALTHY" "CRITICAL" "NOT_CONFIGURED" "NOT_CONFIGURED"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['likely_layer'] == 'grafana-configuration'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "GF-06: query fails yields layer grafana-datasource" {
  result_init "test-gf21" "qa"

  run gf_check_06_verdict "qa" "HEALTHY" "HEALTHY" "HEALTHY" "CRITICAL" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['likely_layer'] == 'grafana-datasource'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "GF-06: all passing yields HEALTHY" {
  result_init "test-gf22" "qa"

  run gf_check_06_verdict "qa" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ===========================================================================
# GF-07
# ===========================================================================

@test "GF-07: logs chain all green yields VISIBLE" {
  result_init "test-gf23" "qa"

  run gf_check_07_e2e_matrix "dhanman-purchase" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  local logs_chain
  logs_chain="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$logs_chain" = "VISIBLE" ]
}

@test "GF-07: logs chain broken at Loki yields BROKEN with promtail-to-loki in evidence" {
  result_init "test-gf24" "qa"

  run gf_check_07_e2e_matrix "dhanman-purchase" "HEALTHY" "HEALTHY" "WARNING" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  local logs_chain
  logs_chain="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$logs_chain" = "BROKEN" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'promtail-to-loki' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "GF-07: metrics chain all green yields VISIBLE" {
  result_init "test-gf25" "qa"

  run gf_check_07_e2e_matrix "dhanman-purchase" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  local metrics_chain
  metrics_chain="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$metrics_chain" = "VISIBLE" ]
}

@test "GF-07: metrics chain broken at Prometheus yields BROKEN with prometheus in evidence" {
  result_init "test-gf26" "qa"

  run gf_check_07_e2e_matrix "dhanman-purchase" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY" "HEALTHY" "CRITICAL" "HEALTHY"
  [ "$status" -eq 0 ]
  local metrics_chain
  metrics_chain="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$metrics_chain" = "BROKEN" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'prometheus' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ===========================================================================
# Security / regression
# ===========================================================================

@test "token value never appears in stored evidence" {
  result_init "test-gf27" "qa"
  local secret_token="SUPER-SECRET-TOKEN-VALUE-12345"
  export MOCK_GRAFANA_DATASOURCES_BODY='[{"uid":"prometheus","editable":false},{"uid":"loki","editable":false}]'
  export MOCK_GRAFANA_DATASOURCES_HTTP_CODE="200"
  export MOCK_GRAFANA_QUERY_PROM_BODY='{"results":{"A":{"frames":[]}}}'
  export MOCK_GRAFANA_QUERY_PROM_HTTP_CODE="200"
  export MOCK_GRAFANA_QUERY_LOKI_BODY='{"results":{"A":{"frames":[]}}}'
  export MOCK_GRAFANA_QUERY_LOKI_HTTP_CODE="200"
  export MOCK_GRAFANA_HEALTH_BODY='{"status":"ok","database":{"state":"ok"}}'
  export MOCK_GRAFANA_HEALTH_HTTP_CODE="200"

  gf_check_01_reachability "qa" >/dev/null
  gf_check_03_datasource_existence "qa" "$secret_token" >/dev/null
  gf_check_04_prometheus_query_through "qa" "$secret_token" >/dev/null
  gf_check_05_loki_query_through "qa" "$secret_token" >/dev/null

  run grep -c "$secret_token" "$RESULT_FILE"
  [ "$status" -ne 0 ]
}

@test "response time is stored but full query result body is not" {
  result_init "test-gf28" "qa"
  export MOCK_GRAFANA_QUERY_PROM_BODY='{"results":{"A":{"frames":[{"schema":{"fields":[]},"data":{"values":[[1,2,3]]}}]}}}'
  export MOCK_GRAFANA_QUERY_PROM_HTTP_CODE="200"
  export MOCK_CURL_TIME_TOTAL="0.077"

  run gf_check_04_prometheus_query_through "qa" "fake-token-value"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert '0.077' in obj['evidence']
assert 'frames' not in obj['evidence']
assert 'values' not in obj['evidence']
assert '\"data\"' not in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
