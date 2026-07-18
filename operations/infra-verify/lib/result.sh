#!/usr/bin/env bash
#
# result.sh — shared result model for infra-verify checks.
# This is a LIBRARY: source it, do not execute it directly.
#
# JSON objects are built and parsed via python3 rather than hand-rolled
# bash string concatenation. Hand-rolled JSON escaping is a well-known
# source of injection/corruption bugs (unescaped quotes, backslashes,
# control characters in evidence strings or journal lines); python3's
# json module guarantees a structurally valid, correctly escaped result
# every time. python3 is already a required dependency of this toolkit
# (see operations/infra-verify/config/generate-inventory.sh) and of
# Ansible itself, so this adds no new dependency.

# Guard against being executed instead of sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "result.sh is a library — source it, do not execute it directly." >&2
  exit 1
fi

# Include guard — safe to source this file more than once (e.g. once
# directly and once transitively via checks/services.sh).
if [[ -n "${_RESULT_SH_LOADED:-}" ]]; then
  return 0
fi
_RESULT_SH_LOADED=1

RESULT_FILE=""
RESULT_RUN_ID=""
RESULT_ENV=""

readonly _RESULT_VALID_STATUSES=(HEALTHY WARNING CRITICAL UNKNOWN NOT_CONFIGURED NOT_APPLICABLE)

# ---------------------------------------------------------------------------
# Internal logging (self-contained — does not assume a caller-provided log())
# ---------------------------------------------------------------------------
_result_log() {
  local level="$1"
  shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s [%s] %s\n' "$ts" "$level" "$*" >&2
}

# ---------------------------------------------------------------------------
# Embedded python3 helpers (kept inline so result.sh remains a single file)
# ---------------------------------------------------------------------------
read -r -d '' _RESULT_JSON_PY <<'PYEOF' || true
import json
import sys

(check_id, target, status, evidence, layer, repair,
 ts, latency_ms, has_journal, captured, redacted) = sys.argv[1:12]
journal_lines = sys.argv[12:]

obj = {
    "check_id": check_id,
    "target": target,
    "status": status,
    "evidence": evidence,
    "likely_layer": layer,
    "recommended_repair": repair,
    "ts": ts,
    "latency_ms": int(latency_ms),
}

if has_journal == "1":
    obj["journal_tail"] = journal_lines
    obj["journal_lines_captured"] = int(captured)
    obj["journal_lines_redacted"] = int(redacted)

print(json.dumps(obj))
PYEOF

read -r -d '' _RESULT_SUMMARY_PY <<'PYEOF' || true
import json
import sys
from datetime import datetime, timezone

run_id, env, result_file = sys.argv[1], sys.argv[2], sys.argv[3]

counts = {"HEALTHY": 0, "WARNING": 0, "CRITICAL": 0, "UNKNOWN": 0, "NOT_APPLICABLE": 0}
results = []

