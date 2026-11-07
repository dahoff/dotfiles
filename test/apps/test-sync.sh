#!/usr/bin/env bash
# test-sync.sh - dotfiles pull pipeline: lock, ff-only pull, self-install, last-sync

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
# A sudo that always fails, so no case can reach the real sudo (a custom install
# script may call it). Cases that need another sudo set SUDOBIN.
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
run pull
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
[[ -L "$HOME/.local/bin/dotfiles" ]] || fail "no symlink"
[[ "$(readlink "$HOME/.local/bin/dotfiles")" == "$WORK/dotfiles/dotfiles" ]] || fail "wrong symlink target"
cmp -s "$WORK/dotfiles/lib/login.sh" "$HOME/.bashrc.d/90-dotfiles.sh" || fail "drop-in differs from lib/login.sh"
run pull
[[ $RC -eq 0 ]] || fail "second sync failed: $OUT"
[[ -L "$HOME/.local/bin/dotfiles" ]] && cmp -s "$WORK/dotfiles/lib/login.sh" "$HOME/.bashrc.d/90-dotfiles.sh" \
    || fail "self-install not kept"
pass "symlink and drop-in installed, idempotent"

# Case 2
info "Case 2: fast-forward pull"
author_commit PULLTEST one
run pull
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
[[ -f "$WORK/dotfiles/PULLTEST" ]] || fail "PULLTEST not pulled: $OUT"
pass "pulled new commit"

# Case 3
info "Case 3: --no-fetch"
author_commit NOPULL two
run pull --no-fetch
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
[[ ! -f "$WORK/dotfiles/NOPULL" ]] || fail "--no-fetch still pulled"
pass "--no-fetch skips pull"

# Case 4
info "Case 4: diverged history"
echo local > "$WORK/dotfiles/LOCALONLY"
git -C "$WORK/dotfiles" add LOCALONLY
git -C "$WORK/dotfiles" commit -q -m "local commit"
LOCAL_SHA=$(git -C "$WORK/dotfiles" rev-parse HEAD)
author_commit OTHER three
rm -f "$HOME/.vimrc" "$HOME/.bashrc.d/90-dotfiles.sh"
run pull
[[ $RC -eq 1 ]] || fail "a diverged pull should stop with 1, got $RC: $OUT"
[[ "$OUT" == *"pull blocked"* && "$OUT" == *"git pull --rebase"* && "$OUT" == *"$WORK/dotfiles"* && "$OUT" == *"dotfiles pull"* ]] \
    || fail "no instructions for a blocked pull: $OUT"
[[ "$(git -C "$WORK/dotfiles" rev-parse HEAD)" == "$LOCAL_SHA" ]] || fail "local HEAD moved"
[[ ! -e "$HOME/.bashrc.d/90-dotfiles.sh" && ! -e "$HOME/.vimrc" ]] || fail "a blocked pull deployed something"
pass "diverged pull stops, repo untouched, nothing deployed"

# Case 5
info "Case 5: dirty conflicting tree"
git -C "$WORK/dotfiles" fetch -q
git -C "$WORK/dotfiles" reset -q --hard '@{u}'
author_commit PULLTEST changed-upstream
echo changed-locally > "$WORK/dotfiles/PULLTEST"
rm -f "$HOME/.bashrc.d/90-dotfiles.sh"
run pull
[[ $RC -eq 1 ]] || fail "a pull that would overwrite local changes should stop with 1, got $RC: $OUT"
[[ "$OUT" == *"pull blocked"* && "$OUT" == *"git pull --rebase"* ]] || fail "no instructions for a blocked pull: $OUT"
[[ "$(cat "$WORK/dotfiles/PULLTEST")" == "changed-locally" ]] || fail "local modification lost"
[[ ! -e "$HOME/.bashrc.d/90-dotfiles.sh" ]] || fail "a blocked pull deployed something"
git -C "$WORK/dotfiles" diff --quiet && fail "git diff is empty"
# Staged, the change blocks the same way
git -C "$WORK/dotfiles" add PULLTEST
run pull
[[ $RC -eq 1 && "$OUT" == *"git pull --rebase"* ]] || fail "staged change did not block: rc=$RC: $OUT"
git -C "$WORK/dotfiles" reset -q --hard
pass "dirty tree kept, pull stopped with instructions"

# Case 5b
info "Case 5b: user autoStash/rebase config is ignored"
git -C "$WORK/dotfiles" config merge.autoStash true
git -C "$WORK/dotfiles" config rebase.autoStash true
git -C "$WORK/dotfiles" config pull.rebase true
echo changed-locally > "$WORK/dotfiles/PULLTEST"
run pull
[[ $RC -eq 1 ]] || fail "expected the pull to stop: rc=$RC: $OUT"
[[ "$OUT" == *"pull blocked"* ]] || fail "no blocked message: $OUT"
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
OUT=$(DOTFILES_CONFIG="$T/config-nogit" "$T/nogit/dotfiles" pull --no-backup --skip-git-setup 2>&1) || RC=$?
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
run pull
[[ $RC -eq 1 ]] || fail "expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"already running"* ]] || fail "no 'already running': $OUT"
run check-updates
[[ $RC -eq 0 ]] || fail "check-updates should exit 0 while locked, got $RC: $OUT"
[[ ! -e "$STATE/last-check" && ! -e "$STATE/report" ]] || fail "check-updates ran while locked"
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null || true; HOLDER=""
run pull
[[ $RC -eq 0 ]] || fail "sync after release failed: $OUT"
pass "lock held, then released"
fi

# Case 8
info "Case 8: last-sync"
rm -f "$STATE/last-sync"
run pull
[[ $RC -eq 0 && -f "$STATE/last-sync" ]] || fail "last-sync missing after success"
touch -d '2000-01-01' "$STATE/last-sync"
run pull --hostname typo
[[ $RC -ne 0 ]] || fail "expected validation failure: $OUT"
[[ "$STATE/last-sync" -nt "$T/config" ]] || fail "last-sync not touched after failure"
pass "last-sync recorded on success and failure"

# Case 9
info "Case 9: interactive sync clears report"
echo x > "$STATE/report"
run pull
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
    chmod +x "$WORK/dotfiles/apps/sleeptest/configure.sh"
    git -C "$WORK/dotfiles" add apps/sleeptest
    git -C "$WORK/dotfiles" commit -q -m "sleeptest"
    cat > "$T/hosts-dir/profiles/sleeper.yaml" <<'EOS'
packages:
  - name: sleeptest
    config:
      dir: sleeptest
EOS
    run pull --profile sleeper --hostname nohost
    [[ $RC -eq 0 ]] || fail "sync failed: $OUT"
    pgrep -f "^sleep 4711" >/dev/null || fail "test child was not started"
    LOCK_FREE=true
    flock -n "$STATE/lock" true || LOCK_FREE=false
    pkill -f "^sleep 4711" || true
    [[ "$LOCK_FREE" == true ]] || fail "lock still held after sync exited (fd leaked to child)"
    pass "lock free after sync with a detached child"
fi

# Helpers shared by the later cases
age_last_sync() { mkdir -p "$STATE"; touch -d '5 hours ago' "$STATE/last-sync"; }
FAKEBIN="$T/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\ntouch "%s/sudo-called"\necho "$*" >> "%s/sudo-args"\nexit 1\n' "$T" "$T" > "$FAKEBIN/sudo"
chmod +x "$FAKEBIN/sudo"
PATH_ORIG="$PATH"
cp "$T/config" "$T/config.orig"

