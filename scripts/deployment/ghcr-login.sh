#!/bin/bash
# Login to GitHub Container Registry
# Usage: ./ghcr-login.sh <github_username> <github_token>

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <github_username> <github_token>"
    echo ""
    echo "Example: $0 myuser ghp_xxxxxxxxxxxx"
    echo ""
    echo "Note: GitHub token needs 'read:packages' and 'write:packages' scopes"
    exit 1
fi

GITHUB_USERNAME="$1"
GITHUB_TOKEN="$2"
REGISTRY="ghcr.io"

echo "🔐 Logging in to GitHub Container Registry..."
echo "$GITHUB_TOKEN" | docker login "$REGISTRY" -u "$GITHUB_USERNAME" --password-stdin

if [ $? -eq 0 ]; then
    echo "✅ Successfully logged in to $REGISTRY as $GITHUB_USERNAME"
    echo ""
    echo "You can now pull images:"
    echo "  docker pull ghcr.io/b2atech/dhanman-common:latest"
    echo ""
    echo "Or use docker-compose:"
    echo "  cd docker-compose && docker compose -f dhanman-services.yml pull"
else
    echo "❌ Login failed"
    exit 1
fi
