# Dhanman Auth0 → Keycloak Migration Plan

**Owner:** B2a
**Status:** Draft v1 (agent-handover ready)
**Auth server:** Keycloak 26.x (Apache 2.0, fully open source — no paid features)
**Hosting:** Existing OVH QA + PROD, Docker-based, behind NGINX
**Stack:** .NET 9, React + TS, Flutter, PostgreSQL, NGINX, Certbot, Vault, Jenkins, Loki/Promtail/Grafana
**Estimated effort:** ~2.5 engineer-weeks across ~5 weeks elapsed

---

## How this document is meant to be used

This plan is structured for handover. Every phase is independently executable by a coding agent (Claude, Cursor, Copilot CLI, Cline, or a human engineer) with no additional context beyond the phase contents.

Each phase contains:
- **Goal** — what success looks like
- **Prerequisites** — hard preconditions (do not start the phase if these aren't met)
- **Inputs the agent will need** — list of secrets/IDs/values the agent must be given
- **Steps** — copy-paste-ready commands, configs, and full code (no pseudocode)
- **Verification** — concrete checks (curl commands with expected output, SQL queries with expected rows, etc.)
- **Exit criteria** — checklist that must all be true before moving on
- **Rollback** — exact procedure
- **Time estimate** — engineer hours
- **Handover prompt** — the literal prompt to paste into an agent to execute this phase

**Do not skip phases. Do not change service migration order in Phase 9.**

---

## Phase summary

| # | Phase | Effort |
|---|---|---|
| 0 | Pre-flight & inventory | 4h |
| 1 | Stand up Keycloak on QA (Docker + NGINX + Postgres) | 5h |
| 2 | Configure realm, clients, protocol mappers, password policy | 4h |
| 3 | dhanman-common dual-issuer JWT validation | 4h |
| 4 | User migration tool Auth0 → Keycloak | 8h |
| 5 | React frontend dual-flow (OIDC) | 6h |
| 6 | Flutter mobile Keycloak integration | 10h |
| 7 | First apartment cutover (pilot) | 4h + 1 week observation |
| 8 | Remaining 2 apartments | 4h + 1 week observation per |
| 9 | Migrate remaining 6 microservices | 10h |
| 10 | Decommission Auth0 | 4h |
| 11 | Post-migration hardening (MFA, passkeys, brute force, realm-as-code) | 10h |

---

## Recommended execution order for this team

The full plan below is still valid, but the practical starting sequence for Dhanman should be simpler than the document's total scope.

Start in this order:

1. **Install and stand up Keycloak in QA**
   - Goal: prove infrastructure, DNS, NGINX, Postgres, admin access, and backups.
   - Use: Phase 1 and Phase 2 only.

2. **Test Keycloak with one simple application first**
   - Goal: validate OIDC login, redirect URIs, token issuance, logout, and claim mapping in isolation before touching Dhanman repos.
   - Recommended simple app:
     - a tiny React SPA
     - or a tiny ASP.NET Core MVC / minimal API app
   - Keep this app outside the business-critical repos.
   - Success criteria:
     - browser login works
     - logout works
     - access token can be decoded
     - expected claims are present
     - Keycloak client configuration is understood by the team

3. **Integrate Keycloak into one Dhanman repo first**
   - Start with `dhanman-common`.
   - Goal: add dual-issuer validation so Auth0 and Keycloak can both work during transition.
   - Use: Phase 3.

4. **Only after that, move into migration and product repos**
   - User migration tool: Phase 4
   - React app: Phase 5
   - Flutter app: Phase 6
   - Controlled rollout: Phases 7-10

This is the recommended practical breakdown:

| Practical Step | Use these phases |
|---|---|
| Install and configure Keycloak on QA | 1, 2 |
| Validate with simple non-Dhanman app | 2 only, plus a tiny test app |
| Add Keycloak support to first repo | 3 |
| Migrate users and client apps | 4, 5, 6 |
| Gradual production rollout | 7, 8, 9, 10 |
| Hardening | 11 |

What not to do:

- Do not start with user migration first.
- Do not start by editing all repos in parallel.
- Do not attempt apartment cutover before one simple app and one real backend repo both work.

---

## Immediate next phases

The next actual work items should be:

### Step A — Install and configure Keycloak on QA

Use Phase 1 and Phase 2.

Exit condition:

- `qa.auth.dhanman.com` is live
- admin access works
- realm and clients exist
- protocol mappers are configured

### Step B — Validate with a simple application

Create a minimal test application with one login button, one logout button, and one page that shows:

- user subject
- email
- audience
- issuer
- custom claims
- token expiry time

Exit condition:

- the team can log in
- the token is understandable
- the redirect/logout flow is stable

### Step C — Integrate `dhanman-common`

Only after Step B is stable, implement Phase 3.

Exit condition:

- Auth0 tokens still work
- Keycloak tokens also work
- no regression for existing API consumers

### Step D — Document QA challenges before PROD

Before any PROD Keycloak work starts, write down what failed, what was confusing, and what had to be adjusted in QA.

Create and maintain:

- `docs/auth-migration/qa-challenges-log.md`

This file must contain:

- issue title
- date
- affected phase
- symptom
- root cause
- fix
- whether the migration plan was updated
- whether PROD needs a preventive action

Minimum rule:

- Do not begin PROD setup until the QA challenge log exists and has been reviewed.

---

## QA-first rule

For Dhanman, the correct rollout pattern is:

1. Install and configure Keycloak in QA.
2. Test with a simple app in QA.
3. Integrate one Dhanman backend in QA.
4. Record QA issues and plan corrections.
5. Repeat the proven pattern in PROD.

This is mandatory for this migration. QA is not just a test environment here; it is the place where the migration procedure itself is debugged.

## Current QA status

As of `2026-05-10`, the QA Keycloak base installation is live at `https://qa.auth.dhanman.com`.

What is working:

- DNS and TLS are in place for `qa.auth.dhanman.com`
- NGINX is proxying to the Keycloak container
- Keycloak is running against the existing QA PostgreSQL host
- the master realm OIDC discovery endpoint is responding
- bootstrap admin creation succeeded on first successful start

What was learned during QA setup:

- first boot must not use `kc.sh start --optimized`
- the initial server start needs a plain `start`, then later runs can use `start --optimized`
- the secret-render path used for the first QA attempt did not match the actual Vault secret structure, so bootstrap secret injection must be validated explicitly before service start

Before PROD:

- update the install procedure so first boot uses non-optimized start
- simplify or harden secret injection so the bootstrap admin password is definitely present before the first container start
- keep the QA challenge log updated with every install correction

---

## Phase 0 — Pre-flight & inventory

**Goal:** A written record of every Auth0 reference, every JWT claim consumed, every redirect URI registered, and every active user. No code changes in this phase.

**Prerequisites:** None.

**Inputs the agent will need:**
- Auth0 dashboard read access
- Read access to all 7 microservice repos and React + Flutter repos
- Read access to PROD `dhanman-common` Postgres (for user count + schema introspection)

**Steps:**

1. **Auth0 tenant inventory.** From Auth0 dashboard → export and save to `docs/auth-migration/auth0-inventory.md`:
   - Applications: name, Client ID, type (Regular Web App / Native / SPA / M2M), allowed callback URLs, allowed logout URLs, allowed origins (CORS)
   - APIs: identifier (audience), signing algorithm
   - Rules / Actions / Hooks: full body of any Action that adds custom claims (these become Keycloak protocol mappers in Phase 2)
   - Connections: which database / social / enterprise connections are in use
   - Roles and Permissions defined inside Auth0 (Dhanman's permissions live in `dhanman-common`, but check)
   - Total user count and last-30-day MAU

2. **Codebase inventory.** Run these greps and save results to the same file:

   ```bash
   # In each .NET service repo
   grep -rn "Authority\|auth0\|AddJwtBearer\|RequireAuthenticatedUser\|TokenValidationParameters\|ClaimTypes\|ICurrentUser" --include="*.cs" --include="*.json" .

   # In React repo
   grep -rn "auth0\|@auth0\|useAuth0\|Auth0Provider\|getAccessTokenSilently" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.json" .

   # In Flutter repo
   grep -rn "auth0\|Auth0\|flutter_auth0\|client_id\|authorize" --include="*.dart" --include="*.yaml" .
   ```

3. **Capture a real production JWT.** Log into the React app, copy the bearer token from a network request, decode at jwt.io. Document every claim and which service/page reads it. Pay attention to namespaced custom claims (`https://dhanman.com/...`) — these must be replicated in Keycloak.

4. **Document the user table schema in `dhanman-common`:**

   ```sql
   SELECT column_name, data_type, is_nullable, column_default
   FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'users'
   ORDER BY ordinal_position;
   ```

   Identify the column that stores the Auth0 `sub` value (likely `external_id`, `auth_id`, or `auth0_id`). The migration tool in Phase 4 needs the exact name.

5. **List every redirect URI per environment:**
   - QA web callback URLs
   - PROD web callback URLs
   - Mobile deep-link callback URI (e.g., `com.dhanman.app://callback`)
   - Logout URLs for each

6. **Check for cross-service HTTP calls.** Do any of `community`, `sales`, `purchase`, `inventory`, `payroll`, `document` make HTTP calls to each other or to `common` using a JWT? If yes, list each call site:

   ```bash
   grep -rn "HttpClient\|RestClient\|FlurlClient" --include="*.cs" .
   ```

   This determines whether Phase 9's dual-issuer rollout needs to be brought forward (see Phase 9 note).

**Verification:**
- File `docs/auth-migration/auth0-inventory.md` exists in repo and is committed
- Question to answer: "If Auth0 disappeared tomorrow, exactly what would break?" — write the answer in the inventory file

**Exit criteria:**
- Inventory file committed
- All custom claims, redirect URIs, and user-table column names documented

**Rollback:** N/A (read-only phase).

**Time:** 4 hours.

**Handover prompt:**
> Execute Phase 0 of the Dhanman Auth0 → Keycloak migration plan. The plan is at `docs/auth-migration/auth0-to-keycloak-migration-plan.md`. Follow it exactly. Produce `docs/auth-migration/auth0-inventory.md`. Do not modify any code. Stop when the exit criteria are met and report what you found.

---

## Phase 1 — Stand up Keycloak on QA

**Goal:** Keycloak 26.x running on the QA OVH server in Docker, reachable at `https://auth-qa.dhanman.com`, backed by Postgres, with admin console accessible only via VPN/allowed IPs.

**Prerequisites:**
- Phase 0 complete
- DNS A record `auth-qa.dhanman.com` → QA OVH server public IP (verified with `dig`)
- Docker + Docker Compose installed on QA server (`docker --version` returns 24.x or later)
- Postgres reachable from the QA server with admin credentials
- Vault QA running and accessible from the QA server

**Inputs the agent will need:**
- QA server SSH credentials
- Postgres admin password (Vault path: `secret/dhanman/qa/postgres/admin`)
- Office IP range(s) for admin console allowlist
- SMTP credentials for password-reset emails (Vault path: `secret/dhanman/qa/smtp`)

**Steps:**

1. **Create the Keycloak Postgres database.** SSH to Postgres host:

   ```bash
   sudo -u postgres psql
   ```

   ```sql
   CREATE DATABASE keycloak;
   CREATE USER keycloak WITH PASSWORD '<generate-strong-32-char-password>';
   GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
   \c keycloak
   GRANT ALL ON SCHEMA public TO keycloak;
   \q
   ```

   Store the password in Vault: `vault kv put secret/dhanman/qa/keycloak/db_password value=<password>`.

2. **Create directory structure on the QA server:**

   ```bash
   sudo mkdir -p /opt/keycloak/{config,data,themes}
   sudo chown -R 1000:1000 /opt/keycloak
   cd /opt/keycloak
   ```

3. **Create `/opt/keycloak/docker-compose.yml`:**

   ```yaml
   version: '3.8'

   services:
     keycloak:
       image: quay.io/keycloak/keycloak:26.0
       container_name: keycloak
       restart: unless-stopped
       command:
         - start
         - --optimized
       environment:
         # DB connection
         KC_DB: postgres
         KC_DB_URL: jdbc:postgresql://<postgres-host>:5432/keycloak
         KC_DB_USERNAME: keycloak
         KC_DB_PASSWORD_FILE: /run/secrets/kc_db_password

         # Hostname / proxy — critical for working behind NGINX
         KC_HOSTNAME: https://auth-qa.dhanman.com
         KC_HOSTNAME_STRICT: "true"
         KC_HOSTNAME_BACKCHANNEL_DYNAMIC: "false"
         KC_PROXY_HEADERS: xforwarded
         KC_HTTP_ENABLED: "true"
         KC_HTTP_PORT: 8080

         # Health and metrics for monitoring
         KC_HEALTH_ENABLED: "true"
         KC_METRICS_ENABLED: "true"

         # Bootstrap admin (one-time, change immediately after first login)
         KC_BOOTSTRAP_ADMIN_USERNAME: bootstrap
         KC_BOOTSTRAP_ADMIN_PASSWORD_FILE: /run/secrets/kc_bootstrap_password

         # Logging
         KC_LOG_LEVEL: INFO
         KC_LOG_CONSOLE_OUTPUT: json

         # JVM
         JAVA_OPTS_APPEND: "-Xms512m -Xmx1024m"
       ports:
         - "127.0.0.1:8080:8080"   # Bind to localhost only — NGINX fronts it
       secrets:
         - kc_db_password
         - kc_bootstrap_password
       volumes:
         - ./data:/opt/keycloak/data
         - ./themes:/opt/keycloak/themes
       healthcheck:
         test: ["CMD-SHELL", "exec 3<>/dev/tcp/127.0.0.1/9000 && echo -e 'GET /health/ready HTTP/1.1\\nhost: localhost\\n' >&3 && cat <&3 | grep -q '\"status\": \"UP\"'"]
         interval: 30s
         timeout: 10s
         retries: 5
         start_period: 60s

   secrets:
     kc_db_password:
       file: /opt/keycloak/config/db_password.secret
     kc_bootstrap_password:
       file: /opt/keycloak/config/bootstrap_password.secret
   ```

4. **Render secrets from Vault** (write a small startup wrapper at `/opt/keycloak/render-secrets.sh`):

   ```bash
   #!/bin/bash
   set -euo pipefail
   export VAULT_ADDR=https://vault-qa.dhanman.com
   # Use AppRole auth or token from local secret
   vault kv get -field=value secret/dhanman/qa/keycloak/db_password > /opt/keycloak/config/db_password.secret
   vault kv get -field=value secret/dhanman/qa/keycloak/bootstrap_password > /opt/keycloak/config/bootstrap_password.secret
   chmod 600 /opt/keycloak/config/*.secret
   ```

   Generate the bootstrap password and store it: `openssl rand -base64 32 | vault kv put secret/dhanman/qa/keycloak/bootstrap_password value=-`.

5. **Create systemd unit** `/etc/systemd/system/keycloak.service`:

   ```ini
   [Unit]
   Description=Keycloak (Docker Compose)
   Requires=docker.service
   After=docker.service network-online.target

   [Service]
   Type=oneshot
   RemainAfterExit=yes
   WorkingDirectory=/opt/keycloak
   ExecStartPre=/opt/keycloak/render-secrets.sh
   ExecStart=/usr/bin/docker compose up -d
   ExecStop=/usr/bin/docker compose down
   TimeoutStartSec=120

   [Install]
   WantedBy=multi-user.target
   ```

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable keycloak
   sudo systemctl start keycloak
   sudo docker compose -f /opt/keycloak/docker-compose.yml logs -f
   ```

   Watch logs until you see `Keycloak X.X.X on JVM (powered by Quarkus X.X.X) started in X.XXXs.`

6. **NGINX reverse proxy.** Create `/etc/nginx/sites-available/auth-qa.dhanman.com`:

   ```nginx
   # WebSocket upgrade map
   map $http_upgrade $connection_upgrade {
       default upgrade;
       ''      close;
   }

   server {
       listen 80;
       server_name auth-qa.dhanman.com;
       return 301 https://$host$request_uri;
   }

   server {
       listen 443 ssl http2;
       server_name auth-qa.dhanman.com;

       ssl_certificate /etc/letsencrypt/live/auth-qa.dhanman.com/fullchain.pem;
       ssl_certificate_key /etc/letsencrypt/live/auth-qa.dhanman.com/privkey.pem;
       ssl_protocols TLSv1.2 TLSv1.3;
       ssl_ciphers HIGH:!aNULL:!MD5;
       ssl_prefer_server_ciphers on;

       # Security headers
       add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
       add_header X-Content-Type-Options "nosniff" always;
       add_header X-Frame-Options "SAMEORIGIN" always;
       add_header Referrer-Policy "strict-origin-when-cross-origin" always;

       client_max_body_size 10M;

       # Block /metrics and /health from public — internal only
       location ~ ^/(metrics|health) {
           allow 127.0.0.1;
           # allow <your-monitoring-subnet>;
           deny all;
           proxy_pass http://127.0.0.1:8080;
       }

       # Restrict admin console to office IPs (REPLACE with real IPs before going live)
       location /admin/ {
           # allow <office-ip-1>;
           # allow <office-ip-2>;
           # deny all;
           proxy_pass http://127.0.0.1:8080;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto https;
           proxy_set_header X-Forwarded-Port 443;
           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection $connection_upgrade;
       }

       # Public OIDC endpoints + login flows
       location / {
           proxy_pass http://127.0.0.1:8080;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto https;
           proxy_set_header X-Forwarded-Port 443;
           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection $connection_upgrade;

           proxy_buffer_size 128k;
           proxy_buffers 4 256k;
           proxy_busy_buffers_size 256k;

           proxy_read_timeout 300s;
           proxy_connect_timeout 60s;
       }
   }
   ```

   Enable + cert + reload:

   ```bash
   sudo ln -s /etc/nginx/sites-available/auth-qa.dhanman.com /etc/nginx/sites-enabled/
   sudo certbot --nginx -d auth-qa.dhanman.com --non-interactive --agree-tos -m ops@dhanman.com
   sudo nginx -t && sudo systemctl reload nginx
   ```

7. **First admin login:**
   - Browse to `https://auth-qa.dhanman.com/admin/`
   - Log in with `bootstrap` / (the password from Vault)
   - Realm dropdown (top-left) → "master" realm → Users → create a new permanent admin account `dhanman-admin` with realm-management roles `realm-admin`
   - Set a strong password, store in Vault `secret/dhanman/qa/keycloak/admin`
   - Sign out, sign back in as `dhanman-admin`
   - Master realm → Users → delete the `bootstrap` user

8. **Promtail log scraping.** Add to `/etc/promtail/config.yml`:

   ```yaml
   - job_name: keycloak
     docker_sd_configs:
       - host: unix:///var/run/docker.sock
         filters:
           - name: name
             values: [keycloak]
     relabel_configs:
       - source_labels: ['__meta_docker_container_name']
         target_label: container
       - target_label: job
         replacement: keycloak
       - target_label: env
         replacement: qa
   ```

   `sudo systemctl restart promtail`. Confirm logs flowing in Grafana with query `{job="keycloak"}`.

**Verification:**

```bash
# Health check returns UP
curl -fs https://auth-qa.dhanman.com/health/ready
# Expected: {"status": "UP", "checks": [...]}

# OIDC discovery (will reference master realm initially — that's fine, we'll create dhanman realm in Phase 2)
curl -fs https://auth-qa.dhanman.com/realms/master/.well-known/openid-configuration | jq .issuer
# Expected: "https://auth-qa.dhanman.com/realms/master"

# JWKS endpoint
curl -fs https://auth-qa.dhanman.com/realms/master/protocol/openid-connect/certs | jq '.keys | length'
# Expected: a number ≥ 1
```

**Exit criteria:**
- `https://auth-qa.dhanman.com/admin/` returns the Keycloak admin login page
- `dhanman-admin` user can log in to the master realm
- `bootstrap` user is deleted
- `systemctl status keycloak` shows active (exited) — Docker compose process is up
- `docker ps` shows `keycloak` container as `(healthy)`
- Logs from Keycloak appearing in Loki under `{job="keycloak"}`

**Rollback:**

```bash
sudo systemctl stop keycloak
sudo systemctl disable keycloak
sudo docker compose -f /opt/keycloak/docker-compose.yml down -v
sudo rm /etc/nginx/sites-enabled/auth-qa.dhanman.com
sudo nginx -t && sudo systemctl reload nginx
sudo -u postgres psql -c "DROP DATABASE keycloak;"
```

No production users affected at any point.

**Time:** 5 hours.

**Handover prompt:**
> Execute Phase 1 of the Dhanman Auth0 → Keycloak migration plan at `docs/auth-migration/auth0-to-keycloak-migration-plan.md`. The QA OVH server is `<server-hostname>`, you have SSH access. Postgres admin credentials are in Vault at `secret/dhanman/qa/postgres/admin`. DNS for `auth-qa.dhanman.com` is already pointing here. Office IPs to allow on `/admin/` are: `<list>`. Stop and report when the exit criteria are met. Do not proceed to Phase 2.

---

## Phase 2 — Configure realm, clients, and protocol mappers

**Goal:** A `dhanman` realm with three clients (web, mobile, internal-admin), a shared client scope `dhanman-claims` that emits `user_id`, `apartment_ids`, `organization_id`, `role` into every token, and password/brute-force policies tightened.

**Prerequisites:** Phase 1 complete and verified.

**Inputs the agent will need:**
- Redirect URIs from Phase 0 inventory
- SMTP credentials for the realm's email config
- Decision on initial password policy (defaults provided below)

**Steps:**

All steps below use the `kcadm.sh` Admin CLI inside the Keycloak container, because it's idempotent and scriptable. You can also do everything via the admin UI — instructions in parentheses where useful.

1. **Open a shell in the Keycloak container and authenticate kcadm:**

   ```bash
   sudo docker exec -it keycloak bash
   /opt/keycloak/bin/kcadm.sh config credentials \
     --server http://localhost:8080 \
     --realm master \
     --user dhanman-admin \
     --password '<password-from-vault>'
   ```

2. **Create the `dhanman` realm:**

   ```bash
   /opt/keycloak/bin/kcadm.sh create realms -s realm=dhanman -s enabled=true \
     -s displayName="Dhanman" \
     -s 'displayNameHtml=<strong>Dhanman</strong>' \
     -s sslRequired=external \
     -s registrationAllowed=false \
     -s loginWithEmailAllowed=true \
     -s duplicateEmailsAllowed=false \
     -s resetPasswordAllowed=true \
     -s editUsernameAllowed=false \
     -s bruteForceProtected=true \
     -s permanentLockout=false \
     -s maxFailureWaitSeconds=900 \
     -s minimumQuickLoginWaitSeconds=60 \
     -s waitIncrementSeconds=60 \
     -s quickLoginCheckMilliSeconds=1000 \
     -s maxDeltaTimeSeconds=43200 \
     -s failureFactor=5 \
     -s 'passwordPolicy=length(10) and digits(1) and specialChars(1) and notUsername(undefined) and notEmail(undefined) and passwordHistory(3) and hashIterations(27500)' \
     -s 'accessTokenLifespan=3600' \
     -s 'ssoSessionIdleTimeout=2592000' \
     -s 'ssoSessionMaxLifespan=2592000'
   ```

3. **Configure SMTP on the realm:**

   ```bash
   /opt/keycloak/bin/kcadm.sh update realms/dhanman \
     -s 'smtpServer.host=<smtp-host>' \
     -s 'smtpServer.port=587' \
     -s 'smtpServer.from=no-reply@dhanman.com' \
     -s 'smtpServer.fromDisplayName=Dhanman' \
     -s 'smtpServer.replyTo=support@dhanman.com' \
     -s 'smtpServer.starttls=true' \
     -s 'smtpServer.auth=true' \
     -s 'smtpServer.user=<smtp-user>' \
     -s 'smtpServer.password=<smtp-password>'
   ```

4. **Define custom user attributes** so the migration tool can populate them. Realm settings → User profile (Keycloak 26+ has the unified user profile). Add three attributes:

   ```bash
   # Read current user profile JSON
   /opt/keycloak/bin/kcadm.sh get users/profile -r dhanman > /tmp/up.json

   # Edit /tmp/up.json to add three attributes under "attributes":
   # {
   #   "name": "apartment_ids",
   #   "displayName": "Apartment IDs",
   #   "multivalued": true,
   #   "permissions": { "view": ["admin","user"], "edit": ["admin"] }
   # },
   # {
   #   "name": "organization_id",
   #   "displayName": "Organization ID",
   #   "permissions": { "view": ["admin","user"], "edit": ["admin"] }
   # },
   # {
   #   "name": "role",
   #   "displayName": "Dhanman Role",
   #   "permissions": { "view": ["admin","user"], "edit": ["admin"] }
   # }

   /opt/keycloak/bin/kcadm.sh update users/profile -r dhanman -f /tmp/up.json
   ```

   Use the JSON in Appendix E as the full reference.

5. **Create the shared client scope `dhanman-claims`:**

   ```bash
   # Create the client scope
   SCOPE_ID=$(/opt/keycloak/bin/kcadm.sh create client-scopes -r dhanman \
     -s name=dhanman-claims \
     -s description="Dhanman identity claims" \
     -s protocol=openid-connect \
     -s 'attributes."include.in.token.scope"=true' \
     -s 'attributes."display.on.consent.screen"=false' \
     -i)
   echo "Scope ID: $SCOPE_ID"

   # Mapper 1: apartment_ids (multi-value attribute → JSON array claim)
   /opt/keycloak/bin/kcadm.sh create client-scopes/$SCOPE_ID/protocol-mappers/models -r dhanman \
     -s name=apartment_ids \
     -s protocol=openid-connect \
     -s protocolMapper=oidc-usermodel-attribute-mapper \
     -s 'config."user.attribute"=apartment_ids' \
     -s 'config."claim.name"=apartment_ids' \
     -s 'config."jsonType.label"=String' \
     -s 'config."multivalued"=true' \
     -s 'config."id.token.claim"=true' \
     -s 'config."access.token.claim"=true' \
     -s 'config."userinfo.token.claim"=true'

   # Mapper 2: organization_id (single value)
   /opt/keycloak/bin/kcadm.sh create client-scopes/$SCOPE_ID/protocol-mappers/models -r dhanman \
     -s name=organization_id \
     -s protocol=openid-connect \
     -s protocolMapper=oidc-usermodel-attribute-mapper \
     -s 'config."user.attribute"=organization_id' \
     -s 'config."claim.name"=organization_id' \
     -s 'config."jsonType.label"=String' \
     -s 'config."id.token.claim"=true' \
     -s 'config."access.token.claim"=true' \
     -s 'config."userinfo.token.claim"=true'

   # Mapper 3: role (single value)
   /opt/keycloak/bin/kcadm.sh create client-scopes/$SCOPE_ID/protocol-mappers/models -r dhanman \
     -s name=role \
     -s protocol=openid-connect \
     -s protocolMapper=oidc-usermodel-attribute-mapper \
     -s 'config."user.attribute"=role' \
     -s 'config."claim.name"=role' \
     -s 'config."jsonType.label"=String' \
     -s 'config."id.token.claim"=true' \
     -s 'config."access.token.claim"=true' \
     -s 'config."userinfo.token.claim"=true'

   # Mapper 4: user_id (Keycloak user UUID → claim "user_id")
   /opt/keycloak/bin/kcadm.sh create client-scopes/$SCOPE_ID/protocol-mappers/models -r dhanman \
     -s name=user_id \
     -s protocol=openid-connect \
     -s protocolMapper=oidc-usermodel-property-mapper \
     -s 'config."user.attribute"=id' \
     -s 'config."claim.name"=user_id' \
     -s 'config."jsonType.label"=String' \
     -s 'config."id.token.claim"=true' \
     -s 'config."access.token.claim"=true' \
     -s 'config."userinfo.token.claim"=true'

   # Mapper 5: audience (so .NET JWT validation can require aud=dhanman-api)
   /opt/keycloak/bin/kcadm.sh create client-scopes/$SCOPE_ID/protocol-mappers/models -r dhanman \
     -s name=dhanman-api-audience \
     -s protocol=openid-connect \
     -s protocolMapper=oidc-audience-mapper \
     -s 'config."included.custom.audience"=dhanman-api' \
     -s 'config."id.token.claim"=false' \
     -s 'config."access.token.claim"=true'
   ```

6. **Create the three clients.**

   **a) `dhanman-web` (public, PKCE):**

   ```bash
   /opt/keycloak/bin/kcadm.sh create clients -r dhanman \
     -s clientId=dhanman-web \
     -s name="Dhanman Web App" \
     -s enabled=true \
     -s publicClient=true \
     -s standardFlowEnabled=true \
     -s implicitFlowEnabled=false \
     -s directAccessGrantsEnabled=false \
     -s serviceAccountsEnabled=false \
     -s 'redirectUris=["https://app-qa.dhanman.com/auth/callback","https://app.dhanman.com/auth/callback"]' \
     -s 'webOrigins=["https://app-qa.dhanman.com","https://app.dhanman.com"]' \
     -s 'attributes."pkce.code.challenge.method"=S256' \
     -s 'attributes."post.logout.redirect.uris"=https://app-qa.dhanman.com##https://app.dhanman.com'
   ```

   Replace placeholder URLs with the real ones from Phase 0 inventory.

   **b) `dhanman-mobile` (public, PKCE, deep-link redirect):**

   ```bash
   /opt/keycloak/bin/kcadm.sh create clients -r dhanman \
     -s clientId=dhanman-mobile \
     -s name="Dhanman Mobile App" \
     -s enabled=true \
     -s publicClient=true \
     -s standardFlowEnabled=true \
     -s directAccessGrantsEnabled=false \
     -s 'redirectUris=["com.dhanman.app://callback"]' \
     -s 'attributes."pkce.code.challenge.method"=S256' \
     -s 'attributes."post.logout.redirect.uris"=com.dhanman.app://logout'
   ```

   **c) `dhanman-internal-admin` (public, PKCE):**

   ```bash
   /opt/keycloak/bin/kcadm.sh create clients -r dhanman \
     -s clientId=dhanman-internal-admin \
     -s name="Dhanman Internal Admin" \
     -s enabled=true \
     -s publicClient=true \
     -s standardFlowEnabled=true \
     -s 'redirectUris=["https://internal-qa.dhanman.com/auth/callback"]' \
     -s 'attributes."pkce.code.challenge.method"=S256'
   ```

