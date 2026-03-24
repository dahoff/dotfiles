#!/usr/bin/env bash
# test-bash.sh - Bash-specific functionality tests

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
echo "Bash-Specific Tests"
echo "======================================"
echo

# Setup test environment
setup_test() {
    local test_id="bashtest"
    TEST_STATE="/tmp/dotfiles-test-$test_id"
    TEST_HOME="/tmp/home-test-$test_id"

    rm -rf "$TEST_STATE" "$TEST_HOME"
    mkdir -p "$TEST_STATE/apps" "$TEST_HOME"

    export STATE_DIR="$TEST_STATE"
    export HOME="$TEST_HOME"
}

cleanup_test() {
    local test_id="bashtest"
    rm -rf "/tmp/dotfiles-test-$test_id" "/tmp/home-test-$test_id"
}

setup_test
cd "$ROOT_DIR/bash"

# Test 1: Bash configuration files exist
info "Test 1: Check bash config files exist"
if [[ -f "files/.bashrc" ]]; then
    pass "Main bashrc exists"
else
    fail "Missing .bashrc"
fi

# Test 2: config.yaml exists and has correct structure
info "Test 2: Check config.yaml structure"
if grep -q "name: bash" config.yaml && grep -q "version:" config.yaml; then
    pass "Config has correct app metadata"
else
    fail "Config metadata incorrect"
fi

# Test 3: .bashrc has interactive guard
info "Test 3: Verify interactive guard"
if grep -q 'case \$- in' files/.bashrc; then
    pass "Interactive guard present"
else
    fail "Interactive guard missing"
fi

# Test 4: .bashrc sources system defaults
info "Test 4: Verify system defaults sourcing"
if grep -q '/etc/bash.bashrc' files/.bashrc && grep -q '/etc/profile.d/' files/.bashrc; then
    pass "System defaults sourced"
else
    fail "System defaults not sourced"
fi

# Test 5: .bashrc has drop-in sourcing loop
info "Test 5: Verify .bashrc.d drop-in sourcing"
if grep -q '\.bashrc\.d/\*\.sh' files/.bashrc; then
    pass "Drop-in sourcing loop present"
else
    fail "Drop-in sourcing loop missing"
fi

# Test 6: .bashrc has history configuration
info "Test 6: Verify history settings"
if grep -q 'HISTSIZE=10000' files/.bashrc && grep -q 'histappend' files/.bashrc; then
    pass "History configured correctly"
else
    fail "History settings missing"
fi

# Test 7: .bashrc has shell options
info "Test 7: Verify shell options"
if grep -q 'checkwinsize' files/.bashrc && grep -q 'globstar' files/.bashrc; then
    pass "Shell options configured"
else
    fail "Shell options missing"
fi

# Test 8: .bashrc has PATH setup
info "Test 8: Verify PATH configuration"
if grep -q '\.local/bin' files/.bashrc && grep -q 'HOME/bin' files/.bashrc; then
    pass "PATH configured"
else
    fail "PATH configuration missing"
fi

# Test 9: .bashrc has WSL detection
info "Test 9: Verify WSL detection"
if grep -q 'WSL_DISTRO_NAME' files/.bashrc && grep -q 'clip.exe' files/.bashrc; then
    pass "WSL detection present"
else
    fail "WSL detection missing"
fi

# Test 10: .bashrc has prompt configuration
info "Test 10: Verify prompt"
if grep -q 'PS1=' files/.bashrc; then
    pass "Prompt configured"
else
    fail "Prompt configuration missing"
fi

# Test 11: .bashrc has completion sourcing
info "Test 11: Verify bash completion"
if grep -q 'bash_completion' files/.bashrc; then
    pass "Bash completion sourced"
else
    fail "Bash completion missing"
fi

# Test 12: .bashrc has standard aliases
info "Test 12: Verify aliases"
if grep -q "alias ll=" files/.bashrc && grep -q "alias gs=" files/.bashrc; then
    pass "Standard aliases present"
else
    fail "Standard aliases missing"
