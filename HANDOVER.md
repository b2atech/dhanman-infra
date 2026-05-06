# DhanMan Infrastructure — Session Handover

## Servers
| Host | IP | Role |
|------|-----|------|
| dm-prd-n | 57.129.74.139 | **Primary prod** — all services run here |
| dm-prd | 51.79.156.217 | **Streaming replica** (read-only) + Jenkins |
| dm-qa | 54.37.159.71 | QA environment |

SSH: `ssh -i ~/.ssh/id_rsa ubuntu@<IP>`  
Ansible: `cd /tmp/dhanman-infra/ansible`  
GitHub: `https://github.com/b2atech/dhanman-infra` (branch: main)

---

## dm-prd-n Status

| Component | Status | Notes |
|-----------|--------|-------|
| Bootstrap (UFW/fail2ban/SSH) | ✅ Done | |
| .NET 9 ASP.NET Core | ✅ Done | |
| PostgreSQL 18.3 | ✅ Done | Port 5432, listen_addresses=*, WAL replication active |
| Redis | ✅ Done | 127.0.0.1 only, AOF, dangerous cmds disabled |
| Docker CE | ✅ Done | |
| HashiCorp Vault | ✅ Installed | **NOT initialized yet — needs `vault operator init`** |
| RabbitMQ | ✅ Done | Docker container, healthy |
| MinIO | ✅ Done | Docker container, healthy |
| Prometheus + Loki + Grafana + Promtail + Portainer + Uptime Kuma | ✅ Done | Docker stack |
| node_exporter | ✅ Done | |
| nginx | ✅ Done | Vhosts deployed, **SSL certs NOT yet issued** |
| Backup scripts + cron | ✅ Done | pg_backup at 02:00, minio_backup at 02:30 |
| PgBouncer | ✅ Done | Port 6432 |
| Production databases | ✅ Migrated | All 8 DBs from dm-prd PG18 restored here |
| DNS | ✅ Done | All domains point to 57.129.74.139 |

## dm-prd Status

| Component | Status | Notes |
|-----------|--------|-------|
| PostgreSQL 18.3 | ✅ Done | **Streaming replica** of dm-prd-n, read-only |
| Replication | ✅ Active | `pg_is_in_recovery() = t` verified |
| Jenkins | ✅ Running | CI/CD still active here |

### Replication details (dm-prd)
- Primary: 57.129.74.139:5432, user: replicator
- pg_basebackup run with `-R` flag (standby.signal + primary_conninfo written)
- max_connections=200 set (must match primary)
- UFW rule on dm-prd-n: `allow from 51.79.156.217 to any port 5432` (inserted at position 4)

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

### 2. Issue SSL certificates via certbot (MANUAL — DNS already resolved)
DNS is already pointing to 57.129.74.139. Run:
```bash
ssh ubuntu@57.129.74.139
# Service domains:
sudo certbot --nginx -d prod.common.dhanman.com -d prod.community.dhanman.com \
  -d prod.inventory.dhanman.com -d prod.payroll.dhanman.com \
  -d prod.purchase.dhanman.com -d prod.sales.dhanman.com \
  -d payment.dhanman.com -d prod.document.dhanman.com -d prod.agent.dhanman.com
# Infra domains:
sudo certbot --nginx -d vault.dhanman.com -d grafana.dhanman.com \
  -d rabbit.dhanman.com -d minio.dhanman.com -d portainer.dhanman.com -d status.dhanman.com
```

