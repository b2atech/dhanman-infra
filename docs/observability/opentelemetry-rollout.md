# OpenTelemetry Rollout — QA → Prod

Living tracker for adding distributed tracing (OpenTelemetry → Grafana Tempo) to all Dhanman .NET services.
Goal: agentic error analysis — follow one request across services, RabbitMQ/MassTransit hops and SQL, and jump between traces ↔ logs (Loki) ↔ metrics (Prometheus).

Supersedes `docs/telemetry-server-setup.md` and `docs/telemetry-dotnet-changes.md` (May 2026 drafts, never executed; they targeted the old prod IP 57.129.74.139 and had a self-looping Prometheus `remote_write`).

## Status

| Step | QA (54.37.159.71) | Prod (51.79.156.217) |
|------|-------------------|----------------------|
| 0. Disk headroom (Prometheus WAL fix) | ✅ 2026-10-20 — 91% → 63% | ⬜ check `du -sh /opt/monitoring/prometheus*` first |
| 1. Prometheus accepts remote write | ✅ 2026-10-20 | ⬜ |
| 2. Tempo running | ✅ 2026-10-20 — `grafana/tempo:2.8.2`, 72h retention | ⬜ (suggest 7–14d) |
| 3. Grafana Tempo datasource | ✅ 2026-10-20 — provisioned from file | ⬜ (prod Loki/Prometheus UIDs differ) |
| 4. `AddDhanmanTelemetry()` in `B2aTech.CrossCuttingConcern` 1.9.0 | ✅ 2026-10-20 published to nuget.org (Trusted Publishing) | (same package) |
| 5. All 11 services bumped to 1.9.0 + one-line call | ✅ 2026-10-20 merged to `main` in all 11 repos; `Enabled: true` only in `appsettings.qa.json` | ⬜ add `OpenTelemetry:Enabled=true` to prod config once Tempo is up |
| 6. Deployed via Jenkins, traces visible in Tempo | ✅ 2026-10-21 all 11 services live on new releases and present in Tempo | ⬜ |
| 6b. Drop parentless Npgsql spans (outbox polling noise, ~96% of traces) | ✅ 2026-10-21 library 1.9.1; all 11 services bumped and live | (same package) |
| 6c. Grafana dashboard "Dhanman — Service Tracing" (folder Dhanman, uid `dhanman-service-tracing`) | ✅ 2026-10-21 provisioned from file | ⬜ (prod datasource UIDs differ) |
| 7. Loki derived field `TraceId` → Tempo (log line → trace click) | ⬜ | ⬜ |
| 8. Ansible role (replace manual steps) | ⬜ | ⬜ |

## Library: `B2aTech.CrossCuttingConcern` 1.9.0 (`b2a-framework` repo)

- `src/B2aTech.CrossCuttingConcern/Telemetry/` — `builder.AddDhanmanTelemetry("dhanman-<svc>")` + `DhanmanTelemetryOptions`.
- **Off by default** — a service does nothing until config `OpenTelemetry:Enabled=true`. Safe to deploy the package bump to prod before Tempo exists there.
- Config section `OpenTelemetry`: `Enabled`, `ServiceName` (override), `OtlpEndpoint` (default: OTLP exporter default / `OTEL_EXPORTER_OTLP_ENDPOINT`), `SamplingRatio` (default 1.0, parent-based), `ExcludedPaths` (default `/health`, `/metrics`, `/swagger`).
- Traces: ASP.NET Core (exceptions recorded), HttpClient, Npgsql (`AddSource("Npgsql")` — Npgsql.OpenTelemetry 10 needs Npgsql 10), MassTransit (built-in source), and any `ActivitySource("Dhanman.*")` for custom spans.
- Span tags from headers: `dhanman.organization_id` (`x-organization-id`), `dhanman.correlation_id` (`correlation-id`) — search traces by org in Tempo.
- OpenTelemetry 1.20.0 (latest stable on 2026-10-20). Pulls `System.Diagnostics.DiagnosticSource` 10.0.0 — fine on net9.
- Logs ↔ traces: Serilog 4 puts `TraceId`/`SpanId` on every event; all services log with `JsonFormatter` to `/var/www/qa/logs/*.log` → Promtail → Loki, so the trace ID is already in each log line (covered by a unit test).
- Pre-existing: 12 `DynamicPermissionHandlerTests` fail on `main` (NRE in test ctor, line 44) — unrelated.