fi

# Test 13: Install and verify .bashrc + ~/.bashrc.d/ directory
info "Test 13: Install and verify bash files"
./install.sh install --no-backup &>/dev/null
if [[ -f "$HOME/.bashrc" ]] && [[ -d "$HOME/.bashrc.d" ]]; then
    pass "Bashrc installed and .bashrc.d created"
else
    fail "Bash files not installed correctly"
fi

# Clean up for next test
./install.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 14: --append mode preserves existing content
info "Test 14: Append mode preserves existing .bashrc"
echo '# MY EXISTING CONFIG' > "$HOME/.bashrc"
echo 'export MY_VAR=hello' >> "$HOME/.bashrc"
./install.sh install --no-backup --append &>/dev/null
if grep -q 'MY EXISTING CONFIG' "$HOME/.bashrc" && \
   grep -q 'export MY_VAR=hello' "$HOME/.bashrc" && \
   grep -q 'bashrc.d' "$HOME/.bashrc"; then
    pass "Append mode preserved existing content and added new"
else
    fail "Append mode did not work correctly"
fi

# Clean up for next test
./install.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 15: --supplement installs single file
info "Test 15: Supplement single file"
SUPP_DIR="/tmp/dotfiles-supp-bashtest"
mkdir -p "$SUPP_DIR"
echo 'export SECRET=abc123' > "$SUPP_DIR/90-secrets.sh"
./install.sh install --no-backup --supplement "$SUPP_DIR/90-secrets.sh" &>/dev/null
if [[ -f "$HOME/.bashrc.d/90-secrets.sh" ]] && \
   grep -q 'SECRET=abc123' "$HOME/.bashrc.d/90-secrets.sh"; then
    pass "Supplement file installed correctly"
else
    fail "Supplement file not installed"
fi

# Clean up for next test
./install.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 16: --supplement with multiple files
info "Test 16: Supplement multiple files"
echo 'export PATH="/opt/bin:$PATH"' > "$SUPP_DIR/10-path.sh"
echo 'export API_KEY=xyz' > "$SUPP_DIR/90-keys.sh"
./install.sh install --no-backup --supplement "$SUPP_DIR/10-path.sh" --supplement "$SUPP_DIR/90-keys.sh" &>/dev/null
if [[ -f "$HOME/.bashrc.d/10-path.sh" ]] && [[ -f "$HOME/.bashrc.d/90-keys.sh" ]]; then
    pass "Multiple supplement files installed"
else
    fail "Multiple supplements not installed"
fi

# Clean up for next test
./install.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 17: Error handling for missing supplement file
info "Test 17: Error: missing supplement file"
if ./install.sh install --no-backup --supplement "/tmp/nonexistent-file.sh" &>/dev/null 2>&1; then
    fail "Should have failed for missing supplement"
else
    pass "Correctly rejected missing supplement file"
fi

# Test 18: --shell-scripts-dir custom path
info "Test 18: Custom shell-scripts-dir"
CUSTOM_DIR="$HOME/.config/shell.d"
./install.sh install --no-backup --shell-scripts-dir "$CUSTOM_DIR" &>/dev/null
if [[ -d "$CUSTOM_DIR" ]]; then
    pass "Custom shell-scripts-dir created"
else
    fail "Custom shell-scripts-dir not created"
fi

# Clean up for next test
./install.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$CUSTOM_DIR"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 19: Post-install hooks defined
info "Test 19: Verify post-install hooks"
if grep -q "post_install:" config.yaml; then
    pass "Post-install hooks defined"
else
    fail "No post-install hooks found"
fi

# Test 20: Requirements defined
info "Test 20: Verify requirements"
if grep -q "bash" config.yaml; then
    pass "Bash requirement listed"
else
    fail "Bash requirement not found"
fi

rm -rf "/tmp/dotfiles-supp-bashtest"
cleanup_test

echo
echo "======================================"
echo -e "${GREEN}All 20 bash-specific tests passed!${NC}"
echo "======================================"
