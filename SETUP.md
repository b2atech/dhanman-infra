# Docker Registry Setup & Deployment Guide

This guide walks through setting up Docker image management and CI/CD for all six Dhanman services.

## Overview

The Dhanman infrastructure uses:
- **GitHub Container Registry (GHCR)** - `ghcr.io/b2atech` for storing Docker images
- **Jenkins or GitHub Actions** - For automated builds and deployments
- **Docker Compose** - For orchestrating multi-container deployments
- **Ansible** - For server provisioning and automated deployments

## Part 1: Set Up CI/CD in Service Repositories

Each of the six service repositories needs CI/CD configuration to build and push Docker images.

### Services to Configure

1. `dhanman-common` - Common/Shared service
2. `dhanman-sales` - Sales management
3. `dhanman-purchase` - Purchase management
4. `dhanman-payroll` - Payroll management
5. `dhanman-inventory` - Inventory management
6. `dhanman-community` - Community/MyHome service

### Step 1.1: Add Dockerfile to Each Service Repo

```bash
# Navigate to service repository
cd /path/to/dhanman-SERVICE

# Copy Dockerfile template
cp /path/to/dhanman-infra/ci-templates/Dockerfile.example ./Dockerfile

# Edit Dockerfile and replace SERVICE_NAME
# For dhanman-common:
sed -i 's/SERVICE_NAME/Common/g' Dockerfile

# For dhanman-sales:
sed -i 's/SERVICE_NAME/Sales/g' Dockerfile

# For dhanman-purchase:
sed -i 's/SERVICE_NAME/Purchase/g' Dockerfile

# For dhanman-payroll:
sed -i 's/SERVICE_NAME/Payroll/g' Dockerfile

# For dhanman-inventory:
sed -i 's/SERVICE_NAME/Inventory/g' Dockerfile

# For dhanman-community (note: uses MyHome):
sed -i 's/SERVICE_NAME/MyHome/g' Dockerfile
```

**Verify Dockerfile paths match your project structure.**

### Step 1.2: Choose CI/CD Platform

#### Option A: Jenkins

**Prerequisites:**
- Jenkins server with Docker installed
- GitHub Personal Access Token with `write:packages` scope

**Steps:**

1. Copy Jenkinsfile to service repo:
```bash
cp /path/to/dhanman-infra/ci-templates/jenkins/Jenkinsfile /path/to/dhanman-SERVICE/
```

2. Update Jenkinsfile:
```groovy
// For dhanman-common:
IMAGE_NAME = 'dhanman-common'
PROJECT_PATH = 'src/Dhanman.Common.Api'

// For dhanman-sales:
IMAGE_NAME = 'dhanman-sales'
PROJECT_PATH = 'src/Dhanman.Sales.Api'

// And so on for other services...
```

3. Configure Jenkins:
   - Create new Pipeline job for each service
   - Point to service repository
   - Add credential `github-container-registry`:
     - Kind: Username with password
     - Username: Your GitHub username
     - Password: GitHub Personal Access Token

4. Create GitHub Personal Access Token:
   - Go to GitHub → Settings → Developer settings → Personal access tokens
   - Generate token with scopes: `write:packages`, `read:packages`, `delete:packages`
   - Save token securely

#### Option B: GitHub Actions (Recommended)

**Prerequisites:**
- Service repositories hosted on GitHub

**Steps:**

1. Copy workflow to service repo:
```bash
mkdir -p /path/to/dhanman-SERVICE/.github/workflows
cp /path/to/dhanman-infra/ci-templates/github-actions/docker-build-push.yml \
   /path/to/dhanman-SERVICE/.github/workflows/
```

2. No additional configuration needed! GitHub Actions uses built-in `GITHUB_TOKEN`

3. Push changes and workflow runs automatically

### Step 1.3: Test the Pipeline

1. Make a small change in the service repo
2. Commit and push to `develop` or `main` branch
3. Monitor build in Jenkins or GitHub Actions
4. Verify image appears in GitHub Packages: `https://github.com/orgs/b2atech/packages`