# Case 17
info "Case 17: login drop-in"
mkdir -p "$WORK/bin" "$STATE"
# A stand-in command that logs its arguments, makes noise and is slow: the drop-in
# must start it detached and silent, so the shell never waits for it
cat > "$WORK/bin/dotfiles" <<EOS
#!/bin/sh
echo "\$@" >> "$WORK/calls"
echo NOISE-OUT
echo NOISE-ERR >&2
sleep 3
EOS
chmod +x "$WORK/bin/dotfiles"
rm -f "$WORK/calls"
DROPIN="$HOME/.bashrc.d/90-dotfiles.sh"
[[ -f "$DROPIN" ]] || fail "drop-in not installed at $DROPIN"
echo "dotfiles: hello" > "$STATE/report"
START=$(date +%s%N)
LOGIN_OUT=$(PATH="$WORK/bin:$PATH_ORIG" bash --norc --noprofile -i -c "source '$DROPIN'" 2>"$T/login.err")
ELAPSED=$(( ($(date +%s%N) - START) / 1000000 ))
[[ "$LOGIN_OUT" == "dotfiles: hello" ]] || fail "login output should be just the report: $LOGIN_OUT"
if grep -q NOISE "$T/login.err"; then fail "the check's stderr reached the terminal: $(cat "$T/login.err")"; fi
[[ $ELAPSED -lt 2000 ]] || fail "login waited for the check (${ELAPSED}ms)"
[[ ! -e "$STATE/report" ]] || fail "report not deleted"
for _ in $(seq 1 20); do [[ -s "$WORK/calls" ]] && break; sleep 0.1; done
[[ "$(cat "$WORK/calls")" == "check-updates" ]] || fail "drop-in should run exactly 'dotfiles check-updates': $(cat "$WORK/calls" 2>&1)"
rm -f "$WORK/calls"
PATH="$WORK/bin:$PATH_ORIG" DOTFILES_NO_UPDATE_CHECK=1 bash --norc --noprofile -i -c "source '$DROPIN'" >/dev/null 2>&1
sleep 0.5
[[ ! -e "$WORK/calls" ]] || fail "DOTFILES_NO_UPDATE_CHECK ignored"
PATH="$WORK/bin:$PATH_ORIG" DOTFILES_NO_AUTO_SYNC=1 bash --norc --noprofile -i -c "source '$DROPIN'" >/dev/null 2>&1
for _ in $(seq 1 20); do [[ -s "$WORK/calls" ]] && break; sleep 0.1; done
[[ -s "$WORK/calls" ]] || fail "the old DOTFILES_NO_AUTO_SYNC should no longer be an opt-out"
rm -f "$WORK/calls"
echo "dotfiles: hello" > "$STATE/report"
LOGIN_OUT=$(PATH="$WORK/bin:$PATH_ORIG" bash --norc -c "source '$DROPIN'" 2>&1)
sleep 0.5
[[ -z "$LOGIN_OUT" ]] || fail "non-interactive shell printed: $LOGIN_OUT"
[[ ! -e "$WORK/calls" ]] || fail "non-interactive shell started a check"
[[ -e "$STATE/report" ]] || fail "non-interactive shell consumed the report"
rm -f "$STATE/report"
pass "login drop-in: report, detached quiet check, opt-out, non-interactive"

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
selfrun() { OUT=$("$WORK/other/dotfiles" pull --no-fetch --no-backup --skip-git-setup 2>&1) || fail "sync from other checkout failed: $OUT"; }
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
info "Case 20: a bad config errors, under its old key name too"
cp "$T/config.orig" "$T/config"
echo "auto_sync: maybe" >> "$T/config"
run pull
[[ $RC -eq 1 && "$OUT" == *"auto_sync must be"* ]] || fail "old key, bad value: rc=$RC $OUT"
cp "$T/config.orig" "$T/config"
echo "update_check: maybe" >> "$T/config"
run pull
[[ $RC -eq 1 && "$OUT" == *"update_check must be"* ]] || fail "bad update_check: rc=$RC $OUT"
cp "$T/config.orig" "$T/config"
pass "bad update_check and auto_sync values are errors"

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
    SYNC_BATCH=true; sync_pull_repo '$T/outer' >/dev/null 2>&1"
CALL=$(grep ' pull ' "$T/gitcalls") || fail "no pull recorded"
for want in 'http.lowSpeedLimit=1000' 'http.lowSpeedTime=30' 'ConnectTimeout=10' 'ServerAliveInterval=15' 'ServerAliveCountMax=2' 'BatchMode=yes'; do
    [[ "$CALL" == *"$want"* ]] || fail "pull lacks $want: $CALL"
done
rm -f "$T/gitcalls"
PATH="$T/gitbin:$PATH_ORIG" bash -c "
    source '$ROOT_DIR/lib/logging.sh'; source '$ROOT_DIR/lib/sync.sh'
    SYNC_BATCH=false; sync_pull_repo '$T/outer' >/dev/null 2>&1"
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
[[ "$LOGIN_OUT" == "dotfiles: hello" ]] || fail "login output should be just the report: $LOGIN_OUT"
for _ in $(seq 1 20); do [[ -s "$WORK/calls" ]] && break; sleep 0.1; done
[[ "$(cat "$WORK/calls")" == "check-updates" ]] || fail "check not started without setsid: $(cat "$WORK/calls" 2>&1)"
[[ -e "$STATE/launch.log" ]] || fail "launch.log not written"
pass "drop-in falls back when setsid is missing"

# Helpers for the sudo / pending cases
# Switch to a fresh HOME and state (not restored: these are the last cases)
fresh_env() {
    export HOME="$T/home$1" STATE_DIR="$T/state$1" XDG_STATE_HOME="$T/xdg-state$1"
    mkdir -p "$HOME" "$STATE_DIR/apps"
    STATE="$XDG_STATE_HOME/dotfiles"
}
# A config using the pendingtest profile (no host.yaml for "nohost")
cat > "$T/config-pt" <<EOF
hosts_dir: $T/hosts-dir
hostname: nohost
profile: pendingtest
EOF

