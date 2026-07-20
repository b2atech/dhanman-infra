#!/usr/bin/env bats
#
# test-services.bats — unit tests for lib/result.sh and checks/services.sh.
# Uses mock systemctl/ss/curl/journalctl fixtures under fixtures/bin — no
# real system calls are made.

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FIXTURES_BIN="${BATS_TEST_DIRNAME}/fixtures/bin"
  PATH="${FIXTURES_BIN}:${PATH}"
  export PATH

  # shellcheck source=../lib/result.sh
  source "${ROOT_DIR}/lib/result.sh"
  # shellcheck source=../checks/services.sh
  source "${ROOT_DIR}/checks/services.sh"

  unset MOCK_SYSTEMCTL_STATE MOCK_SYSTEMCTL_NRESTARTS
  unset MOCK_SS_LISTENING MOCK_SS_PORT
  unset MOCK_CURL_HTTP_CODE MOCK_CURL_TIME_TOTAL
  unset MOCK_JOURNAL_OUTPUT
}

teardown() {
  if [[ -n "${RESULT_FILE:-}" && -f "${RESULT_FILE:-}" ]]; then
    rm -f "$RESULT_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Test 1
# ---------------------------------------------------------------------------
@test "result_add emits valid JSON with correct fields" {
  result_init "test-run-1" "qa"
  result_add "SVC-99" "dhanman-test" "HEALTHY" "all good" "none" "none"

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['check_id'] == 'SVC-99'
assert obj['target'] == 'dhanman-test'
assert obj['status'] == 'HEALTHY'
assert obj['evidence'] == 'all good'
assert obj['likely_layer'] == 'none'
assert obj['recommended_repair'] == 'none'
assert 'ts' in obj
assert obj['latency_ms'] == 0
assert 'journal_tail' not in obj
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 2
# ---------------------------------------------------------------------------
@test "result_add rejects invalid status, substitutes UNKNOWN" {
  result_init "test-run-2" "qa"
  result_add "SVC-99" "dhanman-test" "BOGUS_STATUS" "evidence" "none" "none"

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'UNKNOWN'
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 3
# ---------------------------------------------------------------------------
@test "result_add_with_journal CRITICAL includes journal_tail" {
  result_init "test-run-3" "qa"
  export MOCK_JOURNAL_OUTPUT=$'line one\nline two'
  result_add_with_journal "SVC-01" "dhanman-test" "CRITICAL" "process down" "process" "repair.sh" "dhanman-test-qa.service"

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'journal_tail' in obj
assert isinstance(obj['journal_tail'], list)
assert isinstance(obj['journal_lines_captured'], int)
assert obj['journal_lines_captured'] >= 0
assert isinstance(obj['journal_lines_redacted'], int)
assert obj['journal_lines_redacted'] >= 0
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 4 — the critical guard: absent, not null
# ---------------------------------------------------------------------------
@test "result_add_with_journal HEALTHY omits journal_tail key entirely" {
  result_init "test-run-4" "qa"
  result_add_with_journal "SVC-01" "dhanman-test" "HEALTHY" "process up" "none" "none" "dhanman-test-qa.service"

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert 'journal_tail' not in obj
assert 'journal_lines_captured' not in obj
assert 'journal_lines_redacted' not in obj
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 5
# ---------------------------------------------------------------------------
@test "redact replaces password=secret123 with REDACTED marker" {
  run redact "password=secret123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[REDACTED — possible credential]"* ]]
}

# ---------------------------------------------------------------------------
# Test 6
# ---------------------------------------------------------------------------
@test "redact leaves clean text unchanged" {
  run redact "service started successfully"
  [ "$status" -eq 0 ]
  [ "$output" = "service started successfully" ]
}

# ---------------------------------------------------------------------------
# Test 7
# ---------------------------------------------------------------------------
@test "redact HTML-escapes angle brackets" {
  run redact "value is <script>alert(1)</script>"
  [ "$status" -eq 0 ]
  [[ "$output" == *"&lt;script&gt;"* ]]
  [[ "$output" != *"<script>"* ]]
}

# ---------------------------------------------------------------------------
# Test 8
# ---------------------------------------------------------------------------
@test "redact truncates lines longer than 500 characters" {
  local long_line
  long_line="$(printf 'a%.0s' {1..600})"
  run redact "$long_line"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 500 ]
}

# ---------------------------------------------------------------------------
# Test 9
# ---------------------------------------------------------------------------
@test "result_summary produces valid JSON with correct totals" {
  result_init "test-run-9" "qa"
  result_add "SVC-01" "svc-a" "HEALTHY" "ok" "none" "none"
  result_add "SVC-01" "svc-b" "WARNING" "slow" "application" "none"
  result_add "SVC-01" "svc-c" "CRITICAL" "down" "process" "repair.sh"

  run result_summary
  [ "$status" -eq 0 ]
  local summary_json="$output"

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['run_id'] == 'test-run-9'
assert obj['env'] == 'qa'
assert obj['total'] == 3
assert obj['healthy'] == 1
assert obj['warning'] == 1
assert obj['critical'] == 1
assert obj['unknown'] == 0
assert obj['not_applicable'] == 0
assert len(obj['results']) == 3
print('OK')
" "$summary_json"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 10
# ---------------------------------------------------------------------------
@test "SVC-05 verdict: process down yields CRITICAL" {
  result_init "test-run-10" "qa"
  run svc_check_05_verdict "dhanman-test" "CRITICAL" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 11
# ---------------------------------------------------------------------------
@test "SVC-05 verdict: all healthy yields HEALTHY" {
  result_init "test-run-11" "qa"
  run svc_check_05_verdict "dhanman-test" "HEALTHY" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 12
# ---------------------------------------------------------------------------
@test "SVC-05 verdict: process up with internal 5xx yields CRITICAL" {
  result_init "test-run-12" "qa"
  run svc_check_05_verdict "dhanman-test" "HEALTHY" "HEALTHY" "CRITICAL"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}
