# Phase 0 Discovery — COO Infrastructure Verification Project

**Purpose:** Phase 0 discovery output for the COO Infrastructure Verification project. Every statement below is sourced directly from the 14 files listed at the end of this document, read on 2026-07-17 from branch `feature/coo-infra-verify`, plus confirmed follow-up findings from `ansible/roles/dhanman_service/tasks/main.yml` and `ansible/roles/monitoring/templates/loki-config.yml.j2`, and owner-confirmed answers recorded below. No memory, no assumptions beyond what is explicitly labeled as owner-confirmed.

---

## 1. Confirmed Service List

### PROD (`ansible/inventories/prod/group_vars/all/main.yml`)

| Name | Port | Domain | DLL | has_metrics | systemd unit name |
|---|---|---|---|---|---|
| dhanman-common | 5100 | prod.common.dhanman.com | Dhanman.Common.Api.dll | true (default) | dhanman-common-prod.service (confirmed) |
| dhanman-community | 5101 | prod.community.dhanman.com | Dhanman.Community.Api.dll | true (default) | dhanman-community-prod.service (confirmed) |
| dhanman-inventory | 5102 | prod.inventory.dhanman.com | Dhanman.Inventory.Api.dll | true (default) | dhanman-inventory-prod.service (confirmed) |
| dhanman-payroll | 5103 | prod.payroll.dhanman.com | Dhanman.Payroll.Api.dll | true (default) | dhanman-payroll-prod.service (confirmed) |
| dhanman-purchase | 5104 | prod.purchase.dhanman.com | Dhanman.Purchase.Api.dll | true (default) | dhanman-purchase-prod.service (confirmed) |
| dhanman-sales | 5105 | prod.sales.dhanman.com | Dhanman.Sales.Api.dll | true (default) | dhanman-sales-prod.service (confirmed) |
| dhanman-payment | 5106 | payment.dhanman.com | Dhanman.Payment.Api.dll | true (default) | dhanman-payment-prod.service (confirmed) |
| dhanman-document | 5107 | prod.document.dhanman.com | Dhanman.Document.dll | true (default) | dhanman-document-prod.service (confirmed) |
| dhanman-agent | 5108 | prod.agent.dhanman.com | Dhanman.Agent.API.dll | **false** | dhanman-agent-prod.service (confirmed) |
| dhanman-einvoice | 5109 | prod.einvoice.dhanman.com | Dhanman.EInvoice.Api.dll | true (default) | dhanman-einvoice-prod.service (confirmed) |

### QA (`ansible/inventories/qa/group_vars/all/main.yml`)

| Name | Port | Domain | DLL | has_metrics | systemd unit name |
|---|---|---|---|---|---|
| dhanman-common | 5200 | qa.common.dhanman.com | Dhanman.Common.Api.dll | true (default) | dhanman-common-qa.service (confirmed) |
| dhanman-community | 5205 | qa.community.dhanman.com | **Dhanman.MyHome.Api.dll** | true (default) | dhanman-community-qa.service (confirmed) |
| dhanman-inventory | 5204 | qa.inventory.dhanman.com | Dhanman.Inventory.Api.dll | true (default) | dhanman-inventory-qa.service (confirmed) |
| dhanman-payroll | 5203 | qa.payroll.dhanman.com | Dhanman.Payroll.Api.dll | true (default) | dhanman-payroll-qa.service (confirmed) |
| dhanman-purchase | 5202 | qa.purchase.dhanman.com | Dhanman.Purchase.Api.dll | true (default) | dhanman-purchase-qa.service (confirmed) |
| dhanman-sales | 5201 | qa.sales.dhanman.com | Dhanman.Sales.Api.dll | true (default) | dhanman-sales-qa.service (confirmed) |
| dhanman-payment | 5206 | qa.payment.dhanman.com | Dhanman.Payment.Api.dll | true (default) | dhanman-payment-qa.service (confirmed) |
| dhanman-document | 5207 | qa.document.dhanman.com | Dhanman.Document.dll | true (default) | dhanman-document-qa.service (confirmed) |
| dhanman-agent | 5208 | qa.agent.dhanman.com | Dhanman.Agent.API.dll | true (default) | dhanman-agent-qa.service (confirmed) |
| dhanman-einvoice | 5209 | qa.einvoice.dhanman.com | Dhanman.EInvoice.Api.dll | true (default) | dhanman-einvoice-qa.service (confirmed) |

