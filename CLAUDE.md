# dhanman-infra — Claude Code Guide

Infrastructure-as-Code for **DhanMan**, a SaaS apartment/community management platform by B2A Technologies Private Limited.
Stack: Ansible + .NET 9 ASP.NET Core + PostgreSQL 18 + HashiCorp Vault + nginx + Docker.

---

## Server Layout

| Alias | Host | IP | Role |
|-------|------|----|------|
| Prod | dm-prd | **51.79.156.217** | **Current production** — all services + Jenkins CI |
| Fallback / DR | dm-prd-n | **57.129.74.139** | Fallback server — PostgreSQL streaming replica of prod |
| QA | dm-qa | **54.37.159.71** | QA environment |

SSH: `ssh -i ~/.ssh/id_rsa ubuntu@<IP>`

> **Note:** The Jenkinsfile `Copy Binaries` stage and `ansible/inventories/prod/hosts` currently point to
> `57.129.74.139`. These need to be updated to `51.79.156.217` to reflect the current prod server.

---

## Ansible Inventories

| Directory | Targets |
|-----------|---------|
| `ansible/inventories/prod/` | dm-prd-n (57.129.74.139) — needs updating to dm-prd |
| `ansible/inventories/fallback/` | dm-prd (51.79.156.217) |
| `ansible/inventories/qa/` | dm-qa (54.37.159.71) |
| `ansible/inventory/prod.ini` | Legacy flat file — dm-prd (51.79.156.217) |
| `ansible/inventory/qa.ini` | Legacy flat file — dm-qa (54.37.159.71) |

---

## Services

Nine .NET 9 ASP.NET Core services running on prod, ports 5100–5108:
- `dhanman-common`, `dhanman-community`, `dhanman-inventory`, `dhanman-payroll`, `dhanman-purchase`,
  `dhanman-sales`, `dhanman-payment`, `dhanman-document`, `dhanman-agent`, `dhanman-einvoice`

Service units managed by systemd. Deploy a single service:
```bash
ansible-playbook -i ansible/inventories/prod ansible/playbooks/deploy-service.yml \
  -e service_name=dhanman-common
```

---

## Key Infrastructure

| Component | Details |
|-----------|---------|
| PostgreSQL 18 | `127.0.0.1:5432` on prod; `127.0.0.1:5432` on fallback (streaming replica) |
| PgBouncer | Port `6432` — **not used by apps** (apps connect directly on 5432 due to MassTransit LISTEN/NOTIFY) |
| Redis | `127.0.0.1:6379`, AOF persistence, dangerous commands disabled |
| RabbitMQ | Docker Compose, vhost=`prod` (no leading slash), port 5672 |
| MinIO | Docker Compose; S3 API on 9000 (`files.dhanman.com`), Console on 9001 (`minio.dhanman.com`) |
| HashiCorp Vault | `http://127.0.0.1:8200` internally; `https://vault.dhanman.com` externally |
| Monitoring | Prometheus, Loki, Promtail, Grafana, Portainer, Uptime Kuma — all Docker |
| nginx + SSL | Let's Encrypt via certbot; service domains share cert at `prod.common.dhanman.com` with symlinks |
| Jenkins | Running on dm-prd (51.79.156.217); pipeline in `Jenkinsfile` at repo root |

---

## Secrets & Vault

**No secrets are committed to this repo.** All runtime credentials come from HashiCorp Vault.

Vault secret paths:
- `secret/shared/global` — Auth0, ICICI, MinIO, RabbitMQ, SMTP, API keys
- `secret/shared/databases` — All DB connection strings (`127.0.0.1:5432`)
- `secret/shared/ai` — OpenAI API key

Required env vars before running playbooks:
```bash
export VAULT_ROLE_ID_PROD=<from vault>
export VAULT_ROLE_ID_QA=<from vault>
```

**After every server reboot, Vault must be manually unsealed:**
```bash
ssh ubuntu@51.79.156.217
export VAULT_ADDR='http://127.0.0.1:8200'
vault operator unseal '<unseal key from password manager>'
```

---

## Common Ansible Commands

```bash
# Full provision (new server)
ansible-playbook -i ansible/inventories/prod ansible/playbooks/01-bootstrap.yml
ansible-playbook -i ansible/inventories/prod ansible/playbooks/02-install-infra.yml -e vault_role_id=$VAULT_ROLE_ID_PROD
ansible-playbook -i ansible/inventories/prod ansible/playbooks/03-deploy-services.yml -e vault_role_id=$VAULT_ROLE_ID_PROD

# Set up PostgreSQL streaming replica on fallback
ansible-playbook -i ansible/inventories/fallback ansible/playbooks/04-setup-replica.yml

# Re-run a single role
ansible-playbook -i ansible/inventories/prod ansible/playbooks/02-install-infra.yml --tags <role>

# Rolling restart of one service
ansible-playbook -i ansible/inventories/prod ansible/playbooks/deploy-service.yml -e service_name=dhanman-common
```

---

## Known Issues / TODOs

- **Jenkinsfile + prod inventory** hard-code `57.129.74.139` as prod — update to `51.79.156.217`.
- **PgBouncer** is running but unused. To enable: switch MassTransit to RabbitMQ transport (removes LISTEN/NOTIFY dependency), then update connection strings to port 6432. See `HANDOVER.md` for full guide.
- **pg_hba.conf** entries for `57.129.74.139/32` were added manually on prod — should be codified in the postgresql Ansible role.
- **Vault on old server (57.129.74.139)** is still running — stop it once fallback role is confirmed stable.
- **`ansible/inventories/prod/group_vars/all/secrets.yml`** contains `CHANGE_ME` placeholders — encrypt with ansible-vault or populate.

---

## Security Posture

- UFW: only ports 22, 80, 443 open externally; all infra ports (5432, 6379, 8200, etc.) blocked
- SSH: no root login, no password auth, fail2ban active
- PostgreSQL: listens on `127.0.0.1` only; replication allowed only from `51.79.156.217/32`
- Vault: listens on `127.0.0.1:8200`; nginx terminates TLS
- Redis: bound to `127.0.0.1`; `FLUSHALL`, `KEYS`, etc. disabled
