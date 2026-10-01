#!/usr/bin/env bash
# test-dotfiles - Setup orchestrator tests

set -euo pipefail
unset DOTFILES_HOSTS_REPO

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$TEST_DIR")"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

echo "======================================"
echo "Setup Orchestrator Tests"
echo "======================================"
echo

# Setup test environment
setup_test() {
    local test_id="setuptest"
    TEST_STATE="/tmp/dotfiles-test-$test_id"
    TEST_HOME="/tmp/home-test-$test_id"

    rm -rf "$TEST_STATE" "$TEST_HOME"
    mkdir -p "$TEST_STATE/apps" "$TEST_HOME"

    export STATE_DIR="$TEST_STATE"
    export HOME="$TEST_HOME"
    export DOTFILES_CONFIG="$TEST_HOME/nonexistent-config"
}

cleanup_test() {
    local test_id="setuptest"
    rm -rf "/tmp/dotfiles-test-$test_id" "/tmp/home-test-$test_id"
}

# Test 1: dotfiles exists and is executable
info "Test 1: dotfiles exists and is executable"
if [[ -x "$ROOT_DIR/dotfiles" ]]; then
    pass "dotfiles exists and is executable"
else
    fail "dotfiles missing or not executable"
fi

# Test 2: complete.yaml has packages section with bash and tmux
info "Test 2: complete.yaml has packages section with bash and tmux"
if grep -q "^packages:" "$ROOT_DIR/profiles/complete.yaml" && \
   grep -q "name: bash" "$ROOT_DIR/profiles/complete.yaml" && \
   grep -q "name: tmux" "$ROOT_DIR/profiles/complete.yaml"; then
    pass "complete.yaml has correct structure"
else
    fail "complete.yaml structure incorrect"
fi

# Test 3: bash listed before tmux in complete.yaml
info "Test 3: bash listed before tmux in complete.yaml"
bash_line=$(grep -n "name: bash" "$ROOT_DIR/profiles/complete.yaml" | head -1 | cut -d: -f1)
tmux_line=$(grep -n "name: tmux" "$ROOT_DIR/profiles/complete.yaml" | head -1 | cut -d: -f1)
if [[ "$bash_line" -lt "$tmux_line" ]]; then
    pass "bash listed before tmux"
else
    fail "bash should be listed before tmux"
fi

# Test 4: help command
info "Test 4: help command exits 0 and shows usage"
if output=$(cd "$ROOT_DIR" && ./dotfiles help 2>&1) && echo "$output" | grep -q "Usage:"; then
    pass "help command works"
else
    fail "help command failed"
fi

# Test 5: No args exits non-zero
info "Test 5: no args exits non-zero"
if cd "$ROOT_DIR" && ./dotfiles &>/dev/null 2>&1; then
    fail "Should have exited non-zero with no args"
else
    pass "Correctly exits non-zero with no args"
fi

# Test 6: Invalid command exits non-zero
info "Test 6: invalid command exits non-zero"
if cd "$ROOT_DIR" && ./dotfiles boguscmd &>/dev/null 2>&1; then
    fail "Should have rejected invalid command"
elif cd "$ROOT_DIR" && ./dotfiles deploy &>/dev/null 2>&1; then
    fail "Should have rejected the removed 'deploy' command"
else
    pass "Correctly rejects invalid command and 'deploy'"
fi

# Test 7: remote options are gone
info "Test 7: removed --host option is rejected"
if output=$(cd "$ROOT_DIR" && ./dotfiles sync --host x 2>&1); then
    fail "Should have rejected --host"
elif echo "$output" | grep -q "Unknown option"; then
    pass "Correctly rejects --host as an unknown option"
else
    fail "--host rejected without 'Unknown option': $output"
fi

# Test 9: app installers use the shared core
info "Test 9: app installers source lib/installer.sh"
for app in bash claude git packages scripts tmux vim; do
    if ! grep -q 'lib/installer.sh' "$ROOT_DIR/$app/install.sh"; then
        fail "$app/install.sh does not source lib/installer.sh"
    fi
done
pass "All app installers source lib/installer.sh"

# Test 10: shared core provides deploy
info "Test 10: deploy command in lib/installer.sh"
if grep -q "^cmd_deploy()" "$ROOT_DIR/lib/installer.sh"; then
    pass "cmd_deploy exists in lib/installer.sh"
else
    fail "cmd_deploy missing from lib/installer.sh"
fi

# Test 11: Profile has unified packages format (no separate apps: section)
info "Test 11: Profile uses unified packages format"
if grep -q "^packages:" "$ROOT_DIR/profiles/complete.yaml" && \
   ! grep -q "^apps:" "$ROOT_DIR/profiles/complete.yaml"; then
    pass "Profile uses unified packages format"
else
    fail "Profile should use packages: not apps:"
fi

# Test 12: Profile entries can have config.dir
info "Test 12: Profile entries support config.dir"
if grep -q "dir: git" "$ROOT_DIR/profiles/complete.yaml" && \
   grep -q "dir: bash" "$ROOT_DIR/profiles/complete.yaml"; then
    pass "Profile entries have config.dir"
else
    fail "Profile entries missing config.dir"
fi

