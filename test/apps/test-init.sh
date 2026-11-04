#!/usr/bin/env bash
# test-init.sh - dotfiles init: flags, --yes, config writing, hosts repo, interactive prompts

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
echo "Init Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR DOTFILES_INIT_ASSUME_TTY
T="/tmp/dotfiles-test-init-$$"
trap 'rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home" "$T/state/apps"
export HOME="$T/home"
export STATE_DIR="$T/state"
export XDG_STATE_HOME="$T/xdg-state"
export DOTFILES_CONFIG="$T/config/config.yaml"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_TERMINAL_PROMPT=0
: > "$GIT_CONFIG_GLOBAL"
git config --global user.name tester
git config --global user.email tester@example.com
CFG="$DOTFILES_CONFIG"

# The code under test, copied without .git so sync never pulls the real checkout
DF="$T/dotfiles"
mkdir -p "$DF"
(cd "$ROOT_DIR" && tar --exclude=.git -cf - .) | (cd "$DF" && tar -xf -)

# Hosts repo: a plain copy (path tests) and a bare git origin (URL tests)
HD="$T/hosts-dir"
cp -R "$TEST_DIR/fixtures/hosts-dir" "$HD"
cp -R "$TEST_DIR/fixtures/hosts-dir" "$T/hosts-src"
git -C "$T/hosts-src" init -q
git -C "$T/hosts-src" add -A
git -C "$T/hosts-src" commit -q -m fixture
git clone -q --bare "$T/hosts-src" "$T/hosts.git"
URL="file://$T/hosts.git"
DEFAULT_HD="$HOME/.local/share/dotfiles/dotfiles-hosts"

# A sudo that always fails, so the sync in case 9 can never reach the real sudo
mkdir -p "$T/nosudo"
printf '#!/bin/sh\nexit 1\n' > "$T/nosudo/sudo"
chmod +x "$T/nosudo/sudo"

OUT=""
RC=0
# Run dotfiles init with args (stdin /dev/null), capture output and exit code
run_init() {
    RC=0
    OUT=$(PATH="$T/nosudo:$PATH" "$DF/dotfiles" init "$@" 2>&1 </dev/null) || RC=$?
}
# Run init --no-sync interactively, feeding each argument as one answer line
run_interactive() {
    RC=0
    OUT=$(printf '%s\n' "$@" | DOTFILES_INIT_ASSUME_TTY=1 PATH="$T/nosudo:$PATH" \
        "$DF/dotfiles" init --no-sync 2>&1) || RC=$?
}
has() { grep -qxF -- "$1" "$CFG"; }
# Same config content, ignoring the header date line
same_body() {
    cmp -s <(grep -v '^# Written by dotfiles init on ' "$1") <(grep -v '^# Written by dotfiles init on ' "$2")
}

# Case 1
info "Case 1: no tty and no --yes"
run_init
[[ $RC -eq 1 ]] || fail "expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"init is interactive; pass --yes to accept defaults"* ]] || fail "wrong message: $OUT"
[[ ! -e "$CFG" ]] || fail "config written"
pass "refuses to run without a terminal"

# Case 2
info "Case 2: --yes with a hosts dir path"
run_init --yes --no-sync --hosts-dir "$HD" --hostname testhost
[[ $RC -eq 0 ]] || fail "init failed ($RC): $OUT"
has "hosts_dir: $HD" || fail "hosts_dir missing: $(cat "$CFG")"
has "hostname: testhost" || fail "hostname missing"
has "auto_sync: on" || fail "auto_sync missing"
has "auto_sync_interval: 4h" || fail "interval missing"
grep -q '^# profile:' "$CFG" || fail "profile line not commented: $(cat "$CFG")"
! grep -q '^profile:' "$CFG" || fail "uncommented profile line"
! grep -q 'dotfiles_repo' "$CFG" || fail "dotfiles_repo written"
grep -q "^# Written by dotfiles init on $(date -u +%Y-%m-%d)$" "$CFG" || fail "header missing"
[[ "$OUT" == *"host.yaml found (profile: base)"* ]] || fail "host.yaml not reported: $OUT"
[[ "$OUT" == *"Wrote $CFG"* ]] || fail "Wrote line missing: $OUT"
[[ "$OUT" == *"testhost configured (host.yaml)"* && "$OUT" == *"background sync every 4h"* ]] \
    || fail "closing lines missing: $OUT"
