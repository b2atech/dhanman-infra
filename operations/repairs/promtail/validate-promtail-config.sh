#!/bin/bash
# Dry-run syntax check on Promtail config (read-only diagnostic, no mutation).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/repair-common.sh
source "${SCRIPT_DIR}/../lib/repair-common.sh"

# shellcheck disable=SC2034  # declarative marker read by code reviewers, not by this script
SCOPE_ONE_TARGET="promtail container config file (read-only diagnostic)"

repair_init "validate-promtail-config" "promtail" "validate promtail config syntax"

# Read-only diagnostic: no repair_env_check, no repair_confirm — nothing is mutated.

echo "Validating Promtail config syntax..." >&2

config_file="${PROMTAIL_CONFIG_FILE:-/opt/monitoring/promtail/promtail-config.yml}"

if [[ ! -f "$config_file" ]]; then
  echo "ABORT: config file not found at $config_file" >&2
  exit 1
fi

if docker run --rm \
  -v "${config_file}:/etc/promtail/config.yml:ro" \
  grafana/promtail:2.9.0 \
  -config.file=/etc/promtail/config.yml -dry-run; then
  echo "✓ Promtail config is valid" >&2
  repair_audit_record "succeeded" "config syntax check" "valid" "$config_file"
  exit 0
else
  echo "✗ Promtail config validation FAILED" >&2
  repair_audit_record "failed" "config syntax check" "invalid" ""
  exit 1
fi
