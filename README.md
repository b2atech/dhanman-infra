# Dhanman Infra

This repository contains infrastructure definitions, configs, and automation 
for the Dhanman application servers (Prod, QA, Secondary).

## Structure
- **Snapshots/** → current server state captures (packages, services, configs) for reference & audit.
- **Configs/** → reusable config templates (nginx, systemd, postgres, promtail, grafana).
- **Ansible/** → playbooks and roles to bootstrap servers automatically - the automation to turn a clean VPS → production-ready.
- **Scripts/** → helper scripts for backups, deployment, monitoring, restarts, and migrations.

## Goals
- Enable quick server recreation (DR / failover).
- Keep infra changes tracked in Git.
- Support multi-environment setup (Prod, QA, Secondary).
- Simplify backup, monitoring, and DevOps workflows.

## Usage
1. Store snapshots from live servers in `Snapshots/`.
2. Extract configs into `Configs/` for reuse (gradually move configs from /etc/..., systemd, nginx, promtail, postgres).
3. Use Ansible playbooks in `Ansible/` to provision new servers.
4. Run helper scripts in `Scripts/` for backup/restore and deployments.

## Next Steps
- Add PostgreSQL backup + restore automation.
- Add Loki + Grafana docker-compose setup for secondary server.
- Add Jenkins + QA deployment instructions.