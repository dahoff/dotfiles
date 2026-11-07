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
    export XDG_STATE_HOME="$TEST_HOME/.xdg-state"
}

cleanup_test() {
    local test_id="bashtest"
    rm -rf "/tmp/dotfiles-test-$test_id" "/tmp/home-test-$test_id"
}

setup_test
cd "$ROOT_DIR/apps/bash"

# Test 1: Bash configuration files exist
info "Test 1: Check bash config files exist"
if [[ -f "files/.bashrc" ]]; then
    pass "Main bashrc exists"
else
    fail "Missing .bashrc"
fi

# Test 2: config.yaml exists and has correct structure
info "Test 2: Check config.yaml structure"
if grep -q "name: bash" config.yaml && grep -q "description:" config.yaml; then
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
./configure.sh install --no-backup &>/dev/null
if [[ -f "$HOME/.bashrc" ]] && [[ -d "$HOME/.bashrc.d" ]]; then
    pass "Bashrc installed and .bashrc.d created"
else
    fail "Bash files not installed correctly"
fi

# Clean up for next test
./configure.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 14: a custom .bashrc is replaced, kept as the original, and reported
info "Test 14: Custom .bashrc is replaced with a warning, nothing moves"
WARNINGS="$TEST_HOME/warnings"
SKEL="$TEST_HOME/skel-bashrc"
printf '# stock\nPS1="stock> "\n' > "$SKEL"
echo '# MY EXISTING CONFIG' > "$HOME/.bashrc"
echo 'export MY_VAR=hello' >> "$HOME/.bashrc"
OUT=$(DOTFILES_SKEL_BASHRC="$SKEL" DOTFILES_WARNINGS_FILE="$WARNINGS" ./configure.sh install --no-backup 2>&1) || fail "14: install failed: $OUT"
ORIG="$HOME/.bak/bash/original/.bashrc"
cmp -s files/.bashrc "$HOME/.bashrc" || fail "14: .bashrc is not the repo's file"
[[ ! -e "$HOME/.bashrc.d/00-local.sh" ]] || fail "14: 00-local.sh was created"
grep -qF 'export MY_VAR=hello' "$ORIG" || fail "14: original not kept"
grep -qF "$ORIG" "$WARNINGS" && grep -qF 'no longer loaded' "$WARNINGS" || fail "14: warning missing: $(cat "$WARNINGS" 2>/dev/null)"
[[ "$(grep -c 'no longer loaded' <<< "$OUT")" -ge 1 ]] || fail "14: not shown: $OUT"
pass "Replaced, original kept, warned"

# Clean up for next test
./configure.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 15: --supplement installs single file
info "Test 15: Supplement single file"
SUPP_DIR="/tmp/dotfiles-supp-bashtest"
mkdir -p "$SUPP_DIR"
echo 'export SECRET=abc123' > "$SUPP_DIR/90-secrets.sh"
./configure.sh install --no-backup --supplement "$SUPP_DIR/90-secrets.sh" &>/dev/null
if [[ -f "$HOME/.bashrc.d/90-secrets.sh" ]] && \
   grep -q 'SECRET=abc123' "$HOME/.bashrc.d/90-secrets.sh"; then
    pass "Supplement file installed correctly"
else
    fail "Supplement file not installed"
fi

# Clean up for next test
./configure.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 16: --supplement with multiple files
info "Test 16: Supplement multiple files"
echo 'export PATH="/opt/bin:$PATH"' > "$SUPP_DIR/10-path.sh"
echo 'export API_KEY=xyz' > "$SUPP_DIR/90-keys.sh"
./configure.sh install --no-backup --supplement "$SUPP_DIR/10-path.sh" --supplement "$SUPP_DIR/90-keys.sh" &>/dev/null
if [[ -f "$HOME/.bashrc.d/10-path.sh" ]] && [[ -f "$HOME/.bashrc.d/90-keys.sh" ]]; then
    pass "Multiple supplement files installed"
else
    fail "Multiple supplements not installed"
fi

# Clean up for next test
./configure.sh uninstall &>/dev/null 2>&1 || true
rm -f "$HOME/.bashrc"
rm -rf "$HOME/.bashrc.d"
rm -rf "$TEST_STATE/apps"
mkdir -p "$TEST_STATE/apps"

# Test 17: Error handling for missing supplement file
info "Test 17: Error: missing supplement file"
if ./configure.sh install --no-backup --supplement "/tmp/nonexistent-file.sh" &>/dev/null 2>&1; then
    fail "Should have failed for missing supplement"
else
    pass "Correctly rejected missing supplement file"
fi

# Test 18: --shell-scripts-dir custom path
info "Test 18: Custom shell-scripts-dir"
CUSTOM_DIR="$HOME/.config/shell.d"
./configure.sh install --no-backup --shell-scripts-dir "$CUSTOM_DIR" &>/dev/null
if [[ -d "$CUSTOM_DIR" ]]; then
    pass "Custom shell-scripts-dir created"
else
    fail "Custom shell-scripts-dir not created"
fi

# Clean up for next test
./configure.sh uninstall &>/dev/null 2>&1 || true
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

# --- .bashrc is an ordinary replaced file ---

