#!/usr/bin/env bash
# test-vim.sh - Vim module tests

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
echo "Vim Module Tests"
echo "======================================"
echo

# Setup test environment
setup_test() {
    local test_id="vimtest"
    TEST_STATE="/tmp/dotfiles-test-$test_id"
    TEST_HOME="/tmp/home-test-$test_id"

    rm -rf "$TEST_STATE" "$TEST_HOME"
    mkdir -p "$TEST_STATE/apps" "$TEST_HOME"

    export STATE_DIR="$TEST_STATE"
    export HOME="$TEST_HOME"
}

cleanup_test() {
    local test_id="vimtest"
    rm -rf "/tmp/dotfiles-test-$test_id" "/tmp/home-test-$test_id"
}

setup_test
cd "$ROOT_DIR/vim"

# Test 1: Config files exist in source
info "Test 1: Check vim source files exist"
if [[ -f "files/.vimrc" ]]; then
    pass "Vim source file exists"
else
    fail "Missing .vimrc"
fi

# Test 2: Config.yaml has correct app info
info "Test 2: Check config.yaml structure"
if grep -q "name: vim" config.yaml; then
    pass "Config has correct app name"
else
    fail "Config app name incorrect"
fi

# Test 3: Requirements include vim
info "Test 3: Check requirements"
if awk '/^requirements:/{flag=1;next} /^[[:alpha:]]/{flag=0} flag' config.yaml | grep -qE "^[[:space:]]+-[[:space:]]+vim[[:space:]]*$"; then
    pass "vim is listed as requirement"
else
    fail "vim not in requirements"
fi

# Test 4: .vimrc has sensible defaults
info "Test 4: Verify .vimrc defaults"
if grep -q "set number" files/.vimrc && grep -q "set expandtab" files/.vimrc; then
    pass "Sensible vim defaults configured"
else
    fail "Missing expected vim defaults"
fi

# Test 5: Install deploys files correctly
info "Test 5: Install and verify vim files"
./install.sh install --no-backup &>/dev/null
if [[ -f "$HOME/.vimrc" ]]; then
    pass "Vim files installed correctly"
else
    fail "Vim files not installed correctly"
fi

# Test 6: Installed .vimrc matches source
info "Test 6: Installed .vimrc matches source"
if diff -q "$HOME/.vimrc" "files/.vimrc" &>/dev/null; then
    pass "Installed .vimrc matches source"
else
    fail "Installed .vimrc differs from source"
fi

# Test 7: Uninstall removes files
info "Test 7: Uninstall removes vim files"
./install.sh uninstall &>/dev/null
if [[ ! -f "$HOME/.vimrc" ]]; then
    pass "Vim files removed on uninstall"
else
    fail "Vim files not removed on uninstall"
fi

# Test 8: .vimrc does not contain secrets
info "Test 8: No secrets in .vimrc"
if ! grep -qi "token\|password\|secret" files/.vimrc; then
    pass "No secrets found in .vimrc"
else
    fail "Potential secrets found in .vimrc"
fi

cleanup_test

echo
echo "======================================"
echo -e "${GREEN}All 8 vim module tests passed!${NC}"
echo "======================================"
