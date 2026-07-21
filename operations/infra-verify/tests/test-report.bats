#!/usr/bin/env bats
#
# test-report.bats — unit tests for lib/report.sh (T6.1 JSON schema/writer,
# T6.2 HTML rendering, T6.3 redaction tripwire, T6.4 email delivery). The
# T6.4 tests stub msmtp via PATH injection — nothing here touches a real
# network or real credentials.

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

  # shellcheck source=../lib/result.sh
  source "${ROOT_DIR}/lib/result.sh"
  # shellcheck source=../lib/report.sh
  source "${ROOT_DIR}/lib/report.sh"

  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIR"
}

teardown() {
  if [[ -n "${RESULT_FILE:-}" && -f "${RESULT_FILE:-}" ]]; then
    rm -f "$RESULT_FILE"
  fi
}

# ===========================================================================
# report_build — rollup algorithm
# ===========================================================================

@test "report_build: all HEALTHY yields overall_status HEALTHY" {
  result_init "test-rb1" "qa"
  result_add "SVC-01" "dhanman-purchase" "HEALTHY" "ok" "none" "none"
  result_add "HLT-01" "dhanman-purchase" "HEALTHY" "ok" "none" "none"

  run report_build
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['overall_status'] == 'HEALTHY'
assert obj['critical_severity_breach'] is False
print('OK')
" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "report_build: CRITICAL on non-critical-severity service yields CRITICAL without breach flag" {
  result_init "test-rb2" "qa"
  # dhanman-document is severity:medium in the real qa inventory
  result_add "SVC-01" "dhanman-document" "CRITICAL" "process down" "process" "none"

  run report_build
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['overall_status'] == 'CRITICAL'
assert obj['critical_severity_breach'] is False
print('OK')
" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "report_build: CRITICAL on severity:critical service sets critical_severity_breach" {
  result_init "test-rb3" "qa"
  # dhanman-common is severity:critical in the real qa inventory
  result_add "SVC-01" "dhanman-common" "CRITICAL" "process down" "process" "none"

  run report_build
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['overall_status'] == 'CRITICAL'
assert obj['critical_severity_breach'] is True
print('OK')
" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "report_build: WARNING with no CRITICAL yields overall_status WARNING" {
  result_init "test-rb4" "qa"
  result_add "LOG-04" "dhanman-purchase" "WARNING" "log stale" "application" "none"

  run report_build
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['overall_status'] == 'WARNING'
print('OK')
" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "report_build: UNKNOWN on a critical-path check (PM-01) yields WARNING" {
  result_init "test-rb5" "qa"
  result_add "PM-01" "prometheus" "UNKNOWN" "auth required" "prometheus_readiness" "none"

  run report_build
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['overall_status'] == 'WARNING'
print('OK')
" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "report_build: UNKNOWN off the critical path, no WARNING/CRITICAL, yields HEALTHY" {
  result_init "test-rb6" "qa"
  # LK-03 on a non-critical-severity service is not in the critical-path
  # check-id set and dhanman-document is severity:medium
  result_add "LK-03" "dhanman-document" "UNKNOWN" "could not parse timestamp" "none" "none"

  run report_build
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['overall_status'] == 'HEALTHY'
print('OK')
" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "report_build: counts are correct" {
  result_init "test-rb7" "qa"
  result_add "SVC-01" "dhanman-purchase" "HEALTHY" "ok" "none" "none"
  result_add "SVC-02" "dhanman-purchase" "WARNING" "slow" "none" "none"
  result_add "SVC-03" "dhanman-purchase" "CRITICAL" "down" "process" "none"
  result_add "SVC-04" "dhanman-purchase" "NOT_APPLICABLE" "n/a" "none" "none"
  result_add "SVC-05" "dhanman-purchase" "NOT_CONFIGURED" "no token" "none" "none"

  run report_build
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['total'] == 5
assert obj['healthy'] == 1
assert obj['warning'] == 1
assert obj['critical'] == 1
assert obj['not_applicable'] == 1
assert obj['not_configured'] == 1
print('OK')
" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "report_build: issues array excludes HEALTHY/NOT_APPLICABLE/NOT_CONFIGURED" {
  result_init "test-rb8" "qa"
  result_add "SVC-01" "dhanman-purchase" "HEALTHY" "ok" "none" "none"
  result_add "SVC-02" "dhanman-purchase" "WARNING" "slow" "none" "none"
  result_add "SVC-03" "dhanman-purchase" "NOT_APPLICABLE" "n/a" "none" "none"

  run report_build
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert len(obj['issues']) == 1
assert obj['issues'][0]['check_id'] == 'SVC-02'
assert len(obj['results']) == 3
print('OK')
" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ===========================================================================
# report_render_html — escaping
# ===========================================================================

@test "report_render_html: script tag in evidence is escaped, not executable" {
  result_init "test-rh1" "qa"
  result_add "SVC-01" "dhanman-purchase" "CRITICAL" '<script>alert(1)</script>' "process" "none"

  local report_json
  report_json="$(report_build)"

  run report_render_html "$report_json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"<script>alert(1)</script>"* ]]
  [[ "$output" == *"&lt;script&gt;"* ]]
}

@test "report_render_html: quote-based injection attempt is escaped" {
  result_init "test-rh2" "qa"
  result_add "SVC-01" "dhanman-purchase" "CRITICAL" 'value" onmouseover="alert(1)' "process" "none"

  local report_json
  report_json="$(report_build)"

  run report_render_html "$report_json"
  [ "$status" -eq 0 ]
  [[ "$output" != *'onmouseover="alert(1)'* ]]
  [[ "$output" == *"&quot;"* ]]
}

@test "report_render_html: renders run_id, env, overall status badge" {
  result_init "test-rh3" "qa"
  result_add "SVC-01" "dhanman-purchase" "HEALTHY" "ok" "none" "none"

  local report_json
  report_json="$(report_build)"

  run report_render_html "$report_json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-rh3"* ]]
  [[ "$output" == *"qa"* ]]
  [[ "$output" == *"HEALTHY"* ]]
  [[ "$output" == *"badge"* ]]
}