7. **Attach `dhanman-claims` scope to all three clients as a default scope:**

   ```bash
   for client in dhanman-web dhanman-mobile dhanman-internal-admin; do
     CID=$(/opt/keycloak/bin/kcadm.sh get clients -r dhanman -q clientId=$client --fields id --format csv --noquotes | tail -n1)
     SID=$(/opt/keycloak/bin/kcadm.sh get client-scopes -r dhanman -q name=dhanman-claims --fields id --format csv --noquotes | tail -n1)
     /opt/keycloak/bin/kcadm.sh update clients/$CID/default-client-scopes/$SID -r dhanman
   done
   ```

8. **Create a confidential admin client for the migration tool (Phase 4) — service account with realm-management privileges:**

   ```bash
   # Create the client
   /opt/keycloak/bin/kcadm.sh create clients -r dhanman \
     -s clientId=dhanman-migration-tool \
     -s name="Dhanman User Migration Tool" \
     -s enabled=true \
     -s publicClient=false \
     -s serviceAccountsEnabled=true \
     -s standardFlowEnabled=false \
     -s directAccessGrantsEnabled=false

   # Get its UUID and secret
   MCID=$(/opt/keycloak/bin/kcadm.sh get clients -r dhanman -q clientId=dhanman-migration-tool --fields id --format csv --noquotes | tail -n1)
   /opt/keycloak/bin/kcadm.sh get clients/$MCID/client-secret -r dhanman

   # Grant realm-management roles to the service account
   SA_USER_ID=$(/opt/keycloak/bin/kcadm.sh get clients/$MCID/service-account-user -r dhanman --fields id --format csv --noquotes | tail -n1)
   RM_CLIENT_ID=$(/opt/keycloak/bin/kcadm.sh get clients -r dhanman -q clientId=realm-management --fields id --format csv --noquotes | tail -n1)

   for role in manage-users view-users query-users; do
     /opt/keycloak/bin/kcadm.sh add-roles -r dhanman \
       --uusername "service-account-dhanman-migration-tool" \
       --cclientid realm-management \
       --rolename $role
   done
   ```

   Store the client secret in Vault: `vault kv put secret/dhanman/migration/keycloak-client-secret value=<secret>`.