# The written config round-trips through config_load
(
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
    config_load "$CFG"
    [[ "$CFG_HOSTS_DIR" == "$HD" && "$CFG_HOSTNAME" == testhost && -z "$CFG_PROFILE" \
        && "$CFG_AUTO_SYNC" == on && "$CFG_AUTO_SYNC_INTERVAL" == 4h ]]
) || fail "config does not round-trip through config_load"
# A relative path is stored absolute
(cd "$T" && OUT=$("$DF/dotfiles" init --yes --no-sync --hosts-dir hosts-dir --hostname testhost 2>&1 </dev/null)) \
    || fail "relative path failed"
has "hosts_dir: $HD" || fail "relative hosts_dir not made absolute: $(cat "$CFG")"
pass "config written from flags; host.yaml selects the profile"

# Case 3
info "Case 3: no hosts repo, explicit values"
rm -f "$CFG" "$CFG.bak"
run_init --yes --no-sync --hosts-dir none --hostname testhost --profile minimal --auto-sync off --interval 2h
[[ $RC -eq 0 ]] || fail "init failed ($RC): $OUT"
has "# hosts_dir:" || fail "hosts_dir not commented: $(cat "$CFG")"
has "profile: minimal" || fail "profile missing"
has "auto_sync: off" || fail "auto_sync off missing"
has "auto_sync_interval: 2h" || fail "interval 2h missing"
[[ "$OUT" == *"testhost configured (profile minimal)"* && "$OUT" == *"background sync off"* ]] \
    || fail "closing lines wrong: $OUT"
[[ "$OUT" == *"open a new terminal"* ]] || fail "no new-terminal hint: $OUT"
pass "none hosts repo and explicit profile/auto sync/interval"

# Case 4
info "Case 4: re-run keeps the file; a change makes a .bak"
rm -f "$CFG" "$CFG.bak"
run_init --yes --no-sync --hosts-dir "$HD" --hostname testhost
cp "$CFG" "$T/first.yaml"
run_init --yes --no-sync --hosts-dir "$HD" --hostname testhost
[[ $RC -eq 0 ]] || fail "re-run failed: $OUT"
[[ ! -e "$CFG.bak" ]] || fail ".bak created for identical content"
same_body "$CFG" "$T/first.yaml" || fail "content changed on re-run"
[[ ! -e "$CFG.tmp" ]] || fail ".tmp left behind"
run_init --yes --no-sync --hosts-dir "$HD" --hostname testhost --interval 1h
[[ $RC -eq 0 ]] || fail "init --interval 1h failed: $OUT"
same_body "$CFG.bak" "$T/first.yaml" || fail ".bak does not hold the old content"
has "auto_sync_interval: 1h" || fail "new interval missing"
[[ "$OUT" == *"previous config saved as $CFG.bak"* ]] || fail "backup not reported: $OUT"
pass ".bak only when content differs"

# Case 5
info "Case 5: existing config values are the defaults"
rm -f "$CFG.bak"
printf 'profile: minimal\nhostname: nohost\nauto_sync_interval: 3h\n' > "$CFG"
run_init --yes --no-sync --hosts-dir none
[[ $RC -eq 0 ]] || fail "init failed ($RC): $OUT"
has "profile: minimal" || fail "profile not kept: $(cat "$CFG")"
has "hostname: nohost" || fail "hostname not kept"
has "auto_sync_interval: 3h" || fail "interval not kept"
# An explicit profile with a host.yaml is kept uncommented (it overrides host.yaml)
rm -f "$CFG.bak"
printf 'hosts_dir: %s\nhostname: testhost\nprofile: minimal\n' "$HD" > "$CFG"
run_init --yes --no-sync
[[ $RC -eq 0 ]] || fail "init failed ($RC): $OUT"
has "profile: minimal" || fail "explicit profile commented or lost: $(cat "$CFG")"
[[ "$OUT" == *"profile 'minimal' overrides profile 'base'"* ]] || fail "override not warned: $OUT"
[[ "$OUT" == *"testhost configured (profile minimal)"* ]] || fail "summary hides the kept profile: $OUT"
cp "$CFG" "$T/override.yaml"
rm -f "$CFG.bak"
run_init --yes --no-sync
[[ $RC -eq 0 ]] || fail "re-run failed ($RC): $OUT"
has "profile: minimal" || fail "explicit profile not kept on re-run"
same_body "$CFG" "$T/override.yaml" || fail "re-run changed the config"
[[ ! -e "$CFG.bak" ]] || fail ".bak created on unchanged re-run"
# --profile with a host.yaml is written uncommented too
rm -f "$CFG" "$CFG.bak"
run_init --yes --no-sync --hosts-dir "$HD" --hostname testhost --profile minimal
[[ $RC -eq 0 ]] && has "profile: minimal" || fail "--profile with host.yaml not written: $OUT"
[[ "$OUT" == *"testhost configured (profile minimal)"* ]] || fail "summary hides --profile: $OUT"
# Values with ' #' are quoted and read back whole
rm -f "$CFG"
run_init --yes --no-sync --hosts-dir none --hostname 'a #b'
[[ $RC -eq 0 ]] || fail "init failed ($RC): $OUT"
(
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
    config_load "$CFG"
    [[ "$CFG_HOSTNAME" == 'a #b' ]]
) || fail "hostname with ' #' does not round-trip: $(cat "$CFG")"
pass "existing config keeps profile and hostname; explicit profile overrides host.yaml"