@test "report_render_html: no issues shows the all-clear message" {
  result_init "test-rh4" "qa"
  result_add "SVC-01" "dhanman-purchase" "HEALTHY" "ok" "none" "none"

  local report_json
  report_json="$(report_build)"

  run report_render_html "$report_json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No issues"* ]]
}

# ===========================================================================
# report_scan_for_secrets — tripwire
# ===========================================================================

@test "report_scan_for_secrets: clean text yields CLEAN" {
  run report_scan_for_secrets "service started successfully, all checks passing"
  [ "$status" -eq 0 ]
  [ "$output" = "CLEAN" ]
}

@test "report_scan_for_secrets: password=hunter2 is detected" {
  run report_scan_for_secrets "connecting with password=hunter2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FOUND"* ]]
}

@test "report_scan_for_secrets: PEM block is detected" {
  run report_scan_for_secrets $'-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg\n-----END PRIVATE KEY-----'
  [ "$status" -eq 1 ]
  [[ "$output" == *"FOUND"* ]]
}

@test "report_scan_for_secrets: bearer token is detected" {
  run report_scan_for_secrets "Authorization: Bearer abc123XYZ"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FOUND"* ]]
}

# ===========================================================================
# Tripwire integration — known-bad and known-good fixtures end to end
# ===========================================================================

@test "tripwire integration: an unredacted credential slipping into evidence is caught" {
  result_init "test-tw1" "qa"
  # Simulates a hypothetical future check that forgot to call redact()
  # before building its evidence string.
  result_add "PM-02" "dhanman-purchase" "CRITICAL" "dial tcp: password=hunter2live" "prometheus_targets" "none"

  local report_json rendered_html
  report_json="$(report_build)"
  rendered_html="$(report_render_html "$report_json")"

  run report_scan_for_secrets "$rendered_html"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FOUND"* ]]
}

@test "tripwire integration: properly redacted evidence passes cleanly (no false positive)" {
  result_init "test-tw2" "qa"
  # redact() already ran at check-execution time (as every real check
  # does) — the marker text itself must not trip the scanner.
  local redacted_evidence
  redacted_evidence="$(redact "dial tcp: password=hunter2live")"
  result_add "PM-02" "dhanman-purchase" "CRITICAL" "$redacted_evidence" "prometheus_targets" "none"

  local report_json rendered_html
  report_json="$(report_build)"
  rendered_html="$(report_render_html "$report_json")"

  run report_scan_for_secrets "$rendered_html"
  [ "$status" -eq 0 ]
  [ "$output" = "CLEAN" ]
}

# ===========================================================================
# report_send_email — T6.4
# ===========================================================================

@test "report_send_email: empty recipients_csv is a no-op success" {
  echo "<html>ok</html>" > "${BATS_TEST_TMPDIR}/report.html"

  run report_send_email "qa" "HEALTHY" "${BATS_TEST_TMPDIR}/report.html" ""
  [ "$status" -eq 0 ]
}

