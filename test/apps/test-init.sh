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

unset DOTFILES_HOSTS_DIR DOTFILES_INIT_ASSUME_TTY DOTFILES_RESET_SNAPSHOTTED
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
has "update_check: on" || fail "update_check missing"
has "update_check_interval: 4h" || fail "interval missing"
grep -q '^# profile:' "$CFG" || fail "profile line not commented: $(cat "$CFG")"
! grep -q '^profile:' "$CFG" || fail "uncommented profile line"
! grep -q 'dotfiles_repo' "$CFG" || fail "dotfiles_repo written"
grep -q "^# Written by dotfiles init on $(date -u +%Y-%m-%d)$" "$CFG" || fail "header missing"
[[ "$OUT" == *"host.yaml found (profile: base)"* ]] || fail "host.yaml not reported: $OUT"
[[ "$OUT" == *"Wrote $CFG"* ]] || fail "Wrote line missing: $OUT"
[[ "$OUT" == *"testhost configured (host.yaml)"* && "$OUT" == *"update check every 4h"* ]] \
    || fail "closing lines missing: $OUT"
# The written config round-trips through config_load
(
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/config.sh"
    config_load "$CFG"
    [[ "$CFG_HOSTS_DIR" == "$HD" && "$CFG_HOSTNAME" == testhost && -z "$CFG_PROFILE" \
        && "$CFG_UPDATE_CHECK" == on && "$CFG_UPDATE_CHECK_INTERVAL" == 4h ]]
) || fail "config does not round-trip through config_load"
# A relative path is stored absolute
(cd "$T" && OUT=$("$DF/dotfiles" init --yes --no-sync --hosts-dir hosts-dir --hostname testhost 2>&1 </dev/null)) \
    || fail "relative path failed"
has "hosts_dir: $HD" || fail "relative hosts_dir not made absolute: $(cat "$CFG")"
pass "config written from flags; host.yaml selects the profile"

# Case 3
info "Case 3: no hosts repo, explicit values"
rm -f "$CFG" "$CFG.bak"
run_init --yes --no-sync --hosts-dir none --hostname testhost --profile minimal --update-check off --interval 2h
[[ $RC -eq 0 ]] || fail "init failed ($RC): $OUT"
has "# hosts_dir:" || fail "hosts_dir not commented: $(cat "$CFG")"
has "profile: minimal" || fail "profile missing"
has "update_check: off" || fail "update_check off missing"
has "update_check_interval: 2h" || fail "interval 2h missing"
[[ "$OUT" == *"testhost configured (profile minimal)"* && "$OUT" == *"update check off"* ]] \
    || fail "closing lines wrong: $OUT"
[[ "$OUT" == *"open a new terminal"* ]] || fail "no new-terminal hint: $OUT"
pass "none hosts repo and explicit profile/update check/interval"

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
has "update_check_interval: 1h" || fail "new interval missing"
[[ "$OUT" == *"previous config saved as $CFG.bak"* ]] || fail "backup not reported: $OUT"
pass ".bak only when content differs"

# Case 5
info "Case 5: existing config values are the defaults"
rm -f "$CFG.bak"
printf 'profile: minimal\nhostname: nohost\nauto_sync: off\nauto_sync_interval: 3h\n' > "$CFG"
run_init --yes --no-sync --hosts-dir none
[[ $RC -eq 0 ]] || fail "init failed ($RC): $OUT"
has "profile: minimal" || fail "profile not kept: $(cat "$CFG")"
has "hostname: nohost" || fail "hostname not kept"
has "update_check_interval: 3h" || fail "interval not kept (read from the old auto_sync_interval key)"
has "update_check: off" || fail "update check not kept (read from the old auto_sync key)"
! grep -q '^auto_sync' "$CFG" || fail "old key names written back: $(cat "$CFG")"
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
            "--hosts-dir none --update-check maybe" \
            "--hosts-dir none --hostname nohost --profile nope" \
            "--hosts-dir /nonexistent" \
            "--bogus"; do
    # shellcheck disable=SC2086
    run_init --yes --no-sync $args
    [[ $RC -eq 1 ]] || fail "'$args' should exit 1, got $RC: $OUT"
    [[ ! -e "$CFG" ]] || fail "'$args' wrote a config"
done
pass "invalid hostname, interval, update check, profile, hosts dir and flag rejected"

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
has "update_check_interval: 4h" || fail "default interval not written"
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
has "update_check: off" && has "update_check_interval: 2d" || fail "re-prompted values not written: $(cat "$CFG")"
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

# Case UC
info "Case UC: --update-check validates; --auto-sync is gone; the prompt says Update check"
for args in "--hosts-dir none --update-check maybe" "--hosts-dir none --update-check" "--hosts-dir none --auto-sync on"; do
    rm -f "$CFG"
    # shellcheck disable=SC2086
    run_init --yes --no-sync $args
    [[ $RC -eq 1 ]] || fail "'$args' should exit 1, got $RC: $OUT"
    [[ ! -e "$CFG" ]] || fail "'$args' wrote a config"
done
[[ "$OUT" == *"Unknown init option: --auto-sync"* ]] || fail "--auto-sync not reported unknown: $OUT"
rm -f "$CFG"
run_interactive "$HD" "testhost" "" ""
[[ "$OUT" == *"Update check (on/off) [on]: "* && "$OUT" == *"Update check interval (<n>m|h|d) [4h]: "* ]] || fail "prompts wrong: $OUT"
[[ "$OUT" != *"Background sync"* ]] || fail "old prompt text left: $OUT"
pass "update check flag and prompts"

# ---------------------------------------------------------------------------
# Re-running init: the reset question, the reset, and the move from old records
# ---------------------------------------------------------------------------
CL="$HOME/.claude"
BAK_ORIG="$T/tmux-notify.orig"
cp -p "$DF/apps/claude/files/tmux-notify.sh" "$BAK_ORIG"
mkdir -p "$T/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/lazygit"
chmod +x "$T/fakebin/lazygit"
# A profile and host with a tool that has a drop-in
cat > "$HD/profiles/dropprof.yaml" <<'EOF'
packages:
  - claude
  - scripts
  - lazygit
