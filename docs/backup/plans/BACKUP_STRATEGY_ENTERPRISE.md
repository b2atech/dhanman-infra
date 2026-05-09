# Enterprise DR Backup Strategy for Dhanman Platform

## Executive Summary

This strategy uses a cost-effective 3-2-1-1-0 model:

- 3 copies of critical data: production, local hot backup, offsite immutable backup.
- 2 storage types: server disk plus object storage.
- 1 offsite copy: Backblaze B2.
- 1 immutable copy: B2 Object Lock / retention-protected bucket.
- 0 untested backups: every backup set must be verified and periodically restored.

The previous plan had the right coverage areas, but it relied too much on raw `pg_dump`, `rsync --delete`, and manual restore assumptions. The updated design uses specialized tools where they matter:

- PostgreSQL: `pgBackRest` with WAL archiving and point-in-time recovery.
- Vault: raft snapshots, encrypted before leaving the host.
- MinIO and service files: `restic` encrypted, deduplicated snapshots.
- Offsite storage: Backblaze B2 with Object Lock for ransomware-resistant recovery.
- Recovery proof: scheduled restore drills and verification reports.

## 1. Recovery Objectives

| Component | Target RPO | Target RTO | Primary Recovery Method |
|---|---:|---:|---|
| Vault | 1 hour | 30 minutes | Latest encrypted raft snapshot |
| PostgreSQL | 15 minutes | 30 to 60 minutes | pgBackRest base backup + WAL PITR |
| MinIO objects | 4 hours | 1 to 2 hours | restic restore from local or B2 repo |
| Service configs | 24 hours | 30 minutes | restic restore or Git-managed config |
| Full new PROD loss | 15 minutes to 4 hours | 4 hours | Rebuild host, restore Vault, DB, MinIO, configs |
| Ransomware event | Last clean immutable snapshot | 4 to 8 hours | Restore from B2 Object Lock protected backup |

The PostgreSQL RPO target assumes WAL archiving is healthy. If WAL archiving fails, the effective RPO falls back to the last successful full/differential backup.

## 2. Platform Topology

| Role | SSH Alias | Host | Purpose |
|---|---|---|
| New PROD / PROD-N | `dhanman-prod-n` | `57.129.74.139` | First production backup source and primary backup orchestration host |
| Existing PROD / Warm | `dhanman-prod-ubuntu` | `51.79.156.217` | Warm backup receiver and emergency restore host |
| QA | `dhanman-ubuntu` | `54.37.159.71` | Lower-priority backup source and restore drill target |
| B2 | n/a | Backblaze B2 | Offsite immutable storage |

Keep PROD and QA backup configuration separate. A single script may orchestrate both, but each environment must have explicit hosts, credentials, and retention.

## 2.1 Current Setup Status

