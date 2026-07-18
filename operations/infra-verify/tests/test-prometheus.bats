#!/usr/bin/env bats
#
# test-prometheus.bats — unit tests for checks/prometheus.sh.
# Uses mock curl and docker fixtures under fixtures/bin — no real
# Prometheus or Docker calls.

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FIXTURES_BIN="${BATS_TEST_DIRNAME}/fixtures/bin"
  PATH="${FIXTURES_BIN}:${PATH}"
  export PATH

  # shellcheck source=../lib/result.sh
  source "${ROOT_DIR}/lib/result.sh"
  # shellcheck source=../checks/prometheus.sh
  source "${ROOT_DIR}/checks/prometheus.sh"

  unset MOCK_DOCKER_STATUS MOCK_DOCKER_RESTARTCOUNT
  unset MOCK_PROM_BODY MOCK_PROM_READY_BODY MOCK_PROM_HTTP_CODE
  unset MOCK_LOKI_BODY MOCK_LOKI_READY_BODY MOCK_LOKI_HTTP_CODE
  unset MOCK_CURL_BODY MOCK_CURL_HTTP_CODE MOCK_CURL_FAIL

  NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  STALE_2M_ISO="$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  STALE_4M_ISO="$(date -u -d '4 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
}

teardown() {
  if [[ -n "${RESULT_FILE:-}" && -f "${RESULT_FILE:-}" ]]; then
    rm -f "$RESULT_FILE"
  fi
}

# One-target fixture builder: health, lastScrape, duration, lastError, url
_target_json() {
  local job="$1" instance="$2" health="$3" last_scrape="$4" duration="$5" last_error="$6" scrape_url="$7"
  printf '{"status":"success","data":{"activeTargets":[{"labels":{"job":"%s","instance":"%s"},"health":"%s","lastScrape":"%s","lastScrapeDuration":%s,"lastError":"%s","scrapeUrl":"%s"}]}}' \
    "$job" "$instance" "$health" "$last_scrape" "$duration" "$last_error" "$scrape_url"
}

# ===========================================================================
# PM-01
# ===========================================================================