| Service | Repo | Was on | Note |
|---------|------|--------|------|
| dhanman-common | dhanman-common | 1.8.7 (CPM) | |
| dhanman-sales | dhanman-sales | 1.8.7 | |
| dhanman-purchase | dhanman-purchase | 1.8.7 | |
| dhanman-inventory | dhanman-inventory | 1.8.7 | |
| dhanman-payroll | dhanman-payroll | 1.8.4 | |
| dhanman-payment | dhanman-payment | **1.8.0** | also picks up 1.8.x changes: email queue, cache clear-all, **M2M tokens bypass permission checks** |
| dhanman-community | dhanman-myhome | 1.8.7 | |
| dhanman-document | dhanman-documents | **1.8.0** | same 1.8.x note as payment |
| dhanman-agent | dhanman-agent | 1.8.6 | |
| dhanman-aggregator | dhanman-aggregator | 1.8.7 | |
| dhanman-einvoice | dhanman-eInvoice | — (new) | console-only logs; new `appsettings.qa.json` |

`Domain.Core` / migration projects pinned to 1.0.5 / 1.7.2 were left as-is (the API's 1.9.0 wins at runtime).

## QA verification (2026-10-20)

- Tempo `service.name` values present for all deployed services; request spans carry `dhanman.organization_id` when the header is sent.
- Log ↔ trace: every JSON log line has `TraceId`/`SpanId`; a real request's `TraceId` resolves in Tempo (`/api/traces/<id>` → 200). Log lines from `/metrics` scrapes also carry a `TraceId` but have no trace — expected, `/health`, `/metrics`, `/swagger` are filtered.
- Noise: outbox pollers (`SELECT … FROM party_delete_outbox … FOR UPDATE SKIP LOCKED`, every ~10s per service) create a root trace each — 124 of 134 traces in a 5-min window. Fix planned in 1.9.1: drop Npgsql spans that have no parent.

## Publishing the library

- `b2a-framework/.github/workflows/nuget-publish.yml` uses nuget.org **Trusted Publishing** (policy `b2a.tec.publshing`, owner `b2atech`, globs `B2aTech.*`). No API key to expire. Secret `NUGET_USER=b2atech`.
- Publish: push a `vX.Y.Z` tag, or `gh workflow run nuget-publish.yml --repo b2atech/b2a-framework --ref main -f version=X.Y.Z`.
- nuget.org shows a new version on the website immediately but restores 404 until indexing finishes (~10–20 min). Wait for `https://api.nuget.org/v3-flatcontainer/b2atech.crosscuttingconcern/<ver>/b2atech.crosscuttingconcern.<ver>.nupkg` to return 200 before merging services.
- The old `NUGET_API_KEY` secret is unused (expired) — can be deleted.

## Jenkins (QA auto-deploy)

- Jenkins: dm-prd-n 57.129.74.139:9081, public via nginx at https://jenkins.dgtula.com (⚠️ open to internet behind Jenkins login; UFW 9081 DENY is bypassed by nginx). WireGuard (`wg0`, 10.10.0.0/24) only allows 22 and 8090.
- Multibranch jobs; a push to `main` deploys to QA via GitHub webhook (multibranch webhook trigger; URL and per-job token in Jenkins). Fallback periodic scan is once a day.
- Broken as of 2026-10-20: `dhanman-payment`, `dhanman-eInvoice` webhooks point at dead `jenkins.dhanman.com`; `dhanman-agent`, `dhanman-aggregator` have no webhook. Fix tracked in b2atech/dhanman-infra#6.
- Prod deploy is never automatic — needs `DEPLOY_PROD=true` on the job.

## QA ports (verified)

5200 common · 5201 sales · 5202 purchase · 5203 payroll · 5204 inventory · 5205 community · 5206 payment · 5207 document · 5208 agent · 5209 einvoice · 5210 aggregator. (Prometheus failures: 5208 agent `/metrics` 404, 5209 einvoice `/metrics` 401.)

## Follow-ups (separate from tracing)

- **.NET 9 → .NET 10 (LTS, supported to Nov 2028).** .NET 9 (STS) support ends Nov 2026. Plan as its own change across all services + this library.
- Central package management (`Directory.Packages.props`) in every repo — only `dhanman-common` has it; would stop the 1.8.0–1.8.7 drift.
- Fix Prometheus scrape: agent `:5208/metrics` 404 (no prometheus endpoint), einvoice `:5209/metrics` 401.

## Architecture

```
.NET service (host, systemd) ──OTLP gRPC 127.0.0.1:4317──► Tempo (Docker, loki-stack)
                                                            │  metrics_generator (service graph, span metrics)
                                                            └──remote_write──► Prometheus :9090 (host network)
Grafana ──► Tempo :3200 / Loki :3100 / Prometheus :9090   (traces ↔ logs ↔ metrics)
```

- No separate OTel Collector for now — services export straight to Tempo. Add a collector later only if we need tail sampling or multiple backends.
- OTLP ports are bound to `127.0.0.1` only (services run on the host). Nothing new exposed publicly.
- RabbitMQ: all services use MassTransit 8.5.x, which has a built-in ActivitySource — `.AddSource("MassTransit")` gives publish/consume spans with context propagated through message headers. No extra package.

## QA — what was done (2026-10-20)

### Step 0 — Disk (Prometheus WAL)
Root cause: Prometheus WAL stopped truncating on 2026-08-21 → 722 segments, 19 GB in `/opt/prometheus/data/wal`.

```bash
cd /opt/prometheus
sudo cp docker-compose.yml docker-compose.yml.bak-20261020
# flags now: --storage.tsdb.retention.time=2d --storage.tsdb.retention.size=2GB --web.enable-remote-write-receiver
sudo docker compose down && sudo rm -rf data/wal data/chunks_head && sudo docker compose up -d
```
Result: Prometheus data 21 GB → 203 MB. Also stopped + disabled `gayatri-jenkins` (Jenkins moved off QA).

Pre-existing scrape failures (not caused by this): `127.0.0.1:5208/metrics` → 404 (payment), `127.0.0.1:5209/metrics` → 401.

### Steps 1–3 — Tempo + Grafana
Source of truth in this repo: `observability/qa/`

| Repo file | Deployed to (dm-qa) |
|-----------|---------------------|
| `observability/qa/loki-stack/docker-compose.yml` | `~/loki-stack/docker-compose.yml` (backup: `docker-compose.yml.bak-20261020`) |
| `observability/qa/tempo/tempo.yaml` | `~/loki-stack/tempo/tempo.yaml` |
| `observability/qa/tempo/grafana-datasource-tempo.yaml` | `~/loki-stack/grafana-provisioning/datasources/tempo.yaml` |
| `observability/qa/grafana/dashboards-provider.yaml` | `~/loki-stack/grafana-provisioning/dashboards/dhanman.yaml` |
| `observability/qa/grafana/dashboards/service-tracing.json` (generated by `gen_service_tracing_dashboard.py`) | `~/loki-stack/grafana-dashboards/service-tracing.json` (compose backup: `docker-compose.yml.bak-20261021`) |

```bash
cd ~/loki-stack
mkdir -p tempo/data grafana-provisioning/datasources
sudo chown -R 10001:10001 tempo/data          # Tempo runs as uid 10001
sudo docker compose up -d tempo grafana
```

Verify:
```bash
curl -s http://127.0.0.1:3200/ready                       # "ready" (~15s after start)
# push a test span over OTLP/HTTP and fetch it back
curl -X POST http://127.0.0.1:4318/v1/traces -H 'Content-Type: application/json' -d '<otlp json>'
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/traces/<traceId>   # 200
```
Grafana: Explore → **Tempo** → Search.

## Prod — differences to handle

- **Ask Bharat before every prod step** (see repo `CLAUDE.md`).
- Monitoring stack lives in `/opt/monitoring/docker-compose.yml` (not `~/loki-stack`); Grafana at `logs.dhanman.com`.
- Get prod Loki/Prometheus datasource UIDs (Grafana API or `grafana.db`) and put them in the prod datasource file — QA UIDs (`dezxknsiey134c`, `efm1ca74j8oaod`) won't match.
- Prometheus `remote_write` URL from inside the Tempo container depends on prod networking — check whether Prometheus is on the same Docker network (`http://prometheus:9090`) or host network (gateway IP).
- Check the Prometheus WAL size on prod before anything else — same truncation bug may exist.
- Pick retention based on free disk (QA: 72h traces, 2d metrics).

## Gotchas found

- Grafana on QA had datasources created via UI (no provisioning dir). Adding the provisioning mount does not remove them — only adds Tempo.
- `tempo` image runs as uid 10001 — data dir must be chowned or Tempo crash-loops.
- `/ready` returns "Ingester not ready … waiting for 15s" right after start — normal.
- Compose `version:` attribute is obsolete — removed in our tracked file.
