# Deployment Scripts

Helper scripts for managing Docker deployments of Dhanman services.

## Available Scripts

### ghcr-login.sh

Login to GitHub Container Registry.

**Usage:**
```bash
./ghcr-login.sh <github_username> <github_token>
```

**Example:**
```bash
./ghcr-login.sh myuser ghp_xxxxxxxxxxxx
```

**Requirements:**
- Docker installed
- GitHub Personal Access Token with `read:packages` scope

---

### pull-images.sh

Pull latest Docker images for all Dhanman services.

**Usage:**
```bash
./pull-images.sh [environment]
```

**Examples:**
```bash
# Pull images for prod environment
./pull-images.sh prod

# Pull images for qa environment
./pull-images.sh qa
```

**What it does:**
- Pulls images for all six services
- Reports success/failure for each
- Provides troubleshooting tips if any fail

---

### deploy-services.sh

Deploy or update all Dhanman services using Docker Compose.

**Usage:**
```bash
./deploy-services.sh [environment] [service]
```

**Examples:**
```bash
# Deploy all services in prod environment
./deploy-services.sh prod all

# Deploy only sales service in qa environment
./deploy-services.sh qa dhanman-sales

# Deploy all services (defaults to prod and all)
./deploy-services.sh
```

**What it does:**
1. Verifies Docker Compose file exists
2. Checks environment files are configured
3. Pulls latest images
4. Starts/updates containers
5. Shows service status

---

### update-service.sh

Update a single service to the latest image with zero-downtime.

**Usage:**
```bash
./update-service.sh <service_name>
```

**Examples:**
```bash
# Update sales service
./update-service.sh dhanman-sales

# Update common service
./update-service.sh dhanman-common
```

**What it does:**
1. Pulls latest image
2. Stops current container
3. Removes old container
4. Starts new container with updated image
5. Waits for health check
6. Shows updated status

---

## Prerequisites

All scripts require:
- Docker Engine 20.10+
- Docker Compose v2+
- Bash shell
- Appropriate permissions to run Docker commands

For registry operations (pull/deploy):
- Logged in to ghcr.io (use `ghcr-login.sh`)
- Or working with public images

## Environment Variables

Scripts use these environment variables when available:

- `GITHUB_USERNAME` - Your GitHub username
- `GITHUB_TOKEN` - GitHub Personal Access Token
- `COMPOSE_FILE` - Custom compose file path (optional)

## Quick Start

**First time setup:**

```bash
# 1. Login to registry
./ghcr-login.sh myuser mytoken

# 2. Pull all images
./pull-images.sh

# 3. Configure environment files
cd ../docker-compose/env
cp *.env.example *.env
# Edit each .env file

# 4. Deploy all services
cd ../../scripts/deployment
./deploy-services.sh
```

**Regular updates:**

```bash
# Update all services
./deploy-services.sh

# Or update specific service
./update-service.sh dhanman-sales
```

## Script Locations

Scripts are designed to run from their directory:
```bash
cd /path/to/dhanman-infra/scripts/deployment
./deploy-services.sh
```

They automatically detect project paths and locate Docker Compose files.

## Exit Codes

All scripts follow standard exit code conventions:
- `0` - Success
- `1` - Error (invalid arguments, command failed, etc.)

## Logging

Scripts output to stdout/stderr:
- ✅ - Success messages
- ❌ - Error messages
- ⚠️  - Warning messages
- 🐳 🔐 🚀 📦 etc. - Operation indicators

## Troubleshooting

### Script Permission Denied

```bash
chmod +x *.sh
```

### Cannot Find Docker Compose File

Verify you're running from the scripts/deployment directory, or set:
```bash
export COMPOSE_FILE=/path/to/docker-compose/dhanman-services.yml
./deploy-services.sh
```

### Login Fails

- Verify token has correct permissions (`read:packages`, `write:packages`)
- Check token hasn't expired
- Ensure username is correct

### Pull Fails

- Login first: `./ghcr-login.sh user token`
- Verify images exist: https://github.com/orgs/b2atech/packages
- Check image names match registry

### Deploy Fails

- Ensure environment files exist (`.env`, not `.env.example`)
- Verify database connectivity
- Check port conflicts with `docker ps`
- Review logs: `docker compose logs SERVICE`

## Best Practices

1. **Always login before pulling** - Use `ghcr-login.sh` first
2. **Test in QA first** - Before deploying to production
3. **Backup before major updates** - Use DR script
4. **Monitor after deployment** - Check logs and health
5. **Document changes** - Commit config changes to Git

## Integration with CI/CD

These scripts can be used in CI/CD pipelines:

**Jenkins:**
```groovy
stage('Deploy') {
    steps {
        sh './scripts/deployment/ghcr-login.sh ${GITHUB_USER} ${GITHUB_TOKEN}'
        sh './scripts/deployment/deploy-services.sh qa'
    }
}
```

**GitHub Actions:**
```yaml
- name: Deploy to QA
  run: |
    ./scripts/deployment/ghcr-login.sh ${{ github.actor }} ${{ secrets.GITHUB_TOKEN }}
    ./scripts/deployment/deploy-services.sh qa
```

## Related Documentation

- [Main Setup Guide](../../SETUP.md) - Complete deployment guide
- [Docker Compose README](../../docker-compose/README.md) - Container orchestration
- [CI Templates](../../ci-templates/README.md) - Pipeline setup
