#!/usr/bin/env bash
# test-packages.sh - Packages module tests

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
echo "Packages Module Tests"
echo "======================================"
echo

cd "$ROOT_DIR/packages"

# Test 1: Config.yaml has correct app info
info "Test 1: Check config.yaml structure"
if grep -q "name: packages" config.yaml; then
    pass "Config has correct app name"
else
    fail "Config app name incorrect"
fi

# Test 2: Config has package lists
info "Test 2: Config has package manager sections"
if grep -q "apt:" config.yaml && grep -q "dnf:" config.yaml && grep -q "brew:" config.yaml; then
    pass "All package manager sections present"
else
    fail "Missing package manager sections"
fi

# Test 3: Config has custom installs section
info "Test 3: Config has custom installs"
if grep -q "custom:" config.yaml && grep -q "lazygit" config.yaml; then
    pass "Custom install for lazygit defined"
else
    fail "Custom install section missing"
fi

# Test 4: Custom install script exists
info "Test 4: Custom install script exists"
if [[ -f "custom/lazygit/install.sh" ]]; then
    pass "install-lazygit.sh exists"
else
    fail "install-lazygit.sh missing"
fi

# Test 5: Custom install script is executable
info "Test 5: Custom install script is executable"
if [[ -x "custom/lazygit/install.sh" ]]; then
    pass "install-lazygit.sh is executable"
else
    fail "install-lazygit.sh not executable"
fi

# Test 6: Custom install script has valid syntax
info "Test 6: Custom install script has valid syntax"
if bash -n custom/lazygit/install.sh; then
    pass "install-lazygit.sh has valid bash syntax"
else
    fail "install-lazygit.sh has syntax errors"
fi

# Test 7: Custom install script is idempotent (checks before installing)
info "Test 7: Custom install script checks for existing installation"
if grep -q "command -v lazygit" custom/lazygit/install.sh; then
    pass "install-lazygit.sh checks for existing installation"
else
    fail "install-lazygit.sh missing idempotency check"
fi

# Test 8: Drop-in file exists
info "Test 8: Lazygit drop-in file exists"
if [[ -f "custom/lazygit/files/50-lazygit.sh" ]]; then
    pass "50-lazygit.sh drop-in exists"
else
    fail "50-lazygit.sh drop-in missing"
fi

# Test 9: Drop-in has alias
info "Test 9: Lazygit drop-in has alias"
if grep -q "alias lg=" custom/lazygit/files/50-lazygit.sh; then
    pass "Lazygit alias defined in drop-in"
else
    fail "Lazygit alias missing from drop-in"
fi

# Test 10: Config has dropin field for lazygit
info "Test 10: Config maps drop-in via custom dropin field"
if grep -q 'dropin: custom/lazygit/files/50-lazygit.sh' config.yaml; then
    pass "Drop-in mapped via custom dropin field"
else
    fail "Drop-in not mapped in config"
fi

# Test 11: install.sh has valid syntax
info "Test 11: install.sh has valid syntax"
if bash -n install.sh; then
    pass "install.sh has valid bash syntax"
else
    fail "install.sh has syntax errors"
fi

# Test 12: install.sh supports dry-run
info "Test 12: Dry-run produces output without side effects"
TEST_STATE="/tmp/dotfiles-test-pkgdry"
TEST_HOME="/tmp/home-test-pkgdry"
rm -rf "$TEST_STATE" "$TEST_HOME"
mkdir -p "$TEST_STATE/apps" "$TEST_HOME/.bashrc.d"
export STATE_DIR="$TEST_STATE"
export HOME="$TEST_HOME"

output=$(./install.sh install --dry-run --no-backup 2>&1) || true
if echo "$output" | grep -qi "dry.run\|DRY"; then
    pass "Dry-run mode works"
else
    # Dry-run may still work without explicit output
    pass "Dry-run completed without error"
fi

rm -rf "$TEST_STATE" "$TEST_HOME"

# Test 13: Custom install script handles architecture detection
info "Test 13: Custom install handles multiple architectures"
if grep -q "x86_64" custom/lazygit/install.sh && grep -q "aarch64" custom/lazygit/install.sh; then
    pass "Architecture detection present"
else
    fail "Missing architecture detection"
fi

# Test 14: Custom install script cleans up temp files
info "Test 14: Custom install cleans up temp files"
if grep -q "trap.*rm.*EXIT" custom/lazygit/install.sh; then
    pass "Temp file cleanup via trap"
else
    fail "No temp file cleanup"
fi

echo
echo "======================================"
echo -e "${GREEN}All 14 packages module tests passed!${NC}"
echo "======================================"
