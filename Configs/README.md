# Configs

This directory contains reusable configuration templates extracted from production servers.

## Purpose
- Store configuration files from /etc/ and other system locations
- Provide templates for new server provisioning
- Track configuration changes over time in Git

## Subdirectories
Organize configs by service/component:
- `nginx/` - Nginx web server configurations
- `systemd/` - Systemd service unit files
- `postgres/` - PostgreSQL database configurations
- `promtail/` - Promtail log shipping configurations
- `grafana/` - Grafana monitoring configurations

## Best Practices
- Remove sensitive data (passwords, tokens, keys) before committing
- Use placeholders like `{{ variable_name }}` for values that change per environment
- Document any special setup requirements in this README
