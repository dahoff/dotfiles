#!/usr/bin/env bash
# test-setup.sh - Setup orchestrator tests

set -euo pipefail

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
}

cleanup_test() {
    local test_id="setuptest"
    rm -rf "/tmp/dotfiles-test-$test_id" "/tmp/home-test-$test_id"
}

# Test 1: setup.sh exists and is executable
info "Test 1: setup.sh exists and is executable"
if [[ -x "$ROOT_DIR/setup.sh" ]]; then
    pass "setup.sh exists and is executable"
else
    fail "setup.sh missing or not executable"
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
if output=$(cd "$ROOT_DIR" && ./setup.sh help 2>&1) && echo "$output" | grep -q "Usage:"; then
    pass "help command works"
else
    fail "help command failed"
fi

# Test 5: No args exits non-zero
info "Test 5: no args exits non-zero"
if cd "$ROOT_DIR" && ./setup.sh &>/dev/null 2>&1; then
    fail "Should have exited non-zero with no args"
else
    pass "Correctly exits non-zero with no args"
fi

# Test 6: Invalid command exits non-zero
info "Test 6: invalid command exits non-zero"
if cd "$ROOT_DIR" && ./setup.sh boguscmd &>/dev/null 2>&1; then
    fail "Should have rejected invalid command"
else
    pass "Correctly rejects invalid command"
fi

# Test 7: Mutual exclusion of --host and --hosts-file
info "Test 7: --host and --hosts-file are mutually exclusive"
if cd "$ROOT_DIR" && ./setup.sh deploy --host user@server --hosts-file hosts.yaml &>/dev/null 2>&1; then
    fail "Should have rejected mutual exclusion"
else
    pass "Correctly rejects --host + --hosts-file"
fi

# Test 8: Missing hosts file
info "Test 8: error for nonexistent hosts file"
if cd "$ROOT_DIR" && ./setup.sh deploy --hosts-file /tmp/nonexistent-hosts-file.yaml &>/dev/null 2>&1; then
    fail "Should have errored for missing hosts file"
else
    pass "Correctly errors for missing hosts file"
fi

# Test 9: deploy command exists in bash/install.sh
info "Test 9: deploy command in bash/install.sh"
if grep -q "cmd_deploy" "$ROOT_DIR/bash/install.sh"; then
    pass "cmd_deploy exists in bash/install.sh"
else
    fail "cmd_deploy missing from bash/install.sh"
fi

# Test 10: deploy command exists in tmux/install.sh
info "Test 10: deploy command in tmux/install.sh"
if grep -q "cmd_deploy" "$ROOT_DIR/tmux/install.sh"; then
    pass "cmd_deploy exists in tmux/install.sh"
else
    fail "cmd_deploy missing from tmux/install.sh"
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

# Clean up for setup.sh tests
./install.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 17: setup.sh deploy --dry-run
info "Test 17: setup.sh deploy --dry-run"
cd "$ROOT_DIR"
if ./setup.sh deploy --dry-run &>/dev/null; then
    pass "setup.sh deploy --dry-run succeeds"
else
    fail "setup.sh deploy --dry-run failed"
fi

# Test 18: setup.sh deploy --no-backup (full integration)
info "Test 18: setup.sh deploy --no-backup (full integration)"
cd "$ROOT_DIR"
if ./setup.sh deploy --no-backup &>/dev/null && \
   [[ -f "$HOME/.bashrc" ]] && \
   [[ -f "$HOME/.tmux.conf" ]]; then
    pass "setup.sh deploy installs configs"
else
    fail "setup.sh deploy failed"
fi

# Test 19: setup.sh status
info "Test 19: setup.sh status"
cd "$ROOT_DIR"
if output=$(./setup.sh status 2>&1) && \
   echo "$output" | grep -q "Installed"; then
    pass "setup.sh status shows installed configs"
else
    fail "setup.sh status failed"
fi

# Test 20: Version stored on install (state file contains git hash)
info "Test 20: Version stored on install"
STATE_FILE="$STATE_DIR/apps/bash.yaml"
GIT_HASH=$(cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
if grep -q "version: $GIT_HASH" "$STATE_FILE"; then
    pass "State file contains git hash ($GIT_HASH)"
else
    fail "State file should contain git hash"
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

# Cleanup
cd "$ROOT_DIR/bash" && ./install.sh uninstall &>/dev/null 2>&1 || true
cd "$ROOT_DIR/tmux" && ./install.sh uninstall &>/dev/null 2>&1 || true
cleanup_test

echo
echo "======================================"
echo -e "${GREEN}All 22 setup orchestrator tests passed!${NC}"
echo "======================================"
