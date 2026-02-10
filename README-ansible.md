# Dhanman Ansible Infrastructure

Complete Ansible-based infrastructure automation for deploying and managing Dhanman production environment on Ubuntu 24.04 LTS.

## Overview

This Ansible infrastructure provides automated provisioning, configuration, and deployment of the complete Dhanman production stack including:

- **Base System Setup**: Common packages, firewall (UFW), directory structure
- **.NET Runtime**: ASP.NET Core 9.0 runtime installation
- **Docker**: Docker engine and Docker Compose plugin
- **Application Services**: Systemd service files for all Dhanman modules
- **Nginx**: Reverse proxy configuration for APIs and UIs
- **Environment Templates**: Service-specific `.env` file templates
- **Infrastructure Services**: Docker Compose configurations for supporting services

## Architecture

### Services

The infrastructure manages 8 Dhanman API services:

| Service | Port | Description |
|---------|------|-------------|
| common | 5200 | Common/Shared service |
| sales | 5201 | Sales management |
| purchase | 5202 | Purchase management |
| payroll | 5203 | Payroll management |
| inventory | 5204 | Inventory management |
| community | 5205 | Community/MyHome service |
| document | 5206 | Document management |
| payment | 5207 | Payment processing |

### Directory Structure

```
dhanman-infra/
├── inventory/
│   └── prod.ini                    # Production inventory
├── group_vars/
│   └── prod.yml                    # Production variables
├── playbooks/
│   ├── base.yml                    # Base system setup
│   ├── apps.yml                    # Application setup
│   ├── nginx.yml                   # Nginx configuration
│   └── docker.yml                  # Docker compose files
├── roles/
│   ├── common/                     # System packages, UFW, directories
│   ├── dotnet/                     # .NET 9.0 runtime
│   ├── docker/                     # Docker installation
│   ├── systemd-services/           # Systemd service files
│   ├── nginx/                      # Nginx reverse proxy
│   └── env-templates/              # Environment file templates
├── docker/
│   ├── docker-compose.infra.yml   # Infrastructure services
│   └── docker-compose.loki.yml    # Logging stack
└── README.md                       # This file
```

## Prerequisites

### Control Machine (where you run Ansible)

- Ansible 2.9 or higher
- Python 3.8+
- SSH access to target servers

```bash
# Install Ansible on Ubuntu/Debian
sudo apt update
sudo apt install ansible

# Install Ansible on macOS
brew install ansible
```

### Target Server

- Ubuntu 24.04 LTS
- SSH access with sudo privileges
- User account for deployment (default: `deploy`)

## Quick Start

### 1. Configure Inventory

Edit `inventory/prod.ini` and update:

```ini
[prod]
prod-server ansible_host=YOUR_SERVER_IP ansible_user=deploy
```

### 2. Configure Variables

Edit `group_vars/prod.yml` to customize:

- Deployment user/group
- Service ports
- Domain names
- Database connection strings
- TLS certificate paths

### 3. Run Playbooks

**Base System Setup** (common packages, dotnet, docker):

```bash
ansible-playbook -i inventory/prod.ini playbooks/base.yml
```

**Application Setup** (env files, systemd services):

```bash
ansible-playbook -i inventory/prod.ini playbooks/apps.yml
```

**Nginx Setup** (reverse proxy):

```bash
ansible-playbook -i inventory/prod.ini playbooks/nginx.yml
```

**Docker Compose Files** (copy to /opt/dhanman):

```bash
ansible-playbook -i inventory/prod.ini playbooks/docker.yml
```

**All-in-One** (run all playbooks):

```bash
ansible-playbook -i inventory/prod.ini playbooks/base.yml playbooks/apps.yml playbooks/nginx.yml playbooks/docker.yml
```

## Service Control

By default, services are **NOT** auto-started or enabled. This allows manual verification and configuration before starting services.

### Starting Services

After deployment, you can manually start services:

```bash
# Start a specific service
sudo systemctl start dhanman-common
sudo systemctl enable dhanman-common

# Start all services
for service in common sales purchase payroll inventory community document payment; do
  sudo systemctl start dhanman-$service
  sudo systemctl enable dhanman-$service
done
```

### Starting Nginx

```bash
sudo systemctl start nginx
sudo systemctl enable nginx
```

### Starting Docker Infrastructure