@test "report_send_email: missing msmtp binary returns 1" {
  echo "<html>ok</html>" > "${BATS_TEST_TMPDIR}/report.html"

  # Empty stub dir first (guarantees no msmtp shadows it), plus real
  # system dirs so date/cat/etc. used elsewhere in the call still work —
  # this must isolate only the "msmtp is missing" condition, not the
  # whole PATH.
  run env PATH="${STUB_DIR}:/usr/bin:/bin" bash -c '
    source "'"${ROOT_DIR}"'/lib/result.sh"
    source "'"${ROOT_DIR}"'/lib/report.sh"
    report_send_email "qa" "HEALTHY" "'"${BATS_TEST_TMPDIR}"'/report.html" "a@example.com"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"msmtp not found"* ]]
}

@test "report_send_email: missing HTML file returns 1" {
  cat > "${STUB_DIR}/msmtp" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "${STUB_DIR}/msmtp"

  run env PATH="${STUB_DIR}:${PATH}" bash -c '
    source "'"${ROOT_DIR}"'/lib/result.sh"
    source "'"${ROOT_DIR}"'/lib/report.sh"
    report_send_email "qa" "HEALTHY" "'"${BATS_TEST_TMPDIR}"'/does-not-exist.html" "a@example.com"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTML report file not found"* ]]
}

@test "report_send_email: secret in body aborts and never invokes msmtp" {
  echo "leaked password=hunter2live" > "${BATS_TEST_TMPDIR}/report.html"
  cat > "${STUB_DIR}/msmtp" <<EOF
#!/bin/bash
touch "${BATS_TEST_TMPDIR}/msmtp-was-called"
exit 0
EOF
  chmod +x "${STUB_DIR}/msmtp"

  run env PATH="${STUB_DIR}:${PATH}" bash -c '
    source "'"${ROOT_DIR}"'/lib/result.sh"
    source "'"${ROOT_DIR}"'/lib/report.sh"
    report_send_email "qa" "CRITICAL" "'"${BATS_TEST_TMPDIR}"'/report.html" "a@example.com"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORTED"* ]]
  [ ! -f "${BATS_TEST_TMPDIR}/msmtp-was-called" ]
}

@test "report_send_email: successful send passes correct headers, body, and recipients to msmtp" {
  echo "<html><body>all healthy</body></html>" > "${BATS_TEST_TMPDIR}/report.html"
  cat > "${STUB_DIR}/msmtp" <<EOF
#!/bin/bash
echo "ARGS:\$*" > "${BATS_TEST_TMPDIR}/msmtp.args"
cat > "${BATS_TEST_TMPDIR}/msmtp.stdin"
exit 0
EOF
  chmod +x "${STUB_DIR}/msmtp"

  run env PATH="${STUB_DIR}:${PATH}" bash -c '
    source "'"${ROOT_DIR}"'/lib/result.sh"
    source "'"${ROOT_DIR}"'/lib/report.sh"
    report_send_email "qa" "WARNING" "'"${BATS_TEST_TMPDIR}"'/report.html" "a@example.com,b@example.com"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent to a@example.com,b@example.com"* ]]

  run cat "${BATS_TEST_TMPDIR}/msmtp.args"
  [[ "$output" == *"-a default"* ]]
  [[ "$output" == *"a@example.com"* ]]
  [[ "$output" == *"b@example.com"* ]]

  run cat "${BATS_TEST_TMPDIR}/msmtp.stdin"
  [[ "$output" == *"To: a@example.com,b@example.com"* ]]
  [[ "$output" == *"Subject: DhanMan Infra Report [qa] WARNING"* ]]
  [[ "$output" == *"Content-Type: text/html; charset=UTF-8"* ]]
  [[ "$output" == *"<body>all healthy</body>"* ]]
}

@test "report_send_email: msmtp failure is propagated as a non-zero exit" {
  echo "<html>ok</html>" > "${BATS_TEST_TMPDIR}/report.html"
  cat > "${STUB_DIR}/msmtp" <<'EOF'
#!/bin/bash
cat >/dev/null
exit 1
EOF
  chmod +x "${STUB_DIR}/msmtp"

  run env PATH="${STUB_DIR}:${PATH}" bash -c '
    source "'"${ROOT_DIR}"'/lib/result.sh"
    source "'"${ROOT_DIR}"'/lib/report.sh"
    report_send_email "qa" "HEALTHY" "'"${BATS_TEST_TMPDIR}"'/report.html" "a@example.com"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"msmtp failed"* ]]
}
