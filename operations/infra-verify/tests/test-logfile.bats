#!/usr/bin/env bats
#
# test-logfile.bats — unit tests for checks/logfile.sh.
# Uses a temporary directory as a fake log root — never touches
# /var/www or any real system path. stat/df are mocked via fixtures/bin
# only for the specific queries that need root-independent, deterministic
# values (ownership, disk%); all other stat calls hit the real filesystem
# against the temp fixture files.

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FIXTURES_BIN="${BATS_TEST_DIRNAME}/fixtures/bin"
  PATH="${FIXTURES_BIN}:${PATH}"
  export PATH

  # shellcheck source=../lib/result.sh
  source "${ROOT_DIR}/lib/result.sh"
  # shellcheck source=../checks/logfile.sh
  source "${ROOT_DIR}/checks/logfile.sh"

  TEST_TMP="$(mktemp -d)"

  unset MOCK_STAT_OWNER_GROUP MOCK_DF_PCENT MOCK_DF_IPCENT
}

teardown() {
  if [[ -n "${RESULT_FILE:-}" && -f "${RESULT_FILE:-}" ]]; then
    rm -f "$RESULT_FILE"
  fi
  if [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP:-}" ]]; then
    chmod -R u+rwx "$TEST_TMP" 2>/dev/null || true
    rm -rf "$TEST_TMP"
  fi
}

