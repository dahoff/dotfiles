#!/usr/bin/env bash
# run-remote-tests.sh - dotfiles push integration tests (need the Docker test server)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

# SSH config for test server
SSH_KEY="$SCRIPT_DIR/ssh-key"
SSH_HOST="localhost"
SSH_PORT="2222"
SSH_USER="testuser"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Helper function to SSH into test server
test_ssh() {
    ssh $SSH_OPTS -i "$SSH_KEY" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$@"
}

# What dotfiles push uses for ssh/scp
export DOTFILES_SSH_OPTS="-o Port=$SSH_PORT -o IdentityFile=$SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
TARGET="$SSH_USER@$SSH_HOST"

echo "======================================"
echo "Push Tests (Docker)"
echo "======================================"
echo

# Test 0: Verify test environment is running
info "Test 0: Checking test environment"
# Capture first: grep -q under pipefail can kill docker with SIGPIPE
PS_OUT=$(docker ps 2>&1) || true
if ! grep -q dotfiles-test-server <<< "$PS_OUT"; then
    fail "Test server is not running (run: cd test && ./setup-test-env.sh)"
fi
pass "Test server is running"

if ! test_ssh "echo test" &>/dev/null; then
    fail "Cannot connect to test server"
fi
pass "SSH connection working"
echo

# Local side: sandboxed HOME and config; the hosts repo is a fixture copy
T="/tmp/dotfiles-test-remote-$$"
trap 'rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home"
cp -R "$SCRIPT_DIR/fixtures/hosts-dir" "$T/hosts-dir"
printf 'hosts_dir: %s\n' "$T/hosts-dir" > "$T/push-cfg"
unset DOTFILES_HOSTS_DIR
export HOME="$T/home"
export XDG_STATE_HOME="$T/xdg-state"
export STATE_DIR="$T/state"
export DOTFILES_CONFIG="$T/push-cfg"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
: > "$GIT_CONFIG_GLOBAL"

OUT=""
RC=0
push() {
    RC=0
    OUT=$("${PUSH_BIN:-./dotfiles}" push "$@" 2>&1) || RC=$?
}

WORKTREE_COMMIT=$(git -C "$ROOT_DIR" rev-parse HEAD)

# The remote profile is config-only (base: claude + scripts), so the sync that
# push runs never needs sudo
reset_remote() {
    # The config uses comments, spaces, tabs, quotes and CRLF line ends, and puts
    # the hosts dir at a non-default path: push must read it like config_load
    test_ssh 'rm -rf ~/.local/share/dotfiles ~/dh-custom ~/alt ~/.local/bin/dotfiles ~/.bashrc.d ~/.config/dotfiles ~/.claude ~/.local/state/dotfiles
        mkdir -p ~/.config/dotfiles ~/.claude
        printf "# hosts_dir: /nope\r\n\r\nhostname: testhost\r\nhosts_dir: \"~/dh-custom\"  # comment\r\n" > ~/.config/dotfiles/config.yaml
        printf "{\"liveOnly\":1}\n" > ~/.claude/settings.json'
}

info "P1: first push to a fresh container"
reset_remote
push "$TARGET"
[[ $RC -eq 0 ]] || fail "P1: push exited $RC: $OUT"
test_ssh 'test -x ~/.local/share/dotfiles/dotfiles/dotfiles' || fail "P1: remote dotfiles missing"
test_ssh 'test -f ~/dh-custom/hosts/testhost/host.yaml' || fail "P1: hosts repo not at the path from the spaced/quoted/CRLF config"
test_ssh 'test ! -e ~/.local/share/dotfiles/dotfiles-hosts' || fail "P1: hosts repo also at the default path"
test_ssh 'grep -q "commit='"$WORKTREE_COMMIT"'" ~/.local/share/dotfiles/dotfiles/PUSHED' || fail "P1: PUSHED has no commit"
test_ssh 'grep -q "^source=" ~/dh-custom/PUSHED' || fail "P1: hosts PUSHED missing"
[[ "$(test_ssh 'jq .liveOnly ~/.claude/settings.json')" == "1" ]] || fail "P1: live key lost"
[[ "$(test_ssh 'jq -r .hostKey ~/.claude/settings.json')" == "testhost" ]] || fail "P1: host overlay not applied"
[[ "$(test_ssh 'cat ~/.claude/statusline-command.sh')" == "# host statusline" ]] || fail "P1: host statusline not deployed"
test_ssh 'test -L ~/.local/bin/dotfiles' || fail "P1: remote not self-installed (~/.local/bin/dotfiles)"
test_ssh 'test -f ~/.bashrc.d/90-dotfiles.sh' || fail "P1: remote login drop-in missing"
printf '%s\n' "$OUT" | grep -qF "[$TARGET] push: push" || fail "P1: no summary: $OUT"
pass "P1: repos shipped, configs deployed, self-install ran remotely"

info "P2: second push replaces the trees (removed file is gone)"
mkdir -p "$T/plain"
tar -C "$ROOT_DIR" --exclude=./.git --exclude=./.claude --exclude=./.superpowers -cf - . | tar -x -C "$T/plain"
touch "$T/plain/EXTRA"
PUSH_BIN="$T/plain/dotfiles" push "$TARGET"
[[ $RC -eq 0 ]] || fail "P2: push from the plain copy exited $RC: $OUT"
test_ssh 'test -e ~/.local/share/dotfiles/dotfiles/EXTRA' || fail "P2: EXTRA was not shipped from the plain copy"
test_ssh 'grep -q "commit=none" ~/.local/share/dotfiles/dotfiles/PUSHED' || fail "P2: plain copy PUSHED should say commit=none"
push "$TARGET"
[[ $RC -eq 0 ]] || fail "P2: push exited $RC: $OUT"
test_ssh 'test ! -e ~/.local/share/dotfiles/dotfiles/EXTRA' || fail "P2: EXTRA still on the remote"
test_ssh 'grep -q "commit='"$WORKTREE_COMMIT"'" ~/.local/share/dotfiles/dotfiles/PUSHED' || fail "P2: PUSHED does not show the worktree commit"
test_ssh 'test ! -e ~/.local/share/dotfiles/dotfiles.old && test ! -e ~/.local/share/dotfiles/dotfiles.new' || fail "P2: leftover .old/.new"
pass "P2: trees replaced, no leftovers"

