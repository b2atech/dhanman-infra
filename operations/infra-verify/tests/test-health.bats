#!/usr/bin/env bats
#
# test-health.bats — unit tests for checks/health.sh.
# Uses mock curl fixture under fixtures/bin — no real network calls.

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FIXTURES_BIN="${BATS_TEST_DIRNAME}/fixtures/bin"
  PATH="${FIXTURES_BIN}:${PATH}"
  export PATH

  # shellcheck source=../lib/result.sh
  source "${ROOT_DIR}/lib/result.sh"
  # shellcheck source=../checks/health.sh
  source "${ROOT_DIR}/checks/health.sh"

  unset MOCK_CURL_HTTP_CODE MOCK_CURL_TIME_TOTAL MOCK_CURL_BODY MOCK_CURL_FAIL
}

teardown() {
  if [[ -n "${RESULT_FILE:-}" && -f "${RESULT_FILE:-}" ]]; then
    rm -f "$RESULT_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Test 1
# ---------------------------------------------------------------------------
@test "HLT-01: 2xx fast response yields HEALTHY with latency recorded" {
  result_init "test-h1" "qa"
  export MOCK_CURL_HTTP_CODE=200
  export MOCK_CURL_TIME_TOTAL=0.050
  export MOCK_CURL_BODY="Healthy"

  run hlt_check_01_endpoint "5200" "dhanman-common" "5"
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['check_id'] == 'HLT-01'
assert obj['status'] == 'HEALTHY'
assert '0.050' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 2
# ---------------------------------------------------------------------------
@test "HLT-01: 2xx slow response yields WARNING" {
  result_init "test-h2" "qa"
  export MOCK_CURL_HTTP_CODE=200
  export MOCK_CURL_TIME_TOTAL=2.500
  export MOCK_CURL_BODY="Healthy"

  run hlt_check_01_endpoint "5200" "dhanman-common" "5"
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'WARNING'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 3
# ---------------------------------------------------------------------------
@test "HLT-01: connection refused yields CRITICAL" {
  result_init "test-h3" "qa"
  export MOCK_CURL_FAIL="refused"

  run hlt_check_01_endpoint "5200" "dhanman-common" "5"
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'CRITICAL'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 4
# ---------------------------------------------------------------------------
@test "HLT-01: timeout yields CRITICAL" {
  result_init "test-h4" "qa"
  export MOCK_CURL_FAIL="timeout"

  run hlt_check_01_endpoint "5200" "dhanman-common" "5"
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'CRITICAL'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 5
# ---------------------------------------------------------------------------
@test "HLT-02+03: plain text Healthy yields HEALTHY and HLT-03 NOT_APPLICABLE" {
  result_init "test-h5" "qa"

  run hlt_check_02_body_parse "dhanman-common" "Healthy"
  [ "$status" -eq 0 ]
  local hlt02_status entries_json
  hlt02_status="$(printf '%s\n' "$output" | sed -n '1p')"
  entries_json="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$hlt02_status" = "HEALTHY" ]

  run hlt_check_03_dependencies "dhanman-common" "$entries_json"
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
lines = sys.argv[1].splitlines()
objs = [json.loads(l) for l in lines if l.strip()]
hlt02 = [o for o in objs if o['check_id'] == 'HLT-02'][0]
hlt03 = [o for o in objs if o['check_id'] == 'HLT-03'][0]
assert hlt02['status'] == 'HEALTHY'
assert hlt03['status'] == 'NOT_APPLICABLE'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 6
# ---------------------------------------------------------------------------
@test "HLT-02: plain text Unhealthy yields CRITICAL" {
  result_init "test-h6" "qa"
  run hlt_check_02_body_parse "dhanman-common" "Unhealthy"
  [ "$status" -eq 0 ]
  local hlt02_status
  hlt02_status="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$hlt02_status" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 7
# ---------------------------------------------------------------------------
@test "HLT-02: plain text Degraded yields WARNING" {
  result_init "test-h7" "qa"
  run hlt_check_02_body_parse "dhanman-common" "Degraded"
  [ "$status" -eq 0 ]
  local hlt02_status
  hlt02_status="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$hlt02_status" = "WARNING" ]
}

# ---------------------------------------------------------------------------
# Test 8
# ---------------------------------------------------------------------------
@test "HLT-02+03: JSON status Healthy with healthy entries yields HEALTHY, no failed deps" {
  result_init "test-h8" "qa"
  local body='{"status":"Healthy","entries":{"Db":{"status":"Healthy"},"Redis":{"status":"Healthy"}}}'

  run hlt_check_02_body_parse "dhanman-common" "$body"
  [ "$status" -eq 0 ]
  local hlt02_status entries_json
  hlt02_status="$(printf '%s\n' "$output" | sed -n '1p')"
  entries_json="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$hlt02_status" = "HEALTHY" ]

  run hlt_check_03_dependencies "dhanman-common" "$entries_json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test 9
# ---------------------------------------------------------------------------
@test "HLT-02+03: JSON status Unhealthy with failed entry includes dep name in evidence" {
  result_init "test-h9" "qa"
  local body='{"status":"Unhealthy","entries":{"TemplateDb":{"status":"Unhealthy"},"Redis":{"status":"Healthy"}}}'

  run hlt_check_02_body_parse "dhanman-common" "$body"
  [ "$status" -eq 0 ]
  local hlt02_status entries_json
  hlt02_status="$(printf '%s\n' "$output" | sed -n '1p')"
  entries_json="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$hlt02_status" = "CRITICAL" ]

  run hlt_check_03_dependencies "dhanman-common" "$entries_json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TemplateDb"* ]]

  run python3 -c "
import json, sys
lines = sys.argv[1].splitlines()
objs = [json.loads(l) for l in lines if l.strip()]
hlt03 = [o for o in objs if o['check_id'] == 'HLT-03'][0]
assert 'TemplateDb' in hlt03['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 10
# ---------------------------------------------------------------------------
@test "HLT-02: unrecognised body yields UNKNOWN" {
  result_init "test-h10" "qa"
  run hlt_check_02_body_parse "dhanman-common" "this is not json or a known keyword"
  [ "$status" -eq 0 ]
  local hlt02_status
  hlt02_status="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$hlt02_status" = "UNKNOWN" ]
}

# ---------------------------------------------------------------------------
# Test 11
# ---------------------------------------------------------------------------
@test "HLT-02: credential in body is redacted before storage" {
  result_init "test-h11" "qa"
  run hlt_check_02_body_parse "dhanman-common" "password=secret"
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'password=secret' not in obj['evidence']
assert '[REDACTED' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 12
# ---------------------------------------------------------------------------
@test "HLT-04: no response yields CRITICAL layer network" {
  result_init "test-h12" "qa"
  run hlt_check_04_verdict "dhanman-common" "CRITICAL" "UNKNOWN" ""
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'CRITICAL'
assert obj['likely_layer'] == 'network'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 13
# ---------------------------------------------------------------------------
@test "HLT-04: 200 with body Unhealthy yields CRITICAL layer application" {
  result_init "test-h13" "qa"
  run hlt_check_04_verdict "dhanman-common" "HEALTHY" "CRITICAL" ""
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'CRITICAL'
assert obj['likely_layer'] == 'application'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 14
# ---------------------------------------------------------------------------
@test "HLT-04: 200 with body Healthy yields HEALTHY" {
  result_init "test-h14" "qa"
  run hlt_check_04_verdict "dhanman-common" "HEALTHY" "HEALTHY" ""
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 15
# ---------------------------------------------------------------------------
@test "HLT-04: slow response with body Healthy yields WARNING layer performance" {
  result_init "test-h15" "qa"
  run hlt_check_04_verdict "dhanman-common" "WARNING" "HEALTHY" ""
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'WARNING'
assert obj['likely_layer'] == 'performance'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