### 3. Configure Vault secrets (after Vault init + unseal)
After Vault is initialized and unsealed:
```bash
export VAULT_ADDR='http://127.0.0.1:8200'
vault login <root_token>

# Enable KV secrets engine
vault secrets enable -path=secret kv-v2

# Enable AppRole auth
vault auth enable approle

# Write DB connection strings
vault kv put secret/dhanman/common \
  ConnectionStrings__DefaultConnection="Host=127.0.0.1;Port=6432;Database=prod-dhanman-common;Username=dhanmanprod;Password=<pw>"
# Repeat for: community, inventory, payroll, purchase, sales, payment, agent

# Write RabbitMQ + MinIO secrets
vault kv put secret/dhanman/rabbitmq url="amqp://dhanman:<pw>@127.0.0.1:5672/dhanman"
vault kv put secret/dhanman/minio endpoint="http://127.0.0.1:9000" access_key="<key>" secret_key="<secret>"

# Create policy
vault policy write dhanman-policy - <<EOF
path "secret/data/dhanman/*" { capabilities = ["read"] }
EOF

# Create AppRole
vault write auth/approle/role/dhanman \
  token_policies="dhanman-policy" \
  token_ttl=1h \
  token_max_ttl=4h

# Get RoleID (put this in .env files as Vault__RoleId)
vault read auth/approle/role/dhanman/role-id

# Create SecretID (used once to bootstrap service .env)
vault write -f auth/approle/role/dhanman/secret-id
```

### 4. Deploy .NET service binaries + start services
```bash
cd /tmp/dhanman-infra/ansible
# Create systemd units + .env files (binaries not needed for this step)
ansible-playbook -i inventories/prod playbooks/03-deploy-services.yml \
  -e vault_role_id=<role_id_from_step_3>

# Then copy each service binary via Jenkins or rsync:
# rsync -avz --delete dist/dhanman-common/ ubuntu@57.129.74.139:/var/www/prod/dhanman-common/
# sudo systemctl start dhanman-common-prod
```

### 5. Update secrets.yml with real values (or encrypt with ansible-vault)
Replace CHANGE_ME values in:
- `ansible/inventories/prod/group_vars/all/secrets.yml`
- `ansible/inventories/qa/group_vars/all/secrets.yml`

Then optionally encrypt: `ansible-vault encrypt ansible/inventories/prod/group_vars/all/secrets.yml`

### 6. Security cleanup
- Remove `host all all 0.0.0.0/0 scram-sha-256` from dm-prd pg_hba.conf (security risk)
- Revoke the GitHub PAT used in these sessions
- Add UFW replication rule to Ansible security role (currently added manually on dm-prd-n)

---

## Key Technical Notes

- **PG18 on Ubuntu 25.04**: pgdg plucky repo is gone. Solution: noble pgdg repo + `libicu74` manually installed. Already baked into the postgresql role.
- **Vault/HashiCorp apt**: Uses `noble` repo codename (`vault_apt_codename: noble` in group_vars).
- **Ansible**: Run from `cd /tmp/dhanman-infra/ansible` — cfg picks up roles_path from there.
- **community.docker**: Version 4.5.1 pinned (5.x needs ansible-core 2.17+ which needs Python 3.10+).
- **Secrets**: Never hardcoded. Pass via `-e` at runtime or store in ansible-vault encrypted secrets.yml.
- **postgres password on dm-prd-n**: `pgB@yce-Codd(x->y)` (set manually, not in Ansible)
- **replicator password**: `Repl@DhanMan2024` (set manually on dm-prd-n)
- **PgBouncer**: Port 6432 — services should connect via PgBouncer, not directly to 5432.

---

## Ansible Quick Reference
```bash
export PATH="$PATH:/Users/bharatmane/Library/Python/3.9/bin"
cd /tmp/dhanman-infra/ansible

# Re-run any single role:
ansible-playbook -i inventories/prod playbooks/02-install-infra.yml --tags <role>

# Full site deploy:
ansible-playbook -i inventories/prod playbooks/site.yml

# Deploy service units + .env files:
ansible-playbook -i inventories/prod playbooks/03-deploy-services.yml -e vault_role_id=<role_id>

# Rolling restart single service:
ansible-playbook -i inventories/prod playbooks/deploy-service.yml -e service_name=dhanman-common

# Security hardening only:
ansible-playbook -i inventories/prod playbooks/security-hardening.yml
```
