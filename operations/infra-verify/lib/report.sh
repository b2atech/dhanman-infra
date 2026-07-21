#!/usr/bin/env bash
#
# report.sh — JSON report schema/writer (T6.1), HTML rendering (T6.2), a
# redaction tripwire scanner (T6.3), and email delivery (T6.4, Phase 10.1).
# This is a LIBRARY: source it, do not execute it directly.
#
# T6.4 note: report_send_email() is the only function in this file that
# touches SMTP. It assumes msmtp is already installed and configured via
# /root/.msmtprc (rendered by the infra_verify Ansible role from Vault
# credentials, Phase 7). It re-runs the T6.3 tripwire on the outgoing HTML
# body before sending, as defense in depth on top of report_render_html's
# own escaping. Email delivery is always best-effort: a send failure is
# logged but never fails the run or blocks the report from being written
# to history — see report_send_email's own comment for the rationale.
#
# report_build operates on the CURRENT run's $RESULT_FILE (set by
# result_init, populated by any number of result_add calls from any check
# family — they all share one file per run by design), matching the
# existing result_summary() convention. It does NOT replace
# result_summary(); it adds the severity-weighted overall_status rollup
# that result_summary() does not compute.
#
# JSON REPORT SCHEMA (T6.1):
#   {
#     "run_id": string,
#     "env": string,
#     "ts": string (ISO8601 UTC),
#     "overall_status": "HEALTHY" | "WARNING" | "CRITICAL",
#     "critical_severity_breach": bool,
#     "total": int, "healthy": int, "warning": int, "critical": int,
#     "unknown": int, "not_applicable": int, "not_configured": int,
#     "issues": [ <result objects with status not in HEALTHY/
#                  NOT_APPLICABLE/NOT_CONFIGURED> ],
#     "results": [ <every result object for this run> ]
#   }
#
# OVERALL STATUS ROLLUP — worst-of, no averaging, per
# COO-Infra-Verification-Plan.md section 9.9:
#   1. Any CRITICAL on a service whose inventory severity is "critical"
#      -> CRITICAL (critical_severity_breach = true)
#   2. Else any CRITICAL at all -> CRITICAL
#   3. Else any WARNING -> WARNING
#   4. Else >=1 UNKNOWN "on a critical path" -> WARNING
#   5. Else -> HEALTHY
# "Critical path" (step 4) is a judgment call, not a literal spec value —
# the brief does not define it precisely. This implementation treats
# UNKNOWN as critical-path when it lands on a severity:critical inventory
# service, OR on one of the top-level readiness checks whose own failure
# would blind the report to everything downstream (SVC-01, PT-01, LK-01,
# PM-01, GF-01). Documented here so the interpretation is auditable.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "report.sh is a library — source it, do not execute it directly." >&2
  exit 1
fi

if [[ -n "${_REPORT_SH_LOADED:-}" ]]; then
  return 0
fi
_REPORT_SH_LOADED=1

_REPORT_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly _REPORT_SCRIPT_DIR
REPORT_CONFIG_DIR="$(realpath -m "${_REPORT_SCRIPT_DIR}/../config")"
readonly REPORT_CONFIG_DIR

# shellcheck source=SCRIPTDIR/result.sh
source "${_REPORT_SCRIPT_DIR}/result.sh"

readonly _REPORT_CRITICAL_PATH_CHECK_IDS="SVC-01 PT-01 LK-01 PM-01 GF-01"

# ---------------------------------------------------------------------------
# Severity map loading — bulk-reads the whole inventory file at once
# (unlike the check families' per-field yq/python3 lookups, report.sh
# needs the full name->severity mapping in one shot, so it uses
# python3+PyYAML directly rather than the dual yq/python3 pattern; python3
# is already a hard dependency of this toolkit — see config/generate-
# inventory.sh — so this adds nothing new).
# ---------------------------------------------------------------------------
read -r -d '' _REPORT_SEVERITY_MAP_PY <<'PYEOF' || true
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

out = {}
for svc in data.get("services", []) or []:
    name = svc.get("name")
    severity = svc.get("severity")
    if name:
        out[name] = severity

print(json.dumps(out))
PYEOF