# Case 23
info "Case 23: pending reminder at every terminal, report only once"
LOGIN_SRC="$WORK/dotfiles/lib/login.sh"
REMINDER="dotfiles: lazygit, htop not installed (needs sudo) — run 'dotfiles pull'"
login_run() {
    LOGIN_OUT=$(DOTFILES_NO_UPDATE_CHECK=1 PATH="$PATH_ORIG" bash --norc --noprofile -i -c "source '$LOGIN_SRC'" 2>/dev/null)
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

# Case 26
info "Case 26: a custom drop-in is held until its check passes"
fresh_env 7
SUDOBIN="$FAKEBIN"
cp -R "$TEST_DIR/fixtures/hosts-dir" "$T/hosts-dt"
sed "s#^hosts_dir: .*#hosts_dir: $T/hosts-dt#" "$T/config-pt" > "$T/config-dt"
rm -f "$T/marker"
DOTFILES_TEST_MARKER="$T/marker" DOTFILES_CONFIG="$T/config-dt" run pull --no-fetch
[[ -e "$T/marker" ]] || fail "interactive sync did not run the install script: $OUT"
[[ ! -e "$HOME/.bashrc.d/50-testtool.sh" ]] || fail "interactive: drop-in deployed although check fails"
[[ "$OUT" == *"faketool: drop-in held until the tool is installed"* ]] || fail "interactive: no held message: $OUT"
sed -i 's/^      check: false$/      check: true/' "$T/hosts-dt/profiles/pendingtest.yaml"
DOTFILES_CONFIG="$T/config-dt" run pull --no-fetch
[[ -f "$HOME/.bashrc.d/50-testtool.sh" ]] || fail "drop-in not deployed once check passes: $OUT"
if grep -qx faketool "$STATE/pending"; then fail "faketool still pending"; fi
cat > "$T/hosts-dt/profiles/onlytool.yaml" <<'EOS'
packages:
  - name: faketool
    custom:
      check: true
      script: ../test/fixtures/testtool/install.sh
EOS
echo "dotfiles: stale" > "$STATE/pending"
DOTFILES_CONFIG="$T/config-dt" run pull --no-fetch --profile onlytool
[[ $RC -eq 0 ]] || fail "onlytool sync failed: $OUT"
[[ -e "$STATE/pending" && ! -s "$STATE/pending" ]] || fail "pending not emptied: $(cat "$STATE/pending" 2>&1)"
pass "drop-in held while check fails, deployed once it passes"

# Skipping a sync when nothing changed. ~/.vimrc is the probe: a full sync puts
# a deleted copy back, a skipped sync leaves it missing.
fresh_env 9
SUDOBIN="$NOSUDO"
git -C "$WORK/dotfiles" config --unset merge.autoStash || true
git -C "$WORK/dotfiles" config --unset rebase.autoStash || true
git -C "$WORK/dotfiles" config --unset pull.rebase || true
git -C "$WORK/dotfiles" fetch -q
git -C "$WORK/dotfiles" reset -q --hard '@{u}'
git -C "$WORK/dotfiles" clean -fdq
HOSTS_FP="$T/hosts-fp"
mkdir -p "$HOSTS_FP/profiles"
for p in fptest fpother; do
    cat > "$HOSTS_FP/profiles/$p.yaml" <<'EOS'
packages:
  - name: vim
    config:
      dir: vim
EOS
done
cat > "$HOSTS_FP/profiles/fppending.yaml" <<EOS
packages:
  - name: vim
    config:
      dir: vim
  - name: faketool
    custom:
      check: test -e $T/fp-tool
      script: ../test/fixtures/testtool/install.sh
EOS
cat > "$HOSTS_FP/profiles/fpnocheck.yaml" <<'EOS'
packages:
  - name: vim
    config:
      dir: vim
  - name: faketool
    custom:
      script: ../test/fixtures/testtool/install.sh
EOS
hosts_commit() {
    git -C "$HOSTS_FP" add -A
    git -C "$HOSTS_FP" -c user.name=tester -c user.email=tester@example.com commit -q --allow-empty -m "$1"
}
git -C "$HOSTS_FP" init -q
hosts_commit initial
cat > "$T/config-fp" <<EOF
hosts_dir: $HOSTS_FP
hostname: nohost
profile: fptest
EOF
fp_run() { DOTFILES_CONFIG="$T/config-fp" run "$@"; }
VIMRC="$HOME/.vimrc"
# A sync that must do the full work puts the probe back
expect_full() {
    rm -f "$VIMRC"
    fp_run "$@"
    [[ $RC -eq 0 ]] || fail "sync $* failed: $OUT"
    [[ -f "$VIMRC" ]] || fail "sync $* was skipped, should have run in full: $OUT"
}
# A sync that must be skipped leaves the probe missing
expect_skip() {
    rm -f "$VIMRC"
    fp_run "$@"
    [[ $RC -eq 0 ]] || fail "sync $* failed: $OUT"
    [[ ! -f "$VIMRC" ]] || fail "sync $* ran in full, should have been skipped: $OUT"
}

# Case 27
info "Case 27: an unchanged sync is skipped, and still counts as a sync"
expect_full pull
age_last_sync
expect_skip pull
[[ -n "$(find "$STATE/last-sync" -mmin -1)" ]] || fail "skipped sync did not update last-sync"
pass "second sync skipped, last-sync updated"

# Case 28
info "Case 28: --force and --dry-run are never skipped"
expect_full pull --force
rm -f "$VIMRC"
fp_run pull --dry-run
[[ $RC -eq 0 ]] || fail "dry-run failed: $OUT"
[[ "$OUT" == *"Would"* ]] || fail "dry-run was skipped: $OUT"
expect_skip pull
pass "--force runs in full, --dry-run still reports and leaves the skip in place"

# Case 29
info "Case 29: a new commit in either repo runs in full"
author_commit FPNEW one
expect_full pull
[[ -f "$WORK/dotfiles/FPNEW" ]] || fail "FPNEW not pulled: $OUT"
expect_skip pull
echo "# new" > "$HOSTS_FP/NEW"
hosts_commit "hosts change"
expect_full pull
expect_skip pull
pass "commits in the dotfiles and hosts repos each trigger a full sync"

# Case 30
info "Case 30: uncommitted changes are named and not deployed"
VIMSRC="$WORK/dotfiles/apps/vim/files/.vimrc"
echo '" fp-local-edit' >> "$VIMSRC"
expect_skip pull
[[ "$OUT" == *"uncommitted changes that are not deployed"* && "$OUT" == *"apps/vim/files/.vimrc"* ]] \
    || fail "dirty dotfiles repo not named by pull: $OUT"
fp_run pull --force
[[ $RC -eq 0 ]] || fail "forced pull failed: $OUT"
[[ -f "$VIMRC" ]] || fail "forced pull did not deploy"
if grep -q 'fp-local-edit' "$VIMRC"; then fail "uncommitted edit deployed"; fi
fp_run status
[[ "$OUT" == *"not deployed"* && "$OUT" == *"apps/vim/files/.vimrc"* ]] || fail "status does not name the file: $OUT"
git -C "$WORK/dotfiles" checkout -q -- apps/vim/files/.vimrc
fp_run pull
[[ "$OUT" != *"not deployed"* ]] || fail "clean repo still warned: $OUT"
# An untracked file in the hosts repo is named too, and changes nothing
echo untracked > "$HOSTS_FP/UNTRACKED"
expect_skip pull
[[ "$OUT" == *"UNTRACKED"* ]] || fail "untracked hosts file not named: $OUT"
rm -f "$HOSTS_FP/UNTRACKED"
expect_skip pull
pass "uncommitted files are named, never deployed, and do not trigger a sync"

# Case 30b
info "Case 30b: a layer file deploys once committed; a staged save that is reset never does"
LAYER_DIR="$HOSTS_FP/profiles/fptest/apps/vim/files"
mkdir -p "$LAYER_DIR"
echo '" fp-layer' > "$LAYER_DIR/.vimrc"
fp_run pull --force
[[ $RC -eq 0 ]] || fail "pull failed: $OUT"
[[ "$OUT" == *"profiles/fptest/apps/vim/files/.vimrc"* && "$OUT" == *"not deployed"* ]] || fail "layer file not named: $OUT"
if grep -q 'fp-layer' "$VIMRC"; then fail "untracked layer file deployed"; fi
git -C "$HOSTS_FP" add -A
fp_run pull --force
if grep -q 'fp-layer' "$VIMRC"; then fail "staged layer file deployed"; fi
fp_run status
[[ "$OUT" == *"not deployed"* ]] || fail "status silent on staged file: $OUT"
cp "$VIMRC" "$T/vimrc-before"
git -C "$HOSTS_FP" reset -q --hard
git -C "$HOSTS_FP" clean -qfd
fp_run pull --force
cmp -s "$VIMRC" "$T/vimrc-before" || fail "live file changed after the staged save was discarded"
mkdir -p "$LAYER_DIR"
echo '" fp-layer' > "$LAYER_DIR/.vimrc"
hosts_commit "layer"
expect_full pull
grep -q 'fp-layer' "$VIMRC" || fail "committed layer file not deployed"
# Undo it, so later cases see the plain repo
git -C "$HOSTS_FP" rm -q -r profiles/fptest/apps
hosts_commit "unlayer"
expect_full pull
if grep -q 'fp-layer' "$VIMRC"; then fail "removed layer file still deployed"; fi
expect_skip pull
pass "only committed layer files deploy"

# Case 30c
info "Case 30c: a repo with no commits stops the pull and changes nothing"
HOSTS_NC="$T/hosts-nc"
mkdir -p "$HOSTS_NC/profiles"
cp "$HOSTS_FP/profiles/fptest.yaml" "$HOSTS_NC/profiles/"
git -C "$HOSTS_NC" init -q
cat > "$T/config-nc" <<CFG
hosts_dir: $HOSTS_NC
hostname: nohost
profile: fptest
CFG
echo sentinel > "$VIMRC"
RC=0
OUT=$(DOTFILES_CONFIG="$T/config-nc" PATH="$SUDOBIN:$PATH" "$WORK/dotfiles/dotfiles" pull --no-backup --skip-git-setup 2>&1) || RC=$?
[[ $RC -eq 1 ]] || fail "expected exit 1 for a repo with no commits, got $RC: $OUT"
[[ "$OUT" == *"no commits"* ]] || fail "reason not given: $OUT"
[[ "$(cat "$VIMRC")" == "sentinel" ]] || fail "live file changed: $OUT"
pass "no commits: exit 1, nothing deployed"

# Case 30d
info "Case 30d: a network failure warns and deploys HEAD; a blocked hosts repo stops too"
REAL_URL_FP=$(git -C "$WORK/dotfiles" remote get-url origin)
git -C "$WORK/dotfiles" remote set-url origin "$T/does-not-exist.git"
echo '" fp-dirty' >> "$VIMSRC"
rm -f "$VIMRC"
fp_run pull --force
[[ $RC -eq 0 ]] || fail "network failure should not stop the pull: $OUT"
[[ "$OUT" == *"pull failed"* ]] || fail "no warning: $OUT"
[[ -f "$VIMRC" ]] || fail "HEAD was not deployed"
if grep -q 'fp-dirty' "$VIMRC"; then fail "dirty edit deployed after a network failure"; fi
git -C "$WORK/dotfiles" checkout -q -- apps/vim/files/.vimrc
git -C "$WORK/dotfiles" remote set-url origin "$REAL_URL_FP"
# A hosts repo that has diverged from its upstream
HOSTS_UP="$T/hosts-fp-up.git"
git clone -q --bare "$HOSTS_FP" "$HOSTS_UP"
git -C "$HOSTS_FP" remote add origin "$HOSTS_UP"
git -C "$HOSTS_FP" fetch -q origin
git -C "$HOSTS_FP" branch -q --set-upstream-to="origin/$(git -C "$HOSTS_FP" symbolic-ref --short HEAD)"
HOSTS_OTHER="$T/hosts-fp-other"
git clone -q "$HOSTS_UP" "$HOSTS_OTHER"
echo up > "$HOSTS_OTHER/UPSIDE"
git -C "$HOSTS_OTHER" add -A
git -C "$HOSTS_OTHER" -c user.name=tester -c user.email=tester@example.com commit -q -m upside
git -C "$HOSTS_OTHER" push -q origin HEAD
echo down > "$HOSTS_FP/DOWNSIDE"
hosts_commit "downside"
rm -f "$VIMRC"
fp_run pull --force
[[ $RC -eq 1 ]] || fail "diverged hosts repo should stop the pull, got $RC: $OUT"
[[ "$OUT" == *"git pull --rebase"* && "$OUT" == *"$HOSTS_FP"* ]] || fail "hosts repo not named in the instructions: $OUT"
[[ ! -f "$VIMRC" ]] || fail "deployed despite a blocked hosts pull"
# Put the hosts repo back as it was
git -C "$HOSTS_FP" reset -q --hard HEAD~1
git -C "$HOSTS_FP" remote remove origin
fp_run pull --force
[[ $RC -eq 0 ]] || fail "pull after the repair failed: $OUT"
pass "network failure deploys HEAD; a blocked hosts pull stops"

# Case 30e
info "Case 30e: repo_committed_tree: export of HEAD, modes kept, copy inside another repo used as is"
(
    source "$ROOT_DIR/lib/logging.sh"
    source "$ROOT_DIR/lib/sync.sh"
    WORK_DIR="$T/ct-work"
    mkdir -p "$WORK_DIR"
    CT="$T/ct-repo"
    mkdir -p "$CT/sub"
    git -C "$CT" init -q
    printf '#!/bin/sh\n' > "$CT/tool.sh"
    chmod +x "$CT/tool.sh"
    echo committed > "$CT/f"
    echo kept > "$CT/sub/g"
    printf 'ignored export-ignore\n' > "$CT/.gitattributes"
    echo x > "$CT/ignored"
    git -C "$CT" add -A
    git -C "$CT" -c user.name=t -c user.email=t@example.com commit -q -m c
    echo dirty > "$CT/f"
    echo new > "$CT/untracked"
    out=$(repo_committed_tree "$CT")
    [[ "$out" != "$CT" && "$(cat "$out/f")" == committed ]] || fail "export is not HEAD: $out"
    [[ ! -e "$out/untracked" && ! -e "$out/ignored" ]] || fail "untracked or export-ignore file exported"
    [[ -x "$out/tool.sh" ]] || fail "executable bit lost"
    [[ "$(repo_committed_tree "$CT")" == "$out" ]] || fail "export not reused"
    # a subdirectory of a repo is a copy, not a repo of its own
    [[ "$(repo_committed_tree "$CT/sub")" == "$CT/sub" ]] || fail "copy inside a repo not used as it stands"
    # a plain directory
    mkdir "$T/ct-plain"
    [[ "$(repo_committed_tree "$T/ct-plain")" == "$T/ct-plain" ]] || fail "plain dir not used as it stands"
    # no commits
    mkdir "$T/ct-empty"
    git -C "$T/ct-empty" init -q
    rc=0
    repo_committed_tree "$T/ct-empty" >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 1 ]] || fail "no commits should fail with 1, got $rc"
    # dirty warning: silent for a copy, names files for a repo
    [[ -z "$(repo_warn_dirty "$CT/sub" 2>&1)" ]] || fail "warned for a copy inside a repo"
    w=$(repo_warn_dirty "$CT" 2>&1)
    [[ "$w" == *"f"* && "$w" == *"untracked"* && "$w" == *"not deployed"* ]] || fail "dirty warning: $w"
)
pass "repo_committed_tree and repo_warn_dirty"

