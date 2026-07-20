# Local Test Guide — infra-verify Engine

**Status of this guide:** written 2026-07-18, against commit `f559f15`
(Phase 6 complete: SVC/HLT/LOG/PT/LK/PM/GF check families + JSON/HTML
report renderers all exist and are unit-tested — 207/207 bats tests
passing. **The entrypoint does not yet call any of them.**)

---

## ⚠️ Read this before running anything

Two things in the original request for this guide don't match the
current code, and I'm not going to write steps that quietly fail when
you follow them. Both are corrected throughout this document.

### 1. The entrypoint is not wired up yet

`operations/infra-verify/bin/run-infra-report.sh`'s `run_checks()`
function currently calls seven **empty no-op stub functions**:

```bash
check_services_stub()   { :; }
check_health_stub()     { :; }
check_logging_stub()    { :; }
check_promtail_stub()   { :; }
check_loki_stub()       { :; }
check_prometheus_stub() { :; }
check_grafana_stub()    { :; }
```

It never sources `checks/services.sh`, `checks/health.sh`,
`checks/logfile.sh`, `checks/promtail.sh`, `checks/loki.sh`,
`checks/prometheus.sh`, `checks/grafana.sh`, or `lib/report.sh`. It
never calls `run_svc_checks`, `run_hlt_checks`, `run_log_checks`,
`run_pt_checks`, `run_loki_checks`, `run_pm_checks`,
`run_grafana_checks`, `report_build`, or `report_render_html`.