# Case 6
info "Case 6: URL clones to the default path; re-run pulls"
rm -f "$CFG" "$CFG.bak"
run_init --yes --no-sync --hosts-dir "$URL" --hostname testhost
[[ $RC -eq 0 ]] || fail "clone init failed ($RC): $OUT"
[[ -f "$DEFAULT_HD/hosts/testhost/host.yaml" ]] || fail "not cloned to $DEFAULT_HD"
has "hosts_dir: $DEFAULT_HD" || fail "hosts_dir not the clone: $(cat "$CFG")"
run_init --yes --no-sync --hosts-dir "$URL" --hostname testhost
[[ $RC -eq 0 ]] || fail "re-run with existing clone failed ($RC): $OUT"
[[ "$OUT" == *"Already up to date: $DEFAULT_HD"* ]] || fail "existing clone not pulled: $OUT"
pass "URL cloned, then pulled"

# Case 7
info "Case 7: URL with a pushed (non-git) copy at the default path"
rm -rf "$DEFAULT_HD"
cp -R "$HD" "$DEFAULT_HD"
echo "pushed from test" > "$DEFAULT_HD/PUSHED"
rm -f "$CFG" "$CFG.bak"
run_init --yes --no-sync --hosts-dir "$URL" --hostname testhost
[[ $RC -eq 1 ]] || fail "expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"$DEFAULT_HD"* && "$OUT" == *"--hosts-dir"* ]] || fail "error does not name the path: $OUT"
[[ -f "$DEFAULT_HD/PUSHED" && ! -e "$DEFAULT_HD/.git" ]] || fail "pushed copy touched"
diff -r -x PUSHED "$HD" "$DEFAULT_HD" >/dev/null || fail "pushed copy contents changed"
[[ ! -e "$CFG" ]] || fail "config written"
# A checkout of another URL is refused the same way
rm -rf "$DEFAULT_HD"
git clone -q "$T/hosts.git" "$DEFAULT_HD"
git -C "$DEFAULT_HD" remote set-url origin "file:///elsewhere.git"
run_init --yes --no-sync --hosts-dir "$URL" --hostname testhost
[[ $RC -eq 1 && "$OUT" == *"$DEFAULT_HD"* ]] || fail "other-URL checkout not refused: $OUT"
[[ -d "$DEFAULT_HD/.git" && ! -e "$CFG" ]] || fail "other-URL checkout touched or config written"
# A failed clone writes nothing
rm -rf "$DEFAULT_HD"
run_init --yes --no-sync --hosts-dir "file://$T/missing.git" --hostname testhost
[[ $RC -eq 1 && ! -e "$CFG" && ! -e "$DEFAULT_HD" ]] || fail "failed clone: rc=$RC: $OUT"
pass "existing copy refused and kept; clone failure writes nothing"

# Case 8
info "Case 8: invalid values exit 1 under --yes"
for args in "--hosts-dir none --hostname ../x" \
            "--hosts-dir none --hostname a/b" \
            "--hosts-dir none --interval 10x" \
            "--hosts-dir none --auto-sync maybe" \
            "--hosts-dir none --hostname nohost --profile nope" \
            "--hosts-dir /nonexistent" \
            "--bogus"; do
    # shellcheck disable=SC2086
    run_init --yes --no-sync $args
    [[ $RC -eq 1 ]] || fail "'$args' should exit 1, got $RC: $OUT"
    [[ ! -e "$CFG" ]] || fail "'$args' wrote a config"
done
pass "invalid hostname, interval, auto sync, profile, hosts dir and flag rejected"

# Case 9
info "Case 9: init runs the first sync"
rm -f "$CFG" "$CFG.bak"
run_init --yes --hosts-dir "$HD" --hostname testhost
[[ $RC -eq 0 ]] || fail "init with sync failed ($RC): $OUT"
[[ -f "$HOME/.claude/settings.json" ]] || fail "sync did not deploy claude settings: $OUT"
[[ -L "$HOME/.local/bin/dotfiles" ]] || fail "sync did not self-install"
pass "first sync deployed configs"