with open(result_file, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        results.append(obj)
        status = obj.get("status")
        if status in counts:
            counts[status] += 1

summary = {
    "run_id": run_id,
    "env": env,
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "total": len(results),
    "healthy": counts["HEALTHY"],
    "warning": counts["WARNING"],
    "critical": counts["CRITICAL"],
    "unknown": counts["UNKNOWN"],
    "not_applicable": counts["NOT_APPLICABLE"],
    "results": results,
}
print(json.dumps(summary))
PYEOF

# ---------------------------------------------------------------------------
# result_init <run_id> <env>
# ---------------------------------------------------------------------------
result_init() {
  RESULT_RUN_ID="$1"
  RESULT_ENV="$2"
  RESULT_FILE="$(mktemp "${TMPDIR:-/tmp}/infra-verify-results.XXXXXX")"
  : > "$RESULT_FILE"
}

# ---------------------------------------------------------------------------
# Status validation — substitutes UNKNOWN (with a warning) for anything
# outside the fixed status vocabulary.
# ---------------------------------------------------------------------------
_result_normalize_status() {
  local status="$1"
  local candidate
  for candidate in "${_RESULT_VALID_STATUSES[@]}"; do
    if [[ "$status" == "$candidate" ]]; then
      printf '%s' "$status"
      return 0
    fi
  done
  _result_log WARN "Invalid status '${status}' — substituting UNKNOWN"
  printf 'UNKNOWN'
}

# ---------------------------------------------------------------------------
# Shared JSON writer. has_journal must be "0" or "1".
# ---------------------------------------------------------------------------
_result_write() {
  local check_id="$1" target="$2" status="$3" evidence="$4" layer="$5" repair="$6"
  local has_journal="$7" captured="$8" redacted="$9"
  shift 9
  local -a journal_lines=("$@")

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  python3 -c "$_RESULT_JSON_PY" \
    "$check_id" "$target" "$status" "$evidence" "$layer" "$repair" \
    "$ts" "0" "$has_journal" "$captured" "$redacted" \
    "${journal_lines[@]}" >> "$RESULT_FILE"
}

# ---------------------------------------------------------------------------
# result_add <check_id> <target> <status> <evidence> <layer> <repair>
# ---------------------------------------------------------------------------
result_add() {
  local check_id="$1" target="$2" status="$3" evidence="$4" layer="$5" repair="$6"
  status="$(_result_normalize_status "$status")"
  _result_write "$check_id" "$target" "$status" "$evidence" "$layer" "$repair" "0" "0" "0"
}

# ---------------------------------------------------------------------------
# result_add_with_journal <check_id> <target> <status> <evidence> <layer>
#                          <repair> <unit>
#
# journalctl requires the invoking user to be a member of the
# systemd-journal group. That group membership is provisioned by the
# Ansible infra_verify role (Phase 7) — not implemented or enforced here.
# ---------------------------------------------------------------------------
result_add_with_journal() {
  local check_id="$1" target="$2" status="$3" evidence="$4" layer="$5" repair="$6" unit="$7"

  status="$(_result_normalize_status "$status")"

  if [[ "$status" != "CRITICAL" ]]; then
    result_add "$check_id" "$target" "$status" "$evidence" "$layer" "$repair"
    return 0
  fi

  local raw_journal
  raw_journal="$(journalctl -u "$unit" -n 50 --no-pager --output=short-iso 2>/dev/null || true)"

  local redacted_text
  redacted_text="$(redact "$raw_journal")"

  local -a journal_lines=()
  local redacted_count=0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    journal_lines+=("$line")
    if [[ "$line" == "[REDACTED — possible credential]" ]]; then
      redacted_count=$((redacted_count + 1))
    fi
  done <<< "$redacted_text"

  local captured_count="${#journal_lines[@]}"

  _result_write "$check_id" "$target" "$status" "$evidence" "$layer" "$repair" \
    "1" "$captured_count" "$redacted_count" "${journal_lines[@]}"
}

# ---------------------------------------------------------------------------
# redact <text>
#
# Line-based redaction: any line matching a credential pattern is replaced
# in full with the marker below (not just the matched substring). PEM
# blocks are tracked across lines (BEGIN..END) so the whole block is
# redacted, not just the boundary markers. Every line is then HTML-escaped
# and truncated to 500 characters.
# ---------------------------------------------------------------------------
redact() {
  local input="$1"
  local -a patterns=(
    '([Pp]assword|[Pp]wd|[Ss]ecret|[Tt]oken)[[:space:]]*=[^[:space:]]+'
    '[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]+'
    '[a-zA-Z][a-zA-Z0-9+.-]*://[^/@[:space:]]+:[^/@[:space:]]+@'
  )
  local marker="[REDACTED — possible credential]"
  local in_pem=false
  local out=""
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    local redacted_line="$line"
    local matched=false

    if [[ "$in_pem" == true ]]; then
      matched=true
      if [[ "$line" == *"-----END"* ]]; then
        in_pem=false
      fi
    elif [[ "$line" == *"-----BEGIN"* ]]; then
      matched=true
      in_pem=true
      if [[ "$line" == *"-----END"* ]]; then
        in_pem=false
      fi
    else
      local pat
      for pat in "${patterns[@]}"; do
        if [[ "$line" =~ $pat ]]; then
          matched=true
          break
        fi
      done
    fi

    if [[ "$matched" == true ]]; then
      redacted_line="$marker"
    fi

    # NOTE: the replacement side of ${var//pat/repl} treats a literal
    # unescaped & specially (similar to sed) — it must be written \& or
    # the inserted "&amp;"/"&lt;"/"&gt;"/"&quot;" text gets corrupted.
    redacted_line="${redacted_line//&/\&amp;}"
    redacted_line="${redacted_line//</\&lt;}"
    redacted_line="${redacted_line//>/\&gt;}"
    redacted_line="${redacted_line//\"/\&quot;}"

    if [[ ${#redacted_line} -gt 500 ]]; then
      redacted_line="${redacted_line:0:500}"
    fi

    out+="${redacted_line}"$'\n'
  done <<< "$input"

  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# result_summary — prints the aggregate JSON summary to stdout
# ---------------------------------------------------------------------------
result_summary() {
  python3 -c "$_RESULT_SUMMARY_PY" "$RESULT_RUN_ID" "$RESULT_ENV" "$RESULT_FILE"
}
