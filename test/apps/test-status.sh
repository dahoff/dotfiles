#!/usr/bin/env bash
# test-status.sh - dotfiles status: read-only summary

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
echo "Status Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR
T="/tmp/dotfiles-test-status-$$"
trap 'rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home" "$T/state/apps"
export HOME="$T/home"
export STATE_DIR="$T/state"
export XDG_STATE_HOME="$T/xdg-state"
export DOTFILES_CONFIG="$T/config"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
: > "$GIT_CONFIG_GLOBAL"

cp -R "$TEST_DIR/fixtures/hosts-dir" "$T/hosts-dir"
cat > "$T/config" <<CFG
hosts_dir: $T/hosts-dir
hostname: testhost
CFG
cd "$ROOT_DIR"

OUT=""
RC=0
run() {
    RC=0
    OUT=$(./dotfiles "$@" 2>&1) || RC=$?
}
# Assert OUT contains the given text
has_line() {
    printf '%s\n' "$OUT" | grep -qF -- "$1" || fail "missing '$1' in: $OUT"
}

info "Case 1: before any sync"
run status
[[ $RC -eq 0 ]] || fail "status failed: $OUT"
has_line "claude    not installed"
has_line "update check:    on, every 4h — never run"
has_line "pending:         none"
has_line "host:            testhost  (hosts/testhost/host.yaml)   profile: base"
has_line "config:          $T/config"
has_line "hosts dir:       $T/hosts-dir  (not a git checkout)"
pass "fresh status"

info "Case 4: dotfiles repo shows git branch and sha"
has_line "dotfiles repo:   $ROOT_DIR  (git "
pass "git checkout described"

info "Case 6: status writes nothing"
MARK="$T/marker"
touch "$MARK"
sleep 1
run status
[[ $RC -eq 0 ]] || fail "status failed: $OUT"
CHANGED=$(find "$T/state" "$T/home" -newer "$MARK" 2>/dev/null || true)
[[ -z "$CHANGED" ]] || fail "status changed files: $CHANGED"
[[ ! -e "$T/xdg-state" ]] || fail "status created the state dir"
pass "read-only"