_report_severity_map_json() {
  local env="$1"
  local inventory_file="${REPORT_CONFIG_DIR}/inventory.${env}.yaml"

  if [[ ! -f "$inventory_file" ]]; then
    printf '{}'
    return 0
  fi

  python3 -c "$_REPORT_SEVERITY_MAP_PY" "$inventory_file" 2>/dev/null || printf '{}'
}

# ---------------------------------------------------------------------------
# _REPORT_BUILD_PY: argv = run_id, env, result_file, severity_map_json,
# critical_path_check_ids (space-separated). Implements the rollup
# algorithm documented above and prints the full report JSON.
# ---------------------------------------------------------------------------
read -r -d '' _REPORT_BUILD_PY <<'PYEOF' || true
import json
import sys
from datetime import datetime, timezone

run_id, env, result_file, severity_map_json, critical_path_ids_raw = sys.argv[1:6]

try:
    severity_map = json.loads(severity_map_json)
except Exception:
    severity_map = {}

critical_path_check_ids = set(critical_path_ids_raw.split())

counts = {
    "HEALTHY": 0, "WARNING": 0, "CRITICAL": 0, "UNKNOWN": 0,
    "NOT_APPLICABLE": 0, "NOT_CONFIGURED": 0,
}
results = []
critical_severity_breach = False
unknown_on_critical_path = False