# Case 10
info "Case 10: interactive answers on stdin"
rm -f "$CFG" "$CFG.bak"
run_interactive "$HD" "testhost" "" ""
[[ $RC -eq 0 ]] || fail "interactive init failed ($RC): $OUT"
has "hostname: testhost" || fail "hostname not written: $(cat "$CFG")"
has "hosts_dir: $HD" || fail "hosts_dir not written"
has "auto_sync_interval: 4h" || fail "default interval not written"
[[ "$OUT" == *"[4h]: "* ]] || fail "interval prompt has no default: $OUT"
# Re-run accepting every default: each default is the current value, nothing changes
cp "$CFG" "$T/interactive.yaml"
run_interactive "" "" "" ""
[[ $RC -eq 0 ]] || fail "defaults re-run failed ($RC): $OUT"
[[ "$OUT" == *"[$HD]: "* && "$OUT" == *"[testhost]: "* ]] || fail "defaults not from config: $OUT"
same_body "$CFG" "$T/interactive.yaml" || fail "accepting defaults changed the config"
[[ ! -e "$CFG.bak" ]] || fail ".bak created when nothing changed"
# A bad hostname is rejected like --hostname, then re-prompted
rm -f "$CFG"
run_interactive "$HD" "../bad" "testhost" "" ""
[[ $RC -eq 0 ]] || fail "re-prompt run failed ($RC): $OUT"
[[ "$OUT" == *"../bad"* ]] || fail "bad hostname not reported: $OUT"
has "hostname: testhost" || fail "re-prompted hostname not written"
# Bad interval and hosts dir are re-prompted too
rm -f "$CFG"
run_interactive "/nonexistent" "$HD" "testhost" "maybe" "off" "10x" "2d"
[[ $RC -eq 0 ]] || fail "re-prompt run failed ($RC): $OUT"
has "auto_sync: off" && has "auto_sync_interval: 2d" || fail "re-prompted values not written: $(cat "$CFG")"
# Without a host.yaml the profile names (hosts repo first) are listed before the prompt
rm -f "$CFG"
run_interactive "$HD" "nohost" "" "" ""
[[ $RC -eq 0 ]] || fail "profile prompt run failed ($RC): $OUT"
LIST=$(grep '^profiles: ' <<< "$OUT") || fail "profile names not listed: $OUT"
[[ "$LIST" == "profiles: base, "* && "$LIST" == *", complete" ]] || fail "profile list order wrong: $LIST"
[[ $(grep -o 'minimal' <<< "$LIST" | wc -l) -eq 1 ]] || fail "duplicate profile name: $LIST"
[[ "${OUT%%Profile \[complete\]: *}" == *"$LIST"* ]] || fail "list not printed before the prompt: $OUT"
has "profile: complete" || fail "default profile not written: $(cat "$CFG")"
# EOF before all answers
rm -f "$CFG"
run_interactive "$HD"
[[ $RC -eq 1 ]] || fail "EOF should exit 1, got $RC: $OUT"
[[ "$OUT" == *"init: no answer for 'Hostname'"* ]] || fail "EOF message wrong: $OUT"
[[ ! -e "$CFG" ]] || fail "config written after EOF"
pass "interactive prompts, defaults, re-prompts and EOF"

# SSH access: a fake ssh refuses the number of connections in ssh-refusals, then
# serves the real bare repo, as if the key was added while init waited.
cat > "$T/fake-ssh" <<EOF
#!/bin/sh
n=\$(cat "$T/ssh-refusals")
if [ "\$n" -gt 0 ]; then
    echo \$((n - 1)) > "$T/ssh-refusals"
    echo "git@host: Permission denied (publickey)." >&2
    exit 255
fi
exec git upload-pack "$T/hosts.git"
EOF
chmod +x "$T/fake-ssh"
export GIT_SSH_COMMAND="$T/fake-ssh"
# Otherwise git probes the command with -G, which would use up a refusal
export GIT_SSH_VARIANT=ssh
SSH_URL="git@github.com:me/hosts.git"
KEY="$HOME/.ssh/id_ed25519"
ssh_reset() {
    rm -rf "$HOME/.ssh" "$DEFAULT_HD"
    rm -f "$CFG" "$CFG.bak"
    echo "$1" > "$T/ssh-refusals"
}