| Check | Status | Result |
|---|---|---|
| SSH to new PROD / PROD-N | Done | `dhanman-prod-n` / `57.129.74.139` returns hostname `dm-prd-n` |
| SSH to existing PROD / Warm | Done | `dhanman-prod-ubuntu` / `51.79.156.217` returns hostname `dhanman-prod` |
| SSH to QA | Done | `dhanman-ubuntu` / `54.37.159.71` returns hostname `dhanman-qa` |
| New PROD PostgreSQL client | Done | `psql (PostgreSQL) 18.3` installed |
| New PROD backup disk preflight | Done | `/` and `/opt` have about `179G` free |
| New PROD sudo preflight | Done | Passwordless sudo works for `ubuntu` |
| New PROD pgBackRest | Done | `pgBackRest 2.58.0` installed |
| New PROD restic | Done | `restic 0.17.3` installed |
| New PROD rclone | Done | `rclone 1.60.1` installed |
| Existing PROD backup tooling | Done | `pgBackRest 2.58.0`, `restic 0.17.3`, and `rclone 1.60.1` installed |
| QA backup tooling | Done | `pgBackRest 2.58.0`, `restic 0.17.3`, and `rclone 1.60.1` installed |
| Backup directory layout | Done | `/opt/backups/{pgbackrest,restic,vault,minio,configs,logs,manifests,tmp}` created on all three hosts |
| Existing PROD PGDG apt source | Done | Replaced stale/conflicting PGDG entries with working `noble-pgdg` source |
| QA apt repository health | Pending | Tool install succeeded, but `apt-get update` has unrelated Jenkins/RabbitMQ repository errors |
| New PROD pgBackRest stanza | Done | Stanza `main` created for PostgreSQL 18 data path `/var/lib/postgresql/18/main` |
| New PROD WAL archiving settings | Done | PostgreSQL restarted and WAL archiving is active with pgBackRest `archive-push` |
| New PROD pgBackRest check | Done | `pgbackrest --stanza=main check` passed and archived WAL `000000010000000000000011` |
| New PROD first full backup | Done | Full backup `20260509-130826F` completed successfully |
| Warm PROD pgBackRest repo2 | Done | `repo2` configured on `51.79.156.217` with path `/opt/backups/pgbackrest-repo2` |
| Warm PROD first full backup | Done | Full backup `20260509-141935F` completed successfully on `repo2` |
| PostgreSQL backup scheduling | Done | `postgres` cron replaced old `pg_dump` jobs with pgBackRest full/incremental jobs for `repo1`, `repo2`, and daily `check` |
| B2 PostgreSQL bucket | Done | `dhanman-prod-postgres-immutable` created with Private access, encryption, and Object Lock |
| B2 Vault bucket | Done | `dhanman-prod-vault-immutable` created with Private access, encryption, and Object Lock |
| B2 files bucket | Done | `dhanman-prod-files-immutable` created with Private access, encryption, and Object Lock |
| B2 configs bucket | Done | `dhanman-prod-configs-immutable` created with Private access, encryption, and Object Lock |
| PostgreSQL repo3 to B2 | Done | `repo3` configured against Backblaze S3 endpoint `s3.us-east-005.backblazeb2.com` |
| PostgreSQL first full backup to repo3 | Done | Full backup `20260509-160202F` completed successfully in Backblaze |
| Vault B2 remote and script | Done | Live `vault_backup.sh` uploads daily Vault file-backend archive to `dhanman-prod-vault-immutable` |
| Files B2 remote and script | Done | Live `minio_backup.sh` uploads `/opt/minio/data` backups to `dhanman-prod-files-immutable` |
| Configs B2 remote and script | Done | Live `config_backup.sh` uploads config archives to `dhanman-prod-configs-immutable` |
| Root backup cron schedule | Done | Root cron installed for Vault at `06:15`, files at `06:45`, and configs at `07:15` |

## 3. Recommended Tooling

| Area | Tool | Reason |
|---|---|---|
| PostgreSQL physical backup and PITR | `pgBackRest` | Supports full, differential, incremental backups, WAL archiving, checksums, multiple repositories, parallel restore, and S3-compatible storage. |
| PostgreSQL logical export | `pg_dump` | Secondary safety export for selected databases before risky releases or migrations. Not the main DR mechanism. |
| Files, MinIO exports, configs | `restic` | Encrypted, deduplicated, snapshot-based, easy restore, supports B2/S3-compatible remotes. |
| Object storage | Backblaze B2 | Low-cost hot object storage. Current public pricing starts at about `$6.95/TB/month`, with free egress up to policy limits. |
| Ransomware resistance | B2 Object Lock | Prevents backup deletion or modification until the retention date. |
| Audit snapshots | Existing `dr-audit-extended.sh` | Captures server state for rebuild evidence. |

Sources used for tool choices:

- pgBackRest official site: https://pgbackrest.org/
- PostgreSQL PITR documentation: https://www.postgresql.org/docs/current/continuous-archiving.html
- restic official site: https://restic.net/
- Backblaze B2 pricing: https://www.backblaze.com/cloud-storage/pricing
- Backblaze Object Lock docs: https://www.backblaze.com/docs/cloud-storage-object-lock

## 4. Backup Tier Design