with open(result_file, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        results.append(obj)
        status = obj.get("status", "UNKNOWN")
        if status in counts:
            counts[status] += 1
        else:
            counts["UNKNOWN"] += 1

        target = obj.get("target", "")
        check_id = obj.get("check_id", "")
        svc_severity = severity_map.get(target)

        if status == "CRITICAL" and svc_severity == "critical":
            critical_severity_breach = True

        if status == "UNKNOWN" and (svc_severity == "critical" or check_id in critical_path_check_ids):
            unknown_on_critical_path = True

if critical_severity_breach:
    overall = "CRITICAL"
elif counts["CRITICAL"] > 0:
    overall = "CRITICAL"
elif counts["WARNING"] > 0:
    overall = "WARNING"
elif unknown_on_critical_path:
    overall = "WARNING"
else:
    overall = "HEALTHY"

issues = [r for r in results if r.get("status") not in ("HEALTHY", "NOT_APPLICABLE", "NOT_CONFIGURED")]

report = {
    "run_id": run_id,
    "env": env,
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "overall_status": overall,
    "critical_severity_breach": critical_severity_breach,
    "total": len(results),
    "healthy": counts["HEALTHY"],
    "warning": counts["WARNING"],
    "critical": counts["CRITICAL"],
    "unknown": counts["UNKNOWN"],
    "not_applicable": counts["NOT_APPLICABLE"],
    "not_configured": counts["NOT_CONFIGURED"],
    "issues": issues,
    "results": results,
}
print(json.dumps(report))
PYEOF

# ---------------------------------------------------------------------------
# report_build — prints the report JSON for the current run to stdout.
# ---------------------------------------------------------------------------
report_build() {
  if [[ -z "${RESULT_FILE:-}" || ! -f "$RESULT_FILE" ]]; then
    _result_log ERROR "report_build: no active RESULT_FILE (call result_init first)"
    printf '{}'
    return 1
  fi

  local severity_map
  severity_map="$(_report_severity_map_json "$RESULT_ENV")"

  python3 -c "$_REPORT_BUILD_PY" "$RESULT_RUN_ID" "$RESULT_ENV" "$RESULT_FILE" "$severity_map" "$_REPORT_CRITICAL_PATH_CHECK_IDS"
}

# ---------------------------------------------------------------------------
# _REPORT_HTML_PY: argv[1] = report JSON (as produced by report_build).
# Every interpolated value is passed through html.escape() — Python's
# standard-library escaper, chosen deliberately over hand-rolled bash
# string replacement after result.sh's own earlier lesson: bash's
# ${var//pat/repl} treats an unescaped & in the replacement specially
# (sed-like), which silently corrupted redact()'s HTML entities until
# that was caught and fixed. html.escape() has no such footgun.
#
# Defense-in-depth note: fields that already passed through redact()
# (e.g. a target's evidence embedding a sanitized scrapeUrl) are
# HTML-escaped a second time here. This can cosmetically double-escape
# ("&amp;" -> "&amp;amp;") for that specific sub-string, but never
# under-escapes — every field is treated as untrusted at render time,
# regardless of what happened upstream. Correctness of display beats
# safety here, deliberately.
# ---------------------------------------------------------------------------
read -r -d '' _REPORT_HTML_PY <<'PYEOF' || true
import json
import sys
from html import escape


def esc(value):
    return escape(str(value), quote=True)


report = json.loads(sys.argv[1])

run_id = esc(report.get("run_id", ""))
env = esc(report.get("env", ""))
ts = esc(report.get("ts", ""))
overall_status_raw = report.get("overall_status", "UNKNOWN")
overall = esc(overall_status_raw)
total = int(report.get("total", 0) or 0)
healthy = int(report.get("healthy", 0) or 0)
warning = int(report.get("warning", 0) or 0)
critical = int(report.get("critical", 0) or 0)
unknown = int(report.get("unknown", 0) or 0)
not_applicable = int(report.get("not_applicable", 0) or 0)
issues = report.get("issues", []) or []

status_colors = {
    "HEALTHY": "#2e7d32",
    "WARNING": "#f9a825",
    "CRITICAL": "#c62828",
    "UNKNOWN": "#616161",
}
overall_color = status_colors.get(overall_status_raw, "#616161")

rows = []
for issue in issues:
    check_id = esc(issue.get("check_id", ""))
    target = esc(issue.get("target", ""))
    issue_status_raw = issue.get("status", "")
    issue_status = esc(issue_status_raw)
    evidence = esc(issue.get("evidence", ""))
    layer = esc(issue.get("likely_layer", "none"))
    repair = esc(issue.get("recommended_repair", "none"))
    color = status_colors.get(issue_status_raw, "#616161")
    rows.append(
        "<tr><td>{0}</td><td>{1}</td>"
        '<td style="color:{5};font-weight:bold">{2}</td>'
        "<td>{3}</td><td>{4}</td><td>{6}</td></tr>".format(
            check_id, target, issue_status, evidence, layer, color, repair
        )
    )

rows_html = "\n".join(rows) if rows else '<tr><td colspan="6">No issues — all checks passing.</td></tr>'

html_doc = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>DhanMan Infra Report — {env} — {ts}</title>
<style>
  body {{ font-family: -apple-system, "Segoe UI", Arial, sans-serif; margin: 2em; color: #222; }}
  h1 {{ font-size: 1.3em; }}
  .summary {{ margin-bottom: 1.5em; }}
  .badge {{ display: inline-block; padding: 0.2em 0.6em; border-radius: 4px; color: #fff; font-weight: bold; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ border: 1px solid #ccc; padding: 0.4em 0.6em; text-align: left; font-size: 0.9em; }}
  th {{ background: #f2f2f2; }}
</style>
</head>
<body>
<h1>DhanMan Infrastructure Report — {env}</h1>
<div class="summary">
  <p>Run: {run_id} &middot; Generated: {ts}</p>
  <p>Overall: <span class="badge" style="background:{overall_color}">{overall}</span></p>
  <p>Total checks: {total} &middot; Healthy: {healthy} &middot; Warning: {warning} &middot;
     Critical: {critical} &middot; Unknown: {unknown} &middot; Not applicable: {not_applicable}</p>
</div>
<h2>Issues ({issue_count})</h2>
<table>
<thead><tr><th>Check</th><th>Target</th><th>Status</th><th>Evidence</th><th>Likely layer</th><th>Recommended repair</th></tr></thead>
<tbody>
{rows_html}
</tbody>
</table>
</body>
</html>
""".format(
    env=env, ts=ts, run_id=run_id, overall=overall, overall_color=overall_color,
    total=total, healthy=healthy, warning=warning, critical=critical,
    unknown=unknown, not_applicable=not_applicable, issue_count=len(issues),
    rows_html=rows_html,
)

print(html_doc)
PYEOF

# ---------------------------------------------------------------------------
# report_render_html <report_json> — prints an HTML document to stdout.
# ---------------------------------------------------------------------------
report_render_html() {
  local report_json="$1"
  python3 -c "$_REPORT_HTML_PY" "$report_json"
}

# ---------------------------------------------------------------------------
# report_scan_for_secrets <text>
#
# T6.3 tripwire: a pure DETECTOR (never modifies text) that checks each
# line against the same credential patterns redact() uses (shared
# constant, see lib/result.sh), plus PEM block markers. This is
# deliberately separate from redact() itself — redact() always mutates
# its input (HTML-escaping and truncating even clean lines), so comparing
# its output against the original input is not a reliable way to detect
# "a credential was here"; this function checks for genuine pattern
# matches only, with no side effects.
# Prints "CLEAN" and returns 0 if nothing matched; prints "FOUND: <reason>"
# and returns 1 on the first match (fail-fast — this is a CI gate, not a
# full audit report).
# ---------------------------------------------------------------------------
report_scan_for_secrets() {
  local text="$1"
  local in_pem=false
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$in_pem" == true ]]; then
      printf 'FOUND: PEM block content'
      return 1
    fi
    if [[ "$line" == *"-----BEGIN"* ]]; then
      printf 'FOUND: PEM block header'
      return 1
    fi
    local pat
    for pat in "${_RESULT_CREDENTIAL_PATTERNS[@]}"; do
      if [[ "$line" =~ $pat ]]; then
        printf 'FOUND: credential-shaped pattern'
        return 1
      fi
    done
  done <<< "$text"

  printf 'CLEAN'
  return 0
}

# ---------------------------------------------------------------------------
# report_send_email <env> <overall_status> <report_html_file> <recipients_csv>
#
# T6.4: emails the rendered HTML report via msmtp. Requires msmtp to be
# installed and /root/.msmtprc already configured (infra_verify Ansible
# role, Phase 7) — this function only sends, it never touches credentials
# or SMTP config itself.
#
# Runs report_scan_for_secrets on the outgoing body as defense in depth
# before sending, even though report_render_html already HTML-escapes
# everything: this is a second, independent gate on the exact bytes about
# to leave the host, not a re-check of the same escaping pass.
#
# Email delivery is always best-effort: recipients_csv empty is not an
# error (nothing configured yet), and a send failure is logged and
# returned as a non-zero exit but never treated as fatal by the caller —
# the report is already written to history by the time this runs, and a
# broken mail relay must not turn a HEALTHY/WARNING run into a failed one.
# ---------------------------------------------------------------------------
report_send_email() {
  local env="$1"
  local overall_status="$2"
  local report_html_file="$3"
  local recipients_csv="$4"

  if [[ -z "$recipients_csv" ]]; then
    _result_log INFO "report_send_email: no recipients configured, skipping"
    return 0
  fi

  if ! command -v msmtp >/dev/null 2>&1; then
    _result_log ERROR "report_send_email: msmtp not found, cannot send report email"
    return 1
  fi

  if [[ ! -f "$report_html_file" ]]; then
    _result_log ERROR "report_send_email: HTML report file not found: ${report_html_file}"
    return 1
  fi

  local html_body
  html_body="$(cat -- "$report_html_file")"

  local secret_scan
  secret_scan="$(report_scan_for_secrets "$html_body")"
  if [[ "$secret_scan" != CLEAN* ]]; then
    _result_log ERROR "report_send_email: ABORTED — secret-scan tripwire fired on report body (${secret_scan}); not sending"
    return 1
  fi

  local -a recipients=()
  IFS=',' read -r -a recipients <<< "$recipients_csv"

  if [[ ${#recipients[@]} -eq 0 ]]; then
    _result_log INFO "report_send_email: recipients_csv parsed to zero addresses, skipping"
    return 0
  fi

  local rc=0
  {
    printf 'To: %s\n' "$recipients_csv"
    printf 'Subject: DhanMan Infra Report [%s] %s\n' "$env" "$overall_status"
    printf 'Content-Type: text/html; charset=UTF-8\n'
    printf '\n'
    printf '%s' "$html_body"
  } | msmtp -a default -- "${recipients[@]}" || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    _result_log INFO "report_send_email: sent to ${recipients_csv}"
  else
    _result_log ERROR "report_send_email: msmtp failed (exit=${rc})"
  fi

  return "$rc"
}