# Test 13: Profile entries can have OS package fields
info "Test 13: Profile entries support apt/dnf/brew fields"
if grep -q "apt: git" "$ROOT_DIR/profiles/complete.yaml" && \
   grep -q "dnf: git" "$ROOT_DIR/profiles/complete.yaml"; then
    pass "Profile entries have OS package fields"
else
    fail "Profile entries missing OS package fields"
fi

# Test 14: Minimal profile excludes packages by name
info "Test 14: Minimal profile uses exclude by package name"
if grep -q "extends: complete" "$ROOT_DIR/profiles/minimal.yaml" && \
   grep -q "claude" "$ROOT_DIR/profiles/minimal.yaml"; then
    pass "Minimal profile excludes by package name"
else
    fail "Minimal profile exclude format incorrect"
fi

# Integration tests require test environment
setup_test

# Test 15: bash deploy on clean system (installs)
info "Test 15: bash deploy on clean system"
cd "$ROOT_DIR/bash"
if ./install.sh deploy --no-backup &>/dev/null && [[ -f "$HOME/.bashrc" ]]; then
    pass "bash deploy installs on clean system"
else
    fail "bash deploy failed on clean system"
fi

# Test 16: bash deploy is idempotent (upgrades when already installed)
info "Test 16: bash deploy idempotent (upgrades)"
if ./install.sh deploy --no-backup &>/dev/null && [[ -f "$HOME/.bashrc" ]]; then
    pass "bash deploy upgrades when already installed"
else
    fail "bash deploy idempotent failed"
fi

# Clean up for dotfiles tests
./install.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 17: dotfiles sync --dry-run
info "Test 17: dotfiles sync --dry-run"
cd "$ROOT_DIR"
if ./dotfiles sync --dry-run &>/dev/null; then
    pass "dotfiles sync --dry-run succeeds"
else
    fail "dotfiles sync --dry-run failed"
fi

# Test 18: dotfiles sync --no-backup (full integration)
info "Test 18: dotfiles sync --no-backup (full integration)"
cd "$ROOT_DIR"
if ./dotfiles sync --no-backup &>/dev/null && \
   [[ -f "$HOME/.bashrc" ]] && \
   [[ -f "$HOME/.tmux.conf" ]]; then
    pass "dotfiles sync installs configs"
else
    fail "dotfiles sync failed"
fi

# Test 19: dotfiles status
info "Test 19: dotfiles status"
cd "$ROOT_DIR"
if output=$(./dotfiles status 2>&1) && \
   echo "$output" | grep -q "Installed"; then
    pass "dotfiles status shows installed configs"
else
    fail "dotfiles status failed"
fi

# Test 20: Version stored on install is a content hash
info "Test 20: Version stored on install"
STATE_FILE="$STATE_DIR/apps/bash.yaml"
VERSION=$(grep "^  version:" "$STATE_FILE" | awk '{print $2}')
if [[ "$VERSION" =~ ^[0-9a-f]{12}$ ]]; then
    pass "State file contains content hash ($VERSION)"
else
    fail "State file should contain a 12-char content hash, got '$VERSION'"
fi

# Test 21: Upgrade skips when current (same version)
info "Test 21: Upgrade skips when current"
cd "$ROOT_DIR/bash"
OUTPUT=$(./install.sh deploy --no-backup 2>&1)
if echo "$OUTPUT" | grep -q "already up to date"; then
    pass "Deploy skips when already at current version"
else
    fail "Deploy should skip when version matches"
fi

# Test 22: --force overrides version skip
info "Test 22: --force overrides version skip"
cd "$ROOT_DIR/bash"
OUTPUT=$(./install.sh deploy --no-backup --force 2>&1)
if echo "$OUTPUT" | grep -q "upgraded successfully"; then
    pass "--force overrides version check"
else
    fail "--force should override version check"
fi

# Test 23: Dropins installed even when custom tool already present
info "Test 23: Dropins installed even when custom tool already present"
cd "$ROOT_DIR"
# Create a fake "already installed" tool that the check will find
mkdir -p "$HOME/.local/bin"
echo '#!/bin/sh' > "$HOME/.local/bin/lazyssh"
chmod +x "$HOME/.local/bin/lazyssh"
export PATH="$HOME/.local/bin:$PATH"
# Verify the check would pass (tool is "installed")
if command -v lazyssh &>/dev/null; then
    # Deploy should still install the dropin
    ./dotfiles sync --no-backup --dry-run &>/dev/null 2>&1
    OUTPUT=$(./dotfiles sync --no-backup --dry-run 2>&1)
    if echo "$OUTPUT" | grep -qi "dropin\|50-lazyssh"; then
        pass "Dropin referenced even when tool already installed"
    else
        # Verify by doing a real deploy and checking the file
        ./dotfiles sync --no-backup &>/dev/null 2>&1
        if [[ -f "$HOME/.bashrc.d/50-lazyssh.sh" ]]; then
            pass "Dropin installed even when tool already installed"
        else
            fail "Dropin not installed when tool already present"
        fi
    fi
else
    fail "Test setup failed: fake lazyssh not in PATH"
fi

# Cleanup
cd "$ROOT_DIR/bash" && ./install.sh uninstall &>/dev/null 2>&1 || true
cd "$ROOT_DIR/tmux" && ./install.sh uninstall &>/dev/null 2>&1 || true
cleanup_test

echo
echo "======================================"
echo -e "${GREEN}All 23 setup orchestrator tests passed!${NC}"
echo "======================================"
