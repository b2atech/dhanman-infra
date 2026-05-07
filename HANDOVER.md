# DhanMan Infrastructure — Session Handover

## Servers
| Host | IP | Role |
|------|-----|------|
| dm-prd-n | 57.129.74.139 | **Primary prod** — all services running here |
| dm-prd | 51.79.156.217 | **Streaming replica** (read-only) + Jenkins |
| dm-qa | 54.37.159.71 | QA environment |

SSH: `ssh -i ~/.ssh/id_rsa ubuntu@<IP>`  
Ansible: `cd /tmp/dhanman-infra/ansible`  
GitHub: `https://github.com/b2atech/dhanman-infra` (branch: main)

---

## dm-prd-n Status ✅ FULLY OPERATIONAL

| Component | Status | Notes |
|-----------|--------|-------|
| Bootstrap (UFW/fail2ban/SSH) | ✅ Done | |
| .NET 9 ASP.NET Core | ✅ Done | |
| PostgreSQL 18.3 | ✅ Done | 127.0.0.1:5432, WAL replication active |
| Redis | ✅ Done | 127.0.0.1:6379, password=rdB@yce-Codd(x->y) |
| Docker CE | ✅ Done | |
| HashiCorp Vault | ✅ Running + seeded | https://vault.dhanman.com, unsealed, all secrets loaded |
| RabbitMQ | ✅ Done | Docker, vhost=prod, user=dhanman, pass=B@dhi$1234 |
| MinIO | ✅ Done | Docker, old data migrated, user=dhanmanprodadmin |
| Monitoring stack | ✅ Done | Prometheus, Loki, Grafana, Promtail, Portainer, Uptime Kuma |
| node_exporter | ✅ Done | |
| nginx | ✅ Done + SSL | All service domains have valid Let's Encrypt certs |
| Backup scripts + cron | ✅ Done | pg_backup at 02:00, minio_backup at 02:30 |
| PgBouncer | ✅ Done (port 6432) | Not currently used by apps (direct 5432 for LISTEN/NOTIFY) |
| Production databases | ✅ Running | All 8 DBs migrated from dm-prd |
| All 9 .NET services | ✅ Running | Ports 5100–5108, health checks passing |
| DNS | ✅ Done | All domains → 57.129.74.139 |
| MinIO data | ✅ Migrated | 66MB including avatars, sp-company-logos, apartment buckets |

## dm-prd Status

| Component | Status | Notes |
|-----------|--------|-------|
| PostgreSQL 18.3 | ✅ Done | **Streaming replica** of dm-prd-n, read-only |
| Replication | ✅ Active | `pg_is_in_recovery() = t` verified |
| Jenkins | ✅ Running | CI/CD still active here |

---

## Vault Credentials (NEW SERVER)

**Store in your password manager — do NOT commit actual values here**

- Unseal Key: `<stored in password manager>`
- Root Token: `<stored in password manager>`
- AppRole RoleId: `09ae57e8-8625-34e4-19df-81193b50a513`
- AppRole SecretId: `<generated — run: vault write -f auth/approle/role/dhanman-service/secret-id>`
- Vault Address (internal): `http://127.0.0.1:8200`
- Vault Address (external): `https://vault.dhanman.com`

### Vault Secret Paths
- `secret/shared/global` — Auth0, ICICI, MinIO, RabbitMQ, SMTP, API keys
- `secret/shared/databases` — All DB connection strings (127.0.0.1:5432)
- `secret/shared/ai` — OpenAI API key

### After server reboot: unseal Vault
```bash
ssh ubuntu@57.129.74.139
export VAULT_ADDR='http://127.0.0.1:8200'
vault operator unseal 'wVjzW/SEffsH42zXh/UgIM5NZn93StO6s4bKJehBj3k='
```

---

## Remaining TODO Items

### High Priority

1. **Add missing DNS records** (user must do in DNS provider):
   - `grafana.dhanman.com` → 57.129.74.139
   - `rabbit.dhanman.com` → 57.129.74.139
   - `portainer.dhanman.com` → 57.129.74.139
   - `status.dhanman.com` → 57.129.74.139 (currently points to old server)
   
   Then issue SSL certs:
   ```bash
   ssh ubuntu@57.129.74.139
   sudo certbot certonly --webroot -w /var/www/html \
     -d grafana.dhanman.com -d rabbit.dhanman.com \
     -d portainer.dhanman.com -d status.dhanman.com \
     --email b2a.admn@gmail.com --agree-tos --no-eff-email
   # Create symlinks for cert paths
   sudo ln -s /etc/letsencrypt/live/grafana.dhanman.com /etc/letsencrypt/live/rabbit.dhanman.com
   sudo ln -s /etc/letsencrypt/live/grafana.dhanman.com /etc/letsencrypt/live/portainer.dhanman.com
   sudo ln -s /etc/letsencrypt/live/grafana.dhanman.com /etc/letsencrypt/live/status.dhanman.com
   # Re-enable vhosts
   sudo ln -s /etc/nginx/sites-available/infra-grafana.conf /etc/nginx/sites-enabled/
   sudo ln -s /etc/nginx/sites-available/infra-rabbit.conf /etc/nginx/sites-enabled/
   sudo ln -s /etc/nginx/sites-available/infra-portainer.conf /etc/nginx/sites-enabled/
   sudo ln -s /etc/nginx/sites-available/infra-status.conf /etc/nginx/sites-enabled/
   sudo nginx -t && sudo systemctl reload nginx
   ```

