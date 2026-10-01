#!/usr/bin/env bash
# test-config.sh - lib/config.sh unit tests and config/flag/env precedence in dotfiles

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
echo "Config File Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_REPO
T="/tmp/dotfiles-test-config"
rm -rf "$T"
mkdir -p "$T/home" "$T/state/apps"
export HOME="$T/home"
export STATE_DIR="$T/state"
export XDG_STATE_HOME="$T/xdg-state"
export DOTFILES_CONFIG="$T/nonexistent-config"

source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/config.sh"

CFG="$T/config"
WARN_OUT=""
# Load $CFG, capturing log output in WARN_OUT and the return code in LOAD_RC
load() {
    LOAD_RC=0
    WARN_OUT=$(config_load "$CFG" 2>&1) || LOAD_RC=$?
    # Re-run in this shell so the globals are set (output discarded)
    config_load "$CFG" >/dev/null 2>&1 || true
}

# Unit 1
info "Unit 1: missing file gives defaults"
config_load "$T/nope"
[[ $? -eq 0 && "$CFG_AUTO_SYNC" == on && "$CFG_AUTO_SYNC_INTERVAL" == 4h \
   && -z "$CFG_DOTFILES_REPO$CFG_HOSTS_REPO$CFG_HOSTNAME$CFG_PROFILE" ]] || fail "defaults wrong"
pass "defaults"

# Unit 2
info "Unit 2: all keys, ~ expansion"
cat > "$CFG" << 'EOF'
dotfiles_repo=~/x
hosts_repo=/srv/hosts
hostname=myhost
profile=minimal
auto_sync=off
auto_sync_interval=30m
EOF
load
[[ $LOAD_RC -eq 0 && -z "$WARN_OUT" ]] || fail "unexpected rc/output: $LOAD_RC $WARN_OUT"
[[ "$CFG_DOTFILES_REPO" == "$HOME/x" && "$CFG_HOSTS_REPO" == /srv/hosts && "$CFG_HOSTNAME" == myhost \
   && "$CFG_PROFILE" == minimal && "$CFG_AUTO_SYNC" == off && "$CFG_AUTO_SYNC_INTERVAL" == 30m \
   && "$CFG_FILE" == "$CFG" ]] || fail "values wrong"
pass "all keys parsed"

# Unit 3
info "Unit 3: CRLF, spaces and quotes"
printf 'hostname = spaced \r\nprofile="quoted"\r\nhosts_repo='"'"'/q/r'"'"'\r\n' > "$CFG"
load
[[ $LOAD_RC -eq 0 && -z "$WARN_OUT" ]] || fail "unexpected rc/output: $LOAD_RC $WARN_OUT"
[[ "$CFG_HOSTNAME" == spaced && "$CFG_PROFILE" == quoted && "$CFG_HOSTS_REPO" == /q/r ]] \
    || fail "clean values wrong: [$CFG_HOSTNAME] [$CFG_PROFILE] [$CFG_HOSTS_REPO]"
pass "CRLF/spaces/quotes"

# Unit 4
info "Unit 4: comments and blank lines"
printf '# comment\n\n   # indented comment\n   \nhostname=h1\n' > "$CFG"
load
[[ $LOAD_RC -eq 0 && -z "$WARN_OUT" && "$CFG_HOSTNAME" == h1 ]] || fail "comments not ignored: $WARN_OUT"
pass "comments ignored"

# Unit 5
info "Unit 5: unknown key warns"
printf 'hostname=h1\nbogus=1\n' > "$CFG"
load
[[ $LOAD_RC -eq 0 && "$WARN_OUT" == *"$CFG:2: ignoring unknown key 'bogus': bogus=1"* ]] \
    || fail "no unknown-key warning: $WARN_OUT"
[[ "$CFG_HOSTNAME" == h1 ]] || fail "other keys lost"
pass "unknown key warned"

# Unit 6
info "Unit 6: line without = warns"
printf 'hostname=h1\njust words\nBad-Key=1\n' > "$CFG"
load
[[ "$WARN_OUT" == *"$CFG:2: ignoring line without '=': just words"* ]] || fail "no '=' warning: $WARN_OUT"
[[ "$WARN_OUT" == *"$CFG:3: ignoring malformed line: Bad-Key=1"* ]] || fail "no malformed warning: $WARN_OUT"
[[ $LOAD_RC -eq 0 ]] || fail "warnings should not fail"
pass "malformed lines warned"