```bash
cd /opt/dhanman
docker compose -f docker-compose.infra.yml up -d
docker compose -f docker-compose.loki.yml up -d
```

## Configuration

### Environment Files

Environment files are created at `/var/www/prod/dhanman-{service}/.env` with placeholder values. You must update them with actual configuration:

```bash
# Example: Edit common service environment
sudo nano /var/www/prod/dhanman-common/.env

# Update database connection strings:
# ConnectionStrings__CommonDb=Server=YOUR_DB_HOST;...
```

### TLS/SSL Certificates

The nginx configurations expect Let's Encrypt certificates. Generate them using certbot:

```bash
# Install certbot
sudo apt install certbot python3-certbot-nginx

# Generate certificates for each domain
sudo certbot --nginx -d common.dhanman.com
sudo certbot --nginx -d sales.dhanman.com
# ... repeat for all domains
```

### Firewall (UFW)

UFW is configured to allow:
- Port 22 (SSH)
- Port 80 (HTTP)
- Port 443 (HTTPS)

Additional ports can be configured in `group_vars/prod.yml`:

```yaml
ufw_allowed_ports:
  - 22
  - 80
  - 443
  - 3000  # Grafana (if needed)
```

## Deployment Workflow

1. **Initial Setup**: Run `base.yml` playbook to set up system
2. **Deploy Binaries**: Manually copy .NET binaries to `/var/www/prod/dhanman-binaries/`
3. **Configure Environment**: Edit `.env` files with actual database credentials and settings
4. **Deploy Apps**: Run `apps.yml` to create systemd services
5. **Configure Nginx**: Run `nginx.yml` to set up reverse proxy
6. **Generate Certificates**: Use certbot to generate SSL certificates
7. **Start Services**: Manually start and enable services
8. **Verify**: Test each service endpoint

## Advanced Usage

### Override Variables

You can override variables at runtime:

```bash
ansible-playbook -i inventory/prod.ini playbooks/base.yml \
  -e "nginx_enable=true nginx_state=started"
```

### Run Specific Roles

```bash
ansible-playbook -i inventory/prod.ini playbooks/base.yml --tags "common"
```

### Check Mode (Dry Run)

```bash
ansible-playbook -i inventory/prod.ini playbooks/base.yml --check
```

### Ansible Vault for Secrets

Store sensitive data in encrypted files:

```bash
# Create encrypted vars file
ansible-vault create group_vars/prod_secrets.yml

# Edit encrypted file
ansible-vault edit group_vars/prod_secrets.yml

# Run playbook with vault
ansible-playbook -i inventory/prod.ini playbooks/apps.yml --ask-vault-pass
```

## Troubleshooting

### Check Ansible Connectivity

```bash
ansible -i inventory/prod.ini prod -m ping
```

### View Service Status

```bash
sudo systemctl status dhanman-common
```

### View Service Logs

```bash
sudo journalctl -u dhanman-common -f
```

### Check Nginx Configuration

```bash
sudo nginx -t
```

### View Nginx Logs

```bash
sudo tail -f /var/log/nginx/common.dhanman.com.access.log
sudo tail -f /var/log/nginx/common.dhanman.com.error.log
```

## Security Notes

- **No Secrets**: This repository does NOT contain any secrets or sensitive data
- **Environment Files**: `.env` files contain placeholders - update with actual values
- **Database Credentials**: Must be configured manually in `.env` files
- **UFW Enabled**: Firewall is enabled by default
- **Services Stopped**: All services are stopped by default for security
- **TLS Required**: Nginx configurations expect HTTPS with valid certificates

## Maintenance

### Update .NET Runtime

Edit `roles/dotnet/tasks/main.yml` to change runtime version.

### Add New Service

1. Add service definition to `group_vars/prod.yml` in `dhanman_services` list
2. Create environment template in `roles/env-templates/templates/{service}.env.j2`
3. Re-run playbooks

### Update Nginx Configuration

Edit templates in `roles/nginx/templates/` and re-run `nginx.yml` playbook.

## Support

For issues or questions:
1. Check Ansible output for error messages
2. Verify variable configuration in `group_vars/prod.yml`
3. Check service logs with `journalctl`
4. Review Ansible documentation: https://docs.ansible.com/

## License

This infrastructure code is maintained by the B2ATech DevOps team for Dhanman production deployment.

---

**Last Updated**: 2026-02-10  
**Maintained By**: B2ATech DevOps Team
