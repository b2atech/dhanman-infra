# CI/CD Templates for Dhanman Services

This directory contains CI/CD pipeline templates for building and pushing Docker images to GitHub Container Registry (ghcr.io).

## Available Templates

### 1. Jenkins Pipeline (`jenkins/Jenkinsfile`)

A complete Jenkins pipeline that:
- Builds .NET application
- Runs tests
- Builds Docker image
- Pushes to GitHub Container Registry
- Tags images with branch name and build number

### 2. GitHub Actions Workflow (`github-actions/docker-build-push.yml`)

A GitHub Actions workflow that:
- Triggers on push to main/develop branches and tags
- Builds and tests .NET application
- Builds and pushes Docker image
- Uses semantic versioning for tags
- Leverages GitHub Actions cache

### 3. Dockerfile Example (`Dockerfile.example`)

A multi-stage Dockerfile optimized for .NET 8 applications with:
- Build, publish, and runtime stages
- Non-root user for security
- Health check endpoint
- Minimal runtime image

## Setup Instructions

### For Each Service Repository

#### Option A: Using Jenkins

1. **Copy Jenkinsfile to service repo:**
   ```bash
   cp ci-templates/jenkins/Jenkinsfile /path/to/dhanman-SERVICE/Jenkinsfile
   ```

2. **Update SERVICE_NAME placeholders:**
   - Replace `SERVICE_NAME` with: common, sales, purchase, payroll, inventory, or community
   - Update `PROJECT_PATH` to match your project structure

3. **Configure Jenkins:**
   - Create a new Pipeline job
   - Point to your service repository
   - Set up credential: `github-container-registry` with GitHub Personal Access Token

4. **GitHub Personal Access Token Requirements:**
   - Scope: `write:packages`, `read:packages`, `delete:packages`
   - Username: Your GitHub username
   - Password: The PAT token

#### Option B: Using GitHub Actions

1. **Copy workflow file:**
   ```bash
   mkdir -p .github/workflows
   cp ci-templates/github-actions/docker-build-push.yml /path/to/dhanman-SERVICE/.github/workflows/
   ```

2. **No additional setup needed** - GitHub Actions automatically has access to GITHUB_TOKEN with packages write permission

3. **Verify workflow:**
   - Push to your repository
   - Check Actions tab in GitHub

#### Dockerfile Setup

1. **Copy Dockerfile:**
   ```bash
   cp ci-templates/Dockerfile.example /path/to/dhanman-SERVICE/Dockerfile
   ```

2. **Update placeholders:**
   - Replace `SERVICE_NAME` with actual service name
   - Adjust paths to match your project structure
   - Update .NET version if different from 8.0

## Service-Specific Configuration

### dhanman-common
```bash
IMAGE_NAME='dhanman-common'
PROJECT_PATH='src/Dhanman.Common.Api'
```

### dhanman-sales
```bash
IMAGE_NAME='dhanman-sales'
PROJECT_PATH='src/Dhanman.Sales.Api'
```

### dhanman-purchase
```bash
IMAGE_NAME='dhanman-purchase'
PROJECT_PATH='src/Dhanman.Purchase.Api'
```

### dhanman-payroll
```bash
IMAGE_NAME='dhanman-payroll'
PROJECT_PATH='src/Dhanman.Payroll.Api'
```

### dhanman-inventory
```bash
IMAGE_NAME='dhanman-inventory'
PROJECT_PATH='src/Dhanman.Inventory.Api'
```

### dhanman-community
```bash
IMAGE_NAME='dhanman-community'
PROJECT_PATH='src/Dhanman.MyHome.Api'
```

## Image Naming Convention

Images are pushed to: `ghcr.io/b2atech/{service-name}:{tag}`

**Tag formats:**
- `latest` - Latest from main branch
- `develop` - Latest from develop branch
- `v1.2.3` - Semantic version tag
- `main-123` - Branch name + build number (Jenkins)
- `sha-abc123` - Git commit SHA (GitHub Actions)

## Testing Locally

### Build Docker image:
```bash
docker build -t dhanman-SERVICE:test -f Dockerfile .
```

### Run container:
```bash
docker run -p 5200:80 --env-file .env dhanman-SERVICE:test
```

### Push to registry (manual):
```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
docker tag dhanman-SERVICE:test ghcr.io/b2atech/dhanman-SERVICE:test
docker push ghcr.io/b2atech/dhanman-SERVICE:test
```

## Troubleshooting

### Jenkins Issues

**Problem:** Authentication failed
- Verify credential ID matches `github-container-registry`
- Ensure PAT has `write:packages` scope

**Problem:** Docker build fails
- Check Dockerfile paths match project structure
- Verify .NET SDK version

### GitHub Actions Issues

**Problem:** Permission denied pushing to registry
- Ensure workflow has `packages: write` permission
- Check repository settings → Actions → General → Workflow permissions

**Problem:** Build fails on test step
- Review test logs in Actions tab
- Ensure tests pass locally first

## Best Practices

1. **Always test locally before pushing**
2. **Use specific .NET versions in Dockerfile**
3. **Include health checks in images**
4. **Run containers as non-root user**
5. **Use multi-stage builds to minimize image size**
6. **Tag images with semantic versions for releases**
7. **Keep sensitive data in environment variables, not in image**

## Next Steps

1. Copy templates to each service repository
2. Update placeholders with service-specific values
3. Test pipeline with a small change
4. Update deployment configurations to use new images
5. Set up automated deployments on successful builds

## Related Documentation

- [Docker Compose Setup](../docker-compose/README.md)
- [Ansible Deployment](../ansible/README.md)
- [Main Infrastructure README](../README.md)
