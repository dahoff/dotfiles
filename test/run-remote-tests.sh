#!/usr/bin/env bash
# run-remote-tests.sh - Push-to-remote integration tests (need Docker)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

# SSH config for test server
SSH_KEY="$SCRIPT_DIR/ssh-key"
SSH_HOST="localhost"
SSH_PORT="2222"
SSH_USER="testuser"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Helper function to SSH into test server
test_ssh() {
    ssh $SSH_OPTS -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$@"
}

echo "======================================"
echo "Remote Installation Tests"
echo "======================================"
echo

# Test 0: Verify test environment is running
info "Test 0: Checking test environment"
if ! docker ps | grep -q dotfiles-test-server; then
    fail "Test server is not running"
    echo "Run: cd test-env && ./setup-test-env.sh"
    exit 1
fi
pass "Test server is running"

if ! test_ssh "echo test" &>/dev/null; then
    fail "Cannot connect to test server"
    exit 1
fi
pass "SSH connection working"

echo

# Placeholder: the remote deploy mode these tests exercised was removed when
# the orchestrator was renamed dotfiles. Push tests are added with lib/push.sh.
info "No push tests yet; they are added with 'dotfiles push'"

echo "======================================"
echo -e "${GREEN}Environment check passed${NC}"
echo "======================================"