EOF
mkdir -p "$HD/hosts/dropin"
printf 'profile: dropprof\n' > "$HD/hosts/dropin/host.yaml"
printf 'packages:\n  - scripts\n' > "$HD/profiles/scriptsonly.yaml"
mkdir -p "$HD/hosts/noclaude"
printf 'profile: scriptsonly\n' > "$HD/hosts/noclaude/host.yaml"
printf 'packages:\n  - claude\n  - scripts\n  - git\n' > "$HD/profiles/gitprof.yaml"
mkdir -p "$HD/hosts/gitter"
printf 'profile: gitprof\n' > "$HD/hosts/gitter/host.yaml"

# A host that has been through init --yes, from nothing
# Usage: fresh_host [HOSTNAME]
fresh_host() {
    chmod -R u+rwx "$HOME" 2>/dev/null || true
    rm -rf "$HOME"/.[!.]* "$HOME"/* "$STATE_DIR" "$XDG_STATE_HOME" "$CFG" "$CFG.bak"
    mkdir -p "$STATE_DIR/apps"
    cp -p "$BAK_ORIG" "$DF/apps/claude/files/tmux-notify.sh"
    run_init --yes --hosts-dir "${2:-$HD}" --hostname "${1:-testhost}"
    [[ $RC -eq 0 ]] || fail "baseline init failed ($RC): $OUT"
}
# Re-run init interactively, accepting the four settings questions, then answering the
# rest. With no answers the input ends at the reset question.
# Usage: rerun [ANSWER...]
rerun() {
    RC=0
    OUT=$(printf '%s\n' "" "" "" "" "$@" | DOTFILES_INIT_ASSUME_TTY=1 PATH="$T/fakebin:$T/nosudo:$PATH" \
        "$DF/dotfiles" init 2>&1) || RC=$?
}
# Like rerun, answering the hostname question with HOSTNAME
# Usage: rerun_as HOSTNAME [ANSWER...]
rerun_as() {
    local h="$1"
    shift
    RC=0
    OUT=$(printf '%s\n' "" "$h" "" "" "$@" | DOTFILES_INIT_ASSUME_TTY=1 PATH="$T/fakebin:$T/nosudo:$PATH" \
        "$DF/dotfiles" init 2>&1) || RC=$?
}
# Number of snapshots (not the original) an app's backup folder holds
snap_count() { find "$HOME/.bak/$1" -mindepth 1 -maxdepth 1 -type d ! -name original 2>/dev/null | wc -l; }
rerun_eof() {
    RC=0
    OUT=$(printf '\n\n\n\n' | DOTFILES_INIT_ASSUME_TTY=1 PATH="$T/fakebin:$T/nosudo:$PATH" \
        "$DF/dotfiles" init 2>&1) || RC=$?
}
status_out() { "$DF/dotfiles" status 2>&1 </dev/null; }
# A fingerprint of everything under HOME and the state dirs
tree_sum() {
    (cd / && find "${HOME#/}" "${STATE_DIR#/}" -type f 2>/dev/null | sort | xargs -d '\n' sha256sum) | sha256sum
}
# Hold the same statuses and edits on a host: an unreviewed edit, a dismissed edit, a held
# conflict, a local-only key in a merged file, and the files init must leave alone.
make_local_state() {
    echo "# dismissed edit" >> "$CL/statusline-command.sh"
    printf 'd\n' | DOTFILES_ADD_ASSUME_TTY=1 "$DF/dotfiles" add >/dev/null 2>&1 \
        || fail "could not dismiss the statusline edit"
    echo "my own line" >> "$CL/CLAUDE.md"
    jq '.localOnly = {"mine": true} | .model = "my-model"' "$CL/settings.json" > "$T/s.json"
    cp "$T/s.json" "$CL/settings.json"
    # A held conflict: the repo moved on since the last deploy (the record holds an older
    # version, and the app's state is stale so that the pull looks at it), and so did the file
    echo "# conflict, local" >> "$CL/tmux-notify.sh"
    echo "# an older repo version" > "$STATE_DIR/records/claude/repo/tmux-notify.sh"
    sed -i 's/^  version: .*/  version: stale/' "$STATE_DIR/apps/claude.yaml"
    "$DF/dotfiles" pull >/dev/null 2>&1 </dev/null || true
    grep -q 'version: conflict:' "$STATE_DIR/apps/claude.yaml" || fail "the test setup did not hold a conflict"
    echo "mine" > "$HOME/.bashrc.d/00-local.sh"
    echo "[user]" > "$HOME/.gitconfig.local"
    echo "# drop-in edit" >> "$HOME/.bashrc.d/90-dotfiles.sh"
    echo "data" > "$HOME/.ghost.conf"
    mkdir -p "$STATE_DIR/records/ghost/repo" "$STATE_DIR/records/ghost/review"
    printf 'a.conf\t%s\treplace\n' "$HOME/.ghost.conf" > "$STATE_DIR/records/ghost/manifest.tsv"
    echo "data" > "$STATE_DIR/records/ghost/repo/a.conf"
    echo "data" > "$STATE_DIR/records/ghost/review/a.conf"
    echo "data, edited" > "$HOME/.ghost.conf"
    sed 's/^  name: claude/  name: ghost/; s/^  version: .*/  version: conflict:abc123/' "$STATE_DIR/apps/claude.yaml" > "$STATE_DIR/apps/ghost.yaml"
    mkdir -p "$STATE_DIR/records/.released/1" "$STATE_DIR/records/.add-saved"
    echo old > "$STATE_DIR/records/.released/1/repo"
    echo old > "$STATE_DIR/records/.add-saved/abc"
}
live_local_state_held() {
    grep -qx "my own line" "$CL/CLAUDE.md" \
        && [[ "$(jq -r .localOnly.mine "$CL/settings.json")" == true ]] \
        && [[ "$(jq -r .model "$CL/settings.json")" == my-model ]] \
        && grep -qx "# dismissed edit" "$CL/statusline-command.sh" \
        && grep -qx "# conflict, local" "$CL/tmux-notify.sh"
}

