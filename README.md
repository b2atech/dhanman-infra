# Dhanman Infra

This repository contains infrastructure definitions, configs, and automation 
for the Dhanman application servers (Prod, QA, Secondary).

## Structure
- **snapshots/** → current server state captures (packages, services, configs).
- **configs/** → reusable config templates (nginx, systemd, postgres, promtail, grafana).
- **ansible/** → playbooks and roles to bootstrap servers automatically.
- **scripts/** → helper scripts for backups, deployment, monitoring.

## Goals
- Enable quick server recreation (DR / failover).
- Keep infra changes tracked in Git.
- Support multi-environment setup (Prod, QA, Secondary).
- Simplify backup, monitoring, and DevOps workflows.

## Usage
1. Store snapshots from live servers in `snapshots/`.
2. Extract configs into `configs/` for reuse.
3. Use Ansible playbooks in `ansible/` to provision new servers.
4. Run helper scripts in `scripts/` for backup/restore and deployments.

## Next Steps
- Add PostgreSQL backup + restore automation.
- Add Loki + Grafana docker-compose setup for secondary server.
- Add Jenkins + QA deployment instructions.
