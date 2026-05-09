# Retention Policy

## Baseline

- Daily backups: 7 to 14 days
- Weekly backups: 4 to 8 weeks
- Monthly backups: 6 to 12 months
- DR audit snapshots: keep at least the latest successful copy per environment

## Rules

- Retention must be enforced on remote storage and local staging paths.
- Pruning must never delete the latest verified restore point.
- Production and QA retention can differ, but the policy should be documented
  here before changing automation.