**Note on unit names:** **CONFIRMED from `ansible/roles/dhanman_service/tasks/main.yml`. Unit destination: `/etc/systemd/system/{{ item.name }}-{{ env }}.service`.** The `systemd` module also enables/manages the unit by name `{{ item.name }}-{{ env }}`, matching the `SyslogIdentifier={{ item.name }}-{{ env }}` value already present in `service.unit.j2`.

Log directory `/var/www/<env>/logs` created with mode `0775`, owner `www-data:www-data` (confirmed from `tasks/main.yml`). Per-service working directories: mode `0750`.

**has_metrics logic:** `prometheus.yml.j2` filters the `dhanman_services` job with `{% for svc in services if svc.has_metrics | default(true) %}` — confirms `has_metrics` defaults to `true` when the key is absent (as in every QA service and 9 of 10 PROD services).

---

## 2. Confirmed Log Paths

| Environment | `services_base_dir` (from group_vars) | Log directory |
|---|---|---|
| prod | `/var/www/prod` | `/var/www/prod/logs` |
| qa | `/var/www/qa` | `/var/www/qa/logs` |

**Filename pattern** (from `promtail-config.yml.j2`, `dhanman-logs` job):
```
__path__: "{{ services_base_dir }}/logs/dhanman-*.log"
regex expression: 'dhanman-(?P<service_name>[^-]+)-\d+\.log'
```
Comment in the file cites the example `dhanman-community-20260507.log` — confirms pattern `dhanman-<service>-YYYYMMDD.log`.

**Serilog filter** (`appsettings.Production.json.j2`):
```json
"Filter": [{ "Name": "ByExcluding", "Args": { "expression": "RequestPath = '/metrics' or RequestPath = '/health'" } }]
```
This confirms requests to `/metrics` and `/health` produce **no log line**. Implication for any synthetic-probe-based freshness check: pinging `/health` or `/metrics` will never appear in the log file and therefore cannot be used to verify the log pipeline is alive. Any synthetic technique must hit a different path (one that returns a normal request-logged response, e.g. a 404 on an arbitrary path) — consistent with the master plan's note but independently confirmed here from the actual filter expression.

---

## 3. Confirmed Monitoring Stack

All from `ansible/roles/monitoring/templates/docker-compose.yml.j2`:

| Container | Image:Version | Port(s) published | Network mode | Config file (on host, via `monitoring_dir`) |
|---|---|---|---|---|
| prometheus | prom/prometheus:v2.52.0 | 0.0.0.0:9090 | **host** | `{{ monitoring_dir }}/prometheus/prometheus.yml` |
| alertmanager | prom/alertmanager:v0.27.0 | 127.0.0.1:9093 | bridge (`monitoring` network) | `{{ monitoring_dir }}/alertmanager/alertmanager.yml` |
| loki | grafana/loki:2.9.0 | 127.0.0.1:3100 | bridge (`monitoring` network) | `{{ monitoring_dir }}/loki/loki-config.yml` |
| promtail | grafana/promtail:2.9.0 | **none published** | bridge (`monitoring` network) | `{{ monitoring_dir }}/promtail/promtail-config.yml` |
| grafana | grafana/grafana:latest | 127.0.0.1:3000 (via `GF_SERVER_HTTP_ADDR`/`PORT` env) | **host** | `{{ monitoring_dir }}/grafana/provisioning` |
| blackbox | prom/blackbox-exporter:v0.25.0 | 127.0.0.1:9115 | bridge (`monitoring` network) | `{{ monitoring_dir }}/blackbox/blackbox.yml` |
| nginx-exporter | nginx/nginx-prometheus-exporter:1.1.0 | 127.0.0.1:9113 (redundant — see note) | **host** | n/a (command-line flag only) |
| redis-exporter | oliver006/redis_exporter:v1.62.0 | 127.0.0.1:9121 (redundant — see note) | **host** | n/a (env vars only) |
| postgres-exporter | quay.io/prometheuscommunity/postgres-exporter:v0.16.0 | (none listed; host network) | **host** | `{{ monitoring_dir }}/postgres_exporter` (queries.yml) |
| portainer | portainer/portainer-ce:latest | 127.0.0.1:9443 | bridge (default, no explicit network key) | n/a |
| uptime-kuma | louislam/uptime-kuma:1 | 127.0.0.1:3001 | bridge (default, no explicit network key) | n/a |

