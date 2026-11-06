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

# Test 14: existing content moves to a drop-in, .bashrc is the repo's file
info "Test 14: Existing .bashrc content moves to 00-local.sh"
echo '# MY EXISTING CONFIG' > "$HOME/.bashrc"
echo 'export MY_VAR=hello' >> "$HOME/.bashrc"
./configure.sh install --no-backup &>/dev/null
LOCAL="$HOME/.bashrc.d/00-local.sh"
if cmp -s files/.bashrc "$HOME/.bashrc" && \
   grep -q 'MY EXISTING CONFIG' "$LOCAL" && \
   grep -q 'export MY_VAR=hello' "$LOCAL"; then
    pass "Existing content kept and .bashrc replaced"
else
    fail "Existing content not moved correctly"
fi
[[ "$(stat -c %a "$LOCAL" 2>/dev/null || stat -f %Lp "$LOCAL")" == 600 ]] || fail "00-local.sh should be private"

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

rm -rf "/tmp/dotfiles-supp-bashtest"

# --- Machines set up by the old --append behaviour ---

REPO_RC="$(pwd)/files/.bashrc"
BEGIN='# --- BEGIN managed bashrc (appended by dotfiles installer) ---'
END='# --- END managed bashrc ---'
LOCAL="$HOME/.bashrc.d/00-local.sh"
WARNINGS="$TEST_HOME/warnings"
RUN_OUT=""
RUN_RC=0

reset_bash() {
    ./configure.sh uninstall --no-backup &>/dev/null || true
    rm -rf "$HOME/.bashrc" "$HOME/.bashrc.d" "$HOME/.bak" "$TEST_STATE/apps" "$TEST_STATE/deployed" "$WARNINGS"
    mkdir -p "$TEST_STATE/apps"
}
# Installed, then made to look like an old install: no record, an older version.
# The live .bashrc is what the test writes to stdin.
old_install() {
    ./configure.sh install --no-backup &>/dev/null || fail "install failed"
    rm -f "$HOME/.bashrc" "$LOCAL"
    rm -rf "$TEST_STATE/deployed"
    sed -i.bak 's/^  version: .*/  version: old/' "$TEST_STATE/apps/bash.yaml"
    cat > "$HOME/.bashrc"
}
block() {
    echo
    echo "$BEGIN"
    cat "${1:-$REPO_RC}"
    echo "$END"
}
upgrade() {
    RUN_RC=0
    RUN_OUT=$(DOTFILES_WARNINGS_FILE="$WARNINGS" ./configure.sh upgrade "$@" 2>&1) || RUN_RC=$?
    [[ $RUN_RC -eq 0 ]] || fail "upgrade failed: $RUN_OUT"
}
is_repo_rc() {
    cmp -s "$REPO_RC" "$HOME/.bashrc" || fail "$1: .bashrc is not the repo's file"
    grep -qF "$BEGIN" "$HOME/.bashrc" && fail "$1: block left behind"
    true
}
saved_copies() {
    find "$HOME/.bak/bash" -maxdepth 1 -name 'bashrc.before-cleanup.*' 2>/dev/null | wc -l | tr -d ' '
}

# Test 21: a distro's stock file is not moved
info "Test 21: Stock .bashrc is replaced, not moved"
reset_bash
SKEL="$TEST_HOME/skel-bashrc"
printf '# stock\nPS1="stock> "\n' > "$SKEL"
cp "$SKEL" "$HOME/.bashrc"
DOTFILES_SKEL_BASHRC="$SKEL" ./configure.sh install --no-backup &>/dev/null
is_repo_rc "21"
[[ ! -e "$LOCAL" ]] || fail "21: stock file moved to a drop-in"
pass "Stock file not moved"

# Test 22: the old flag still works
info "Test 22: --append is accepted and does nothing"
reset_bash
echo '# mine' > "$HOME/.bashrc"
./configure.sh install --no-backup --append &>/dev/null || fail "22: --append rejected"
is_repo_rc "22"
pass "--append ignored"

# Test 23: this machine's shape: a managed copy plus one identical block
info "Test 23: Managed copy plus block becomes one file, quietly"
reset_bash
{ cat "$REPO_RC"; block; } | old_install
upgrade --no-backup
is_repo_rc "23"
[[ ! -e "$LOCAL" ]] || fail "23: nothing should move"
[[ "$(saved_copies)" == 0 && ! -s "$WARNINGS" ]] || fail "23: warned about nothing: $RUN_OUT"
grep -qF "$HOME/.bashrc" "$TEST_STATE/deployed/bash.tsv" || fail "23: not recorded"
pass "Duplicates removed"