info "P3: refuses a remote git checkout"
test_ssh 'mkdir -p ~/.local/share/dotfiles/dotfiles/.git && touch ~/.local/share/dotfiles/dotfiles/KEEP'
BEFORE=$(test_ssh 'ls -A ~/.local/share/dotfiles/dotfiles | sort | tr "\n" " "')
push "$TARGET"
[[ $RC -eq 1 ]] || fail "P3: expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "is a git checkout" || fail "P3: no refusal message: $OUT"
AFTER=$(test_ssh 'ls -A ~/.local/share/dotfiles/dotfiles | sort | tr "\n" " "')
[[ "$BEFORE" == "$AFTER" ]] || fail "P3: remote dir changed"
test_ssh 'rm -rf ~/.local/share/dotfiles/dotfiles/.git ~/.local/share/dotfiles/dotfiles/KEEP'
pass "P3: refused, remote unchanged"

info "P4: --dry-run changes nothing"
push "$TARGET"
[[ $RC -eq 0 ]] || fail "P4: setup push exited $RC: $OUT"
MTIME_BEFORE=$(test_ssh 'stat -c %Y ~/.local/share/dotfiles/dotfiles/PUSHED')
LISTING_BEFORE=$(test_ssh 'ls -A ~/.local/share/dotfiles ~/.local/share/dotfiles/dotfiles | sort | tr "\n" " "')
sleep 1
push --dry-run "$TARGET"
[[ $RC -eq 0 ]] || fail "P4: dry-run exited $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "Would push" || fail "P4: no 'Would push' line: $OUT"
MTIME_AFTER=$(test_ssh 'stat -c %Y ~/.local/share/dotfiles/dotfiles/PUSHED')
LISTING_AFTER=$(test_ssh 'ls -A ~/.local/share/dotfiles ~/.local/share/dotfiles/dotfiles | sort | tr "\n" " "')
[[ "$MTIME_BEFORE" == "$MTIME_AFTER" && "$LISTING_BEFORE" == "$LISTING_AFTER" ]] || fail "P4: dry-run changed the remote"
pass "P4: dry-run printed the plan and changed nothing"

info "P5: unreachable host"
RC=0
OUT=$(DOTFILES_SSH_OPTS="-o Port=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    ./dotfiles push "$TARGET" 2>&1) || RC=$?
[[ $RC -eq 1 ]] || fail "P5: expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "push FAILED" || fail "P5: no FAILED summary: $OUT"
pass "P5: unreachable host fails with a summary"

info "P6: refuses to replace a foreign (non-pushed, non-git) directory"
push "$TARGET"
[[ $RC -eq 0 ]] || fail "P6: setup push exited $RC: $OUT"
test_ssh 'rm -rf ~/dh-custom && mkdir -p ~/dh-custom && echo precious > ~/dh-custom/keep.txt'
push "$TARGET"
[[ $RC -eq 1 ]] || fail "P6: expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "exists and is not a pushed dotfiles copy; refusing to replace it" || fail "P6: no refusal message: $OUT"
test_ssh 'test -f ~/dh-custom/keep.txt' || fail "P6: keep.txt was destroyed"
push --dry-run "$TARGET"
[[ $RC -eq 1 ]] || fail "P6: dry-run should refuse too, got $RC: $OUT"
test_ssh 'rm -rf ~/dh-custom'
push "$TARGET"
[[ $RC -eq 0 ]] || fail "P6: push after cleanup exited $RC: $OUT"
pass "P6: foreign directory refused and left intact"

info "P7: the remote dotfiles checkout is found through its ~/.local/bin/dotfiles link"
reset_remote
test_ssh 'mkdir -p ~/alt/dotfiles/lib ~/.local/bin
    echo old > ~/alt/dotfiles/PUSHED
    printf "#!/bin/sh\n" > ~/alt/dotfiles/dotfiles && chmod +x ~/alt/dotfiles/dotfiles
    ln -s ~/alt/dotfiles/dotfiles ~/.local/bin/dotfiles'
push "$TARGET"
[[ $RC -eq 0 ]] || fail "P7: push exited $RC: $OUT"
test_ssh 'test -f ~/alt/dotfiles/lib/config.sh' || fail "P7: dotfiles not unpacked into ~/alt/dotfiles"
test_ssh 'grep -q "commit='"$WORKTREE_COMMIT"'" ~/alt/dotfiles/PUSHED' || fail "P7: PUSHED not refreshed in ~/alt/dotfiles"
test_ssh 'test ! -e ~/.local/share/dotfiles/dotfiles' || fail "P7: dotfiles also shipped to the default path"
[[ "$(test_ssh 'readlink ~/.local/bin/dotfiles')" == "$(test_ssh 'echo ~/alt/dotfiles/dotfiles')" ]] || fail "P7: the link was re-pointed"
test_ssh 'test -f ~/dh-custom/hosts/testhost/host.yaml' || fail "P7: hosts dir not at the config.yaml path"
pass "P7: pushed into the checkout the link points to"

echo
echo "======================================"
echo -e "${GREEN}All push tests passed${NC}"
echo "======================================"