# Case R1
info "Case R1: a re-run saves its answers, then asks about a reset; no keeps everything"
fresh_host
make_local_state
live_local_state_held || fail "R1: the test setup did not hold its edits"
SUM_BEFORE=$(tree_sum)
rerun ""
[[ $RC -eq 0 ]] || fail "R1: init failed ($RC): $OUT"
[[ "$OUT" == *"Wrote $CFG"* ]] || fail "R1: answers not saved: $OUT"
[[ "$OUT" == *"Reset every managed file to the repo layers? [no]: "* ]] || fail "R1: no reset question with a default of no: $OUT"
[[ "${OUT%%Reset every managed*}" == *"Wrote $CFG"* ]] || fail "R1: the question came before the answers were saved: $OUT"
[[ "$OUT" == *"Not resetting"* ]] || fail "R1: no note that nothing was reset: $OUT"
live_local_state_held || fail "R1: an empty answer lost local edits: $OUT"
[[ -f "$HOME/.bashrc.d/00-local.sh" && -f "$HOME/.gitconfig.local" ]] || fail "R1: untouched files lost"
# Anything but yes means no, and the pull that follows is a normal one
for a in n no N maybe "reset" " "; do
    rerun "$a"
    [[ $RC -eq 0 ]] || fail "R1: answer '$a' failed ($RC): $OUT"
    [[ "$OUT" != *"Type 'reset'"* ]] || fail "R1: answer '$a' went on to the confirmation: $OUT"
    live_local_state_held || fail "R1: answer '$a' lost local edits"
done
# EOF at the question: no reset, a normal pull
rerun_eof
[[ $RC -eq 0 ]] || fail "R1: EOF run failed ($RC): $OUT"
[[ "$OUT" == *"Not resetting"* ]] || fail "R1: EOF not taken as no: $OUT"
live_local_state_held || fail "R1: EOF lost local edits"
# A yes that is not confirmed with 'reset' cancels
for a in "" no Reset RESET "reset please" y; do
    rerun yes "$a"
    [[ $RC -eq 0 ]] || fail "R1: confirmation '$a' failed ($RC): $OUT"
    [[ "$OUT" == *"Type 'reset' to go ahead: "* ]] || fail "R1: no confirmation asked for '$a': $OUT"
    [[ "$OUT" == *"Not resetting"* ]] || fail "R1: cancel not reported for '$a': $OUT"
    live_local_state_held || fail "R1: cancelled confirmation '$a' lost local edits"
done
# EOF at the confirmation cancels too
rerun yes
[[ $RC -eq 0 && "$OUT" == *"Not resetting"* ]] || fail "R1: EOF at the confirmation not a cancel: rc=$RC $OUT"
live_local_state_held || fail "R1: EOF at the confirmation lost local edits"
[[ -d "$STATE_DIR/records/ghost" && -d "$STATE_DIR/records/.add-saved" ]] || fail "R1: records touched without a reset"
pass "the question defaults to no; no, EOF and a missing 'reset' all run a normal pull"

# Case R2
info "Case R2: confirming lists what is lost, then resets everything to the repo layers"
fresh_host
cp -R "$STATE_DIR/records" "$T/records-before"
make_local_state
SC_BEFORE=$(snap_count claude)
rerun yes reset
[[ $RC -eq 0 ]] || fail "R2: reset failed ($RC): $OUT"
LISTED="${OUT#*This would be lost:}"
LISTED="${LISTED%%00-local.sh and .gitconfig.local are not touched*}"
# Status' notes about what its lists mean don't belong under "would be lost"
for note in "yours is kept" "kept local on purpose" "reviews them" "asks again"; do
    [[ "$LISTED" != *"$note"* ]] || fail "R2: a status note is listed as lost ('$note'): $LISTED"
done
[[ "$LISTED" == *"not in the repo's last deployed version"* ]] || fail "R2: local-only keys not worded as last deployed: $LISTED"
# One snapshot, and the user is told where it is
[[ $(( $(snap_count claude) - SC_BEFORE )) -eq 1 ]] || fail "R2: a reset used $(( $(snap_count claude) - SC_BEFORE )) snapshot slots, not one"
[[ "$OUT" == *"Snapshot of the claude files: ~/.bak/claude/"* ]] || fail "R2: the snapshot's path is not shown: $OUT"
[[ "$LISTED" == *"~/.claude/CLAUDE.md"* ]] || fail "R2: the unreviewed edit is not listed: $LISTED"
[[ "$LISTED" == *'~/.claude/settings.json  key ["localOnly"]'* ]] || fail "R2: the local-only key is not listed: $LISTED"
[[ "$LISTED" == *'~/.claude/settings.json  key ["model"]'* ]] || fail "R2: the changed value is not listed: $LISTED"
[[ "$LISTED" == *"conflicts:"* && "$LISTED" == *"~/.claude/tmux-notify.sh  (the repo changed it too)"* ]] || fail "R2: the conflict is not listed: $LISTED"
[[ "$LISTED" == *"dismissed:"* && "$LISTED" == *"~/.claude/statusline-command.sh"* ]] || fail "R2: the dismissed edit is not listed: $LISTED"
[[ "$LISTED" == *"~/.bashrc.d/90-dotfiles.sh"* ]] || fail "R2: the drop-in edit is not listed: $LISTED"
[[ "$LISTED" == *"~/.ghost.conf"* && "$LISTED" == *"doesn't manage"* ]] || fail "R2: the file of an app out of the profile is not listed: $LISTED"
[[ "$LISTED" != *"00-local.sh"* ]] || fail "R2: an unmanaged file is listed as lost: $LISTED"
# Every managed file is the repo layers exactly
for f in CLAUDE.md settings.json settings.local.json statusline-command.sh tmux-notify.sh; do
    cmp -s "$T/records-before/claude/repo/$f" "$CL/$f" || fail "R2: $f is not the repo's: $(cat "$CL/$f")"
