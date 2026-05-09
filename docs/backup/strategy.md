# Backup Strategy

## Scope

This repository stores the backup strategy artifacts for Dhanman infrastructure
without storing backup payloads themselves in Git.

## Backup Domains

1. PostgreSQL logical backups
2. Filesystem backups for application and uploaded files
3. DR audit snapshots for rebuild evidence
4. Restore verification reports

## Repo Conventions

- `scripts/backup/` contains executable backup and verification helpers.
- `scripts/restore/` contains restore and smoke-test helpers.
- `configs/backup/` contains sample configuration and exclusion rules.
- `snapshots/` contains metadata, audit evidence, and restore reports only.
- Large backup archives must go to external storage such as B2, S3, or another
  remote repository, not into Git.

## Suggested Flow

1. Run database and filesystem backups on schedule.
2. Upload backup outputs to remote object storage.
3. Keep a manifest for each backup run.
4. Periodically restore into an isolated target and record the result under
   `snapshots/restore-reports/`.
5. Retain DR audit outputs under `snapshots/audits/`.
