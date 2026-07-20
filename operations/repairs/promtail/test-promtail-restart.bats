#!/usr/bin/env bats
# Tests for operations/repairs/promtail/restart-promtail.sh
#
# docker (and, incidentally, systemctl if present) are never invoked
# against real infrastructure — docker is stubbed via PATH injection.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/restart-promtail.sh"
  export REPAIR_BACKUP_ROOT="${BATS_TEST_TMPDIR}/backups"
  export REPAIR_AUDIT_LOG="${BATS_TEST_TMPDIR}/audit/repairs.jsonl"
  export REPAIR_ENV_FILE="${BATS_TEST_TMPDIR}/dhanman-env"
  mkdir -p "$REPAIR_BACKUP_ROOT" "${BATS_TEST_TMPDIR}/stub"

  cat > "${BATS_TEST_TMPDIR}/stub/docker" <<'EOF'
#!/bin/bash
if [[ "$1" == "inspect" ]]; then
  for arg in "$@"; do
    case "$arg" in
      *NetworkMode*) echo "${DOCKER_STUB_NETWORK:-dhanman_qa_net}"; exit 0 ;;
      *State.Running*) echo "${DOCKER_STUB_RUNNING:-true}"; exit 0 ;;
      *State.Status*) echo "running"; exit 0 ;;
    esac
  done
  exit 0
elif [[ "$1" == "restart" ]]; then
  exit "${DOCKER_STUB_RESTART_EXIT:-0}"
elif [[ "$1" == "exec" ]]; then
  exit "${DOCKER_STUB_EXEC_EXIT:-0}"
fi
exit 0
EOF
  chmod +x "${BATS_TEST_TMPDIR}/stub/docker"

  # No-op sleep so the /ready poll loop (up to 30 iterations) and the
  # fixed post-restart delay don't slow the suite down with real waits.
  cat > "${BATS_TEST_TMPDIR}/stub/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "${BATS_TEST_TMPDIR}/stub/sleep"
}

@test "aborts with exit 1 when the env can't be determined from the container's network" {
  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    export DOCKER_STUB_NETWORK="some_other_network"
    bash "'"$SCRIPT"'"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT: cannot determine if this is QA or PROD Promtail"* ]]
}

@test "aborts when the detected env doesn't match the host's /etc/dhanman-env" {
  echo -n "prod" > "$REPAIR_ENV_FILE"
  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    export DOCKER_STUB_NETWORK="dhanman_qa_net"
    bash "'"$SCRIPT"'"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT: Expected env=qa but running on prod host"* ]]
}

@test "restarts promtail and records success when confirmed and container comes back up" {
  echo -n "qa" > "$REPAIR_ENV_FILE"
  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    export DOCKER_STUB_NETWORK="dhanman_qa_net"
    echo "yes" | bash "'"$SCRIPT"'"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ Repair succeeded: Promtail restarted"* ]]
  grep -q '"status":"succeeded"' "$REPAIR_AUDIT_LOG"
}

@test "exits 3 (no file backup, nothing to roll back) when the container isn't running after restart" {
  echo -n "qa" > "$REPAIR_ENV_FILE"
  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    export DOCKER_STUB_NETWORK="dhanman_qa_net"
    export DOCKER_STUB_RUNNING="false"
    echo "yes" | bash "'"$SCRIPT"'"
  '
  [ "$status" -eq 3 ]
  [[ "$output" == *"✗ Postcheck FAILED: Promtail container not running"* ]]
  grep -q '"status":"verify-failed"' "$REPAIR_AUDIT_LOG"
}

@test "succeeds even if /ready never responds, but warns instead of failing" {
  echo -n "qa" > "$REPAIR_ENV_FILE"
  run bash -c '
    export PATH="'"${BATS_TEST_TMPDIR}"'/stub:$PATH"
    export DOCKER_STUB_NETWORK="dhanman_qa_net"
    export DOCKER_STUB_EXEC_EXIT="1"
    echo "yes" | bash "'"$SCRIPT"'"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ Promtail container is running but /ready did not respond"* ]]
  [[ "$output" == *"✓ Repair succeeded"* ]]
}