done
cmp -s "$T/records-before/dotfiles/repo/90-dotfiles.sh" "$HOME/.bashrc.d/90-dotfiles.sh" || fail "R2: the drop-in is not the repo's"
[[ "$(jq -r '.localOnly // "gone"' "$CL/settings.json")" == gone ]] || fail "R2: a local-only key survived"
# Untouched
[[ "$(cat "$HOME/.bashrc.d/00-local.sh")" == mine && "$(cat "$HOME/.gitconfig.local")" == "[user]" ]] || fail "R2: 00-local.sh or .gitconfig.local changed"
# Fresh records: the repo copy, the review copy and the live file agree
for f in CLAUDE.md settings.json settings.local.json statusline-command.sh tmux-notify.sh; do
    cmp -s "$STATE_DIR/records/claude/repo/$f" "$CL/$f" || fail "R2: repo copy of $f is not what was deployed"
    cmp -s "$STATE_DIR/records/claude/review/$f" "$CL/$f" || fail "R2: review copy of $f is not what was deployed"
done
# Nothing old survives under records/, and no app out of the profile keeps a record
[[ "$(ls -A "$STATE_DIR/records" | sort | tr '\n' ' ')" == "claude dotfiles scripts " ]] \
    || fail "R2: records holds more than the profile's apps: $(ls -A "$STATE_DIR/records")"
[[ ! -e "$STATE_DIR/records/.released" && ! -e "$STATE_DIR/records/.add-saved" ]] || fail "R2: .released or .add-saved survived"
! grep -q 'version: conflict:' "$STATE_DIR"/apps/*.yaml || fail "R2: a conflict state survived: $(grep -h 'version:' "$STATE_DIR"/apps/*.yaml)"
grep -q 'version: abc123' "$STATE_DIR/apps/ghost.yaml" || fail "R2: the out-of-profile app's state is not settled: $(cat "$STATE_DIR/apps/ghost.yaml")"
# The files of the app out of the profile are left alone, and said so in the summary
[[ "$(cat "$HOME/.ghost.conf")" == "data, edited" ]] || fail "R2: a file of an app out of the profile changed"
[[ "$OUT" == *"$HOME/.ghost.conf is not managed by ghost in this profile and has local edits"* ]] || fail "R2: the summary does not name it: $OUT"
# Status reads clean
ST=$(status_out)
for label in "unreviewed changes" conflicts dismissed; do
    grep -qx "$label: none" <<< "$ST" || fail "R2: status is not clean ($label): $ST"
done
# A snapshot holds the old content, drop-in included
SNAP_CL=$(grep -rl "my own line" "$HOME/.bak/claude" | head -1) || true
[[ -n "$SNAP_CL" && "$(basename "$SNAP_CL")" == CLAUDE.md && "$(dirname "$SNAP_CL")" != */original ]] || fail "R2: no snapshot of the edited CLAUDE.md"
grep -rq "localOnly" "$HOME/.bak/claude" || fail "R2: no snapshot of the local-only key"
grep -rq "# drop-in edit" "$HOME/.bak/dotfiles" || fail "R2: no snapshot of the edited drop-in: $(find "$HOME/.bak/dotfiles")"
# A second reset has nothing to lose
rerun yes reset
[[ $RC -eq 0 && "$OUT" == *"no local changes would be lost"* ]] || fail "R2: a clean host still lists losses: rc=$RC $OUT"
pass "reset lists the losses and makes every managed file the repo's, with fresh records"

# Case R3
info "Case R3: --yes never resets; a run with no terminal does not reset either"
fresh_host
make_local_state
run_init --yes
[[ $RC -eq 0 ]] || fail "R3: --yes failed ($RC): $OUT"
[[ "$OUT" != *"Reset every"* ]] || fail "R3: --yes asked about a reset: $OUT"
live_local_state_held || fail "R3: --yes lost local edits"
printf '%s\n' reset reset | DOTFILES_INIT_ASSUME_TTY=1 PATH="$T/nosudo:$PATH" "$DF/dotfiles" init --yes >/dev/null 2>&1 || fail "R3: --yes with answers on stdin failed"
live_local_state_held || fail "R3: --yes with 'reset' on stdin lost local edits"
run_init
[[ $RC -eq 1 && "$OUT" == *"init is interactive"* ]] || fail "R3: no terminal and no --yes: rc=$RC $OUT"
live_local_state_held || fail "R3: a refused run lost local edits"
# A terminal that can't be read: no answer, a normal pull
RC=0
OUT=$(DOTFILES_INIT_ASSUME_TTY=1 PATH="$T/nosudo:$PATH" "$DF/dotfiles" init < <(printf '\n\n\n\n') 2>&1) || RC=$?
[[ $RC -eq 0 && "$OUT" == *"Not resetting"* ]] || fail "R3: no answer at the question: rc=$RC $OUT"
live_local_state_held || fail "R3: no answer lost local edits"
pass "--yes and a missing terminal never reset"

# Case R4
info "Case R4: a failed snapshot stops a reset with nothing changed"
fresh_host
make_local_state
rm -rf "$HOME/.bak/claude"
: > "$HOME/.bak/claude"
SUM_BEFORE=$(tree_sum)
rerun yes reset
[[ $RC -eq 1 ]] || fail "R4: expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"nothing was reset"* ]] || fail "R4: no explanation: $OUT"
[[ "$(tree_sum)" == "$SUM_BEFORE" ]] || fail "R4: files or records changed after a failed snapshot"
live_local_state_held || fail "R4: local edits lost"
rm -f "$HOME/.bak/claude"
rerun yes reset
[[ $RC -eq 0 ]] || fail "R4: the retry failed ($RC): $OUT"
[[ "$(jq -r '.localOnly // "gone"' "$CL/settings.json")" == gone ]] || fail "R4: the retry did not reset: $OUT"
pass "snapshot failure: exit 1, nothing changed; the retry resets"

