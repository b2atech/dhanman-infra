#!/usr/bin/env bash
#
# generate-inventory.sh — builds operations/infra-verify/config/inventory.<env>.yaml
# from the authoritative Ansible service list in
# ansible/inventories/<env>/group_vars/all/main.yml.
#
# Read-only against the Ansible source; writes only inside this config/ dir.
# Idempotent — safe to re-run at any time (each output is regenerated from
# scratch and replaced atomically).

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(realpath -m "${SCRIPT_DIR}/../../..")"
readonly REPO_ROOT

readonly SRC_PROD="${REPO_ROOT}/ansible/inventories/prod/group_vars/all/main.yml"
readonly SRC_QA="${REPO_ROOT}/ansible/inventories/qa/group_vars/all/main.yml"
readonly OUT_PROD="${SCRIPT_DIR}/inventory.prod.yaml"
readonly OUT_QA="${SCRIPT_DIR}/inventory.qa.yaml"

# ---------------------------------------------------------------------------
# Fixed defaults (not present in group_vars — deliberate, documented here)
# ---------------------------------------------------------------------------
readonly DEFAULT_FRESHNESS_MINUTES=30
readonly DEFAULT_TIMEOUT_SECONDS=5
readonly DEFAULT_JOURNAL_ON_DOWN=true
# alertmanager has no dedicated group_var — port 9093 is only a docker-compose
# literal (ansible/roles/monitoring/templates/docker-compose.yml.j2). Likewise
# the promtail container name "promtail" is a docker-compose literal, not a var.
readonly ALERTMANAGER_PORT=9093
readonly PROMTAIL_CONTAINER="promtail"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local level="$1"
  shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s [%s] %s\n' "$ts" "$level" "$*" >&2
}

# ---------------------------------------------------------------------------
# YAML tool detection — prefer yq, fall back to python3+PyYAML
# ---------------------------------------------------------------------------
YAML_TOOL=""

detect_yaml_tool() {
  if command -v yq >/dev/null 2>&1; then
    YAML_TOOL="yq"
    log INFO "Using yq: $(command -v yq)"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    YAML_TOOL="python3"
    log INFO "yq not found; using python3+PyYAML: $(command -v python3)"
    return 0
  fi
  log ERROR "Neither 'yq' nor 'python3 (with PyYAML)' is available. Install one of them and retry."
  exit 1
}

# ---------------------------------------------------------------------------
# Source readers — same behaviour regardless of which tool is selected:
# absent field -> "null", boolean fields -> "true"/"false", else raw value.
# ---------------------------------------------------------------------------
get_service_count() {
  local file="$1"
  if [[ "$YAML_TOOL" == "yq" ]]; then
    yq eval '.services | length' "$file"
  else
    python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(len(data.get("services", [])))
' "$file"
  fi
}

get_service_field() {
  local file="$1" index="$2" field="$3"
  if [[ "$YAML_TOOL" == "yq" ]]; then
    yq eval ".services[${index}].${field}" "$file"
  else
    python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
svc = data["services"][int(sys.argv[2])]
val = svc.get(sys.argv[3])
if val is None:
    print("null")
elif isinstance(val, bool):
    print("true" if val else "false")
else:
    print(val)
' "$file" "$index" "$field"
  fi
}

get_top_level() {
  local file="$1" field="$2"
  if [[ "$YAML_TOOL" == "yq" ]]; then
    yq eval ".${field}" "$file"
  else
    python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
val = data.get(sys.argv[2])
if val is None:
    print("null")
elif isinstance(val, bool):
    print("true" if val else "false")
else:
    print(val)
' "$file" "$field"
  fi
}