# Case 30f
info "Case 30f: uncommitted profiles, host.yaml, os-packages.yaml and app configs change nothing, and are named"
# Each broken edit would fail the pull (or move the file) if it were read
probe_deployed() {
    rm -f "$VIMRC"
    fp_run pull --force "$@"
    [[ $RC -eq 0 ]] || fail "uncommitted edit changed the pull ($*): $OUT"
    [[ -f "$VIMRC" ]] || fail "vim not deployed ($*): $OUT"
}
# A committed host directory, then uncommitted edits to it
mkdir -p "$HOSTS_FP/hosts/nohost"
printf 'profile: fptest\n' > "$HOSTS_FP/hosts/nohost/host.yaml"
hosts_commit "host nohost"
printf 'profile: nosuchprofile\n' > "$HOSTS_FP/hosts/nohost/host.yaml"
probe_deployed
[[ "$OUT" == *"hosts/nohost/host.yaml"* && "$OUT" == *"not deployed"* ]] || fail "host.yaml edit not named: $OUT"
printf 'profile: fptest\nexclude:\n  - vim\n' > "$HOSTS_FP/hosts/nohost/host.yaml"
probe_deployed
git -C "$HOSTS_FP" checkout -q -- hosts/nohost/host.yaml
# A new host directory that is not committed
mkdir -p "$HOSTS_FP/hosts/newhost"
printf 'profile: nosuchprofile\n' > "$HOSTS_FP/hosts/newhost/host.yaml"
probe_deployed --hostname newhost
[[ "$OUT" == *"hosts/newhost/host.yaml"* ]] || fail "new host dir not named: $OUT"
fp_run status --hostname newhost
[[ "$OUT" == *"no host directory"* ]] || fail "status read the uncommitted host dir: $OUT"
rm -rf "$HOSTS_FP/hosts/newhost"
# A hosts profile
cp "$HOSTS_FP/profiles/fptest.yaml" "$T/fptest.yaml.orig"
printf 'packages:\n  - name: nosuchtool\n' > "$HOSTS_FP/profiles/fptest.yaml"
probe_deployed
[[ "$OUT" == *"profiles/fptest.yaml"* ]] || fail "profile edit not named: $OUT"
cp "$T/fptest.yaml.orig" "$HOSTS_FP/profiles/fptest.yaml"
# A public profile
author_commit profiles/fpvim.yaml $'packages:\n  - name: vim\n    config:\n      dir: vim'
fp_run pull --profile fpvim
[[ $RC -eq 0 && -f "$WORK/dotfiles/profiles/fpvim.yaml" ]] || fail "public profile not pulled: $OUT"
printf 'packages:\n  - name: nosuchtool\n' > "$WORK/dotfiles/profiles/fpvim.yaml"
probe_deployed --profile fpvim
[[ "$OUT" == *"profiles/fpvim.yaml"* ]] || fail "public profile edit not named: $OUT"
git -C "$WORK/dotfiles" checkout -q -- profiles/fpvim.yaml
# os-packages.yaml: defining vim twice would be an error
printf 'packages:\n  - vim\n' >> "$WORK/dotfiles/apps/os-packages.yaml"
probe_deployed
[[ "$OUT" == *"apps/os-packages.yaml"* ]] || fail "os-packages edit not named: $OUT"
git -C "$WORK/dotfiles" checkout -q -- apps/os-packages.yaml
# An app's config.yaml
sed -i 's#dest: ~/.vimrc#dest: ~/.vimrc-moved#' "$WORK/dotfiles/apps/vim/config.yaml"
probe_deployed
[[ ! -e "$HOME/.vimrc-moved" ]] || fail "uncommitted config.yaml moved the file"
[[ "$OUT" == *"apps/vim/config.yaml"* ]] || fail "config.yaml edit not named: $OUT"
git -C "$WORK/dotfiles" checkout -q -- apps/vim/config.yaml
# The login drop-in comes from the committed lib/login.sh
echo '# uncommitted drop-in change' >> "$WORK/dotfiles/lib/login.sh"
DROPIN=$(find "$HOME" -name 90-dotfiles.sh | head -1)
[[ -n "$DROPIN" ]] || fail "no drop-in installed"
rm -f "$DROPIN"
fp_run pull --force
[[ -f "$DROPIN" ]] || fail "drop-in not reinstalled"
git -C "$WORK/dotfiles" show HEAD:lib/login.sh | cmp -s - "$DROPIN" || fail "uncommitted lib/login.sh reached the drop-in"
git -C "$WORK/dotfiles" checkout -q -- lib/login.sh
# Back to the plain hosts repo
git -C "$HOSTS_FP" rm -q -r hosts
hosts_commit "no host dir"
fp_run pull --force
[[ $RC -eq 0 ]] || fail "pull after the cleanup failed: $OUT"
pass "only committed profiles, host.yaml, os-packages, app configs and login.sh take effect"