# Case R5
info "Case R5: an interrupted reset: the failing file is reported and left, the rest reset, and init again finishes"
fresh_host
make_local_state
echo "{ not json" > "$DF/apps/claude/files/settings.json"
rerun yes reset
[[ $RC -ne 0 ]] || fail "R5: a reset with a broken layer file exited 0: $OUT"
[[ "$OUT" == *"settings.json"* && "$OUT" == *"FAIL"* ]] || fail "R5: the failing file is not reported: $OUT"
# The broken file is left as it was; the other files of the app and the other apps reset
[[ "$(jq -r .localOnly.mine "$CL/settings.json")" == true ]] || fail "R5: the file that failed was changed"
cmp -s "$T/records-before/claude/repo/CLAUDE.md" "$CL/CLAUDE.md" || fail "R5: CLAUDE.md was not reset"
cmp -s "$T/records-before/claude/repo/tmux-notify.sh" "$CL/tmux-notify.sh" || fail "R5: tmux-notify.sh was not reset"
cmp -s "$T/records-before/dotfiles/repo/90-dotfiles.sh" "$HOME/.bashrc.d/90-dotfiles.sh" || fail "R5: the drop-in was not reset"
# Its record is the one it had, so the edit is still seen as one
grep -q settings.json "$STATE_DIR/records/claude/manifest.tsv" || fail "R5: the record of the failed file is gone"
[[ ! -e "$STATE_DIR/records/.released" && ! -e "$STATE_DIR/records/.add-saved" && ! -d "$STATE_DIR/records/ghost" ]] || fail "R5: the old leftovers were not cleared"
# Fix the file and run init again: the reset finishes
cp "$T/records-before/claude/repo/settings.json" "$DF/apps/claude/files/settings.json"
rerun yes reset
[[ $RC -eq 0 ]] || fail "R5: the second reset failed ($RC): $OUT"
[[ "$(jq -r '.localOnly // "gone"' "$CL/settings.json")" == gone ]] || fail "R5: the second reset left the local-only key"
ST=$(status_out)
for label in "unreviewed changes" conflicts dismissed; do
    grep -qx "$label: none" <<< "$ST" || fail "R5: status is not clean after finishing ($label): $ST"
done
pass "a failing file is reported and left; init again finishes the reset"

# Case R6
info "Case R6: a tool's drop-in is reset, and a snapshot holds its old content"
fresh_host dropin
[[ -f "$HOME/.bashrc.d/50-lazygit.sh" ]] || fail "R6: the lazygit drop-in was not deployed: $OUT"
echo "alias lg='my-lazygit'" > "$HOME/.bashrc.d/50-lazygit.sh"
cp "$DF/apps/lazygit/files/50-lazygit.sh" "$T/50-lazygit.repo"
echo "# local line" >> "$HOME/.bashrc.d/90-dotfiles.sh"
rerun yes reset
[[ $RC -eq 0 ]] || fail "R6: reset failed ($RC): $OUT"
[[ "$OUT" == *"~/.bashrc.d/50-lazygit.sh"* ]] || fail "R6: the edited tool drop-in is not listed: $OUT"
cmp -s "$T/50-lazygit.repo" "$HOME/.bashrc.d/50-lazygit.sh" || fail "R6: the tool drop-in is not the repo's"
grep -rqF "my-lazygit" "$HOME/.bak/lazygit" || fail "R6: no snapshot of the old tool drop-in: $(find "$HOME/.bak" -type f)"
grep -rqF "# local line" "$HOME/.bak/dotfiles" || fail "R6: no snapshot of the old login drop-in"
cmp -s "$STATE_DIR/records/lazygit/repo/50-lazygit.sh" "$HOME/.bashrc.d/50-lazygit.sh" || fail "R6: the drop-in's record is not fresh"
ST=$(status_out)
grep -qx "unreviewed changes: none" <<< "$ST" || fail "R6: status is not clean: $ST"
pass "tool and login drop-ins reset, with snapshots"

