#!/usr/bin/env bash
# test-push.sh - dotfiles push: local cases (the Docker cases are in run-remote-tests.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$TEST_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

echo "======================================"
echo "Push Tests (local)"
echo "======================================"
echo

unset DOTFILES_HOSTS_REPO
T="/tmp/dotfiles-test-push-$$"
trap 'rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home"
export HOME="$T/home"
export STATE_DIR="$T/state"
export XDG_STATE_HOME="$T/xdg-state"
export DOTFILES_CONFIG="$T/config"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
: > "$DOTFILES_CONFIG"
cd "$ROOT_DIR"

OUT=""
RC=0
run() {
    RC=0
    OUT=$(./dotfiles "$@" 2>&1) || RC=$?
}

info "Case 1: no HOST is a usage error"
run push
[[ $RC -eq 1 ]] || fail "expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "Usage: dotfiles push" || fail "no usage message: $OUT"
pass "push without HOST: usage error"

info "Case 2: unreachable hosts fail and are summarized; the next host still runs"
export DOTFILES_SSH_OPTS="-o Port=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run push testuser@localhost otheruser@localhost
[[ $RC -eq 1 ]] || fail "expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "[testuser@localhost] push: push FAILED" || fail "no FAILED summary for first host: $OUT"
printf '%s\n' "$OUT" | grep -qF "[otheruser@localhost] push: push FAILED" || fail "second host not attempted: $OUT"
pass "unreachable hosts: exit 1, per-host FAILED summary"

info "Case 3: push takes no lock and writes no local state"
[[ ! -e "$T/xdg-state/dotfiles/lock" && ! -e "$T/xdg-state/dotfiles/last-sync" ]] \
    || fail "push touched local state"
[[ ! -e "$T/home/.local/bin/dotfiles" ]] || fail "push self-installed locally"
pass "no local state"

echo
echo -e "${GREEN}All push tests passed${NC}"
