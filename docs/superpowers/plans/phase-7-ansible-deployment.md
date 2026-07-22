# Phase 7: Ansible Deployment of Infra-Verify Engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Deploy the read-only infra-verify check engine to QA and PROD hosts via Ansible, with cron-based daily execution and email reporting.

**Architecture:** A new lightweight Ansible role (`infra_verify`) copies the engine files from the repo to each host, creates an unprivileged `infraverify` user with minimal group membership (`systemd-journal` for SVC-06 journal reads), renders SMTP credentials from Vault into msmtp config, and installs a single daily cron entry. The role is gated behind an Ansible tag so it can be independently enabled/disabled. No modifications to existing roles (monitoring, dhanman_service, etc.).

**Tech Stack:** Ansible (existing playbooks), Vault (for SMTP credentials), cron (system scheduler), msmtp (SMTP client), bash (engine runtime).

## Global Constraints

- **Must not modify:** `ansible/roles/monitoring/`, `ansible/roles/dhanman_service/`, `ansible/inventory/`, service deployment paths, or any existing role's tasks
- **Must preserve:** existing cron entries (backup, deployments), Jenkins pipeline structure
- **QA-first deployment:** role tested on QA, manual verification for 3 days before PROD enable
- **PROD checks read-only:** PROD runs all checks but initial email recipient is infra lead only (full COO list after 5 QA days)
- **Vault integration:** SMTP username/password read from `secret/shared/global` (confirmed in CLAUDE.md); no secrets on CLI or in logs
- **Idempotence:** cron task must be safe to re-run; file ownership/perms stable; no state outside of reports/audit
- **Exit codes:** engine returns 0 (healthy), 1 (warning), 2 (critical), 3 (engine failure); cron job captures and logs these
- **Rollback:** removing the role tag from `02-install-infra.yml` disables the feature; existing reports remain in history

---

## File Structure

| Path | Purpose | Create/Modify |
|---|---|---|
| `ansible/roles/infra_verify/` | New role directory | Create |
| `ansible/roles/infra_verify/tasks/main.yml` | Role tasks: user, files, ACL, cron, msmtp | Create |
| `ansible/roles/infra_verify/templates/msmtprc.j2` | msmtp config (Vault credentials, TLS, from-address) | Create |
| `ansible/roles/infra_verify/templates/cron-run.sh.j2` | Cron job wrapper (logging, lock monitoring, cleanup) | Create |
| `ansible/roles/infra_verify/defaults/main.yml` | Default vars (schedule time 06:15, env-name mapping, report recipients) | Create |
| `ansible/roles/infra_verify/handlers/main.yml` | Handlers (none for this phase; reserved) | Create (empty) |
| `ansible/playbooks/02-install-infra.yml` | Add role inclusion behind `infra_verify` tag | Modify |
| `Jenkinsfile` | Add shellcheck to Validate stage for all `.sh` files | Modify |
| `ansible/roles/infra_verify/tests/test-role.md` | Acceptance test checklist (manual verification steps) | Create |

---

## Tasks

### Task 1: Create Ansible Role Directory Structure & Defaults

**Files:**
- Create: `ansible/roles/infra_verify/tasks/main.yml` (empty, will fill in Task 2)
- Create: `ansible/roles/infra_verify/defaults/main.yml`
- Create: `ansible/roles/infra_verify/handlers/main.yml` (empty)
- Create: `ansible/roles/infra_verify/templates/` (directory)
- Create: `ansible/roles/infra_verify/tests/test-role.md`

**Interfaces:**
- Consumes: nothing
- Produces: role scaffold with sane defaults

- [ ] **Step 1: Create role directory structure**

```bash
mkdir -p ansible/roles/infra_verify/{tasks,templates,tests}
touch ansible/roles/infra_verify/{tasks/main.yml,handlers/main.yml}
```

- [ ] **Step 2: Write defaults/main.yml**

