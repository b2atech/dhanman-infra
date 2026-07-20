# Phase 7 Deployment Guide — infra-verify Engine (Ansible Rollout)

**Audience:** operators deploying or maintaining the infra-verify daily check engine on
QA and PROD. No prior familiarity with the check engine's internals is assumed — this
guide only covers *deploying and operating* it. For how the engine itself works (check
families, JSON/HTML report schema, exit codes), see
`docs/operations/LOCAL-TEST-GUIDE.md` and `docs/superpowers/plans/phase-7-ansible-deployment.md`.

**Status:** role implemented and validated (Ansible syntax-check, ansible-lint, shellcheck
in CI). This guide documents rollout to QA, then PROD, per the plan's staged approach.

---

## 1. Overview

Phase 7 packages the read-only infra-verify check engine (built in Phases 0–6) as a new
Ansible role, `infra_verify`, and wires it into the existing `02-install-infra.yml`
playbook behind the `infra_verify` tag. Running the role on a host:

1. Creates an unprivileged system user `infraverify` (no login shell, no sudo) with
   supplementary membership in `systemd-journal` (needed so the engine can read
   `journalctl` output for the SVC-06 check).
2. Copies the engine (`operations/infra-verify/`) from the repo to `/opt/infra-verify`
   on the target host, owned by `infraverify:infraverify`.
3. Grants `infraverify` read-only ACL access to the service logs directory
   (`/var/www/<host>/logs`) so the LOG family checks work without granting broader
   filesystem access.
4. Renders SMTP credentials from Vault (`secret/shared/global`) into `/root/.msmtprc`
   (mode `0600`, root-only) — **credentials are never printed to the CLI, logged, or
   committed anywhere.**
5. Installs a single daily cron job (`/etc/cron.d/infra-verify-daily`, default
   `06:15` IST) that runs the engine via a wrapper script, logs to syslog, and prevents
   overlapping runs with a lock file.
6. Verifies the deployment: confirms the entrypoint script exists and is executable,
   and confirms the cron entry was installed.

The role does **not** touch any existing role (`monitoring`, `dhanman_service`,
`nginx`, etc.), the inventory files, or the Jenkins pipeline structure beyond adding a
`shellcheck` lint pass in the Validate stage. It is entirely additive and gated behind
its own tag, so it can be run — or skipped — independently of every other
infrastructure component.

**What the engine checks, once running:** services (SVC), health endpoints (HLT),
application logs (LOG), Promtail (PT), Loki (LK), Prometheus (PM), and Grafana (GF) —
seven check families, each producing a `HEALTHY` / `WARNING` / `CRITICAL` /
`NOT_APPLICABLE` / `NOT_CONFIGURED` result per item, rolled up into one JSON + one HTML
report per run, emailed to the configured recipients and archived in
`/opt/infra-verify/history/`.

**Exit codes** (used by the cron wrapper to decide the syslog severity it logs at):

