#!/usr/bin/env bash
# cleanup-test-env.sh - Cleanup Docker test environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

echo "======================================"
echo "Cleaning up test environment"
echo "======================================"
echo

# Stop and remove containers
info "Stopping containers..."
cd docker
docker-compose down -v
cd ..

success "Containers stopped and removed"

# Remove test SSH keys (optional)
if [[ "${1:-}" == "--full" ]]; then
    info "Removing SSH keys..."
    rm -f ssh-key ssh-key.pub
    success "SSH keys removed"
fi

# Remove Docker image (optional)
if [[ "${1:-}" == "--full" ]]; then
    info "Removing Docker image..."
    docker rmi dotfiles-test-server:latest 2>/dev/null || true
    success "Docker image removed"
fi

echo
success "Cleanup complete!"
echo
echo "To setup again: ./setup-test-env.sh"
