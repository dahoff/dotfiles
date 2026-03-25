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

cd "$ROOT_DIR"

# Test 1: Profile has package entries (replaces old config.yaml test)
info "Test 1: Profile has packages section"
if grep -q "^packages:" profiles/complete.yaml; then
    pass "Profile has packages section"
else
    fail "Profile missing packages section"
fi

# Test 2: Profile has OS package entries with apt/dnf/brew
info "Test 2: Profile has OS package entries"
if grep -q "apt:" profiles/complete.yaml && \
   grep -q "dnf:" profiles/complete.yaml && \
   grep -q "brew:" profiles/complete.yaml; then
    pass "OS package fields present in profile"
else
    fail "Missing OS package fields in profile"
fi

# Test 3: Profile has custom install entries
info "Test 3: Profile has custom installs"
if grep -q "custom:" profiles/complete.yaml && grep -q "lazygit" profiles/complete.yaml; then
    pass "Custom install for lazygit defined in profile"
else
    fail "Custom install section missing from profile"
fi

# Test 4: Custom install script exists
info "Test 4: Custom install script exists"
if [[ -f "packages/custom/lazygit/install.sh" ]]; then
    pass "install-lazygit.sh exists"
else
    fail "install-lazygit.sh missing"
fi

# Test 5: Custom install script is executable
info "Test 5: Custom install script is executable"
if [[ -x "packages/custom/lazygit/install.sh" ]]; then
    pass "install-lazygit.sh is executable"
else
    fail "install-lazygit.sh not executable"
fi

# Test 6: Custom install script has valid syntax
info "Test 6: Custom install script has valid syntax"
if bash -n packages/custom/lazygit/install.sh; then
    pass "install-lazygit.sh has valid bash syntax"
else
    fail "install-lazygit.sh has syntax errors"
fi

# Test 7: Custom install script is idempotent (checks before installing)
info "Test 7: Custom install script checks for existing installation"
if grep -q "command -v lazygit" packages/custom/lazygit/install.sh; then
    pass "install-lazygit.sh checks for existing installation"
else
    fail "install-lazygit.sh missing idempotency check"
fi

# Test 8: Drop-in file exists
info "Test 8: Lazygit drop-in file exists"
if [[ -f "packages/custom/lazygit/files/50-lazygit.sh" ]]; then
    pass "50-lazygit.sh drop-in exists"
else
    fail "50-lazygit.sh drop-in missing"
fi

# Test 9: Drop-in has alias
info "Test 9: Lazygit drop-in has alias"
if grep -q "alias lg=" packages/custom/lazygit/files/50-lazygit.sh; then
    pass "Lazygit alias defined in drop-in"
else
    fail "Lazygit alias missing from drop-in"
fi

# Test 10: Profile maps dropin via custom section
info "Test 10: Profile maps drop-in via custom dropin field"
if grep -q 'dropin: custom/lazygit/files/50-lazygit.sh' profiles/complete.yaml; then
    pass "Drop-in mapped via profile custom dropin field"
else
    fail "Drop-in not mapped in profile"
fi

# Test 11: packages/install.sh has valid syntax
info "Test 11: packages/install.sh has valid syntax"
if bash -n packages/install.sh; then
    pass "packages/install.sh has valid bash syntax"
else
    fail "packages/install.sh has syntax errors"
fi

# Test 12: packages/config.yaml no longer exists (merged into profile)
info "Test 12: packages/config.yaml removed (merged into profile)"
if [[ ! -f "packages/config.yaml" ]]; then
    pass "packages/config.yaml correctly removed"
else
    fail "packages/config.yaml should not exist (merged into profiles)"
fi

# Test 13: Custom install script handles architecture detection
info "Test 13: Custom install handles multiple architectures"
if grep -q "x86_64" packages/custom/lazygit/install.sh && grep -q "aarch64" packages/custom/lazygit/install.sh; then
    pass "Architecture detection present"
else
    fail "Missing architecture detection"
fi

# Test 14: Custom install script cleans up temp files
info "Test 14: Custom install cleans up temp files"
if grep -q "trap.*rm.*EXIT" packages/custom/lazygit/install.sh; then
    pass "Temp file cleanup via trap"
else
    fail "No temp file cleanup"
fi

echo
echo "======================================"
echo -e "${GREEN}All 14 packages module tests passed!${NC}"
echo "======================================"
