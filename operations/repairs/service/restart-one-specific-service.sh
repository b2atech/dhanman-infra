#!/bin/bash
# Restart a single systemd dhanman-* service unit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/repair-common.sh
source "${SCRIPT_DIR}/../lib/repair-common.sh"

# shellcheck disable=SC2034  # declarative marker read by code reviewers, not by this script
SCOPE_ONE_TARGET="dhanman-*-qa.service or dhanman-*-prod.service (systemd units only)"

target_unit="${1:-}"

if [[ -z "$target_unit" ]]; then
  echo "Usage: $0 <unit-name>" >&2
  echo "Example: $0 dhanman-purchase-prod.service" >&2
  exit 1
fi

# Validate unit name against allowlist (must match dhanman-*-qa/prod pattern)
if ! [[ "$target_unit" =~ ^dhanman-[a-z]+-[a-z]+\.service$ ]]; then
  echo "ABORT: unit name must match pattern dhanman-*-qa.service or dhanman-*-prod.service" >&2
  exit 1
fi

# Extract env from unit name (qa or prod)
env="${target_unit##*-}"
env="${env%.service}"

repair_init "restart-one-specific-service" "$target_unit" "restart systemd unit $target_unit"

repair_env_check "$env"

echo "Current state:" >&2
repair_show_current_state "$target_unit"

repair_confirm "restart systemd unit $target_unit" "$env"

repair_apply_change "systemctl restart $target_unit" "restart systemd unit"

sleep 2

repair_postcheck "systemctl is-active $target_unit" "active"

repair_tripwire_check "/etc/systemd /run/systemd"

repair_audit_record "succeeded" \
  "$(systemctl show "$target_unit" -p State,ExecMainPID)" \
  "$(systemctl is-active "$target_unit")" \
  "$target_unit"

echo "✓ Repair succeeded: $target_unit restarted" >&2
exit 0
