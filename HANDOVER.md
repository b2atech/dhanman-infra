# DhanMan Infrastructure — Session Handover

## Servers
| Host | IP | Role |
|------|-----|------|
| dm-prd-n | 57.129.74.139 | **New primary prod** — all work done here |
| dm-prd | 51.79.156.217 | Fallback + Jenkins (has prod PG18 data) |
| dm-qa | 54.37.159.71 | QA environment |

SSH: `ssh -i ~/.ssh/id_rsa ubuntu@<IP>`  
Ansible: `cd /tmp/dhanman-infra/ansible`  
GitHub: `https://github.com/b2atech/dhanman-infra` (branch: main)

---

## dm-prd-n Status ✅ COMPLETE

| Component | Status | Notes |
|-----------|--------|-------|
| Bootstrap (UFW/fail2ban/SSH) | ✅ Done | |
| .NET 9 ASP.NET Core | ✅ Done | |
| PostgreSQL 18.3 | ✅ Done | Port 5432, 127.0.0.1 only, WAL ready |
| Redis | ✅ Done | 127.0.0.1 only, AOF, dangerous cmds disabled |
| Docker CE | ✅ Done | |
| HashiCorp Vault | ✅ Done | **NOT initialized yet — needs `vault operator init`** |
| RabbitMQ | ✅ Done | Docker container, healthy |
| MinIO | ✅ Done | Docker container, healthy |
| Prometheus + Loki + Grafana + Promtail + Portainer + Uptime Kuma | ✅ Done | Docker stack |
| node_exporter | ✅ Done | |
| nginx | ✅ Done | Vhosts deployed, **SSL certs NOT yet issued** |
| Backup scripts + cron | ✅ Done | pg_backup at 02:00, minio_backup at 02:30 |
| PgBouncer | ✅ Done | Port 6432 |

---

## Pending Steps (in order)

### 1. Initialize Vault on dm-prd-n (MANUAL — must be done once)
```bash
ssh ubuntu@57.129.74.139
export VAULT_ADDR='http://127.0.0.1:8200'
vault operator init          # save the 5 unseal keys + root token SECURELY
vault operator unseal        # run 3 times with 3 different keys
vault login <root_token>
```

### 2. Issue SSL certificates via certbot (MANUAL — DNS must resolve first)
Point all domains to 57.129.74.139, then:
```bash
ssh ubuntu@57.129.74.139
# For each service domain:
sudo certbot --nginx -d prod.common.dhanman.com -d prod.community.dhanman.com \
  -d prod.inventory.dhanman.com -d prod.payroll.dhanman.com \
  -d prod.purchase.dhanman.com -d prod.sales.dhanman.com \
  -d payment.dhanman.com -d prod.document.dhanman.com -d prod.agent.dhanman.com
# For infra domains:
sudo certbot --nginx -d vault.dhanman.com -d grafana.dhanman.com \
  -d rabbit.dhanman.com -d minio.dhanman.com -d portainer.dhanman.com -d status.dhanman.com
```

### 3. Migrate production databases from dm-prd → dm-prd-n
dm-prd has 8 prod databases (PG18): prod-dhanman-{common,community,inventory,payroll,purchase,sales,payment,agent}
Users: dhanmanprod, dhanmanbackup, dhanmanqa, postgres_exporter

```bash
# On dm-prd (51.79.156.217):
sudo -u postgres pg_dumpall --globals-only > /tmp/pg_globals.sql
for db in prod-dhanman-common prod-dhanman-community prod-dhanman-inventory \
          prod-dhanman-payroll prod-dhanman-purchase prod-dhanman-sales \
          prod-dhanman-payment prod-dhanman-agent; do
  sudo -u postgres pg_dump -Fc "$db" > /tmp/${db}.dump
done

# Copy to dm-prd-n:
scp -i ~/.ssh/id_rsa ubuntu@51.79.156.217:/tmp/pg_globals.sql ubuntu@57.129.74.139:/tmp/
scp -i ~/.ssh/id_rsa ubuntu@51.79.156.217:/tmp/prod-dhanman-*.dump ubuntu@57.129.74.139:/tmp/

# On dm-prd-n (57.129.74.139):
sudo -u postgres psql -f /tmp/pg_globals.sql
for db in prod-dhanman-common prod-dhanman-community prod-dhanman-inventory \
          prod-dhanman-payroll prod-dhanman-purchase prod-dhanman-sales \
          prod-dhanman-payment prod-dhanman-agent; do
  sudo -u postgres createdb "$db"
  sudo -u postgres pg_restore -d "$db" /tmp/${db}.dump
done
```

### 4. Configure Vault secrets (after Vault init)
Load all DB connection strings, RabbitMQ, MinIO credentials into Vault.
Then run the dhanman_service role to deploy .env files with Vault__RoleId.

### 5. Deploy .NET service binaries + start services
```bash
cd /tmp/dhanman-infra/ansible
ansible-playbook -i inventories/prod playbooks/03-deploy-services.yml -e vault_role_id=<role_id>
# Then deploy each binary via Jenkins or manually rsync
```

### 6. Set up PostgreSQL streaming replica on dm-prd
```bash
cd /tmp/dhanman-infra/ansible
ansible-playbook -i inventories/fallback playbooks/04-setup-replica.yml
```

### 7. Set up real secrets in secrets.yml (or ansible-vault encrypt it)
Replace CHANGE_ME values in:
- `ansible/inventories/prod/group_vars/all/secrets.yml`
- `ansible/inventories/qa/group_vars/all/secrets.yml`

---

## Key Technical Notes

- **PG18 on Ubuntu 25.04**: pgdg plucky repo is gone. Solution: noble pgdg repo + `libicu74` manually installed. Already baked into the postgresql role.
- **Vault/HashiCorp apt**: Uses `noble` repo codename (`vault_apt_codename: noble` in group_vars).
- **Ansible**: Run from `cd /tmp/dhanman-infra/ansible` — cfg picks up roles_path from there.
- **community.docker**: Version 4.5.1 pinned (5.x needs ansible-core 2.17+ which needs Python 3.10+).
- **Secrets**: Never hardcoded. Pass via `-e` at runtime or store in ansible-vault encrypted secrets.yml.
- **dm-prd pg_hba.conf**: Changed from `md5` to `peer` for postgres local auth (more secure).

---

## Ansible Quick Reference
```bash
export PATH="$PATH:/Users/bharatmane/Library/Python/3.9/bin"
cd /tmp/dhanman-infra/ansible

# Re-run any single role:
ansible-playbook -i inventories/prod playbooks/02-install-infra.yml --tags <role>

# Full site deploy:
ansible-playbook -i inventories/prod playbooks/site.yml

# Rolling restart single service:
ansible-playbook -i inventories/prod playbooks/deploy-service.yml -e service_name=dhanman-common

# Security hardening only:
ansible-playbook -i inventories/prod playbooks/security-hardening.yml
```