2. ~~Configure Grafana datasources~~ — **Done**. Prometheus + Loki auto-provisioned via Ansible.
   Dashboards imported: Node Exporter Full, PostgreSQL, Redis, RabbitMQ, NGINX.

3. **Set up pg_hba.conf in Ansible** — the `57.129.74.139/32` rules were added manually. Add them to the postgresql role so they survive reprovisioning.

4. **PgBouncer connection pooling** — PgBouncer is running on port 6432 but apps connect directly to 5432. Full guide below.

   #### Why apps bypass PgBouncer
   MassTransit (used by all services for messaging) relies on PostgreSQL `LISTEN/NOTIFY`. PgBouncer
   in **transaction mode** does not support `LISTEN/NOTIFY` — connections holding a LISTEN subscription
   are not returned to the pool, breaking the entire pooling benefit.

   #### Two options to enable PgBouncer properly

   **Option A — Switch MassTransit to RabbitMQ transport (recommended)**
   The services already have RabbitMQ configured. Remove the MassTransit PostgreSQL transport
   dependency and all `LISTEN/NOTIFY` usage disappears. Then PgBouncer transaction mode works.
   After that, update connection strings:

   *Step 1 — Update Vault secrets* (`secret/shared/databases`): change port `5432` → `6432` in all
   connection strings, and append Npgsql options:
   ```
   Server=127.0.0.1;Port=6432;Database=prod-dhanman-common;User Id=dhanmanprod;
   Password=...;MaxAutoPrepare=0;No Reset On Close=true
   ```
   `MaxAutoPrepare=0` disables EF Core prepared statements (not supported in transaction mode).
   `No Reset On Close=true` prevents Npgsql from issuing DISCARD ALL on connection return.

   *Step 2 — Update PgBouncer userlist*:
   ```bash
   sudo -u postgres psql -c "SELECT '\"' || usename || '\" \"' || passwd || '\"' FROM pg_shadow WHERE usename='dhanmanprod';" \
     | grep dhanmanprod | sudo tee /etc/pgbouncer/userlist.txt
   sudo systemctl reload pgbouncer
   ```

   *Step 3 — Redeploy all services* via Ansible.

   **Option B — Switch to PgBouncer session mode**
   Session mode supports `LISTEN/NOTIFY` but provides less pooling benefit (one server connection
   per client session). Change `pool_mode = session` in `/etc/pgbouncer/pgbouncer.ini`. No app
   changes needed, but you lose transaction-level pooling efficiency.

   #### Current connection string location
   Stored in Vault at `secret/shared/databases`. All strings currently use `Port=5432`.

5. **Update Jenkins** on dm-prd to deploy to dm-prd-n instead of dm-prd. Change the deployment target IP/path in Jenkins pipelines.

6. **Frontend deployment** — the frontend (1.3GB) was not copied. It may be served from old server or needs redeployment via Jenkins.

### Security Cleanup
- Remove `CHANGE_ME` values in `ansible/inventories/prod/group_vars/all/secrets.yml` (or encrypt with ansible-vault)
- Remove `host all all 0.0.0.0/0 scram-sha-256` from dm-prd pg_hba.conf (security risk on old server)
- Revoke the GitHub PAT used in these sessions
- The old Vault on dm-prd is still running — consider stopping it once you've confirmed new Vault is stable

---

## Key Technical Notes

- **PG18 on Ubuntu 25.04**: pgdg plucky repo is gone. noble pgdg repo + `libicu74` workaround baked in.
- **Vault after reboot**: must be manually unsealed — run `vault operator unseal <key>` on each restart.
- **RabbitMQ vhost**: apps use vhost `prod` (no leading slash). Old config had `/prod` which was wrong.
- **DB connections**: use `127.0.0.1:5432` directly (not PgBouncer port 6432) because apps use LISTEN/NOTIFY.
- **nginx SSL**: service domains share one cert at `prod.common.dhanman.com` with symlinks for other domains.
- **pg_hba.conf**: `57.129.74.139/32` entries for dhanmanprod added manually — needed because apps connect via external IP.
- **MinIO endpoint**: `files.dhanman.com` → nginx → port 9000 (S3 API). Console at `minio.dhanman.com` → port 9001.

---

## Ansible Quick Reference
```bash
export PATH="$PATH:/Users/bharatmane/Library/Python/3.9/bin"
cd /tmp/dhanman-infra/ansible

# Re-run any single role:
ansible-playbook -i inventories/prod playbooks/02-install-infra.yml --tags <role>

# Rolling restart single service:
ansible-playbook -i inventories/prod playbooks/deploy-service.yml -e service_name=dhanman-common
```
