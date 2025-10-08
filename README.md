# Dhanman Infra

This repository contains infrastructure definitions, configs, and automation 
for the Dhanman application servers (Prod, QA, Secondary).

## Structure

- **ansible/** → Playbooks and roles to bootstrap servers automatically
- **ci-templates/** → CI/CD pipeline templates (Jenkins, GitHub Actions, Dockerfile)
- **configs/** → Reusable config templates (nginx, systemd, postgres, promtail, grafana)
- **docker-compose/** → Container orchestration for all Dhanman services
- **scripts/** → Helper scripts for backups, deployment, monitoring
- **snapshots/** → Current server state captures (packages, services, configs)

## Services

This infrastructure manages six Dhanman microservices:

1. **dhanman-common** (Port 5200) - Common/Shared APIs
2. **dhanman-sales** (Port 5201) - Sales Management
3. **dhanman-purchase** (Port 5202) - Purchase Management
4. **dhanman-payroll** (Port 5203) - Payroll Management
5. **dhanman-inventory** (Port 5204) - Inventory Management
6. **dhanman-community** (Port 5205) - Community/MyHome

All services are containerized and available from GitHub Container Registry at `ghcr.io/b2atech`.

## Quick Start

### 1. Set Up Service Repositories with CI/CD

Each service repository needs a build pipeline to create and push Docker images.

**Option A: Jenkins Pipeline**

Copy the Jenkinsfile template to each service repo:
```bash
cp ci-templates/jenkins/Jenkinsfile /path/to/dhanman-SERVICE/
# Update SERVICE_NAME and PROJECT_PATH in the file
```

**Option B: GitHub Actions**

Copy the workflow to each service repo:
```bash
mkdir -p /path/to/dhanman-SERVICE/.github/workflows
cp ci-templates/github-actions/docker-build-push.yml /path/to/dhanman-SERVICE/.github/workflows/
```

Add a Dockerfile to each service:
```bash
cp ci-templates/Dockerfile.example /path/to/dhanman-SERVICE/Dockerfile
# Update SERVICE_NAME placeholders
```

See [CI Templates README](ci-templates/README.md) for detailed setup instructions.

### 2. Deploy Services with Docker Compose

**Prerequisites:**
- Docker Engine 20.10+ and Docker Compose v2+
- Access to GitHub Container Registry

**Login to registry:**
```bash
./scripts/deployment/ghcr-login.sh <github_username> <github_token>
```

**Configure environment:**
```bash
cd docker-compose/env
cp *.env.example *.env
# Edit each .env file with actual database credentials
```

**Deploy all services:**
```bash
./scripts/deployment/deploy-services.sh
```

**Or deploy with docker-compose directly:**
```bash
cd docker-compose
docker compose -f dhanman-services.yml up -d
```

See [Docker Compose README](docker-compose/README.md) for detailed deployment instructions.

### 3. Deploy with Ansible

For automated server provisioning and deployment:

```bash
cd ansible
ansible-playbook -i inventories/qa qa.yml
```

The Ansible roles support:
- Server setup and configuration
- Docker installation and configuration
- Service deployment from GHCR
- Nginx reverse proxy configuration
- Monitoring setup (Prometheus, Grafana, Loki)

## Goals

- ✅ Enable quick server recreation (DR / failover)
- ✅ Keep infra changes tracked in Git
- ✅ Support multi-environment setup (Prod, QA, Secondary)
- ✅ Simplify backup, monitoring, and DevOps workflows
- ✅ Container-based deployments with image registry
- ✅ Automated CI/CD pipelines for all services

## Common Tasks

### Update a Service

Update a single service to the latest image:
```bash
./scripts/deployment/update-service.sh dhanman-sales
```

### Pull Latest Images

Pull all service images without deploying:
```bash
./scripts/deployment/pull-images.sh
```

### View Service Logs

```bash
cd docker-compose
docker compose -f dhanman-services.yml logs -f dhanman-sales
```

### Check Service Health

```bash
cd docker-compose
docker compose -f dhanman-services.yml ps
```

### Deploy to QA Environment

```bash
cd ansible
ansible-playbook -i inventories/qa qa.yml --tags deploy
```

## CI/CD Pipeline

Each service repository should have:

1. **Dockerfile** - Multi-stage build for .NET 8 application
2. **Jenkins Pipeline** OR **GitHub Actions Workflow** - Automated build and push
3. **Image Tags** - Semantic versioning and branch-based tags

Images are automatically built and pushed to `ghcr.io/b2atech/{service-name}` on:
- Push to main/develop branches
- Git tags (v1.2.3)
- Pull requests (testing only)

## Registry Authentication

**For CI/CD (Jenkins):**
- Create GitHub Personal Access Token with `write:packages` scope
- Add credential in Jenkins: ID `github-container-registry`

**For CI/CD (GitHub Actions):**
- No setup needed - uses built-in `GITHUB_TOKEN`

**For Local/Server Use:**
```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
```

## Monitoring

The infrastructure includes monitoring stack:
- **Prometheus** - Metrics collection
- **Grafana** - Visualization and dashboards  
- **Loki** - Log aggregation
- **Promtail** - Log shipping

## Backup & Recovery

Disaster recovery audit script:
```bash
./scripts/backup/dr-audit-extended.sh
```

This captures:
- Installed packages
- Running services
- Nginx configurations
- PostgreSQL databases
- Docker containers and images

## Documentation

- [CI/CD Templates Guide](ci-templates/README.md) - Pipeline setup for service repos
- [Docker Compose Guide](docker-compose/README.md) - Container deployment
- [Ansible Documentation](ansible/README.md) - Server provisioning

## Troubleshooting

**Cannot pull images:**
- Ensure you're logged in: `docker login ghcr.io`
- Verify token has `read:packages` permission
- Check images exist: https://github.com/orgs/b2atech/packages

**Service won't start:**
- Check logs: `docker compose logs -f SERVICE_NAME`
- Verify environment variables in `.env` files
- Ensure database is accessible

**Build pipeline fails:**
- Review CI/CD logs in Jenkins or GitHub Actions
- Verify Dockerfile paths match project structure
- Ensure tests pass locally

## Next Steps

- [ ] Set up automated backups for PostgreSQL
- [ ] Add Kubernetes manifests as alternative to Docker Compose
- [ ] Implement blue-green deployment strategy
- [ ] Add service mesh (Istio/Linkerd) for prod environment
- [ ] Set up centralized secrets management (Vault/Azure Key Vault)
