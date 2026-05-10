# QA Challenges Log

Use this file to record every meaningful issue discovered while standing up and validating Keycloak in QA.

PROD work should not begin until this file has been reviewed and the migration plan has been corrected where needed.

## Status

- QA install started: completed on 2026-05-10
- Simple app validation completed: pending
- First Dhanman repo validation completed: pending
- Ready for PROD promotion: pending

## Entry Template

### YYYY-MM-DD - Short issue title

- Phase:
- Environment:
- Symptom:
- Root cause:
- Fix applied:
- Files or services changed:
- Plan updated:
- PROD preventive action:
- Notes:

## Entries

### 2026-05-10 - Keycloak first boot failed with optimized startup

- Phase: Phase 1
- Environment: QA
- Symptom: the container kept restarting and `qa.auth.dhanman.com` returned `502 Bad Gateway`
- Root cause: the container was started with `kc.sh start --optimized` on the very first boot, which Keycloak rejects before the initial build/startup cycle has completed
- Fix applied: removed `--optimized` for the first QA startup, restarted the service, and allowed Keycloak to complete its initial schema build and bootstrap flow
- Files or services changed: `/opt/keycloak/docker-compose.yml`, `keycloak` systemd service, QA NGINX upstream verification
- Plan updated: yes
- PROD preventive action: first PROD boot must use plain `start`; only switch to `start --optimized` after the initial successful startup/build cycle
- Notes: once startup completed, OIDC discovery became available at `https://qa.auth.dhanman.com/realms/master/.well-known/openid-configuration`

### 2026-05-10 - QA secret injection path did not match the real Vault layout

- Phase: Phase 1
- Environment: QA
- Symptom: Keycloak reported that the bootstrap admin password was not set even though secret files had been rendered
- Root cause: the secret-render script was reading Vault paths and fields that did not match the actual QA Keycloak secret structure
- Fix applied: temporarily switched QA compose wiring to direct environment values so the service could be brought up and validated end to end
- Files or services changed: `/opt/keycloak/render-secrets.sh`, `/opt/keycloak/docker-compose.yml`
- Plan updated: yes
- PROD preventive action: validate the Vault secret structure and render output before first PROD start; do not assume `_FILE`-based secret wiring is correct without an explicit check
- Notes: after this change, Keycloak created the bootstrap admin and completed startup normally