**Practical effect:** running `run-infra-report.sh --environment qa`
today logs a start line and a completion line and exits 0. No network
call happens. No file appears in `history/`. This is expected, current
behavior, not a bug to chase — the wiring is a not-yet-built piece
(reasonably, Phase 7's territory, or an explicit wiring task before it).

Steps 1–4 below work exactly as described today. Steps 5 onward are
marked **[BLOCKED]** and describe what will happen once the wiring
exists, so this guide doesn't need a rewrite the day it does.

### 2. This engine only ever talks to `127.0.0.1` — there is no remote mode

Every check module hardcodes localhost:

| Module | Base URL / target |
|---|---|
| `checks/services.sh` (SVC) | `http://127.0.0.1:<service_port>` |
| `checks/health.sh` (HLT) | `http://127.0.0.1:<service_port>/health` |
| `checks/promtail.sh` (PT) | `docker inspect promtail`, `docker exec promtail ...` |
| `checks/loki.sh` (LK) | `http://127.0.0.1:3100` |
| `checks/prometheus.sh` (PM) | `http://127.0.0.1:9090`, `docker inspect prometheus` |
| `checks/grafana.sh` (GF) | `http://127.0.0.1:3000` |

This is deliberate — it matches the master plan's design ("the engine
lives in the repo, is deployed to each host... QA and PROD reports are
generated per host"). There is no `--host`/base-URL override anywhere.

**Practical effect:** even after the wiring exists, running this
engine from your laptop **cannot** reach QA's monitoring stack over the
network at `54.37.159.71` — it will always check your laptop's own
`127.0.0.1:9090` / `:3100` / `:3000`, which have nothing listening.
Network access to `54.37.159.71` is irrelevant to this tool's own HTTP
calls. **The engine only produces meaningful output when it runs ON
the QA (or PROD) host itself.**

Given both of these, "local test" in this guide means: verify tooling,
verify the inventory/config files, verify argument parsing and
dry-run behavior — all of which genuinely run on your own machine
today. The *first point real signal can appear* is an SSH session on
QA, once the wiring exists — which is Part B below, not a separate
later stage.

---

## 1. Overview

This guide covers preflight verification of the infra-verify engine
before it is ever deployed via Ansible (Phase 7). It exists to catch
tooling gaps, inventory drift, and argument-handling bugs on a
developer machine — things that are cheap to catch before touching QA
— and to be honest about what still can't be tested until the
orchestration wiring lands.

**Expected outcome of this guide today:** confidence that the CLI,
argument validation, dry-run path, and generated inventory are all
correct. **Not** a working end-to-end JSON/HTML report from real QA
monitoring — that requires the wiring fix plus an SSH session on QA
(Part B).

---

## 2. Prerequisites

- `bash`, `python3` — **required**. Every check module and
  `lib/result.sh`/`lib/report.sh` use `python3` for all JSON
  parsing/building; `yq` is used where available as a faster
  alternative for YAML reads, with `python3`+PyYAML as the fallback.
- `curl` — required once the wiring exists (every HTTP-based check).
- `docker` — required **only on the host actually running Promtail/
  Loki/Prometheus containers** (i.e., QA or PROD) — not required on
  your local machine for Part A below.
- `jq` — **not** a runtime dependency of any script in this repo (none
  of them call `jq`). Listed here purely as a convenient tool *for you*
  to inspect the JSON report once one exists.
- Git branch `feature/coo-infra-verify` checked out.
- `cd` to the repo root before starting.

---

## 3. Part A — Local Preflight (works today, no QA access needed)

### Step 1: Verify tools are installed

```bash
which bash python3 curl jq
python3 --version
jq --version
```

`docker` isn't needed for this part — skip `docker ps` here; it matters
only once you're on the QA host itself (Part B).

### Step 2: Set up a local test workspace

```bash
mkdir -p ~/dhanman-local-test
cd ~/dhanman-local-test
cp -r <repo>/operations/infra-verify .
ls -la infra-verify/bin/ infra-verify/config/ infra-verify/checks/
```

### Step 3: Verify the inventory was generated (from Phase 1)

```bash
ls -l infra-verify/config/inventory.qa.yaml
head -20 infra-verify/config/inventory.qa.yaml
```

Should show `dhanman-common`, `dhanman-community`, etc. — this file is
already committed and generated; it doesn't require network access or
the orchestration wiring to inspect.

### Step 4: Test the entrypoint

```bash
cd ~/dhanman-local-test
bash infra-verify/bin/run-infra-report.sh --help
bash infra-verify/bin/run-infra-report.sh --environment qa --dry-run
```

`--help` prints usage and exits 0. `--dry-run` logs what it *would* run
and exits 0 — this genuinely works today, since dry-run mode returns
before `run_checks()` (and thus the stubs) is ever reached.

**This is as far as Part A can meaningfully go today.** Everything
past this point needs either the orchestration wiring, or QA itself,
or both.

---

## 4. Part B — First Live Run [BLOCKED until the stub→real-check wiring exists]

Do not attempt this yet. Once `run_checks()` in
`bin/run-infra-report.sh` actually sources `checks/*.sh` + `lib/
report.sh` and calls the real `run_*_checks`/`report_build`/
`report_render_html` functions, this section describes the intended
flow — **run entirely over SSH on the QA host**, not from your laptop:

```bash
ssh ubuntu@54.37.159.71
cd /path/to/dhanman-infra   # or wherever the repo/engine is deployed
bash operations/infra-verify/bin/run-infra-report.sh --environment qa
```

Expected once wired: real HTTP calls to `127.0.0.1:9090` /`:3100`
/`:3000` and `127.0.0.1:<service_port>` **on that host**, real `docker
inspect`/`exec`/`logs` calls against the containers actually running
there, runtime in the tens of seconds, and (once the entrypoint is
updated to call `report_build`/`report_render_html` and write their
output) a JSON and HTML file in `history/`.

**Exit codes:** the master plan's intended mapping is `0`=healthy,
`1`=warning, `2`=critical, `3`=engine failure (§9.10). **This mapping
is not implemented yet either** — currently `run-infra-report.sh` only
ever exits `0` (success), `1` (bad arguments), `75` (lock held), or `3`
(global timeout exceeded); it has no path that inspects
`report_build`'s `overall_status` and translates it to `1`/`2`. This is
part of the same wiring gap as everything else in this section.

### Examining the report — once it exists

The actual JSON schema, from `lib/report.sh`'s `report_build`
(**note the field names — they differ from earlier drafts of this
guide**: `env` not `environment`, `total` not `total_checks`):

```json
{
  "run_id": "...",
  "env": "qa",
  "ts": "2026-...",
  "overall_status": "HEALTHY | WARNING | CRITICAL",
  "critical_severity_breach": true,
  "total": 0, "healthy": 0, "warning": 0, "critical": 0,
  "unknown": 0, "not_applicable": 0, "not_configured": 0,
  "issues": [ "...only non-HEALTHY/NOT_APPLICABLE/NOT_CONFIGURED results..." ],
  "results": [ "...every result object for this run..." ]
}
```

```bash
# Overall shape
jq '.env, .overall_status, .total' infra-verify/history/report-qa-*.json

# Full validation (fails loudly on parse error)
jq . infra-verify/history/report-qa-*.json >/dev/null

# Result count across all seven families
jq '.results | length' infra-verify/history/report-qa-*.json

# HTML sanity check
head -100 infra-verify/history/report-qa-*.html
```

### Secrets check

```bash
grep -iE "password|token|secret" infra-verify/history/report-qa-*.json
grep -iE "password|token|secret" infra-verify/history/report-qa-*.html
```

Both should return nothing. If either matches, that's a real finding —
`lib/report.sh`'s `report_scan_for_secrets` function exists specifically
to catch this class of leak in CI; a manual grep here is the same idea
applied to one real report by hand.

### Per-service / per-family inspection

```bash
jq '.results[] | select(.target == "dhanman-common") | .status' infra-verify/history/report-qa-*.json
jq '.results[] | select(.check_id | startswith("LK")) | .status' infra-verify/history/report-qa-*.json
```

Check-ID prefixes: `SVC-`, `HLT-`, `LOG-`, `PT-`, `LK-`, `PM-`, `GF-`.

---

## 5. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Everything reports connection-refused/CRITICAL, even for QA-hosted checks | You're running from a machine that isn't QA/PROD itself — see the localhost-only note above | Confirm you're SSH'd into `54.37.159.71` and running the command there, not from your laptop |
| `docker: command not found` | Docker isn't installed/running — only matters when you're on QA/PROD | `docker ps` should work on that host; if not, `sudo systemctl start docker` |
| JSON parse errors / corrupted report | A check family crashed, or (currently) the report was never written because the wiring doesn't exist | Confirm the wiring landed; then isolate with `--component services`, `--component logging`, etc. |
| `journalctl` errors / "Operation not permitted" | The invoking user isn't in the `systemd-journal` group | Expected until the Ansible role (Phase 7) provisions this; not blocking — SVC-01's journal capture will just come back empty on CRITICAL services |
| "Grafana Viewer token not configured" | Expected — the token was never created in Vault (Phase 0 gap, still open) | Not blocking; GF-03/04/05 correctly report `NOT_CONFIGURED` |
| `run-infra-report.sh` exits 0 with no report file | **Current expected behavior** — see the wiring gap above | Not a bug to chase locally; this is the thing that needs building |

---

## 6. If a real run (Part B) fails once the wiring exists

Capture:
- Full stdout/stderr from `run-infra-report.sh`
- The JSON report, if one was produced
- `jq . infra-verify/history/report-qa-*.json` output
- `docker ps` output (on the QA host)
- `curl -v http://127.0.0.1:9090/-/ready` (on the QA host — **not** from a laptop, per the localhost note)

---

## 7. Notes

- Everything in this repo's check engine is **read-only** — no
  infrastructure changes, no repair scripts, no `POST` to any
  monitoring write/lifecycle endpoint.
- `history/` is not yet written to by anything — `HISTORY_DIR` is
  computed in `run-infra-report.sh` but nothing calls
  `report_build`/`report_render_html` or persists their output there.
  That wiring, and deciding the exact `report-<env>-<ts>.json` naming
  convention, is outstanding work.
- Once Part B is unblocked and actually running on QA, it's safe to
  re-run repeatedly — nothing in the check engine mutates state.