| Tier | Location | Purpose | Retention |
|---|---|---|---|
| Hot | `/opt/backups` on new PROD / PROD-N (`57.129.74.139`) | Fast local restore | 7 to 14 days |
| Warm | `/opt/backups` on existing PROD (`51.79.156.217`) | Survive primary host loss | 30 days |
| Cold immutable | Backblaze B2 Object Lock buckets | Survive datacenter loss, ransomware, operator mistakes | 90 days minimum, 12 months for monthly anchors |

Do not use `rsync --delete` for warm replication until the backup set has passed verification. The safer flow is:

1. Write backup into a timestamped staging directory.
2. Generate manifest and checksums.
3. Verify the backup locally.
4. Sync/copy to warm server under the same immutable timestamp.
5. Upload/copy to B2.
6. Mark the backup set as `verified`.
7. Prune only after a newer verified backup exists.

## 5. PostgreSQL Strategy

### 5.1 Primary Method: pgBackRest

Use `pgBackRest` as the main production database backup system.

Recommended repositories:

| Repository | Target | Retention |
|---|---|---|
| `repo1` | Local disk on new PROD / PROD-N (`57.129.74.139`) | 2 full backups + required WAL |
| `repo2` | Warm server existing PROD (`51.79.156.217`) | 4 full backups + required WAL |
| `repo3` | Backblaze B2 immutable bucket | 90 days daily coverage + 12 monthly anchors |

Recommended schedule:

| Time | Backup Type | Frequency |
|---|---|---|
| Continuous | WAL archive push | Always |
| 01:30 | Incremental backup | Daily |
| 02:00 Sunday | Full backup | Weekly |
| Before risky release | Logical `pg_dump` | On demand |

Expected benefits:

- Restore to a point just before accidental delete, bad migration, or corruption.
- Faster backups than repeated full `pg_dump`.
- Lower storage cost because differential/incremental backups avoid full duplication.
- Built-in manifest/checksum verification.

### 5.2 Secondary Method: Logical Dumps

Keep logical dumps as a second line of defense, not as the primary DR method.

Use cases:

- Before database migrations.
- Before major deployments.
- For selective table or schema recovery.
- For cross-version migration testing.

Recommended retention:

- Daily logical dumps: 7 days.
- Pre-release logical dumps: 14 to 30 days.
- Monthly logical dump: 6 to 12 months if compliance requires it.

### 5.3 Required PostgreSQL Fixes

The backup user should use least privilege and explicit host rules.

Avoid this pattern:

```text
host all dhanmanbackup 0.0.0.0/0 md5
```

Prefer explicit rules:

```text
hostssl all dhanmanbackup 127.0.0.1/32 scram-sha-256
hostssl all dhanmanbackup 51.79.156.217/32 scram-sha-256
hostssl all dhanmanbackup 54.37.159.71/32 scram-sha-256
```

Also verify:

- PostgreSQL roles and globals are backed up.
- Extensions are documented.
- Target restore DB creation is scripted.
- PITR restore is tested at least monthly.

## 6. Vault Strategy

### 6.1 What to Back Up

- Vault raft snapshot.
- Vault policies.
- Auth method configuration.
- AppRole role IDs.
- Seal/unseal operational notes.

Avoid exporting all secret values to plaintext JSON unless there is a specific incident-response requirement.

Current live note:

- New PROD currently uses Vault `storage "file"` with path `/opt/vault/data`, not integrated raft.
- Until Vault storage is migrated to raft, the practical backup artifact is an archive of `/opt/vault/data` plus Vault config, not a raft snapshot.

### 6.2 Backup Flow

1. If using raft, create raft snapshot locally.
2. If using file backend, archive `/opt/vault/data` and Vault config locally.
3. Encrypt the backup artifact if it leaves the host outside the protected B2 bucket path.
4. Store local copy under `/opt/backups/vault/`.
5. Upload to B2 Object Lock bucket.
6. Verify restore on an isolated Vault test node monthly.

Recommended retention:

- Hourly local snapshots: 48 hours.
- Daily local snapshots: 14 days.
- Daily B2 snapshots: 90 days.
- Monthly B2 anchors: 12 months.

## 7. MinIO Strategy

Raw filesystem `rsync` of MinIO data is risky unless MinIO is stopped or the storage model is proven safe. For DR, prefer one of these methods:

| Option | Cost | Reliability | Recommendation |
|---|---:|---:|---|
| MinIO bucket replication to another MinIO/B2-compatible target | Medium | High | Best if MinIO is business-critical and changes often |
| `mc mirror` to B2 | Low | Good | Good simple option for object-level backups |
| `restic backup` of MinIO data directory while service is quiesced | Low | Good | Good if MinIO can tolerate backup window |
| Raw `rsync` while MinIO is running | Low | Risky | Avoid as primary strategy |

Recommended low-cost path:

1. Use `mc mirror` or `restic` for object data.
2. Enable bucket versioning for critical buckets where feasible.
3. Keep B2 Object Lock for immutable copies.
4. Test restore of a representative document set monthly.

Recommended retention:

- Daily snapshots: 14 days.
- Weekly snapshots: 8 weeks.
- Monthly snapshots: 12 months.

## 8. Service Config Strategy

Service config backups must be small, encrypted, and easy to inspect.

Back up:

- `/etc/nginx/`
- `/etc/postgresql/`
- `/etc/systemd/system/`
- `/etc/cron.d/`
- selected user crontabs
- `/opt/scripts/`
- deployment compose files
- monitoring configs
- generated service inventory from `dr-audit-extended.sh`

Do not blindly archive entire `/opt/app/` if it contains build artifacts, logs, cache, or secrets. Use an include list plus an exclude file.

Recommended method:

```bash
restic backup \
  /etc/nginx \
  /etc/postgresql \
  /etc/systemd/system \
  /etc/cron.d \
  /opt/scripts \
  --tag configs \
  --exclude-file /opt/scripts/backup/restic-excludes.txt
```

## 9. B2 Bucket Design

Use separate buckets or clearly separated prefixes with separate application keys.

Recommended buckets:

```text
dhanman-prod-postgres-immutable
dhanman-prod-vault-immutable
dhanman-prod-files-immutable
dhanman-prod-configs-immutable
dhanman-qa-backups
```

Object Lock rules:

- Enable Object Lock before production use.
- Use default bucket retention.
- Use compliance mode for critical monthly anchors.
- Use governance mode for daily operational backups if flexibility is needed.
- Use separate B2 application keys for upload and admin deletion/pruning.

Cost-effective retention:

| Backup Class | Daily | Weekly | Monthly |
|---|---:|---:|---:|
| PostgreSQL pgBackRest | 14 days | 8 weeks | 12 months |
| Vault | 14 days | 8 weeks | 12 months |
| MinIO/files | 14 days | 8 weeks | 12 months |
| Configs/audits | 30 days | 12 weeks | 12 months |

## 10. Safe Pruning Policy

Pruning must follow these rules:

- Never prune unless a newer verified backup exists.
- Never prune local, warm, and B2 in the same job.
- Never use `--delete` against a warm backup target from an unverified source.
- Keep at least one known-good monthly recovery point outside normal daily pruning.
- Keep restore drill reports before deleting old monthly anchors.

Recommended pruning order:

1. Verify latest local backup.
2. Verify latest warm backup.
3. Verify latest B2 backup or object listing.
4. Prune local old backups.
5. Prune warm old backups.
6. Let B2 lifecycle/Object Lock expire old immutable backups.

## 11. Verification and Monitoring

Every backup job must produce a manifest:

```json
{
  "environment": "prod",
  "backup_id": "2026-05-09_02-00",
  "component": "postgres",
  "tool": "pgbackrest",
  "status": "verified",
  "started_at": "2026-05-09T02:00:00Z",
  "finished_at": "2026-05-09T02:18:00Z",
  "artifacts": [
    {
      "path": "repo1/prod/2026-05-09_02-00",
      "checksum": "sha256:..."
    }
  ]
}
```

Minimum validation:

- PostgreSQL: `pgBackRest check`, WAL archive health, restore test.
- Vault: snapshot exists, encrypted artifact opens with recovery key, isolated restore test.
- MinIO/files: `restic check`, random file restore, application-level document read.
- Configs: restic snapshot listing and targeted restore.
- B2: object listing and retention lock confirmation.

Alert on:

- Missing backup.
- Backup older than expected RPO.
- Failed WAL archive push.
- B2 upload failure.
- Warm replication failure.
- Disk usage above 80%.
- Restore drill not completed by due date.

## 11.1 Context To Provide During An Incident

When asking for recovery help, provide these items first:

- Incident type: database corruption, deleted data, host loss, ransomware, Vault issue, MinIO issue, or config loss.
- Target host: new PROD (`57.129.74.139`), warm PROD (`51.79.156.217`), or QA (`54.37.159.71`).
- Recovery goal: latest possible state or a specific time before a bad change.
- Approximate bad event time in absolute format, for example `2026-05-09 13:22 IST`.
- What is still alive: PostgreSQL, Vault, MinIO, NGINX, app services, SSH.
- Whether we are restoring in place or to a clean host.
- Whether B2 is reachable.
- Whether user traffic has already been stopped.

Useful commands to run or give me output from:

```bash
hostname
date
sudo systemctl status postgresql@18-main --no-pager -n 30
sudo -u postgres pgbackrest --stanza=main info
sudo -u postgres psql -Atc "select now();"
df -h
```

## 12. Recovery Runbooks

### 12.1 PostgreSQL: Recover To Latest Possible State

Use this when the database host died or PostgreSQL is unrecoverable and the goal is to come back with minimum data loss.

Recovery source:

- Latest full backup
- Latest incremental chain
- All available WAL after that

Typical command flow:

```bash
sudo systemctl stop postgresql@18-main
sudo -u postgres pgbackrest --stanza=main --delta restore
sudo systemctl start postgresql@18-main
sudo -u postgres pgbackrest --stanza=main info
sudo -u postgres psql -Atc "select now();"
```

Use this when:

- Disk corruption
- Host reboot damage
- PostgreSQL will not start
- Restore to replacement host with latest state

### 12.2 PostgreSQL: Recover To A Specific Time

Use this when bad data was introduced by a delete, migration, script, or deployment and the database itself is still restorable.

Required context:

- Exact or approximate time before the bad event
- Time zone
- Whether to restore in place or to another host

Typical command flow:

```bash
sudo systemctl stop postgresql@18-main
sudo -u postgres pgbackrest \
  --stanza=main \
  --type=time \
  --target="2026-05-09 13:20:00+05:30" \
  restore
sudo systemctl start postgresql@18-main
```

Use this when:

- A table was deleted
- Bad migration ran
- Wrong script updated data
- Application bug wrote corrupt rows

### 12.3 PostgreSQL: Restore To Another Host For Validation

Use this when you want to verify a recovery point without touching production first.

Typical command flow:

```bash
sudo systemctl stop postgresql@18-main
sudo -u postgres pgbackrest \
  --stanza=main \
  --type=time \
  --target="2026-05-09 13:20:00+05:30" \
  restore
sudo systemctl start postgresql@18-main
```

Then validate:

```bash
sudo -u postgres psql -Atc "select current_timestamp;"
sudo -u postgres psql -d prod-dhanman-common -c "select count(*) from information_schema.tables;"
```

Preferred restore target:

- QA when testing a recovery point
- Existing PROD warm host when primary host is lost

### 12.4 Full New PROD / PROD-N Loss

Use this when `57.129.74.139` is gone or cannot be trusted.

Sequence:

1. Provision clean host or use warm PROD as temporary restore target.
2. Install PostgreSQL, Vault, MinIO, NGINX, systemd units, and backup tools.
3. Restore service configs first.
4. Restore Vault.
5. Restore PostgreSQL.
6. Restore MinIO/files.
7. Start services in dependency order.
8. Smoke test before traffic cutover.

Core command families:

```bash
sudo -u postgres pgbackrest --stanza=main --delta restore
sudo systemctl start postgresql@18-main
restic snapshots
restic restore <snapshot_id> --target /
vault operator raft snapshot restore /path/to/snapshot.snap
```

### 12.5 Warm PROD Failover

Use this when new PROD is down but `51.79.156.217` is healthy enough to serve as the emergency restore target.

Sequence:

1. Stop applications that could still write to the old primary.
2. Restore PostgreSQL onto warm PROD.
3. Restore required configs and files.
4. Start dependency services.
5. Point application traffic to warm PROD only after validation.

Decision rule:

- Use warm PROD for fast recovery when the primary host is unavailable.
- Use a brand-new host when compromise or ransomware makes the warm host suspicious too.

### 12.6 Vault Recovery

Use the latest clean encrypted raft snapshot.

Typical command flow:

```bash
vault status
vault operator raft snapshot restore /path/to/vault.snap
vault status
```

After Vault restore:

- Verify auth methods
- Verify policies
- Verify application secrets can be read
- Rotate credentials if the incident involved compromise

### 12.7 MinIO / File Recovery

Use restic or object mirror artifacts, depending on what is configured at the time.

Typical command flow:

```bash
restic snapshots
restic restore <snapshot_id> --target /restore
```

If restoring MinIO data in place:

```bash
sudo systemctl stop minio
sudo rsync -a /restore/path/ /opt/minio-data-prod/
sudo systemctl start minio
```

Validate with representative objects, not only directory counts.

### 12.8 Service Config Recovery

Use this when PostgreSQL is healthy but service config files, units, NGINX, or scripts were lost or damaged.

Typical command flow:

```bash
restic snapshots
restic restore <snapshot_id> --target /restore
sudo rsync -a /restore/etc/nginx/ /etc/nginx/
sudo rsync -a /restore/etc/systemd/system/ /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart nginx
```

### 12.9 Ransomware Or Host Compromise

Sequence:

1. Isolate affected hosts.
2. Do not run prune, sync, or replication jobs from affected hosts.
3. Pick the last known-clean backup point.
4. Restore only into clean infrastructure.
5. Restore Vault, then rotate secrets and credentials.
6. Restore PostgreSQL, files, and configs.
7. Bring services online gradually.

Non-negotiable rule:

- In a compromise event, prefer B2 immutable backups over local copies unless local copies are independently verified clean.

### 12.10 Post-Recovery Validation

After any recovery:

1. Verify PostgreSQL is accepting connections.
2. Verify Vault is unsealed and serving expected secrets.
3. Verify MinIO objects are readable.
4. Verify NGINX and application health checks.
5. Verify one business-critical workflow end to end.
6. Record the restored source, target time, operator, and outcome under `snapshots/restore-reports/`.

## 13. Backup Schedule

| Time | Component | Tool | Frequency |
|---|---|---|---|
| Continuous | PostgreSQL WAL | pgBackRest archive-push | Always |
| 01:30 | PostgreSQL incremental to `repo1` | pgBackRest | Daily Monday-Saturday |
| 02:00 Sunday | PostgreSQL full to `repo1` | pgBackRest | Weekly |
| 03:00 | PostgreSQL incremental to `repo2` | pgBackRest | Daily Monday-Saturday |
| 03:30 Sunday | PostgreSQL full to `repo2` | pgBackRest | Weekly |
| 04:30 | PostgreSQL incremental to `repo3` | pgBackRest | Daily Monday-Saturday |
| 05:00 Sunday | PostgreSQL full to `repo3` | pgBackRest | Weekly |
| 06:15 | Vault backup | archive `/opt/vault/data` + B2 upload | Daily |
| 06:45 | MinIO/files | local copy of `/opt/minio/data` + B2 upload | Daily |
| 07:15 | Configs | tar archive + B2 upload | Daily |
| 05:30 | Verification | pgBackRest/restic/B2 checks | Daily |
| Monthly | Restore drill | Manual or scripted | Monthly |
| Quarterly | Full DR simulation | Manual | Quarterly |

Stagger jobs to avoid disk and network contention. Database WAL archiving must not depend on the nightly backup window.

## 14. Rollout Plan

### Phase 1: Stabilize Current Risk

- Fix PostgreSQL backup connectivity with `hostssl` and `scram-sha-256`.
- Stop using destructive `rsync --delete` for unverified backup replication.
- Add manifests/checksums to current scripts.
- Confirm B2 access and create Object Lock enabled buckets.

### Phase 2: PostgreSQL DR Upgrade

