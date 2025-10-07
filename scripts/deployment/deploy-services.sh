#!/bin/bash
# Deploy Dhanman services using Docker Compose
# Usage: ./deploy-services.sh [environment] [service]

set -e

ENVIRONMENT="${1:-prod}"
SERVICE="${2:-all}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_DIR="$PROJECT_ROOT/docker-compose"
COMPOSE_FILE="$COMPOSE_DIR/dhanman-services.yml"

echo "🚀 Deploying Dhanman services..."
echo "Environment: $ENVIRONMENT"
echo "Service: $SERVICE"
echo "Compose file: $COMPOSE_FILE"
echo ""

# Check if compose file exists
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌ Docker Compose file not found: $COMPOSE_FILE"
    exit 1
fi

# Check if environment files exist
ENV_DIR="$COMPOSE_DIR/env"
if [ ! -d "$ENV_DIR" ]; then
    echo "❌ Environment directory not found: $ENV_DIR"
    exit 1
fi

# Verify at least one .env file exists (not just examples)
ENV_COUNT=$(find "$ENV_DIR" -name "*.env" ! -name "*.example" | wc -l)
if [ "$ENV_COUNT" -eq 0 ]; then
    echo "⚠️  No environment files found!"
    echo "Please copy and configure environment files:"
    echo "  cd $ENV_DIR"
    echo "  cp common.env.example common.env"
    echo "  # Edit common.env with actual values"
    echo "  # Repeat for all services"
    exit 1
fi

cd "$COMPOSE_DIR"

# Pull latest images
echo "📦 Pulling latest images..."
if [ "$SERVICE" = "all" ]; then
    docker compose -f dhanman-services.yml pull
else
    docker compose -f dhanman-services.yml pull "$SERVICE"
fi

# Deploy services
echo ""
echo "🔄 Starting services..."
if [ "$SERVICE" = "all" ]; then
    docker compose -f dhanman-services.yml up -d
else
    docker compose -f dhanman-services.yml up -d "$SERVICE"
fi

# Wait a moment for containers to start
sleep 5

# Show status
echo ""
echo "📊 Service status:"
docker compose -f dhanman-services.yml ps

echo ""
echo "✅ Deployment complete!"
echo ""
echo "Useful commands:"
echo "  View logs: docker compose -f $COMPOSE_FILE logs -f"
echo "  Stop services: docker compose -f $COMPOSE_FILE down"
echo "  Restart service: docker compose -f $COMPOSE_FILE restart <service>"
