#!/usr/bin/env bash
# test-sync.sh - dotfiles sync pipeline: lock, ff-only pull, self-install, last-sync

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
echo "Sync Pipeline Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR
HAVE_FLOCK=true
command -v flock >/dev/null 2>&1 || { HAVE_FLOCK=false; info "flock not found: lock cases will be skipped"; }
HAVE_RSYNC=true
command -v rsync >/dev/null 2>&1 || HAVE_RSYNC=false
# Copy a tree without .git (rsync, or cp fallback)
copy_tree() {
    if [[ "$HAVE_RSYNC" == true ]]; then
        rsync -a --delete --exclude .git "$1"/ "$2"/
    else
        mkdir -p "$2"
        (cd "$1" && tar --exclude=.git -cf - .) | (cd "$2" && tar -xf -)
    fi
}
T="/tmp/dotfiles-test-sync-$$"
HOLDER=""
cleanup() {
    [[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null || true
    rm -rf "$T"
}
trap cleanup EXIT
rm -rf "$T"
mkdir -p "$T/home" "$T/state/apps"
export HOME="$T/home"
export STATE_DIR="$T/state"
export XDG_STATE_HOME="$T/xdg-state"
export DOTFILES_CONFIG="$T/config"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_TERMINAL_PROMPT=0
: > "$GIT_CONFIG_GLOBAL"

ORIGIN="$T/origin.git"
WORK="$T/work"
mkdir -p "$WORK"

# Origin, the repo under test and an "author" clone that pushes new commits.
# Both clones get the current working-tree code, committed as "wip".
git clone -q --bare "$ROOT_DIR" "$ORIGIN"
git clone -q "$ORIGIN" "$WORK/dotfiles"
git clone -q "$ORIGIN" "$WORK/author"
for r in dotfiles author; do
    git -C "$WORK/$r" config user.name tester
    git -C "$WORK/$r" config user.email tester@example.com
done
copy_tree "$ROOT_DIR" "$WORK/dotfiles"
git -C "$WORK/dotfiles" add -A
git -C "$WORK/dotfiles" commit -q --allow-empty -m wip
git -C "$WORK/dotfiles" push -q origin HEAD
git -C "$WORK/author" pull -q

cp -R "$TEST_DIR/fixtures/hosts-dir" "$T/hosts-dir"
cat > "$T/config" <<EOF
hosts_dir: $T/hosts-dir
hostname: testhost
EOF

STATE="$XDG_STATE_HOME/dotfiles"
OUT=""
RC=0
# A sudo that always fails, so no case can reach the real sudo (--auto installs
# for real when sudo -n succeeds). Cases that need another sudo set SUDOBIN.
NOSUDO="$T/nosudo"
mkdir -p "$NOSUDO"
printf '#!/bin/sh\nexit 1\n' > "$NOSUDO/sudo"
chmod +x "$NOSUDO/sudo"
SUDOBIN="$NOSUDO"
# Run the repo's dotfiles with args, capture output in OUT and exit code in RC
run() {
    RC=0
    OUT=$(PATH="$SUDOBIN:$PATH" "$WORK/dotfiles/dotfiles" "$@" --no-backup --skip-git-setup 2>&1) || RC=$?
}
author_commit() {
    local file="$1" content="$2"
    echo "$content" > "$WORK/author/$file"
    git -C "$WORK/author" add "$file"
    git -C "$WORK/author" commit -q -m "author $file"
    git -C "$WORK/author" push -q origin HEAD
}

# Case 1
info "Case 1: self-install"
run sync
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
[[ -L "$HOME/.local/bin/dotfiles" ]] || fail "no symlink"
[[ "$(readlink "$HOME/.local/bin/dotfiles")" == "$WORK/dotfiles/dotfiles" ]] || fail "wrong symlink target"
cmp -s "$WORK/dotfiles/lib/login.sh" "$HOME/.bashrc.d/90-dotfiles.sh" || fail "drop-in differs from lib/login.sh"
run sync
[[ $RC -eq 0 ]] || fail "second sync failed: $OUT"
[[ -L "$HOME/.local/bin/dotfiles" ]] && cmp -s "$WORK/dotfiles/lib/login.sh" "$HOME/.bashrc.d/90-dotfiles.sh" \
    || fail "self-install not kept"
pass "symlink and drop-in installed, idempotent"

# Case 2
info "Case 2: fast-forward pull"
author_commit PULLTEST one
run sync
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
[[ -f "$WORK/dotfiles/PULLTEST" ]] || fail "PULLTEST not pulled: $OUT"
pass "pulled new commit"

# Case 3
info "Case 3: --no-pull"
author_commit NOPULL two
run sync --no-pull
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
[[ ! -f "$WORK/dotfiles/NOPULL" ]] || fail "--no-pull still pulled"
pass "--no-pull skips pull"

# Case 4
info "Case 4: diverged history"
echo local > "$WORK/dotfiles/LOCALONLY"
git -C "$WORK/dotfiles" add LOCALONLY
git -C "$WORK/dotfiles" commit -q -m "local commit"
LOCAL_SHA=$(git -C "$WORK/dotfiles" rev-parse HEAD)
author_commit OTHER three
run sync
[[ $RC -eq 0 ]] || fail "sync should still succeed: $OUT"
[[ "$OUT" == *"pull failed"* ]] || fail "no pull failed warning: $OUT"
[[ "$OUT" != *"operation(s) failed"* ]] || fail "pull failure counted as failed operation: $OUT"
[[ "$(git -C "$WORK/dotfiles" rev-parse HEAD)" == "$LOCAL_SHA" ]] || fail "local HEAD moved"
pass "diverged pull warns, repo untouched"

# Case 5
info "Case 5: dirty conflicting tree"
git -C "$WORK/dotfiles" fetch -q
git -C "$WORK/dotfiles" reset -q --hard '@{u}'
author_commit PULLTEST changed-upstream
echo changed-locally > "$WORK/dotfiles/PULLTEST"
run sync
[[ $RC -eq 0 ]] || fail "sync should still succeed: $OUT"
[[ "$OUT" == *"pull failed"* ]] || fail "no pull failed warning: $OUT"
[[ "$(cat "$WORK/dotfiles/PULLTEST")" == "changed-locally" ]] || fail "local modification lost"
git -C "$WORK/dotfiles" diff --quiet && fail "git diff is empty"
git -C "$WORK/dotfiles" checkout -q -- PULLTEST
pass "dirty tree kept, warning shown"

# Case 5b
info "Case 5b: user autoStash/rebase config is ignored"
git -C "$WORK/dotfiles" config merge.autoStash true
git -C "$WORK/dotfiles" config rebase.autoStash true
git -C "$WORK/dotfiles" config pull.rebase true
echo changed-locally > "$WORK/dotfiles/PULLTEST"
run sync
[[ $RC -eq 0 ]] || fail "sync should still succeed: $OUT"
[[ "$OUT" == *"pull failed"* ]] || fail "no pull failed warning: $OUT"
[[ "$(cat "$WORK/dotfiles/PULLTEST")" == "changed-locally" ]] || fail "local modification lost"
[[ -z "$(git -C "$WORK/dotfiles" stash list)" ]] || fail "a stash entry was created"
git -C "$WORK/dotfiles" checkout -q -- PULLTEST
git -C "$WORK/dotfiles" config --unset merge.autoStash
git -C "$WORK/dotfiles" config --unset rebase.autoStash
git -C "$WORK/dotfiles" config --unset pull.rebase
pass "no stash or rebase despite user config"

# Case 6
info "Case 6: non-git dotfiles repo"
copy_tree "$WORK/dotfiles" "$T/nogit"
cat > "$T/config-nogit" <<EOF
hosts_dir: $T/hosts-dir
hostname: testhost
EOF
RC=0
OUT=$(DOTFILES_CONFIG="$T/config-nogit" "$T/nogit/dotfiles" sync --no-backup --skip-git-setup 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
[[ "$OUT" != *"pull failed"* ]] || fail "unexpected pull warning: $OUT"
pass "non-git repo skipped silently"

# Case 7
info "Case 7: lock held"
if [[ "$HAVE_FLOCK" != true ]]; then
    info "skipped (no flock)"
else
mkdir -p "$STATE"
( flock 9; exec sleep 30 ) 9>"$STATE/lock" &
HOLDER=$!
for _ in $(seq 1 50); do
    flock -n "$STATE/lock" true 2>/dev/null || break
    sleep 0.1
done
flock -n "$STATE/lock" true 2>/dev/null && fail "lock holder did not take the lock"
run sync
[[ $RC -eq 1 ]] || fail "expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"already running"* ]] || fail "no 'already running': $OUT"
run sync --auto
[[ $RC -eq 0 ]] || fail "--auto should exit 0, got $RC: $OUT"
[[ "$OUT" != *"Phase"* ]] || fail "--auto deployed while locked: $OUT"
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null || true; HOLDER=""
run sync
[[ $RC -eq 0 ]] || fail "sync after release failed: $OUT"
pass "lock held, then released"
fi

# Case 8
info "Case 8: last-sync"
rm -f "$STATE/last-sync"
run sync
[[ $RC -eq 0 && -f "$STATE/last-sync" ]] || fail "last-sync missing after success"
touch -d '2000-01-01' "$STATE/last-sync"
run sync --hostname typo
[[ $RC -ne 0 ]] || fail "expected validation failure: $OUT"
[[ "$STATE/last-sync" -nt "$T/config" ]] || fail "last-sync not touched after failure"
pass "last-sync recorded on success and failure"

# Case 9
info "Case 9: interactive sync clears report"
echo x > "$STATE/report"
run sync
[[ ! -e "$STATE/report" ]] || fail "report not cleared"
pass "report cleared"

# Case 10
info "Case 10: children do not inherit the lock"
if [[ "$HAVE_FLOCK" != true ]]; then
    info "skipped (no flock)"
else
    mkdir -p "$WORK/dotfiles/apps/sleeptest"
    cat > "$WORK/dotfiles/apps/sleeptest/configure.sh" <<'EOS'
#!/usr/bin/env bash
# Starts a detached long-lived child, like a tmux server would
(setsid sleep 4711 >/dev/null 2>&1 &)
exit 0
EOS
    cat > "$T/hosts-dir/profiles/sleeper.yaml" <<'EOS'
packages:
  - name: sleeptest
    config:
      dir: sleeptest
EOS
    run sync --profile sleeper --hostname nohost
    [[ $RC -eq 0 ]] || fail "sync failed: $OUT"
    pgrep -f "^sleep 4711" >/dev/null || fail "test child was not started"
    LOCK_FREE=true
    flock -n "$STATE/lock" true || LOCK_FREE=false
    pkill -f "^sleep 4711" || true
    [[ "$LOCK_FREE" == true ]] || fail "lock still held after sync exited (fd leaked to child)"
    pass "lock free after sync with a detached child"
fi

# Helpers for --auto cases
LOG="$STATE/last-sync.log"
age_last_sync() { mkdir -p "$STATE"; touch -d '5 hours ago' "$STATE/last-sync"; }
FAKEBIN="$T/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\ntouch "%s/sudo-called"\necho "$*" >> "%s/sudo-args"\nexit 1\n' "$T" "$T" > "$FAKEBIN/sudo"
chmod +x "$FAKEBIN/sudo"
PATH_ORIG="$PATH"
cp "$T/config" "$T/config.orig"

# Case 11
info "Case 11: throttle"
rm -f "$LOG" "$STATE/report"
touch "$STATE/last-sync"
BEFORE=$(stat -c %Y "$STATE/last-sync")
run sync --auto
[[ $RC -eq 0 ]] || fail "throttled --auto should exit 0: $OUT"
[[ ! -e "$LOG" ]] || fail "throttled --auto wrote a log"
[[ ! -e "$STATE/report" ]] || fail "throttled --auto wrote a report"
[[ "$(stat -c %Y "$STATE/last-sync")" == "$BEFORE" ]] || fail "throttled --auto touched last-sync"
age_last_sync
run sync --auto
[[ $RC -eq 0 ]] || fail "--auto failed: $OUT"
[[ -f "$LOG" ]] || fail "no log after --auto"
[[ "$(head -1 "$LOG")" == "dotfiles sync --auto "* ]] || fail "bad log header: $(head -1 "$LOG")"
[[ "$STATE/last-sync" -nt "$T/config" ]] || fail "last-sync not touched by --auto"
pass "throttle skips recent, runs old and logs"

# Case 12
info "Case 12: auto_sync=off"
echo "auto_sync: off" >> "$T/config"
age_last_sync
OLDSUM=$(cksum < "$LOG")
OLDTIME=$(stat -c %Y "$STATE/last-sync")
run sync --auto
[[ $RC -eq 0 ]] || fail "--auto with auto_sync=off should exit 0: $OUT"
[[ "$(cksum < "$LOG")" == "$OLDSUM" ]] || fail "log changed with auto_sync=off"
[[ "$(stat -c %Y "$STATE/last-sync")" == "$OLDTIME" ]] || fail "last-sync touched with auto_sync=off"
cp "$T/config.orig" "$T/config"
pass "auto_sync=off leaves everything alone"

# Case 13
info "Case 13: config-only with pending packages"
sed -i 's/^hostname: .*/hostname: nohost/' "$T/config"
echo "profile: pendingtest" >> "$T/config"
rm -rf "$HOME/.bashrc.d/50-testtool.sh" "$HOME/.claude" "$STATE/report" "$T/sudo-called" "$T/sudo-args"
age_last_sync
RC=0
OUT=$(PATH="$FAKEBIN:$PATH_ORIG" "$WORK/dotfiles/dotfiles" sync --auto --no-backup 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "--auto failed: $OUT / $(cat "$LOG")"
# The only sudo call allowed is the passwordless probe (-n true)
[[ ! -e "$T/sudo-called" ]] || [[ "$(cat "$T/sudo-args")" == "-n true" ]] || fail "--auto called sudo: $(cat "$T/sudo-args")"
{ grep -qx nonexistent-pkg "$STATE/pending" && grep -qx faketool "$STATE/pending"; } \
    || fail "pending missing entries: $(cat "$STATE/pending")"
[[ -s "$STATE/report" ]] || fail "no report (configs were updated)"
if grep -q "pending" "$STATE/report"; then fail "report has a pending line: $(cat "$STATE/report")"; fi
[[ ! -e "$HOME/.bashrc.d/50-testtool.sh" ]] || fail "drop-in deployed although its check fails"
grep -q "faketool: drop-in held until the tool is installed" "$LOG" || fail "no held message: $(cat "$LOG")"
[[ -f "$HOME/.claude/settings.json" ]] || fail "claude configs not deployed"
pass "config-only, pending recorded, no pending line in report, drop-in held"

# Case 14
info "Case 14: updated apps in report"
cp "$T/config.orig" "$T/config"
echo "profile: base" >> "$T/config"
OLD_HOME="$HOME"; OLD_STATE_DIR="$STATE_DIR"; OLD_XDG="$XDG_STATE_HOME"; OLD_STATE="$STATE"
export HOME="$T/home2" STATE_DIR="$T/state2" XDG_STATE_HOME="$T/xdg-state2"
mkdir -p "$HOME" "$STATE_DIR/apps"
STATE="$XDG_STATE_HOME/dotfiles"; LOG="$STATE/last-sync.log"
run sync --auto
[[ $RC -eq 0 ]] || fail "--auto failed: $OUT / $(cat "$LOG")"
grep -q '^dotfiles: updated claude, scripts' "$STATE/report" || fail "bad report: $(cat "$STATE/report" 2>&1)"
age_last_sync
run sync --auto
[[ ! -e "$STATE/report" ]] || fail "report written without changes: $(cat "$STATE/report")"
echo "# changed" >> "$T/hosts-dir/profiles/base/apps/claude/files/tmux-notify.sh"
age_last_sync
run sync --auto
grep -q '^dotfiles: updated claude$' "$STATE/report" || fail "bad report after change: $(cat "$STATE/report" 2>&1)"
pass "updated apps reported once"

# Case 15
info "Case 15: pull failure in report"
age_last_sync
git -C "$WORK/dotfiles" fetch -q
git -C "$WORK/dotfiles" reset -q --hard '@{u}'
echo local2 > "$WORK/dotfiles/LOCAL2"
git -C "$WORK/dotfiles" add LOCAL2
git -C "$WORK/dotfiles" commit -q -m "local commit 2"
author_commit OTHER2 four
run sync --auto
[[ $RC -eq 0 ]] || fail "pull failure changed exit code: $OUT"
grep -q "^dotfiles: $WORK/dotfiles: pull failed (.*) — see " "$STATE/report" \
    || fail "no pull failure in report: $(cat "$STATE/report" 2>&1)"
if grep -q "sync failed" "$STATE/report"; then fail "pull failure reported as sync failed"; fi
git -C "$WORK/dotfiles" fetch -q
git -C "$WORK/dotfiles" reset -q --hard '@{u}'
pass "pull failure reported"

# Case 16
info "Case 16: validation failure in --auto"
sed -i 's/^hostname: .*/hostname: typo/' "$T/config"
age_last_sync
rm -f "$STATE/report"
run sync --auto
[[ $RC -ne 0 ]] || fail "expected failure: $OUT"
grep -q '^dotfiles: sync failed (' "$STATE/report" || fail "no failure report: $(cat "$STATE/report" 2>&1)"
[[ "$STATE/last-sync" -nt "$T/config" ]] || fail "last-sync not touched after failure"
export HOME="$OLD_HOME" STATE_DIR="$OLD_STATE_DIR" XDG_STATE_HOME="$OLD_XDG"
STATE="$OLD_STATE"
cp "$T/config.orig" "$T/config"
pass "validation failure reported, last-sync touched"

# Case 16b
info "Case 16b: failed installer is not reported as updated"
cp -R "$TEST_DIR/fixtures/hosts-dir" "$T/hosts-bad"
sed -i "s#^hosts_dir: .*#hosts_dir: $T/hosts-bad#; s/^hostname: .*/hostname: badjson/" "$T/config"
export HOME="$T/home3" STATE_DIR="$T/state3" XDG_STATE_HOME="$T/xdg-state3"
mkdir -p "$HOME" "$STATE_DIR/apps"
STATE="$XDG_STATE_HOME/dotfiles"
run sync --auto
grep -q 'sync failed (' "$STATE/report" || fail "no failure report: $(cat "$STATE/report" 2>&1) / $OUT"
if grep -q 'updated claude' "$STATE/report"; then fail "failed app reported as updated: $(cat "$STATE/report")"; fi
export HOME="$OLD_HOME" STATE_DIR="$OLD_STATE_DIR" XDG_STATE_HOME="$OLD_XDG"
STATE="$OLD_STATE"
cp "$T/config.orig" "$T/config"
pass "failed installer: failure reported, not updated"

# Case 16c
info "Case 16c: early abort still reports a failure"
sed -i "s#^hosts_dir: .*#hosts_dir: /nonexistent#" "$T/config"
age_last_sync
rm -f "$STATE/report"
run sync --auto
[[ $RC -ne 0 ]] || fail "expected failure: $OUT"
grep -q 'sync failed (setup)' "$STATE/report" || fail "no setup failure report: $(cat "$STATE/report" 2>&1)"
[[ "$STATE/last-sync" -nt "$T/config" ]] || fail "last-sync not touched"
cp "$T/config.orig" "$T/config"
pass "early abort reported as setup failure"

# Case 16d
info "Case 16d: last-sync in the future does not throttle"
LOG="$STATE/last-sync.log"
touch -d '+2 days' "$STATE/last-sync"
rm -f "$LOG"
run sync --auto
[[ -f "$LOG" ]] || fail "future last-sync throttled the run"
pass "clock skew runs the sync"

# Case 17
info "Case 17: login drop-in"
mkdir -p "$WORK/bin" "$STATE"
printf '#!/bin/sh\necho "$@" >> "%s/calls"\n' "$WORK" > "$WORK/bin/dotfiles"
chmod +x "$WORK/bin/dotfiles"
rm -f "$WORK/calls"
DROPIN="$HOME/.bashrc.d/90-dotfiles.sh"
[[ -f "$DROPIN" ]] || fail "drop-in not installed at $DROPIN"
echo "dotfiles: hello" > "$STATE/report"
LOGIN_OUT=$(PATH="$WORK/bin:$PATH_ORIG" bash --norc --noprofile -i -c "source '$DROPIN'" 2>/dev/null)
[[ "$LOGIN_OUT" == *"dotfiles: hello"* ]] || fail "report not shown: $LOGIN_OUT"
[[ ! -e "$STATE/report" ]] || fail "report not deleted"
for _ in $(seq 1 20); do grep -q 'sync --auto' "$WORK/calls" 2>/dev/null && break; sleep 0.1; done
grep -q 'sync --auto' "$WORK/calls" || fail "background sync not started"
rm -f "$WORK/calls"
PATH="$WORK/bin:$PATH_ORIG" DOTFILES_NO_AUTO_SYNC=1 bash --norc --noprofile -i -c "source '$DROPIN'" >/dev/null 2>&1
sleep 0.5
[[ ! -e "$WORK/calls" ]] || fail "DOTFILES_NO_AUTO_SYNC ignored"
echo "dotfiles: hello" > "$STATE/report"
LOGIN_OUT=$(PATH="$WORK/bin:$PATH_ORIG" bash --norc -c "source '$DROPIN'" 2>&1)
sleep 0.5
[[ -z "$LOGIN_OUT" ]] || fail "non-interactive shell printed: $LOGIN_OUT"
[[ ! -e "$WORK/calls" ]] || fail "non-interactive shell started a sync"
[[ -e "$STATE/report" ]] || fail "non-interactive shell consumed the report"
rm -f "$STATE/report"
pass "login drop-in: report, auto sync, opt-out, non-interactive"

# Case 18
info "Case 18: command works through symlinks (absolute, relative, PATH)"
OUT=$("$HOME/.local/bin/dotfiles" status 2>&1) || fail "symlinked status failed: $OUT"
[[ "$OUT" == *"dotfiles repo:"* ]] || fail "symlinked status output: $OUT"
mkdir -p "$T/rel/bin"
ln -s ../../work/dotfiles/dotfiles "$T/rel/bin/dotfiles"
OUT=$("$T/rel/bin/dotfiles" status 2>&1) || fail "relative symlink status failed: $OUT"
[[ "$OUT" == *"dotfiles repo:"* ]] || fail "relative symlink output: $OUT"
ln -s rel/bin/dotfiles "$T/chain"
OUT=$("$T/chain" status 2>&1) || fail "chained symlink status failed: $OUT"
[[ "$OUT" == *"dotfiles repo:"* ]] || fail "chained symlink output: $OUT"
OUT=$(PATH="$HOME/.local/bin:$PATH_ORIG" dotfiles status 2>&1) || fail "PATH status failed: $OUT"
[[ "$OUT" == *"dotfiles repo:"* ]] || fail "PATH status output: $OUT"
pass "symlinked command resolves its repo"

# Case 19
info "Case 19: self-install creates the link only when missing or dangling"
cp -R "$WORK/dotfiles" "$WORK/other"
echo "# running-checkout marker" >> "$WORK/other/lib/login.sh"
OLD_HOME="$HOME"; OLD_STATE_DIR="$STATE_DIR"; OLD_XDG="$XDG_STATE_HOME"; OLD_STATE="$STATE"
export HOME="$T/home4" STATE_DIR="$T/state4" XDG_STATE_HOME="$T/xdg-state4"
mkdir -p "$HOME" "$STATE_DIR/apps"
SELF="$HOME/.local/bin/dotfiles"
selfrun() { OUT=$("$WORK/other/dotfiles" sync --no-pull --no-backup --skip-git-setup 2>&1) || fail "sync from other checkout failed: $OUT"; }
# (a) no link: created, pointing at the running checkout
selfrun
[[ "$(readlink "$SELF")" == "$WORK/other/dotfiles" ]] || fail "(a) link not created: $(readlink "$SELF")"
# (b) a valid link to checkout A while running from B: unchanged, with a warning,
# and the drop-in comes from A
rm "$SELF"; ln -s "$WORK/dotfiles/dotfiles" "$SELF"
selfrun
[[ "$(readlink "$SELF")" == "$WORK/dotfiles/dotfiles" ]] || fail "(b) valid link re-pointed: $(readlink "$SELF")"
[[ "$OUT" == *"leaving it"* ]] || fail "(b) no 'leaving it' warning: $OUT"
cmp -s "$WORK/dotfiles/lib/login.sh" "$HOME/.bashrc.d/90-dotfiles.sh" || fail "(b) drop-in not taken from the linked checkout"
# (c) a dangling link: re-created to the running checkout
rm "$SELF"; ln -s "$T/does-not-exist/dotfiles" "$SELF"
selfrun
[[ "$(readlink "$SELF")" == "$WORK/other/dotfiles" ]] || fail "(c) dangling link not re-created: $(readlink "$SELF")"
# (d) a regular file: untouched, with a warning
rm "$SELF"; echo "#!/bin/sh" > "$SELF"
selfrun
[[ ! -L "$SELF" && "$(cat "$SELF")" == "#!/bin/sh" ]] || fail "(d) regular file replaced"
[[ "$OUT" == *"not a symlink"* ]] || fail "(d) no warning: $OUT"
export HOME="$OLD_HOME" STATE_DIR="$OLD_STATE_DIR" XDG_STATE_HOME="$OLD_XDG"
STATE="$OLD_STATE"
pass "link created only if missing or dangling; valid link or file left with a warning"

# Case 20
info "Case 20: --auto with a bad config reports it, throttled by the default interval"
cp "$T/config.orig" "$T/config"
echo "auto_sync: maybe" >> "$T/config"
rm -f "$STATE/report" "$STATE/last-sync"
run sync --auto
[[ $RC -ne 0 ]] || fail "bad config --auto should fail: $OUT"
grep -q 'sync failed (config)' "$STATE/report" || fail "no config report: $(cat "$STATE/report" 2>&1)"
grep -q 'auto_sync must be' "$STATE/last-sync.log" || fail "error text not in log: $(cat "$STATE/last-sync.log")"
[[ -e "$STATE/last-sync" ]] || fail "last-sync not touched"
rm -f "$STATE/report"
run sync --auto
[[ $RC -eq 0 ]] || fail "second --auto should be throttled (exit 0): $OUT"
[[ ! -e "$STATE/report" ]] || fail "throttled run wrote a report"
cp "$T/config.orig" "$T/config"
echo "hostname: a/b" >> "$T/config"
age_last_sync
run sync --auto
grep -q 'sync failed (config)' "$STATE/report" || fail "bad hostname not reported: $(cat "$STATE/report" 2>&1)"
rm -f "$STATE/report"
cp "$T/config.orig" "$T/config"
echo "auto_sync: maybe" >> "$T/config"
run sync
[[ $RC -eq 1 && "$OUT" == *"auto_sync must be"* ]] || fail "interactive bad config: rc=$RC $OUT"
cp "$T/config.orig" "$T/config"
pass "config error reported once per default interval; interactive still errors"

# Case 21
info "Case 21: pull helper: toplevel check and stall bounds"
REALGIT=$(command -v git)
mkdir -p "$T/gitbin"
printf '#!/bin/sh\necho "GSC=${GIT_SSH_COMMAND:-} $*" >> "%s/gitcalls"\nexec "%s" "$@"\n' "$T" "$REALGIT" > "$T/gitbin/git"
chmod +x "$T/gitbin/git"
git clone -q "$ORIGIN" "$T/outer"
mkdir -p "$T/outer/nested"; echo x > "$T/outer/nested/f"
rm -f "$T/gitcalls"
PULL_OUT=$(PATH="$T/gitbin:$PATH_ORIG" bash -c "
    source '$ROOT_DIR/lib/logging.sh'; source '$ROOT_DIR/lib/sync.sh'
    sync_pull_repo '$T/outer/nested'; echo rc=\$?") || true
[[ "$PULL_OUT" == "rc=0" ]] || fail "nested non-git dir produced output: $PULL_OUT"
if grep -q ' pull ' "$T/gitcalls"; then fail "pull attempted in a non-root directory"; fi
rm -f "$T/gitcalls"
PATH="$T/gitbin:$PATH_ORIG" bash -c "
    source '$ROOT_DIR/lib/logging.sh'; source '$ROOT_DIR/lib/sync.sh'
    SYNC_AUTO=true; sync_pull_repo '$T/outer' >/dev/null 2>&1"
CALL=$(grep ' pull ' "$T/gitcalls") || fail "no pull recorded"
for want in 'http.lowSpeedLimit=1000' 'http.lowSpeedTime=30' 'ConnectTimeout=10' 'ServerAliveInterval=15' 'ServerAliveCountMax=2' 'BatchMode=yes'; do
    [[ "$CALL" == *"$want"* ]] || fail "pull lacks $want: $CALL"
done
rm -f "$T/gitcalls"
PATH="$T/gitbin:$PATH_ORIG" bash -c "
    source '$ROOT_DIR/lib/logging.sh'; source '$ROOT_DIR/lib/sync.sh'
    SYNC_AUTO=false; sync_pull_repo '$T/outer' >/dev/null 2>&1"
CALL=$(grep ' pull ' "$T/gitcalls") || fail "no pull recorded"
[[ "$CALL" == *ConnectTimeout=10* && "$CALL" != *BatchMode* ]] || fail "interactive ssh options wrong: $CALL"
pass "non-root dirs skipped; pull is bounded"

# Case 22
info "Case 22: login drop-in without setsid"
NOSETSID="$T/nosetsid"
mkdir -p "$NOSETSID"
for tool in bash cat rm mkdir sleep; do ln -sf "$(command -v $tool)" "$NOSETSID/$tool"; done
cp "$WORK/bin/dotfiles" "$NOSETSID/dotfiles"
rm -f "$WORK/calls" "$STATE/launch.log"
echo "dotfiles: hello" > "$STATE/report"
LOGIN_OUT=$(PATH="$NOSETSID" bash --norc --noprofile -i -c "source '$DROPIN'" 2>/dev/null)
[[ "$LOGIN_OUT" == *"dotfiles: hello"* ]] || fail "report not shown: $LOGIN_OUT"
for _ in $(seq 1 20); do grep -q 'sync --auto' "$WORK/calls" 2>/dev/null && break; sleep 0.1; done
grep -q 'sync --auto' "$WORK/calls" || fail "background sync not started without setsid"
[[ -e "$STATE/launch.log" ]] || fail "launch.log not written"
pass "drop-in falls back when setsid is missing"

# Helpers for the sudo / pending cases
# Switch to a fresh HOME and state (not restored: these are the last cases)
fresh_env() {
    export HOME="$T/home$1" STATE_DIR="$T/state$1" XDG_STATE_HOME="$T/xdg-state$1"
    mkdir -p "$HOME" "$STATE_DIR/apps"
    STATE="$XDG_STATE_HOME/dotfiles"
    LOG="$STATE/last-sync.log"
}
# A config using the pendingtest profile (no host.yaml for "nohost")
cat > "$T/config-pt" <<EOF
hosts_dir: $T/hosts-dir
hostname: nohost
profile: pendingtest
EOF
# Run --auto with a stdin that is open but never delivers data, so anything
# reading it would block; timeout 20 turns a hang into RC=124.
# setsid drops any controlling terminal (as the login drop-in does), so a test run
# from a terminal still reaches the no-terminal path of the sudo probe.
STDIN_FIFO="$T/stdin.fifo"
mkfifo "$STDIN_FIFO"
DETACH=()
command -v setsid >/dev/null 2>&1 && DETACH=(setsid -w)
NO_TTY_POSSIBLE=true
if [[ ${#DETACH[@]} -eq 0 ]] && { : </dev/tty; } 2>/dev/null; then NO_TTY_POSSIBLE=false; fi
auto_blocking_stdin() {
    local writer
    sleep 60 > "$STDIN_FIFO" &
    writer=$!
    RC=0
    OUT=$(PATH="$SUDOBIN:$PATH_ORIG" timeout 20 ${DETACH[@]+"${DETACH[@]}"} "$WORK/dotfiles/dotfiles" \
        sync --auto --no-backup < "$STDIN_FIFO" 2>&1) || RC=$?
    kill "$writer" 2>/dev/null || true
    wait "$writer" 2>/dev/null || true
}
HAVE_SUDO_PM=false
command -v apt-get >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 && HAVE_SUDO_PM=true

# Case 23
info "Case 23: pending reminder at every terminal, report only once"
LOGIN_SRC="$WORK/dotfiles/lib/login.sh"
REMINDER="dotfiles: lazygit, htop not installed (needs sudo) — run 'dotfiles sync'"
login_run() {
    LOGIN_OUT=$(DOTFILES_NO_AUTO_SYNC=1 PATH="$PATH_ORIG" bash --norc --noprofile -i -c "source '$LOGIN_SRC'" 2>/dev/null)
}
mkdir -p "$STATE"
printf 'lazygit\nhtop\n' > "$STATE/pending"
echo "dotfiles: hello" > "$STATE/report"
login_run; FIRST="$LOGIN_OUT"
login_run; SECOND="$LOGIN_OUT"
[[ "$FIRST" == *"dotfiles: hello"* ]] || fail "report not shown: $FIRST"
[[ "$SECOND" != *"dotfiles: hello"* ]] || fail "report shown twice: $SECOND"
grep -qxF "$REMINDER" <<< "$FIRST" || fail "no reminder in first shell: $FIRST"
grep -qxF "$REMINDER" <<< "$SECOND" || fail "no reminder in second shell: $SECOND"
printf 'lazygit\n\nhtop' > "$STATE/pending"
login_run
grep -qxF "$REMINDER" <<< "$LOGIN_OUT" || fail "blank line / no final newline broke the reminder: $LOGIN_OUT"
: > "$STATE/pending"
login_run
[[ "$LOGIN_OUT" != *"not installed"* ]] || fail "reminder with empty pending: $LOGIN_OUT"
rm -f "$STATE/pending"
login_run
[[ -z "$LOGIN_OUT" ]] || fail "output without pending file: $LOGIN_OUT"
pass "reminder at every shell while pending; report once; silent when nothing pending"

# Case 24
info "Case 24: a sudo that would prompt does not hang or install"
fresh_env 5
SUDOBIN="$T/promptsudo"
mkdir -p "$SUDOBIN"
cat > "$SUDOBIN/sudo" <<EOS
#!/bin/sh
# -n branch blocks on stdin unless it is /dev/null
if [ "\$1" = "-n" ]; then read -r _; exit 1; fi
echo "\$*" >> "$T/sudo-installs"
exit 0
EOS
chmod +x "$SUDOBIN/sudo"
rm -f "$T/sudo-installs"
DOTFILES_CONFIG="$T/config-pt" auto_blocking_stdin
[[ $RC -ne 124 ]] || fail "--auto hung on the sudo probe"
[[ $RC -eq 0 ]] || fail "--auto failed ($RC): $OUT / $(cat "$LOG" 2>&1)"
[[ ! -e "$T/sudo-installs" ]] || fail "install ran without passwordless sudo: $(cat "$T/sudo-installs")"
if grep -q "passwordless sudo" "$LOG"; then fail "probe treated a failing sudo as passwordless"; fi
grep -qx nonexistent-pkg "$STATE/pending" || fail "pending lacks nonexistent-pkg: $(cat "$STATE/pending")"
pass "prompting sudo: no hang, check-only"

# Case 25
info "Case 25: passwordless sudo installs in the background"
fresh_env 6
SUDOBIN="$T/pwlsudo"
mkdir -p "$SUDOBIN"
cat > "$SUDOBIN/sudo" <<EOS
#!/bin/sh
if [ "\$1" = "-n" ] && [ "\$2" = "true" ]; then exit 0; fi
echo "\$*" >> "$T/sudo-installs"
# Blocks unless stdin is /dev/null
cat >/dev/null
exit 0
EOS
chmod +x "$SUDOBIN/sudo"
rm -f "$T/sudo-installs" "$T/marker"
if [[ "$NO_TTY_POSSIBLE" == true ]]; then
    DOTFILES_TEST_SUDO=1 DOTFILES_TEST_MARKER="$T/marker" DOTFILES_CONFIG="$T/config-pt" auto_blocking_stdin
    [[ $RC -ne 124 ]] || fail "--auto hung during installs"
    [[ $RC -eq 0 ]] || fail "--auto failed ($RC): $OUT / $(cat "$LOG" 2>&1)"
    grep -q "passwordless sudo: installing packages" "$LOG" || fail "log lacks the passwordless note: $(cat "$LOG")"
    if [[ "$HAVE_SUDO_PM" == true ]]; then
        grep -q "^-n .*install.*dotfiles-nonexistent-pkg" "$T/sudo-installs" 2>/dev/null \
            || fail "no sudo -n OS package install recorded: $(cat "$T/sudo-installs" 2>&1)"
        if command -v apt-get >/dev/null 2>&1; then
            grep -q "^-n DEBIAN_FRONTEND=noninteractive apt-get install" "$T/sudo-installs" \
                || fail "apt install not noninteractive: $(cat "$T/sudo-installs")"
        fi
    else
        info "no apt-get/dnf: OS package install check skipped"
    fi
    [[ -e "$T/marker" ]] || fail "custom install script did not run"
    grep -qx -- "-n testtool-install" "$T/sudo-installs" \
        || fail "custom installer's sudo did not get -n: $(cat "$T/sudo-installs" 2>&1)"
    if grep -v '^-n ' "$T/sudo-installs"; then fail "a sudo call under --auto lacked -n"; fi
    [[ ! -e "$HOME/.bashrc.d/50-testtool.sh" ]] || fail "drop-in deployed although check still fails"
    grep -qx faketool "$STATE/pending" || fail "faketool should stay pending (check fails): $(cat "$STATE/pending")"
    pass "passwordless sudo: OS packages and custom scripts installed with sudo -n, stdin closed"
else
    info "Case 25 skipped: no setsid and a terminal is attached"
fi

# Case 25b
info "Case 25b: passwordless sudo but a terminal attached stays check-only"
fresh_env 8
SUDOBIN="$T/pwlsudo"
rm -f "$T/sudo-installs" "$T/marker"
DOTFILES_TEST_HAS_TTY=1 DOTFILES_TEST_SUDO=1 DOTFILES_TEST_MARKER="$T/marker" DOTFILES_CONFIG="$T/config-pt" \
    auto_blocking_stdin
[[ $RC -ne 124 ]] || fail "--auto hung with a terminal attached"
[[ $RC -eq 0 ]] || fail "--auto failed ($RC): $OUT / $(cat "$LOG" 2>&1)"
if grep -q "passwordless sudo" "$LOG"; then fail "installed although a terminal is attached: $(cat "$LOG")"; fi
[[ ! -e "$T/sudo-installs" ]] || fail "sudo install ran with a terminal attached: $(cat "$T/sudo-installs")"
[[ ! -e "$T/marker" ]] || fail "custom install script ran with a terminal attached"
grep -qx nonexistent-pkg "$STATE/pending" || fail "pending lacks nonexistent-pkg: $(cat "$STATE/pending")"
grep -qx faketool "$STATE/pending" || fail "pending lacks faketool: $(cat "$STATE/pending")"
pass "terminal attached: --auto stays check-only even with passwordless sudo"

# Case 26
info "Case 26: a custom drop-in is held until its check passes"
fresh_env 7
SUDOBIN="$FAKEBIN"
cp -R "$TEST_DIR/fixtures/hosts-dir" "$T/hosts-dt"
sed "s#^hosts_dir: .*#hosts_dir: $T/hosts-dt#" "$T/config-pt" > "$T/config-dt"
rm -f "$T/marker"
DOTFILES_TEST_MARKER="$T/marker" DOTFILES_CONFIG="$T/config-dt" run sync --no-pull
[[ -e "$T/marker" ]] || fail "interactive sync did not run the install script: $OUT"
[[ ! -e "$HOME/.bashrc.d/50-testtool.sh" ]] || fail "interactive: drop-in deployed although check fails"
[[ "$OUT" == *"faketool: drop-in held until the tool is installed"* ]] || fail "interactive: no held message: $OUT"
age_last_sync
DOTFILES_CONFIG="$T/config-dt" run sync --auto --no-pull
[[ $RC -eq 0 ]] || fail "--auto failed: $OUT / $(cat "$LOG")"
[[ ! -e "$HOME/.bashrc.d/50-testtool.sh" ]] || fail "--auto: drop-in deployed although check fails"
grep -q "faketool: drop-in held until the tool is installed" "$LOG" || fail "--auto: no held message: $(cat "$LOG")"
sed -i 's/^      check: false$/      check: true/' "$T/hosts-dt/profiles/pendingtest.yaml"
DOTFILES_CONFIG="$T/config-dt" run sync --no-pull
[[ -f "$HOME/.bashrc.d/50-testtool.sh" ]] || fail "drop-in not deployed once check passes: $OUT"
if grep -qx faketool "$STATE/pending"; then fail "faketool still pending"; fi
cat > "$T/hosts-dt/profiles/onlytool.yaml" <<'EOS'
packages:
  - name: faketool
    custom:
      check: true
      script: custom/testtool/install.sh
EOS
echo "dotfiles: stale" > "$STATE/pending"
DOTFILES_CONFIG="$T/config-dt" run sync --no-pull --profile onlytool
[[ $RC -eq 0 ]] || fail "onlytool sync failed: $OUT"
[[ -e "$STATE/pending" && ! -s "$STATE/pending" ]] || fail "pending not emptied: $(cat "$STATE/pending" 2>&1)"
pass "drop-in held while check fails (interactive and --auto), deployed once it passes"

echo
echo "All sync tests passed"
