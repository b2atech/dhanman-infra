# Service Repository Setup Checklist

Use this checklist when adding Docker CI/CD to each service repository.

## 📋 Pre-Setup

- [ ] Identify service name (common, sales, purchase, payroll, inventory, or community)
- [ ] Verify .NET project structure and paths
- [ ] Ensure tests run successfully locally
- [ ] Have GitHub Personal Access Token ready (for Jenkins) or use GitHub Actions

---

## 🐳 Step 1: Add Dockerfile

- [ ] Copy Dockerfile template to service repo:
  ```bash
  cp /path/to/dhanman-infra/ci-templates/Dockerfile.example ./Dockerfile
  ```

- [ ] Update Dockerfile placeholders:
  - [ ] Replace `SERVICE_NAME` with actual service name:
    - `Common` for dhanman-common
    - `Sales` for dhanman-sales
    - `Purchase` for dhanman-purchase
    - `Payroll` for dhanman-payroll
    - `Inventory` for dhanman-inventory
    - `MyHome` for dhanman-community
  - [ ] Verify project paths match your structure
  - [ ] Update .NET version if not 8.0

- [ ] Test Dockerfile locally:
  ```bash
  docker build -t test-image .
  docker run -p 8080:80 test-image
  # Test: curl http://localhost:8080/health
  ```

---

## 🔧 Step 2A: Jenkins Pipeline (If Using Jenkins)

- [ ] Copy Jenkinsfile:
  ```bash
  cp /path/to/dhanman-infra/ci-templates/jenkins/Jenkinsfile ./Jenkinsfile
  ```

- [ ] Update Jenkinsfile:
  - [ ] Set `IMAGE_NAME` (e.g., `dhanman-sales`)
  - [ ] Set `PROJECT_PATH` to match your project
  - [ ] Verify `DOTNET_VERSION`

- [ ] Configure Jenkins:
  - [ ] Create new Pipeline job
  - [ ] Point to service repository
  - [ ] Add credential `github-container-registry`:
    - Username: GitHub username
    - Password: GitHub PAT with `write:packages`

- [ ] Test pipeline:
  - [ ] Push code
  - [ ] Monitor build in Jenkins
  - [ ] Verify image at https://github.com/orgs/b2atech/packages

---

## 🔧 Step 2B: GitHub Actions (If Using GitHub Actions)

- [ ] Copy workflow file:
  ```bash
  mkdir -p .github/workflows
  cp /path/to/dhanman-infra/ci-templates/github-actions/docker-build-push.yml \
     .github/workflows/docker-build-push.yml
  ```

- [ ] No additional configuration needed!

- [ ] Test workflow:
  - [ ] Push code to GitHub
  - [ ] Check Actions tab
  - [ ] Verify image at https://github.com/orgs/b2atech/packages

---

## ✅ Step 3: Verify

- [ ] Image exists in GitHub Container Registry
- [ ] Image name is: `ghcr.io/b2atech/dhanman-SERVICENAME`
- [ ] Tags are generated correctly (latest, develop, version)
- [ ] Can pull image locally:
  ```bash
  docker pull ghcr.io/b2atech/dhanman-SERVICENAME:latest
  ```

---

## 📝 Step 4: Update Infrastructure Repo

Update dhanman-infra repo to use the new image:

- [ ] Update docker-compose files if needed
- [ ] Update Ansible configurations if needed
- [ ] Document any service-specific configurations
- [ ] Test deployment in QA environment

---

## 📚 Step 5: Documentation

- [ ] Add deployment notes to service repo README
- [ ] Document any environment variables needed
- [ ] Note any special build requirements
- [ ] Update team wiki/docs

---

## 🎯 Service-Specific Configuration

### dhanman-common
- [ ] IMAGE_NAME: `dhanman-common`
- [ ] PROJECT_PATH: `src/Dhanman.Common.Api`
- [ ] Dockerfile SERVICE_NAME: `Common`

### dhanman-sales
- [ ] IMAGE_NAME: `dhanman-sales`
- [ ] PROJECT_PATH: `src/Dhanman.Sales.Api`
- [ ] Dockerfile SERVICE_NAME: `Sales`

### dhanman-purchase
- [ ] IMAGE_NAME: `dhanman-purchase`
- [ ] PROJECT_PATH: `src/Dhanman.Purchase.Api`
- [ ] Dockerfile SERVICE_NAME: `Purchase`

### dhanman-payroll
- [ ] IMAGE_NAME: `dhanman-payroll`
- [ ] PROJECT_PATH: `src/Dhanman.Payroll.Api`
- [ ] Dockerfile SERVICE_NAME: `Payroll`

### dhanman-inventory
- [ ] IMAGE_NAME: `dhanman-inventory`
- [ ] PROJECT_PATH: `src/Dhanman.Inventory.Api`
- [ ] Dockerfile SERVICE_NAME: `Inventory`

### dhanman-community
- [ ] IMAGE_NAME: `dhanman-community`
- [ ] PROJECT_PATH: `src/Dhanman.MyHome.Api`
- [ ] Dockerfile SERVICE_NAME: `MyHome`

---

## 🐛 Troubleshooting

### Build Fails
- [ ] Check paths in Dockerfile match project structure
- [ ] Verify all projects in solution can restore
- [ ] Test build locally: `dotnet build`
- [ ] Check .NET SDK version

### Tests Fail
- [ ] Run tests locally: `dotnet test`
- [ ] Check test dependencies
- [ ] Review test logs in pipeline

### Docker Build Fails
- [ ] Verify Dockerfile syntax
- [ ] Test locally: `docker build .`
- [ ] Check base image availability
- [ ] Review Docker logs

### Push to Registry Fails
- [ ] Verify authentication (Jenkins credential or GITHUB_TOKEN)
- [ ] Check token has `write:packages` permission
- [ ] Verify image name format
- [ ] Check network connectivity

### Image Not Appearing
- [ ] Check GitHub Packages: https://github.com/orgs/b2atech/packages
- [ ] Verify package visibility (public/private)
- [ ] Check repository permissions
- [ ] Review build logs

---

## 📞 Support

Need help? Check:
1. [SETUP.md](SETUP.md) - Complete setup guide
2. [CI Templates README](ci-templates/README.md) - Detailed CI/CD docs
3. Pipeline/workflow logs (Jenkins or GitHub Actions)
4. DevOps team

---

## ✨ Completion

When all checkboxes are complete:
- [ ] Service successfully builds images automatically
- [ ] Images are pushed to ghcr.io/b2atech
- [ ] Can deploy using docker-compose
- [ ] Team is notified of new automated deployment
- [ ] Documentation is updated

**Congratulations! Your service is now containerized with automated CI/CD! 🎉**
