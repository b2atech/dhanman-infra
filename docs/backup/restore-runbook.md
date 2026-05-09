# Restore Runbook

## Goal

Restore a known backup into a clean target and verify that the application can
start and basic data is readable.

## Minimum Steps

1. Pick a backup set and note its timestamp and source environment.
2. Restore PostgreSQL first.
3. Restore application file storage next.
4. Start dependent services.
5. Run smoke tests from `scripts/restore/smoke-test-restore.sh`.
6. Save the outcome under `snapshots/restore-reports/<env>/`.

## Evidence To Save

- Backup identifier
- Restore timestamp
- Target host or environment
- Restore duration
- Validation results
- Operator notes