# Case 31
info "Case 31: a failed sync is retried with the same commit"
CONFIGURE_GOOD="$T/configure-good.sh"
cp "$WORK/dotfiles/apps/vim/configure.sh" "$CONFIGURE_GOOD"
author_commit apps/vim/configure.sh 'exit 1'
fp_run pull
[[ $RC -ne 0 ]] || fail "broken sync should fail: $OUT"
fp_run pull
[[ $RC -ne 0 ]] || fail "failed sync was not retried: $OUT"
cp "$CONFIGURE_GOOD" "$WORK/author/apps/vim/configure.sh"
git -C "$WORK/author" add apps/vim/configure.sh
git -C "$WORK/author" commit -q -m "repair configure"
git -C "$WORK/author" push -q origin HEAD
expect_full pull
expect_skip pull
pass "failure leaves nothing to skip against; the repaired sync is skipped next time"

# Case 32
info "Case 32: going back to an earlier commit after a failure runs in full"
GOOD_SHA=$(git -C "$WORK/dotfiles" rev-parse HEAD)
echo '" fp-next' >> "$WORK/author/apps/vim/files/.vimrc"
git -C "$WORK/author" add apps/vim/files/.vimrc
git -C "$WORK/author" commit -q -m next
printf 'exit 1\n' > "$WORK/author/apps/vim/configure.sh"
git -C "$WORK/author" add apps/vim/configure.sh
git -C "$WORK/author" commit -q -m "break configure"
git -C "$WORK/author" push -q origin HEAD
fp_run pull
[[ $RC -ne 0 ]] || fail "broken sync should fail: $OUT"
git -C "$WORK/dotfiles" reset -q --hard "$GOOD_SHA"
rm -f "$VIMRC"
fp_run pull --no-fetch
[[ $RC -eq 0 ]] || fail "sync at the good commit failed: $OUT"
[[ -f "$VIMRC" ]] || fail "sync after a failure was skipped: $OUT"
git -C "$WORK/author" revert --no-edit HEAD >/dev/null
git -C "$WORK/author" push -q origin HEAD
git -C "$WORK/dotfiles" pull -q --ff-only
expect_full pull
pass "a failed sync discards the earlier record"

# Case 33
info "Case 33: pending packages are retried"
sed -i 's/^profile: .*/profile: fppending/' "$T/config-fp"
rm -f "$T/fp-tool"
export DOTFILES_TEST_MARKER="$T/marker"
fp_run pull
grep -qx faketool "$STATE/pending" || fail "faketool should be pending: $(cat "$STATE/pending")"
touch "$T/fp-tool"
expect_full pull
[[ ! -s "$STATE/pending" ]] || fail "pending not emptied: $(cat "$STATE/pending")"
expect_skip pull
pass "a sync with pending packages is not skipped next time"

# Case 34
info "Case 34: a custom script without a check still runs on every sync"
sed -i 's/^profile: .*/profile: fpnocheck/' "$T/config-fp"
fp_run pull
rm -f "$T/marker"
expect_full pull
[[ -e "$T/marker" ]] || fail "check-less script did not run: $OUT"
unset DOTFILES_TEST_MARKER
sed -i 's/^profile: .*/profile: fptest/' "$T/config-fp"
pass "check-less custom scripts keep running"

# Case 35
info "Case 35: a changed profile, host or config runs in full"
expect_full pull
expect_skip pull
expect_full pull --profile fpother
expect_full pull
expect_skip pull
expect_full pull --hostname otherhost
expect_full pull
expect_skip pull
sed -i 's/^profile: .*/profile: fpother/' "$T/config-fp"
expect_full pull
sed -i 's/^profile: .*/profile: fptest/' "$T/config-fp"
expect_full pull
pass "profile, hostname and config changes are noticed"

# Case 35b
info "Case 35b: a held conflict turns off the early stop, and resolving it restores it"
expect_full pull
expect_skip pull
expect_full pull
echo '" conflict edit' >> "$VIMRC"
cp "$VIMRC" "$T/vimrc-edited"
printf '" conflict repo\n' >> "$WORK/author/apps/vim/files/.vimrc"
git -C "$WORK/author" add apps/vim/files/.vimrc
git -C "$WORK/author" commit -q -m "conflict repo"
git -C "$WORK/author" push -q origin HEAD
for _ in 1 2; do
    fp_run pull
    [[ $RC -eq 0 ]] || fail "a conflict should not fail the pull: $OUT"
    cmp -s "$VIMRC" "$T/vimrc-edited" || fail "edit overwritten"
    [[ "$OUT" == *"kept your edit to $VIMRC"* ]] || fail "no warning: $OUT"
    [[ ! -e "$STATE/last-complete" ]] || fail "a held conflict counted as complete"
