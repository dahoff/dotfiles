#!/usr/bin/env bash
# test-push.sh - dotfiles pull --remote and init --remote: local cases (the Docker cases are in run-remote-tests.sh)

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
run pull --remote
[[ $RC -eq 1 ]] || fail "expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "Usage: dotfiles pull --remote" || fail "no usage message: $OUT"
pass "pull --remote without HOST: usage error"

info "Case 1b: init flags without init --remote are a usage error"
for args in "--hostname x" "--profile p" "--yes" "--update-check on" "--interval 4h"; do
    # shellcheck disable=SC2086
    run pull --remote $args testuser@localhost
    [[ $RC -eq 1 ]] || fail "pull --remote $args: expected exit 1, got $RC: $OUT"
    printf '%s\n' "$OUT" | grep -qF "only valid with init --remote" || fail "pull --remote $args: no usage message: $OUT"
done
pass "init flags without init --remote: usage error"

info "Case 1c: --hostname with more than one HOST is a usage error"
run init --remote --hostname x testuser@h1 testuser@h2
[[ $RC -eq 1 ]] || fail "expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "only valid with a single HOST" || fail "no usage message: $OUT"
pass "--hostname with two hosts: usage error"

info "Case 1d: invalid init flag values are refused before contacting the host"
mkdir -p "$T/fakebin"
# Records that it was called, then fails like an unreachable host
cat > "$T/fakebin/ssh" <<EOF
#!/bin/sh
: > "$T/ssh-called"
exit 255
EOF
chmod +x "$T/fakebin/ssh"
push_fake_ssh() {
    rm -f "$T/ssh-called"
    RC=0
    OUT=$(PATH="$T/fakebin:$PATH" ./dotfiles init --remote --yes "$@" testuser@localhost 2>&1) || RC=$?
}
while IFS='|' read -r flag value want; do
    push_fake_ssh "$flag" "$value"
    [[ $RC -eq 1 ]] || fail "$flag '$value': expected exit 1, got $RC: $OUT"
    printf '%s\n' "$OUT" | grep -qF "$want" || fail "$flag '$value': wrong error: $OUT"
    [[ ! -e "$T/ssh-called" ]] || fail "$flag '$value': the host was contacted: $OUT"
done <<'CASES'
--interval|10x|interval must be <n>m, <n>h or <n>d: 10x
--update-check|maybe|update check must be 'on' or 'off': maybe
--hostname|a/b|invalid hostname 'a/b'
--profile|a/b|invalid profile name 'a/b'
--auto-sync|on|Unknown option: --auto-sync
CASES
# Control: well-formed values do go on to the host
push_fake_ssh --interval 4h --update-check on --hostname h1 --profile whatever
[[ -e "$T/ssh-called" ]] || fail "valid flags should reach the host: $OUT"
pass "invalid init flags refused locally"

info "Case 2: unreachable hosts fail and are summarized; the next host still runs"
export DOTFILES_SSH_OPTS="-o Port=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run pull --remote testuser@localhost otheruser@localhost
[[ $RC -eq 1 ]] || fail "expected exit 1, got $RC: $OUT"
printf '%s\n' "$OUT" | grep -qF "[testuser@localhost] remote: send FAILED" || fail "no FAILED summary for first host: $OUT"
printf '%s\n' "$OUT" | grep -qF "[otheruser@localhost] remote: send FAILED" || fail "second host not attempted: $OUT"
pass "unreachable hosts: exit 1, per-host FAILED summary"

info "Case 3: push takes no lock and writes no local state"
[[ ! -e "$T/xdg-state/dotfiles/lock" && ! -e "$T/xdg-state/dotfiles/last-sync" ]] \
    || fail "push touched local state"
[[ ! -e "$T/home/.local/bin/dotfiles" ]] || fail "push self-installed locally"
pass "no local state"

info "Case 3b: the remote command line (a fake ssh that logs every call)"
mkdir -p "$T/fakebin2"
cat > "$T/fakebin2/ssh" <<EOF
#!/bin/sh
echo "\$*" >> "$T/ssh-log"
case " \$* " in *" -t "*|*"sh -s"*) ;; *) readlink /proc/\$\$/fd/0 >> "$T/ssh-stdin" ;; esac
case "\$*" in
    *"sh -s"*) cat > /dev/null; printf 'dotfiles_repo=/r/dotfiles\nhosts_dir=/r/hosts\n' ;;
    *"mktemp -d"*) echo /tmp/fake-rtmp ;;
    *"[ -x '/r/dotfiles/dotfiles' ]"*) echo exists ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin2/scp"