# Unit 7/8
info "Unit 7/8: invalid auto_sync and interval"
printf 'auto_sync=maybe\n' > "$CFG"
load
[[ $LOAD_RC -eq 1 ]] || fail "auto_sync=maybe should return 1"
printf 'auto_sync_interval=10x\n' > "$CFG"
load
[[ $LOAD_RC -eq 1 ]] || fail "interval 10x should return 1"
pass "invalid values rejected"

# Unit 9
info "Unit 9: config_interval_seconds"
[[ "$(config_interval_seconds 30m)" == 1800 && "$(config_interval_seconds 4h)" == 14400 \
   && "$(config_interval_seconds 2d)" == 172800 ]] || fail "seconds wrong"
for bad in h 0x ""; do
    ! config_interval_seconds "$bad" >/dev/null || fail "'$bad' should fail"
done
pass "interval seconds"

# Integration: dotfiles sync --dry-run
echo
info "Integration: precedence in dotfiles"
HR="$T/hosts-repo"
cp -R "$TEST_DIR/fixtures/hosts-repo" "$HR"
cd "$ROOT_DIR"

run() {
    RC=0
    OUT=$(./dotfiles sync --dry-run "$@" 2>&1) || RC=$?
}
fresh_home() {
    rm -rf "$T/home" "$T/state"
    mkdir -p "$T/home" "$T/state/apps"
}

fresh_home
printf 'hosts_repo=%s\nhostname=testhost\n' "$HR" > "$DOTFILES_CONFIG"
run
[[ $RC -eq 0 && "$OUT" == *"Using profile 'base'"* ]] || fail "config hosts_repo+hostname: $OUT"
pass "config hosts_repo + hostname"

run --hostname excludehost
[[ $RC -eq 0 && "$OUT" == *"Host directory: hosts/excludehost"* ]] || fail "flag hostname should win: $OUT"
pass "flag beats config hostname"

printf 'hosts_repo=/nonexistent\n' > "$DOTFILES_CONFIG"
DOTFILES_HOSTS_REPO="$HR" run --hostname testhost
[[ $RC -eq 0 && "$OUT" == *"Using profile 'base'"* ]] || fail "env should beat config: $OUT"
pass "env beats config hosts_repo"

rm -f "$DOTFILES_CONFIG"
fresh_home
mkdir -p "$HOME/.local/share/dotfiles"
cp -R "$TEST_DIR/fixtures/hosts-repo" "$HOME/.local/share/dotfiles/dotfiles-hosts"
run --hostname testhost
[[ $RC -eq 0 && "$OUT" == *"Using profile 'base'"* ]] || fail "default hosts repo not used: $OUT"
pass "default hosts repo path"

fresh_home
printf 'profile=minimal\n' > "$DOTFILES_CONFIG"
run --hostname nosuchhost
[[ $RC -eq 0 && "$OUT" == *"Using profile 'minimal'"* ]] || fail "config profile: $OUT"
pass "config profile"

printf 'hosts_repo=/nonexistent\n' > "$DOTFILES_CONFIG"
run
[[ $RC -ne 0 && "$OUT" == *"Hosts repo not found"* ]] || fail "bad hosts_repo: rc=$RC $OUT"
pass "nonexistent hosts_repo aborts"

printf 'dotfiles_repo=/nonexistent\n' > "$DOTFILES_CONFIG"
run
[[ $RC -ne 0 && "$OUT" == *"dotfiles repo not found: /nonexistent"* ]] || fail "bad dotfiles_repo: rc=$RC $OUT"
pass "nonexistent dotfiles_repo aborts"

printf 'dotfiles_repo=%s\nprofile=minimal\n' "$T" > "$DOTFILES_CONFIG"
run --hostname nosuchhost
[[ $RC -eq 0 && "$OUT" == *"Running $ROOT_DIR/dotfiles but config dotfiles_repo is $T"* ]] \
    || fail "different dotfiles_repo should warn and continue: rc=$RC $OUT"
pass "different dotfiles_repo warns"

rm -rf "$T"
echo
pass "All config tests passed"