done
fp_run status
[[ "$OUT" == *"conflict"* ]] || fail "status does not show it: $OUT"
fp_run pull --force "$VIMRC"
[[ $RC -eq 0 ]] || fail "--force PATH failed: $OUT"
grep -q '" conflict repo' "$VIMRC" || fail "repo's version not taken"
[[ ! -e "$STATE/last-complete" ]] || fail "--force PATH counted as a complete pull"
fp_run pull
[[ "$OUT" != *"kept your edit"* ]] || fail "still warned: $OUT"
[[ -e "$STATE/last-complete" ]] || fail "resolved pull not complete"
expect_skip pull
pass "a conflict is re-checked until resolved"

# Case 36
info "Case 36: uninstall means the next sync reinstalls"
expect_skip pull
fp_run uninstall
[[ $RC -eq 0 ]] || fail "uninstall failed: $OUT"
expect_full pull
expect_skip pull
fp_run uninstall --dry-run
expect_skip pull
pass "uninstall clears the record, its dry run does not"

# Case 38
info "Case 38: a repo without git history is never skipped"
fresh_env 11
VIMRC="$HOME/.vimrc"
copy_tree "$HOSTS_FP" "$T/hosts-plain"
rm -rf "$T/hosts-plain/.git"
sed "s#^hosts_dir: .*#hosts_dir: $T/hosts-plain#" "$T/config-fp" > "$T/config-plain"
for _ in 1 2; do
    rm -f "$VIMRC"
    DOTFILES_CONFIG="$T/config-plain" run pull
    [[ $RC -eq 0 ]] || fail "sync failed: $OUT"
    [[ -f "$VIMRC" ]] || fail "sync with a plain hosts dir was skipped: $OUT"
done
pass "a plain hosts dir always runs in full"

# Case 39
info "Case 39: a copy inside another git repo is never skipped"
fresh_env 12
VIMRC="$HOME/.vimrc"
PARENT="$T/parent"
mkdir -p "$PARENT"
git -C "$PARENT" init -q
echo 'hosts-nested/' > "$PARENT/.gitignore"
git -C "$PARENT" add .gitignore
git -C "$PARENT" -c user.name=tester -c user.email=tester@example.com commit -q -m initial
cp -R "$T/hosts-plain" "$PARENT/hosts-nested"
sed "s#^hosts_dir: .*#hosts_dir: $PARENT/hosts-nested#" "$T/config-fp" > "$T/config-nested"
for _ in 1 2; do
    rm -f "$VIMRC"
    DOTFILES_CONFIG="$T/config-nested" run pull
    [[ $RC -eq 0 ]] || fail "sync failed: $OUT"
    [[ -f "$VIMRC" ]] || fail "sync with a nested hosts dir was skipped: $OUT"
done
pass "a pushed copy inside a clean parent repo always runs in full"

# Case 40
info "Case 40: pull deploys; pull --no-fetch skips the fetch"
author_commit VERBPULL four
rm -f "$VIMRC"
fp_run pull --force
[[ $RC -eq 0 ]] || fail "pull failed: $OUT"
[[ -f "$VIMRC" ]] || fail "pull did not deploy: $OUT"
[[ -f "$WORK/dotfiles/VERBPULL" ]] || fail "pull did not fetch: $OUT"
author_commit VERBNOFETCH five
fp_run pull --no-fetch
[[ $RC -eq 0 ]] || fail "pull --no-fetch failed: $OUT"
[[ ! -f "$WORK/dotfiles/VERBNOFETCH" ]] || fail "pull --no-fetch still fetched"
pass "pull deploys, --no-fetch skips the fetch"

# Case 41
info "Case 41: sync needs a terminal"
rm -f "$VIMRC"
fp_run sync --force </dev/null
[[ $RC -eq 1 ]] || fail "sync without a terminal should exit 1, got $RC: $OUT"
[[ "$OUT" == *"needs a terminal"* ]] || fail "no 'needs a terminal': $OUT"
[[ ! -f "$VIMRC" ]] || fail "sync without a terminal still deployed: $OUT"
pass "sync without a terminal: exit 1, nothing deployed"

# Case 42
info "Case 42: sync runs add, then pull, with its flags"
rm -f "$VIMRC"
DOTFILES_ADD_ASSUME_TTY=1 fp_run sync --force </dev/null
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
[[ -f "$VIMRC" ]] || fail "sync did not pull (--force not passed on): $OUT"
ADD_LINE=$(grep -n "No local edits" <<< "$OUT" | head -1 | cut -d: -f1)
PULL_LINE=$(grep -n "Phase 1" <<< "$OUT" | head -1 | cut -d: -f1)
[[ -n "$ADD_LINE" && -n "$PULL_LINE" && "$ADD_LINE" -lt "$PULL_LINE" ]] \
    || fail "add did not run before pull (add line '$ADD_LINE', pull line '$PULL_LINE'): $OUT"
# Without --force nothing changed, so pull stops early, after add has run
rm -f "$VIMRC"
DOTFILES_ADD_ASSUME_TTY=1 fp_run sync --no-fetch </dev/null
[[ $RC -eq 0 && "$OUT" == *"No local edits"* && "$OUT" == *"Already up to date"* ]] \
    || fail "sync --no-fetch: rc=$RC: $OUT"
pass "sync: add first, then pull with every flag"

# Case 43
info "Case 43: sync stops when add fails"
rm -f "$VIMRC"
DOTFILES_ADD_ASSUME_TTY=1 fp_run sync --force --profile no-such-profile </dev/null
[[ $RC -ne 0 ]] || fail "sync should fail when add fails: $OUT"
[[ "$OUT" != *"Phase 1"* && ! -f "$VIMRC" ]] || fail "pull ran after add failed: $OUT"
pass "a failed add stops sync before pull"

# Case 44
info "Case 44: sync --dry-run previews the pull and skips add"
rm -f "$VIMRC"
fp_run sync --dry-run </dev/null
[[ $RC -eq 0 ]] || fail "sync --dry-run failed: $OUT"
[[ "$OUT" == *"Skipping 'dotfiles add' in a dry run"* ]] || fail "no note that add was skipped: $OUT"
[[ "$OUT" != *"No local edits"* && "$OUT" != *"needs a terminal"* ]] || fail "add ran or a terminal was demanded: $OUT"
[[ "$OUT" == *"Phase 1"* || "$OUT" == *"Would"* || "$OUT" == *"dry"* ]] || fail "no pull preview: $OUT"
[[ ! -f "$VIMRC" ]] || fail "sync --dry-run deployed: $OUT"
pass "sync --dry-run: pull --dry-run, add skipped"

# Case 45
info "Case 45: pull takes no --auto; push is gone; --no-pull is unknown"
rm -f "$VIMRC"
fp_run pull --auto </dev/null
[[ $RC -eq 1 && "$OUT" == *"Unknown option: --auto"* ]] || fail "pull --auto: rc=$RC: $OUT"
[[ ! -f "$VIMRC" && ! -e "$STATE/last-check" ]] || fail "pull --auto deployed or checked: $OUT"
fp_run sync --auto </dev/null
[[ $RC -eq 1 && "$OUT" == *"Unknown option: --auto"* ]] || fail "sync --auto: rc=$RC: $OUT"
fp_run push x
[[ $RC -eq 1 && "$OUT" == *"pull --remote"* && "$OUT" == *"init --remote"* ]] || fail "push x: rc=$RC: $OUT"
fp_run pull --no-pull
[[ $RC -eq 1 && "$OUT" == *"Unknown option: --no-pull"* ]] || fail "pull --no-pull: rc=$RC: $OUT"
fp_run sync --no-pull </dev/null
[[ $RC -eq 1 && "$OUT" == *"Unknown option: --no-pull"* ]] || fail "sync --no-pull: rc=$RC: $OUT"
pass "--auto rejected everywhere, push replaced, --no-pull rejected"

