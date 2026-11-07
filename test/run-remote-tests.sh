#!/usr/bin/env bash
# run-remote-tests.sh - dotfiles pull --remote and init --remote integration tests (need the Docker test server)

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

# What dotfiles pull --remote uses for ssh/scp
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
# push [--init] ARGS...: pull --remote ARGS, or with --init, init --remote ARGS
push() {
    local verb=pull a
    local -a args=()
    for a in "$@"; do
        if [[ "$a" == --init ]]; then verb=init; else args+=("$a"); fi
    done
    RC=0
    OUT=$("${PUSH_BIN:-./dotfiles}" "$verb" --remote "${args[@]}" 2>&1) || RC=$?
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
printf '%s\n' "$OUT" | grep -qF "[$TARGET] remote: send" || fail "P1: no summary: $OUT"
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
    ./dotfiles pull --remote "$TARGET" 2>&1) || RC=$?
[[ $RC -eq 1 ]] || fail "P5: expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "send FAILED" || fail "P5: no FAILED summary: $OUT"
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

# push --init: a fresh host with no config at all
info "PI1: push --init sets up a fresh host"
test_ssh 'rm -rf ~/.local/share/dotfiles ~/.config/dotfiles ~/.claude ~/.bashrc.d/90-dotfiles.sh ~/.local/bin/dotfiles'
push --dry-run --init --yes --hostname testhost "$TARGET"
[[ $RC -eq 0 ]] || fail "PI1: dry-run exited $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "Would run dotfiles init on $TARGET" || fail "PI1: no 'Would run dotfiles init' line: $OUT"
test_ssh 'test ! -e ~/.local/share/dotfiles && test ! -e ~/.config/dotfiles' || fail "PI1: dry-run changed the remote"
push --init --yes --hostname testhost "$TARGET"
[[ $RC -eq 0 ]] || fail "PI1: push --init exited $RC: $OUT"
CFG=$(test_ssh 'cat ~/.config/dotfiles/config.yaml') || fail "PI1: no remote config"
grep -qx 'hostname: testhost' <<< "$CFG" || fail "PI1: config hostname wrong: $CFG"
grep -qx 'hosts_dir: /home/testuser/.local/share/dotfiles/dotfiles-hosts' <<< "$CFG" || fail "PI1: config hosts_dir wrong: $CFG"
grep -qx 'update_check: on' <<< "$CFG" || fail "PI1: config update_check wrong: $CFG"
[[ "$(test_ssh 'readlink -f ~/.local/bin/dotfiles')" == /home/testuser/.local/share/dotfiles/dotfiles/* ]] \
    || fail "PI1: ~/.local/bin/dotfiles does not link into the pushed checkout"
[[ "$(test_ssh 'cat ~/.claude/statusline-command.sh')" == "# host statusline" ]] || fail "PI1: sync did not run (host statusline missing)"
test_ssh 'test -f ~/.bashrc.d/90-dotfiles.sh' || fail "PI1: remote login drop-in missing"
pass "PI1: config written, self-installed, synced"

info "PI2: push --init again keeps the existing config values as defaults"
# Hand-set an uncommented profile: the same one testhost's host.yaml selects
# (base), so the sync needs nothing extra. The edited file is what init writes.
test_ssh 'sed -i "s/^# profile: .*/profile: base/" ~/.config/dotfiles/config.yaml'
test_ssh 'grep -qx "profile: base" ~/.config/dotfiles/config.yaml' || fail "PI2: setup could not set the profile"
test_ssh 'test ! -e ~/.config/dotfiles/config.yaml.bak' || fail "PI2: config.bak already present before the run"
push --init --yes "$TARGET"
[[ $RC -eq 0 ]] || fail "PI2: push --init exited $RC: $OUT"
CFG2=$(test_ssh 'cat ~/.config/dotfiles/config.yaml')
grep -qx 'hostname: testhost' <<< "$CFG2" || fail "PI2: hostname not kept: $CFG2"
grep -qx 'profile: base' <<< "$CFG2" || fail "PI2: hand-set profile not kept uncommented: $CFG2"
test_ssh 'test ! -e ~/.config/dotfiles/config.yaml.bak' || fail "PI2: config.bak written, so the config changed: $CFG2"
pass "PI2: existing values (hostname, hand-set profile) kept, no config.bak"

info "PI3: push --init with a profile the remote lacks leaves the config alone"
push --init --yes --profile no-such-profile "$TARGET"
[[ $RC -eq 1 ]] || fail "PI3: expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "profile 'no-such-profile' not found" || fail "PI3: not refused by the remote init: $OUT"
[[ "$(test_ssh 'cat ~/.config/dotfiles/config.yaml')" == "$CFG2" ]] || fail "PI3: remote config changed"
pass "PI3: unknown profile refused by the remote init, config unchanged"

info "PI4: push --init without a local hosts dir keeps the remote's configured hosts_dir"
# An empty local config and no default hosts dir under the local HOME: no hosts payload
: > "$T/empty-cfg"
[[ ! -e "$HOME/.local/share/dotfiles/dotfiles-hosts" ]] || fail "PI4: local default hosts dir exists"
grep -qx 'hosts_dir: /home/testuser/.local/share/dotfiles/dotfiles-hosts' <<< "$CFG2" || fail "PI4: setup: remote hosts_dir not set: $CFG2"
DOTFILES_CONFIG="$T/empty-cfg" push --dry-run --init --yes "$TARGET"
[[ $RC -eq 0 ]] || fail "PI4: dry-run exited $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "Would push dotfiles.tar" || fail "PI4: no dotfiles payload planned: $OUT"
! printf '%s\n' "$OUT" | grep -qF "hosts.tar" || fail "PI4: a hosts payload would be shipped: $OUT"
DOTFILES_CONFIG="$T/empty-cfg" push --init --yes "$TARGET"
[[ $RC -eq 0 ]] || fail "PI4: push --init exited $RC: $OUT"
CFG4=$(test_ssh 'cat ~/.config/dotfiles/config.yaml')
[[ "$(grep -v '^# Written by dotfiles init on ' <<< "$CFG4")" == "$(grep -v '^# Written by dotfiles init on ' <<< "$CFG2")" ]] \
    || fail "PI4: remote config changed: was $CFG2, now $CFG4"
test_ssh 'test ! -e ~/.config/dotfiles/config.yaml.bak' || fail "PI4: config.bak written"
pass "PI4: no hosts payload, remote hosts_dir kept"

# The remote has no git (a pushed copy), and the terminal is the one ssh -t gives it. script
# supplies a local terminal; the answers follow after a pause, so the remote is reading.
info "PI5: push --init asks about a reset over ssh -t: no keeps local edits, reset restores the repo's"
test_ssh 'echo "remote local edit" >> ~/.claude/CLAUDE.md; echo mine > ~/.bashrc.d/00-local.sh'
init_tty() {
    RC=0
    # Input sent before the remote has set the terminal up is dropped, so one line at a time
    OUT=$( ( sleep 8; for a in "" "" "" "$@"; do printf '%s\n' "$a"; sleep 2; done; sleep 2 ) \
        | script -qec "${PUSH_BIN:-./dotfiles} init --remote $TARGET" /dev/null 2>&1 ) || RC=$?
}
init_tty ""
[[ $RC -eq 0 ]] || fail "PI5: init --remote exited $RC: $OUT"
grep -qF "Reset every managed file to the repo layers? [no]:" <<< "$OUT" || fail "PI5: no reset question over ssh -t: $OUT"
test_ssh 'grep -qx "remote local edit" ~/.claude/CLAUDE.md' || fail "PI5: an empty answer lost the remote edit"
init_tty yes reset
[[ $RC -eq 0 ]] || fail "PI5: reset exited $RC: $OUT"
grep -qF "~/.claude/CLAUDE.md" <<< "$OUT" || fail "PI5: the lost edit was not listed: $OUT"
test_ssh '! grep -q "remote local edit" ~/.claude/CLAUDE.md' || fail "PI5: the reset left the remote edit"
test_ssh 'grep -rq "remote local edit" ~/.bak/claude' || fail "PI5: no snapshot of the remote edit"
test_ssh 'test "$(cat ~/.bashrc.d/00-local.sh)" = mine' || fail "PI5: 00-local.sh changed"
pass "PI5: the reset question reaches the terminal over ssh -t, and works without git"

echo
echo "======================================"
echo -e "${GREEN}All push tests passed${NC}"
echo "======================================"
