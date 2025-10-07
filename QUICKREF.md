# Quick Reference Guide - Docker Registry Integration

## 🎯 Overview

This infrastructure now supports automated Docker image building, storage in GitHub Container Registry (GHCR), and deployment for all six Dhanman services.

## 📦 Services

| Service | Port | Repository | Registry Image |
|---------|------|------------|----------------|
| dhanman-common | 5200 | b2atech/dhanman-common | ghcr.io/b2atech/dhanman-common |
| dhanman-sales | 5201 | b2atech/dhanman-sales | ghcr.io/b2atech/dhanman-sales |
| dhanman-purchase | 5202 | b2atech/dhanman-purchase | ghcr.io/b2atech/dhanman-purchase |
| dhanman-payroll | 5203 | b2atech/dhanman-payroll | ghcr.io/b2atech/dhanman-payroll |
| dhanman-inventory | 5204 | b2atech/dhanman-inventory | ghcr.io/b2atech/dhanman-inventory |
| dhanman-community | 5205 | b2atech/dhanman-community | ghcr.io/b2atech/dhanman-community |

## 🚀 Quick Start Commands

### For DevOps/Deployment

```bash
# Clone this repo
git clone https://github.com/b2atech/dhanman-infra.git
cd dhanman-infra

# Login to registry
./scripts/deployment/ghcr-login.sh YOUR_USERNAME YOUR_TOKEN

# Pull all images
./scripts/deployment/pull-images.sh

# Configure environment (copy and edit .env files)
cd docker-compose/env
cp *.env.example *.env
# Edit each .env file with real values

# Deploy all services
cd ../..
./scripts/deployment/deploy-services.sh

# Update specific service
./scripts/deployment/update-service.sh dhanman-sales
```

### For Developers (Service Repos)

```bash
# Add Dockerfile to your service repo
cp /path/to/dhanman-infra/ci-templates/Dockerfile.example ./Dockerfile
# Update SERVICE_NAME placeholders

# Option A: Add Jenkins pipeline
cp /path/to/dhanman-infra/ci-templates/jenkins/Jenkinsfile ./Jenkinsfile
# Update IMAGE_NAME and PROJECT_PATH

# Option B: Add GitHub Actions (recommended)
mkdir -p .github/workflows
cp /path/to/dhanman-infra/ci-templates/github-actions/docker-build-push.yml \
   .github/workflows/
# No changes needed! Works automatically

# Commit and push - image builds automatically
git add Dockerfile .github/
git commit -m "Add Docker image build pipeline"
git push
```

## 📁 File Structure

```
dhanman-infra/
├── SETUP.md                          # Complete setup guide
├── README.md                         # Main documentation
├── docker-compose/
│   ├── dhanman-services.yml         # Main compose file (latest tags)
│   ├── prod/
│   │   └── dhanman-services-prod.yml # Prod config (version tags)
│   └── qa/
│       └── dhanman-services-qa.yml   # QA config (develop tags)
├── ci-templates/
│   ├── Dockerfile.example           # Multi-stage .NET Dockerfile
│   ├── jenkins/Jenkinsfile          # Jenkins pipeline
│   └── github-actions/              # GitHub Actions workflow
└── scripts/deployment/
    ├── ghcr-login.sh               # Login to registry
    ├── pull-images.sh              # Pull all images
    ├── deploy-services.sh          # Deploy/update all
    └── update-service.sh           # Update single service
```

## 🔑 Authentication

**GitHub Personal Access Token Required:**
- Go to: Settings → Developer settings → Personal access tokens
- Scopes needed: `read:packages`, `write:packages` (for CI/CD), `delete:packages` (optional)
- Use with: `./scripts/deployment/ghcr-login.sh USERNAME TOKEN`

**Jenkins Setup:**
- Add credential ID: `github-container-registry`
- Type: Username with password
- Username: GitHub username
- Password: Personal Access Token

**GitHub Actions:**
- No setup needed - uses built-in `GITHUB_TOKEN`

## 🏷️ Image Tagging Strategy

| Environment | Tag | Updates |
|-------------|-----|---------|
| Development | `develop` | Auto on push to develop |
| QA | `develop` or `latest` | Auto on push |
| Production | `v1.0.0` (semver) | Manual release tags |

## 📋 Common Operations

### Check Service Status
```bash
cd docker-compose
docker compose -f dhanman-services.yml ps
```

### View Logs
```bash
# All services
docker compose -f dhanman-services.yml logs -f

# Specific service
docker compose -f dhanman-services.yml logs -f dhanman-sales
```

### Restart Service
```bash
docker compose -f dhanman-services.yml restart dhanman-sales
```

### Stop All Services
```bash
docker compose -f dhanman-services.yml down
```

### Pull Latest and Redeploy
```bash
./scripts/deployment/deploy-services.sh
```

## 🐛 Troubleshooting

| Problem | Solution |
|---------|----------|
| Can't pull images | Run `./scripts/deployment/ghcr-login.sh` first |
| Service won't start | Check logs: `docker compose logs SERVICE` |
| Port already in use | Check conflicts: `docker ps`, `netstat -tlnp` |
| Build fails | Verify paths in Dockerfile match project structure |

## 📚 Documentation

- **[SETUP.md](SETUP.md)** - Complete step-by-step setup guide
- **[docker-compose/README.md](docker-compose/README.md)** - Container orchestration details
- **[ci-templates/README.md](ci-templates/README.md)** - CI/CD pipeline setup
- **[scripts/deployment/README.md](scripts/deployment/README.md)** - Deployment scripts reference

## 🔄 Workflow

```
Developer pushes code
         ↓
Jenkins/GitHub Actions builds image
         ↓
Image pushed to ghcr.io/b2atech/SERVICE:TAG
         ↓
DevOps runs: ./scripts/deployment/update-service.sh SERVICE
         ↓
Service updated with new image
```

## 💡 Best Practices

1. ✅ Test in QA before production
2. ✅ Use version tags for production
3. ✅ Keep .env files outside Git
4. ✅ Monitor logs after deployment
5. ✅ Run health checks: `curl http://localhost:520X/health`
6. ✅ Backup before major updates

## 🎓 Learning Resources

- Docker Compose: https://docs.docker.com/compose/
- GitHub Container Registry: https://docs.github.com/packages
- .NET Docker: https://docs.microsoft.com/dotnet/core/docker/

## 🆘 Need Help?

1. Check documentation in this repo
2. Review GitHub Actions/Jenkins logs
3. Check Docker logs: `docker compose logs`
4. Contact DevOps team

---

**Last Updated:** Created with Docker registry integration
**Maintained By:** B2ATech DevOps Team