# The update check: fetch, count, report. It never deploys or installs.
fresh_env 20
CU_BIN="$T/cubin"
mkdir -p "$CU_BIN"
for tool in apt-get apt dnf yum brew pacman sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/pkgcalls"\nexit 1\n' "$tool" "$T" > "$CU_BIN/$tool"
    chmod +x "$CU_BIN/$tool"
done
cat > "$T/config-cu" <<EOF
hosts_dir: $HOSTS_FP
hostname: nohost
profile: fptest
EOF
cu_run() {
    RC=0
    OUT=$(DOTFILES_CONFIG="${CU_CFG:-$T/config-cu}" PATH="$CU_BIN:$PATH" "${CU_CMD:-$WORK/dotfiles/dotfiles}" check-updates </dev/null 2>&1) || RC=$?
}
age_check() { touch -d '5 hours ago' "$STATE/last-check"; }
cu_head() { git -C "$WORK/dotfiles" rev-parse HEAD; }
cu_tracking() { git -C "$WORK/dotfiles" rev-parse '@{u}'; }
CU_BRANCH=$(git -C "$WORK/dotfiles" symbolic-ref --short HEAD)
git -C "$WORK/dotfiles" reset -q --hard
git -C "$WORK/dotfiles" clean -fdq
git -C "$WORK/dotfiles" fetch -q
git -C "$WORK/dotfiles" reset -q --hard '@{u}'

# Case 46
info "Case 46: an upstream commit ahead is reported, and nothing else happens"
author_commit CUNEW one
HEAD_BEFORE=$(cu_head)
rm -f "$T/pkgcalls"
cu_run
[[ $RC -eq 0 ]] || fail "check-updates failed: $OUT"
[[ -z "$OUT" ]] || fail "check-updates should be silent: $OUT"
[[ -s "$STATE/report" ]] || fail "no report"
grep -q 'updates available' "$STATE/report" || fail "report lacks 'updates available': $(cat "$STATE/report")"
grep -q "dotfiles pull" "$STATE/report" || fail "report lacks 'dotfiles pull': $(cat "$STATE/report")"
[[ "$(wc -l < "$STATE/report")" -eq 1 ]] || fail "report should be one line: $(cat "$STATE/report")"
[[ "$(cu_head)" == "$HEAD_BEFORE" ]] || fail "HEAD moved"
[[ ! -e "$WORK/dotfiles/CUNEW" ]] || fail "the new commit reached the working tree"
[[ "$(git -C "$WORK/dotfiles" rev-list --count 'HEAD..@{u}')" == 1 ]] || fail "the upstream commit was not fetched"
[[ -z "$(git -C "$WORK/dotfiles" status --porcelain)" ]] || fail "working tree changed"
[[ -z "$(find "$HOME" -mindepth 1 2>/dev/null)" ]] || fail "files appeared under HOME: $(find "$HOME" -mindepth 1)"
[[ ! -e "$T/pkgcalls" ]] || fail "a package command ran: $(cat "$T/pkgcalls")"
[[ -e "$STATE/last-check" ]] || fail "no last-check"
[[ ! -e "$STATE/last-sync" && ! -e "$STATE/pending" ]] || fail "check-updates touched pull's state"
[[ ! -d "$STATE/lock.d" ]] || fail "lock left behind"
if [[ "$HAVE_FLOCK" == true ]]; then flock -n "$STATE/lock" true || fail "lock still held"; fi
pass "report written; HEAD, tree, HOME and packages untouched"

# Case 47
info "Case 47: a second run inside the interval does nothing"
rm -f "$STATE/report"
author_commit CUNEW2 two
TRACK_BEFORE=$(cu_tracking)
CHECK_MTIME=$(stat -c %Y "$STATE/last-check")
cu_run
[[ $RC -eq 0 && -z "$OUT" ]] || fail "throttled run: rc=$RC: $OUT"
[[ ! -e "$STATE/report" ]] || fail "throttled run wrote a report"
[[ "$(cu_tracking)" == "$TRACK_BEFORE" ]] || fail "throttled run fetched"
[[ "$(stat -c %Y "$STATE/last-check")" == "$CHECK_MTIME" ]] || fail "throttled run touched last-check"
age_check
cu_run
[[ -s "$STATE/report" ]] || fail "no report once the interval passed"
[[ "$(cu_tracking)" != "$TRACK_BEFORE" ]] || fail "no fetch once the interval passed"
[[ -n "$(find "$STATE/last-check" -mmin -1)" ]] || fail "last-check not touched"
pass "throttled by last-check, runs again when it is old"

# Case 48
info "Case 48: update_check_interval is the boundary; the default is 4h"
cp "$T/config-cu" "$T/config-cu30"
echo "update_check_interval: 30m" >> "$T/config-cu30"
rm -f "$STATE/report"
touch -d '29 minutes ago' "$STATE/last-check"
CU_CFG="$T/config-cu30" cu_run
[[ ! -e "$STATE/report" ]] || fail "ran 29m after the last check with a 30m interval"
touch -d '31 minutes ago' "$STATE/last-check"
CU_CFG="$T/config-cu30" cu_run
[[ -s "$STATE/report" ]] || fail "did not run 31m after the last check with a 30m interval"
rm -f "$STATE/report"
touch -d '3 hours ago' "$STATE/last-check"
author_commit CUNEW3 three
cu_run
[[ ! -e "$STATE/report" ]] || fail "default interval is shorter than 4h"
touch -d '+2 days' "$STATE/last-check"
cu_run
[[ -s "$STATE/report" ]] || fail "a last-check in the future (clock skew) blocked the check"
rm -f "$STATE/last-check"
rm -f "$STATE/report"
cu_run
[[ -s "$STATE/report" ]] || fail "first run (no last-check) did not check"
pass "interval boundary, default, clock skew and first run"

# Case 49
info "Case 49: update_check off does nothing, under both key names"
for key in update_check auto_sync; do
    cp "$T/config-cu" "$T/config-cu-off"
    echo "$key: off" >> "$T/config-cu-off"
    rm -f "$STATE/report"
    age_check
    author_commit "CUOFF-$key" off
    TRACK_BEFORE=$(cu_tracking)
    CHECK_MTIME=$(stat -c %Y "$STATE/last-check")
    CU_CFG="$T/config-cu-off" cu_run
    [[ $RC -eq 0 && -z "$OUT" ]] || fail "$key off: rc=$RC: $OUT"
    [[ ! -e "$STATE/report" ]] || fail "$key off wrote a report"
    [[ "$(cu_tracking)" == "$TRACK_BEFORE" ]] || fail "$key off fetched"
    [[ "$(stat -c %Y "$STATE/last-check")" == "$CHECK_MTIME" ]] || fail "$key off touched last-check"
done
cp "$T/config-cu" "$T/config-cu-alias"
echo "auto_sync_interval: 10m" >> "$T/config-cu-alias"
touch -d '11 minutes ago' "$STATE/last-check"
CU_CFG="$T/config-cu-alias" cu_run
[[ -s "$STATE/report" ]] || fail "auto_sync_interval alias ignored"
pass "off respected; old key names still work"