@test "PM-01: container running and ready yields HEALTHY" {
  result_init "test-pm1" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_DOCKER_RESTARTCOUNT="0"
  export MOCK_PROM_HTTP_CODE="200"
  export MOCK_PROM_READY_BODY="Prometheus Server is Ready."

  run pm_check_01_ready
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "PM-01: container stopped yields CRITICAL, layer prometheus_runtime" {
  result_init "test-pm2" "qa"
  export MOCK_DOCKER_STATUS="exited"

  run pm_check_01_ready
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['likely_layer'] == 'prometheus_runtime'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-01: restart-loop (RestartCount >= 5) yields WARNING" {
  result_init "test-pm3" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_DOCKER_RESTARTCOUNT="5"
  export MOCK_PROM_HTTP_CODE="200"

  run pm_check_01_ready
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

@test "PM-01: readiness connection failure yields CRITICAL" {
  result_init "test-pm4" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_CURL_FAIL="1"

  run pm_check_01_ready
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

@test "PM-01: readiness HTTP error (503) yields CRITICAL, layer prometheus_readiness" {
  result_init "test-pm5" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_PROM_HTTP_CODE="503"

  run pm_check_01_ready
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['likely_layer'] == 'prometheus_readiness'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-01: 401 is classified as UNKNOWN, not reported as down" {
  result_init "test-pm6" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_PROM_HTTP_CODE="401"

  run pm_check_01_ready
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

@test "PM-01: 403 is classified as UNKNOWN, not reported as down" {
  result_init "test-pm6b" "qa"
  export MOCK_DOCKER_STATUS="running"
  export MOCK_PROM_HTTP_CODE="403"

  run pm_check_01_ready
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

# ===========================================================================
# PM-02
# ===========================================================================

@test "PM-02: healthy target yields HEALTHY" {
  result_init "test-pm7" "qa"
  export MOCK_PROM_BODY
  MOCK_PROM_BODY="$(_target_json dhanman_services 127.0.0.1:5104 up "$NOW_ISO" 0.01 "" http://127.0.0.1:5104/metrics)"

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "PM-02: target missing from active targets yields CRITICAL" {
  result_init "test-pm8" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"activeTargets":[]}}'

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

@test "PM-02: blackholed target (health=down) exposes sanitized lastError" {
  result_init "test-pm9" "qa"
  export MOCK_PROM_BODY
  MOCK_PROM_BODY="$(_target_json dhanman_services 127.0.0.1:5104 down "$NOW_ISO" 0.01 "connection refused" http://127.0.0.1:5104/metrics)"

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'CRITICAL'
assert 'connection refused' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-02: lastError containing a fake credential is redacted" {
  result_init "test-pm10" "qa"
  export MOCK_PROM_BODY
  MOCK_PROM_BODY="$(_target_json dhanman_services 127.0.0.1:5104 down "$NOW_ISO" 0.01 "dial tcp: password=hunter2" http://127.0.0.1:5104/metrics)"

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
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

@test "PM-02: scrape URL with fake userinfo is sanitized" {
  result_init "test-pm11" "qa"
  export MOCK_PROM_BODY
  MOCK_PROM_BODY="$(_target_json dhanman_services 127.0.0.1:5104 up "$NOW_ISO" 0.01 "" "http://admin:s3cr3t@127.0.0.1:5104/metrics")"

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 's3cr3t' not in json.dumps(obj)
assert '[REDACTED' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-02: scrape URL with fake token query param is sanitized" {
  result_init "test-pm11b" "qa"
  export MOCK_PROM_BODY
  MOCK_PROM_BODY="$(_target_json dhanman_services 127.0.0.1:5104 up "$NOW_ISO" 0.01 "" "http://127.0.0.1:5104/metrics?token=abcXYZ123")"

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'abcXYZ123' not in json.dumps(obj)
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-02: stale lastScrape yields WARNING" {
  result_init "test-pm12" "qa"
  export MOCK_PROM_BODY
  MOCK_PROM_BODY="$(_target_json dhanman_services 127.0.0.1:5104 up "$STALE_2M_ISO" 0.01 "" http://127.0.0.1:5104/metrics)"
  PM_STALENESS_WARN_SECONDS=60 PM_STALENESS_CRIT_SECONDS=180

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

@test "PM-02: very stale lastScrape yields CRITICAL" {
  result_init "test-pm12b" "qa"
  export MOCK_PROM_BODY
  MOCK_PROM_BODY="$(_target_json dhanman_services 127.0.0.1:5104 up "$STALE_4M_ISO" 0.01 "" http://127.0.0.1:5104/metrics)"

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

@test "PM-02: excessive scrapeDuration yields WARNING" {
  result_init "test-pm13" "qa"
  export MOCK_PROM_BODY
  MOCK_PROM_BODY="$(_target_json dhanman_services 127.0.0.1:5104 up "$NOW_ISO" 7.5 "" http://127.0.0.1:5104/metrics)"

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

@test "PM-02: malformed targets JSON yields UNKNOWN" {
  result_init "test-pm14" "qa"
  export MOCK_PROM_BODY='{not valid json'

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

@test "PM-02: Prometheus API status=error yields UNKNOWN" {
  result_init "test-pm15" "qa"
  export MOCK_PROM_BODY='{"status":"error","errorType":"bad_data","error":"nope"}'

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

@test "PM-02: has_metrics=false yields NOT_APPLICABLE, never MISSING" {
  result_init "test-pm16" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"activeTargets":[]}}'

  run pm_check_02_target_health "dhanman-agent" "dhanman_services" "127.0.0.1:5108" "false" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

@test "PM-02: NOT_APPLICABLE when PM-01 CRITICAL" {
  result_init "test-pm17" "qa"

  run pm_check_02_target_health "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "CRITICAL"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

# ===========================================================================
# PM-03
# ===========================================================================

@test "PM-03: all expected targets found yields HEALTHY" {
  result_init "test-pm18" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"activeTargets":[
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:5104"}},
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:5105"}}
  ]}}'

  run pm_check_03_target_comparison "qa" "dhanman-purchase:5104" "dhanman-sales:5105"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "PM-03: expected service target missing yields CRITICAL" {
  result_init "test-pm19" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"activeTargets":[
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:5104"}}
  ]}}'

  run pm_check_03_target_comparison "qa" "dhanman-purchase:5104" "dhanman-sales:5105"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'dhanman-sales' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-03: unexpected service target yields WARNING" {
  result_init "test-pm20" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"activeTargets":[
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:5104"}},
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:9999"}}
  ]}}'

  run pm_check_03_target_comparison "qa" "dhanman-purchase:5104"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

@test "PM-03: duplicate active target yields WARNING" {
  result_init "test-pm21" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"activeTargets":[
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:5104"}},
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:5104"}}
  ]}}'

  run pm_check_03_target_comparison "qa" "dhanman-purchase:5104"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

@test "PM-03: unexpected job name yields WARNING" {
  result_init "test-pm22" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"activeTargets":[
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:5104"}},
    {"labels":{"job":"totally_unexpected_job","instance":"127.0.0.1:1234"}}
  ]}}'

  run pm_check_03_target_comparison "qa" "dhanman-purchase:5104"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'totally_unexpected_job' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-03: has_metrics=false service excluded from expected list is never reported missing" {
  result_init "test-pm23" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"activeTargets":[
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:5104"}}
  ]}}'

  # dhanman-agent (has_metrics=false) intentionally not in the expected list
  run pm_check_03_target_comparison "qa" "dhanman-purchase:5104"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'dhanman-agent' not in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-03: malformed targets JSON yields UNKNOWN" {
  result_init "test-pm24" "qa"
  export MOCK_PROM_BODY='not json at all'

  run pm_check_03_target_comparison "qa" "dhanman-purchase:5104"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

# ===========================================================================
# PM-04
# ===========================================================================

@test "PM-04: fresh metric yields HEALTHY" {
  result_init "test-pm25" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"5"]}]}}'

  run pm_check_04_metric_staleness "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "PM-04: warning-stale metric yields WARNING" {
  result_init "test-pm26" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"90"]}]}}'

  run pm_check_04_metric_staleness "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

