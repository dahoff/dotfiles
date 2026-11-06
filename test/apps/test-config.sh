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

unset DOTFILES_HOSTS_DIR
T="/tmp/dotfiles-test-config"
rm -rf "$T"
mkdir -p "$T/home" "$T/state/apps"
export HOME="$T/home"
export STATE_DIR="$T/state"
export XDG_STATE_HOME="$T/xdg-state"
export DOTFILES_CONFIG="$T/nonexistent-config.yaml"

source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/config.sh"

CFG="$T/config.yaml"
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
   && -z "$CFG_HOSTS_DIR$CFG_HOSTNAME$CFG_PROFILE" ]] || fail "defaults wrong"
pass "defaults"

# Unit 2
info "Unit 2: all keys, ~ expansion"
cat > "$CFG" << 'EOF'
hosts_dir: ~/x
hostname: myhost
profile: minimal
auto_sync: off
auto_sync_interval: 30m
EOF
load
[[ $LOAD_RC -eq 0 && -z "$WARN_OUT" ]] || fail "unexpected rc/output: $LOAD_RC $WARN_OUT"
[[ "$CFG_HOSTS_DIR" == "$HOME/x" && "$CFG_HOSTNAME" == myhost \
   && "$CFG_PROFILE" == minimal && "$CFG_AUTO_SYNC" == off && "$CFG_AUTO_SYNC_INTERVAL" == 30m \
   && "$CFG_FILE" == "$CFG" ]] || fail "values wrong"
pass "all keys parsed"

# Unit 3
info "Unit 3: CRLF and quotes"
printf 'hostname: spaced \r\nprofile: "quoted"\r\nhosts_dir: '"'"'/q/r'"'"'\r\n' > "$CFG"
load
[[ $LOAD_RC -eq 0 && -z "$WARN_OUT" ]] || fail "unexpected rc/output: $LOAD_RC $WARN_OUT"
[[ "$CFG_HOSTNAME" == spaced && "$CFG_PROFILE" == quoted && "$CFG_HOSTS_DIR" == /q/r ]] \
    || fail "clean values wrong: [$CFG_HOSTNAME] [$CFG_PROFILE] [$CFG_HOSTS_DIR]"
pass "CRLF/quotes"

# Unit 4
info "Unit 4: comments and blank lines"
printf '# comment\n\n   # indented comment\n   \nhostname: h1\n' > "$CFG"
load
[[ $LOAD_RC -eq 0 && -z "$WARN_OUT" && "$CFG_HOSTNAME" == h1 ]] || fail "comments not ignored: $WARN_OUT"
printf 'hostname: h1 # trailing\nprofile: p   #x\nhosts_dir: "/a#b" # c\n' > "$CFG"
load
[[ $LOAD_RC -eq 0 && -z "$WARN_OUT" && "$CFG_HOSTNAME" == h1 && "$CFG_PROFILE" == p && "$CFG_HOSTS_DIR" == "/a#b" ]] \
    || fail "trailing comment/quoted #: [$CFG_HOSTNAME] [$CFG_PROFILE] [$CFG_HOSTS_DIR] $WARN_OUT"
printf "profile: 'x#y'\n" > "$CFG"
load
[[ "$CFG_PROFILE" == 'x#y' ]] || fail "# inside single quotes lost: [$CFG_PROFILE]"
printf 'profile: a#b\n' > "$CFG"
load
[[ "$CFG_PROFILE" == 'a#b' ]] || fail "# without leading space is not a comment: [$CFG_PROFILE]"
printf 'profile: a # b # c\n' > "$CFG"
load
[[ "$CFG_PROFILE" == a ]] || fail "comment must start at the first ' #': [$CFG_PROFILE]"
printf 'auto_sync_interval: 4h  # every 4h # was 1h\n' > "$CFG"
load
[[ $LOAD_RC -eq 0 && "$CFG_AUTO_SYNC_INTERVAL" == 4h ]] || fail "interval with two # comments: rc=$LOAD_RC"
pass "comments ignored, # in quotes kept"

# Unit 4b
info "Unit 4b: a value containing ': ' is kept whole"
printf 'profile: a: b\nhosts_dir: "/p: q"\n' > "$CFG"
load
[[ "$CFG_PROFILE" == 'a: b' && "$CFG_HOSTS_DIR" == '/p: q' && -z "$WARN_OUT" ]] \
    || fail "first ': ' only: [$CFG_PROFILE] [$CFG_HOSTS_DIR] $WARN_OUT"
pass "value with ': '"

# Unit 4c
info "Unit 4c: auto_sync boolean spellings normalize"
for pair in on:on off:off true:on false:off yes:on no:off; do
    printf 'auto_sync: %s\n' "${pair%%:*}" > "$CFG"
    load
    [[ $LOAD_RC -eq 0 && "$CFG_AUTO_SYNC" == "${pair##*:}" ]] || fail "auto_sync ${pair%%:*} -> [$CFG_AUTO_SYNC] rc=$LOAD_RC"
done
pass "auto_sync normalized"

# Unit 5
info "Unit 5: unknown keys warn (including the removed dotfiles_repo and hosts_repo)"
printf 'hostname: h1\nbogus: 1\ndotfiles_repo: /x\nhosts_repo: /y\n' > "$CFG"
load
[[ $LOAD_RC -eq 0 && "$WARN_OUT" == *"$CFG:2: ignoring unknown key 'bogus': bogus: 1"* ]] \
    || fail "no unknown-key warning: $WARN_OUT"
