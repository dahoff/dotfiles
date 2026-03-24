#!/usr/bin/env bash
# test-tmux.sh - Tmux-specific functionality tests

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
echo "Tmux-Specific Tests"
echo "======================================"
echo

# Setup test environment
setup_test() {
    local test_id="tmuxtest"
    TEST_STATE="/tmp/dotfiles-test-$test_id"
    TEST_HOME="/tmp/home-test-$test_id"

    rm -rf "$TEST_STATE" "$TEST_HOME"
    mkdir -p "$TEST_STATE/apps" "$TEST_HOME"

    export STATE_DIR="$TEST_STATE"
    export HOME="$TEST_HOME"
}

cleanup_test() {
    local test_id="tmuxtest"
    rm -rf "/tmp/dotfiles-test-$test_id" "/tmp/home-test-$test_id"
}

setup_test
cd "$ROOT_DIR/tmux"

# Test 1: Tmux configuration files exist
info "Test 1: Check tmux config files exist"
if [[ -f "files/.tmux.conf" ]]; then
    pass "Main tmux config exists"
else
    fail "Missing .tmux.conf"
fi

# Test 2: Cheatsheet files exist
info "Test 2: Check cheatsheet files exist"
if [[ -f "files/.tmux-cheatsheet.sh" ]] && [[ -f "files/.tmux-cheatsheet.txt" ]]; then
    pass "Cheatsheet files exist"
else
    fail "Missing cheatsheet files"
fi

# Test 3: Cheatsheet script is executable
info "Test 3: Check cheatsheet script permissions"
if [[ -x "files/.tmux-cheatsheet.sh" ]]; then
    pass "Cheatsheet script is executable"
else
    fail "Cheatsheet script is not executable"
fi

# Test 4: Config contains expected tmux settings
info "Test 4: Verify key tmux settings in config"
if grep -q "set -g mouse on" files/.tmux.conf; then
    pass "Mouse support configured"
else
    fail "Mouse support not found in config"
fi

# Test 5: Verify OSC 52 clipboard integration
info "Test 5: Check OSC 52 clipboard config"
if grep -q "set -g set-clipboard on" files/.tmux.conf; then
    pass "OSC 52 clipboard configured"
else
    fail "OSC 52 clipboard not configured"
fi

# Test 6: Check for popup keybindings
info "Test 6: Verify popup keybindings"
if grep -q "display-popup" files/.tmux.conf; then
    pass "Popup keybindings found"
else
    fail "Popup keybindings not found"
fi

# Test 7: Verify cheatsheet content
info "Test 7: Check cheatsheet content"
if [[ -s "files/.tmux-cheatsheet.txt" ]]; then
    pass "Cheatsheet has content"
else
    fail "Cheatsheet is empty"
fi

# Test 8: Install and verify tmux-specific files
info "Test 8: Install and verify tmux files"
./install.sh install --no-backup &>/dev/null
if [[ -f "$HOME/.tmux.conf" ]] && [[ -f "$HOME/.tmux/.tmux-cheatsheet.sh" ]] && [[ -f "$HOME/.tmux/.tmux-cheatsheet.txt" ]]; then
    pass "All tmux files installed correctly"
else
    fail "Tmux files not installed correctly"
fi

# Test 9: Verify config.yaml has correct app info
info "Test 9: Check config.yaml structure"
if grep -q "name: tmux" config.yaml && grep -q "version:" config.yaml; then
    pass "Config has correct app metadata"
else
    fail "Config metadata incorrect"
fi

# Test 10: Check for post-install hooks
info "Test 10: Verify post-install hooks"
if grep -q "post_install:" config.yaml; then
    pass "Post-install hooks defined"
else
    fail "No post-install hooks found"
fi

# Test 11: Window numbering starts at 1
info "Test 11: Verify base-index set to 1"
if grep -q "set -g base-index 1" files/.tmux.conf; then
    pass "Windows start at 1 (not 0)"
else
    fail "base-index not set to 1"
fi

# Test 12: Alt+number window bindings exist
info "Test 12: Check Alt+number bindings"
if grep -q "bind -n M-1 select-window" files/.tmux.conf && \
   grep -q "bind -n M-9 select-window" files/.tmux.conf; then
    pass "Alt+number window bindings configured"
else
    fail "Alt+number bindings missing"
fi

# Test 13: Alt+0 binding for last window
info "Test 13: Verify Alt+0 binding"
if grep -q "bind -n M-0 select-window -l" files/.tmux.conf; then
    pass "Alt+0 bound to last window"
else
    fail "Alt+0 binding incorrect or missing"
fi

# Test 14: Cheatsheet documents window switching
info "Test 14: Check cheatsheet has window switching docs"
if grep -q "Alt+1 to Alt+9" files/.tmux-cheatsheet.txt; then
    pass "Cheatsheet documents Alt+number shortcuts"
else
    fail "Cheatsheet missing window shortcut docs"
fi

# Test 15: Backtick prefix configured
info "Test 15: Verify backtick as prefix"
if grep -q "set -g prefix \`" files/.tmux.conf; then
    pass "Backtick configured as prefix"
else
    fail "Backtick prefix not configured"
fi

# Test 16: Literal backtick bindings
info "Test 16: Check literal backtick bindings"
if grep -q "bind \` send-keys '\`'" files/.tmux.conf && \
   grep -q "bind -n M-\` send-keys '\`'" files/.tmux.conf; then
    pass "Literal backtick bindings configured"
else
    fail "Literal backtick bindings missing"
fi

# Test 17: Cheatsheet shows new prefix
info "Test 17: Verify cheatsheet documents backtick prefix"
if grep -q "Prefix.*\` (backtick)" files/.tmux-cheatsheet.txt; then
    pass "Cheatsheet documents backtick prefix"
else
    fail "Cheatsheet doesn't show backtick prefix"
fi

# Test 18: Ctrl+t top popup binding
info "Test 18: Verify Ctrl+t top popup binding"
if grep -q 'bind -n C-t display-popup.*"top"' files/.tmux.conf; then
    pass "Ctrl+t bound to top popup"
else
    fail "Ctrl+t top binding missing"
fi

# Test 19: Cheatsheet documents Ctrl+t
info "Test 19: Check cheatsheet documents Ctrl+t"
if grep -q "Ctrl+t.*top" files/.tmux-cheatsheet.txt; then
    pass "Cheatsheet documents Ctrl+t shortcut"
else
    fail "Cheatsheet missing Ctrl+t documentation"
fi

cleanup_test

echo
echo "======================================"
echo -e "${GREEN}All 19 tmux-specific tests passed!${NC}"
echo "======================================"