**Named volumes:** `prometheus_data`, `alertmanager_data`, `loki_data`, `grafana_data`, `portainer_data`, `uptime_kuma_data`. **No volume exists for Promtail's positions file** — corroborates the ephemeral-positions finding in §4.

**New finding (not previously stated this precisely):** `nginx-exporter` and `redis-exporter` declare both `network_mode: host` **and** a `ports:` mapping — with host networking, Docker ignores the `ports:` block entirely, so those lines are dead configuration (harmless, but worth cleanup — out of scope here).

---

## 4. Confirmed Promtail Configuration

From `ansible/roles/monitoring/templates/promtail-config.yml.j2`:

**Server:** `http_listen_port: 9080` — **not published to the host** per the docker-compose service definition (§3). A host-level `curl 127.0.0.1:9080/ready` will fail; any readiness check must run inside the `monitoring` Docker network or via `docker exec`.

**PT-02 decision:** readiness check will use `docker exec promtail wget -qO- 127.0.0.1:9080/ready`. No compose port mapping change required.

**Positions file:** `/tmp/positions.yaml` — inside the container, no bind mount or named volume backs this path. Every container restart wipes it, causing Promtail to re-scan configured paths from scratch on restart: duplicate log ingestion into Loki and/or "entry too far behind" rejections if Loki's ingestion-order tolerance is exceeded. Confirmed reliability risk.

**Push target:** `clients: url: http://loki:3100/loki/api/v1/push` (batchsize 1048576, batchwait 5s, timeout 10s). The hostname `loki` resolves via Docker's embedded DNS because both `promtail` and `loki` containers share the `monitoring` bridge network (confirmed in §3).

**Scrape jobs:**

| Job | Path glob | Labels |
|---|---|---|
| `dhanman-logs` | `{{ services_base_dir }}/logs/dhanman-*.log` | `env`, `service_name` (from filename regex), `Level` (from JSON/CLEF regex, defaults to `Information`), static `log_type: application` |
| `nginx` | `/var/log/nginx/*.log` | `job: nginx`, `env` |
| `postgresql` | `/var/log/postgresql/*.log` | `job: postgresql`, `env`, `log_type: postgres`; multiline stage (`firstline: '^\d{4}-\d{2}-\d{2}'`, `max_wait_time: 3s`) |
| `systemd-journal` | journal input (not file glob), `max_age: 12h` | `job: systemd-journal`, `host`, `env`; relabel `__journal__systemd_unit` → `unit` |

---

## 4b. Confirmed Loki Configuration

Source: `ansible/roles/monitoring/templates/loki-config.yml.j2`

| Setting | Value |
|---|---|
| `auth_enabled` | `false` |
| Storage | filesystem |
| `chunks_directory` | `/loki/chunks` |
| `rules_directory` | `/loki/rules` |
| `path_prefix` | `/loki` |
| Replication factor | 1 (single-binary) |
| Ring store | `inmemory` |
| Schema | `tsdb`, `v13`, from `2024-01-01`, index period `24h` |
| Retention | `744h` (31 days), `retention_enabled: true` |
| Compactor | enabled, `compaction_interval: 10m` |

No per-stream rate limits or ingestion limits configured — `limits_config` contains only the retention line.

---

## 5. Confirmed Prometheus Configuration