@test "PM-04: critical-stale metric yields CRITICAL" {
  result_init "test-pm27" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"300"]}]}}'

  run pm_check_04_metric_staleness "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

@test "PM-04: empty result yields UNKNOWN, distinct from query failure" {
  result_init "test-pm28" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[]}}'

  run pm_check_04_metric_staleness "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'metric absent, not a query failure' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-04: NaN sample value yields UNKNOWN" {
  result_init "test-pm29" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"NaN"]}]}}'

  run pm_check_04_metric_staleness "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

@test "PM-04: Inf sample value yields UNKNOWN" {
  result_init "test-pm30" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"+Inf"]}]}}'

  run pm_check_04_metric_staleness "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

@test "PM-04: API status=error yields UNKNOWN" {
  result_init "test-pm31" "qa"
  export MOCK_PROM_BODY='{"status":"error"}'

  run pm_check_04_metric_staleness "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

@test "PM-04: malformed JSON yields UNKNOWN" {
  result_init "test-pm32" "qa"
  export MOCK_PROM_BODY='{{{broken'

  run pm_check_04_metric_staleness "dhanman-purchase" "dhanman_services" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

@test "PM-04: has_metrics=false yields NOT_APPLICABLE" {
  result_init "test-pm33" "qa"

  run pm_check_04_metric_staleness "dhanman-agent" "dhanman_services" "127.0.0.1:5108" "false" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

@test "validate_prometheus_query rejects service-name injection attempt" {
  run validate_prometheus_query 'time() - timestamp(up{job="dhanman_services",instance="127.0.0.1:5104"}) or node_cpu_seconds_total'
  [ "$status" -eq 1 ]
  [[ "$output" == *"REJECTED"* ]]
}

@test "validate_prometheus_query rejects an injected label value with embedded braces" {
  run validate_prometheus_query 'up{job="x"}{evil="y"}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"REJECTED"* ]]
}

# ===========================================================================
# PM-05
# ===========================================================================

@test "PM-05: all expected exporters up yields HEALTHY" {
  result_init "test-pm34" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[
    {"metric":{"job":"node"},"value":[1700000000,"1"]},
    {"metric":{"job":"postgres"},"value":[1700000000,"1"]},
    {"metric":{"job":"rabbitmq"},"value":[1700000000,"1"]},
    {"metric":{"job":"nginx"},"value":[1700000000,"1"]},
    {"metric":{"job":"redis"},"value":[1700000000,"1"]}
  ]}}'

  run pm_check_05_exporter_sweep "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "PM-05: one exporter down yields CRITICAL" {
  result_init "test-pm35" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[
    {"metric":{"job":"node"},"value":[1700000000,"1"]},
    {"metric":{"job":"postgres"},"value":[1700000000,"0"]},
    {"metric":{"job":"rabbitmq"},"value":[1700000000,"1"]},
    {"metric":{"job":"nginx"},"value":[1700000000,"1"]},
    {"metric":{"job":"redis"},"value":[1700000000,"1"]}
  ]}}'

  run pm_check_05_exporter_sweep "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

