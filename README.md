# dhanman-infra

Ansible-based Infrastructure-as-Code for DhanMan — a SaaS apartment/community management platform by B2A Technologies Private Limited.

## Server Layout

| Host | IP | Role |
|------|----|------|
| dm-prd-n | 57.129.74.139 | **Primary production** — all services + Vault + PostgreSQL primary |
| dm-prd | 51.79.156.217 | **Fallback** — PostgreSQL streaming replica + Jenkins CI |
| dm-qa | 54.37.159.71 | QA environment |

## Prerequisites

On the machine running Ansible:
```bash
pip install ansible ansible-lint
ansible-galaxy collection install community.docker community.postgresql
```

SSH key (`~/.ssh/id_rsa`) must have access to all three servers as `ubuntu`.

## Secrets

**No secrets are stored in this repo.** All runtime credentials come from HashiCorp Vault.

Before running playbooks, set per-environment Vault role IDs in your shell or CI:
```bash
export VAULT_ROLE_ID_PROD=<from vault>
export VAULT_ROLE_ID_QA=<from vault>
```

Or pass as extra vars: `-e vault_role_id=$VAULT_ROLE_ID_PROD`

Passwords that must be set manually on first provision (stored in Vault, NOT here):
- `rabbitmq_password` — RabbitMQ `dhanman` user
- `minio_root_user` / `minio_root_password` — MinIO root credentials
- `grafana_admin_password` — Grafana admin
- PostgreSQL passwords via `~/.pgpass` on the server

## Directory Structure

```
ansible/
├── ansible.cfg
├── inventories/
│   ├── prod/          # dm-prd-n (primary production)
│   ├── fallback/      # dm-prd (PostgreSQL replica + Jenkins)
│   └── qa/            # dm-qa
├── playbooks/
│   ├── site.yml                  # Run everything (01 → 02 → 03)
│   ├── 01-bootstrap.yml          # Common baseline + security hardening
│   ├── 02-install-infra.yml      # Install all infrastructure
│   ├── 03-deploy-services.yml    # Deploy .NET service units
│   ├── 04-setup-replica.yml      # Configure PostgreSQL streaming replica on dm-prd
│   ├── 05-cleanup-qa.yml         # Remove old PostgreSQL replica from dm-qa
│   ├── deploy-service.yml        # Rolling restart of a single service (called by Jenkins)
│   └── security-hardening.yml    # Re-run security hardening only
└── roles/
    ├── common/          # Hostname, packages, timezone, directories
    ├── security/        # UFW, fail2ban, SSH hardening
    ├── dotnet/          # .NET 9 ASP.NET Core runtime
    ├── dhanman_service/ # systemd units + .env files for 9 services
    ├── nginx/           # nginx + certbot + SSL vhosts
    ├── postgresql/      # PostgreSQL 18 + PgBouncer + pg_cron + pgvector
    ├── redis/           # Redis (AOF, localhost-only)
    ├── vault/           # HashiCorp Vault
    ├── docker/          # Docker CE + Compose plugin
    ├── rabbitmq/        # RabbitMQ (Docker Compose)
    ├── minio/           # MinIO (Docker Compose)
    ├── monitoring/      # Prometheus + Loki + Promtail + Grafana + Portainer + Uptime Kuma
    └── backup/          # pg_backup.sh + minio_backup.sh cron jobs
Jenkinsfile             # CI/CD pipeline
```

## First-Time Provisioning (dm-prd-n)

```bash
# 1. Bootstrap (security hardening, baseline packages)
ansible-playbook -i ansible/inventories/prod ansible/playbooks/01-bootstrap.yml

# 2. Install all infrastructure
ansible-playbook -i ansible/inventories/prod ansible/playbooks/02-install-infra.yml \
  -e vault_role_id=$VAULT_ROLE_ID_PROD

# 3. Initialize and unseal Vault (manual step — run on server)
#    ssh ubuntu@57.129.74.139
#    vault operator init
#    vault operator unseal  (x3)

# 4. Deploy service units
ansible-playbook -i ansible/inventories/prod ansible/playbooks/03-deploy-services.yml \
  -e vault_role_id=$VAULT_ROLE_ID_PROD
```

## Set Up PostgreSQL Replica (dm-prd)

```bash
# Run AFTER primary is fully set up and Vault is unsealed
ansible-playbook -i ansible/inventories/fallback ansible/playbooks/04-setup-replica.yml
```

## Rolling Deploy (Jenkins / Manual)

```bash
# Deploy a single service after copying new binary
ansible-playbook -i ansible/inventories/prod ansible/playbooks/deploy-service.yml \
  -e service_name=dhanman-common
```

## Security Notes

- PostgreSQL listens on `127.0.0.1` only; replication allowed only from `51.79.156.217/32`
- Vault listens on `127.0.0.1:8200` only; nginx terminates TLS externally
- Redis bound to `127.0.0.1`; dangerous commands (`FLUSHALL`, `KEYS`, etc.) disabled
- All infra ports (5432, 6379, 8200, 9090, etc.) blocked by UFW; only 22/80/443 open
- SSH: no root login, no password auth, fail2ban active