chmod +x "$T/fakebin2/ssh" "$T/fakebin2/scp"
fake_run() {
    rm -f "$T/ssh-log" "$T/ssh-stdin"
    RC=0
    # typed-ahead input on stdin: only the terminal calls may take it
    OUT=$(PATH="$T/fakebin2:$PATH" ./dotfiles "$@" 2>&1 < <(printf "typed ahead\n")) || RC=$?
}
last_ssh() { tail -n 1 "$T/ssh-log"; }
fake_run pull --remote testuser@h1
[[ $RC -eq 0 ]] || fail "pull --remote: exit $RC: $OUT"
[[ "$(last_ssh)" == *"'/r/dotfiles/dotfiles' pull --no-fetch" ]] || fail "wrong remote command: $(last_ssh)"
[[ "$(last_ssh)" != *--force* ]] || fail "--force sent without being asked: $(last_ssh)"
fake_run pull --remote --force testuser@h1 testuser@h2
[[ $RC -eq 0 ]] || fail "pull --remote --force: exit $RC: $OUT"
[[ "$(grep -c "pull --no-fetch --force$" "$T/ssh-log")" == 2 ]] || fail "--force not sent to both hosts: $(cat "$T/ssh-log")"
fake_run pull --remote --force --dry-run testuser@h1
[[ $RC -eq 0 ]] || fail "pull --remote --dry-run: exit $RC: $OUT"
[[ "$(last_ssh)" == *"pull --no-fetch --force --dry-run" ]] || fail "dry run command wrong: $(last_ssh)"
fake_run pull --remote --dry-run testuser@h1
[[ "$(last_ssh)" == *"pull --no-fetch --dry-run" ]] || fail "dry run command wrong: $(last_ssh)"
# --remote may come after the host-less flags or before them
fake_run pull testuser@h1 --remote --force
[[ $RC -eq 0 && "$(last_ssh)" == *"pull --no-fetch --force" ]] || fail "flag order: rc=$RC $(last_ssh)"
fake_run init --remote --yes --hostname h1 testuser@h1
[[ $RC -eq 0 ]] || fail "init --remote: exit $RC: $OUT"
[[ "$(last_ssh)" == *"'/r/dotfiles/dotfiles' init '--yes' '--hostname' 'h1'" ]] || fail "wrong remote init command: $(last_ssh)"
fake_run init --remote --yes --update-check off --interval 2h testuser@h1
[[ $RC -eq 0 && "$(last_ssh)" == *"init '--yes' '--update-check' 'off' '--interval' '2h'" ]] || fail "update check not forwarded: rc=$RC $(last_ssh)"
fake_run init --remote --force testuser@h1
[[ $RC -eq 0 && "$(last_ssh)" != *--force* ]] || fail "init --remote --force: rc=$RC, remote command: $(last_ssh)"
pass "remote pull and init command lines, --force forwarded to pull"

info "Case 3b2: only the terminal call of a push takes the terminal's input"
fake_run init --remote --yes testuser@h1
[[ $RC -eq 0 ]] || fail "init --remote: exit $RC: $OUT"
[[ -s "$T/ssh-stdin" ]] || fail "no non-terminal ssh calls were logged"
[[ "$(sort -u "$T/ssh-stdin")" == /dev/null ]] || fail "an ssh call read the terminal's input: $(sort -u "$T/ssh-stdin")"
pass "non-terminal ssh calls read /dev/null"

info "Case 3c: pull --remote warns when a repo is behind its upstream"
UP="$T/up.git"
git init -q --bare "$UP"
git clone -q "$UP" "$T/behind" 2>/dev/null
git -C "$T/behind" config user.name tester
git -C "$T/behind" config user.email tester@example.com
(cd "$ROOT_DIR" && tar --exclude=.git -cf - .) | (cd "$T/behind" && tar -xf -)
git -C "$T/behind" add -A
git -C "$T/behind" commit -q -m base
git -C "$T/behind" push -q origin HEAD
git clone -q "$UP" "$T/ahead"
git -C "$T/ahead" config user.name tester
git -C "$T/ahead" config user.email tester@example.com
echo more > "$T/ahead/MORE"
git -C "$T/ahead" add MORE
git -C "$T/ahead" commit -q -m more
git -C "$T/ahead" push -q origin HEAD
behind_run() {
    rm -f "$T/ssh-log" "$T/ssh-stdin"
    RC=0
    OUT=$(cd "$T/behind" && PATH="$T/fakebin2:$PATH" ./dotfiles "$@" 2>&1) || RC=$?
}
behind_run pull --remote testuser@h1
[[ "$OUT" != *"behind its upstream"* ]] || fail "warned before the upstream had moved: $OUT"
git -C "$T/behind" fetch -q
behind_run pull --remote testuser@h1
[[ $RC -eq 0 ]] || fail "a warning must not fail the send: $OUT"
[[ "$OUT" == *"$T/behind is 1 commit(s) behind its upstream"* ]] || fail "no behind warning: $OUT"
[[ -s "$T/ssh-log" ]] || fail "the send did not go ahead after the warning"
behind_run init --remote --yes testuser@h1
[[ "$OUT" != *"behind its upstream"* ]] || fail "init --remote should not warn: $OUT"
git -C "$T/behind" merge -q --ff-only '@{u}'
behind_run pull --remote testuser@h1
[[ "$OUT" != *"behind its upstream"* ]] || fail "warned after catching up: $OUT"
pass "behind-upstream warning, send still goes ahead"

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