reset_bash() {
    ./configure.sh uninstall --no-backup &>/dev/null || true
    rm -rf "$HOME/.bashrc" "$HOME/.bashrc.d" "$HOME/.bak" "$TEST_STATE/apps" "$TEST_STATE/records" "$WARNINGS"
    mkdir -p "$TEST_STATE/apps"
}

# Test 21: a distro's stock file gets no warning
info "Test 21: Stock .bashrc is replaced without a warning"
reset_bash
cp "$SKEL" "$HOME/.bashrc"
OUT=$(DOTFILES_SKEL_BASHRC="$SKEL" DOTFILES_WARNINGS_FILE="$WARNINGS" ./configure.sh install --no-backup 2>&1) || fail "21: install failed: $OUT"
cmp -s files/.bashrc "$HOME/.bashrc" || fail "21: not the repo's file"
[[ ! -s "$WARNINGS" ]] || fail "21: warned: $(cat "$WARNINGS")"
grep -qF 'no longer loaded' <<< "$OUT" && fail "21: warned on screen: $OUT"
[[ ! -e "$HOME/.bashrc.d/00-local.sh" ]] || fail "21: 00-local.sh created"
pass "Stock file: no warning"

# Test 22: no .bashrc at all, no warning; empty .bashrc, no warning
info "Test 22: Missing or blank .bashrc gets no warning"
reset_bash
OUT=$(DOTFILES_WARNINGS_FILE="$WARNINGS" ./configure.sh install --no-backup 2>&1) || fail "22: install failed: $OUT"
[[ ! -s "$WARNINGS" ]] || fail "22: warned for a missing file"
reset_bash
printf '\n  \n' > "$HOME/.bashrc"
OUT=$(DOTFILES_WARNINGS_FILE="$WARNINGS" ./configure.sh install --no-backup 2>&1) || fail "22: install failed: $OUT"
[[ ! -s "$WARNINGS" ]] || fail "22: warned for a blank file"
pass "No warning"

# Test 23: an existing 00-local.sh is still sourced, and left alone
info "Test 23: Existing 00-local.sh is sourced and unchanged"
reset_bash
mkdir -p "$HOME/.bashrc.d"
echo 'export LOCAL_MARK=yes' > "$HOME/.bashrc.d/00-local.sh"
BEFORE=$(cat "$HOME/.bashrc.d/00-local.sh")
./configure.sh install --no-backup &>/dev/null || fail "23: install failed"
[[ "$(cat "$HOME/.bashrc.d/00-local.sh")" == "$BEFORE" ]] || fail "23: drop-in changed"
[[ "$(bash -ic 'echo "${LOCAL_MARK:-}"' 2>/dev/null </dev/null | tail -1)" == yes ]] || fail "23: drop-in not sourced"
./configure.sh upgrade --no-backup &>/dev/null || fail "23: upgrade failed"
[[ "$(cat "$HOME/.bashrc.d/00-local.sh")" == "$BEFORE" ]] || fail "23: drop-in changed by upgrade"
pass "00-local.sh kept and loaded"

# Test 24: --append is gone
info "Test 24: --append is rejected"
reset_bash
if ./configure.sh install --no-backup --append &>/dev/null; then
    fail "24: --append accepted"
fi
[[ ! -e "$HOME/.bashrc" ]] || fail "24: something was installed"
pass "--append rejected"

# Test 25: --supplement still works next to a custom .bashrc
info "Test 25: --supplement still works"
reset_bash
mkdir -p "$SUPP_DIR"
echo 'export S=1' > "$SUPP_DIR/60-s.sh"
echo '# mine' > "$HOME/.bashrc"
./configure.sh install --no-backup --supplement "$SUPP_DIR/60-s.sh" &>/dev/null || fail "25: install failed"
grep -qxF 'export S=1' "$HOME/.bashrc.d/60-s.sh" || fail "25: supplement missing"
cmp -s files/.bashrc "$HOME/.bashrc" || fail "25: not the repo's file"
pass "--supplement works"

# Test 26: the warning is for installs only
info "Test 26: Upgrade does not warn again"
reset_bash
echo '# mine' > "$HOME/.bashrc"
DOTFILES_SKEL_BASHRC="$SKEL" ./configure.sh install --no-backup &>/dev/null || fail "26: install failed"
rm -f "$WARNINGS"
DOTFILES_SKEL_BASHRC="$SKEL" DOTFILES_WARNINGS_FILE="$WARNINGS" ./configure.sh upgrade --no-backup &>/dev/null || fail "26: upgrade failed"
[[ ! -s "$WARNINGS" ]] || fail "26: warned on upgrade"
pass "Install only"

# Test 27: a dry run changes nothing and doesn't claim a replacement
info "Test 27: Dry run does not warn or change .bashrc"
reset_bash
echo '# mine' > "$HOME/.bashrc"
OUT=$(DOTFILES_SKEL_BASHRC="$SKEL" DOTFILES_WARNINGS_FILE="$WARNINGS" ./configure.sh install --no-backup --dry-run 2>&1) || fail "27: dry run failed: $OUT"
[[ "$(cat "$HOME/.bashrc")" == '# mine' ]] || fail "27: .bashrc changed"
[[ ! -s "$WARNINGS" ]] || fail "27: warned in a dry run"
pass "Dry run quiet"

rm -rf "$SUPP_DIR"
cleanup_test

echo
echo "======================================"
echo -e "${GREEN}All 27 bash-specific tests passed!${NC}"
echo "======================================"