9. **Customize the password-reset email template.** This is what migrated users will see. In the admin UI: Realm settings → Email → templates can be overridden by placing `messages_en.properties` under `/opt/keycloak/themes/dhanman/email/messages/`. For now, the default template is fine — we'll polish it in Phase 11.

10. **Test token issuance manually with a temporary user:**

    ```bash
    # Create a test user with all custom attributes
    /opt/keycloak/bin/kcadm.sh create users -r dhanman \
      -s username=migration-test \
      -s email=test@dhanman.com \
      -s emailVerified=true \
      -s enabled=true \
      -s 'attributes.apartment_ids=["b1ff5e30-0000-0000-0000-000000000001"]' \
      -s 'attributes.organization_id=org-test-001' \
      -s 'attributes.role=committee_member'

    /opt/keycloak/bin/kcadm.sh set-password -r dhanman --username migration-test --new-password 'TestPass123!'
    ```

    Outside the container, get a token via direct grant (temporarily enable on dhanman-web for this test, then disable):

    ```bash
    # Temporarily allow direct grants on dhanman-web for this test only
    CID=$(curl -s -H "Authorization: Bearer $(get-admin-token)" \
      "https://auth-qa.dhanman.com/admin/realms/dhanman/clients?clientId=dhanman-web" | jq -r '.[0].id')

    # ... or just test via the browser by visiting the authorization URL directly:
    # https://auth-qa.dhanman.com/realms/dhanman/protocol/openid-connect/auth?client_id=dhanman-web&redirect_uri=https://oidcdebugger.com/debug&response_type=code&scope=openid+email+profile&state=test
    ```

    Decode the resulting access token at jwt.io. Confirm presence of: `iss`, `aud=dhanman-api`, `sub`, `user_id`, `apartment_ids`, `organization_id`, `role`, `email`.

    **Delete the test user after verification:**

    ```bash
    /opt/keycloak/bin/kcadm.sh delete users -r dhanman -q username=migration-test
    ```

**Verification:**

```bash
# Realm exists
curl -fs https://auth-qa.dhanman.com/realms/dhanman/.well-known/openid-configuration | jq .issuer
# Expected: "https://auth-qa.dhanman.com/realms/dhanman"

# JWKS exposed
curl -fs https://auth-qa.dhanman.com/realms/dhanman/protocol/openid-connect/certs | jq '.keys | length'
# Expected: ≥ 1

# Three clients exist
sudo docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r dhanman -q clientId=dhanman-web --fields clientId
sudo docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r dhanman -q clientId=dhanman-mobile --fields clientId
sudo docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r dhanman -q clientId=dhanman-internal-admin --fields clientId

# Migration client can get a service account token
curl -fs -X POST https://auth-qa.dhanman.com/realms/dhanman/protocol/openid-connect/token \
  -d "grant_type=client_credentials" \
  -d "client_id=dhanman-migration-tool" \
  -d "client_secret=<secret-from-vault>" | jq .access_token
# Expected: a JWT string
```

**Exit criteria:**
- Realm `dhanman` visible in admin console
- All three clients created with correct redirect URIs
- `dhanman-claims` client scope assigned as default to all three clients
- Test JWT contains all custom claims with correct values
- Migration tool service account can authenticate
- Test user deleted

**Rollback:**

```bash
sudo docker exec keycloak /opt/keycloak/bin/kcadm.sh delete realms/dhanman
```

This nukes the realm, all clients, all users in that realm. Master realm and the Keycloak install are untouched.

**Time:** 4 hours.

**Handover prompt:**
> Execute Phase 2 of the Dhanman Auth0 → Keycloak migration plan. Keycloak is running at `https://auth-qa.dhanman.com`. Admin credentials at Vault `secret/dhanman/qa/keycloak/admin`. Use the redirect URIs from `docs/auth-migration/auth0-inventory.md`. SMTP credentials at Vault `secret/dhanman/qa/smtp`. Stop and report when verification passes. Do not proceed to Phase 3.

---

## Phase 3 — dhanman-common dual-issuer JWT validation

**Goal:** `dhanman-common` accepts JWTs from either Auth0 or Keycloak. Every other microservice still trusts Auth0 only — common is the canary. The dual-issuer setup uses ASP.NET Core's policy scheme to route validation based on the token's `iss` claim.

**Prerequisites:** Phase 2 complete and verified.

**Inputs the agent will need:**
- Auth0 issuer URL and audience (from existing config)
- Keycloak issuer URL: `https://auth-qa.dhanman.com/realms/dhanman` (QA)
- Keycloak audience: `dhanman-api`
- Database write access to `dhanman-common` for the schema migration
- Vault paths for the new config values

**Steps:**

1. **Schema migration** — add nullable mapping columns to `users` table in `dhanman-common`. Create EF Core migration:

   ```bash
   cd src/Dhanman.Common.Persistence
   dotnet ef migrations add AddKeycloakIdentityMapping -c DhanmanDbContext
   ```

   Edit the generated migration so it produces:

   ```csharp
   public partial class AddKeycloakIdentityMapping : Migration
   {
       protected override void Up(MigrationBuilder migrationBuilder)
       {
           migrationBuilder.AddColumn<Guid>(
               name: "keycloak_id",
               table: "users",
               type: "uuid",
               nullable: true);

           migrationBuilder.AddColumn<string>(
               name: "auth_provider",
               table: "users",
               type: "varchar(20)",
               maxLength: 20,
               nullable: true,
               defaultValue: "auth0");

           migrationBuilder.CreateIndex(
               name: "ix_users_keycloak_id",
               table: "users",
               column: "keycloak_id",
               unique: true,
               filter: "keycloak_id IS NOT NULL");
       }

       protected override void Down(MigrationBuilder migrationBuilder)
       {
           migrationBuilder.DropIndex(name: "ix_users_keycloak_id", table: "users");
           migrationBuilder.DropColumn(name: "auth_provider", table: "users");
           migrationBuilder.DropColumn(name: "keycloak_id", table: "users");
       }
   }
   ```

   Apply on QA: `dotnet ef database update -c DhanmanDbContext` (or via Jenkins migration job).

2. **Update the `User` entity** in `Dhanman.Common.Domain.Entities`:

   ```csharp
   public class User : Entity
   {
       // ... existing properties ...

       public Guid? KeycloakId { get; set; }
       public string? AuthProvider { get; set; } = "auth0";
   }
   ```

   Update the EF configuration if you use explicit mappings.

3. **Update `appsettings.json` and `appsettings.<Env>.json`** in `Dhanman.Common.Api`:

   ```json
   {
     "Auth": {
       "Auth0": {
         "Authority": "https://<your-tenant>.auth0.com/",
         "Audience": "https://api.dhanman.com",
         "Enabled": true
       },
       "Keycloak": {
         "Authority": "https://auth-qa.dhanman.com/realms/dhanman",
         "Audience": "dhanman-api",
         "Enabled": true,
         "RequireHttpsMetadata": true
       }
     }
   }
   ```

   Pull values from Vault at startup as you do today.

4. **Replace JWT bearer registration in `Program.cs`:**

   ```csharp
   using System.IdentityModel.Tokens.Jwt;
   using Microsoft.AspNetCore.Authentication.JwtBearer;
   using Microsoft.IdentityModel.Tokens;

   var auth0Section = builder.Configuration.GetSection("Auth:Auth0");
   var keycloakSection = builder.Configuration.GetSection("Auth:Keycloak");

   builder.Services
       .AddAuthentication(options =>
       {
           options.DefaultAuthenticateScheme = "MultiAuth";
           options.DefaultChallengeScheme = "MultiAuth";
       })
       .AddJwtBearer("Auth0", options =>
       {
           options.Authority = auth0Section["Authority"];
           options.Audience = auth0Section["Audience"];
           options.RequireHttpsMetadata = true;
           options.TokenValidationParameters = new TokenValidationParameters
           {
               ValidateIssuer = true,
               ValidateAudience = true,
               ValidateLifetime = true,
               ValidateIssuerSigningKey = true,
               ClockSkew = TimeSpan.FromSeconds(30),
               NameClaimType = "sub"
           };
           options.Events = new JwtBearerEvents
           {
               OnAuthenticationFailed = ctx =>
               {
                   Log.Warning(ctx.Exception, "Auth0 JWT validation failed");
                   return Task.CompletedTask;
               }
           };
       })
       .AddJwtBearer("Keycloak", options =>
       {
           options.Authority = keycloakSection["Authority"];
           options.Audience = keycloakSection["Audience"];
           options.RequireHttpsMetadata = bool.Parse(keycloakSection["RequireHttpsMetadata"] ?? "true");
           options.TokenValidationParameters = new TokenValidationParameters
           {
               ValidateIssuer = true,
               ValidateAudience = true,
               ValidateLifetime = true,
               ValidateIssuerSigningKey = true,
               ClockSkew = TimeSpan.FromSeconds(30),
               // Keycloak puts Dhanman user UUID in custom claim "user_id"; sub is the Keycloak UUID
               NameClaimType = "user_id"
           };
           options.Events = new JwtBearerEvents
           {
               OnAuthenticationFailed = ctx =>
               {
                   Log.Warning(ctx.Exception, "Keycloak JWT validation failed");
                   return Task.CompletedTask;
               }
           };
       })
       .AddPolicyScheme("MultiAuth", "MultiAuth", options =>
       {
           options.ForwardDefaultSelector = context =>
           {
               var authHeader = context.Request.Headers.Authorization.ToString();
               if (string.IsNullOrEmpty(authHeader) || !authHeader.StartsWith("Bearer "))
                   return "Auth0"; // safe default; will fail validation cleanly

               var token = authHeader.Substring("Bearer ".Length);
               try
               {
                   var jwt = new JwtSecurityTokenHandler().ReadJwtToken(token);
                   var iss = jwt.Issuer ?? string.Empty;

                   if (iss.Contains("dhanman.com/realms/dhanman", StringComparison.OrdinalIgnoreCase))
                       return "Keycloak";

                   return "Auth0";
               }
               catch
               {
                   return "Auth0";
               }
           };
       });

   builder.Services.AddAuthorization();
   builder.Services.AddHttpContextAccessor();
   builder.Services.AddScoped<ICurrentUserService, CurrentUserService>();
   ```

5. **Implement `ICurrentUserService`** in `Dhanman.Common.Application`:

   ```csharp
   public interface ICurrentUserService
   {
       /// <summary>Internal Dhanman user GUID (users.id).</summary>
       Guid? UserId { get; }
       string AuthProvider { get; }
       string? Email { get; }
       Guid? OrganizationId { get; }
       IReadOnlyList<Guid> ApartmentIds { get; }
   }

   public sealed class CurrentUserService : ICurrentUserService
   {
       private readonly IHttpContextAccessor _ctx;
       private readonly DhanmanDbContext _db;
       private Guid? _cachedUserId;
       private bool _resolved;

       public CurrentUserService(IHttpContextAccessor ctx, DhanmanDbContext db)
       {
           _ctx = ctx;
           _db = db;
       }

       private System.Security.Claims.ClaimsPrincipal? Principal => _ctx.HttpContext?.User;

       public string AuthProvider
       {
           get
           {
               var iss = Principal?.FindFirst("iss")?.Value ?? string.Empty;
               return iss.Contains("/realms/dhanman", StringComparison.OrdinalIgnoreCase)
                   ? "keycloak"
                   : "auth0";
           }
       }

       public string? Email => Principal?.FindFirst("email")?.Value;

       public Guid? OrganizationId
       {
           get
           {
               var v = Principal?.FindFirst("organization_id")?.Value;
               return Guid.TryParse(v, out var g) ? g : null;
           }
       }

       public IReadOnlyList<Guid> ApartmentIds
       {
           get
           {
               var claims = Principal?.FindAll("apartment_ids")?.Select(c => c.Value) ?? Enumerable.Empty<string>();
               return claims
                   .Select(s => Guid.TryParse(s, out var g) ? (Guid?)g : null)
                   .Where(g => g.HasValue)
                   .Select(g => g!.Value)
                   .ToList();
           }
       }

       public Guid? UserId
       {
           get
           {
               if (_resolved) return _cachedUserId;
               _resolved = true;
               if (Principal == null) return null;

               if (AuthProvider == "keycloak")
               {
                   // Keycloak: prefer the user_id claim (which is Keycloak user UUID),
                   // resolve to internal Dhanman user id via keycloak_id mapping.
                   var kcId = Principal.FindFirst("user_id")?.Value
                              ?? Principal.FindFirst("sub")?.Value;
                   if (Guid.TryParse(kcId, out var g))
                   {
                       _cachedUserId = _db.Users
                           .Where(u => u.KeycloakId == g)
                           .Select(u => (Guid?)u.Id)
                           .FirstOrDefault();
                   }
               }
               else
               {
                   var sub = Principal.FindFirst("sub")?.Value;
                   if (!string.IsNullOrEmpty(sub))
                   {
                       _cachedUserId = _db.Users
                           .Where(u => u.ExternalId == sub)
                           .Select(u => (Guid?)u.Id)
                           .FirstOrDefault();
                   }
               }
               return _cachedUserId;
           }
       }
   }
   ```

   Replace any direct `User.FindFirst("sub")` access in handlers with `_currentUser.UserId`. Grep first:

   ```bash
   grep -rn 'FindFirst("sub")\|ClaimTypes.NameIdentifier' --include="*.cs" .
   ```

6. **Add structured logging middleware** to record which issuer authenticated each request:

   ```csharp
   app.Use(async (context, next) =>
   {
       if (context.User?.Identity?.IsAuthenticated == true)
       {
           var iss = context.User.FindFirst("iss")?.Value ?? "unknown";
           context.Items["AuthIssuer"] = iss;
           Log.Information("Auth: request authenticated via {Issuer}", iss);
       }
       await next();
   });
   ```