# Case R7
info "Case R7: only the committed layers deploy in a reset, with git"
fresh_host
GITDF="$T/dotfiles-git"
rm -rf "$GITDF"
cp -R "$DF" "$GITDF"
git -C "$GITDF" init -q -b main
git -C "$GITDF" add -A
git -C "$GITDF" commit -q -m committed
echo "# uncommitted layer change" >> "$GITDF/apps/claude/files/CLAUDE.md"
echo "my own line" >> "$CL/CLAUDE.md"
RC=0
OUT=$(printf '%s\n' "" "" "" "" yes reset | DOTFILES_INIT_ASSUME_TTY=1 PATH="$T/nosudo:$PATH" "$GITDF/dotfiles" init 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "R7: reset failed ($RC): $OUT"
cmp -s "$T/records-before/claude/repo/CLAUDE.md" "$CL/CLAUDE.md" || fail "R7: CLAUDE.md is not the committed layer: $(cat "$CL/CLAUDE.md")"
! grep -q "uncommitted layer change" "$CL/CLAUDE.md" || fail "R7: an uncommitted layer change deployed"
pass "a reset deploys the committed layers"

# Case O1
info "Case O1: a host with only old records: no question; snapshot, fresh records, local-only keys kept"
fresh_host
echo "my own line" >> "$CL/CLAUDE.md"
jq '.localOnly = {"mine": true}' "$CL/settings.json" > "$T/s.json"
cp "$T/s.json" "$CL/settings.json"
cp "$CL/settings.json" "$T/settings.before"
# The records of an older version: only deployed/*.tsv
rm -rf "$STATE_DIR/records"
mkdir -p "$STATE_DIR/deployed"
printf 'abc\tCLAUDE.md\t%s\n' "$CL/CLAUDE.md" > "$STATE_DIR/deployed/claude.tsv"
printf 'abc\tsettings.json\t%s\n' "$CL/settings.json" >> "$STATE_DIR/deployed/claude.tsv"
echo "# login edit" >> "$HOME/.bashrc.d/90-dotfiles.sh"
echo "mine" > "$HOME/.bashrc.d/00-local.sh"
RC=0
OUT=$("$DF/dotfiles" pull 2>&1 </dev/null) || RC=$?
[[ $RC -eq 1 && "$OUT" == *"Run 'dotfiles init' to start fresh records"* ]] || fail "O1: pull does not point at init: rc=$RC $OUT"
rerun
[[ $RC -eq 0 ]] || fail "O1: init failed ($RC): $OUT"
[[ "$OUT" != *"Reset every"* ]] || fail "O1: asked about a reset: $OUT"
[[ ! -e "$STATE_DIR/deployed" ]] || fail "O1: old records survived"
grep -rqF "my own line" "$HOME/.bak/claude" || fail "O1: no snapshot of the edited CLAUDE.md"
grep -rqF "localOnly" "$HOME/.bak/claude" || fail "O1: no snapshot of the merged file"
grep -rqF "# login edit" "$HOME/.bak/dotfiles" || fail "O1: no snapshot of the drop-in"
cmp -s "$T/records-before/claude/repo/CLAUDE.md" "$CL/CLAUDE.md" || fail "O1: a replaced file was not deployed fresh"
[[ "$(jq -r .localOnly.mine "$CL/settings.json")" == true ]] || fail "O1: a local-only key of a merged file was lost"
[[ "$(jq -r .profileKey "$CL/settings.json")" == true ]] || fail "O1: the repo's keys are missing from the merged file"
[[ "$(cat "$HOME/.bashrc.d/00-local.sh")" == mine ]] || fail "O1: 00-local.sh changed"
cmp -s "$T/records-before/dotfiles/repo/90-dotfiles.sh" "$HOME/.bashrc.d/90-dotfiles.sh" || fail "O1: the drop-in is not fresh"
for f in CLAUDE.md settings.json; do
    [[ -s "$STATE_DIR/records/claude/repo/$f" && -s "$STATE_DIR/records/claude/review/$f" ]] || fail "O1: no fresh record of $f"
done
ST=$(status_out)
grep -qx "unreviewed changes: none" <<< "$ST" || fail "O1: status after the move: $ST"
RC=0
"$DF/dotfiles" pull >/dev/null 2>&1 </dev/null || RC=$?
[[ $RC -eq 0 ]] || fail "O1: pull after the move failed"
# The next re-run is a normal one, with the question
rerun
[[ "$OUT" == *"Reset every managed file"* ]] || fail "O1: the next init does not ask about a reset: $OUT"
pass "old records: snapshot, removed, deployed fresh, local-only keys kept"

# Case O2
info "Case O2: a failed snapshot in the move changes nothing; once fixed, init moves and the next one asks"
fresh_host
echo "my own line" >> "$CL/CLAUDE.md"
rm -rf "$STATE_DIR/records"
mkdir -p "$STATE_DIR/deployed"
printf 'abc\tCLAUDE.md\t%s\n' "$CL/CLAUDE.md" > "$STATE_DIR/deployed/claude.tsv"
rm -rf "$HOME/.bak/claude"
: > "$HOME/.bak/claude"
SUM_BEFORE=$(tree_sum)
rerun
[[ $RC -eq 1 ]] || fail "O2: expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"nothing was changed"* ]] || fail "O2: no explanation: $OUT"
[[ "$(tree_sum)" == "$SUM_BEFORE" ]] || fail "O2: something changed after a failed snapshot"
[[ -f "$STATE_DIR/deployed/claude.tsv" ]] || fail "O2: the old records went"
rm -f "$HOME/.bak/claude"
rerun
[[ $RC -eq 0 && ! -e "$STATE_DIR/deployed" ]] || fail "O2: the retry did not move: rc=$RC $OUT"
grep -rqF "my own line" "$HOME/.bak/claude" || fail "O2: no snapshot after the retry"
rerun
[[ "$OUT" == *"Reset every managed file"* ]] || fail "O2: the next init does not ask about a reset: $OUT"
pass "failed snapshot in the move: nothing changed, then a normal re-run with the question"

# Case F1
info "Case F1: when status can't tell what a reset loses, no reset is offered"
fresh_host
echo "# local login edit" >> "$HOME/.bashrc.d/90-dotfiles.sh"
# A layer file the app doesn't deploy makes the overlays invalid
mkdir -p "$HD/hosts/testhost/apps/claude/files"
echo stray > "$HD/hosts/testhost/apps/claude/files/bogus.txt"
rerun yes reset
rm -f "$HD/hosts/testhost/apps/claude/files/bogus.txt"
[[ "$OUT" != *"no local changes would be lost"* ]] || fail "F1: said nothing would be lost: $OUT"
[[ "$OUT" != *"Reset every managed file"* && "$OUT" != *"Type 'reset'"* ]] || fail "F1: a reset was offered: $OUT"
[[ "$OUT" == *"Can't tell what a reset would lose"* ]] || fail "F1: no reason given: $OUT"
grep -qx "# local login edit" "$HOME/.bashrc.d/90-dotfiles.sh" || fail "F1: the login drop-in was reset anyway"
pass "an unreadable status means no reset is offered"

# Case F2
info "Case F2: files with no record that a reset overwrites are listed, and snapshotted"
fresh_host noclaude
[[ ! -e "$CL/settings.json" ]] || fail "F2: setup: claude files already there"
mkdir -p "$CL"
echo '{"mine": 1}' > "$CL/settings.json"
echo "my notes" > "$CL/CLAUDE.md"
rerun_as testhost yes reset
[[ $RC -eq 0 ]] || fail "F2: reset failed ($RC): $OUT"
LISTED="${OUT#*This would be lost:}"
LISTED="${LISTED%%00-local.sh and .gitconfig.local are not touched*}"
[[ "$LISTED" == *"no record"* && "$LISTED" == *"~/.claude/settings.json"* && "$LISTED" == *"~/.claude/CLAUDE.md"* ]] \
    || fail "F2: the files with no record are not listed: $LISTED"
[[ "$LISTED" != *"no local changes would be lost"* ]] || fail "F2: said nothing would be lost: $LISTED"
[[ "$(jq -r '.mine // "gone"' "$CL/settings.json")" == gone ]] || fail "F2: the reset did not overwrite settings.json"
grep -rqF "my notes" "$HOME/.bak/claude" || fail "F2: no snapshot of the file with no record"
grep -rqF '"mine"' "$HOME/.bak/claude" || fail "F2: no snapshot of the merged file with no record"
pass "files with no record are listed and snapshotted"

# Case F3
info "Case F3: init reads host.yaml and profiles from the committed hosts repo"
HG="$T/hosts-git"
rm -rf "$HG"
cp -R "$TEST_DIR/fixtures/hosts-dir" "$HG"
git -C "$HG" init -q -b main
git -C "$HG" add -A
git -C "$HG" commit -q -m fixture
rm -f "$CFG" "$CFG.bak"
mkdir -p "$HG/hosts/newhost"
printf 'profile: minimal\n' > "$HG/hosts/newhost/host.yaml"
printf 'packages:\n  - scripts\n' > "$HG/profiles/unco.yaml"
run_init --yes --no-sync --hosts-dir "$HG" --hostname newhost
[[ $RC -eq 1 ]] || fail "F3: an uncommitted host.yaml: expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"not committed"* && "$OUT" == *"Commit it, then run init again"* ]] || fail "F3: no explanation: $OUT"
[[ ! -e "$CFG" ]] || fail "F3: the config was written"
run_init --yes --no-sync --hosts-dir "$HG" --hostname testhost --profile unco
[[ $RC -eq 1 && "$OUT" == *"profile 'unco' not found"* ]] || fail "F3: an uncommitted profile was accepted: rc=$RC $OUT"
[[ ! -e "$CFG" ]] || fail "F3: the config was written for an uncommitted profile"
run_interactive "$HG" "nohost" "" "" ""
[[ $RC -eq 0 ]] || fail "F3: interactive init failed ($RC): $OUT"
LIST=$(grep -a '^profiles: ' <<< "$OUT") || fail "F3: no profile list: $OUT"
[[ "$LIST" != *unco* ]] || fail "F3: an uncommitted profile is listed: $LIST"
# A committed host.yaml is what counts, whatever the working tree says
rm -f "$CFG"
rm "$HG/hosts/testhost/host.yaml"
run_init --yes --no-sync --hosts-dir "$HG" --hostname testhost
[[ $RC -eq 0 && "$OUT" == *"testhost/host.yaml found (profile: base)"* ]] || fail "F3: the committed host.yaml was not used: rc=$RC $OUT"
# Committing it is what makes it count
git -C "$HG" checkout -q -- hosts/testhost/host.yaml
git -C "$HG" add -A
git -C "$HG" commit -q -m more
rm -f "$CFG"
run_init --yes --no-sync --hosts-dir "$HG" --hostname newhost
[[ $RC -eq 0 && "$OUT" == *"newhost/host.yaml found (profile: minimal)"* ]] || fail "F3: a committed host.yaml was refused: rc=$RC $OUT"
pass "uncommitted host.yaml and profiles are refused; committed ones are used"

# Case F5
info "Case F5: a login drop-in that can't be reset fails the run and the reset is not finished"
fresh_host
make_local_state
chmod 444 "$HOME/.bashrc.d/90-dotfiles.sh"; chmod 555 "$HOME/.bashrc.d"
rerun yes reset
chmod 755 "$HOME/.bashrc.d"; chmod 644 "$HOME/.bashrc.d/90-dotfiles.sh"
[[ $RC -ne 0 ]] || fail "F5: a failed drop-in reset exited 0: $OUT"
[[ "$OUT" == *"login drop-in"* && "$OUT" == *"FAIL"* ]] || fail "F5: the failure is not in the summary: $OUT"
[[ "$OUT" == *"reset is not finished"* ]] || fail "F5: not said to be unfinished: $OUT"
[[ -d "$STATE_DIR/records/ghost" && -d "$STATE_DIR/records/.released" ]] || fail "F5: the reset was finished anyway"
rerun yes reset
[[ $RC -eq 0 ]] || fail "F5: the retry failed ($RC): $OUT"
[[ ! -d "$STATE_DIR/records/ghost" && -f "$HOME/.bashrc.d/90-dotfiles.sh" ]] || fail "F5: the retry did not finish the reset"
pass "a failed drop-in reset is a failed run, and init again finishes it"

# Case F6
info "Case F6: two managed files with one name in an app stop the snapshot, with nothing changed"
fresh_host
mkdir -p "$HOME/a" "$HOME/b" "$STATE_DIR/records/dup/repo" "$STATE_DIR/records/dup/review"
echo one > "$HOME/a/x.conf"
echo two > "$HOME/b/x.conf"
printf 'a\t%s\treplace\nb\t%s\treplace\n' "$HOME/a/x.conf" "$HOME/b/x.conf" > "$STATE_DIR/records/dup/manifest.tsv"
echo one > "$STATE_DIR/records/dup/repo/a"; echo one > "$STATE_DIR/records/dup/review/a"
echo two > "$STATE_DIR/records/dup/repo/b"; echo two > "$STATE_DIR/records/dup/review/b"
echo "my own line" >> "$CL/CLAUDE.md"
SUM_BEFORE=$(tree_sum)
rerun yes reset
[[ $RC -eq 1 ]] || fail "F6: expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"share one snapshot path"* && "$OUT" == *"x.conf"* ]] || fail "F6: no explanation: $OUT"
[[ "$(tree_sum)" == "$SUM_BEFORE" ]] || fail "F6: something changed"
grep -qx "my own line" "$CL/CLAUDE.md" || fail "F6: an edit was lost"
pass "a snapshot name collision stops before anything changes"

# Case F7
info "Case F7: a reset names an edited drop-in of a tool out of the profile once, not twice"
fresh_host dropin
echo "alias lg='my-lazygit'" > "$HOME/.bashrc.d/50-lazygit.sh"
rerun_as testhost yes reset
[[ $RC -eq 0 ]] || fail "F7: reset failed ($RC): $OUT"
[[ "$OUT" == *"$HOME/.bashrc.d/50-lazygit.sh is not managed by lazygit in this profile and has local edits; the reset left it in place and stopped tracking it"* ]] \
    || fail "F7: the reset did not name the file: $OUT"
[[ "$OUT" != *"its records are kept"* ]] || fail "F7: contradictory warning: $OUT"
[[ ! -d "$STATE_DIR/records/lazygit" ]] || fail "F7: the records were kept"
pass "one consistent warning"

# Case F10
info "Case F10: a reset on a terminal never runs git-setup or touches .gitconfig.local"
fresh_host gitter
[[ -x "$HOME/.local/bin/git-setup" ]] || fail "F10: setup: git-setup not deployed: $OUT"
printf '[user]\n' > "$HOME/.gitconfig.local"
RC=0
OUT=$( ( sleep 1; for a in "" "" "" "" yes reset; do printf '%s\n' "$a"; sleep 1; done; sleep 3 ) \
    | PATH="$T/fakebin:$T/nosudo:$PATH" script -qec "$DF/dotfiles init" /dev/null 2>&1 ) || RC=$?
[[ $RC -eq 0 ]] || fail "F10: reset failed ($RC): $OUT"
[[ "$OUT" == *"Type 'reset' to go ahead"* ]] || fail "F10: the terminal run never got to the confirmation: $OUT"
[[ "$OUT" != *"running git-setup"* ]] || fail "F10: git-setup ran during a reset: $OUT"
[[ "$(cat "$HOME/.gitconfig.local")" == "[user]" ]] || fail "F10: .gitconfig.local changed: $(cat "$HOME/.gitconfig.local")"
pass "git-setup is skipped during a reset"

# Case F11
# A hosts repo with an origin: ff-work pushes to ff.git, and ff-host is the host's checkout
# of it. The host starts on profile base; the pushed commit moves it to dropprof, which adds
# lazygit and so its drop-in.
ff_setup() {
    rm -rf "$T/ff.git" "$T/ff-work" "$T/ff-host"
    cp -R "$TEST_DIR/fixtures/hosts-dir" "$T/ff-work"
    mkdir -p "$T/ff-work/hosts/ffhost"
    printf 'profile: base\n' > "$T/ff-work/hosts/ffhost/host.yaml"
    printf 'packages:\n  - claude\n  - scripts\n  - lazygit\n' > "$T/ff-work/profiles/dropprof.yaml"
    git -C "$T/ff-work" init -q -b main
    git -C "$T/ff-work" add -A
    git -C "$T/ff-work" commit -q -m base
    git clone -q --bare "$T/ff-work" "$T/ff.git"
    git -C "$T/ff-work" remote add origin "$T/ff.git"
    git -C "$T/ff-work" fetch -q origin
    git -C "$T/ff-work" branch -q -u origin/main main
    git clone -q "$T/ff.git" "$T/ff-host"
    fresh_host ffhost "$T/ff-host"
}
ff_push_profile() {
    printf 'profile: dropprof\n' > "$T/ff-work/hosts/ffhost/host.yaml"
    git -C "$T/ff-work" commit -q -am "ffhost gets lazygit"
    git -C "$T/ff-work" push -q origin main
}

info "Case F11: the repos are brought up to date before a reset is listed and snapshotted"
ff_setup
mkdir -p "$HOME/.bashrc.d"
echo "alias lg='my-own-lazygit'" > "$HOME/.bashrc.d/50-lazygit.sh"
ff_push_profile
rerun_as ffhost yes reset
[[ $RC -eq 0 ]] || fail "F11: reset failed ($RC): $OUT"
LISTED="${OUT#*This would be lost:}"
LISTED="${LISTED%%00-local.sh and .gitconfig.local are not touched*}"
[[ "$LISTED" == *"~/.bashrc.d/50-lazygit.sh"* ]] || fail "F11: the file the update newly manages is not listed: $LISTED"
grep -rqF "my-own-lazygit" "$HOME/.bak/lazygit" || fail "F11: no snapshot of the file the update newly manages: $(find "$HOME/.bak" -type f)"
cmp -s "$DF/apps/lazygit/files/50-lazygit.sh" "$HOME/.bashrc.d/50-lazygit.sh" || fail "F11: the file is not the repo's"
# Saying no still pulls normally
ff_setup
echo "alias lg='my-own-lazygit'" > "$HOME/.bashrc.d/50-lazygit.sh"
ff_push_profile
rerun_as ffhost ""
[[ $RC -eq 0 && "$OUT" == *"Not resetting"* ]] || fail "F11: no: rc=$RC $OUT"
pass "an update that newly manages an existing file is listed and snapshotted"

# Case F12
info "Case F12: a blocked update stops before the question, with nothing changed"
ff_setup
echo "my own line" >> "$CL/CLAUDE.md"
git -C "$T/ff-host" commit -q --allow-empty -m "local commit"
ff_push_profile
SUM_BEFORE=$(tree_sum)
rerun_as ffhost yes reset
[[ $RC -eq 1 ]] || fail "F12: expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"pull blocked"* && "$OUT" == *"git pull --rebase"* ]] || fail "F12: no explanation: $OUT"
[[ "$OUT" != *"Reset every managed file"* ]] || fail "F12: the question was asked: $OUT"
[[ "$(tree_sum)" == "$SUM_BEFORE" ]] || fail "F12: something changed"
pass "a blocked update stops with the rebase instructions"

# Case F13
info "Case F13: a network failure is a warning, and the reset is still offered"
ff_setup
echo "my own line" >> "$CL/CLAUDE.md"
git -C "$T/ff-host" remote set-url origin "file://$T/nowhere.git"
rerun_as ffhost yes reset
[[ $RC -eq 0 ]] || fail "F13: reset failed ($RC): $OUT"
[[ "$OUT" == *"pull failed"* ]] || fail "F13: the failed update was not warned about: $OUT"
[[ "$OUT" == *"Type 'reset' to go ahead"* ]] || fail "F13: no reset was offered: $OUT"
! grep -q "my own line" "$CL/CLAUDE.md" || fail "F13: the reset did not happen"
# A pinned checkout doesn't move
ff_setup
git -C "$T/ff-host" checkout -q --detach
PIN=$(git -C "$T/ff-host" rev-parse HEAD)
ff_push_profile
rerun_as ffhost yes reset
[[ $RC -eq 0 && "$(git -C "$T/ff-host" rev-parse HEAD)" == "$PIN" ]] || fail "F13: a pinned checkout moved: rc=$RC"
pass "network failure warns; a pinned checkout stays"

echo
echo -e "${GREEN}All init tests passed${NC}"
