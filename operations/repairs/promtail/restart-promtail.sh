#!/bin/bash
# Restart the Promtail Docker container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/repair-common.sh
source "${SCRIPT_DIR}/../lib/repair-common.sh"

# shellcheck disable=SC2034  # declarative marker read by code reviewers, not by this script
SCOPE_ONE_TARGET="promtail docker container"

repair_init "restart-promtail" "promtail" "restart docker container promtail"

# Detect env from hostname/docker network
env=$(docker inspect promtail --format '{{.HostConfig.NetworkMode}}' 2>/dev/null | grep -o 'qa\|prod' || echo "unknown")
if [[ "$env" == "unknown" ]]; then
  echo "ABORT: cannot determine if this is QA or PROD Promtail" >&2
  exit 1
fi

repair_env_check "$env"

echo "Current Promtail state:" >&2
repair_show_current_state "promtail"

repair_confirm "restart docker container promtail" "$env"

repair_apply_change "docker restart promtail" "restart Promtail container"

sleep 3

# Postcheck: container must be running
docker_running=$(docker inspect promtail --format '{{.State.Running}}' 2>/dev/null || echo "false")
if [[ "$docker_running" != "true" ]]; then
  echo "✗ Postcheck FAILED: Promtail container not running" >&2
  repair_rollback_and_exit 3
fi

# Wait for the /ready endpoint to respond (best-effort, does not fail the repair)
ready=false
for _ in $(seq 1 30); do
  if docker exec promtail wget -qO- 127.0.0.1:9080/ready >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done

if [[ "$ready" == "true" ]]; then
  echo "✓ Promtail /ready endpoint responding" >&2
else
  echo "⚠ Promtail container is running but /ready did not respond within 30s" >&2
fi

repair_audit_record "succeeded" \
  "$(docker inspect promtail --format '{{.State.Status}}')" \
  "$(docker inspect promtail --format '{{.State.Running}}')" \
  "promtail container"

echo "✓ Repair succeeded: Promtail restarted" >&2
exit 0