7. **Local build, test, deploy to QA via Jenkins:**

   ```bash
   dotnet build src/Dhanman.Common.sln -c Release
   dotnet test src/Dhanman.Common.sln -c Release
   ```

   Trigger the Jenkins QA deploy pipeline for `dhanman-common`.

**Verification:**

```bash
# 1. Existing Auth0 token still works
curl -fs -H "Authorization: Bearer <real-auth0-token>" \
  https://api-qa.dhanman.com/api/v1/users/me
# Expected: 200 with user details

# 2. Get a Keycloak token for an existing test user (you'll create them properly in Phase 4)
#    For now, manually create a test user in Keycloak admin UI, set both their
#    keycloak_id in dhanman-common.users and an apartment_ids attribute in Keycloak.
KC_TOKEN=$(curl -s -X POST \
  https://auth-qa.dhanman.com/realms/dhanman/protocol/openid-connect/token \
  -d "client_id=dhanman-web" \
  -d "username=test@dhanman.com" \
  -d "password=TestPass123!" \
  -d "grant_type=password" | jq -r .access_token)
# Note: password grant requires temporarily enabling directAccessGrantsEnabled on dhanman-web for this test.

curl -fs -H "Authorization: Bearer $KC_TOKEN" \
  https://api-qa.dhanman.com/api/v1/users/me
# Expected: 200 with the SAME user details as the Auth0 call

# 3. Loki should show two log lines per request:
#    "Auth: request authenticated via https://...auth0.com/"
#    "Auth: request authenticated via https://auth-qa.dhanman.com/realms/dhanman"
```

**Exit criteria:**
- Build and tests pass on the dual-issuer branch
- Schema migration applied to QA Postgres
- Existing Auth0-issued tokens continue to work in QA against `dhanman-common`
- A Keycloak-issued token (after manual user creation + mapping) returns the correct user
- Loki shows the issuer log line for both token types

**Rollback:**
- Revert the `Program.cs` change to single-issuer Auth0 (git revert + redeploy)
- Keep the schema columns — they are nullable and harmless
- No data loss

**Time:** 4 hours.

**Handover prompt:**
> Execute Phase 3 of the Dhanman Auth0 → Keycloak migration plan. Implement the dual-issuer JWT validation in `dhanman-common`. Keycloak issuer is `https://auth-qa.dhanman.com/realms/dhanman`, audience `dhanman-api`. Apply the EF Core migration to QA. Deploy via Jenkins. Verify both Auth0 and Keycloak tokens work. Stop and report when exit criteria are met.

---

## Phase 4 — User migration tool: Auth0 → Keycloak

**Goal:** A reusable, idempotent .NET 9 console tool that pulls every user from Auth0, creates them in Keycloak with the correct attributes, populates `dhanman-common.users.keycloak_id`, and triggers a password-reset email.

**Why no password hash migration:** Auth0 does not export password hashes (security policy). Users will set a new password on first login.

**Prerequisites:** Phase 3 deployed on QA.

**Inputs the agent will need:**
- Auth0 Management API credentials (Vault: `secret/dhanman/migration/auth0-mgmt`)
- Keycloak service-account credentials (Vault: `secret/dhanman/migration/keycloak-client-secret`)
- `dhanman-common` Postgres connection string (Vault: `secret/dhanman/qa/postgres/common`)

**Steps:**

1. **Generate Auth0 Management API credentials.** Auth0 dashboard → Applications → Create application → "Machine to Machine" → authorize for "Auth0 Management API" → grant scopes: `read:users`, `read:user_idp_tokens`. Store Client ID + Secret in Vault `secret/dhanman/migration/auth0-mgmt` as `client_id` and `client_secret`.

2. **Create the migration project:**

   ```bash
   mkdir -p tools/Dhanman.Auth.Migration
   cd tools/Dhanman.Auth.Migration
   dotnet new console --framework net9.0
   dotnet add package Microsoft.Extensions.Hosting --version 9.0.0
   dotnet add package Microsoft.Extensions.Configuration.Json --version 9.0.0
   dotnet add package Microsoft.Extensions.Configuration.EnvironmentVariables --version 9.0.0
   dotnet add package Serilog.Extensions.Hosting --version 8.0.0
   dotnet add package Serilog.Sinks.Console --version 5.0.0
   dotnet add package Serilog.Sinks.File --version 5.0.0
   dotnet add package Npgsql --version 8.0.4
   dotnet add package Polly --version 8.4.0
   dotnet add package System.CommandLine --version 2.0.0-beta4.22272.1
   ```

3. **Create `appsettings.json`** (committed; secrets pulled from env at runtime):

   ```json
   {
     "Auth0": {
       "Domain": "<your-tenant>.auth0.com",
       "Audience": "https://<your-tenant>.auth0.com/api/v2/"
     },
     "Keycloak": {
       "Authority": "https://auth-qa.dhanman.com",
       "Realm": "dhanman",
       "ClientId": "dhanman-migration-tool",
       "WebClientId": "dhanman-web"
     },
     "Database": {
       "ConnectionString": "Host=<host>;Port=5432;Database=dhanman_common;Username=migration_user;Password=__VAULT__"
     },
     "Migration": {
       "BatchSize": 100,
       "ApartmentIdFilter": null,
       "DryRun": true,
       "SendPasswordResetEmail": true,
       "PasswordResetActionLifespanSeconds": 86400
     }
   }
   ```

4. **Create `Program.cs`** (full implementation, not pseudocode):

   ```csharp
   using System.CommandLine;
   using Microsoft.Extensions.Configuration;
   using Microsoft.Extensions.DependencyInjection;
   using Microsoft.Extensions.Hosting;
   using Serilog;

   var dryRunOpt = new Option<bool>("--dry-run", "Log actions without writing");
   var apartmentOpt = new Option<Guid?>("--apartment-id", "Migrate only users belonging to this apartment");
   var batchOpt = new Option<int>("--batch-size", () => 100, "Auth0 page size");

   var root = new RootCommand("Dhanman Auth0 → Keycloak migration tool");
   root.AddOption(dryRunOpt); root.AddOption(apartmentOpt); root.AddOption(batchOpt);

   root.SetHandler(async (dryRun, apartmentId, batchSize) =>
   {
       var host = Host.CreateDefaultBuilder()
           .ConfigureAppConfiguration(cfg =>
           {
               cfg.AddJsonFile("appsettings.json", optional: false);
               cfg.AddEnvironmentVariables(prefix: "DHANMAN_");
           })
           .ConfigureServices((ctx, services) =>
           {
               services.AddHttpClient();
               services.AddSingleton<Auth0Client>();
               services.AddSingleton<KeycloakClient>();
               services.AddSingleton<DhanmanDbClient>();
               services.AddSingleton(new MigrationOptions
               {
                   DryRun = dryRun,
                   ApartmentIdFilter = apartmentId,
                   BatchSize = batchSize
               });
               services.AddSingleton<MigrationOrchestrator>();
           })
           .UseSerilog((ctx, lc) => lc
               .WriteTo.Console()
               .WriteTo.File("logs/migration-.log", rollingInterval: RollingInterval.Day))
           .Build();

       var orchestrator = host.Services.GetRequiredService<MigrationOrchestrator>();
       await orchestrator.RunAsync();
   }, dryRunOpt, apartmentOpt, batchOpt);

   return await root.InvokeAsync(args);

   public class MigrationOptions
   {
       public bool DryRun { get; set; }
       public Guid? ApartmentIdFilter { get; set; }
       public int BatchSize { get; set; } = 100;
   }
   ```

5. **Create `Auth0Client.cs`:**

   ```csharp
   using System.Net.Http.Headers;
   using System.Net.Http.Json;
   using System.Text.Json;
   using System.Text.Json.Serialization;
   using Microsoft.Extensions.Configuration;
   using Polly;
   using Polly.Retry;

   public sealed class Auth0Client
   {
       private readonly HttpClient _http;
       private readonly IConfiguration _cfg;
       private string? _token;
       private DateTime _tokenExpires;
       private readonly AsyncRetryPolicy _retry;

       public Auth0Client(IHttpClientFactory factory, IConfiguration cfg)
       {
           _http = factory.CreateClient("auth0");
           _http.BaseAddress = new Uri($"https://{cfg["Auth0:Domain"]}/");
           _cfg = cfg;
           _retry = Policy
               .Handle<HttpRequestException>()
               .Or<TaskCanceledException>()
               .WaitAndRetryAsync(5, n => TimeSpan.FromSeconds(Math.Pow(2, n)));
       }

       private async Task EnsureTokenAsync()
       {
           if (_token != null && _tokenExpires > DateTime.UtcNow.AddMinutes(1)) return;

           var resp = await _http.PostAsJsonAsync("oauth/token", new
           {
               client_id = Environment.GetEnvironmentVariable("DHANMAN_AUTH0_CLIENT_ID"),
               client_secret = Environment.GetEnvironmentVariable("DHANMAN_AUTH0_CLIENT_SECRET"),
               audience = _cfg["Auth0:Audience"],
               grant_type = "client_credentials"
           });
           resp.EnsureSuccessStatusCode();
           var tok = await resp.Content.ReadFromJsonAsync<TokenResponse>();
           _token = tok!.AccessToken;
           _tokenExpires = DateTime.UtcNow.AddSeconds(tok.ExpiresIn);
           _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", _token);
       }

       public async IAsyncEnumerable<Auth0User> StreamUsersAsync(int pageSize)
       {
           await EnsureTokenAsync();
           int page = 0;
           while (true)
           {
               var url = $"api/v2/users?per_page={pageSize}&page={page}&include_totals=false&fields=user_id,email,email_verified,given_name,family_name,name,created_at,last_login";
               var users = await _retry.ExecuteAsync(() =>
                   _http.GetFromJsonAsync<List<Auth0User>>(url))
                   ?? new List<Auth0User>();

               if (users.Count == 0) yield break;
               foreach (var u in users) yield return u;
               page++;
               // Auth0 default rate limit ~ 2 requests/sec on free tenants
               await Task.Delay(600);
           }
       }

       private sealed class TokenResponse
       {
           [JsonPropertyName("access_token")] public string AccessToken { get; set; } = "";
           [JsonPropertyName("expires_in")]   public int ExpiresIn { get; set; }
       }
   }

   public sealed class Auth0User
   {
       [JsonPropertyName("user_id")]        public string UserId { get; set; } = "";
       [JsonPropertyName("email")]          public string? Email { get; set; }
       [JsonPropertyName("email_verified")] public bool EmailVerified { get; set; }
       [JsonPropertyName("given_name")]     public string? GivenName { get; set; }
       [JsonPropertyName("family_name")]    public string? FamilyName { get; set; }
       [JsonPropertyName("name")]           public string? Name { get; set; }
   }
   ```

6. **Create `KeycloakClient.cs`:**

   ```csharp
   using System.Net.Http.Headers;
   using System.Net.Http.Json;
   using System.Text.Json;
   using System.Text.Json.Serialization;
   using Microsoft.Extensions.Configuration;
   using Polly;
   using Polly.Retry;

   public sealed class KeycloakClient
   {
       private readonly HttpClient _http;
       private readonly IConfiguration _cfg;
       private string? _token;
       private DateTime _tokenExpires;
       private readonly AsyncRetryPolicy<HttpResponseMessage> _retry;

       public KeycloakClient(IHttpClientFactory factory, IConfiguration cfg)
       {
           _http = factory.CreateClient("keycloak");
           _http.BaseAddress = new Uri(cfg["Keycloak:Authority"]!);
           _cfg = cfg;
           _retry = Policy
               .HandleResult<HttpResponseMessage>(r =>
                   r.StatusCode == System.Net.HttpStatusCode.TooManyRequests ||
                   (int)r.StatusCode >= 500)
               .WaitAndRetryAsync(5, n => TimeSpan.FromSeconds(Math.Pow(2, n)));
       }

       private async Task EnsureTokenAsync()
       {
           if (_token != null && _tokenExpires > DateTime.UtcNow.AddMinutes(1)) return;

           var realm = _cfg["Keycloak:Realm"];
           var content = new FormUrlEncodedContent(new Dictionary<string, string>
           {
               ["grant_type"]    = "client_credentials",
               ["client_id"]     = _cfg["Keycloak:ClientId"]!,
               ["client_secret"] = Environment.GetEnvironmentVariable("DHANMAN_KEYCLOAK_CLIENT_SECRET")!
           });
           var resp = await _http.PostAsync($"realms/{realm}/protocol/openid-connect/token", content);
           resp.EnsureSuccessStatusCode();
           var tok = await resp.Content.ReadFromJsonAsync<TokenResponse>();
           _token = tok!.AccessToken;
           _tokenExpires = DateTime.UtcNow.AddSeconds(tok.ExpiresIn);
           _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", _token);
       }

       /// <summary>Returns existing Keycloak user id if email already exists, otherwise null.</summary>
       public async Task<Guid?> FindByEmailAsync(string email)
       {
           await EnsureTokenAsync();
           var realm = _cfg["Keycloak:Realm"];
           var resp = await _http.GetAsync(
               $"admin/realms/{realm}/users?email={Uri.EscapeDataString(email)}&exact=true");
           resp.EnsureSuccessStatusCode();
           var users = await resp.Content.ReadFromJsonAsync<List<KcUser>>();
           return users?.FirstOrDefault()?.Id;
       }

       public async Task<Guid> CreateUserAsync(KcCreateUser user)
       {
           await EnsureTokenAsync();
           var realm = _cfg["Keycloak:Realm"];
           var resp = await _retry.ExecuteAsync(() =>
               _http.PostAsJsonAsync($"admin/realms/{realm}/users", user));
           resp.EnsureSuccessStatusCode();
           // Keycloak returns Location: /admin/realms/{realm}/users/{id}
           var location = resp.Headers.Location!.ToString();
           var idStr = location.Split('/').Last();
           return Guid.Parse(idStr);
       }

       public async Task SendExecuteActionsEmailAsync(Guid userId, string clientId, int lifespanSeconds, params string[] actions)
       {
           await EnsureTokenAsync();
           var realm = _cfg["Keycloak:Realm"];
           var url = $"admin/realms/{realm}/users/{userId}/execute-actions-email?client_id={clientId}&lifespan={lifespanSeconds}";
           var resp = await _http.PutAsync(url, JsonContent.Create(actions));
           resp.EnsureSuccessStatusCode();
       }

       private sealed class TokenResponse
       {
           [JsonPropertyName("access_token")] public string AccessToken { get; set; } = "";
           [JsonPropertyName("expires_in")]   public int ExpiresIn { get; set; }
       }

       private sealed class KcUser
       {
           [JsonPropertyName("id")]    public Guid Id { get; set; }
           [JsonPropertyName("email")] public string? Email { get; set; }
       }
   }

   public sealed class KcCreateUser
   {
       [JsonPropertyName("username")]      public string Username { get; set; } = "";
       [JsonPropertyName("email")]         public string Email { get; set; } = "";
       [JsonPropertyName("emailVerified")] public bool EmailVerified { get; set; }
       [JsonPropertyName("firstName")]     public string? FirstName { get; set; }
       [JsonPropertyName("lastName")]      public string? LastName { get; set; }
       [JsonPropertyName("enabled")]       public bool Enabled { get; set; } = true;
       [JsonPropertyName("attributes")]    public Dictionary<string, List<string>>? Attributes { get; set; }
       [JsonPropertyName("requiredActions")] public List<string>? RequiredActions { get; set; }
   }
   ```

