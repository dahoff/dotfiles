#!/usr/bin/env bash
# test-ssh.sh - SSH client config module tests

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
echo "SSH Module Tests"
echo "======================================"
echo

TEST_STATE="/tmp/dotfiles-test-sshtest"
TEST_HOME="/tmp/home-test-sshtest"

# A fresh state and home for each scenario
reset_env() {
    rm -rf "$TEST_STATE" "$TEST_HOME"
    mkdir -p "$TEST_STATE/apps" "$TEST_HOME"
    export STATE_DIR="$TEST_STATE"
    export HOME="$TEST_HOME"
    export XDG_STATE_HOME="$TEST_HOME/.xdg-state"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

reset_env
cd "$ROOT_DIR/apps/ssh"

# Test 1: The public stub has no hosts and Includes config.local
info "Test 1: Public config is a stub that Includes config.local"
if grep -qx "Include config.local" files/config && ! grep -qiE '^[[:space:]]*(Host|Match)[[:space:]]' files/config; then
    pass "Stub Includes config.local and defines no hosts"
else
    fail "Stub should Include config.local and define no hosts"
fi

# Test 2: ssh can read the stub, even with config.local missing
info "Test 2: ssh parses the stub"
if command -v ssh >/dev/null 2>&1; then
    if ssh -F files/config -G example.invalid </dev/null >/dev/null 2>&1; then
        pass "ssh -G accepts the stub"
    else
        fail "ssh -G rejected the stub"
    fi
else
    info "ssh not installed; skipped"
fi

# Test 3: Fresh install creates a private ~/.ssh and a 0600 config
info "Test 3: Fresh install"
./configure.sh install --no-backup &>/dev/null
if diff -q "$HOME/.ssh/config" files/config &>/dev/null \
    && [[ "$(mode_of "$HOME/.ssh/config")" == 600 ]] \
    && [[ "$(mode_of "$HOME/.ssh")" == 700 ]] \
    && [[ ! -e "$HOME/.ssh/config.local" ]]; then
    pass "Config deployed 0600 in a 0700 ~/.ssh; no config.local created"
else
    fail "Fresh install: unexpected state"
fi

# Test 4: Uninstall removes the config
info "Test 4: Uninstall"
./configure.sh uninstall &>/dev/null
if [[ ! -f "$HOME/.ssh/config" ]]; then
    pass "Config removed on uninstall"
else
    fail "Config not removed on uninstall"
fi

# Test 5: An existing config is kept as config.local
info "Test 5: Existing ~/.ssh/config becomes config.local"
reset_env
mkdir -m 700 "$HOME/.ssh"
printf 'Host oldbox\n    HostName 10.9.9.9\n' > "$HOME/.ssh/config"
chmod 644 "$HOME/.ssh/config"
./configure.sh install --no-backup &>/dev/null
if grep -q "Host oldbox" "$HOME/.ssh/config.local" \
    && [[ "$(mode_of "$HOME/.ssh/config.local")" == 600 ]] \
    && diff -q "$HOME/.ssh/config" files/config &>/dev/null; then
    pass "Old hosts kept in config.local (0600); managed config deployed"
else
    fail "Existing config not preserved"
fi

# Test 6: A second install (after uninstall) doesn't clobber config.local
info "Test 6: Existing config.local is never overwritten"
./configure.sh uninstall &>/dev/null
printf 'Host other\n    HostName 10.8.8.8\n' > "$HOME/.ssh/config"
./configure.sh install --no-backup &>/dev/null
if grep -q "Host oldbox" "$HOME/.ssh/config.local" && ! grep -q "Host other" "$HOME/.ssh/config.local"; then
    pass "config.local left alone"
else
    fail "config.local was changed"
fi

# Test 7: A config that already matches the repo isn't moved
info "Test 7: Matching config stays put"
reset_env
mkdir -m 700 "$HOME/.ssh"
cp files/config "$HOME/.ssh/config"
./configure.sh install --no-backup &>/dev/null
if [[ ! -e "$HOME/.ssh/config.local" ]] && diff -q "$HOME/.ssh/config" files/config &>/dev/null; then
    pass "No config.local made from an identical file"
else
    fail "Identical config was moved"
fi

# Test 8: Dry run changes nothing
info "Test 8: Dry run"
reset_env
mkdir -m 700 "$HOME/.ssh"
printf 'Host oldbox\n' > "$HOME/.ssh/config"
./configure.sh install --dry-run &>/dev/null
if [[ ! -e "$HOME/.ssh/config.local" ]] && grep -q "Host oldbox" "$HOME/.ssh/config"; then
    pass "Dry run left ~/.ssh alone"
else
    fail "Dry run changed ~/.ssh"
fi

rm -rf "$TEST_STATE" "$TEST_HOME"

echo
echo "======================================"
echo -e "${GREEN}All 8 ssh module tests passed!${NC}"
echo "======================================"