# Test 24: own content before and after the blocks is kept, in order
info "Test 24: Own content around blocks is kept"
reset_bash
{ echo 'export BEFORE=1'; block; echo 'export BETWEEN=1'; block; echo 'export AFTER=1'; } | old_install
upgrade --no-backup
is_repo_rc "24"
[[ "$(grep -E '^export ' "$LOCAL" | paste -sd' ' -)" == "export BEFORE=1 export BETWEEN=1 export AFTER=1" ]] || fail "24: wrong content: $(cat "$LOCAL")"
grep -qF 'moved your own' "$WARNINGS" || fail "24: move not reported"
[[ "$(saved_copies)" == 0 ]] || fail "24: nothing differed"
pass "Own content kept"

# Test 25: a hand edit inside a managed copy is saved, even with --no-backup
info "Test 25: Differing managed copy is saved and reported"
reset_bash
{ cat "$REPO_RC"; echo 'alias edited=1'; block; } | old_install
upgrade --no-backup
is_repo_rc "25"
[[ "$(saved_copies)" == 1 ]] || fail "25: no saved copy"
grep -qxF 'alias edited=1' "$HOME"/.bak/bash/bashrc.before-cleanup.* || fail "25: edit not in the saved copy"
grep -qF 'hand edits may be gone' "$WARNINGS" || fail "25: not reported"
pass "Hand edit saved"

# Test 26: moving twice doesn't duplicate, and an edited drop-in is not overwritten
info "Test 26: 00-local.sh is added to, not replaced or duplicated"
reset_bash
{ echo 'export MINE=1'; block; } | old_install
mkdir -p "$HOME/.bashrc.d"
echo 'export ALREADY=1' > "$LOCAL"
upgrade --no-backup
grep -qxF 'export ALREADY=1' "$LOCAL" || fail "26: existing drop-in overwritten"
[[ "$(grep -cxF 'export MINE=1' "$LOCAL")" == 1 ]] || fail "26: content missing"
BEFORE=$(cat "$LOCAL")
{ echo 'export MINE=1'; block; } > "$HOME/.bashrc"
sed -i.bak 's/^  version: .*/  version: old/' "$TEST_STATE/apps/bash.yaml"
rm -rf "$TEST_STATE/deployed"
upgrade --no-backup
[[ "$(cat "$LOCAL")" == "$BEFORE" ]] || fail "26: content duplicated"
pass "No duplicates"

# Test 27: dry run changes nothing
info "Test 27: Dry run leaves the old file alone"
reset_bash
{ echo 'export MINE=1'; block; } | old_install
BEFORE=$(cat "$HOME/.bashrc")
upgrade --no-backup --dry-run
[[ "$(cat "$HOME/.bashrc")" == "$BEFORE" && ! -e "$LOCAL" ]] || fail "27: dry run changed something"
printf '%s\n' "$RUN_OUT" | grep -qF 'Would move' || fail "27: not explained: $RUN_OUT"
pass "Dry run"

# Test 28: once cleaned up, more updates add nothing and hand edits are protected
info "Test 28: Later updates don't append, and keep a hand edit"
reset_bash
{ cat "$REPO_RC"; block; } | old_install
upgrade --no-backup
sed -i.bak 's/^  version: .*/  version: old/' "$TEST_STATE/apps/bash.yaml"
upgrade --no-backup
is_repo_rc "28"
echo 'alias mine=1' >> "$HOME/.bashrc"
sed -i.bak 's/^  version: .*/  version: old/' "$TEST_STATE/apps/bash.yaml"
upgrade --no-backup
grep -qxF 'alias mine=1' "$HOME/.bashrc" || fail "28: hand edit overwritten"
[[ "$(wc -l < "$HOME/.bashrc" | tr -d ' ')" == "$(( $(wc -l < "$REPO_RC" | tr -d ' ') + 1 ))" ]] || fail "28: file grew"
pass "No more blocks"

cleanup_test

echo
echo "======================================"
echo -e "${GREEN}All 28 bash-specific tests passed!${NC}"
echo "======================================"
