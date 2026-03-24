#!/usr/bin/env bash
# test-git.sh - Git module tests

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
echo "Git Module Tests"
echo "======================================"
echo

# Setup test environment
setup_test() {
    local test_id="gittest"
    TEST_STATE="/tmp/dotfiles-test-$test_id"
    TEST_HOME="/tmp/home-test-$test_id"

    rm -rf "$TEST_STATE" "$TEST_HOME"
    mkdir -p "$TEST_STATE/apps" "$TEST_HOME"

    export STATE_DIR="$TEST_STATE"
    export HOME="$TEST_HOME"
}

cleanup_test() {
    local test_id="gittest"
    rm -rf "/tmp/dotfiles-test-$test_id" "/tmp/home-test-$test_id"
}

setup_test
cd "$ROOT_DIR/git"

# Test 1: Config files exist in source
info "Test 1: Check git source files exist"
if [[ -f "files/.gitconfig" ]] && [[ -f "files/.gitignore_global" ]]; then
    pass "Git source files exist"
else
    fail "Missing git source files"
fi

# Test 2: Config.yaml has correct app info
info "Test 2: Check config.yaml structure"
if grep -q "name: git" config.yaml; then
    pass "Config has correct app name"
else
    fail "Config app name incorrect"
fi

# Test 3: Requirements include git
info "Test 3: Check requirements"
if grep -q "git" config.yaml; then
    pass "Git is listed as requirement"
else
    fail "Git not in requirements"
fi

# Test 4: Post-install hooks defined
info "Test 4: Verify post-install hooks"
if grep -q "post_install:" config.yaml && grep -q "core.excludesfile" config.yaml; then
    pass "Post-install hooks defined for excludesfile"
else
    fail "Post-install hooks missing"
fi

# Test 5: .gitconfig has local include
info "Test 5: Check .gitconfig.local include pattern"
if grep -q "gitconfig.local" files/.gitconfig; then
    pass ".gitconfig includes .gitconfig.local"
else
    fail ".gitconfig missing .gitconfig.local include"
fi

# Test 6: .gitconfig has sensible defaults
info "Test 6: Verify .gitconfig defaults"
if grep -q "defaultBranch = main" files/.gitconfig && grep -q "rebase = true" files/.gitconfig; then
    pass "Sensible git defaults configured"
else
    fail "Missing expected git defaults"
fi

# Test 7: .gitignore_global has common patterns
info "Test 7: Verify .gitignore_global patterns"
if grep -q ".DS_Store" files/.gitignore_global && grep -q "node_modules" files/.gitignore_global; then
    pass "Common ignore patterns present"
else
    fail "Missing expected ignore patterns"
fi

# Test 8: Fresh machine install (no existing .gitconfig)
info "Test 8: Install on fresh machine (no existing .gitconfig)"
./install.sh install --no-backup &>/dev/null
if [[ -f "$HOME/.gitconfig" ]] && [[ ! -f "$HOME/.gitconfig.local" ]]; then
    pass "Fresh install: .gitconfig deployed, no .gitconfig.local created"
else
    fail "Fresh install: unexpected state"
fi
./install.sh uninstall &>/dev/null

# Test 9: Install preserves existing .gitconfig as .gitconfig.local
info "Test 9: Existing .gitconfig renamed to .gitconfig.local"
# Simulate an existing .gitconfig with user settings
cat > "$HOME/.gitconfig" << 'GITCFG'
[user]
    name = Test User
    email = test@example.com
[credential]
    helper = cache
GITCFG
./install.sh install --no-backup &>/dev/null
if [[ -f "$HOME/.gitconfig.local" ]] && grep -q "Test User" "$HOME/.gitconfig.local" && grep -q "credential" "$HOME/.gitconfig.local"; then
    pass "Existing .gitconfig preserved as .gitconfig.local (all settings retained)"
else
    fail "Existing .gitconfig not preserved correctly"
fi

# Test 10: Managed .gitconfig deployed after rename
info "Test 10: Managed .gitconfig deployed after rename"
if grep -q "defaultBranch = main" "$HOME/.gitconfig" && grep -q "gitconfig.local" "$HOME/.gitconfig"; then
    pass "Managed .gitconfig deployed with include directive"
else
    fail "Managed .gitconfig not deployed correctly"
fi

# Test 11: .gitconfig.local is not overwritten on re-install
info "Test 11: Re-install does not overwrite .gitconfig.local"
./install.sh uninstall &>/dev/null
echo "# custom addition" >> "$HOME/.gitconfig.local"
./install.sh install --no-backup &>/dev/null
if grep -q "custom addition" "$HOME/.gitconfig.local"; then
    pass "Re-install preserves existing .gitconfig.local"
else
    fail "Re-install overwrote .gitconfig.local"
fi
./install.sh uninstall &>/dev/null
rm -f "$HOME/.gitconfig.local"

# Test 12: Install deploys files correctly
info "Test 12: Install and verify git files"
./install.sh install --no-backup &>/dev/null
if [[ -f "$HOME/.gitconfig" ]] && [[ -f "$HOME/.gitignore_global" ]]; then
    pass "Git files installed correctly"
else
    fail "Git files not installed correctly"
fi

# Test 13: Installed .gitconfig has include at bottom (local overrides managed)
info "Test 13: Include directive at bottom of .gitconfig"
last_section=$(grep '^\[' "$HOME/.gitconfig" | tail -1)
if [[ "$last_section" == "[include]" ]]; then
    pass "Include directive is last section (local overrides managed)"
else
    fail "Include directive is not the last section"
fi

# Test 14: git-setup script deployed
info "Test 14: git-setup deployed to ~/.local/bin/"
if [[ -x "$HOME/.local/bin/git-setup" ]]; then
    pass "git-setup deployed and executable"
else
    fail "git-setup not deployed"
fi

# Test 15: Uninstall removes files
info "Test 15: Uninstall removes git files"
./install.sh uninstall &>/dev/null
if [[ ! -f "$HOME/.gitconfig" ]] && [[ ! -f "$HOME/.gitignore_global" ]]; then
    pass "Git files removed on uninstall"
else
    fail "Git files not removed on uninstall"
fi

# Test 16: .gitconfig does not contain secrets
info "Test 16: No secrets in .gitconfig"
if ! grep -qi "token\|password\|secret" files/.gitconfig; then
    pass "No secrets found in .gitconfig"
else
    fail "Potential secrets found in .gitconfig"
fi

cleanup_test

echo
echo "======================================"
echo -e "${GREEN}All 16 git module tests passed!${NC}"
echo "======================================"
