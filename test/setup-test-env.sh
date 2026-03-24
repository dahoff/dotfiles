#!/usr/bin/env bash
# setup-test-env.sh - Setup Docker test environment for remote installation testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "======================================"
echo "Docker Test Environment Setup"
echo "======================================"
echo

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    error "Docker is not installed"
    echo "Install Docker Desktop for Windows and ensure it's running"
    exit 1
fi

# Check if Docker is running
if ! docker info &>/dev/null; then
    error "Docker is not running"
    echo "Start Docker Desktop and try again"
    exit 1
fi

success "Docker is installed and running"

# Generate SSH key for testing if it doesn't exist
if [[ ! -f ssh-key ]]; then
    info "Generating test SSH key..."
    ssh-keygen -t ed25519 -f ssh-key -N "" -C "test-key-for-dotfiles"
    success "SSH key generated"
else
    info "Using existing SSH key"
fi

# Check if container is already running and healthy
if docker ps --filter "name=dotfiles-test-server" --filter "status=running" | grep -q dotfiles-test-server; then
    info "Test server is already running"
    # Quick SSH check to verify it's actually working
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=1 \
           -i ssh-key -p 2222 testuser@localhost "echo test" &>/dev/null; then
        success "Test environment is ready"
    else
        warn "Container is running but SSH is not responding, restarting..."
        cd docker
        docker-compose down
        docker-compose up -d
        cd ..
    fi
else
    # Container doesn't exist or is stopped - clean up any existing state
    info "Setting up test environment..."
    cd docker
    # Clean up any existing containers/networks
    docker-compose down 2>/dev/null || true

    # Build Docker image (only if it doesn't exist)
    if ! docker images | grep -q "dotfiles-test-server.*latest"; then
        info "Building Docker image (first time)..."
        docker-compose build
        success "Docker image built and cached"
    else
        info "Using cached Docker image"
    fi

    # Start container
    info "Starting test server container..."
    docker-compose up -d
    cd ..
fi

# Wait for SSH to be ready (quick check first)
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=1 \
       -i ssh-key -p 2222 testuser@localhost "echo test" &>/dev/null; then
    success "SSH server is ready"
else
    info "Waiting for SSH server to start..."
    for i in {1..30}; do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=1 \
               -i ssh-key -p 2222 testuser@localhost "echo test" &>/dev/null; then
            break
        fi
        sleep 1
        if [[ $i -eq 30 ]]; then
            error "SSH server did not start in time"
            echo "Check logs with: cd docker && docker-compose logs"
            exit 1
        fi
    done
    success "SSH server is ready"
fi

echo
echo "======================================"
echo "Test Environment Ready!"
echo "======================================"
echo
echo "SSH Connection Details:"
echo "  Host: localhost"
echo "  Port: 2222"
echo "  User: testuser"
echo "  Key:  ./ssh-key"
echo
echo "Test SSH connection:"
echo "  ssh -i ssh-key -p 2222 testuser@localhost"
echo
echo "Test remote installation:"
echo "  cd ../tmux"
echo "  ./install.sh install --remote testuser@localhost"
echo
echo "View container logs:"
echo "  cd docker && docker-compose logs -f"
echo
echo "SSH into container:"
echo "  ssh -i ssh-key -p 2222 testuser@localhost"
echo
echo "Stop test environment:"
echo "  ./cleanup-test-env.sh"
echo