7. **Create `DhanmanDbClient.cs`:**

   ```csharp
   using Microsoft.Extensions.Configuration;
   using Npgsql;

   public sealed class DhanmanDbClient
   {
       private readonly string _conn;

       public DhanmanDbClient(IConfiguration cfg)
       {
           // Replace __VAULT__ placeholder at runtime
           var template = cfg["Database:ConnectionString"]!;
           var pw = Environment.GetEnvironmentVariable("DHANMAN_DB_PASSWORD")!;
           _conn = template.Replace("__VAULT__", pw);
       }

       public async IAsyncEnumerable<DhanmanUserRow> StreamUsersAsync(Guid? apartmentFilter)
       {
           await using var conn = new NpgsqlConnection(_conn);
           await conn.OpenAsync();

           var sql = @"
               SELECT u.id, u.external_id, u.email, u.organization_id, u.role,
                      u.keycloak_id,
                      COALESCE(array_agg(DISTINCT ua.apartment_id) FILTER (WHERE ua.apartment_id IS NOT NULL), '{}') AS apartment_ids
               FROM users u
               LEFT JOIN user_apartments ua ON ua.user_id = u.id
               WHERE u.external_id IS NOT NULL
                 AND u.is_deleted = false
           ";
           if (apartmentFilter.HasValue)
               sql += " AND EXISTS (SELECT 1 FROM user_apartments uaf WHERE uaf.user_id = u.id AND uaf.apartment_id = @apt) ";
           sql += " GROUP BY u.id";

           await using var cmd = new NpgsqlCommand(sql, conn);
           if (apartmentFilter.HasValue)
               cmd.Parameters.AddWithValue("apt", apartmentFilter.Value);

           await using var rdr = await cmd.ExecuteReaderAsync();
           while (await rdr.ReadAsync())
           {
               yield return new DhanmanUserRow
               {
                   Id             = rdr.GetGuid(0),
                   ExternalId     = rdr.GetString(1),
                   Email          = rdr.IsDBNull(2) ? null : rdr.GetString(2),
                   OrganizationId = rdr.IsDBNull(3) ? null : rdr.GetGuid(3),
                   Role           = rdr.IsDBNull(4) ? null : rdr.GetString(4),
                   KeycloakId     = rdr.IsDBNull(5) ? null : rdr.GetGuid(5),
                   ApartmentIds   = (Guid[])rdr.GetValue(6)
               };
           }
       }

       public async Task UpdateKeycloakMappingAsync(Guid userId, Guid keycloakId)
       {
           await using var conn = new NpgsqlConnection(_conn);
           await conn.OpenAsync();
           await using var cmd = new NpgsqlCommand(
               "UPDATE users SET keycloak_id = @kc, modified_on_utc = NOW() WHERE id = @id", conn);
           cmd.Parameters.AddWithValue("kc", keycloakId);
           cmd.Parameters.AddWithValue("id", userId);
           await cmd.ExecuteNonQueryAsync();
       }

       public async Task SetAuthProviderAsync(Guid userId, string provider)
       {
           await using var conn = new NpgsqlConnection(_conn);
           await conn.OpenAsync();
           await using var cmd = new NpgsqlCommand(
               "UPDATE users SET auth_provider = @p, modified_on_utc = NOW() WHERE id = @id", conn);
           cmd.Parameters.AddWithValue("p", provider);
           cmd.Parameters.AddWithValue("id", userId);
           await cmd.ExecuteNonQueryAsync();
       }
   }

   public sealed class DhanmanUserRow
   {
       public Guid Id { get; set; }
       public string ExternalId { get; set; } = "";
       public string? Email { get; set; }
       public Guid? OrganizationId { get; set; }
       public string? Role { get; set; }
       public Guid? KeycloakId { get; set; }
       public Guid[] ApartmentIds { get; set; } = Array.Empty<Guid>();
   }
   ```

8. **Create `MigrationOrchestrator.cs`:**

   ```csharp
   using Microsoft.Extensions.Configuration;
   using Serilog;

   public sealed class MigrationOrchestrator
   {
       private readonly Auth0Client _auth0;
       private readonly KeycloakClient _kc;
       private readonly DhanmanDbClient _db;
       private readonly MigrationOptions _opts;
       private readonly IConfiguration _cfg;

       public MigrationOrchestrator(Auth0Client auth0, KeycloakClient kc, DhanmanDbClient db,
                                    MigrationOptions opts, IConfiguration cfg)
       {
           _auth0 = auth0; _kc = kc; _db = db; _opts = opts; _cfg = cfg;
       }

       public async Task RunAsync()
       {
           Log.Information("Starting migration. DryRun={Dry} ApartmentFilter={Apt}",
               _opts.DryRun, _opts.ApartmentIdFilter);

           // Step 1: Index Dhanman users by Auth0 sub (external_id)
           var dhanmanByExternalId = new Dictionary<string, DhanmanUserRow>();
           await foreach (var row in _db.StreamUsersAsync(_opts.ApartmentIdFilter))
           {
               dhanmanByExternalId[row.ExternalId] = row;
           }
           Log.Information("Loaded {Count} Dhanman users matching filter", dhanmanByExternalId.Count);

           int created = 0, skippedAlreadyMigrated = 0, skippedNoMatch = 0, failed = 0;

           // Step 2: Walk Auth0 users
           await foreach (var au in _auth0.StreamUsersAsync(_opts.BatchSize))
           {
               if (!dhanmanByExternalId.TryGetValue(au.UserId, out var dhRow))
               {
                   skippedNoMatch++;
                   continue;
               }
               if (dhRow.KeycloakId != null)
               {
                   skippedAlreadyMigrated++;
                   continue;
               }
               if (string.IsNullOrEmpty(au.Email))
               {
                   Log.Warning("Auth0 user {Sub} has no email, skipping", au.UserId);
                   failed++;
                   continue;
               }

               try
               {
                   // Idempotency: check if Keycloak already has this email
                   var existing = await _kc.FindByEmailAsync(au.Email);
                   Guid keycloakId;

                   if (existing.HasValue)
                   {
                       Log.Information("Keycloak user already exists for {Email} (id {Id}), reusing",
                           au.Email, existing);
                       keycloakId = existing.Value;
                   }
                   else
                   {
                       var kcUser = new KcCreateUser
                       {
                           Username      = au.Email,
                           Email         = au.Email,
                           EmailVerified = au.EmailVerified,
                           FirstName     = au.GivenName,
                           LastName      = au.FamilyName,
                           Enabled       = true,
                           Attributes    = new Dictionary<string, List<string>>
                           {
                               ["apartment_ids"]  = dhRow.ApartmentIds.Select(g => g.ToString()).ToList(),
                               ["organization_id"] = new List<string> { dhRow.OrganizationId?.ToString() ?? "" },
                               ["role"]           = new List<string> { dhRow.Role ?? "" }
                           },
                           RequiredActions = new List<string> { "UPDATE_PASSWORD", "VERIFY_EMAIL" }
                       };

                       if (_opts.DryRun)
                       {
                           Log.Information("[DRY] Would create Keycloak user: {Email}", au.Email);
                           continue;
                       }

                       keycloakId = await _kc.CreateUserAsync(kcUser);
                   }

                   if (!_opts.DryRun)
                   {
                       await _db.UpdateKeycloakMappingAsync(dhRow.Id, keycloakId);

                       // Send password-reset email
                       await _kc.SendExecuteActionsEmailAsync(
                           keycloakId,
                           _cfg["Keycloak:WebClientId"]!,
                           int.Parse(_cfg["Migration:PasswordResetActionLifespanSeconds"] ?? "86400"),
                           "UPDATE_PASSWORD", "VERIFY_EMAIL");
                   }

                   created++;
                   Log.Information("Migrated {Email} → keycloak_id {Kc}", au.Email, keycloakId);
               }
               catch (Exception ex)
               {
                   failed++;
                   Log.Error(ex, "Migration failed for {Email}", au.Email);
               }
           }

           Log.Information("Done. Created={C} AlreadyMigrated={A} NoDhanmanMatch={N} Failed={F}",
               created, skippedAlreadyMigrated, skippedNoMatch, failed);
       }
   }
   ```

9. **Run dry-run on QA first:**

   ```bash
   export DHANMAN_AUTH0_CLIENT_ID=$(vault kv get -field=client_id secret/dhanman/migration/auth0-mgmt)
   export DHANMAN_AUTH0_CLIENT_SECRET=$(vault kv get -field=client_secret secret/dhanman/migration/auth0-mgmt)
   export DHANMAN_KEYCLOAK_CLIENT_SECRET=$(vault kv get -field=value secret/dhanman/migration/keycloak-client-secret)
   export DHANMAN_DB_PASSWORD=$(vault kv get -field=value secret/dhanman/qa/postgres/migration_user)

   dotnet run -- --dry-run
   ```

   Inspect logs. Confirm counts match expectations (`SELECT COUNT(*) FROM users WHERE external_id IS NOT NULL AND is_deleted = false`).

10. **Run for real on QA:**

    ```bash
    dotnet run
    ```

11. **Have one QA tester click their password-reset email**, set a new password, and log into the React app (after Phase 5 lands). End-to-end verification before promoting to PROD.

**Verification:**

```sql
-- After migration completes
SELECT COUNT(*) FILTER (WHERE external_id IS NOT NULL) AS auth0_users,
       COUNT(*) FILTER (WHERE keycloak_id IS NOT NULL) AS migrated,
       COUNT(*) FILTER (WHERE keycloak_id IS NULL AND external_id IS NOT NULL) AS pending
FROM users
WHERE is_deleted = false;
-- Expected: migrated == auth0_users, pending == 0 (or only known exclusions)
```

```bash
# Spot-check 5 users in Keycloak
sudo docker exec keycloak /opt/keycloak/bin/kcadm.sh get users -r dhanman -q max=5 \
  --fields id,email,emailVerified,attributes,requiredActions
# Expected: 5 users with apartment_ids/organization_id/role attributes set
```

**Exit criteria:**
- All Auth0 users present in Keycloak (counts match)
- `users.keycloak_id` populated for all migrated users
- Password-reset emails delivered (check inbox of one test user)
- One end-to-end manual login by a QA tester succeeds

**Rollback:**

```bash
# Wipe Keycloak users (DESTRUCTIVE — only on QA)
sudo docker exec keycloak /opt/keycloak/bin/kcadm.sh get users -r dhanman --fields id --format csv --noquotes \
  | tail -n +2 | xargs -I{} sudo docker exec keycloak /opt/keycloak/bin/kcadm.sh delete users/{} -r dhanman

# Reset mapping in dhanman-common
psql "$CONN" -c "UPDATE users SET keycloak_id = NULL, auth_provider = 'auth0' WHERE keycloak_id IS NOT NULL;"
```

**Time:** 8 hours (most of it spent writing and testing the migration tool).

**Handover prompt:**
> Execute Phase 4 of the Dhanman Auth0 → Keycloak migration plan. Build the .NET 9 console migration tool at `tools/Dhanman.Auth.Migration/`. Run dry-run first, then real migration against QA. The plan contains all source files in full — copy them as-is. Verify with the SQL queries provided. Stop and report when exit criteria are met.

---

## Phase 5 — React frontend dual-flow

**Goal:** The React web app authenticates via either Auth0 or Keycloak. Routing is per-user, based on a flag returned by `dhanman-common`.

**Prerequisites:** Phase 4 complete on QA (Keycloak has users mapped).

**Inputs the agent will need:**
- React repo path
- Existing Auth0 React SDK config
- Keycloak QA URL: `https://auth-qa.dhanman.com/realms/dhanman`
- Keycloak `dhanman-web` client id

**Steps:**

1. **Add a public endpoint to `dhanman-common`** — given an email, return which provider:

   File: `src/Dhanman.Common.Api/Controllers/AuthDiscoveryController.cs`

   ```csharp
   using Microsoft.AspNetCore.Authorization;
   using Microsoft.AspNetCore.Mvc;
   using Microsoft.EntityFrameworkCore;

   [ApiController]
   [Route("api/v1/auth")]
   [AllowAnonymous]
   public sealed class AuthDiscoveryController : ControllerBase
   {
       private readonly DhanmanDbContext _db;
       public AuthDiscoveryController(DhanmanDbContext db) => _db = db;

       [HttpGet("provider")]
       [ResponseCache(Duration = 300, Location = ResponseCacheLocation.Any)]
       public async Task<IActionResult> GetProvider([FromQuery] string email)
       {
           if (string.IsNullOrWhiteSpace(email)) return BadRequest();

           var provider = await _db.Users
               .Where(u => u.Email.ToLower() == email.ToLower() && !u.IsDeleted)
               .Select(u => u.AuthProvider)
               .FirstOrDefaultAsync();

           // Default new emails to keycloak (post-cutover) or auth0 (during transition).
           // During transition, default to "auth0" so unmapped users still log in via Auth0.
           return Ok(new { provider = provider ?? "auth0" });
       }
   }
   ```

2. **Install Keycloak OIDC client.** From the React repo root:

   ```bash
   npm install react-oidc-context oidc-client-ts
   ```

   Keep `@auth0/auth0-react` installed during transition.

3. **Add config to `.env.qa` and `.env.production`:**

   ```
   VITE_KEYCLOAK_AUTHORITY=https://auth-qa.dhanman.com/realms/dhanman
   VITE_KEYCLOAK_CLIENT_ID=dhanman-web
   ```

4. **Create `src/auth/keycloakConfig.ts`:**

   ```ts
   import { UserManagerSettings } from 'oidc-client-ts';

   export const keycloakConfig: UserManagerSettings = {
     authority: import.meta.env.VITE_KEYCLOAK_AUTHORITY,
     client_id: import.meta.env.VITE_KEYCLOAK_CLIENT_ID,
     redirect_uri: `${window.location.origin}/auth/callback`,
     post_logout_redirect_uri: window.location.origin,
     response_type: 'code',
     scope: 'openid email profile offline_access',
     loadUserInfo: true,
     automaticSilentRenew: true,
     monitorSession: false
   };
   ```

5. **Create `src/auth/AuthRouter.tsx`** — a two-step login that decides provider after email entry:

   ```tsx
   import { useState } from 'react';
   import { AuthProvider as OidcProvider, useAuth as useOidcAuth } from 'react-oidc-context';
   import { Auth0Provider, useAuth0 } from '@auth0/auth0-react';
   import { keycloakConfig } from './keycloakConfig';
   import axios from 'axios';

   type Provider = 'auth0' | 'keycloak' | null;

   export function AuthRouter({ children }: { children: React.ReactNode }) {
     const [provider, setProvider] = useState<Provider>(
       (sessionStorage.getItem('auth_provider') as Provider) ?? null
     );

     // Email-entry screen if not yet decided
     if (!provider && !window.location.pathname.startsWith('/auth/callback')) {
       return <EmailGate onResolved={(p) => {
         sessionStorage.setItem('auth_provider', p);
         setProvider(p);
       }} />;
     }

     if (provider === 'keycloak' || sessionStorage.getItem('auth_provider') === 'keycloak') {
       return <OidcProvider {...keycloakConfig}>{children}</OidcProvider>;
     }

     return (
       <Auth0Provider
         domain={import.meta.env.VITE_AUTH0_DOMAIN}
         clientId={import.meta.env.VITE_AUTH0_CLIENT_ID}
         authorizationParams={{
           redirect_uri: `${window.location.origin}/auth/callback`,
           audience: import.meta.env.VITE_AUTH0_AUDIENCE
         }}
       >
         {children}
       </Auth0Provider>
     );
   }

   function EmailGate({ onResolved }: { onResolved: (p: Provider) => void }) {
     const [email, setEmail] = useState('');
     const [busy, setBusy] = useState(false);

     const submit = async (e: React.FormEvent) => {
       e.preventDefault();
       setBusy(true);
       try {
         const r = await axios.get(`/api/v1/auth/provider?email=${encodeURIComponent(email)}`);
         onResolved(r.data.provider as Provider);
       } finally {
         setBusy(false);
       }
     };

     return (
       <form onSubmit={submit} style={{ maxWidth: 400, margin: '120px auto', padding: 24 }}>
         <h2>Sign in to Dhanman</h2>
         <input
           type="email" required value={email}
           onChange={(e) => setEmail(e.target.value)}
           placeholder="Email address"
           style={{ width: '100%', padding: 12, fontSize: 16 }}
         />
         <button type="submit" disabled={busy} style={{ marginTop: 16, padding: 12, width: '100%' }}>
           {busy ? 'Checking…' : 'Continue'}
         </button>
       </form>
     );
   }
   ```