info "Case 2: after sync"
RC=0
OUT=$(./dotfiles pull --no-backup --skip-git-setup --no-fetch 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
run status
has_line "claude    up to date"
has_line "scripts   up to date"
has_line "update check:    on, every 4h — never run"
touch "$XDG_STATE_HOME/dotfiles/last-check"
run status
has_line "update check:    on, every 4h — last run just now"
touch -d '3 hours ago' "$XDG_STATE_HOME/dotfiles/last-check"
run status
has_line "update check:    on, every 4h — last run 3h ago"
echo "update_check: off" >> "$T/config"
run status
has_line "update check:    off"
sed -i '/^update_check: off$/d' "$T/config"
pass "up to date after sync; update check shows its own last run"

info "Case 3: host layer edit"
echo '{"edited": true}' > "$T/hosts-dir/hosts/testhost/apps/claude/files/settings.json"
run status
has_line "claude    update available"
has_line "scripts   up to date"
pass "update available"

info "Case 5: pushed copy"
echo "source=koi commit=abc1234" > "$T/hosts-dir/PUSHED"
run status
has_line "(pushed: source=koi"
pass "PUSHED file shown"

info "Case 7: missing config, pending list, bad profile"
rm "$T/config"
run status --hosts-dir "$T/hosts-dir" --hostname testhost
[[ $RC -eq 0 ]] || fail "status failed: $OUT"
has_line "(not found, using defaults)"
printf 'a\nb\n' > "$XDG_STATE_HOME/dotfiles/pending"
run status --hosts-dir "$T/hosts-dir" --profile nonexistent-profile
[[ $RC -eq 0 ]] || fail "bad profile must exit 0: $OUT"
has_line "pending:         a, b"
has_line "dotfiles repo:"
pass "tolerates missing config and bad profile"

# ---------------------------------------------------------------------------
# Part 2: a copy of the repo with records: every review state in status, the drop-ins
# deployed through the records, and uninstall protecting edits
# ---------------------------------------------------------------------------

unset DOTFILES_RESET DOTFILES_FORCE_PATH DOTFILES_ADD_ASSUME_TTY
D="$T/part2"
R="$D/dotfiles"
H="$D/hosts"
mkdir -p "$D/home" "$D/state/apps" "$D/bin" "$R" "$H/profiles" "$H/hosts/dphost"
export HOME="$D/home"
export STATE_DIR="$D/state"
export XDG_STATE_HOME="$D/xdg-state"
export DOTFILES_CONFIG="$D/config"
export GIT_TERMINAL_PROMPT=0
export GIT_SETUP_SKIP=true
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main
# A tool that is already installed, so no install script runs
printf '#!/bin/sh\nexit 0\n' > "$D/bin/lazygit"
chmod +x "$D/bin/lazygit"
export PATH="$D/bin:$PATH"

(cd "$ROOT_DIR" && tar --exclude=.git --exclude=.worktrees --exclude=.superpowers -cf - .) | (cd "$R" && tar -xf -)
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" commit -q -m base
printf 'packages:\n  - lazygit\n  - scripts\n  - claude\n' > "$H/profiles/dp.yaml"
printf 'packages:\n  - scripts\n  - claude\n' > "$H/profiles/nolz.yaml"
printf 'profile: dp\n' > "$H/hosts/dphost/host.yaml"
git -C "$H" init -q
git -C "$H" add -A
git -C "$H" commit -q -m base
printf 'hosts_dir: %s\nhostname: dphost\n' "$H" > "$D/config"

LZ="$HOME/.bashrc.d/50-lazygit.sh"
LG="$HOME/.bashrc.d/90-dotfiles.sh"
EXTRACT="$HOME/.local/bin/extract"
REC="$STATE_DIR/records"

run2() {
    RC=0
    OUT=$("$R/dotfiles" "$@" 2>&1 </dev/null) || RC=$?
}
# dotfiles add with the given answers
add2() {
    RC=0
    OUT=$(printf '%s\n' "$@" | DOTFILES_ADD_ASSUME_TTY=1 timeout 120 "$R/dotfiles" add ${ADD2_ARGS[@]+"${ADD2_ARGS[@]}"} 2>&1) || RC=$?
    [[ $RC -ne 124 ]] || fail "add hung: $OUT"
}
declare -a ADD2_ARGS=()
no_line() {
    if printf '%s\n' "$OUT" | grep -qF -- "$1"; then fail "unexpected '$1' in: $OUT"; fi
}
pull2() {
    run2 pull --no-backup --no-fetch "$@"
    [[ $RC -eq 0 ]] || fail "pull failed: $OUT"
}
commit2() {
    git -C "$R" add -A
    git -C "$R" commit -q -m "$1"
}
# The text of one status section: its label line and the indented lines under it
section() {
    printf '%s\n' "$OUT" | awk -v l="$1" 'index($0, l ":") == 1 { p = 1; print; next } /^  / && p { print; next } { p = 0 }'
}
section_has() {
    section "$1" | grep -qF -- "$2" || fail "'$2' not under '$1' in: $OUT"
}
section_lacks() {
    if section "$1" | grep -qF -- "$2"; then fail "'$2' under '$1' in: $OUT"; fi
}
all_none() {
    has_line "updates available: none"
    has_line "unreviewed changes: none"
    has_line "conflicts: none"
    has_line "dismissed: none"
    has_line "saved, not committed: none"
    has_line "uncommitted files: none"
}

info "Case 8: the drop-ins are deployed through the records"
pull2
for pair in "lazygit:50-lazygit.sh:$R/apps/lazygit/files/50-lazygit.sh:$LZ" "dotfiles:90-dotfiles.sh:$R/lib/login.sh:$LG"; do
    IFS=: read -r app name source live <<< "$pair"
    [[ "$(cat "$REC/$app/manifest.tsv")" == "$name"$'\t'"$live"$'\t'replace ]] || fail "$app manifest: $(cat "$REC/$app/manifest.tsv" 2>&1)"
    cmp -s "$source" "$REC/$app/repo/$name" || fail "$app: wrong repo copy"
    cmp -s "$live" "$REC/$app/review/$name" || fail "$app: wrong review copy"
    cmp -s "$source" "$live" || fail "$app: not deployed"
    [[ "$(stat -c %a "$live")" == 644 ]] || fail "$app: mode $(stat -c %a "$live")"
    [[ "$(stat -c %a "$REC/$app/repo/$name")" == 600 ]] || fail "$app: repo copy is not private"
done
pass "recorded with both copies"

info "Case 9: status with nothing to report"
run2 status
[[ $RC -eq 0 ]] || fail "status failed: $OUT"
all_none
no_line "not tracked yet"
pass "every label says none"

info "Case 10: an edit to a drop-in is unreviewed, counted by pull, and kept"
echo '# my lazygit edit' >> "$LZ"
EDITED_LZ=$(cat "$LZ")
run2 status
section_has "unreviewed changes" "~/.bashrc.d/50-lazygit.sh"
has_line "conflicts: none"
echo '# repo change elsewhere' >> "$R/apps/scripts/files/extract"
commit2 "scripts change"
pull2
has_line "1 file(s) have local edits, run 'dotfiles add'"
[[ "$(cat "$LZ")" == "$EDITED_LZ" ]] || fail "edit overwritten"
pass "unreviewed"

info "Case 11: the edit survives a repo change to the drop-in and is flagged"
echo '# repo lazygit v2' >> "$R/apps/lazygit/files/50-lazygit.sh"
commit2 "lazygit drop-in v2"
run2 pull --no-backup --no-fetch
[[ $RC -eq 0 ]] || fail "pull failed: $OUT"
[[ "$(cat "$LZ")" == "$EDITED_LZ" ]] || fail "edit overwritten by the repo's change"
has_line "kept your edit to $LZ"
no_line "Already up to date"
run2 status
section_has "conflicts" "~/.bashrc.d/50-lazygit.sh  (the repo changed it too)"
section_has "updates available" "lazygit drop-in"
section_lacks "unreviewed changes" "50-lazygit.sh"
# The repo copy didn't take the new version, and the conflict keeps the next pull from stopping early
cmp -s "$REC/lazygit/repo/50-lazygit.sh" "$R/apps/lazygit/files/50-lazygit.sh" && fail "repo copy took the held version"
run2 pull --no-backup --no-fetch
has_line "kept your edit to $LZ"
pass "kept and flagged"

info "Case 12: add offers the drop-in with the public default as the only save target"
add2 s y q
has_line "Saving the whole file undoes the repo's change"
has_line "1) dotfiles default (PUBLIC repo, all machines)"
no_line "2) "
no_line "hosts repo"
pass "public default only"

info "Case 13: saving it stages the public layer; status shows it waiting for a commit"
add2 s y 1 public
has_line "Staged apps/lazygit/files/50-lazygit.sh"
cmp -s "$LZ" "$R/apps/lazygit/files/50-lazygit.sh" || fail "layer file is not the live file"
[[ "$(git -C "$R" diff --cached --name-only)" == "apps/lazygit/files/50-lazygit.sh" ]] || fail "not staged"
run2 status
section_has "saved, not committed" "~/.bashrc.d/50-lazygit.sh"
section_lacks "conflicts" "50-lazygit.sh"
section_lacks "unreviewed changes" "50-lazygit.sh"
section_has "uncommitted files, not deployed" "apps/lazygit/files/50-lazygit.sh"
run2 pull --no-backup --no-fetch
no_line "have local edits"
add2 k
has_line "No local edits"
pass "saved"

info "Case 14: committing the save settles it"
commit2 "saved lazygit edit"
pull2
cmp -s "$LZ" "$REC/lazygit/repo/50-lazygit.sh" || fail "repo copy not updated"
run2 status
all_none
pass "settled"

info "Case 15: an edit to 90-dotfiles.sh survives, is flagged, and add offers only dismiss and skip"
echo '# my login edit' >> "$LG"
EDITED_LG=$(cat "$LG")
echo '# login v2' >> "$R/lib/login.sh"
commit2 "login v2"
run2 pull --no-backup --no-fetch
[[ $RC -eq 0 ]] || fail "pull failed: $OUT"
[[ "$(cat "$LG")" == "$EDITED_LG" ]] || fail "login edit overwritten"
has_line "kept your edit to $LG"
run2 status
section_has "conflicts" "~/.bashrc.d/90-dotfiles.sh  (the repo changed it too)"
add2 s k
has_line "Dismiss or skip?"
no_line "Save, dismiss or skip?"
has_line "program code (lib/login.sh)"
has_line "Not an option: s"
[[ -z "$(git -C "$R" diff --cached --name-only)" ]] || fail "something was staged"
[[ "$(cat "$LG")" == "$EDITED_LG" ]] || fail "add changed the live file"
pass "dismiss and skip only"

info "Case 16: dismissing it keeps it local; status lists it as dismissed"
add2 d
run2 status
section_has "dismissed" "~/.bashrc.d/90-dotfiles.sh"
has_line "conflicts: none"
cmp -s "$R/lib/login.sh" "$REC/dotfiles/repo/90-dotfiles.sh" || fail "repo copy not taken from the repo"
cmp -s "$LG" "$REC/dotfiles/review/90-dotfiles.sh" || fail "review copy not taken from the live file"
pull2
[[ "$(cat "$LG")" == "$EDITED_LG" ]] || fail "pull overwrote a dismissed edit"
ADD2_ARGS=(--all)
add2 k
ADD2_ARGS=()
has_line "You dismissed this earlier"
pass "dismissed"

info "Case 17: pull --force PATH takes the repo's drop-in, and status is clean"
run2 pull --no-backup --no-fetch --force "$LG"
[[ $RC -eq 0 ]] || fail "force pull failed: $OUT"
cmp -s "$R/lib/login.sh" "$LG" || fail "force did not take the repo's file: $OUT"
grep -rlF '# my login edit' "$HOME/.bak/dotfiles" >/dev/null || fail "no snapshot of the edit"
run2 status
all_none
run2 pull --no-backup --no-fetch --force "$HOME/.bashrc.d/90-nothing.sh"
[[ $RC -ne 0 ]] || fail "force PATH accepted an unmanaged file"
pass "force PATH on a drop-in"

info "Case 18: drop-in edits are in scope only for the profile, except the login one"
echo '# lazygit edit again' >> "$LZ"
echo '# login edit again' >> "$LG"
run2 status --profile nolz
section_lacks "unreviewed changes" "50-lazygit.sh"
section_has "unreviewed changes" "90-dotfiles.sh"
ADD2_ARGS=(--profile nolz)
add2 k
ADD2_ARGS=()
no_line "50-lazygit.sh"
has_line "90-dotfiles.sh"
run2 status
section_has "unreviewed changes" "50-lazygit.sh"
section_has "unreviewed changes" "90-dotfiles.sh"
add2 k k
has_line "50-lazygit.sh"
cp "$R/lib/login.sh" "$LG"
cp "$R/apps/lazygit/files/50-lazygit.sh" "$LZ"
run2 status
all_none
pass "scope"

info "Case 19: a missing live drop-in is not an edit, and the next full pull restores it"
rm -f "$LZ" "$LG"
run2 status
[[ $RC -eq 0 ]] || fail "status failed: $OUT"
all_none
echo '# trigger' >> "$R/apps/scripts/files/fuzzy-find"
commit2 "trigger a deploy"
pull2
cmp -s "$R/apps/lazygit/files/50-lazygit.sh" "$LZ" || fail "lazygit drop-in not restored"
cmp -s "$R/lib/login.sh" "$LG" || fail "login drop-in not restored"
pass "restored"

info "Case 20: a drop-in over a file nobody deployed is snapshotted, even with --no-backup"
rm -rf "$REC/lazygit" "$HOME/.bak/lazygit"
echo '# there before dotfiles' > "$LZ"
echo '# trigger 2' >> "$R/apps/scripts/files/fuzzy-find"
commit2 "trigger a deploy again"
pull2
cmp -s "$R/apps/lazygit/files/50-lazygit.sh" "$LZ" || fail "not deployed over it"
grep -rlF '# there before dotfiles' "$HOME/.bak/lazygit" >/dev/null || fail "no snapshot of the file it replaced"
[[ -f "$REC/lazygit/manifest.tsv" ]] || fail "no records"
pass "snapshot"

info "Case 21: a drop-in whose tool is no longer managed stays, with a warning when edited"
echo '# edited before the tool left' >> "$LZ"
printf 'packages:\n  - scripts\n  - claude\n' > "$H/profiles/dp.yaml"
git -C "$H" commit -q -am "drop lazygit"
pull2
has_line "$LZ is no longer managed by lazygit and has unreviewed edits"
grep -qF '# edited before the tool left' "$LZ" || fail "the file was changed"
[[ ! -e "$REC/lazygit" ]] || fail "records kept"
run2 status
section_lacks "unreviewed changes" "50-lazygit.sh"
printf 'packages:\n  - lazygit\n  - scripts\n  - claude\n' > "$H/profiles/dp.yaml"
git -C "$H" commit -q -am "lazygit back"
pull2
cmp -s "$R/apps/lazygit/files/50-lazygit.sh" "$LZ" || fail "not deployed again"
printf 'packages:\n  - scripts\n  - claude\n' > "$H/profiles/dp.yaml"
git -C "$H" commit -q -am "drop lazygit again"
pull2
no_line "no longer managed"
cmp -s "$R/apps/lazygit/files/50-lazygit.sh" "$LZ" || fail "unedited file changed"
[[ ! -e "$REC/lazygit" ]] || fail "records kept"
printf 'packages:\n  - lazygit\n  - scripts\n  - claude\n' > "$H/profiles/dp.yaml"
git -C "$H" commit -q -am "lazygit back again"
pull2
pass "no longer managed"

info "Case 22: status lists uncommitted files, also for a repo with no git"
echo x > "$R/stray.txt"
run2 status
section_has "uncommitted files, not deployed" "$R: stray.txt"
rm -f "$R/stray.txt"
mkdir -p "$D/nogit"
(cd "$R" && tar --exclude=.git -cf - .) | (cd "$D/nogit" && tar -xf -)
cp -R "$H" "$D/hosts-nogit"
rm -rf "$D/hosts-nogit/.git"
RC=0
OUT=$("$D/nogit/dotfiles" status --hosts-dir "$D/hosts-nogit" 2>&1 </dev/null) || RC=$?
[[ $RC -eq 0 ]] || fail "status failed: $OUT"
has_line "(not a git checkout)"
has_line "uncommitted files: none"
no_line "fatal"
pass "no git"

info "Case 23: a conflict does not hide an update in status"
echo '# my extract edit' >> "$EXTRACT"
echo '# repo extract v2' >> "$R/apps/scripts/files/extract"
commit2 "extract v2"
pull2
run2 status
has_line "scripts   conflict held back"
section_has "conflicts" "~/.local/bin/extract"
section_lacks "updates available" "scripts"
echo '# repo fuzzy-find v3' >> "$R/apps/scripts/files/fuzzy-find"
commit2 "fuzzy-find v3"
run2 status
has_line "scripts   update available"
section_has "updates available" "scripts"
section_has "conflicts" "~/.local/bin/extract"
pull2
run2 status
has_line "scripts   conflict held back"
section_lacks "updates available" "scripts"
pass "conflict and update"

info "Case 24: after pull --force PATH, the file taken from the repo is no longer an edit or conflict"
run2 pull --no-backup --no-fetch --force "$EXTRACT"
[[ $RC -eq 0 ]] || fail "force pull failed: $OUT"
cmp -s "$R/apps/scripts/files/extract" "$EXTRACT" || fail "force did not take the repo's file"
run2 status
has_line "scripts   up to date"
grep -q "^  version: conflict" "$STATE_DIR/apps/scripts.yaml" && fail "the state still says a conflict is held"
section_lacks "conflicts" "extract"
all_none
pass "no stale status"

info "Case 25: uninstall lists local changes and takes a snapshot, even with --no-backup"
echo '# edit before uninstall' >> "$EXTRACT"
BEFORE=$(find "$HOME/.bak/scripts" -mindepth 1 -maxdepth 1 -type d | wc -l)
run2 uninstall --dry-run
[[ $RC -eq 0 ]] || fail "dry run failed: $OUT"
[[ -e "$EXTRACT" && -f "$REC/scripts/manifest.tsv" ]] || fail "dry run changed things"
[[ "$(find "$HOME/.bak/scripts" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$BEFORE" ]] || fail "dry run took a snapshot"
run2 uninstall --no-backup
[[ $RC -eq 0 ]] || fail "uninstall failed: $OUT"
has_line "Local changes in these files will be replaced or removed"
has_line "  $EXTRACT"
no_line "  $HOME/.local/bin/fuzzy-find"
[[ "$(find "$HOME/.bak/scripts" -mindepth 1 -maxdepth 1 -type d | wc -l)" -gt "$BEFORE" ]] || fail "no snapshot taken"
grep -rlF '# edit before uninstall' "$HOME/.bak/scripts" >/dev/null || fail "the snapshot lacks the edit"
[[ ! -e "$EXTRACT" ]] || fail "extract not removed"
[[ ! -e "$REC/scripts" ]] || fail "records kept"
[[ -f "$LZ" && -f "$LG" && -f "$REC/lazygit/manifest.tsv" && -f "$REC/dotfiles/manifest.tsv" ]] || fail "uninstall touched the drop-ins"
pass "uninstall snapshots"

info "Case 26: uninstall of clean files says nothing about changes, and still snapshots"
pull2 --force
BEFORE=$(find "$HOME/.bak/scripts" -mindepth 1 -maxdepth 1 -type d | wc -l)
run2 uninstall
[[ $RC -eq 0 ]] || fail "uninstall failed: $OUT"
no_line "Local changes in these files"
[[ "$(find "$HOME/.bak/scripts" -mindepth 1 -maxdepth 1 -type d | wc -l)" -gt "$BEFORE" ]] || fail "no snapshot taken"
pass "clean uninstall"

info "Case 27: uninstall with no records still snapshots"
pull2 --force
rm -rf "$REC/scripts"
echo '# no records edit' >> "$EXTRACT"
run2 uninstall --no-backup
[[ $RC -eq 0 ]] || fail "uninstall failed: $OUT"
has_line "No records of what dotfiles deployed for scripts"
grep -rlF '# no records edit' "$HOME/.bak/scripts" >/dev/null || fail "the snapshot lacks the edit"
[[ ! -e "$EXTRACT" ]] || fail "extract not removed"
pass "uninstall without records"

info "Case 28: a failed snapshot stops uninstall before anything is restored"
pull2 --force
echo '# edit kept by a failed snapshot' >> "$EXTRACT"
if [[ "$(id -u)" -eq 0 ]]; then
    info "running as root: unwritable directories can't be tested"
else
    chmod 500 "$HOME/.bak/scripts"
    run2 uninstall --no-backup
    chmod 700 "$HOME/.bak/scripts"
    [[ $RC -ne 0 ]] || fail "uninstall went on without a snapshot: $OUT"
    has_line "nothing was restored or removed"
    grep -qF '# edit kept by a failed snapshot' "$EXTRACT" || fail "the file was changed"
    [[ -f "$STATE_DIR/apps/scripts.yaml" && -f "$REC/scripts/manifest.tsv" ]] || fail "state or records were removed"
    [[ -f "$HOME/.local/bin/fuzzy-find" ]] || fail "another file was removed"
fi
pass "failed snapshot"

echo
echo "All status tests passed"