| Code | Meaning |
|---|---|
| `0` | All checks HEALTHY |
| `1` | At least one WARNING, no CRITICAL |
| `2` | At least one CRITICAL finding |
| `3` | Engine failure (crashed, timed out, or couldn't run) |
| `75` | Lock held — a previous run is still in progress; this run was skipped, not failed |

---

## 2. Prerequisites (check before running anything)

Confirm all of the following **before** invoking the playbook. Skipping this step is
the single most common cause of a failed or silently-broken rollout.

- [ ] **Vault is unsealed** on the target environment. The role reads
      `secret/shared/global:smtp_username` / `smtp_password` via the `hashi_vault`
      lookup plugin at playbook run time — if Vault is sealed, this task fails
      immediately (visibly, not silently).
      ```bash
      ssh ubuntu@<host-ip>
      export VAULT_ADDR='http://127.0.0.1:8200'
      vault status   # "Sealed: false" required
      ```
- [ ] **`VAULT_ROLE_ID_QA` / `VAULT_ROLE_ID_PROD`** exported in the shell you're running
      `ansible-playbook` from (same requirement as every other role in this repo — see
      `CLAUDE.md`).
- [ ] **SMTP relay is reachable** from the target host. The engine uses `msmtp` against
      `smtp-relay.brevo.com:587` (see `ansible/roles/infra_verify/defaults/main.yml`).
      A quick reachability check once the role is deployed:
      ```bash
      ssh ubuntu@<host-ip>
      echo "Test infra-verify SMTP" | msmtp --debug -a default your-address@example.com
      ```
- [ ] **You have the recipient list confirmed** for the environment you're deploying to
      (see `ansible/inventories/<env>/group_vars/all/infra_verify.yml`). QA and PROD
      have separate recipient lists — do not reuse one for the other.
- [ ] **You are on a working directory with the current `feature/coo-infra-verify`
      branch** (or whichever branch/tag has Tasks 1–4 merged) checked out, so the role
      files and `02-install-infra.yml` wiring are present.

---

## 3. QA Deployment

QA goes first, always. Nothing is deployed to PROD until QA has run cleanly for **3
consecutive days** with emails actually delivered.

### Step 1 — Run the role

From the repo root, with `VAULT_ROLE_ID_QA` exported:

```bash
ansible-playbook -i ansible/inventories/qa ansible/playbooks/02-install-infra.yml \
  --tags infra_verify \
  -e vault_role_id=$VAULT_ROLE_ID_QA
```

**What you should see:** a normal Ansible run listing each task in
`ansible/roles/infra_verify/tasks/main.yml` (group/user creation, file copy, ACL grant,
Vault lookup, msmtp render, cron install, verification), ending with
`PLAY RECAP ... ok=<N> changed=<N> unreachable=0 failed=0`. The final task in the role
prints a `debug` summary block (user, path, cron schedule, history/audit dirs) — read it
to sanity-check the values that were actually applied, not just that the play didn't
fail.

If `failed=0` is not what you see, stop here — do not proceed to PROD, and see
Troubleshooting (§6) before re-running.

### Step 2 — Verify the deployment on the host

SSH to QA and check each piece the role claims to have set up:

```bash
ssh ubuntu@54.37.159.71
```

**User and permissions:**
```bash
id infraverify
# Expect: uid/gid for infraverify, groups=...,systemd-journal
getent passwd infraverify | grep nologin   # shell should be nologin
sudo -l -U infraverify                     # should show "not allowed to run sudo" (i.e., no entry)
```

**Files deployed:**
```bash
ls -la /opt/infra-verify/bin/run-infra-report.sh   # should exist, mode 0755, owner infraverify
ls -la /opt/infra-verify/history/                  # should exist, writable by infraverify
ls -la /var/log/dhanman/infra-audit/               # should exist, root:adm
```

**ACL on the log directory:**
```bash
getfacl /var/www/qa/logs | grep infraverify
# Expect: user:infraverify:r-x
```

**msmtp config (do NOT cat the whole file on a shared terminal — it contains the SMTP
password):**
```bash
sudo test -f /root/.msmtprc && sudo stat -c '%a %U:%G' /root/.msmtprc
# Expect: 600 root:root
```

**Cron job:**
```bash
cat /etc/cron.d/infra-verify-daily
# Expect a line scheduling /opt/infra-verify/cron-run.sh at 06:15 IST, run as root
```

### Step 3 — Do a manual dry run before waiting for cron

Don't wait until 06:15 tomorrow to find out something's wrong. Trigger one run by hand,
as the same user cron will use:

```bash
sudo /opt/infra-verify/cron-run.sh
echo "Exit code: $?"
```

Expected exit code `0` (healthy) or `1` (warnings present, but the run itself worked —
warnings are informational, not a deployment failure). `2` means a real CRITICAL finding
was detected (investigate the underlying service, not the deployment). `3` or `75` mean
the *run itself* failed or was skipped — see Troubleshooting.

Then confirm output landed where expected:
```bash
ls -la /opt/infra-verify/history/          # a report-qa-<timestamp>.json and .html
sudo journalctl --no-pager | grep infra-verify-cron | tail -50   # syslog trail of the run
```

And confirm the email actually arrived in the QA recipients' inboxes (see
`ansible/inventories/qa/group_vars/all/infra_verify.yml` for the current list).

### Step 4 — Monitor for 3 consecutive days

This is not optional. Let the daily cron job run unattended for **3 consecutive days**
and confirm, each day:

- [ ] Cron fired at the scheduled time (`journalctl | grep infra-verify-cron` shows a
      "Starting daily check run" line at ~06:15 IST)
- [ ] The run completed with an exit code you'd expect given real system state (`0` or
      `1` under normal conditions)
- [ ] A new report pair appeared in `/opt/infra-verify/history/`
- [ ] The email was delivered to the QA recipient list
- [ ] No secrets appear in the JSON/HTML report (spot-check: `grep -iE
      "password|token|secret" /opt/infra-verify/history/report-qa-<latest>.json` should
      return nothing)

Only once all 3 days pass cleanly do you move to PROD (§4). If a day fails, do not reset
the counter silently — diagnose and fix first (§6), then restart the 3-day count.

