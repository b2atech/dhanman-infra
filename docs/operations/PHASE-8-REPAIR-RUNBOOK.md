# Phase 8 — Repair Script Runbook

Repair scripts are **production safety-critical**. Each script:
- Requires explicit operator confirmation before making changes (QA: type
  `yes`; PROD: type an exact phrase that embeds the target and today's date)
- Backs up files before modifying them (file-based repairs only)
- Validates the change worked (postcheck)
- Records the action in an audit log
- Can roll back on failure

## When to use

The daily infra-verify report recommends a repair script by name, e.g.:

```
Recommended action: operations/repairs/service/restart-one-specific-service.sh
```

That script name tells you exactly what will be repaired and how.

## Example: restart a service

Scenario: the report says `dhanman-purchase-prod` is CRITICAL (service down).
Recommended action: `operations/repairs/service/restart-one-specific-service.sh`.

Steps:

1. SSH to PROD: `ssh ubuntu@51.79.156.217`
2. Run the script:
   ```bash
   sudo bash operations/repairs/service/restart-one-specific-service.sh dhanman-purchase-prod.service
   ```
3. The script will:
   - Show the current unit state (precheck)
   - Ask for confirmation:
     `Do you want to restart systemd unit dhanman-purchase-prod.service? (PROD REPAIR dhanman-purchase-prod.service 20260721): `
   - You type exactly: `PROD REPAIR dhanman-purchase-prod.service 20260721`
   - The script restarts the service
   - The script verifies it's active (postcheck)
   - The script records the action in `/var/log/dhanman/infra-audit/repairs.jsonl`

4. Exit codes:
   - `0` success
   - `1` precondition failed (bad unit name, wrong host, etc.)
   - `2` user cancelled (you typed something other than the confirmation phrase)
   - `3` postcheck failed — rollback attempted (succeeded if there was a file
     to restore; for service/container restarts there is nothing to roll
     back to, so this just means the action didn't verify)
   - `4` CRITICAL — rollback itself failed (manual intervention needed)

## Safety gates

Every repair script has three gates:

**Gate 1: Confirmation**
- QA: type `yes`
- PROD: type `PROD REPAIR <target> <date>` exactly
- If you type anything else, the script exits cleanly (exit 2) — nothing is
  touched.

**Gate 2: Postcheck**
- After applying the change, the script validates it worked.
- For repairs that modified a file, a validation failure triggers an
  automatic restore from backup — you will see the rollback happen (exit 3,
  not silent).
- For repairs with no file to restore (a service or container restart),
  exit 3 means the postcheck failed but there is nothing to roll back —
  investigate the service/container directly.

**Gate 3: Audit**
- Every change is recorded in `/var/log/dhanman/infra-audit/repairs.jsonl`.
- Includes timestamp, what changed, who ran it (`$SUDO_USER`), and the
  backup location (if any).

## Troubleshooting

If a repair fails with exit `4` (CRITICAL — rollback failed):
- **Do not** retry the script.
- Contact the infra lead immediately.
- The backup file is preserved at `/opt/repairs/backups/<script>/<repair_id>/`.
- The script's stderr output names the exact backup path to restore from
  manually.

If a repair fails with exit `3` (postcheck failed, rollback ok):
- The file (or service/container) was changed, but the postcheck caught a
  problem.
- If a file was involved, the backup has already been restored.
- Investigate why the postcheck failed (logs, configuration) before
  re-running the repair.

## Approved repair scripts

This runbook covers Phase 8's initial set (proof-of-concept):

- `restart-one-specific-service.sh` — restart a single `dhanman-*` systemd unit
- `validate-promtail-config.sh` — read-only Promtail config syntax check (no mutation)
- `restart-promtail.sh` — restart the Promtail Docker container
- `validate-prometheus-config.sh` — read-only Prometheus config/rules syntax check (no mutation)

Approval process for each new repair script:

1. Code review (safety-focused review of confirm/backup/rollback/audit paths)
2. QA testing (deliberately break the target, verify the repair fixes it)
3. Sudoers entry added to `/etc/sudoers.d/dhanman-repairs-<script>`
4. PROD deployment via Ansible (separate approval)

## Known limitations (Phase 8 scope)

- The `fallback` host's `env` value (`fallback`, from `ansible/inventories/fallback/group_vars/all/main.yml`)
  is neither `qa` nor `prod`. `repair_confirm` only special-cases `prod`;
  every other value — including `fallback` — falls through to the QA-style
  `yes`/`no` prompt. Repair scripts have not been exercised against the
  fallback host; treat that as untested until a future phase addresses it
  explicitly.
- Email notification on rollback failure (exit 4) is not yet wired up —
  tracked as a Phase 10 TODO in `repair_rollback_and_exit`.
- `repair_tripwire_check` scans the whole filesystem (`find /`) per
  allowlisted path; this can be slow on hosts with large filesystems. It is
  a warning-only check and never blocks or rolls back on its own.