# ---------------------------------------------------------------------------
# Severity assignment — hardcoded per T1.2 spec
# ---------------------------------------------------------------------------
severity_for() {
  case "$1" in
    dhanman-common|dhanman-community|dhanman-payment)
      echo critical
      ;;
    dhanman-payroll|dhanman-purchase|dhanman-sales|dhanman-inventory)
      echo high
      ;;
    dhanman-document|dhanman-einvoice|dhanman-agent)
      echo medium
      ;;
    *)
      log WARN "No severity mapping for '$1' — defaulting to medium"
      echo medium
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Emit one service block
# ---------------------------------------------------------------------------
emit_service() {
  local out="$1"
  local env_name="$2"
  local name="$3"
  local port="$4"
  local domain="$5"
  local has_metrics="$6"
  local services_base_dir="$7"
  local severity="$8"

  local systemd_unit="${name}-${env_name}.service"
  local internal_url="http://127.0.0.1:${port}"
  local health_url="${internal_url}/health"
  local metrics_url="null"
  if [[ "$has_metrics" == "true" ]]; then
    metrics_url="${internal_url}/metrics"
  fi
  local log_dir="${services_base_dir}/logs"
  local log_pattern="${name}-*.log"
  local short_name="${name#dhanman-}"

  {
    printf '  - name: %s\n' "$name"
    printf '    environment: %s\n' "$env_name"
    printf '    port: %s\n' "$port"
    printf '    domain: %s\n' "$domain"
    printf '    has_metrics: %s\n' "$has_metrics"
    printf '    systemd_unit: %s\n' "$systemd_unit"
    printf '    internal_url: %s\n' "$internal_url"
    printf '    health_url: %s\n' "$health_url"
    printf '    metrics_url: %s\n' "$metrics_url"
    printf '    log_dir: %s\n' "$log_dir"
    printf '    log_pattern: "%s"\n' "$log_pattern"
    printf '    loki_labels:\n'
    printf '      env: %s\n' "$env_name"
    printf '      service_name: %s\n' "$short_name"
    printf '    freshness_threshold_minutes: %s\n' "$DEFAULT_FRESHNESS_MINUTES"
    printf '    timeout_seconds: %s\n' "$DEFAULT_TIMEOUT_SECONDS"
    printf '    severity: %s\n' "$severity"
    printf '    journal_on_down: %s\n' "$DEFAULT_JOURNAL_ON_DOWN"
    printf '\n'
  } >> "$out"
}

# ---------------------------------------------------------------------------
# Generate one environment's inventory file
# ---------------------------------------------------------------------------
generate_inventory() {
  local env_name="$1"
  local src="$2"
  local out="$3"

  if [[ ! -f "$src" ]]; then
    log ERROR "Source file not found: ${src}"
    exit 1
  fi

  local services_base_dir monitoring_dir loki_port prometheus_port grafana_port
  services_base_dir="$(get_top_level "$src" services_base_dir)"
  monitoring_dir="$(get_top_level "$src" monitoring_dir)"
  loki_port="$(get_top_level "$src" loki_port)"
  prometheus_port="$(get_top_level "$src" prometheus_port)"
  grafana_port="$(get_top_level "$src" grafana_port)"

  local tmp_out
  tmp_out="$(mktemp "${out}.tmp.XXXXXX")"

  {
    printf '# AUTO-GENERATED by generate-inventory.sh\n'
    printf '#  Source: ansible/inventories/%s/group_vars/all/main.yml\n' "$env_name"
    printf '#  Do not edit manually — re-run generate-inventory.sh\n'
    printf '\n'
    printf 'services:\n'
  } > "$tmp_out"

  local count
  count="$(get_service_count "$src")"

  local i name port domain raw_hm has_metrics severity
  for (( i = 0; i < count; i++ )); do
    name="$(get_service_field "$src" "$i" name)"
    port="$(get_service_field "$src" "$i" port)"
    domain="$(get_service_field "$src" "$i" domain)"
    raw_hm="$(get_service_field "$src" "$i" has_metrics)"
    if [[ "$raw_hm" == "null" || -z "$raw_hm" ]]; then
      has_metrics="true"
    else
      has_metrics="$raw_hm"
    fi
    severity="$(severity_for "$name")"
    emit_service "$tmp_out" "$env_name" "$name" "$port" "$domain" "$has_metrics" "$services_base_dir" "$severity"
  done

  {
    printf 'environment:\n'
    printf '  name: %s\n' "$env_name"
    printf '  services_base_dir: %s\n' "$services_base_dir"
    printf '  log_dir: %s/logs\n' "$services_base_dir"
    printf '  loki_url: http://127.0.0.1:%s\n' "$loki_port"
    printf '  prometheus_url: http://127.0.0.1:%s\n' "$prometheus_port"
    printf '  grafana_url: http://127.0.0.1:%s\n' "$grafana_port"
    printf '  alertmanager_url: http://127.0.0.1:%s\n' "$ALERTMANAGER_PORT"
    printf '  promtail_container: %s\n' "$PROMTAIL_CONTAINER"
    printf '  monitoring_dir: %s\n' "$monitoring_dir"
  } >> "$tmp_out"

  mv -f "$tmp_out" "$out"
  log INFO "Generated ${out} (${count} services)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  detect_yaml_tool
  generate_inventory qa "$SRC_QA" "$OUT_QA"
  generate_inventory prod "$SRC_PROD" "$OUT_PROD"
  log INFO "Inventory generation complete."
}

main "$@"