---

## 4. PROD Deployment

Do not start this section until QA's 3-day monitoring period (§3, Step 4) has passed
cleanly and been reviewed. PROD deployment follows the identical mechanical steps as
QA — the only material difference is the recipient list and initial rollout caution.

### Step 1 — Run the role

```bash
ansible-playbook -i ansible/inventories/prod ansible/playbooks/02-install-infra.yml \
  --tags infra_verify \
  -e vault_role_id=$VAULT_ROLE_ID_PROD
```

Same expected output as QA (§3, Step 1): `PLAY RECAP` with `failed=0`, plus the role's
final `debug` summary.

### Step 2 — Verify, same checks as QA

Repeat every check in §3 Step 2, against `51.79.156.217` instead of the QA host, and
against `/var/www/<prod-host-short-name>/logs` for the ACL check. Also repeat the
manual dry run (§3 Step 3) before relying on cron.

### Step 3 — Initial recipient list: infra lead only

**Important:** `ansible/inventories/prod/group_vars/all/infra_verify.yml` should be set
so that the *first* PROD emails go only to the infra lead — not the full CTO/COO
distribution list. This limits the blast radius of any false positives or noisy alerts
while PROD is still being validated in production conditions (different traffic
patterns, different log volume than QA).

### Step 4 — Monitor for 5 confirmed runs before widening the list

Let PROD run unattended and confirm **5 consecutive successful daily runs** (same
checklist as QA §3 Step 4, applied to PROD). "Successful" means: cron fired on
schedule, exit code was `0` or `1` (not `2`/`3`/`75` for an infrastructure reason rather
than a real incident), a report was written, and the email reached the infra lead.

### Step 5 — Enable full recipient list

Once 5 confirmed runs have passed review, update
`ansible/inventories/prod/group_vars/all/infra_verify.yml` to the full list (CTO + COO +
infra lead — see the file's comments for the current addresses) and re-run the role:

```bash
ansible-playbook -i ansible/inventories/prod ansible/playbooks/02-install-infra.yml \
  --tags infra_verify \
  -e vault_role_id=$VAULT_ROLE_ID_PROD
```

Re-running only changes the cron job's recipient configuration (via the recipients
variable consumed by the engine) — it does not recreate the user, re-copy files
unnecessarily, or disrupt history already collected; the role's tasks are idempotent.

Confirm the next day's email reaches all recipients on the widened list before
considering PROD rollout complete.

---

## 5. Rollback

Two ways to disable the daily checks, from least to most invasive. Existing reports in
`/opt/infra-verify/history/` and audit logs in `/var/log/dhanman/infra-audit/` are
**never deleted** by either method — only the *scheduling* is undone.

### Option A — Remove the cron entry directly (fastest, no playbook run needed)

```bash
ssh ubuntu@<host-ip>
sudo rm /etc/cron.d/infra-verify-daily
```

This stops future runs immediately. The engine, user, and files remain in place — you
can still trigger a manual run with `sudo /opt/infra-verify/cron-run.sh` if needed. Use
this when you need to stop the noise *right now* and will sort out the Ansible side
later.

### Option B — Untag the role in the playbook (the "proper" rollback)