# Case 50
info "Case 50: a bad config writes no report and exits 1"
rm -f "$STATE/report"
age_check
cp "$T/config-cu" "$T/config-cu-bad"
echo "update_check: maybe" >> "$T/config-cu-bad"
CU_CFG="$T/config-cu-bad" cu_run
[[ $RC -eq 1 && "$OUT" == *"update_check must be"* ]] || fail "bad config: rc=$RC: $OUT"
[[ ! -e "$STATE/report" ]] || fail "bad config wrote a report"
pass "bad config is an error, not a report"

# Case 51
info "Case 51: nothing to report when up to date; an old report is left alone"
git -C "$WORK/dotfiles" pull -q --ff-only
age_check
echo "dotfiles: older report" > "$STATE/report"
cu_run
[[ $RC -eq 0 && -z "$OUT" ]] || fail "up to date: rc=$RC: $OUT"
[[ "$(cat "$STATE/report")" == "dotfiles: older report" ]] || fail "report changed when up to date: $(cat "$STATE/report")"
rm -f "$STATE/report"
age_check
cu_run
[[ ! -e "$STATE/report" ]] || fail "report written when up to date"
pass "up to date: no report"

# Case 52
info "Case 52: a pinned repo is not checked"
author_commit CUPIN one
git -C "$WORK/dotfiles" checkout -q --detach
TRACK_BEFORE=$(git -C "$WORK/dotfiles" rev-parse origin/"$CU_BRANCH")
age_check
rm -f "$STATE/report"
cu_run
[[ $RC -eq 0 && -z "$OUT" ]] || fail "pinned: rc=$RC: $OUT"
[[ ! -e "$STATE/report" ]] || fail "pinned repo reported: $(cat "$STATE/report")"
[[ "$(git -C "$WORK/dotfiles" rev-parse origin/"$CU_BRANCH")" == "$TRACK_BEFORE" ]] || fail "pinned repo was fetched"
git -C "$WORK/dotfiles" checkout -q "$CU_BRANCH"
git -C "$WORK/dotfiles" pull -q --ff-only
pass "pinned: no fetch, no report"

# Case 53
info "Case 53: no git, or no upstream, writes no report"
copy_tree "$WORK/dotfiles" "$T/cu-nogit"
copy_tree "$HOSTS_FP" "$T/cu-hosts-nogit"
sed "s#^hosts_dir: .*#hosts_dir: $T/cu-hosts-nogit#" "$T/config-cu" > "$T/config-cu-nogit"
rm -f "$STATE/report" "$STATE/last-check"
CU_CMD="$T/cu-nogit/dotfiles" CU_CFG="$T/config-cu-nogit" cu_run
[[ $RC -eq 0 && -z "$OUT" ]] || fail "no git: rc=$RC: $OUT"
[[ ! -e "$STATE/report" ]] || fail "no git: report written"
# A repo without an upstream (own history, no remote), with a hosts repo without one too
copy_tree "$WORK/dotfiles" "$T/cu-noup"
git -C "$T/cu-noup" init -q
git -C "$T/cu-noup" add -A
git -C "$T/cu-noup" -c user.name=tester -c user.email=tester@example.com commit -q -m init
rm -f "$STATE/report" "$STATE/last-check"
CU_CMD="$T/cu-noup/dotfiles" cu_run
[[ $RC -eq 0 && -z "$OUT" ]] || fail "no upstream: rc=$RC: $OUT"
[[ ! -e "$STATE/report" ]] || fail "no upstream: report written"
# A copy inside another repo's tree is not a checkout of its own
mkdir -p "$WORK/dotfiles/cu-sub"
copy_tree "$T/cu-nogit" "$WORK/dotfiles/cu-sub"
rm -f "$STATE/last-check"
CU_CMD="$WORK/dotfiles/cu-sub/dotfiles" cu_run
[[ $RC -eq 0 && ! -e "$STATE/report" ]] || fail "nested copy: rc=$RC report=$(cat "$STATE/report" 2>&1)"
rm -rf "$WORK/dotfiles/cu-sub"
pass "no git / no upstream / nested copy: silent, no report"

# Case 54
info "Case 54: a failed fetch writes no report"
author_commit CUFAIL one
REAL_URL=$(git -C "$WORK/dotfiles" remote get-url origin)
git -C "$WORK/dotfiles" remote set-url origin "$T/does-not-exist.git"
age_check
rm -f "$STATE/report"
HEAD_BEFORE=$(cu_head)
cu_run
[[ $RC -eq 0 && -z "$OUT" ]] || fail "failed fetch: rc=$RC: $OUT"
[[ ! -e "$STATE/report" ]] || fail "failed fetch wrote a report"
[[ -n "$(find "$STATE/last-check" -mmin -1)" ]] || fail "a failed attempt should still count against the interval"
[[ "$(cu_head)" == "$HEAD_BEFORE" ]] || fail "HEAD moved"
git -C "$WORK/dotfiles" remote set-url origin "$REAL_URL"
pass "failed fetch: silent, no report"

# Case 55
info "Case 55: the hosts repo is checked too, and named in the report"
git clone -q --bare "$HOSTS_FP" "$T/hosts-origin.git"
git clone -q "$T/hosts-origin.git" "$T/hosts-up"
git clone -q "$T/hosts-origin.git" "$T/hosts-author"
git -C "$WORK/dotfiles" pull -q --ff-only
cat > "$T/config-cu-up" <<EOF
hosts_dir: $T/hosts-up
hostname: nohost
profile: fptest
EOF
echo hosts-new > "$T/hosts-author/NEWFILE"
git -C "$T/hosts-author" add NEWFILE
git -C "$T/hosts-author" -c user.name=tester -c user.email=tester@example.com commit -q -m "hosts news"
git -C "$T/hosts-author" push -q origin HEAD
HOSTS_HEAD=$(git -C "$T/hosts-up" rev-parse HEAD)
age_check
rm -f "$STATE/report"
CU_CFG="$T/config-cu-up" cu_run
[[ $RC -eq 0 && -s "$STATE/report" ]] || fail "hosts update not reported: rc=$RC: $OUT"
grep -q 'updates available' "$STATE/report" && grep -q 'hosts' "$STATE/report" && grep -q 'dotfiles pull' "$STATE/report" \
    || fail "report does not name the hosts repo: $(cat "$STATE/report")"
if grep -q 'updates available (dotfiles' "$STATE/report"; then fail "dotfiles repo named although it is up to date: $(cat "$STATE/report")"; fi
[[ "$(git -C "$T/hosts-up" rev-parse HEAD)" == "$HOSTS_HEAD" ]] || fail "hosts HEAD moved"
[[ ! -e "$T/hosts-up/NEWFILE" ]] || fail "hosts working tree changed"
# Both repos ahead: both named
author_commit CUBOTH one
age_check
rm -f "$STATE/report"
CU_CFG="$T/config-cu-up" cu_run
grep -q 'dotfiles' "$STATE/report" && grep -q 'hosts' "$STATE/report" || fail "both repos not named: $(cat "$STATE/report")"
pass "hosts repo reported; both named when both are ahead"

# Case 56
info "Case 56: a missing hosts dir does not stop the dotfiles repo being checked"
sed "s#^hosts_dir: .*#hosts_dir: $T/no-such-hosts#" "$T/config-cu" > "$T/config-cu-nohosts"
age_check
rm -f "$STATE/report"
CU_CFG="$T/config-cu-nohosts" cu_run
[[ $RC -eq 0 && -s "$STATE/report" ]] || fail "missing hosts dir: rc=$RC: $OUT report=$(cat "$STATE/report" 2>&1)"
pass "missing hosts dir is skipped"

echo
echo "All sync tests passed"
