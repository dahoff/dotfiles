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

unset DOTFILES_HOSTS_DIR
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

info "Case 1b: init flags without --init are a usage error"
for args in "--hostname x" "--profile p" "--yes" "--auto-sync on" "--interval 4h"; do
    # shellcheck disable=SC2086
    run push $args testuser@localhost
    [[ $RC -eq 1 ]] || fail "push $args: expected exit 1, got $RC: $OUT"
    printf '%s\n' "$OUT" | grep -qF "only valid with --init" || fail "push $args: no usage message: $OUT"
done
pass "init flags without --init: usage error"

info "Case 1c: --hostname with more than one HOST is a usage error"
run push --init --hostname x testuser@h1 testuser@h2
[[ $RC -eq 1 ]] || fail "expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "only valid with a single HOST" || fail "no usage message: $OUT"
pass "--hostname with two hosts: usage error"

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

info "Case 4: the remote snippet reads hosts_dir like config_load"
# shellcheck source=../../lib/logging.sh
source "$ROOT_DIR/lib/logging.sh"
# shellcheck source=../../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../../lib/push.sh
source "$ROOT_DIR/lib/push.sh"
SH=sh
command -v dash >/dev/null 2>&1 && SH=dash
snippet() {
    # $1 = config file content (printf format); prints the snippet's stdout+stderr
    printf -- "$1" > "$T/snip-cfg"
    push_remote_snippet | DOTFILES_CONFIG="$T/snip-cfg" $SH 2>&1
}
D="$HOME/.local/share/dotfiles"
EXP=$(printf 'dotfiles_repo=%s/dotfiles\nhosts_dir=%s/dotfiles-hosts' "$D" "$D")
[[ "$(snippet '')" == "$EXP" ]] || fail "defaults wrong: $(snippet '')"
[[ "$(push_remote_snippet | DOTFILES_CONFIG="$T/none.yaml" $SH 2>&1)" == "$EXP" ]] || fail "missing config should give defaults"
# Each case: config content -> hosts_dir the snippet must print, identical to config_load's
parity() {
    local content="$1" want="$2" out got
    out=$(snippet "$content")
    got=$(printf '%s\n' "$out" | sed -n 's/^hosts_dir=//p')
    [[ "$got" == "$want" ]] || fail "snippet hosts_dir '$got', want '$want' for: $content"
    printf -- "$content" > "$T/snip-cfg"
    config_load "$T/snip-cfg" >/dev/null 2>&1 || true
    [[ "$want" == "$D/dotfiles-hosts" ]] || [[ "$CFG_HOSTS_DIR" == "$want" ]] \
        || fail "config_load gave '$CFG_HOSTS_DIR', want '$want' for: $content"
}
parity 'hosts_dir: /srv/h\n' /srv/h
parity '# hosts_dir: /nope\n\nhosts_dir: ~/h one  \r\n' "$HOME/h one"
parity 'hosts_dir: "~/dh-custom"  # comment\r\n' "$HOME/dh-custom"
parity "hosts_dir: '/a b'\t# c\n" "/a b"
parity 'hosts_dir: "/a#b"\n' "/a#b"
parity 'hosts_dir: "/a#b" # c\n' "/a#b"
parity 'hosts_dir: /a#b\n' "/a#b"
parity 'hosts_dir: /a   # c # d\n' /a
parity 'hosts_dir: ~\n' "$HOME"
parity 'hosts_dir: /a\nhosts_dir: /b\n' /b
parity 'hosts_dir:   /sp  \n' /sp
parity '  hosts_dir: /indented\n' "$D/dotfiles-hosts"
parity '- hosts_dir: /list\n' "$D/dotfiles-hosts"
parity 'hosts_dir=/equals\n' "$D/dotfiles-hosts"
parity 'hosts_dir: /last-no-newline' /last-no-newline
parity 'hosts_dirx: /nope\n' "$D/dotfiles-hosts"
OUT=$(snippet 'hosts_dir: relative/path\n')
printf '%s\n' "$OUT" | grep -qF "non-absolute hosts_dir" || fail "no warning for a relative path: $OUT"
printf '%s\n' "$OUT" | grep -qF "hosts_dir=$D/dotfiles-hosts" || fail "relative path should fall back to the default: $OUT"
OUT=$(snippet 'hosts_repo: /old\n')
[[ "$OUT" == "$EXP" ]] || fail "removed hosts_repo key must be ignored: $OUT"
pass "snippet hosts_dir matches config_load rules ($SH)"

info "Case 5: the snippet finds the dotfiles checkout through ~/.local/bin/dotfiles"
rdot() { push_remote_snippet | DOTFILES_CONFIG="$T/none.yaml" $SH 2>&1 | sed -n 's/^dotfiles_repo=//p'; }
LB="$HOME/.local/bin"
[[ "$(rdot)" == "$D/dotfiles" ]] || fail "no link should give the default: $(rdot)"
mkdir -p "$LB" "$T/alt/dotfiles/lib" "$T/other" "$T/nolib"
: > "$T/alt/dotfiles/dotfiles"
: > "$T/other/tool"
: > "$T/nolib/dotfiles"
ln -s "$T/alt/dotfiles/dotfiles" "$LB/dotfiles"
[[ "$(rdot)" == "$T/alt/dotfiles" ]] || fail "absolute link not followed: $(rdot)"
rm "$LB/dotfiles"
ln -s "../../../alt/dotfiles/dotfiles" "$LB/dotfiles"
[[ "$(rdot)" == "$T/alt/dotfiles" ]] || fail "relative link not followed: $(rdot)"
rm "$LB/dotfiles"
ln -s "$T/alt/dotfiles/dotfiles" "$T/hop"
ln -s "$T/hop" "$LB/dotfiles"
[[ "$(rdot)" == "$T/alt/dotfiles" ]] || fail "chained links not followed: $(rdot)"
rm "$LB/dotfiles"
ln -s "$T/other/tool" "$LB/dotfiles"
[[ "$(rdot)" == "$D/dotfiles" ]] || fail "link to a non-dotfiles file should give the default: $(rdot)"
rm "$LB/dotfiles"
ln -s "$T/nolib/dotfiles" "$LB/dotfiles"
[[ "$(rdot)" == "$D/dotfiles" ]] || fail "link to a dir without lib/ should give the default: $(rdot)"
rm "$LB/dotfiles"
ln -s "$T/missing/dotfiles" "$LB/dotfiles"
[[ "$(rdot)" == "$D/dotfiles" ]] || fail "dangling link should give the default: $(rdot)"
rm "$LB/dotfiles"
: > "$LB/dotfiles"
[[ "$(rdot)" == "$D/dotfiles" ]] || fail "a plain file should give the default: $(rdot)"
rm "$LB/dotfiles"
pass "link resolution ($SH)"

echo
echo -e "${GREEN}All push tests passed${NC}"