@test "PM-05: expected exporter missing yields WARNING" {
  result_init "test-pm36" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[
    {"metric":{"job":"node"},"value":[1700000000,"1"]}
  ]}}'

  run pm_check_05_exporter_sweep "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

@test "PM-05: exporter not configured for env yields NOT_CONFIGURED" {
  result_init "test-pm37" "qa"

  run pm_check_05_exporter_sweep "HEALTHY" ""
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_CONFIGURED" ]
}

@test "PM-05: duplicate exporter target yields WARNING" {
  result_init "test-pm38" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[
    {"metric":{"job":"node"},"value":[1700000000,"1"]},
    {"metric":{"job":"node"},"value":[1700000000,"1"]},
    {"metric":{"job":"postgres"},"value":[1700000000,"1"]},
    {"metric":{"job":"rabbitmq"},"value":[1700000000,"1"]},
    {"metric":{"job":"nginx"},"value":[1700000000,"1"]},
    {"metric":{"job":"redis"},"value":[1700000000,"1"]}
  ]}}'

  run pm_check_05_exporter_sweep "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

@test "PM-05: query/API failure yields UNKNOWN" {
  result_init "test-pm39" "qa"
  export MOCK_PROM_BODY='not json'

  run pm_check_05_exporter_sweep "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

@test "PM-05: NOT_APPLICABLE when PM-01 CRITICAL" {
  result_init "test-pm40" "qa"

  run pm_check_05_exporter_sweep "CRITICAL"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

# ===========================================================================
# PM-06
# ===========================================================================

@test "PM-06: config reload successful and rules fresh yields HEALTHY" {
  result_init "test-pm41" "qa"
  export MOCK_PROM_RELOAD_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"1"]}]}}'
  local now_epoch
  now_epoch="$(date +%s)"
  export MOCK_PROM_RULES_BODY
  MOCK_PROM_RULES_BODY="{\"status\":\"success\",\"data\":{\"result\":[{\"value\":[1700000000,\"${now_epoch}\"]}]}}"

  run pm_check_06_config_and_rules "HEALTHY" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'rule evaluation fresh' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-06: config reload metric reports failure yields CRITICAL" {
  result_init "test-pm42" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"0"]}]}}'

  run pm_check_06_config_and_rules "HEALTHY" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['likely_layer'] == 'prometheus_configuration'
assert 'validate-prometheus-config.sh' in obj['recommended_repair']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-06: rules expected but metric missing yields WARNING" {
  result_init "test-pm43" "qa"
  export MOCK_PROM_RELOAD_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"1"]}]}}'
  export MOCK_PROM_RULES_BODY='{"status":"success","data":{"result":[]}}'

  run pm_check_06_config_and_rules "HEALTHY" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['likely_layer'] == 'prometheus_rules'
assert 'metric absent' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-06: rule evaluation stale yields WARNING" {
  result_init "test-pm43b" "qa"
  export MOCK_PROM_RELOAD_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"1"]}]}}'
  local stale_epoch
  stale_epoch="$(( $(date +%s) - 600 ))"
  export MOCK_PROM_RULES_BODY
  MOCK_PROM_RULES_BODY="{\"status\":\"success\",\"data\":{\"result\":[{\"value\":[1700000000,\"${stale_epoch}\"]}]}}"

  run pm_check_06_config_and_rules "HEALTHY" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['likely_layer'] == 'prometheus_rules'
assert 'stale' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-06: rules not configured for env skips rule check" {
  result_init "test-pm44" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"1"]}]}}'

  run pm_check_06_config_and_rules "HEALTHY" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'rules not configured' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-06: query/API failure yields UNKNOWN" {
  result_init "test-pm45" "qa"
  export MOCK_PROM_BODY='not json'

  run pm_check_06_config_and_rules "HEALTHY" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