If you want the role to stop being applied on future `02-install-infra.yml` runs
entirely (e.g., you're decommissioning the feature, not just pausing it), remove or
comment out the role block in `ansible/playbooks/02-install-infra.yml`:

```yaml
    # - role: infra_verify
    #   tags: infra_verify
    #   when: inventory_hostname in groups.get('dhanman_qa', []) or inventory_hostname in groups.get('dhanman_prod', [])
```

This does not retroactively undo anything already on the host (cron entry, user,
files) — it only prevents the role from being re-applied or re-verified on the next
full playbook run. Combine with Option A if you also want the existing cron entry gone
immediately.

To fully tear down a host's deployment (rare — only for full decommission):
```bash
ssh ubuntu@<host-ip>
sudo rm -f /etc/cron.d/infra-verify-daily
sudo rm -rf /opt/infra-verify        # WARNING: deletes history/ reports too — back up first if needed
sudo userdel infraverify
sudo groupdel infraverify
sudo rm -f /root/.msmtprc
```

---

## 6. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Playbook fails at "Fetch SMTP credentials from Vault" | Vault is sealed, or the AppRole/SecretID used for `vault_role_id` doesn't have read access to `secret/shared/global` | `vault status` on the host; unseal if needed (see `CLAUDE.md`). Confirm the SecretID hasn't expired (see prior incident: Vault AppRole SecretID expiry after domain migration) |
| Playbook fails at "Grant infraverify read access to service logs directory" (`acl` module, path not found) | The task's log directory path must resolve to the inventory-defined `services_base_dir` (`/var/www/qa` or `/var/www/prod`, set in each environment's `group_vars/all/main.yml`) — if it instead resolves to something host-name-derived (e.g. `/var/www/dm-qa`), the path won't exist and the `acl` module errors | Confirm the task uses the global `services_base_dir` var (no task-local override) — check `ansible/roles/infra_verify/tasks/main.yml`'s ACL task has no `vars:` block shadowing it. Then verify the target dir with `ls -ld {{ services_base_dir }}/logs` on the host before re-running |
| Cron entry exists but never fires | Host's system cron daemon isn't running, or `/etc/cron.d/infra-verify-daily` has bad syntax | `sudo systemctl status cron`; `sudo cat /etc/cron.d/infra-verify-daily` — check for a trailing newline and correct 5-field schedule; `sudo run-parts --test /etc/cron.d` won't apply here (this is cron.d, not cron.daily) — use `crontab -l -u root` style validation via `sudo cat` instead |
| Email never arrives, run exits 0 | SMTP credentials wrong/expired in Vault, or relay blocking the host's IP, or msmtp misconfigured | `sudo msmtp --debug -a default <test-address>` on the host (never paste the debug output containing credentials into chat/tickets — read it locally only); check msmtp's own log at `~root/.msmtp.log` |
| Run exits `3` (engine failure) | Script crashed, a check module errored unexpectedly, or a dependency (`python3`, `curl`) is missing on the host | `sudo journalctl --no-pager \| grep infra-verify-cron \| tail -100` for the full trail; re-run manually with `sudo /opt/infra-verify/bin/run-infra-report.sh --environment <qa|prod>` (not the cron wrapper) to see raw stderr |
| Two runs overlap / run exits `75` | A previous run is still executing when cron fires again — normally caused by a hung check (e.g., a slow `docker exec` call) rather than the schedule itself | This is not a failure by design (`75` = "skipped, lock held", not "crashed"). If it happens repeatedly, investigate why a run is taking longer than the interval to the next scheduled run, not just the lock |
| Lock file stuck (every run exits `75` even though no run is actually in progress) | A previous run was killed (OOM, host reboot mid-run) without releasing `/var/lock/infra-verify.lock` | Confirm no `run-infra-report.sh` process is actually running (`ps aux \| grep run-infra-report`), then `sudo rm /var/lock/infra-verify.lock` and re-run manually to confirm it now completes |
| `journalctl` / "Operation not permitted" in the SVC-06 check | `infraverify` isn't in the `systemd-journal` group (role task didn't apply, or ran before this task existed) | `id infraverify` should list `systemd-journal`; if missing, re-run the role (`--tags infra_verify`) — this task is idempotent and safe to repeat |
| Report JSON/HTML contains what looks like a credential | Should never happen — `lib/report.sh`'s secret-scanning exists specifically to catch this | Treat as a real incident: stop the cron job (§5 Option A) immediately, rotate the credential in Vault, then investigate before re-enabling |

---

## 7. Next Steps

Phase 7 completes the deployment mechanics. Follow-on work (not part of this phase):

- **Phase 8+**: alerting integration beyond email (e.g., piping CRITICAL results into
  the existing Grafana/Uptime Kuma alerting paths), historical trend dashboards built
  from the accumulated `history/` JSON reports, and possibly a lightweight web view of
  the latest report instead of only email/file access.
- **Fixed during this phase (verify on first real run)**: two inventory-mismatch bugs
  were caught during doc review and corrected before the first deployment — (1) the
  role's `when` clause originally referenced inventory groups `qa`/`prod` instead of the
  real group names `dhanman_qa`/`dhanman_prod`, and (2) the ACL task originally
  recomputed its own `services_base_dir` from `inventory_hostname_short` instead of
  reusing the correct, already-defined global var, which would have pointed it at
  `/var/www/dm-qa` instead of `/var/www/qa`. Both are fixed in the current role/playbook,
  but since neither has been exercised against a real host yet, treat the very first QA
  run as the actual validation of both fixes — see the troubleshooting table above if
  either resurfaces.
- **PgBouncer / Vault-on-old-server cleanup** and other longstanding infra TODOs remain
  tracked in `CLAUDE.md` — unrelated to this phase but worth keeping in view during any
  future infra_verify role changes, since they share the same playbook.
