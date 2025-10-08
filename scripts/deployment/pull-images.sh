#!/bin/bash
# Pull latest images for all Dhanman services
# Usage: ./pull-images.sh [environment]

set -e

ENVIRONMENT="${1:-prod}"
REGISTRY="ghcr.io/b2atech"

# Service list
SERVICES=(
    "dhanman-common"
    "dhanman-sales"
    "dhanman-purchase"
    "dhanman-payroll"
    "dhanman-inventory"
    "dhanman-community"
)

echo "🐳 Pulling latest images from GitHub Container Registry..."
echo "Environment: $ENVIRONMENT"
echo ""

# Check if logged in
if ! docker info 2>&1 | grep -q "Username"; then
    echo "⚠️  Not logged in to Docker registry. Attempting to pull public images..."
fi

FAILED=0

for service in "${SERVICES[@]}"; do
    IMAGE="$REGISTRY/$service:latest"
    echo "📦 Pulling $IMAGE..."
    
    if docker pull "$IMAGE"; then
        echo "✅ Successfully pulled $service"
    else
        echo "❌ Failed to pull $service"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $FAILED -eq 0 ]; then
    echo "✅ All images pulled successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Update environment files in docker-compose/env/"
    echo "  2. Start services: cd docker-compose && docker compose -f dhanman-services.yml up -d"
else
    echo "⚠️  $FAILED image(s) failed to pull"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check if you're logged in: ./scripts/deployment/ghcr-login.sh <user> <token>"
    echo "  2. Verify images exist: https://github.com/orgs/b2atech/packages"
    echo "  3. Ensure you have read:packages permission"
    exit 1
fi