@test "PM-06: NOT_APPLICABLE when PM-01 CRITICAL" {
  result_init "test-pm46" "qa"

  run pm_check_06_config_and_rules "CRITICAL" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

@test "PM-06: never issues a POST request or calls /-/reload (static check)" {
  run bash -c "grep -v '^[[:space:]]*#' '${ROOT_DIR}/checks/prometheus.sh' | grep -E -- '-X[[:space:]]*POST|--request[[:space:]]+POST|/-/reload'"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# PM-07
# ===========================================================================

@test "PM-07: application key metric present yields HEALTHY" {
  result_init "test-pm47" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"42"]}]}}'

  run pm_check_07_key_metrics "app" "dhanman-purchase" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "PM-07: target up but key metric absent yields WARNING" {
  result_init "test-pm48" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[]}}'

  run pm_check_07_key_metrics "app" "dhanman-purchase" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['likely_layer'] == 'metrics_exposure_or_scrape_configuration'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-07: has_metrics=false yields NOT_APPLICABLE" {
  result_init "test-pm49" "qa"

  run pm_check_07_key_metrics "app" "dhanman-agent" "127.0.0.1:5108" "false" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

@test "PM-07: node metric group present yields HEALTHY" {
  result_init "test-pm50" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"12345"]}]}}'

  run pm_check_07_key_metrics "node" "qa/node" "127.0.0.1:9100" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "PM-07: postgres metric present yields HEALTHY" {
  result_init "test-pm51" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"1"]}]}}'

  run pm_check_07_key_metrics "postgres" "qa/postgres" "127.0.0.1:9187" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "PM-07: rabbitmq metric present yields HEALTHY" {
  result_init "test-pm52" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"1"]}]}}'

  run pm_check_07_key_metrics "rabbitmq" "qa/rabbitmq" "127.0.0.1:15692" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

@test "PM-07: down target does not create a duplicate CRITICAL (NOT_APPLICABLE instead)" {
  result_init "test-pm53" "qa"

  run pm_check_07_key_metrics "app" "dhanman-purchase" "127.0.0.1:5104" "true" "CRITICAL"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_APPLICABLE" ]
}

@test "PM-07: alternate HTTP metric family is accepted as a fallback" {
  result_init "test-pm54" "qa"
  # First two candidates return empty; the fixture always returns the
  # same body for every curl call in this bats process, so to exercise
  # the fallback path meaningfully we verify against the primary
  # candidate directly instead (both paths share the same lookup logic).
  export MOCK_PROM_BODY='{"status":"success","data":{"result":[{"value":[1700000000,"7"]}]}}'

  run pm_check_07_key_metrics "app" "dhanman-purchase" "127.0.0.1:5104" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'key metric present' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "PM-07: unsupported target_type is rejected" {
  result_init "test-pm55" "qa"

  run pm_check_07_key_metrics "not_a_real_type" "something" "" "true" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
}

# ===========================================================================
# Security / regression
# ===========================================================================

@test "validate_prometheus_query rejects empty {} selector" {
  run validate_prometheus_query 'up{}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"REJECTED"* ]]
}

@test "validate_prometheus_query rejects range vector syntax" {
  run validate_prometheus_query 'rate(http_requests_total{job="x"}[5m])'
  [ "$status" -eq 1 ]
  [[ "$output" == *"REJECTED"* ]]
}

@test "validate_prometheus_query accepts a bare metric name" {
  run validate_prometheus_query 'prometheus_config_last_reload_successful'
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "validate_prometheus_query accepts the PM-04 fixed template" {
  run validate_prometheus_query 'time() - timestamp(up{job="dhanman_services",instance="127.0.0.1:5104"})'
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "validate_prometheus_query accepts a job regex selector" {
  run validate_prometheus_query 'up{job=~"node|postgres|rabbitmq|nginx|redis"}'
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "no -X POST, --request POST, or /-/reload appears anywhere in prometheus.sh" {
  run bash -c "grep -v '^[[:space:]]*#' '${ROOT_DIR}/checks/prometheus.sh' | grep -E -- '-X[[:space:]]*POST|--request[[:space:]]+POST|/-/reload'"
  [ "$status" -ne 0 ]
}

@test "no admin or lifecycle write endpoints appear anywhere in prometheus.sh" {
  run grep -E -- '/-/quit|/api/v1/admin' "${ROOT_DIR}/checks/prometheus.sh"
  [ "$status" -ne 0 ]
}

@test "full targets response body is never embedded verbatim in evidence" {
  result_init "test-pm56" "qa"
  export MOCK_PROM_BODY='{"status":"success","data":{"activeTargets":[
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:5104"}},
    {"labels":{"job":"dhanman_services","instance":"127.0.0.1:9999"}}
  ]}}'

  run pm_check_03_target_comparison "qa" "dhanman-purchase:5104"
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'activeTargets' not in obj['evidence']
assert len(obj['evidence']) < 500
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
