# Dhanman Services Docker Compose

This directory contains Docker Compose configurations for deploying all Dhanman services using container images from GitHub Container Registry (ghcr.io).

## Services

The following six services are orchestrated:

1. **dhanman-common** (Port 5200) - Common/Shared service
2. **dhanman-sales** (Port 5201) - Sales management service
3. **dhanman-purchase** (Port 5202) - Purchase management service
4. **dhanman-payroll** (Port 5203) - Payroll management service
5. **dhanman-inventory** (Port 5204) - Inventory management service
6. **dhanman-community** (Port 5205) - Community/MyHome service

## Prerequisites

- Docker Engine 20.10+ and Docker Compose v2+
- Access to GitHub Container Registry (ghcr.io)
- PostgreSQL database server configured

## Setup

### 1. Authenticate with GitHub Container Registry

```bash
# Using a GitHub Personal Access Token with read:packages permission
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
```

### 2. Configure Environment Variables

Copy the example environment files and update with your actual values:

```bash
cd docker-compose/env
cp common.env.example common.env
cp sales.env.example sales.env
cp purchase.env.example purchase.env
cp payroll.env.example payroll.env
cp inventory.env.example inventory.env
cp community.env.example community.env
```

**Important:** Update database passwords and other sensitive values in each `.env` file.

### 3. Create Log Directories

```bash
sudo mkdir -p /var/www/logs/{common,sales,purchase,payroll,inventory,community}
sudo chown -R $USER:$USER /var/www/logs
```

## Deployment

### Start All Services

```bash
cd /path/to/dhanman-infra/docker-compose
docker compose -f dhanman-services.yml up -d
```

### Start Individual Service

```bash
docker compose -f dhanman-services.yml up -d dhanman-common
```

### View Logs

```bash
# All services
docker compose -f dhanman-services.yml logs -f

# Specific service
docker compose -f dhanman-services.yml logs -f dhanman-sales
```

### Stop Services

```bash
docker compose -f dhanman-services.yml down
```

### Update to Latest Images

```bash
docker compose -f dhanman-services.yml pull
docker compose -f dhanman-services.yml up -d
```

## Health Checks

All services include health checks that verify the `/health` endpoint. View health status:

```bash
docker ps
```

Look for "healthy" in the STATUS column.

## Network Configuration

All services are connected to a shared `dhanman-network` bridge network, allowing inter-service communication.

## Troubleshooting

### Check Service Status

```bash
docker compose -f dhanman-services.yml ps
```

### Inspect Service

```bash
docker inspect dhanman-common
```

### Access Container Shell

```bash
docker exec -it dhanman-common /bin/bash
```

### View Service Configuration

```bash
docker compose -f dhanman-services.yml config
```

## Production Considerations

- Use specific image tags instead of `latest` for reproducible deployments
- Set up log rotation for `/var/www/logs`
- Configure Nginx reverse proxy for SSL/TLS termination
- Use Docker secrets or external secret management for sensitive data
- Set up monitoring and alerting for container health
- Implement backup strategy for container data and logs

## Related Documentation

- [Ansible Deployment](../ansible/README.md)
- [Main Infrastructure README](../README.md)
