# infra_verify Role — Acceptance Test Checklist

Manual verification steps for the `infra_verify` Ansible role. Run against QA first;
PROD deployment follows only after QA sign-off (see Phase 7 plan).

> **Note:** This checklist is scaffolded in Task 1 based on the acceptance criteria and
> global constraints in `docs/superpowers/plans/phase-7-ansible-deployment.md`. It will be
> extended as Tasks 2–4 add the role's tasks, templates, and playbook wiring.

## Pre-flight

- [ ] `ansible-playbook --syntax-check` passes for the playbook including this role
- [ ] `ansible-lint ansible/roles/infra_verify/` passes (or documented exceptions)
- [ ] Role does not modify `ansible/roles/monitoring/`, `ansible/roles/dhanman_service/`,
      or `ansible/inventory/`

## User & filesystem

- [ ] `infraverify` system user exists with shell `/usr/sbin/nologin` and no sudo rights
- [ ] `infraverify` group exists; user has `systemd-journal` supplementary membership
      (required for SVC-06 journal reads)
- [ ] Engine files present at `infra_verify_dest` (`/opt/infra-verify`) owned by
      `infraverify:infraverify`
- [ ] `infra_verify_history_dir` (`/opt/infra-verify/history`) exists and is writable by
      `infraverify`
- [ ] `infra_verify_audit_dir` (`/var/log/dhanman/infra-audit`) exists with correct
      ownership/permissions
- [ ] No write access exists for `infraverify` outside of history/audit directories

## SMTP / email

- [ ] SMTP credentials are sourced from Vault (`secret/shared/global`) — never present in
      playbook output, `ansible -vvv` logs, or committed files
- [ ] msmtp config renders with `smtp_host`, `smtp_port`, `smtp_from`, and TLS enabled
      per `smtp_use_tls`
- [ ] Test email sends successfully from the target host using the rendered config

## Cron

- [ ] Cron entry named `infra_verify_cron_name` (`infra-verify-daily`) exists in
      `/etc/cron.d/`
- [ ] Cron entry is scheduled for `infra_verify_schedule_hour:infra_verify_schedule_minute`
      (default `06:15`) in the host's configured timezone (IST)
- [ ] Cron job is idempotent — re-running the playbook does not duplicate or corrupt the
      cron entry
- [ ] Lock file (`infra_verify_lock_file`) prevents overlapping runs if a prior run is
      still in progress

## Execution & exit codes

- [ ] Manual run as `infraverify` user completes and returns one of the documented exit
      codes: `0` (healthy), `1` (warning), `2` (critical), `3` (engine failure)
- [ ] Cron wrapper captures stdout/stderr and logs at `infra_verify_log_level` (default
      `INFO`)
- [ ] A report is written to the history directory for each run

## Recipients & rollout

- [ ] `infra_verify_recipients` resolves to the correct list per environment:
      - QA: infra lead + devops team
      - PROD (initial): infra lead only, until 5 consecutive QA days pass
      - PROD (after sign-off): CTO + COO + infra lead
- [ ] 3 consecutive daily QA runs succeed with emails delivered before PROD is enabled

## Rollback

- [ ] Removing the `infra_verify` tag from `02-install-infra.yml` (or the cron entry)
      disables the daily run without deleting existing reports/history
