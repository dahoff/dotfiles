#!/usr/bin/env bash
# test-scripts.sh - Scripts module tests

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
echo "Scripts Module Tests"
echo "======================================"
echo

# Setup test environment
setup_test() {
    local test_id="scriptstest"
    TEST_STATE="/tmp/dotfiles-test-$test_id"
    TEST_HOME="/tmp/home-test-$test_id"

    rm -rf "$TEST_STATE" "$TEST_HOME"
    mkdir -p "$TEST_STATE/apps" "$TEST_HOME"

    export STATE_DIR="$TEST_STATE"
    export HOME="$TEST_HOME"
}

cleanup_test() {
    local test_id="scriptstest"
    rm -rf "/tmp/dotfiles-test-$test_id" "/tmp/home-test-$test_id"
}

setup_test
cd "$ROOT_DIR/scripts"

# Test 1: Source scripts exist
info "Test 1: Check source scripts exist"
if [[ -f "files/git-branch-clean" ]] && [[ -f "files/extract" ]]; then
    pass "Source scripts exist"
else
    fail "Missing source scripts"
fi

# Test 2: Source scripts are executable
info "Test 2: Check source scripts are executable"
if [[ -x "files/git-branch-clean" ]] && [[ -x "files/extract" ]]; then
    pass "Source scripts are executable"
else
    fail "Source scripts not executable"
fi

# Test 3: Config.yaml has correct app info
info "Test 3: Check config.yaml structure"
if grep -q "name: scripts" config.yaml; then
    pass "Config has correct app name"
else
    fail "Config app name incorrect"
fi

# Test 4: Config maps to ~/.local/bin/
info "Test 4: Config targets ~/.local/bin/"
if grep -q "~/.local/bin/" config.yaml; then
    pass "Scripts target ~/.local/bin/"
else
    fail "Scripts don't target ~/.local/bin/"
fi

# Test 5: Config sets mode 0755
info "Test 5: Config sets executable permissions"
if grep -q "0755" config.yaml; then
    pass "Scripts set to mode 0755"
else
    fail "Scripts not set to 0755"
fi

# Test 6: Install deploys scripts
info "Test 6: Install and verify scripts"
./install.sh install --no-backup &>/dev/null
if [[ -f "$HOME/.local/bin/git-branch-clean" ]] && [[ -f "$HOME/.local/bin/extract" ]]; then
    pass "Scripts installed to ~/.local/bin/"
else
    fail "Scripts not installed correctly"
fi

# Test 7: Installed scripts are executable
info "Test 7: Installed scripts have correct permissions"
if [[ -x "$HOME/.local/bin/git-branch-clean" ]] && [[ -x "$HOME/.local/bin/extract" ]]; then
    pass "Installed scripts are executable"
else
    fail "Installed scripts not executable"
fi

# Test 8: git-branch-clean has valid bash syntax
info "Test 8: git-branch-clean has valid syntax"
if bash -n files/git-branch-clean; then
    pass "git-branch-clean has valid bash syntax"
else
    fail "git-branch-clean has syntax errors"
fi

# Test 9: extract has valid bash syntax
info "Test 9: extract has valid syntax"
if bash -n files/extract; then
    pass "extract has valid bash syntax"
else
    fail "extract has syntax errors"
fi

# Test 10: extract handles known formats
info "Test 10: extract handles common archive formats"
if grep -q "tar.gz" files/extract && grep -q "zip" files/extract && grep -q "tar.xz" files/extract; then
    pass "extract handles tar.gz, zip, tar.xz"
else
    fail "extract missing common format handlers"
fi

# Test 11: Uninstall removes scripts
info "Test 11: Uninstall removes scripts"
./install.sh uninstall &>/dev/null
if [[ ! -f "$HOME/.local/bin/git-branch-clean" ]] && [[ ! -f "$HOME/.local/bin/extract" ]]; then
    pass "Scripts removed on uninstall"
else
    fail "Scripts not removed on uninstall"
fi

cleanup_test

echo
echo "======================================"
echo -e "${GREEN}All 11 scripts module tests passed!${NC}"
echo "======================================"