# ---------------------------------------------------------------------------
# Test 1
# ---------------------------------------------------------------------------
@test "LOG-01: directory exists and traversable yields HEALTHY" {
  result_init "test-l1" "qa"
  local dir="${TEST_TMP}/logs1"
  mkdir -p "$dir"
  chmod 755 "$dir"

  run log_check_01_dir_exists "$dir" "dhanman-test"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 2
# ---------------------------------------------------------------------------
@test "LOG-01: directory missing yields CRITICAL" {
  result_init "test-l2" "qa"
  local dir="${TEST_TMP}/does-not-exist"

  run log_check_01_dir_exists "$dir" "dhanman-test"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 3
# ---------------------------------------------------------------------------
@test "LOG-01: directory exists but not traversable yields WARNING" {
  result_init "test-l3" "qa"
  local dir="${TEST_TMP}/logs3"
  mkdir -p "$dir"
  chmod 000 "$dir"

  run log_check_01_dir_exists "$dir" "dhanman-test"
  chmod 755 "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

# ---------------------------------------------------------------------------
# Test 4
# ---------------------------------------------------------------------------
@test "LOG-02: today's file exists yields HEALTHY" {
  result_init "test-l4" "qa"
  local dir="${TEST_TMP}/logs4"
  mkdir -p "$dir"
  local today
  today="$(date +%Y%m%d)"
  touch "${dir}/dhanman-test-${today}.log"

  run log_check_02_today_file "$dir" "dhanman-test"
  [ "$status" -eq 0 ]
  local log02_status
  log02_status="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$log02_status" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 5
# ---------------------------------------------------------------------------
@test "LOG-02: today missing but yesterday exists yields WARNING" {
  result_init "test-l5" "qa"
  local dir="${TEST_TMP}/logs5"
  mkdir -p "$dir"
  local yesterday
  yesterday="$(date -d 'yesterday' +%Y%m%d)"
  touch "${dir}/dhanman-test-${yesterday}.log"

  run log_check_02_today_file "$dir" "dhanman-test"
  [ "$status" -eq 0 ]
  local log02_status
  log02_status="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$log02_status" = "WARNING" ]
}

# ---------------------------------------------------------------------------
# Test 6
# ---------------------------------------------------------------------------
@test "LOG-02: neither today nor yesterday exists yields CRITICAL" {
  result_init "test-l6" "qa"
  local dir="${TEST_TMP}/logs6"
  mkdir -p "$dir"

  run log_check_02_today_file "$dir" "dhanman-test"
  [ "$status" -eq 0 ]
  local log02_status
  log02_status="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$log02_status" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 7
# ---------------------------------------------------------------------------
@test "LOG-03: file readable and non-empty yields HEALTHY" {
  result_init "test-l7" "qa"
  local dir="${TEST_TMP}/logs7"
  mkdir -p "$dir"
  local f="${dir}/dhanman-test-file.log"
  echo "some log content" > "$f"
  chmod 644 "$f"

  run log_check_03_readable "dhanman-test" "$f" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 8
# ---------------------------------------------------------------------------
@test "LOG-03: file readable but empty yields WARNING" {
  result_init "test-l8" "qa"
  local dir="${TEST_TMP}/logs8"
  mkdir -p "$dir"
  local f="${dir}/dhanman-test-file.log"
  : > "$f"
  chmod 644 "$f"

  run log_check_03_readable "dhanman-test" "$f" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

# ---------------------------------------------------------------------------
# Test 9
# ---------------------------------------------------------------------------
@test "LOG-03: file not readable yields CRITICAL" {
  result_init "test-l9" "qa"
  local dir="${TEST_TMP}/logs9"
  mkdir -p "$dir"
  local f="${dir}/dhanman-test-file.log"
  echo "content" > "$f"
  chmod 000 "$f"

  run log_check_03_readable "dhanman-test" "$f" "HEALTHY"
  chmod 644 "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 10
# ---------------------------------------------------------------------------
@test "LOG-04: mtime within threshold yields HEALTHY" {
  result_init "test-l10" "qa"
  local dir="${TEST_TMP}/logs10"
  mkdir -p "$dir"
  local f="${dir}/dhanman-test-file.log"
  touch "$f"

  run log_check_04_freshness "dhanman-test" "$f" "HEALTHY" "30"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 11
# ---------------------------------------------------------------------------
@test "LOG-04: mtime beyond threshold, service healthy yields WARNING" {
  result_init "test-l11" "qa"
  local dir="${TEST_TMP}/logs11"
  mkdir -p "$dir"
  local f="${dir}/dhanman-test-file.log"
  touch -d '2 hours ago' "$f"

  run log_check_04_freshness "dhanman-test" "$f" "HEALTHY" "30" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

# ---------------------------------------------------------------------------
# Test 12
# ---------------------------------------------------------------------------
@test "LOG-05: correct ownership (www-data:www-data) yields HEALTHY" {
  result_init "test-l12" "qa"
  local dir="${TEST_TMP}/logs12"
  mkdir -p "$dir"
  local f="${dir}/dhanman-test-file.log"
  touch "$f"
  export MOCK_STAT_OWNER_GROUP="www-data www-data"

  run log_check_05_ownership "dhanman-test" "$f" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 13
# ---------------------------------------------------------------------------
@test "LOG-05: wrong ownership yields WARNING" {
  result_init "test-l13" "qa"
  local dir="${TEST_TMP}/logs13"
  mkdir -p "$dir"
  local f="${dir}/dhanman-test-file.log"
  touch "$f"
  export MOCK_STAT_OWNER_GROUP="root root"

  run log_check_05_ownership "dhanman-test" "$f" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

# ---------------------------------------------------------------------------
# Test 14
# ---------------------------------------------------------------------------
@test "LOG-06: no files outside log_dir yields HEALTHY" {
  result_init "test-l14" "qa"
  local base="${TEST_TMP}/base14"
  local dir="${base}/logs"
  mkdir -p "$dir"
  touch "${dir}/dhanman-test-20260718.log"

  run log_check_06_wrong_location "dhanman-test" "$base" "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 15
# ---------------------------------------------------------------------------
@test "LOG-06: file outside log_dir yields WARNING with path in evidence" {
  result_init "test-l15" "qa"
  local base="${TEST_TMP}/base15"
  local dir="${base}/logs"
  mkdir -p "$dir"
  mkdir -p "${base}/wrongplace"
  touch "${base}/wrongplace/dhanman-test-20260718.log"

  run log_check_06_wrong_location "dhanman-test" "$base" "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
assert obj['status'] == 'WARNING'
assert 'wrongplace' in obj['evidence']
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Test 16
# ---------------------------------------------------------------------------
@test "LOG-07: disk under 80% yields HEALTHY" {
  result_init "test-l16" "qa"
  export MOCK_DF_PCENT=50
  export MOCK_DF_IPCENT=50

  run log_check_07_disk_space "qa" "${TEST_TMP}"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 17
# ---------------------------------------------------------------------------
@test "LOG-07: disk over 90% yields CRITICAL" {
  result_init "test-l17" "qa"
  export MOCK_DF_PCENT=95
  export MOCK_DF_IPCENT=50

  run log_check_07_disk_space "qa" "${TEST_TMP}"
  [ "$status" -eq 0 ]
  [ "$output" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# Test 18
# ---------------------------------------------------------------------------
@test "LOG-08: file count between 1 and 35 yields HEALTHY" {
  result_init "test-l18" "qa"
  local dir="${TEST_TMP}/logs18"
  mkdir -p "$dir"
  local i
  for i in $(seq -w 1 10); do
    touch "${dir}/dhanman-test-202607${i}.log"
  done

  run log_check_08_rotation "dhanman-test" "$dir" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "HEALTHY" ]
}

# ---------------------------------------------------------------------------
# Test 19
# ---------------------------------------------------------------------------
@test "LOG-08: file count over 35 yields WARNING" {
  result_init "test-l19" "qa"
  local dir="${TEST_TMP}/logs19"
  mkdir -p "$dir"
  local i
  for i in $(seq -w 1 40); do
    touch "${dir}/dhanman-test-file${i}.log"
  done

  run log_check_08_rotation "dhanman-test" "$dir" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]
}

# ---------------------------------------------------------------------------
# Test 20
# ---------------------------------------------------------------------------
@test "LOG-03/04: idle service (empty+stale+SVC healthy) yields WARNING with application-idle layer" {
  result_init "test-l20" "qa"
  local dir="${TEST_TMP}/logs20"
  mkdir -p "$dir"
  local f="${dir}/dhanman-test-file.log"
  : > "$f"
  touch -d '2 hours ago' "$f"

  run log_check_03_readable "dhanman-test" "$f" "HEALTHY" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run log_check_04_freshness "dhanman-test" "$f" "HEALTHY" "30" "HEALTHY" "HEALTHY"
  [ "$status" -eq 0 ]
  [ "$output" = "WARNING" ]

  run python3 -c "
import json, sys
lines = sys.argv[1].splitlines()
objs = [json.loads(l) for l in lines if l.strip()]
log03 = [o for o in objs if o['check_id'] == 'LOG-03'][0]
log04 = [o for o in objs if o['check_id'] == 'LOG-04'][0]
assert log03['status'] == 'WARNING'
assert log04['status'] == 'WARNING'
assert log03['likely_layer'] == 'application-idle'
assert log04['likely_layer'] == 'application-idle'
assert 'idle' in log03['evidence'].lower()
assert 'idle' in log04['evidence'].lower()
print('OK')
" "$(cat "$RESULT_FILE")"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