6. **Unified token accessor for axios interceptor.** Replace existing Auth0-specific token logic in `src/api/axios.ts`:

   ```ts
   import axios from 'axios';
   import { User } from 'oidc-client-ts';

   function getOidcUser(): User | null {
     const authority = import.meta.env.VITE_KEYCLOAK_AUTHORITY;
     const clientId = import.meta.env.VITE_KEYCLOAK_CLIENT_ID;
     const key = `oidc.user:${authority}:${clientId}`;
     const raw = sessionStorage.getItem(key);
     return raw ? User.fromStorageString(raw) : null;
   }

   export function setupAxios(getAuth0Token: () => Promise<string | undefined>) {
     axios.interceptors.request.use(async (config) => {
       const provider = sessionStorage.getItem('auth_provider');
       let token: string | undefined;

       if (provider === 'keycloak') {
         token = getOidcUser()?.access_token;
       } else {
         token = await getAuth0Token();
       }

       if (token) config.headers.Authorization = `Bearer ${token}`;
       return config;
     });
   }
   ```

7. **Logout** — must hit the active provider's end-session endpoint:

   ```ts
   export async function logout() {
     const provider = sessionStorage.getItem('auth_provider');
     sessionStorage.removeItem('auth_provider');

     if (provider === 'keycloak') {
       const authority = import.meta.env.VITE_KEYCLOAK_AUTHORITY;
       window.location.href = `${authority}/protocol/openid-connect/logout?post_logout_redirect_uri=${encodeURIComponent(window.location.origin)}&client_id=${import.meta.env.VITE_KEYCLOAK_CLIENT_ID}`;
     } else {
       // Existing Auth0 logout call
     }
   }
   ```

8. **Build, deploy to QA, smoke test:**

   ```bash
   npm run build:qa
   # Deploy via existing Jenkins pipeline
   ```

**Verification:**

End-to-end manual tests on QA:

| Test case | Expected |
|---|---|
| Existing Auth0 user enters email → email gate decides "auth0" → Auth0 Universal Login → returns to app | Logged in, dashboard loads with their data |
| Migrated Keycloak user enters email → email gate decides "keycloak" → Keycloak login screen → enters new password (forced reset) → returns to app | Logged in, dashboard loads with their data |
| Same Keycloak user logs out → logs back in (same browser) | Logs in successfully without forced reset (password is set now) |
| Keycloak user lets access token expire (1h) and continues using app | Silent renew refreshes token, no re-login prompt |

**Exit criteria:**
- All test cases pass on QA
- Network tab shows correct `Authorization: Bearer ...` header for both flows
- No regressions for existing Auth0 users

**Rollback:** Revert React build to previous Auth0-only version. Backend still accepts both, so safe.

**Time:** 6 hours.

**Handover prompt:**
> Execute Phase 5 of the Dhanman Auth0 → Keycloak migration plan. Add the `/api/v1/auth/provider` endpoint to `dhanman-common` and implement the React dual-flow per the plan. The plan contains full code for the controller, AuthRouter component, axios interceptor, and logout helper. Deploy to QA. Run all four verification test cases. Stop and report when exit criteria are met.

---

## Phase 6 — Flutter mobile Keycloak integration

**Goal:** The Flutter app authenticates via Keycloak (and Auth0 during transition), refreshes tokens correctly across backgrounding/network drops, and SignalR connections accept the new JWT on both Android and iOS.

**This is the highest-risk phase. Allocate generous time and test on REAL devices.**

**Prerequisites:** Phase 5 deployed to QA.

**Inputs the agent will need:**
- Flutter repo path
- Android `applicationId` (for deep-link scheme)
- iOS bundle identifier
- Existing Auth0 Flutter config

**Steps:**

1. **Add packages to `pubspec.yaml`:**

   ```yaml
   dependencies:
     flutter_appauth: ^7.0.0
     flutter_secure_storage: ^9.2.0
     http: ^1.2.0
   ```

   ```bash
   flutter pub get
   ```

2. **Configure Android deep links** in `android/app/src/main/AndroidManifest.xml`:

   ```xml
   <activity
       android:name="net.openid.appauth.RedirectUriReceiverActivity"
       android:exported="true"
       tools:node="replace">
       <intent-filter>
           <action android:name="android.intent.action.VIEW" />
           <category android:name="android.intent.category.DEFAULT" />
           <category android:name="android.intent.category.BROWSABLE" />
           <data android:scheme="com.dhanman.app" android:host="callback" />
       </intent-filter>
   </activity>
   ```

   Also in `android/app/build.gradle`, ensure:

   ```gradle
   defaultConfig {
       manifestPlaceholders = [
           'appAuthRedirectScheme': 'com.dhanman.app'
       ]
   }
   ```

   Confirm `com.dhanman.app://callback` is registered as an allowed redirect URI on the `dhanman-mobile` Keycloak client (Phase 2).

3. **Configure iOS deep links** in `ios/Runner/Info.plist`:

   ```xml
   <key>CFBundleURLTypes</key>
   <array>
     <dict>
       <key>CFBundleTypeRole</key>
       <string>Editor</string>
       <key>CFBundleURLName</key>
       <string>com.dhanman.app</string>
       <key>CFBundleURLSchemes</key>
       <array>
         <string>com.dhanman.app</string>
       </array>
     </dict>
   </array>
   ```

4. **Create `lib/auth/keycloak_auth.dart`:**

   ```dart
   import 'package:flutter_appauth/flutter_appauth.dart';
   import 'package:flutter_secure_storage/flutter_secure_storage.dart';

   class KeycloakAuth {
     static const _kClientId = 'dhanman-mobile';
     static const _kRedirectUri = 'com.dhanman.app://callback';
     // Wire from --dart-define / build flavor
     static const _kDiscoveryUrl = String.fromEnvironment(
       'KEYCLOAK_DISCOVERY_URL',
       defaultValue: 'https://auth-qa.dhanman.com/realms/dhanman/.well-known/openid-configuration',
     );

     static const _kScopes = ['openid', 'email', 'profile', 'offline_access'];

     final FlutterAppAuth _appAuth = FlutterAppAuth();
     final FlutterSecureStorage _storage = const FlutterSecureStorage(
       aOptions: AndroidOptions(encryptedSharedPreferences: true),
     );

     Future<bool> login() async {
       try {
         final result = await _appAuth.authorizeAndExchangeCode(
           AuthorizationTokenRequest(
             _kClientId,
             _kRedirectUri,
             discoveryUrl: _kDiscoveryUrl,
             scopes: _kScopes,
             promptValues: ['login'],
           ),
         );
         if (result == null) return false;
         await _persist(result);
         await _storage.write(key: 'auth_provider', value: 'keycloak');
         return true;
       } catch (e) {
         return false;
       }
     }

     Future<String?> getValidAccessToken() async {
       final access = await _storage.read(key: 'access_token');
       final expiryStr = await _storage.read(key: 'token_expiry');
       if (access == null || expiryStr == null) return null;

       final expiry = DateTime.parse(expiryStr);
       if (DateTime.now().isBefore(expiry.subtract(const Duration(minutes: 1)))) {
         return access;
       }
       return await _refresh();
     }

     Future<String?> _refresh() async {
       final refresh = await _storage.read(key: 'refresh_token');
       if (refresh == null) return null;
       try {
         final result = await _appAuth.token(TokenRequest(
           _kClientId,
           _kRedirectUri,
           discoveryUrl: _kDiscoveryUrl,
           refreshToken: refresh,
           grantType: 'refresh_token',
           scopes: _kScopes,
         ));
         if (result == null) return null;
         await _persist(result);
         return result.accessToken;
       } catch (e) {
         await logout();
         return null;
       }
     }

     Future<void> _persist(dynamic result) async {
       await _storage.write(key: 'access_token', value: result.accessToken);
       if (result.refreshToken != null) {
         await _storage.write(key: 'refresh_token', value: result.refreshToken);
       }
       if (result.accessTokenExpirationDateTime != null) {
         await _storage.write(
           key: 'token_expiry',
           value: result.accessTokenExpirationDateTime.toIso8601String(),
         );
       }
       if (result.idToken != null) {
         await _storage.write(key: 'id_token', value: result.idToken);
       }
     }

     Future<void> logout() async {
       final idToken = await _storage.read(key: 'id_token');
       try {
         await _appAuth.endSession(EndSessionRequest(
           idTokenHint: idToken,
           postLogoutRedirectUrl: 'com.dhanman.app://callback',
           discoveryUrl: _kDiscoveryUrl,
         ));
       } catch (_) {}

       await _storage.delete(key: 'access_token');
       await _storage.delete(key: 'refresh_token');
       await _storage.delete(key: 'id_token');
       await _storage.delete(key: 'token_expiry');
       await _storage.delete(key: 'auth_provider');
     }
   }
   ```

5. **Two-step login mirror of web.** In your existing login screen, before calling either provider, hit the discovery endpoint:

   ```dart
   final resp = await http.get(Uri.parse(
     '${apiBaseUrl}/api/v1/auth/provider?email=${Uri.encodeQueryComponent(email)}'
   ));
   final provider = jsonDecode(resp.body)['provider'] as String;

   if (provider == 'keycloak') {
     final ok = await KeycloakAuth().login();
     if (ok) Navigator.pushReplacementNamed(context, '/home');
   } else {
     await _existingAuth0Login();
   }
   ```

6. **Centralize token attachment** in your HTTP interceptor (Dio, http_interceptor, whatever you use):

   ```dart
   final provider = await secureStorage.read(key: 'auth_provider');
   final token = provider == 'keycloak'
     ? await KeycloakAuth().getValidAccessToken()
     : await Auth0Service.getValidAccessToken();
   if (token != null) request.headers['Authorization'] = 'Bearer $token';
   ```

7. **SignalR.** Update the `accessTokenFactory` (or Dart equivalent in your SignalR client) to use the same `getValidAccessToken` function. Critical: it must be called on every reconnect, not just initial connect.

8. **Push to test devices.** Build flavor for QA:

   ```bash
   flutter build apk --dart-define=KEYCLOAK_DISCOVERY_URL=https://auth-qa.dhanman.com/realms/dhanman/.well-known/openid-configuration --flavor qa
   flutter build ios --dart-define=KEYCLOAK_DISCOVERY_URL=https://auth-qa.dhanman.com/realms/dhanman/.well-known/openid-configuration --flavor qa
   ```

   Distribute via Firebase App Distribution or TestFlight + Play Internal Testing.

9. **Run the full test matrix on a real Android device AND a real iOS device:**

   | # | Test | Auth0 user | Keycloak user |
   |---|---|---|---|
   | 1 | First login from cold start | ✅ | ✅ |
   | 2 | Token refresh after 1h | ✅ | ✅ |
   | 3 | App backgrounded for 10 min, resumed | ✅ | ✅ |
   | 4 | App killed, reopened | ✅ | ✅ |
   | 5 | SignalR connect on app open | ✅ | ✅ |
   | 6 | SignalR reconnect after network drop | ✅ | ✅ |
   | 7 | Visitor-approval push notification → tap → opens app authenticated | ✅ | ✅ |
   | 8 | Logout → log back in (same user) | ✅ | ✅ |
   | 9 | Force-quit during login flow → reopen | ✅ | ✅ |
   | 10 | Biometric unlock after lock | ✅ | ✅ |
   | 11 | Refresh token expired after 30d (simulate by manipulating storage) → forced re-login | ✅ | ✅ |
   | 12 | Network offline during token refresh → graceful failure | ✅ | ✅ |

   Every cell must pass on BOTH platforms. Document any failures in `docs/auth-migration/mobile-test-results.md`.

**Verification:**
- Test matrix all green on both Android and iOS
- 48-hour internal trial with at least 2 team members using the app daily
- Loki shows successful Keycloak token validation for mobile-originated requests

**Exit criteria:**
- Test matrix complete
- 48-hour trial with no auth-related crashes or stuck-token states
- SignalR delivers a real-time notification (visitor approval) for a Keycloak user

**Rollback:** Ship a build with the Keycloak code path behind a remote feature flag. Auth0 path remains intact.

**Time:** 10 hours of work + 48h internal trial wait.

**Handover prompt:**
> Execute Phase 6 of the Dhanman Auth0 → Keycloak migration plan. Implement Keycloak login in the Flutter app per the plan. Deep-link scheme is `com.dhanman.app://callback`. Build for QA, distribute to test devices, run the 12-row test matrix on both Android and iOS, save results to `docs/auth-migration/mobile-test-results.md`. Do not proceed past this phase until ALL cells are green.

---

## Phase 7 — First apartment cutover (pilot)

**Goal:** One real apartment migrated end-to-end on PROD, observed for 7 days, no rollback needed.

**Prerequisites:** Phases 1–6 complete on QA. PROD Keycloak stood up at `https://auth.dhanman.com` (repeat Phases 1 and 2 against PROD). PROD `dhanman-common` running the dual-issuer build. PROD React + Flutter builds shipped (with Keycloak code path enabled but `auth_provider='auth0'` for everyone in PROD initially, so behavior is unchanged).

**Inputs the agent will need:**
- The pilot apartment's UUID
- Names + WhatsApp numbers of that apartment's committee for pre-comms
- Support contact channel

**Steps:**

1. **Promote infrastructure to PROD.**
   - Repeat Phase 1 with hostname `auth.dhanman.com`, Vault paths `secret/dhanman/prod/keycloak/*`, PROD office IPs for admin allowlist.
   - Repeat Phase 2 — same realm/client/mapper config, PROD redirect URIs, PROD SMTP.
   - Promote dual-issuer `dhanman-common` build via Jenkins.
   - Promote React build with Keycloak config pointing to `https://auth.dhanman.com/realms/dhanman`.
   - Push Flutter build with PROD discovery URL via the app stores (or hotfix flag if remote-config is in place).

2. **Pick the pilot apartment.** Selection criteria (in priority order):
   - Smallest active user count
   - Most engaged committee — they will report issues clearly
   - Closest relationship to the team — ideally a founder's building or a friendly society
   - Tech-comfortable demographic if possible

3. **Pre-cutover comms (T-48h).** Send WhatsApp + in-app notice to that apartment's residents:

   > **Dhanman is upgrading our login system on [date].**
   >
   > You'll receive an email asking you to set a new password — one time only. Your data, units, and history are unchanged. The whole process takes under a minute.
   >
   > If you don't get the email or can't log in afterward, reply here or contact [support number].