info "Case SSH 1: no key: one is created and shown, and init retries until the clone works"
ssh_reset 2
run_interactive "$SSH_URL" "" "" testhost "" ""
[[ $RC -eq 0 ]] || fail "SSH 1: init failed ($RC): $OUT"
[[ "$(stat -c %a "$KEY")" == 600 ]] || fail "SSH 1: private key missing or wrong mode"
ssh-keygen -y -P "" -f "$KEY" >/dev/null 2>&1 || fail "SSH 1: key needs a passphrase"
[[ "$OUT" == *"$(cat "$KEY.pub")"* ]] || fail "SSH 1: public key not shown: $OUT"
[[ "$OUT" == *"https://github.com/settings/keys"* ]] || fail "SSH 1: no link to add the key: $OUT"
[[ -f "$DEFAULT_HD/hosts/testhost/host.yaml" ]] || fail "SSH 1: not cloned"
has "hosts_dir: $DEFAULT_HD" || fail "SSH 1: hosts_dir not written: $(cat "$CFG")"
pass "key created, shown and clone retried"

info "Case SSH 2: an existing key is shown, not replaced"
ssh_reset 1
mkdir -p "$HOME/.ssh"
ssh-keygen -q -t rsa -b 2048 -N "" -f "$HOME/.ssh/id_rsa" -C existing
cp "$HOME/.ssh/id_rsa" "$T/id_rsa.before"
run_interactive "$SSH_URL" "" testhost "" ""
[[ $RC -eq 0 ]] || fail "SSH 2: init failed ($RC): $OUT"
cmp -s "$HOME/.ssh/id_rsa" "$T/id_rsa.before" || fail "SSH 2: existing key changed"
[[ ! -e "$KEY" ]] || fail "SSH 2: created a second key"
[[ "$OUT" == *"$(cat "$HOME/.ssh/id_rsa.pub")"* ]] || fail "SSH 2: existing public key not shown: $OUT"
pass "existing key reused"

info "Case SSH 3: a private key with no .pub file is left alone"
ssh_reset 1
mkdir -p "$HOME/.ssh"
echo "not a real key" > "$KEY"
run_interactive "$SSH_URL" "" testhost "" ""
[[ $RC -eq 1 ]] || fail "SSH 3: expected exit 1, got $RC: $OUT"
[[ "$(cat "$KEY")" == "not a real key" ]] || fail "SSH 3: key overwritten"
[[ ! -e "$CFG" ]] || fail "SSH 3: config written"
pass "private key without .pub not overwritten"

info "Case SSH 4: q stops without writing anything"
ssh_reset 1
run_interactive "$SSH_URL" q
[[ $RC -eq 1 ]] || fail "SSH 4: expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"could not clone $SSH_URL"* ]] || fail "SSH 4: no clone error: $OUT"
[[ ! -e "$CFG" ]] || fail "SSH 4: config written"
[[ ! -e "$DEFAULT_HD" ]] || fail "SSH 4: hosts dir left behind"
pass "q stops"

info "Case SSH 5: --yes fails at once and creates no key"
ssh_reset 1
run_init --yes --no-sync --hosts-dir "$SSH_URL" --hostname testhost
[[ $RC -eq 1 ]] || fail "SSH 5: expected exit 1, got $RC: $OUT"
[[ ! -e "$HOME/.ssh" ]] || fail "SSH 5: touched ~/.ssh under --yes"
[[ ! -e "$CFG" ]] || fail "SSH 5: config written"
pass "--yes does not prompt or create a key"

info "Case SSH 6: a failed clone that does not use ssh creates no key"
ssh_reset 0
run_interactive "file://$T/no-such-repo.git"
[[ $RC -eq 1 ]] || fail "SSH 6: expected exit 1, got $RC: $OUT"
[[ ! -e "$HOME/.ssh" ]] || fail "SSH 6: touched ~/.ssh for a non-ssh URL"
pass "non-ssh URL creates no key"

info "Case SSH 7: another git host is named, without a GitHub link"
ssh_reset 1
run_interactive "ssh://git@git.work.example:2222/me/hosts.git" "" testhost "" ""
[[ $RC -eq 0 ]] || fail "SSH 7: init failed ($RC): $OUT"
[[ "$OUT" == *"your account on git.work.example:"* ]] || fail "SSH 7: host not named: $OUT"
[[ "$OUT" != *"github.com/settings/keys"* ]] || fail "SSH 7: GitHub link for another host: $OUT"
pass "other git host named"
unset GIT_SSH_COMMAND GIT_SSH_VARIANT

echo
echo -e "${GREEN}All init tests passed${NC}"