From `ansible/roles/monitoring/templates/prometheus.yml.j2` and `docker-compose.yml.j2`:

**Global:** `scrape_interval: 15s`, `evaluation_interval: 15s`, external label `env`.

**Alerting:** static Alertmanager target `127.0.0.1:9093`. **Rule files:** `/etc/prometheus/rules/*.yml`.

**Scrape jobs:**

| Job | Target(s) | Notes |
|---|---|---|
| `node` | `127.0.0.1:9100` | node_exporter |
| `dhanman_services` | `127.0.0.1:<port>` per service, filtered by `has_metrics \| default(true)` | metrics_path `/metrics` |
| `postgres` | `127.0.0.1:9187` | postgres-exporter |
| `rabbitmq` | `127.0.0.1:15692` | |
| `nginx` | `127.0.0.1:9113` | |
| `redis` | `127.0.0.1:9121` | |
| `minio` | `127.0.0.1:9000`, path `/minio/v2/metrics/cluster` | bearer token via `minio_metrics_token` |
| `blackbox_http` | `https://<svc.domain>/health` for **every** service in `services` (not filtered by `has_metrics`) | module `http_2xx`, relayed through blackbox `127.0.0.1:9115` |
| `blackbox_ssl` | `<svc.domain>:443` for every service | module `tcp_connect` |
| `vault` | `127.0.0.1:8200`, path `/v1/sys/metrics`, format `prometheus` | |

**Retention:** `--storage.tsdb.retention.time=30d` (docker-compose command args).

**Lifecycle flag:** `--web.enable-lifecycle` is present, combined with `--web.listen-address=0.0.0.0:9090` and `network_mode: host`. **Security concern (confirmed):** any local process on the host can `POST /-/reload` without authentication; UFW blocks this externally but not locally. Matches the master plan's flagged concern — independently verified here from the actual compose command args.

---

## 6. Confirmed Email Relay

From `ansible/roles/monitoring/templates/alertmanager.yml.j2` — **no passwords or credential values reproduced**:

- **Relay host:port:** `smtp-relay.brevo.com:587`
- **From address:** `alerts@dhanman.com`
- **Recipient variable:** `alert_emails` (Jinja default `devops@dhanman.com` if undefined). PROD group_vars sets `alert_emails: "b2a.admn@gmail.com, bharat.mane@gmail.com"`. **QA group_vars (`ansible/inventories/qa/group_vars/all/main.yml`) does not define `alert_emails`** in the file read — QA would fall back to the template default unless set in a file not read this pass (e.g. an unread override or `secrets.yml`). This gap must be resolved before Phase 6 (email delivery) — the QA report cannot send to correct recipients until the QA alert_emails value is confirmed.
- **Credential variable names (values not read):** `smtp_username`, `smtp_password` — referenced only as Jinja variables with defaults in this template (`smtp_username | default('8ba6c9001@smtp-brevo.com')`, `smtp_password | default('')`). **The Vault path that supplies these values is not shown in this file.** CLAUDE.md (a project doc, not one of the 14 files read this pass) states these live under `secret/shared/global`, but that specific mapping is **not independently confirmed** from the files read in this step — flagged in Gaps §10.

---

## 7. Confirmed Scheduling Mechanism

From `ansible/roles/backup/tasks/main.yml` — the only scheduling-related file in this read set:

| Job | Schedule | Mechanism | User |
|---|---|---|---|
| PostgreSQL nightly backup | `0 2 * * *` (2:00 AM) | Ansible `cron` module → `/opt/scripts/pg_backup.sh` | postgres |
| MinIO nightly backup | `30 2 * * *` (2:30 AM) | Ansible `cron` module → `/opt/scripts/minio_backup.sh` | root |

No systemd timer units appear in any file read this pass. **Jenkinsfile was not among the files read for this discovery step**, so Jenkins' role cannot be independently confirmed here (it is described in CLAUDE.md as a deploy-oriented CI pipeline on the prod host, but that is project documentation, not a file inspected in this pass).