- Install and configure `pgBackRest`.
- Configure local, warm, and B2 repositories.
- Enable WAL archiving.
- Run first full backup.
- Run first PITR restore test into QA or isolated restore host.

### Phase 3: Files, Vault, and Configs

- Replace raw file rsync with `restic` or `mc mirror`.
- Encrypt Vault snapshots before replication.
- Add restic config backup for `/etc` and `/opt/scripts`.
- Store audit snapshots under `snapshots/audits/`.

### Phase 4: Operate and Prove

- Daily verification job.
- Monthly database restore drill.
- Quarterly full DR exercise.
- Track all restore results in `snapshots/restore-reports/`.

## 15. Implementation Tracking

| Task | Status | Notes |
|---|---|---|
| Define improved DR strategy | Done | This document |
| Confirm SSH access to new PROD, existing PROD, and QA | Done | Verified hosts: `dm-prd-n`, `dhanman-prod`, `dhanman-qa` |
| Confirm first PROD backup source is new PROD-N | Done | First production backup must run on `dhanman-prod-n` / `57.129.74.139` |
| Run new PROD preflight | Done | PostgreSQL client 18.3 present, `/opt` has about `179G` free, sudo works |
| Install backup tooling on new PROD, existing PROD, and QA | Done | `pgBackRest 2.58.0`, `restic 0.17.3`, and `rclone 1.60.1` verified |
| Create `/opt/backups` layout on new PROD, existing PROD, and QA | Done | Standard directories created for pgBackRest, restic, Vault, MinIO, configs, logs, manifests, and tmp |
| Create B2 Object Lock buckets | Done | PostgreSQL, Vault, files, and configs buckets created with encryption and Object Lock |
| Configure pgBackRest | Done | Local repo configured at `/opt/backups/pgbackrest`; stanza `main` created on new PROD |
| Enable PostgreSQL WAL archiving | Done | Restart completed; archive mode and pgBackRest `archive-push` verified |
| Run first pgBackRest check | Done | WAL archive verified successfully on repo1 |
| Run first full pgBackRest backup | Done | Backup label `20260509-130826F` created successfully |
| Configure warm PROD pgBackRest repo2 | Done | Dedicated remote config, SSH trust, stanza, and repo2 path `/opt/backups/pgbackrest-repo2` verified |
| Run first full pgBackRest backup on repo2 | Done | Backup label `20260509-141935F` created successfully on warm PROD |
| Replace old PostgreSQL cron jobs with pgBackRest schedule | Done | Daily incremental, weekly full, repo2 replication, and daily check installed under `postgres` |
| Configure PostgreSQL repo3 on Backblaze | Done | `repo3` configured to `dhanman-prod-postgres-immutable` via Backblaze S3 endpoint |
| Run first full pgBackRest backup on repo3 | Done | Backup label `20260509-160202F` created successfully in Backblaze |
| Extend PostgreSQL cron jobs to repo3 | Done | Daily incremental and weekly full added for the Backblaze repository |
| Configure Vault B2 backup | Done | Live script validated and uploaded `vault-20260509-162335.tar.gz` to the Vault bucket |
| Configure files B2 backup | Done | Live script validated and uploaded MinIO data to the files bucket |
| Configure configs B2 backup | Done | Live script validated and uploaded `configs-20260509-162335.tar.gz` to the configs bucket |
| Install root cron for Vault/files/config backups | Done | Daily root cron installed and verified |
| Add backup manifests/checksums | Pending | Required for verification |
| Update prune logic | Pending | Must protect latest verified backups |
| Add daily verification job | Pending | Required for 3-2-1-1-0 |
| Run first PITR restore drill | Pending | Required before claiming RTO/RPO |
| Run first full DR drill | Pending | Required before production confidence |

## 16. Non-Negotiable Rules

- A backup is not valid until a restore has been tested.
- Offsite backups must be immutable.
- Vault backups must be encrypted before replication.
- PostgreSQL DR must use WAL/PITR, not only daily dumps.
- Warm backup replication must not delete good backups because the source is broken.
- Pruning must be separate from backup creation.
- Credentials for backup upload must not also have broad delete/admin permissions.
