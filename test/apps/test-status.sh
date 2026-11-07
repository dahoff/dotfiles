#!/usr/bin/env bash
# test-status.sh - dotfiles status: read-only summary

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
echo "Status Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR
T="/tmp/dotfiles-test-status-$$"
trap 'rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home" "$T/state/apps"
export HOME="$T/home"
export STATE_DIR="$T/state"
export XDG_STATE_HOME="$T/xdg-state"
export DOTFILES_CONFIG="$T/config"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
: > "$GIT_CONFIG_GLOBAL"

cp -R "$TEST_DIR/fixtures/hosts-dir" "$T/hosts-dir"
cat > "$T/config" <<CFG
hosts_dir: $T/hosts-dir
hostname: testhost
CFG
cd "$ROOT_DIR"

OUT=""
RC=0
run() {
    RC=0
    OUT=$(./dotfiles "$@" 2>&1) || RC=$?
}
# Assert OUT contains the given text
has_line() {
    printf '%s\n' "$OUT" | grep -qF -- "$1" || fail "missing '$1' in: $OUT"
}

info "Case 1: before any sync"
run status
[[ $RC -eq 0 ]] || fail "status failed: $OUT"
has_line "claude    not installed"
has_line "update check:    on, every 4h — never run"
has_line "pending:         none"
has_line "host:            testhost  (hosts/testhost/host.yaml)   profile: base"
has_line "config:          $T/config"
has_line "hosts dir:       $T/hosts-dir  (not a git checkout)"
pass "fresh status"

info "Case 4: dotfiles repo shows git branch and sha"
has_line "dotfiles repo:   $ROOT_DIR  (git "
pass "git checkout described"

info "Case 6: status writes nothing"
MARK="$T/marker"
touch "$MARK"
sleep 1
run status
[[ $RC -eq 0 ]] || fail "status failed: $OUT"
CHANGED=$(find "$T/state" "$T/home" -newer "$MARK" 2>/dev/null || true)
[[ -z "$CHANGED" ]] || fail "status changed files: $CHANGED"
[[ ! -e "$T/xdg-state" ]] || fail "status created the state dir"
pass "read-only"

info "Case 2: after sync"
RC=0
OUT=$(./dotfiles pull --no-backup --skip-git-setup --no-fetch 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
run status
has_line "claude    up to date"
has_line "scripts   up to date"
has_line "update check:    on, every 4h — never run"
touch "$XDG_STATE_HOME/dotfiles/last-check"
run status
has_line "update check:    on, every 4h — last run just now"
touch -d '3 hours ago' "$XDG_STATE_HOME/dotfiles/last-check"
run status
has_line "update check:    on, every 4h — last run 3h ago"
echo "update_check: off" >> "$T/config"
run status
has_line "update check:    off"
sed -i '/^update_check: off$/d' "$T/config"
pass "up to date after sync; update check shows its own last run"

info "Case 3: host layer edit"
echo '{"edited": true}' > "$T/hosts-dir/hosts/testhost/apps/claude/files/settings.json"
run status
has_line "claude    update available"
has_line "scripts   up to date"
pass "update available"

info "Case 5: pushed copy"
echo "source=koi commit=abc1234" > "$T/hosts-dir/PUSHED"
run status
has_line "(pushed: source=koi"
pass "PUSHED file shown"

info "Case 7: missing config, pending list, bad profile"
rm "$T/config"
run status --hosts-dir "$T/hosts-dir" --hostname testhost
[[ $RC -eq 0 ]] || fail "status failed: $OUT"
has_line "(not found, using defaults)"
printf 'a\nb\n' > "$XDG_STATE_HOME/dotfiles/pending"
run status --hosts-dir "$T/hosts-dir" --profile nonexistent-profile
[[ $RC -eq 0 ]] || fail "bad profile must exit 0: $OUT"
has_line "pending:         a, b"
has_line "dotfiles repo:"
pass "tolerates missing config and bad profile"

echo
echo "All status tests passed"
