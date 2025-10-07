#!/bin/bash
# Validate dhanman-infra setup
# Run this script to verify your infrastructure is properly configured

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║           Dhanman Infrastructure Validation Script                   ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo ""

CHECKS_PASSED=0
CHECKS_FAILED=0
WARNINGS=0

# Function to check and report
check() {
    local name="$1"
    local command="$2"
    
    if eval "$command" >/dev/null 2>&1; then
        echo "✅ $name"
        ((CHECKS_PASSED++))
        return 0
    else
        echo "❌ $name"
        ((CHECKS_FAILED++))
        return 1
    fi
}

# Function for warnings
warn() {
    local name="$1"
    local command="$2"
    
    if eval "$command" >/dev/null 2>&1; then
        echo "✅ $name"
    else
        echo "⚠️  $name"
        ((WARNINGS++))
    fi
}

echo "📋 Checking Prerequisites..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "Docker installed" "command -v docker"
check "Docker Compose v2 installed" "docker compose version"
check "Git installed" "command -v git"
warn "Ansible installed (optional)" "command -v ansible"
warn "yamllint installed (optional)" "command -v yamllint"

echo ""
echo "📁 Checking Repository Structure..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "docker-compose directory exists" "test -d $PROJECT_ROOT/docker-compose"
check "ci-templates directory exists" "test -d $PROJECT_ROOT/ci-templates"
check "scripts/deployment directory exists" "test -d $PROJECT_ROOT/scripts/deployment"
check "ansible directory exists" "test -d $PROJECT_ROOT/ansible"

echo ""
echo "🐳 Validating Docker Compose Files..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "Main compose file exists" "test -f $PROJECT_ROOT/docker-compose/dhanman-services.yml"
check "QA compose file exists" "test -f $PROJECT_ROOT/docker-compose/qa/dhanman-services-qa.yml"
check "Prod compose file exists" "test -f $PROJECT_ROOT/docker-compose/prod/dhanman-services-prod.yml"

# Validate YAML syntax if yamllint is available
if command -v yamllint >/dev/null 2>&1; then
    if yamllint -d relaxed "$PROJECT_ROOT/docker-compose"/*.yml >/dev/null 2>&1; then
        echo "✅ Docker Compose YAML syntax valid"
        ((CHECKS_PASSED++))
    else
        echo "❌ Docker Compose YAML syntax invalid"
        ((CHECKS_FAILED++))
    fi
else
    echo "⚠️  YAML validation skipped (yamllint not installed)"
    ((WARNINGS++))
fi

echo ""
echo "📝 Checking Environment Templates..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for service in common sales purchase payroll inventory community; do
    check "$service.env.example exists" "test -f $PROJECT_ROOT/docker-compose/env/$service.env.example"
done

echo ""
echo "🔧 Validating CI/CD Templates..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "Dockerfile.example exists" "test -f $PROJECT_ROOT/ci-templates/Dockerfile.example"
check "Jenkinsfile exists" "test -f $PROJECT_ROOT/ci-templates/jenkins/Jenkinsfile"
check "GitHub Actions workflow exists" "test -f $PROJECT_ROOT/ci-templates/github-actions/docker-build-push.yml"

echo ""
echo "🚀 Checking Deployment Scripts..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for script in ghcr-login.sh pull-images.sh deploy-services.sh update-service.sh; do
    if test -f "$PROJECT_ROOT/scripts/deployment/$script"; then
        if test -x "$PROJECT_ROOT/scripts/deployment/$script"; then
            echo "✅ $script exists and is executable"
            ((CHECKS_PASSED++))
        else
            echo "⚠️  $script exists but not executable"
            ((WARNINGS++))
        fi
    else
        echo "❌ $script missing"
        ((CHECKS_FAILED++))
    fi
done

# Validate shell script syntax
echo ""
echo "Validating shell script syntax..."
for script in "$PROJECT_ROOT/scripts/deployment"/*.sh; do
    if bash -n "$script" 2>/dev/null; then
        echo "✅ $(basename $script) syntax valid"
        ((CHECKS_PASSED++))
    else
        echo "❌ $(basename $script) syntax invalid"
        ((CHECKS_FAILED++))
    fi
done

echo ""
echo "📚 Checking Documentation..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "README.md exists" "test -f $PROJECT_ROOT/README.md"
check "SETUP.md exists" "test -f $PROJECT_ROOT/SETUP.md"
check "QUICKREF.md exists" "test -f $PROJECT_ROOT/QUICKREF.md"
check "SERVICE-SETUP-CHECKLIST.md exists" "test -f $PROJECT_ROOT/SERVICE-SETUP-CHECKLIST.md"
check "ARCHITECTURE.md exists" "test -f $PROJECT_ROOT/ARCHITECTURE.md"
check "docker-compose/README.md exists" "test -f $PROJECT_ROOT/docker-compose/README.md"
check "ci-templates/README.md exists" "test -f $PROJECT_ROOT/ci-templates/README.md"
check "scripts/deployment/README.md exists" "test -f $PROJECT_ROOT/scripts/deployment/README.md"

echo ""
echo "🔐 Checking Security Configuration..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check ".gitignore for env files exists" "test -f $PROJECT_ROOT/docker-compose/.gitignore"
check ".gitignore contains *.env" "grep -q '*.env' $PROJECT_ROOT/docker-compose/.gitignore"

# Check if actual .env files exist (should NOT be in repo)
if ls "$PROJECT_ROOT/docker-compose/env"/*.env >/dev/null 2>&1; then
    echo "⚠️  .env files found (ensure they're in .gitignore)"
    ((WARNINGS++))
else
    echo "✅ No .env files in repository (good!)"
    ((CHECKS_PASSED++))
fi

echo ""
echo "🐋 Checking Docker Connectivity..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if docker info >/dev/null 2>&1; then
    echo "✅ Docker daemon is running"
    ((CHECKS_PASSED++))
    
    # Check if logged into registry
    if docker info 2>&1 | grep -q "ghcr.io"; then
        echo "✅ Logged in to GitHub Container Registry"
        ((CHECKS_PASSED++))
    else
        echo "⚠️  Not logged in to GitHub Container Registry"
        echo "   Run: ./scripts/deployment/ghcr-login.sh USERNAME TOKEN"
        ((WARNINGS++))
    fi
else
    echo "❌ Docker daemon is not running"
    ((CHECKS_FAILED++))
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║                         VALIDATION SUMMARY                            ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "✅ Checks Passed: $CHECKS_PASSED"
echo "❌ Checks Failed: $CHECKS_FAILED"
echo "⚠️  Warnings:     $WARNINGS"
echo ""

if [ $CHECKS_FAILED -eq 0 ]; then
    echo "🎉 All critical checks passed!"
    echo ""
    echo "Next steps:"
    echo "  1. Review SETUP.md for complete setup instructions"
    echo "  2. Configure environment files in docker-compose/env/"
    echo "  3. Run: ./scripts/deployment/ghcr-login.sh USERNAME TOKEN"
    echo "  4. Deploy: ./scripts/deployment/deploy-services.sh"
    echo ""
    exit 0
else
    echo "⚠️  Some checks failed. Please review the output above."
    echo ""
    echo "Common issues:"
    echo "  • Docker not installed: Install Docker Engine"
    echo "  • Files missing: Re-clone the repository"
    echo "  • Scripts not executable: Run 'chmod +x scripts/deployment/*.sh'"
    echo ""
    exit 1
fi