## Part 2: Deploy Services with Docker Compose

### Step 2.1: Authenticate with GHCR

On the server where you'll run services:

```bash
# Clone dhanman-infra repo
git clone https://github.com/b2atech/dhanman-infra.git
cd dhanman-infra

# Login to GitHub Container Registry
./scripts/deployment/ghcr-login.sh YOUR_GITHUB_USERNAME YOUR_GITHUB_TOKEN
```

### Step 2.2: Configure Environment Variables

```bash
cd docker-compose/env

# Copy environment templates
cp common.env.example common.env
cp sales.env.example sales.env
cp purchase.env.example purchase.env
cp payroll.env.example payroll.env
cp inventory.env.example inventory.env
cp community.env.example community.env

# Edit each file with actual values
nano common.env  # Update database credentials, etc.
nano sales.env
nano purchase.env
nano payroll.env
nano inventory.env
nano community.env
```

**Important:** Update these values in each `.env` file:
- Database connection strings (server, credentials)
- `DOTNET_ENVIRONMENT` (production, qa, etc.)
- Any service-specific configuration

### Step 2.3: Create Log Directories

```bash
# For QA environment
sudo mkdir -p /var/www/qa/logs/{common,sales,purchase,payroll,inventory,community}
sudo chown -R $USER:$USER /var/www/qa/logs

# For Production environment
sudo mkdir -p /var/www/prod/logs/{common,sales,purchase,payroll,inventory,community}
sudo chown -R $USER:$USER /var/www/prod/logs
```

### Step 2.4: Deploy Services

**For QA Environment:**
```bash
cd docker-compose
docker compose -f dhanman-services.yml pull
docker compose -f dhanman-services.yml up -d
```

**Or use deployment script:**
```bash
./scripts/deployment/deploy-services.sh qa
```

**For Production Environment:**
```bash
cd docker-compose/prod
# First, copy and configure env files
cp -r ../env ./env
# Edit env files with production values

docker compose -f dhanman-services-prod.yml pull
docker compose -f dhanman-services-prod.yml up -d
```

### Step 2.5: Verify Deployment

```bash
# Check service status
docker compose -f dhanman-services.yml ps

# Check logs
docker compose -f dhanman-services.yml logs -f

# Check individual service
docker compose -f dhanman-services.yml logs -f dhanman-common

# Test health endpoints
curl http://localhost:5200/health  # common
curl http://localhost:5201/health  # sales
curl http://localhost:5202/health  # purchase
curl http://localhost:5203/health  # payroll
curl http://localhost:5204/health  # inventory
curl http://localhost:5205/health  # community
```

## Part 3: Deploy with Ansible (Advanced)

For automated server provisioning and deployment:

### Step 3.1: Configure Inventory

Edit inventory file:
```bash
cd ansible/inventories/qa
nano hosts.yml
```

Add your server:
```yaml
all:
  children:
    dhanman-qa:
      hosts:
        qa-server:
          ansible_host: your.server.ip
          ansible_user: ubuntu
```

### Step 3.2: Set Registry Credentials

Create Ansible vault for secrets:
```bash
cd ansible
ansible-vault create group_vars/all/vault.yml
```

Add credentials:
```yaml
ghcr_username: your_github_username
ghcr_token: your_github_token
```

### Step 3.3: Run Ansible Playbook

```bash
cd ansible

# Deploy all services
ansible-playbook -i inventories/qa qa.yml --ask-vault-pass

# Deploy specific service
ansible-playbook -i inventories/qa qa-services.yml \
  -e service_name=dhanman-sales \
  -e docker_image=ghcr.io/b2atech/dhanman-sales:latest \
  -e service_port=5201 \
  --ask-vault-pass
```

## Part 4: Ongoing Operations

### Update a Single Service

When a new version of a service is built:

```bash
# Using helper script
./scripts/deployment/update-service.sh dhanman-sales

# Or manually
cd docker-compose
docker compose -f dhanman-services.yml pull dhanman-sales
docker compose -f dhanman-services.yml up -d dhanman-sales
```

