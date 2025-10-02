# Snapshots

This directory contains snapshots of the current server state for reference and audit purposes.

## Purpose
- Store server state captures (packages, services, configurations)
- Maintain historical records for audit trails
- Enable quick reference when troubleshooting or recreating servers

## What to Store Here
- Package lists (dpkg, apt, yum outputs)
- Service status outputs
- Configuration file snapshots
- System information dumps
- Any other server state documentation

## Naming Convention
Use descriptive names with timestamps:
- `packages_YYYY-MM-DD.txt`
- `services_YYYY-MM-DD.txt`
- `server_info_YYYY-MM-DD.txt`
