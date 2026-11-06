#!/usr/bin/env bash
# test-versions.sh - dotfiles versions, dotfiles checkout, and being pinned

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
echo "Versions Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR
T="/tmp/dotfiles-test-versions-$$"
trap 'rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home" "$T/state/apps" "$T/author"
export HOME="$T/home"
export STATE_DIR="$T/state"
export XDG_STATE_HOME="$T/xdg-state"
export DOTFILES_CONFIG="$T/config"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_TERMINAL_PROMPT=0
export GIT_SETUP_SKIP=true
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main

(cd "$ROOT_DIR" && tar --exclude=.git -cf - .) | (cd "$T/author" && tar -xf -)
A="$T/author"
EXTRACT="apps/scripts/files/extract"
DAY=10
# Commit everything with its own date, so tags sort predictably
commit() {
    DAY=$((DAY + 1))
    git -C "$A" add -A
    GIT_COMMITTER_DATE="2026-01-${DAY}T12:00:00" git -C "$A" commit -q --allow-empty -m "$1"
}
git -C "$A" init -q
mv "$A/lib/versions.sh" "$T/versions.sh.keep"
commit "before checkout existed"
git -C "$A" tag old
mv "$T/versions.sh.keep" "$A/lib/versions.sh"
echo '# v1.0' >> "$A/$EXTRACT"
commit "v1.0"
git -C "$A" tag v1.0
SHA10=$(git -C "$A" rev-parse --short HEAD)
echo '# v1.1' >> "$A/$EXTRACT"
commit "v1.1"
git -C "$A" tag v1.1
echo '# after v1.1' >> "$A/$EXTRACT"
commit "untagged"

git clone -q --bare "$A" "$T/origin.git"
git -C "$A" remote add origin "$T/origin.git"
git -C "$A" fetch -q origin
git -C "$A" branch -q -u origin/main
git clone -q "$T/origin.git" "$T/dotfiles"
R="$T/dotfiles"

cp -R "$TEST_DIR/fixtures/hosts-dir" "$T/hosts-dir"
# A git hosts dir, so an unchanged sync can stop early
git -C "$T/hosts-dir" init -q
git -C "$T/hosts-dir" add -A
git -C "$T/hosts-dir" commit -q -m base
cat > "$T/config" <<CFG
hosts_dir: $T/hosts-dir
hostname: testhost
CFG

LIVE="$HOME/.local/bin/extract"
OUT=""
RC=0
run() {
    RC=0
    OUT=$("$R/dotfiles" "$@" 2>&1 </dev/null) || RC=$?
}
has_line() {
    printf '%s\n' "$OUT" | grep -qF -- "$1" || fail "missing '$1' in: $OUT"
}
no_line() {
    if printf '%s\n' "$OUT" | grep -qF -- "$1"; then fail "unexpected '$1' in: $OUT"; fi
}
head_is() {
    [[ "$(git -C "$R" rev-parse HEAD)" == "$(git -C "$R" rev-parse "$1^{commit}")" ]] || fail "HEAD is not at $1"
}

run sync --no-backup
[[ $RC -eq 0 ]] || fail "first sync failed: $OUT"

info "Case 1: versions lists tags, newest first, and flags what is too old"
run versions
[[ $RC -eq 0 ]] || fail "versions failed: $OUT"
[[ "$(printf '%s\n' "$OUT" | awk '{print $1}' | paste -sd' ' -)" == "v1.1 v1.0 old" ]] || fail "wrong order: $OUT"
printf '%s\n' "$OUT" | grep -E '^old .*too old to check out' >/dev/null || fail "old not flagged: $OUT"
if printf '%s\n' "$OUT" | grep -E '^v1' | grep -qF 'too old'; then fail "v1 flagged: $OUT"; fi
pass "tags listed"

info "Case 2: status on main"
run status
has_line "on main, up to date with origin/main"
pass "status shows the branch"

info "Case 3: checkout a tag pins and deploys it, with the pinned warning"
run checkout v1.0
[[ $RC -eq 0 ]] || fail "checkout failed: $OUT"
head_is v1.0
git -C "$R" symbolic-ref -q HEAD >/dev/null && fail "HEAD should be detached"
has_line "pinned to v1.0"
grep -q '# v1.0' "$LIVE" || fail "v1.0 not deployed"
grep -q '# v1.1' "$LIVE" && fail "v1.1 still deployed"
pass "pinned to the tag"

info "Case 4: status and versions show the pin"
run status
has_line "version:         v1.0, pinned (run 'dotfiles checkout main' to follow it), 2 behind origin/main"
run versions
printf '%s\n' "$OUT" | grep -E '^v1\.0 .*\(current\)' >/dev/null || fail "current not marked: $OUT"
pass "pin shown"

