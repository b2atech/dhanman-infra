#!/bin/bash
# Update a specific service to latest image
# Usage: ./update-service.sh <service_name>

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <service_name>"
    echo ""
    echo "Available services:"
    echo "  - dhanman-common"
    echo "  - dhanman-sales"
    echo "  - dhanman-purchase"
    echo "  - dhanman-payroll"
    echo "  - dhanman-inventory"
    echo "  - dhanman-community"
    exit 1
fi

SERVICE_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_DIR="$PROJECT_ROOT/docker-compose"
COMPOSE_FILE="$COMPOSE_DIR/dhanman-services.yml"

cd "$COMPOSE_DIR"

echo "🔄 Updating $SERVICE_NAME..."
echo ""

# Pull latest image
echo "📦 Pulling latest image..."
docker compose -f dhanman-services.yml pull "$SERVICE_NAME"

# Stop the service
echo "🛑 Stopping $SERVICE_NAME..."
docker compose -f dhanman-services.yml stop "$SERVICE_NAME"

# Remove old container
echo "🗑️  Removing old container..."
docker compose -f dhanman-services.yml rm -f "$SERVICE_NAME"

# Start with new image
echo "🚀 Starting $SERVICE_NAME with new image..."
docker compose -f dhanman-services.yml up -d "$SERVICE_NAME"

# Wait for health check
echo "⏳ Waiting for service to be healthy..."
sleep 10

# Show status
echo ""
echo "📊 Service status:"
docker compose -f dhanman-services.yml ps "$SERVICE_NAME"

echo ""
echo "✅ Update complete!"
echo ""
echo "View logs: docker compose -f $COMPOSE_FILE logs -f $SERVICE_NAME"
