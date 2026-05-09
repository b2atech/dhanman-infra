# OpenTelemetry — Server Setup (Grafana Tempo)

This documents what to run on dm-prd-n (57.129.74.139) to receive and store traces from .NET services.

## What Gets Added

| Component | Role | Port |
|-----------|------|------|
| Grafana Tempo | Trace storage + query backend | 3200 (HTTP), 4317 (OTLP gRPC) |
| Grafana datasource | Tempo added alongside Prometheus + Loki | — |

Tempo runs as a new Docker container in the monitoring stack. The OTLP gRPC port 4317 is bound to `127.0.0.1` so only processes on the host can push traces to it (the .NET services run on the host).

---

## Step 1 — Add Tempo to monitoring docker-compose

This is already templated in Ansible. Run:

```bash
cd /tmp/dhanman-infra/ansible
ansible-playbook -i inventories/prod playbooks/02-install-infra.yml --tags monitoring
```

If doing it manually on the server instead:

```bash
ssh ubuntu@57.129.74.139
sudo mkdir -p /opt/monitoring/tempo

sudo tee /opt/monitoring/tempo/tempo-config.yml > /dev/null <<'EOF'
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"

ingester:
  max_block_duration: 5m

compactor:
  compaction:
    block_retention: 336h   # 14 days

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/blocks
    wal:
      path: /var/tempo/wal

metrics_generator:
  registry:
    external_labels:
      source: tempo
      cluster: dhanman-prod
  storage:
    path: /var/tempo/generator/wal
    remote_write:
      - url: http://127.0.0.1:9090/api/v1/write
        send_exemplars: true
EOF
```

Add this service block to `/opt/monitoring/docker-compose.yml` (inside `services:`):

```yaml
  tempo:
    image: grafana/tempo:2.5.0
    container_name: tempo
    restart: unless-stopped
    command: -config.file=/etc/tempo/tempo-config.yml
    ports:
      - "127.0.0.1:3200:3200"   # Tempo HTTP API (Grafana queries here)
      - "127.0.0.1:4317:4317"   # OTLP gRPC (services push traces here)
    volumes:
      - /opt/monitoring/tempo/tempo-config.yml:/etc/tempo/tempo-config.yml:ro
      - tempo_data:/var/tempo
    networks:
      - monitoring
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```

Also add `tempo_data:` under the `volumes:` section at the bottom of docker-compose.yml.

Start Tempo:
```bash
cd /opt/monitoring
sudo docker compose up -d tempo
sudo docker logs tempo --tail=20
```

---

## Step 2 — Add Tempo datasource to Grafana

Add to `/opt/monitoring/grafana/provisioning/datasources/datasources.yml` (append after the Loki block):

```yaml
  - name: Tempo
    type: tempo
    access: proxy
    url: http://127.0.0.1:3200
    uid: tempo
    jsonData:
      httpMethod: GET
      tracesToLogsV2:
        datasourceUid: loki
        spanStartTimeShift: "-1m"
        spanEndTimeShift: "1m"
        tags:
          - key: service.name
            value: app
      tracesToMetrics:
        datasourceUid: prometheus
      serviceMap:
        datasourceUid: prometheus
      nodeGraph:
        enabled: true
    editable: false
```

Restart Grafana to pick up the new datasource:
```bash
cd /opt/monitoring
sudo docker compose restart grafana
```

---

## Step 3 — Enable Prometheus remote_write (for service graph)

Tempo's metrics generator writes span-derived metrics (request rate, error rate, latency) back to Prometheus via remote_write. Enable it in Prometheus config at `/opt/monitoring/prometheus/prometheus.yml`:

```yaml
# Add this block at the top level (same level as scrape_configs):
remote_write:
  - url: http://127.0.0.1:9090/api/v1/write
```

Then reload Prometheus:
```bash
curl -s -X POST http://127.0.0.1:9090/-/reload
```

---

## Step 4 — Add Prometheus scrape for Tempo

Add this job to `/opt/monitoring/prometheus/prometheus.yml` under `scrape_configs:`:

```yaml
  - job_name: tempo
    static_configs:
      - targets: ["127.0.0.1:3200"]
```

Reload Prometheus after adding:
```bash
curl -s -X POST http://127.0.0.1:9090/-/reload
```

---

## Verification

After deploying .NET changes and restarting services:

```bash
# Tempo is receiving traces
curl -s http://127.0.0.1:3200/ready
# Should return: ready

# Check OTLP port is listening
ss -tlnp | grep 4317

# Check Tempo metrics
curl -s http://127.0.0.1:3200/metrics | grep tempo_distributor_spans_received_total
```

In Grafana (`logs.dhanman.com`):
1. Go to **Explore → Tempo datasource**
2. Search by **Service Name** = `dhanman-common` (or any service)
3. Click a trace → waterfall view of all spans

---

## Disk usage estimate

Tempo retains 14 days of traces. With 9 services at moderate load:
- ~50–200 MB/day depending on request volume
- Safe on current server — monitor with node_exporter disk alert

To check: `du -sh /var/lib/docker/volumes/*tempo*`

---

## Ansible

The Ansible templates for this (once written):
- `ansible/roles/monitoring/templates/tempo-config.yml.j2`
- `ansible/roles/monitoring/templates/docker-compose.yml.j2` — add tempo service
- `ansible/roles/monitoring/templates/grafana-datasources.yml.j2` — add Tempo datasource
- `ansible/roles/monitoring/tasks/main.yml` — add tempo dir + config deploy task
