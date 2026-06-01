# Keycloak Brute Force Protection — Runbook

## Background

The `dhanman` realm on QA (and prod) has Keycloak brute force protection configured.
When enabled, users are locked out after **5 failed login attempts** for **15 minutes**.

This was the cause of user lockouts reported in June 2026. Brute force protection was
temporarily disabled on QA to unblock users.

---

## Current Settings (dhanman realm)

| Setting | Value |
|---|---|
| `bruteForceProtected` | configurable (disabled Jun 2026) |
| `failureFactor` | 5 (lock after 5 failed attempts) |
| `maxFailureWaitSeconds` | 900 (15-minute lockout) |
| `bruteForceStrategy` | MULTIPLE |

---

## Prerequisites

SSH into the target server and get an admin token:

```bash
# QA
ssh ubuntu@54.37.159.71

# Prod
ssh ubuntu@51.79.156.217
```

```bash
TOKEN=$(curl -s -X POST 'http://localhost:8080/realms/master/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=admin-cli' \
  -d 'grant_type=password' \
  -d 'username=bootstrap' \
  -d 'password=<bootstrap-password-from-vault>' | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
```

> Bootstrap password for QA is in the Keycloak container env (`KC_BOOTSTRAP_ADMIN_PASSWORD`).
> Check with: `docker inspect keycloak --format '{{range .Config.Env}}{{println .}}{{end}}' | grep BOOTSTRAP`

---

## Check Current Status

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  'http://localhost:8080/admin/realms/dhanman' | \
  python3 -c 'import sys,json; d=json.load(sys.stdin); print("bruteForceProtected:", d["bruteForceProtected"], "| failureFactor:", d["failureFactor"])'
```

---

## Disable Brute Force Protection (temporary)

Use when users are getting locked out and the issue needs to be unblocked quickly.

```bash
curl -s -o /dev/null -w '%{http_code}' -X PUT 'http://localhost:8080/admin/realms/dhanman' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"bruteForceProtected": false}'
# Expected: 204
```

---

## Re-enable Brute Force Protection

Run this once the issue is resolved. Recommended settings below are more forgiving
than the original (10 attempts, 5-min wait instead of 5 attempts, 15-min wait).

```bash
curl -s -o /dev/null -w '%{http_code}' -X PUT 'http://localhost:8080/admin/realms/dhanman' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "bruteForceProtected": true,
    "failureFactor": 10,
    "maxFailureWaitSeconds": 300,
    "waitIncrementSeconds": 60,
    "minimumQuickLoginWaitSeconds": 60,
    "maxDeltaTimeSeconds": 43200,
    "permanentLockout": false
  }'
# Expected: 204
```

---

## Unlock a Specific Locked User

If brute force is enabled and a single user is locked, unlock just them without
touching the realm settings.

```bash
# Find the user ID
curl -s -H "Authorization: Bearer $TOKEN" \
  'http://localhost:8080/admin/realms/dhanman/users?search=<email>' | \
  python3 -c 'import sys,json; u=json.load(sys.stdin); print(u[0]["id"], u[0]["username"])'

# Check their brute force status
curl -s -H "Authorization: Bearer $TOKEN" \
  'http://localhost:8080/admin/realms/dhanman/attack-detection/brute-force/users/<userId>'

# Unlock them
curl -s -o /dev/null -w '%{http_code}' -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  'http://localhost:8080/admin/realms/dhanman/attack-detection/brute-force/users/<userId>'
# Expected: 204
```

---

## Clear All Locked Users (without disabling protection)

```bash
curl -s -o /dev/null -w '%{http_code}' -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  'http://localhost:8080/admin/realms/dhanman/attack-detection/brute-force/users'
# Expected: 204
```
