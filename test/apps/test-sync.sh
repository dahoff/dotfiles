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

unset DOTFILES_HOSTS_REPO
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

cp -R "$TEST_DIR/fixtures/hosts-repo" "$T/hosts-repo"
cat > "$T/config" <<EOF
dotfiles_repo=$WORK/dotfiles
hosts_repo=$T/hosts-repo
hostname=testhost
EOF

STATE="$XDG_STATE_HOME/dotfiles"
OUT=""
RC=0
# Run the repo's dotfiles with args, capture output in OUT and exit code in RC
run() {
    RC=0
    OUT=$("$WORK/dotfiles/dotfiles" "$@" --no-backup --skip-git-setup 2>&1) || RC=$?
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
dotfiles_repo=$T/nogit
hosts_repo=$T/hosts-repo
hostname=testhost
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
    mkdir -p "$WORK/dotfiles/sleeptest"
    cat > "$WORK/dotfiles/sleeptest/install.sh" <<'EOS'
#!/usr/bin/env bash
# Starts a detached long-lived child, like a tmux server would
(setsid sleep 4711 >/dev/null 2>&1 &)
exit 0
EOS
    cat > "$T/hosts-repo/profiles/sleeper.yaml" <<'EOS'
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

echo
echo "All sync tests passed"