4. **Pre-cutover comms (T-2h).** Send a short reminder.

5. **Run the migration tool with apartment filter:**

   ```bash
   cd tools/Dhanman.Auth.Migration

   # Set PROD env vars
   export DHANMAN_AUTH0_CLIENT_ID=$(vault kv get -field=client_id secret/dhanman/prod/migration/auth0-mgmt)
   export DHANMAN_AUTH0_CLIENT_SECRET=$(vault kv get -field=client_secret secret/dhanman/prod/migration/auth0-mgmt)
   export DHANMAN_KEYCLOAK_CLIENT_SECRET=$(vault kv get -field=value secret/dhanman/prod/migration/keycloak-client-secret)
   export DHANMAN_DB_PASSWORD=$(vault kv get -field=value secret/dhanman/prod/postgres/migration_user)

   # Point appsettings to PROD
   export DHANMAN_Keycloak__Authority=https://auth.dhanman.com
   export DHANMAN_Auth0__Domain=<prod-auth0-tenant>.auth0.com

   dotnet run -- --apartment-id <pilot-apartment-uuid>
   ```

6. **Flip `auth_provider`** for that apartment's users only (the migration tool already creates the Keycloak users; this final step is what causes them to be routed to Keycloak on next login):

   ```sql
   BEGIN;
   UPDATE users
   SET auth_provider = 'keycloak', modified_on_utc = NOW()
   WHERE keycloak_id IS NOT NULL
     AND id IN (
       SELECT user_id FROM user_apartments WHERE apartment_id = '<pilot-apartment-uuid>'
     );
   -- Verify count looks right before COMMIT
   COMMIT;
   ```

7. **First 24 hours — close monitoring.**
   - Grafana / Loki: `{job="dhanman-common"} |= "401"` and `{job="keycloak"} |= "ERROR"`
   - Keycloak admin → Sessions → see who has logged in
   - WhatsApp / support inbox for "I can't log in"
   - On-call rotation: someone responds within 15 minutes during business hours

8. **Days 1–7 — passive monitoring + outreach.**
   - Daily check: how many of that apartment's users completed password reset? Run:

     ```sql
     SELECT
       COUNT(*) FILTER (WHERE u.last_login_utc > current_date - interval '1 day') AS logged_in_today,
       COUNT(*) FILTER (WHERE u.last_login_utc IS NULL OR u.last_login_utc < current_date - interval '7 days') AS not_yet_migrated
     FROM users u
     INNER JOIN user_apartments ua ON ua.user_id = u.id
     WHERE ua.apartment_id = '<pilot-apartment-uuid>' AND u.is_deleted = false;
     ```

   - Day 3: re-send password-reset email to anyone who hasn't logged in yet:

     ```bash
     # Get list of pending users from DB, then for each:
     sudo docker exec keycloak /opt/keycloak/bin/kcadm.sh update users/<user-id>/execute-actions-email \
       -r dhanman -s '["UPDATE_PASSWORD","VERIFY_EMAIL"]' \
       --query "client_id=dhanman-web&lifespan=86400"
     ```

   - Day 7: phone call to anyone still not logged in.

**Verification:**
- ≥80% of pilot apartment users completed password reset within 7 days
- Zero support escalations that required code rollback
- No SignalR / mobile / push notification regressions reported
- Keycloak Loki errors stay at zero or near-zero

**Exit criteria:** All four verification items met.

**Rollback (per-apartment, very cheap):**

```sql
UPDATE users
SET auth_provider = 'auth0', modified_on_utc = NOW()
WHERE id IN (
  SELECT user_id FROM user_apartments WHERE apartment_id = '<pilot-apartment-uuid>'
);
```

Users continue using Auth0 on next login. Their Keycloak records remain (no harm). Investigate root cause before retrying.

**Time:** 4 hours of work + 7 days observation.

**Handover prompt:**
> Execute Phase 7 of the Dhanman Auth0 → Keycloak migration plan. The pilot apartment UUID is `<UUID>`. PROD Keycloak is at `https://auth.dhanman.com`. Send the pre-cutover comms (templates in the plan). Run the migration tool with `--apartment-id <UUID>`. Flip `auth_provider` to `keycloak` for that apartment. Monitor for 7 days using the queries in the plan. Stop and report at end of day 7 with the metrics.

---

## Phase 8 — Remaining 2 apartments

**Goal:** All current PROD users on Keycloak.

**Prerequisites:** Phase 7 exit criteria met, including the 7-day observation.

**Inputs the agent will need:**
- UUIDs of remaining 2 apartments
- The same comms templates from Phase 7

**Steps:**

1. **Repeat Phase 7's pattern** for the next apartment, then the third — one at a time, never in parallel. You want a clean signal on what caused any issue.

2. **Tighten the comms based on Phase 7 learning.** For example, if pilot showed 30% of users took >3 days to reset, schedule the day-3 reminder automatically. Update `docs/auth-migration/comms-templates.md`.

3. **After all three apartments:** verify completeness:

   ```sql
   SELECT
     a.name,
     COUNT(u.id) AS total_users,
     COUNT(*) FILTER (WHERE u.auth_provider = 'keycloak') AS on_keycloak,
     COUNT(*) FILTER (WHERE u.auth_provider = 'auth0') AS on_auth0,
     COUNT(*) FILTER (WHERE u.auth_provider IS NULL) AS unassigned
   FROM apartments a
   INNER JOIN user_apartments ua ON ua.apartment_id = a.id
   INNER JOIN users u ON u.id = ua.user_id
   WHERE u.is_deleted = false
   GROUP BY a.id, a.name;
   ```

   Expected: every apartment row has `on_auth0 = 0` and `unassigned = 0`.

4. **Inactive users.** If you find users who never logged in despite multiple reminders:
   - For users inactive >180 days: set `is_deleted = true`. Document the count.
   - For users inactive <180 days: keep `auth_provider = 'auth0'` for now and revisit in Phase 10. The dual-issuer code in common still validates Auth0 tokens for them.

**Verification:**
- Query above shows 100% of active users on Keycloak
- Auth0 dashboard shows ≤1% of historical login traffic (only stragglers)
- No support escalations from the second or third apartment

**Exit criteria:** Above met for ≥7 days post-third-apartment cutover.

**Rollback:** Per-apartment, same SQL as Phase 7.

**Time:** 4 hours per apartment + 7 days observation between cutovers.

**Handover prompt:**
> Execute Phase 8 of the Dhanman Auth0 → Keycloak migration plan. Migrate apartment `<UUID-2>` first using Phase 7's procedure. Wait 7 days. Then migrate `<UUID-3>`. Wait 7 more days. Run the validation query at the end. Report final per-apartment metrics.

---

## Phase 9 — Migrate remaining 6 microservices

**Goal:** `community`, `sales`, `purchase`, `inventory`, `payroll`, `document` all validate Keycloak tokens (and remove Auth0 validation once safe).

**Prerequisites:** Phase 8 complete. All active users on Keycloak.

**IMPORTANT NOTE — read this before starting:** During Phases 7–8, the other 6 services were still validating Auth0 tokens — but residents were getting Keycloak tokens after migration. This works ONLY if those services either (a) weren't called from those users' workflows during the cutover, or (b) were dual-issuer-enabled before Phase 7.

If Phase 0's cross-service inventory showed any of the 6 services are hit during normal user workflows (very likely for at least `community`, `sales`, `document`), apply the dual-issuer config from Phase 3 to those services BEFORE running Phase 7. In other words: hoist Phase 9 forward as soon as Phase 3 lands. The plan keeps Phase 9 separate for clarity, but in practice the dual-issuer config should be applied to all 7 services before any apartment cutover.

**Inputs the agent will need:**
- For each service: repo path, current `Program.cs` JWT bearer config, current appsettings structure
- Vault paths for Keycloak config per service

**Steps for each of the 6 services:**

1. **Apply the dual-issuer config from Phase 3.** Same `Program.cs` pattern, same `appsettings.json` structure under `Auth:Auth0` and `Auth:Keycloak`.

2. **Update `ICurrentUserService` (or equivalent) per service.** If services share a common library, update the lib once. If each service has its own implementation, copy the Phase 3 implementation into each.

3. **For services that have their own user-join tables**, ensure they look up by internal Dhanman `users.id` (the Guid), not by Auth0 sub or Keycloak UUID. `dhanman-common.users.id` is the universal identifier post-migration.

4. **Smoke test in QA** with a Keycloak-issued token: hit one read endpoint and one write endpoint per service.

5. **Deploy to PROD via Jenkins.** No user-facing change — purely additive.

6. **Wait 48 hours.** Monitor 401/403 rates per service in Grafana. If clean, move to next service.

7. **After all 6 are dual-issuer in PROD**, switch each to **Keycloak-only** by deleting the Auth0 scheme registration and the policy switch. Deploy each, wait 48h, proceed.

**Migration order (post-Phase 8):**

| Step | Service | Why this order |
|---|---|---|
| 1 | `community` | Highest user-facing traffic — best canary for Keycloak-only |
| 2 | `document` | Lower business risk, simpler endpoints |
| 3 | `sales` | Approval workflows depend on it — exercise carefully |
| 4 | `purchase` | Same domain as sales |
| 5 | `inventory` | Cross-service warehouse sync — coordinate with sales/purchase |
| 6 | `payroll` | Lowest user count — last because regression here is least visible |

**Verification per service:**

```bash
# After Keycloak-only deploy, an Auth0 token should now fail
curl -i -H "Authorization: Bearer <stale-auth0-token>" \
  https://api.dhanman.com/<service>/api/v1/health-authorized
# Expected: 401

# A Keycloak token should succeed
curl -i -H "Authorization: Bearer <fresh-keycloak-token>" \
  https://api.dhanman.com/<service>/api/v1/health-authorized
# Expected: 200
```

**Exit criteria:**
- All 6 services running Keycloak-only in PROD
- 48h of zero Auth0 traffic across all services per Grafana

**Rollback per service:** Redeploy the dual-issuer build for that service. Keep apartment-level cutover unchanged.

**Time:** 10 hours total (mostly waiting between deploys).

**Handover prompt:**
> Execute Phase 9 of the Dhanman Auth0 → Keycloak migration plan. Apply Phase 3's dual-issuer config to each of the 6 services in the order specified. Deploy to PROD via Jenkins. Wait 48h between services. Once all 6 are dual-issuer and stable, switch each to Keycloak-only in the same order. Verify with the curl tests. Stop and report after each service.

---

## Phase 10 — Decommission Auth0

**Goal:** No code references to Auth0 anywhere. Auth0 subscription cancelled.

**Prerequisites:** Phase 9 complete. ≥7 consecutive days of zero Auth0 traffic across all services.

**Steps:**

1. **Remove dual-issuer code from all 7 services.** Delete the `AddJwtBearer("Auth0", ...)` registration, delete the `MultiAuth` policy scheme, fall back to single-scheme `AddJwtBearer()` for Keycloak only:

   ```csharp
   builder.Services
       .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
       .AddJwtBearer(options =>
       {
           options.Authority = builder.Configuration["Auth:Keycloak:Authority"];
           options.Audience = builder.Configuration["Auth:Keycloak:Audience"];
           // ... rest of Phase 3 Keycloak config ...
       });
   ```

   Delete the corresponding Auth0 keys from all `appsettings*.json` files.

2. **Remove Auth0 SDK from React.**

   ```bash
   npm uninstall @auth0/auth0-react
   ```

   Delete the Auth0 callback route, the `Auth0Provider` wrap in `AuthRouter.tsx`, and the email-gate fallback to Auth0. Login now goes straight to Keycloak. Delete `VITE_AUTH0_*` env vars.

3. **Remove Auth0 SDK from Flutter.** Remove from `pubspec.yaml`. Delete `lib/auth/auth0_*.dart`. Delete the email-gate two-step provider router (everyone is Keycloak now — login goes straight to Keycloak). Delete the `auth_provider` storage logic.

4. **Optional — drop transitional columns.** Keep them for 90 days post-decommission for safety. After 90 days:

   ```sql
   ALTER TABLE users DROP COLUMN external_id;
   ALTER TABLE users DROP COLUMN auth_provider;
   -- Keep keycloak_id; it's the new external identifier
   ```

5. **Cancel Auth0 subscription.**
   - Auth0 dashboard → Settings → Tenant Settings → export tenant config to JSON, save to `docs/auth-migration/auth0-tenant-archive-<date>.json` (audit/legal)
   - Cancel paid plan if any
   - Keep the tenant accessible for 30 days in case of post-cutover surprise

6. **Update internal docs:**
   - `README.md` of every service — auth section
   - Engineering onboarding doc
   - Architecture diagram
   - Runbooks
   - `CLAUDE.md` if it references Auth0

   Run a final grep to confirm cleanup:

   ```bash
   for repo in dhanman-common dhanman-community dhanman-sales dhanman-purchase \
              dhanman-inventory dhanman-payroll dhanman-document dhanman-web dhanman-mobile; do
     echo "=== $repo ==="
     cd /path/to/$repo
     grep -rn -i "auth0" . --exclude-dir=node_modules --exclude-dir=bin --exclude-dir=obj
   done
   ```

   Expected: only matches in archived migration docs.

**Verification:**
- Grep returns no Auth0 references in source code
- Auth0 invoice closed
- All services validate only Keycloak tokens
- All apps redirect only to Keycloak

**Exit criteria:** All four met.

**Rollback:** None at this point. Keycloak is your auth system. If Keycloak has a critical issue, fix Keycloak.

**Time:** 4 hours.

**Handover prompt:**
> Execute Phase 10 of the Dhanman Auth0 → Keycloak migration plan. Remove all Auth0 code references from the 7 services, React app, and Flutter app. Run the grep verification. Archive Auth0 tenant config. Cancel the Auth0 subscription only after grep is clean and ≥7 days of zero Auth0 traffic. Stop and report after grep verification passes.

---

## Phase 11 — Post-migration hardening

**Goal:** Keycloak is production-grade — backed up, monitored, MFA-enforced where it matters, realm config in version control, passkeys offered.

**Prerequisites:** Phase 10 complete.

**Steps:**

1. **Brute-force protection — already enabled in Phase 2.** Verify the realm settings are still in place:

   ```bash
   sudo docker exec keycloak /opt/keycloak/bin/kcadm.sh get realms/dhanman \
     --fields bruteForceProtected,failureFactor,maxFailureWaitSeconds,permanentLockout
   ```

   Expected: `bruteForceProtected=true`, `failureFactor=5`.

2. **Compromised password protection.** Add a HIBP-style check via Keycloak password policy. The built-in password policy has a "Not Recently Used" / "Password History" element, but Keycloak does NOT bundle a HIBP API check natively in the realm policy DSL. Two options:

   **Option A (simple, no extension):** rely on a strong policy + password history + brute force. This is what Phase 2 already configures. For most B2C contexts this is sufficient.

   **Option B (stronger, requires SPI extension):** install a community SPI extension like `keycloak-pwned-passwords`:

   ```bash
   # Download a maintained release
   wget https://github.com/<maintainer>/keycloak-pwned-passwords/releases/download/<version>/keycloak-pwned-passwords-<version>.jar
   sudo cp keycloak-pwned-passwords-*.jar /opt/keycloak/data/providers/
   sudo systemctl restart keycloak
   # Then: Realm settings → Authentication → Password Policy → add "HIBP" policy
   ```

   Verify the extension is supported on your Keycloak version before installing. Recommendation for Dhanman: start with Option A; revisit Option B if a security review demands it.