info "Case 5: sync stays pinned and warns, even when nothing changed"
echo '# newer' >> "$A/$EXTRACT"
commit "newer"
git -C "$A" push -q origin main
git -C "$R" fetch -q origin
run sync --no-backup
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
has_line "pinned to v1.0"
head_is v1.0
run sync --no-backup
has_line "Already up to date"
has_line "pinned to v1.0"
head_is v1.0
pass "sync warned and did not move"

info "Case 6: background sync stays pinned without warning"
rm -f "$XDG_STATE_HOME/dotfiles/last-sync"
run sync --auto
[[ $RC -eq 0 ]] || fail "auto sync failed: $OUT"
head_is v1.0
if grep -qF "pinned to" "$XDG_STATE_HOME/dotfiles/last-sync.log"; then fail "auto warned"; fi
[[ ! -s "$XDG_STATE_HOME/dotfiles/report" ]] || ! grep -qF pinned "$XDG_STATE_HOME/dotfiles/report" || fail "report mentions the pin"
pass "auto stayed quiet"

info "Case 7: refusals leave the checkout where it is"
run checkout nonexistent
[[ $RC -ne 0 ]] || fail "unknown ref accepted"
has_line "Unknown version 'nonexistent'"
run checkout old
[[ $RC -ne 0 ]] || fail "old version accepted"
has_line "too old"
echo '# wip' >> "$R/$EXTRACT"
run checkout v1.1
[[ $RC -ne 0 ]] || fail "dirty checkout accepted"
has_line "uncommitted changes"
git -C "$R" checkout -q -- "$EXTRACT"
head_is v1.0
run checkout
[[ $RC -ne 0 ]] || fail "missing ref accepted"
has_line "Usage: dotfiles checkout"
pass "refused"

info "Case 8: dry run changes nothing"
run checkout v1.1 --dry-run
[[ $RC -eq 0 ]] || fail "dry run failed: $OUT"
has_line "Would switch to v1.1"
head_is v1.0
pass "dry run"

info "Case 9: checkout by commit"
run checkout "$SHA10"
[[ $RC -eq 0 ]] || fail "checkout by commit failed: $OUT"
head_is "$SHA10"
pass "commit accepted"

info "Case 10: checkout main follows it again, with the latest"
run checkout main
[[ $RC -eq 0 ]] || fail "checkout main failed: $OUT"
[[ "$(git -C "$R" symbolic-ref --short HEAD)" == main ]] || fail "not on main"
head_is origin/main
grep -q '# newer' "$LIVE" || fail "latest not deployed"
no_line "pinned to"
run status
has_line "on main, up to date with origin/main"
echo '# newest' >> "$A/$EXTRACT"
commit "newest"
git -C "$A" push -q origin main
run sync --no-backup
grep -q '# newest' "$LIVE" || fail "sync no longer follows main"
pass "following main"

info "Case 11: a failed fetch still uses what is already here"
git -C "$R" remote set-url origin "$T/gone.git"
run checkout v1.1
[[ $RC -eq 0 ]] || fail "offline checkout failed: $OUT"
has_line "could not fetch"
head_is v1.1
run versions
[[ $RC -eq 0 ]] || fail "offline versions failed: $OUT"
has_line "could not fetch"
has_line "v1.1"
git -C "$R" remote set-url origin "$T/origin.git"
run checkout main
pass "offline"

info "Case 12: no tags"
git -C "$R" tag -d old v1.0 v1.1 >/dev/null
git -C "$T/origin.git" tag -d old v1.0 v1.1 >/dev/null
run versions
[[ $RC -eq 0 ]] || fail "versions failed: $OUT"
has_line "No tagged versions yet"
pass "empty list explained"

info "Case 13: a copy without git"
mkdir "$T/pushed"
(cd "$R" && tar --exclude=.git -cf - .) | (cd "$T/pushed" && tar -xf -)
RC=0
OUT=$("$T/pushed/dotfiles" versions 2>&1 </dev/null) || RC=$?
[[ $RC -ne 0 ]] || fail "versions accepted a copy"
has_line "not a git checkout"
RC=0
OUT=$("$T/pushed/dotfiles" checkout main 2>&1 </dev/null) || RC=$?
[[ $RC -ne 0 ]] || fail "checkout accepted a copy"
has_line "not a git checkout"
RC=0
OUT=$("$T/pushed/dotfiles" status 2>&1 </dev/null) || RC=$?
no_line "version:"
pass "refused"

echo
echo "All versions tests passed"