[[ "$WARN_OUT" == *"$CFG:3: ignoring unknown key 'dotfiles_repo'"* ]] || fail "dotfiles_repo not warned: $WARN_OUT"
[[ "$WARN_OUT" == *"$CFG:4: ignoring unknown key 'hosts_repo'"* ]] || fail "hosts_repo not warned: $WARN_OUT"
[[ "$CFG_HOSTNAME" == h1 && -z "$CFG_HOSTS_DIR" ]] || fail "other keys lost or hosts_repo honored"
pass "unknown keys warned"

# Unit 6
info "Unit 6: malformed, indented and list lines warn"
printf 'hostname: h1\njust words\nBad-Key: 1\n  profile: x\n- item\n' > "$CFG"
load
[[ "$WARN_OUT" == *"$CFG:2: ignoring line without 'key: value': just words"* ]] || fail "no colon warning: $WARN_OUT"
[[ "$WARN_OUT" == *"$CFG:3: ignoring malformed line: Bad-Key: 1"* ]] || fail "no malformed warning: $WARN_OUT"
[[ "$WARN_OUT" == *"$CFG:4: ignoring indented line or list item"* ]] || fail "no indented warning: $WARN_OUT"
[[ "$WARN_OUT" == *"$CFG:5: ignoring indented line or list item"* ]] || fail "no list-item warning: $WARN_OUT"
[[ -z "$CFG_PROFILE" && "$CFG_HOSTNAME" == h1 ]] || fail "indented line was applied"
[[ $LOAD_RC -eq 0 ]] || fail "warnings should not fail"
pass "malformed lines warned"

# Unit 7/8
info "Unit 7/8: invalid auto_sync and interval"
printf 'auto_sync: maybe\n' > "$CFG"
load
[[ $LOAD_RC -eq 1 ]] || fail "auto_sync maybe should return 1"
printf 'auto_sync_interval: 10x\n' > "$CFG"
load
[[ $LOAD_RC -eq 1 ]] || fail "interval 10x should return 1"
pass "invalid values rejected"

# Unit 8b
info "Unit 8b: invalid hostname value"
for bad in 'a/b' '.' '..' ''; do
    printf 'hostname: "%s"\n' "$bad" > "$CFG"
    load
    [[ $LOAD_RC -eq 1 ]] || fail "hostname='$bad' should return 1"
done
printf 'hostname: good-name\n' > "$CFG"
load
[[ $LOAD_RC -eq 0 && "$CFG_HOSTNAME" == good-name ]] || fail "valid hostname rejected"
pass "invalid hostname rejected"

# Unit 9
info "Unit 9: config_interval_seconds"
[[ "$(config_interval_seconds 30m)" == 1800 && "$(config_interval_seconds 4h)" == 14400 \
   && "$(config_interval_seconds 2d)" == 172800 ]] || fail "seconds wrong"
for bad in h 0x ""; do
    ! config_interval_seconds "$bad" >/dev/null || fail "'$bad' should fail"
done
pass "interval seconds"

# Integration: dotfiles pull --dry-run
echo
info "Integration: precedence in dotfiles"
HR="$T/hosts-dir"
cp -R "$TEST_DIR/fixtures/hosts-dir" "$HR"
cd "$ROOT_DIR"

run() {
    RC=0
    OUT=$(./dotfiles pull --dry-run "$@" 2>&1) || RC=$?
}
fresh_home() {
    rm -rf "$T/home" "$T/state"
    mkdir -p "$T/home" "$T/state/apps"
}

fresh_home
printf 'hosts_dir: %s\nhostname: testhost\n' "$HR" > "$DOTFILES_CONFIG"
run
[[ $RC -eq 0 && "$OUT" == *"Using profile 'base'"* ]] || fail "config hosts_dir+hostname: $OUT"
pass "config hosts_dir + hostname"

run --hostname excludehost
[[ $RC -eq 0 && "$OUT" == *"Host directory: hosts/excludehost"* ]] || fail "flag hostname should win: $OUT"
pass "flag beats config hostname"

printf 'hosts_dir: /nonexistent\n' > "$DOTFILES_CONFIG"
DOTFILES_HOSTS_DIR="$HR" run --hostname testhost
[[ $RC -eq 0 && "$OUT" == *"Using profile 'base'"* ]] || fail "env should beat config: $OUT"
pass "env beats config hosts_dir"

rm -f "$DOTFILES_CONFIG"
fresh_home
mkdir -p "$HOME/.local/share/dotfiles"
cp -R "$TEST_DIR/fixtures/hosts-dir" "$HOME/.local/share/dotfiles/dotfiles-hosts"
run --hostname testhost
[[ $RC -eq 0 && "$OUT" == *"Using profile 'base'"* ]] || fail "default hosts dir not used: $OUT"
pass "default hosts dir path"

fresh_home
printf 'profile: minimal\n' > "$DOTFILES_CONFIG"
run --hostname nosuchhost
[[ $RC -eq 0 && "$OUT" == *"Using profile 'minimal'"* ]] || fail "config profile: $OUT"
pass "config profile"

printf 'hosts_dir: /nonexistent\n' > "$DOTFILES_CONFIG"
run
[[ $RC -ne 0 && "$OUT" == *"Hosts dir not found"* ]] || fail "bad hosts_dir: rc=$RC $OUT"
pass "nonexistent hosts_dir aborts"

rm -rf "$T"
echo
pass "All config tests passed"