3. **MFA — enforce TOTP for elevated roles.** Free in Keycloak. Two-step setup:

   **a) Enable Conditional OTP authenticator** (already in default browser flow as "Conditional OTP"). Configure it to require OTP based on a user attribute or role:

   - Authentication → Flows → Browser → "Conditional OTP" → set the condition based on user attribute `force_mfa=true`

   **b) Set the attribute on committee/admin users.** During user creation/migration (or via a one-time backfill):

   ```bash
   # For each user with role committee_member / facility_manager / admin:
   sudo docker exec keycloak /opt/keycloak/bin/kcadm.sh update users/<user-id> -r dhanman \
     -s 'attributes.force_mfa=["true"]'
   ```

   Or simpler: assign these users a Keycloak role `requires-mfa` and condition the OTP flow on the role.

   On next login, qualifying users will be prompted to enroll TOTP.

4. **Passkeys (WebAuthn) — free in Keycloak, optional for residents.**
   - Realm settings → WebAuthn → enable
   - Authentication → Required Actions → enable `Webauthn Register`
   - Users get an option in their account console to add a passkey

5. **Backups.**

   **Keycloak DB:** add the `keycloak` database to your existing pg_basebackup or pg_dump rotation:

   ```bash
   # Daily logical dump (cron)
   pg_dump -Fc -h <host> -U postgres keycloak > /backup/keycloak-$(date +%F).dump
   # Retain 30 daily, 12 monthly
   ```

   **Test restore on a separate VM at least once.** A backup that hasn't been restored is not a backup.

   **Realm export to git (config-as-code).** Daily cron job:

   ```bash
   sudo docker exec keycloak /opt/keycloak/bin/kc.sh export \
     --dir /opt/keycloak/data/export \
     --realm dhanman \
     --users skip
   # Then commit /opt/keycloak/data/export/dhanman-realm.json to a private git repo
   ```

   This way, realm config (clients, mappers, flows, policies) is versioned and you can re-create the realm from JSON if needed. Users live in DB only.

6. **Loki dashboards in Grafana.** Add to your existing auth dashboard:

   ```promql
   # Login success rate
   sum by (env) (rate({job="keycloak"} |= "LOGIN_ERROR" [5m]))

   # Token issuance rate
   sum by (client_id) (rate({job="keycloak"} |= "CODE_TO_TOKEN" [5m]))

   # 401 rate per microservice
   sum by (job) (rate({job=~"dhanman-.*"} |= "JWT validation failed" [5m]))
   ```

7. **Alerts.** Configure in Grafana / Alertmanager:
   - Keycloak container down for >2 minutes
   - Login failure rate >20% over 5 minutes (possible attack or outage)
   - 401 spike on any microservice >50/min (possible JWKS rotation issue)
   - Postgres `keycloak` DB connection failures

8. **JWKS caching across services.** Each .NET service caches the JWKS by default for 24h via `IConfigurationManager`. Document the rotation procedure in the runbook (step 9 below). For now, restart each service after key rotation; later, consider a coordinated cache flush or signed JWT key-id rotation.

9. **Production runbook — `docs/runbooks/keycloak.md`:**

   ```markdown
   # Keycloak Runbook

   ## Restart
   sudo systemctl restart keycloak

   ## Check health
   curl https://auth.dhanman.com/health/ready

   ## Restore from backup
   sudo systemctl stop keycloak
   pg_restore -h <host> -U postgres -d keycloak --clean /backup/keycloak-<date>.dump
   sudo systemctl start keycloak

   ## Rotate signing key
   1. Admin console → Realm settings → Keys → Providers → Add "rsa-generated"
   2. Set priority higher than existing key
   3. Set existing key priority to 0 (still active for verification, not for signing)
   4. Restart all 7 microservices to invalidate JWKS cache
   5. After 7 days, delete old key

   ## Add a new redirect URI for an existing client
   /opt/keycloak/bin/kcadm.sh update clients/<client-id>/redirect-uris -r dhanman \
     -s '["existing1","existing2","new-uri"]'

   ## Invalidate all sessions for a user (e.g. stolen device)
   /opt/keycloak/bin/kcadm.sh post users/<user-id>/logout -r dhanman

   ## Delete a user permanently (GDPR request)
   /opt/keycloak/bin/kcadm.sh delete users/<user-id> -r dhanman
   psql -c "UPDATE users SET is_deleted = true, deleted_on_utc = NOW() WHERE keycloak_id = '<user-id>';"
   ```

10. **Walkthrough with one teammate.** Pick someone on the team and have them execute the runbook steps in QA. If they get stuck, the runbook is wrong — fix it.

**Verification:**
- `pg_restore` of a recent backup succeeds on QA test VM
- Realm export JSON committed to git, last update <24h
- A test committee user is forced through TOTP enrollment on next login
- Grafana dashboards show live data
- Runbook walked through end-to-end by another team member

**Exit criteria:** All five met.

**Rollback:** N/A — these are additive hardening steps.

**Time:** 10 hours.

**Handover prompt:**
> Execute Phase 11 of the Dhanman Auth0 → Keycloak migration plan. Implement all hardening steps in order: brute-force verification, MFA enforcement for committee/admin roles, passkeys enabled, daily DB backup + realm export, Loki dashboards + alerts, runbook in `docs/runbooks/keycloak.md`, walkthrough by another teammate. Verify each before moving on. Stop and report.

---

## Appendix A — JWT claim contract (post-cutover)

This is the contract every Dhanman microservice can rely on after Phase 10:

| Claim | Type | Source | Notes |
|---|---|---|---|
| `iss` | string | Keycloak | `https://auth.dhanman.com/realms/dhanman` |
| `aud` | string | Keycloak audience mapper | `dhanman-api` |
| `sub` | string | Keycloak | Keycloak user UUID |
| `azp` | string | Keycloak | Authorized party — one of `dhanman-web`, `dhanman-mobile`, `dhanman-internal-admin` |
| `exp` | number | Keycloak | Expiry epoch |
| `iat` | number | Keycloak | Issued-at epoch |
| `email` | string | Keycloak | User email |
| `email_verified` | bool | Keycloak | |
| `user_id` | string | Mapper (User Property → id) | Same as `sub`, but explicitly named |
| `apartment_ids` | array<string> | Mapper (User Attribute) | Apartments this user belongs to (UUIDs as strings) |
| `organization_id` | string | Mapper (User Attribute) | Owning organization UUID |
| `role` | string | Mapper (User Attribute) | Role label (resident, committee_member, facility_manager, admin, etc.) |

**Authoritative permissions** still come from `dhanman-common` per request — JWT claims are coarse routing/identity hints. Do not encode the full permission list in the JWT (token bloat, revocation latency).

The Dhanman internal user id (`dhanman-common.users.id`) is resolved server-side by joining `keycloak_id = sub` (or `user_id`). All inter-service operations should use this internal Guid, never the Keycloak UUID directly.

---

## Appendix B — Vault paths reference

```
# QA
secret/dhanman/qa/keycloak/db_password
secret/dhanman/qa/keycloak/bootstrap_password
secret/dhanman/qa/keycloak/admin
secret/dhanman/qa/postgres/migration_user
secret/dhanman/qa/smtp

# PROD
secret/dhanman/prod/keycloak/db_password
secret/dhanman/prod/keycloak/admin
secret/dhanman/prod/postgres/migration_user
secret/dhanman/prod/smtp

# Migration tool (per-environment)
secret/dhanman/migration/auth0-mgmt              (client_id, client_secret)
secret/dhanman/migration/keycloak-client-secret  (value)
secret/dhanman/prod/migration/auth0-mgmt
secret/dhanman/prod/migration/keycloak-client-secret
```

---

## Appendix C — Why Keycloak (and what we accepted)

**Why Keycloak over FusionAuth Community:**
- Apache 2.0 — every feature free, forever
- M2M / Client Credentials grant in the box (FusionAuth Community: paid)
- Advanced MFA enforcement, conditional flows in the box (FusionAuth Community: paid)
- Passkeys / WebAuthn in the box (FusionAuth Community: paid)
- Login page theming and branding in the box (FusionAuth Community: paid)
- Realm-based multi-tenancy if Dhanman ever needs strict tenant isolation later

**What we accepted:**
- Higher operational complexity than FusionAuth — JVM tuning, Quarkus internals, theming via Freemarker
- Realm import/export across major versions sometimes needs manual editing
- Admin UI is functional but not as polished as FusionAuth's
- Postgres schema is large and Keycloak-managed (don't write to it directly)

**Why dual-issuer over big-bang cutover:**
- Migrate apartment-by-apartment (pilot, then phased)
- Zero downtime
- Per-user rollback is one SQL statement

**Why force password reset rather than migrate hashes:**
- Auth0 does not export password hashes
- Forced reset is one-time, recoverable via email; bad password compatibility is not

**Why permissions stay in `dhanman-common`:**
- Tokens cached for ≤1h on mobile; permission revocation must be instant
- Permission lists can be large; token bloat hurts mobile and SignalR negotiate
- Existing `[RequiresPermissions(...)]` infrastructure already does the lookup correctly

---

## Appendix D — What this plan does NOT cover

- **Visitor public QR token flow** — its own signed-token system, untouched. Confirm in Phase 0 that nothing in the visitor flow references Auth0 directly.
- **Admin / staff console SSO with Google or Microsoft** — possible in Keycloak as Identity Providers; add after Phase 11 if needed.
- **Mobile app store re-review** — Phase 6's Flutter changes may trigger a fresh App Store / Play Store review. Allow buffer time.
- **GDPR / data subject request flows** — Keycloak has APIs for user delete and data export; document for compliance separately.
- **B2B SSO with vendors / auditors** — Keycloak supports SAML and OIDC IdP federation; out of scope for this plan.
- **High-availability Keycloak cluster** — single-instance is fine for current scale (3 apartments → ~50 apartments). When you cross ~10k MAU, plan a clustered Keycloak deployment with shared infinispan cache. Out of scope here.
- **Custom login theme matching Dhanman branding** — Keycloak theming is non-trivial. Plan for 1–2 days of dedicated frontend work to ship a polished custom theme. Add as a follow-up after Phase 11.

---

## Appendix E — Reference: Keycloak realm user-profile JSON

For Phase 2 step 4. Save as `users-profile.json` and apply with:
`/opt/keycloak/bin/kcadm.sh update users/profile -r dhanman -f users-profile.json`

```json
{
  "attributes": [
    {
      "name": "username",
      "displayName": "${username}",
      "validations": {
        "length": { "min": 3, "max": 255 },
        "username-prohibited-characters": {}
      },
      "permissions": { "view": ["admin", "user"], "edit": ["admin", "user"] }
    },
    {
      "name": "email",
      "displayName": "${email}",
      "validations": { "email": {}, "length": { "max": 255 } },
      "required": { "roles": ["user"] },
      "permissions": { "view": ["admin", "user"], "edit": ["admin", "user"] }
    },
    {
      "name": "firstName",
      "displayName": "${firstName}",
      "validations": { "length": { "max": 255 } },
      "permissions": { "view": ["admin", "user"], "edit": ["admin", "user"] }
    },
    {
      "name": "lastName",
      "displayName": "${lastName}",
      "validations": { "length": { "max": 255 } },
      "permissions": { "view": ["admin", "user"], "edit": ["admin", "user"] }
    },
    {
      "name": "apartment_ids",
      "displayName": "Apartment IDs",
      "multivalued": true,
      "permissions": { "view": ["admin", "user"], "edit": ["admin"] }
    },
    {
      "name": "organization_id",
      "displayName": "Organization ID",
      "permissions": { "view": ["admin", "user"], "edit": ["admin"] }
    },
    {
      "name": "role",
      "displayName": "Dhanman Role",
      "permissions": { "view": ["admin", "user"], "edit": ["admin"] }
    },
    {
      "name": "force_mfa",
      "displayName": "Force MFA",
      "permissions": { "view": ["admin"], "edit": ["admin"] }
    }
  ],
  "groups": [
    { "name": "user-metadata", "displayHeader": "User metadata", "displayDescription": "Internal Dhanman attributes" }
  ]
}
```

---

## Appendix F — Common Keycloak gotchas

1. **`KC_HOSTNAME_STRICT=true` behind a reverse proxy.** If Keycloak issues redirect URLs containing `localhost:8080` instead of `https://auth.dhanman.com`, your `KC_HOSTNAME` and `KC_PROXY_HEADERS` are wrong. Verify with `curl -I https://auth.dhanman.com/realms/dhanman/protocol/openid-connect/auth?...` — the `Location:` header must be on `auth.dhanman.com`.

2. **Audience claim is missing.** By default Keycloak does NOT put your client_id into the `aud` claim. The `dhanman-api-audience` protocol mapper in Phase 2 step 5 fixes this. If you skip it, .NET's `ValidateAudience = true` will reject every token. Symptom: 401 with `IDX10214: Audience validation failed`.

3. **`offline_access` scope vs refresh tokens.** Refresh tokens work without `offline_access` for short-lived sessions, but `offline_access` makes them survive realm-level "Logged In Sessions" cleanup. For mobile (Flutter) include `offline_access`; for web (React) it's optional but recommended.

4. **Keycloak 26+ deprecates legacy hostname options.** Don't use `KC_HOSTNAME_URL`, `KC_HOSTNAME_ADMIN_URL`, etc. — they're removed in v26. Use `KC_HOSTNAME` (full URL) + `KC_HOSTNAME_STRICT` only.

5. **Bootstrap admin is one-shot.** The `KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD` env vars only work on first startup with an empty DB. Once the master realm has any user, those env vars are ignored. If you lose the bootstrap admin and have no other admin: `kc.sh bootstrap-admin user --username temp --password temp` from inside the container.

6. **`/admin/` path is sensitive.** Never expose it publicly without IP allowlisting or VPN. The NGINX config in Phase 1 has the allowlist commented — uncomment and populate it before any PROD work.

7. **Keycloak rotates its own DB schema across major versions.** Migrations run automatically on container startup. Do NOT downgrade Keycloak after an upgrade — the schema is forward-only without manual SQL.

8. **Service account roles via `realm-management` client.** Phase 2 step 8 grants `manage-users` etc. via the `realm-management` client. Don't grant via the `dhanman` realm's own roles — that's a different role mapping and won't give the migration tool admin REST access.

9. **`execute-actions-email` requires SMTP.** If SMTP is misconfigured, the API call returns 200 but no email is sent. Check the Keycloak logs for `Failed to send email` and verify SMTP via `kcadm.sh test-smtp` before running the migration.

10. **JWKS rotation breaks all services until cache expires.** Default JWKS cache in .NET is 24h. Plan key rotations for low-traffic windows and have a "restart all services" runbook ready.

---

## Appendix G — Estimated total cost & timeline

| Item | Cost |
|---|---|
| Keycloak software | $0 (Apache 2.0) |
| OVH compute (existing servers) | $0 incremental |
| Engineer time | ~80 hours total across 5 weeks |
| Auth0 monthly bill after migration | $0 (cancelled) |
| Auth0 monthly bill before migration | (current) |
| **Net monthly savings post-migration** | (current Auth0 bill — should pay back the migration cost in 1–6 months depending on Auth0 spend) |

---

## Document changelog

- **v1** — Initial draft, all 12 phases (0–11), 7 appendices. Auth server: Keycloak 26.x. Infrastructure: existing OVH QA + PROD via Docker Compose, NGINX, Postgres, Vault.