**Recommendation for infra-verify scheduling:** cron via the Ansible `cron` module, matching the exact pattern already established in `ansible/roles/backup/tasks/main.yml`. This is the only scheduling mechanism confirmed present in the files read, making it the lowest-risk, most consistent choice — no new scheduling technology introduced.

---

## 8. Confirmed Server Details

| Environment | Alias | `ansible_host` | `ansible_user` | SSH key |
|---|---|---|---|---|
| prod | dm-prd | **51.79.156.217** | ubuntu | `~/.ssh/id_rsa` |
| qa | dm-qa | **54.37.159.71** | ubuntu | `~/.ssh/id_ed25519` |

Source: `ansible/inventories/prod/hosts`, `ansible/inventories/qa/hosts`.

**Discrepancy noted:** CLAUDE.md (project doc) states, under "Known Issues," that `ansible/inventories/prod/hosts` "currently points to `57.129.74.139`" and needs updating to `51.79.156.217`. **The actual file content read in this step already shows `51.79.156.217`** for `dm-prd`. This means either (a) the inventory was already corrected after CLAUDE.md's known-issues note was written, or (b) CLAUDE.md is stale. This is reported exactly as observed — no assumption is made about which is true. This directly answers Open Question #3 from the master plan (§9.20): **as of this read, `ansible/inventories/prod/hosts` targets `dm-prd` / `51.79.156.217`.**

The fallback/DR inventory (`ansible/inventories/fallback/hosts`) was **not** among the files requested for this discovery pass, so the DR host's current inventory state is not verified here.

---

## 9. Confirmed Domain Names

| Source | Variable | Value |
|---|---|---|
| prod group_vars | `domain` | `dhanman.com` |
| prod group_vars | `vault_address` | `https://vault.dgtula.com` |
| qa group_vars | `domain` | `dhanman.com` |
| qa group_vars | `vault_address` | `https://vault.qa.dgtula.com` |
| prod group_vars | `services_ssl_cert_domain` | `prod.common.dhanman.com` |
| all service `domain` fields (prod + qa) | — | all `*.dhanman.com` (see §1 tables) |
| Grafana | `GF_SERVER_ROOT_URL` (docker-compose.yml.j2) | `https://logs.{{ domain }}` → renders `https://logs.dhanman.com` (since `domain: dhanman.com` in both envs) |
| nginx infra-vhost | `server_name {{ item.subdomain }}.{{ domain }}` | renders on `dhanman.com` for all infra subdomains (`logs`, `status`, `vault`, `rabbitmq`, `minio`, `files`, `portainer` for prod; `vault-qa`, `grafana-qa`, `rabbit-qa`, `minio-qa`, `status-qa` for qa) |

**Conclusion, based only on these files:** only the **Vault address variable** (`vault_address`) has migrated to `dgtula.com` in both environments' group_vars. Every other domain reference read in this pass — service domains, Grafana's root URL (driven by the `domain` var), and all nginx infra-vhost subdomains — still resolves under `dhanman.com` in the checked-in templates and variables. This confirms, from file evidence alone, the master plan's suspicion (§9.2) that rendered server state may differ from these templates: **as committed, the migration is partial and limited to Vault.**

**Follow-up finding:** an attempted health-check fetch to `https://prod.common.dhanman.com/health` and `https://qa.common.dhanman.com/health` both failed with DNS resolution errors (`ENOTFOUND`) from the agent's network context. This does not confirm a `dgtula.com` cutover — the owner's own SSH-based test against `http://127.0.0.1:5200/health` on the QA host succeeded (see §10, Health endpoint schema — RESOLVED), meaning the service itself is healthy and reachable locally; the public DNS/hostname resolution question remains unconfirmed and is not treated as blocking since the internal check succeeded.

---

## 10. Gaps — Status After Owner Follow-Up