### Update All Services

```bash
./scripts/deployment/deploy-services.sh
```

### Rollback a Service

```bash
cd docker-compose

# Stop current version
docker compose -f dhanman-services.yml stop dhanman-sales

# Edit docker-compose file to use previous tag
nano dhanman-services.yml
# Change: ghcr.io/b2atech/dhanman-sales:latest
# To:     ghcr.io/b2atech/dhanman-sales:v1.0.0

# Pull and restart
docker compose -f dhanman-services.yml pull dhanman-sales
docker compose -f dhanman-services.yml up -d dhanman-sales
```

### View Service Logs

```bash
# All services
docker compose -f dhanman-services.yml logs -f

# Specific service
docker compose -f dhanman-services.yml logs -f dhanman-sales

# Last 100 lines
docker compose -f dhanman-services.yml logs --tail=100 dhanman-sales
```

### Monitor Resource Usage

```bash
# All containers
docker stats

# Specific container
docker stats dhanman-sales
```

## Part 5: Production Considerations

### Image Tagging Strategy

**Development/QA:**
- Use `develop` or `latest` tags for auto-updates
- Images rebuild on every push to develop branch

**Production:**
- Use semantic version tags: `v1.0.0`, `v1.1.0`, etc.
- Pin specific versions in production compose file
- Test in QA before promoting to production

### Security Best Practices

1. **Never commit .env files** - Use `.gitignore`
2. **Use secrets management** - Consider HashiCorp Vault or Azure Key Vault
3. **Rotate credentials regularly** - GitHub tokens, database passwords
4. **Scan images for vulnerabilities** - Use GitHub Security features
5. **Run containers as non-root** - Already configured in Dockerfile

### Monitoring & Alerting

Set up monitoring for:
- Container health status
- Resource usage (CPU, memory)
- Application logs
- Response times and error rates

Use existing monitoring stack:
- Prometheus - Metrics
- Grafana - Dashboards
- Loki - Logs
- Promtail - Log shipping

### Backup Strategy

1. **Database backups** - Automated PostgreSQL dumps
2. **Container configs** - All in Git (this repo)
3. **Application data** - Volume backups if applicable
4. **Disaster recovery snapshots** - Use existing DR script

### High Availability

For production HA:
1. Run multiple instances of each service
2. Use load balancer (Nginx, HAProxy)
3. Configure health checks
4. Implement graceful shutdown
5. Consider Kubernetes for advanced orchestration

## Troubleshooting

### Cannot Pull Images

**Error:** `unauthorized: authentication required`

**Solution:**
```bash
# Re-login to registry
./scripts/deployment/ghcr-login.sh YOUR_USERNAME YOUR_TOKEN

# Verify credentials
docker info | grep Username
```

### Service Won't Start

**Check logs:**
```bash
docker compose logs dhanman-SERVICE
```

**Common issues:**
- Database connection failed - Check connection strings in `.env`
- Port already in use - Check for conflicts
- Environment variable missing - Verify `.env` file

### Build Pipeline Fails

**Jenkins:**
- Check Jenkins console output
- Verify Docker is installed on Jenkins agent
- Check credential configuration

**GitHub Actions:**
- Check Actions tab in repository
- Review workflow logs
- Verify GITHUB_TOKEN permissions

### Image Not Found

**Verify image exists:**
```bash
docker search ghcr.io/b2atech/dhanman-SERVICE
```

**Check GitHub Packages:**
- Visit: `https://github.com/orgs/b2atech/packages`
- Verify package visibility (public/private)
- Check if image tag exists

## Support

For issues or questions:
1. Check this documentation
2. Review relevant README files in subdirectories
3. Check service-specific documentation
4. Contact DevOps team

## Next Steps

After completing setup:
- [ ] Configure automated backups
- [ ] Set up monitoring alerts
- [ ] Document service-specific configurations
- [ ] Create runbooks for common operations
- [ ] Schedule regular security updates
- [ ] Plan disaster recovery drills
