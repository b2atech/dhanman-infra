# PostgreSQL Backup Notes

Recommended defaults:

- Use `pg_dump` for logical backups per database.
- Use custom format for flexible restore workflows.
- Store roles and globals separately if cluster-wide objects matter.
- Compress before upload if remote storage policy allows it.
