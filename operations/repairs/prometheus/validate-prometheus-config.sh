#!/bin/bash
# Dry-run syntax check on Prometheus config + alert rules (read-only diagnostic).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/repair-common.sh
source "${SCRIPT_DIR}/../lib/repair-common.sh"

# shellcheck disable=SC2034  # declarative marker read by code reviewers, not by this script
SCOPE_ONE_TARGET="prometheus config + alert rules (read-only diagnostic)"

repair_init "validate-prometheus-config" "prometheus" "validate prometheus config and rules"

# Read-only diagnostic: no repair_env_check, no repair_confirm — nothing is mutated.

config_file="${PROMETHEUS_CONFIG_FILE:-/opt/monitoring/prometheus/prometheus.yml}"
rules_dir="${PROMETHEUS_RULES_DIR:-/opt/monitoring/prometheus/rules}"

if [[ ! -f "$config_file" ]]; then
  echo "ABORT: config file not found at $config_file" >&2
  exit 1
fi

echo "Validating Prometheus config..." >&2

if docker run --rm -v "${config_file}:/etc/prometheus/prometheus.yml:ro" \
  -v "${rules_dir}:/etc/prometheus/rules:ro" \
  --entrypoint promtool \
  prom/prometheus:v2.52.0 check config /etc/prometheus/prometheus.yml; then
  echo "✓ Prometheus config is valid" >&2
  repair_audit_record "succeeded" "config+rules syntax check" "valid" "$config_file $rules_dir"
  exit 0
else
  echo "✗ Prometheus config validation FAILED" >&2
  repair_audit_record "failed" "config+rules syntax check" "invalid" ""
  exit 1
fi