```yaml
---
# ansible/roles/infra_verify/defaults/main.yml
# Defaults for the infra-verify check engine deployment role.
# All variables are overridable at the inventory/group_vars level.

# User and group for the engine
infraverify_user: infraverify
infraverify_group: infraverify
infraverify_home: /opt/infra-verify
infraverify_shell: /usr/sbin/nologin

# Source and destination paths
infra_verify_repo_source: "{{ playbook_dir }}/../operations/infra-verify"
infra_verify_dest: /opt/infra-verify

# SMTP configuration (Vault-sourced in tasks; defaults here for reference)
smtp_host: smtp-relay.brevo.com
smtp_port: 587
smtp_from: infra-report@dhanman.com
smtp_use_tls: yes

# Daily schedule (cron, 24-hour format, timezone IST)
# Override in group_vars per environment
infra_verify_schedule_hour: "06"
infra_verify_schedule_minute: "15"

# Report recipients (override in group_vars per environment)
# QA: infra lead + devops team
# PROD: CTO + COO + infra lead (after 5 QA days)
infra_verify_recipients: "{{ alert_emails | default(['devops@example.com']) }}"

# Cron job name (used in /etc/cron.d/ naming)
infra_verify_cron_name: "infra-verify-daily"

# Lock file for preventing overlapping runs
infra_verify_lock_file: /var/lock/infra-verify.lock

# History directory (on host, gitignored)
infra_verify_history_dir: "{{ infra_verify_dest }}/history"

# Audit log directory
infra_verify_audit_dir: /var/log/dhanman/infra-audit

# Log level for cron wrapper (DEBUG, INFO, WARNING, ERROR)
infra_verify_log_level: INFO
```

- [ ] **Step 3: Write handlers/main.yml (empty, reserved for future use)**

```yaml
---
# ansible/roles/infra_verify/handlers/main.yml
# Handlers are empty in Phase 7; reserved for Phase 8+ (restart monitoring on config change, etc.)
```

- [ ] **Step 4: Write test acceptance checklist (test-role.md)**

Full content in task brief (too long for inline here).

- [ ] **Step 5: Commit scaffold**

```bash
git add ansible/roles/infra_verify/{tasks,handlers,templates,tests}
git commit -m "chore(phase-7): scaffold infra_verify role with defaults"
```

---

### Task 2: Implement Role Tasks — User, Files, ACL, Cron, SMTP

**Files:**
- Modify: `ansible/roles/infra_verify/tasks/main.yml`
- Create: `ansible/roles/infra_verify/templates/msmtprc.j2`
- Create: `ansible/roles/infra_verify/templates/cron-run.sh.j2`

**Interfaces:**
- Consumes: `infra_verify_user`, `infra_verify_home`, `infra_verify_dest`, `smtp_*` vars from defaults
- Produces: deployed engine at `/opt/infra-verify`, cron job in `/etc/cron.d/`, msmtp config at `/root/.msmtprc`

Full task details in task brief.

---

### Task 3: Wire Role into Playbook & Create Group Vars

**Files:**
- Modify: `ansible/playbooks/02-install-infra.yml`
- Create: `ansible/inventories/qa/group_vars/all/infra_verify.yml`
- Create: `ansible/inventories/prod/group_vars/all/infra_verify.yml`

**Interfaces:**
- Consumes: role variables from defaults
- Produces: role called with `--tags infra_verify` support

Full task details in task brief.

---

### Task 4: Add Shellcheck to Jenkins Validate Stage

**Files:**
- Modify: `Jenkinsfile`

**Interfaces:**
- Consumes: bash scripts in `operations/infra-verify/`
- Produces: Jenkins Validate stage that runs `shellcheck` on all `.sh` files

Full task details in task brief.

---

### Task 5: Update README / Phase 7 Transition Doc

**Files:**
- Create: `docs/operations/phase-7-deployment.md`
- Modify: `docs/operations/LOCAL-TEST-GUIDE.md` (add note about deployment)

**Interfaces:**
- Consumes: phase completion state from Phase 1-6
- Produces: deployment instructions for QA/PROD

Full task details in task brief.

---

### Task 6: Final Validation & Phase 7 Complete Summary

**Files:**
- None (validation only)

**Interfaces:**
- Consumes: all Phase 7 deliverables
- Produces: validation report

Full task details in task brief.

---

## Plan Summary

**Phase 7 delivers:** A production-ready Ansible deployment of the infra-verify engine to QA and PROD, with:
- Unprivileged `infraverify` user (no sudo, no write access outside history/audit)
- Engine files deployed to `/opt/infra-verify/` on each host
- Log directory ACL for read access (needed for LOG family checks)
- SMTP config from Vault (credentials never in logs or on CLI)
- Daily cron job at 06:15 IST
- Wire into existing `02-install-infra.yml` playbook
- Shellcheck integrated into Jenkins Validate stage
- Full deployment guide for operators

**Acceptance:** Phase 7 is accepted when (1) Ansible validation passes, (2) role is deployed to QA via `--tags infra_verify`, (3) 3 consecutive daily runs succeed with emails delivered, and (4) infra lead approves. PROD deployment follows after QA sign-off.

**Rollback:** Remove the `--tags infra_verify` tag from playbook or delete cron entry; reports are preserved.