| Gap | Severity | Detail |
|---|---|---|
| Credential rotation status of `ansible/inventories/prod/group_vars/all/secrets.yml` | **IMPORTANT** | Private repo — no public exposure. Credential rotation planned as a separate task before PROD deployment in Phase 7. Phase 1 may proceed. |
| Health endpoint response schema per service | **RESOLVED** | QA port 5200 (dhanman-common) returns plain text `Healthy`. No JSON. HLT-02 uses string match. HLT-03 attempts JSON parse, treats absence as NOT_APPLICABLE not ERROR. Confirmed by owner via `curl -s http://127.0.0.1:5200/health` over SSH on the QA host. |
| Promtail `9080` not published to host | **RESOLVED** | Option (b) chosen — `docker exec promtail wget -qO- 127.0.0.1:9080/ready`. No infra change needed. |
| Exact systemd unit filename/destination path | **RESOLVED** | Unit is `item.name-env.service`, e.g. `dhanman-purchase-prod.service`. Confirmed from `tasks/main.yml`. |
| Loki retention/limits configuration | **RESOLVED** | 744h retention, no rate limits, filesystem storage, tsdb v13. See Section 4b. |
| Vault path backing `smtp_username`/`smtp_password` | IMPORTANT | `alertmanager.yml.j2` only shows Ansible variable names with inline defaults; the Vault path (`secret/shared/global`, per CLAUDE.md) is not shown in any file read this pass. |
| Fallback/DR inventory (`ansible/inventories/fallback/hosts`) | IMPORTANT | Not read this pass; DR host identity not independently re-verified here (memory holds `dm-prd-n` / `57.129.74.139` from a prior session, but that is out of scope for a file-only discovery pass). |
| Jenkinsfile contents / Jenkins' actual scheduled-job usage | IMPORTANT | Not read this pass; Jenkins' role as CI-only vs. also-scheduling cannot be confirmed from these 14 files. |
| QA `alert_emails` value | IMPORTANT | Not set in `ansible/inventories/qa/group_vars/all/main.yml`; may be defined in an unread file (e.g. `secrets.yml` or a `group_vars/all/vault.yml` not requested). Must be resolved before Phase 6. |
| Rendered/live domain (DNS) state for public service hostnames | OPTIONAL | `prod.common.dhanman.com` and `qa.common.dhanman.com` both failed DNS resolution (`ENOTFOUND`) from the agent's network; owner's internal SSH-based check succeeded instead. Public DNS state not confirmed. Not blocking — internal health check path is sufficient for HLT family design. |
| Uptime Kuma monitor configuration / API key existence | OPTIONAL | Stored in a Docker volume (`uptime_kuma_data`), not in any repo file. |

**No BLOCKING gaps remain.** Phase 1 may proceed once this document is approved and written.

---

**Files inspected for this discovery pass (16, read-only):**
`ansible/inventories/prod/group_vars/all/main.yml`, `ansible/inventories/qa/group_vars/all/main.yml`, `ansible/inventories/prod/hosts`, `ansible/inventories/qa/hosts`, `ansible/roles/monitoring/templates/docker-compose.yml.j2`, `ansible/roles/monitoring/templates/promtail-config.yml.j2`, `ansible/roles/monitoring/templates/prometheus.yml.j2`, `ansible/roles/monitoring/templates/alertmanager.yml.j2`, `ansible/roles/monitoring/templates/grafana-datasources.yml.j2`, `ansible/roles/dhanman_service/templates/service.unit.j2`, `ansible/roles/dhanman_service/templates/appsettings.Production.json.j2`, `ansible/roles/nginx/templates/service-vhost.conf.j2`, `ansible/roles/nginx/templates/infra-vhost.conf.j2`, `ansible/roles/backup/tasks/main.yml`, `ansible/roles/dhanman_service/tasks/main.yml`, `ansible/roles/monitoring/templates/loki-config.yml.j2`.

`ansible/inventories/prod/group_vars/all/secrets.yml` was **not read** (per standing rule) — its rotation status is owner-reported only, recorded in §10 as IMPORTANT (not blocking, per owner decision — private repo, rotation deferred to Phase 7).

No files were modified. Two read-only external HTTP fetch attempts were made (both service health URLs); both failed with DNS errors and returned no data — results recorded in §9 and §10.
