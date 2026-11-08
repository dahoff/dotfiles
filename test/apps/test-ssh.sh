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

# Stage the app the way dotfiles does, with a layer (a hosts-repo profile) that adds koi
stage_with_repo_host() {
    mkdir -p "$TEST_HOME/layer/apps/ssh/files"
    { cat files/config; printf '\nHost koi\n    HostName 192.168.1.156\n'; } > "$TEST_HOME/layer/apps/ssh/files/config"
    (
        source "$ROOT_DIR/lib/logging.sh"
        source "$ROOT_DIR/lib/utils.sh"
        source "$ROOT_DIR/lib/overlay.sh"
        overlay_stage_app "$ROOT_DIR/apps/ssh" "$TEST_HOME/stage" /dev/null "$TEST_HOME/layer"
    ) || fail "could not stage"
}

# Test 5: An existing config is merged in, minus hosts the repo has
info "Test 5: Existing ~/.ssh/config is merged into the managed one"
reset_env
mkdir -m 700 "$HOME/.ssh"
cat > "$HOME/.ssh/config" <<'CFG'
# my old config
ServerAliveInterval 30
Include config.local

Host oldbox    #Added by lazyssh
    HostName 10.9.9.9
    User bob
Host KOI
    HostName 10.0.0.99
Host koi spare
    HostName 10.0.0.98
Match host *.lab
    User labuser
CFG
chmod 644 "$HOME/.ssh/config"
./configure.sh install --no-backup &>/dev/null
LIVE="$HOME/.ssh/config"
# The repo copy comes first, unchanged
head -n "$(wc -l < files/config)" "$LIVE" | diff -q - files/config &>/dev/null || fail "repo copy not first in $LIVE"
grep -q "Host oldbox" "$LIVE" || fail "oldbox not merged"
grep -q "Match host \*.lab" "$LIVE" || fail "Match block not merged"
[[ "$(grep -c 'Include config.local' "$LIVE")" == 1 ]] || fail "Include config.local duplicated"
# Options from above the first Host stay global
awk '/^Host \*$/{f=1} f && /ServerAliveInterval 30/{ok=1} END{exit !ok}' "$LIVE" || fail "global option not under Host *"
[[ "$(mode_of "$LIVE")" == 600 && ! -e "$HOME/.ssh/config.local" ]] || fail "mode or config.local wrong"
pass "Old entries appended after the repo copy; globals under Host *; no config.local"

# Test 6: Hosts the repo already has are dropped; a block with any new alias stays
info "Test 6: Hosts already in the repo aren't merged"
reset_env
stage_with_repo_host
mkdir -m 700 "$HOME/.ssh"
printf 'Host koi\n    HostName 10.0.0.99\nHost Koi\n    HostName 10.0.0.97\nHost koi spare\n    HostName 10.0.0.98\nHost newone\n    HostName 10.0.0.5\n' > "$HOME/.ssh/config"
./configure.sh install --no-backup --stage "$TEST_HOME/stage" &>/dev/null
LIVE="$HOME/.ssh/config"
grep -q "10.0.0.99" "$LIVE" && fail "duplicate koi merged"
grep -q "10.0.0.97" "$LIVE" && fail "duplicate Koi (case) merged"
grep -q "Host koi spare" "$LIVE" || fail "block with a new alias dropped"
grep -q "Host newone" "$LIVE" || fail "newone not merged"
[[ "$(ssh -F "$LIVE" -G koi </dev/null 2>/dev/null | awk '/^hostname /{print $2}')" == 192.168.1.156 ]] || fail "repo's koi doesn't win"
pass "Repo aliases dropped (any case); new ones kept; repo entry wins"

# Test 7: A config that already matches the repo is left as it is
info "Test 7: Matching config stays put"
reset_env
mkdir -m 700 "$HOME/.ssh"
cp files/config "$HOME/.ssh/config"
./configure.sh install --no-backup &>/dev/null
if diff -q "$HOME/.ssh/config" files/config &>/dev/null; then
    pass "Nothing appended to an identical file"
else
    fail "Identical config changed"
fi

# Test 8: Dry run changes nothing
info "Test 8: Dry run"
reset_env
mkdir -m 700 "$HOME/.ssh"
printf 'Host oldbox\n' > "$HOME/.ssh/config"
./configure.sh install --dry-run &>/dev/null
if [[ "$(cat "$HOME/.ssh/config")" == "Host oldbox" && ! -e "$HOME/.ssh/config.local" ]]; then
    pass "Dry run left ~/.ssh alone"
else
    fail "Dry run changed ~/.ssh"
fi

# Test 9: An upgrade never merges again
info "Test 9: Only the first install merges"
reset_env
mkdir -m 700 "$HOME/.ssh"
printf 'Host oldbox\n    HostName 10.9.9.9\n' > "$HOME/.ssh/config"
./configure.sh install --no-backup &>/dev/null
./configure.sh upgrade &>/dev/null
[[ "$(grep -c 'Host oldbox' "$HOME/.ssh/config" || true)" == 1 ]] || fail "upgrade merged again, or dropped the merged entries"
pass "No second merge on upgrade"

rm -rf "$TEST_STATE" "$TEST_HOME"

echo
echo "======================================"
echo -e "${GREEN}All 9 ssh module tests passed!${NC}"
echo "======================================"
