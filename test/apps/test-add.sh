#!/usr/bin/env bash
# test-add.sh - keeping local edits through deploys, and dotfiles add

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
echo "Edit Protection and Add Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR
T="/tmp/dotfiles-test-add-$$"
trap 'rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home" "$T/state/apps" "$T/dotfiles"
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

R="$T/dotfiles"
H="$T/hosts-dir"
(cd "$ROOT_DIR" && tar --exclude=.git -cf - .) | (cd "$R" && tar -xf -)
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" commit -q -m base
cp -R "$TEST_DIR/fixtures/hosts-dir" "$H"
git -C "$H" init -q
git -C "$H" add -A
git -C "$H" commit -q -m base
cat > "$T/config" <<CFG
hosts_dir: $H
hostname: testhost
CFG

EXTRACT="$HOME/.local/bin/extract"
FFIND="$HOME/.local/bin/fuzzy-find"
REPO_EXTRACT="$R/apps/scripts/files/extract"
REPO_FFIND="$R/apps/scripts/files/fuzzy-find"
HOST_EXTRACT="$H/hosts/testhost/apps/scripts/files/extract"
PROFILE_EXTRACT="$H/profiles/base/apps/scripts/files/extract"
MANIFEST="$STATE_DIR/deployed/scripts.tsv"

OUT=""
RC=0
run() {
    RC=0
    OUT=$("$R/dotfiles" "$@" 2>&1 </dev/null) || RC=$?
}
# Run dotfiles add, answering the prompts with the given lines
add() {
    RC=0
    OUT=$(printf '%s\n' "$@" | DOTFILES_ADD_ASSUME_TTY=1 "$R/dotfiles" add 2>&1) || RC=$?
}
do_pull() {
    run pull --no-backup "$@"
    [[ $RC -eq 0 ]] || fail "pull failed: $OUT"
}
has_line() {
    printf '%s\n' "$OUT" | grep -qF -- "$1" || fail "missing '$1' in: $OUT"
}
no_line() {
    if printf '%s\n' "$OUT" | grep -qF -- "$1"; then fail "unexpected '$1' in: $OUT"; fi
}
# Sync redeploys only when the repo moved, as it does after a pull
commit_repo() {
    git -C "$R" add -A
    git -C "$R" commit -q -m "$1"
}
reset_edit() {
    cp "$REPO_EXTRACT" "$EXTRACT"
}

do_pull

info "Case 1: every managed file has a record, merged files marked"
[[ -f "$MANIFEST" ]] || fail "no manifest"
grep -qF "$EXTRACT" "$MANIFEST" || fail "extract not recorded"
[[ "$(grep -F "$EXTRACT" "$MANIFEST" | cut -f1)" == "$(sha256sum "$EXTRACT" | cut -d' ' -f1)" ]] || fail "wrong hash"
[[ "$(grep -F "/settings.json" "$STATE_DIR/deployed/claude.tsv" | cut -f1)" == merge ]] || fail "merge file not marked"
run status
has_line "local edits:     none"
pass "recorded"

info "Case 2: an unedited file still updates"
echo '# repo update 1' >> "$REPO_FFIND"
commit_repo "update fuzzy-find"
do_pull
grep -q 'repo update 1' "$FFIND" || fail "unedited file did not update"
pass "normal update"

info "Case 3: an edit survives a redeploy of its app and is reported"
echo '# my edit' >> "$EXTRACT"
EDITED=$(cat "$EXTRACT")
echo '# repo update 2' >> "$REPO_FFIND"
commit_repo "update fuzzy-find again"
do_pull
[[ "$(cat "$EXTRACT")" == "$EDITED" ]] || fail "edit overwritten"
grep -q 'repo update 2' "$FFIND" || fail "other file in the app did not update"
has_line "1 file(s) have local edits, run 'dotfiles add'"
run status
has_line "~/.local/bin/extract"
no_line "the repo changed it too"
pass "edit kept"

info "Case 4: both changed: the edit is kept, flagged, and reaches the auto report"
echo '# repo update 3' >> "$REPO_EXTRACT"
commit_repo "update extract"
rm -f "$XDG_STATE_HOME/dotfiles/last-sync"
RC=0
"$R/dotfiles" pull --auto --no-fetch --no-backup >/dev/null 2>&1 </dev/null || RC=$?
[[ $RC -eq 0 ]] || fail "auto sync failed"
[[ "$(cat "$EXTRACT")" == "$EDITED" ]] || fail "edit overwritten by auto"
grep -qF "kept your edit to $EXTRACT" "$XDG_STATE_HOME/dotfiles/report" || fail "not in report"
run status
has_line "~/.local/bin/extract  (the repo changed it too)"
pass "conflict kept"

info "Case 5: --force takes the repo's version, and a snapshot keeps the edit"
run pull --force
[[ $RC -eq 0 ]] || fail "force sync failed: $OUT"
cmp -s "$REPO_EXTRACT" "$EXTRACT" || fail "force did not overwrite"
grep -rlF '# my edit' "$HOME/.bak/scripts" >/dev/null || fail "no snapshot of the edit"
run status
has_line "local edits:     none"
pass "force overwrites with a backup"

info "Case 6: a matching edit is not an edit"
echo '# repo update 4' >> "$REPO_EXTRACT"
cp "$REPO_EXTRACT" "$EXTRACT"
commit_repo "update extract again"
run status
has_line "local edits:     none"
do_pull
cmp -s "$REPO_EXTRACT" "$EXTRACT" || fail "matching file changed"
[[ "$(grep -F "$EXTRACT" "$MANIFEST" | cut -f1)" == "$(sha256sum "$EXTRACT" | cut -d' ' -f1)" ]] || fail "record not updated"
pass "matching edit"

info "Case 7: an existing machine gets records when the version is unchanged"
echo '# edit before records' >> "$EXTRACT"
EDITED=$(cat "$EXTRACT")
rm -rf "$STATE_DIR/deployed" "$XDG_STATE_HOME/dotfiles/last-complete"
run status
has_line "not tracked yet"
do_pull
[[ "$(grep -F "$EXTRACT" "$MANIFEST" | cut -f1)" == "$(sha256sum "$REPO_EXTRACT" | cut -d' ' -f1)" ]] || fail "baseline is not the repo version"
run status
has_line "~/.local/bin/extract"
echo '# repo update 5' >> "$REPO_FFIND"
commit_repo "update fuzzy-find a third time"
do_pull
[[ "$(cat "$EXTRACT")" == "$EDITED" ]] || fail "edit overwritten after baseline"
pass "baseline"

info "Case 8: no record and a changed repo: keep the file, say so"
rm -rf "$STATE_DIR/deployed"
echo '# repo update 6' >> "$REPO_EXTRACT"
commit_repo "update extract with no records"
do_pull
[[ "$(cat "$EXTRACT")" == "$EDITED" ]] || fail "file with no record overwritten"
has_line "Keeping local edit: $EXTRACT"
[[ "$(grep -F "$EXTRACT" "$MANIFEST" | cut -f1)" == unknown ]] || fail "not marked unknown"
run status
has_line "~/.local/bin/extract  (the repo changed it too)"
run pull --force
reset_edit
pass "unknown kept"

info "Case 9: dry run keeps edits and writes nothing"
echo '# dry' >> "$EXTRACT"
EDITED=$(cat "$EXTRACT")
BEFORE=$(cat "$MANIFEST")
echo '# repo update 7' >> "$REPO_EXTRACT"
commit_repo "dry update"
run pull --dry-run --no-backup
[[ $RC -eq 0 ]] || fail "dry run failed: $OUT"
[[ "$(cat "$EXTRACT")" == "$EDITED" && "$(cat "$MANIFEST")" == "$BEFORE" ]] || fail "dry run wrote something"
run pull --force --no-backup
pass "dry run"

info "Case 10: add needs a terminal"
echo '# add test' >> "$EXTRACT"
RC=0
OUT=$(cd "$T" && "$R/dotfiles" add 2>&1 </dev/null) || RC=$?
[[ $RC -ne 0 ]] || fail "add ran without a terminal"
has_line "interactive"
pass "refused"

info "Case 11: declining saves nothing"
add n
[[ $RC -eq 0 ]] || fail "add failed: $OUT"
has_line "+# add test"
has_line "repo: scripts/extract"
[[ ! -e "$HOST_EXTRACT" ]] || fail "declined file saved"
[[ -z "$(git -C "$H" status --porcelain)" ]] || fail "hosts repo changed"
[[ -z "$(git -C "$R" status --porcelain)" ]] || fail "dotfiles repo changed"
add q
[[ -z "$(git -C "$H" status --porcelain)" ]] || fail "quit saved something"
pass "declined"

info "Case 12: accepting saves to the host layer and stages, without committing"
HEAD_H=$(git -C "$H" rev-parse HEAD)
add y 1
[[ $RC -eq 0 ]] || fail "add failed: $OUT"
has_line "1) host: testhost"
has_line "2) profile: base"
has_line "3) dotfiles default (PUBLIC"
has_line "Staged, not committed"
cmp -s "$EXTRACT" "$HOST_EXTRACT" || fail "not copied to the host layer"
[[ "$(git -C "$H" diff --cached --name-only)" == "hosts/testhost/apps/scripts/files/extract" ]] || fail "not staged"
[[ "$(git -C "$H" rev-parse HEAD)" == "$HEAD_H" ]] || fail "add committed"
[[ -z "$(git -C "$R" status --porcelain)" ]] || fail "dotfiles repo changed"
run status
has_line "local edits:     none"
pass "staged only"

info "Case 13: the staged change deploys, and the next add has nothing to do"
do_pull
cmp -s "$HOST_EXTRACT" "$EXTRACT" || fail "live file differs from the layer"
add n
has_line "No local edits"
git -C "$H" commit -q -m "keep edit"
pass "clean afterwards"

info "Case 14: a file already in a layer defaults back to it; a lower layer warns"
echo '# second edit' >> "$EXTRACT"
add y ""
cmp -s "$EXTRACT" "$HOST_EXTRACT" || fail "default was not the file's layer"
git -C "$H" commit -q -am "second edit"
echo '# third edit' >> "$EXTRACT"
add y 2
has_line "has its own copy"
cmp -s "$EXTRACT" "$PROFILE_EXTRACT" || fail "not saved to the profile"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
cp "$HOST_EXTRACT" "$EXTRACT"
do_pull
pass "layers"

info "Case 15: a new copy in a higher layer warns that it shadows lower ones"
FFIND_BEFORE=$(cat "$REPO_FFIND")
echo '# ffind edit' >> "$FFIND"
add y 1
has_line "later changes to lower layers"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
printf '%s\n' "$FFIND_BEFORE" > "$FFIND"
[[ -z "$(git -C "$H" status --porcelain)" ]] || fail "hosts repo not clean"
pass "shadow warning"

info "Case 16: the public repo needs the word"
do_pull
cp "$REPO_FFIND" "$FFIND"
do_pull
echo '# public edit' >> "$FFIND"
add y 3 no
has_line "PUBLIC repo"
[[ -z "$(git -C "$R" status --porcelain)" ]] || fail "public repo changed without confirmation"
add y 3 public
[[ "$(git -C "$R" diff --cached --name-only)" == "apps/scripts/files/fuzzy-find" ]] || fail "not staged in the public repo"
git -C "$R" reset -q --hard
pass "public confirmed"

info "Case 17: a target with uncommitted changes is not overwritten"
cp "$REPO_FFIND" "$FFIND"
run pull --force --no-backup
echo '# public edit' >> "$FFIND"
echo '# other wip' >> "$REPO_FFIND"
WIP=$(cat "$REPO_FFIND")
add y 3 public
has_line "uncommitted changes; skipped"
[[ "$(cat "$REPO_FFIND")" == "$WIP" ]] || fail "uncommitted work overwritten"
git -C "$R" checkout -q -- apps/scripts/files/fuzzy-find
cp "$REPO_FFIND" "$FFIND"
run pull --force --no-backup
pass "uncommitted work kept"

info "Case 18: pinned machines can't save to the public repo"
git -C "$R" commit -q --allow-empty -m "for the pin"
git -C "$R" checkout -q --detach
echo '# pinned edit' >> "$FFIND"
add y 1
no_line "dotfiles default (PUBLIC"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
git -C "$R" checkout -q main
cp "$REPO_FFIND" "$FFIND"
run pull --force --no-backup
pass "public option hidden"

info "Case 19: merged files show managed keys only and can't be accepted"
CL="$HOME/.claude/settings.json"
jq '.model = "my-model" | .myLocalKey = {"token": "abc"} | del(.profileKey)' "$CL" > "$T/s.json"
cp "$T/s.json" "$CL"
BEFORE=$(cat "$CL")
run status
has_line "~/.claude/settings.json  (merged, keys the repo manages differ)"
add
[[ $RC -eq 0 ]] || fail "add failed: $OUT"
has_line "settings.json (merged, showing keys the repo manages)"
has_line '- "profile-model"'
has_line '+ "my-model"'
has_line "profileKey"
has_line "(removed)"
has_line "1 local keys not shown or copied"
has_line "can't be accepted here"
no_line "abc"
no_line "Save this change"
[[ "$(cat "$CL")" == "$BEFORE" ]] || fail "merged file changed"
[[ -z "$(git -C "$H" status --porcelain)" ]] || fail "hosts repo changed"
pass "merged display-only"

info "Case 20: keys apps add to a merged file are not edits"
git -C "$H" reset -q --hard
run pull --force --no-backup
jq '.claudeAddedThis = 1' "$CL" > "$T/s.json"
cp "$T/s.json" "$CL"
run status
no_line "settings.json"
pass "local keys ignored"

info "Case 21: unmanaged files are never offered"
mkdir -p "$HOME/.bashrc.d" "$HOME/.ssh"
echo 'export KEY=secret' > "$HOME/.bashrc.d/90-secrets.sh"
echo 'PRIVATE' > "$HOME/.ssh/id_test"
add n n n
no_line "90-secrets"
no_line "id_test"
pass "unmanaged ignored"

info "Case 22: git: a fresh deploy stays identical, so it shows no false edit"
GC="$HOME/.gitconfig"
GIT_CONF="$R/apps/git/configure.sh"
bash "$GIT_CONF" install --skip-git-setup --no-backup >/dev/null 2>&1 || fail "git install failed"
cmp -s "$R/apps/git/files/.gitconfig" "$GC" || fail "deploying changed ~/.gitconfig"
pass "gitconfig untouched after deploy"

info "Case 23: git: an old install's expanded path is replaced, a real edit is kept"
GIT_STATE="$STATE_DIR/apps/git.yaml"
legacy_gitconfig() {
    rm -f "$STATE_DIR/deployed/git.tsv"
    sed -i "s/^  version: .*/  version: oldversion/" "$GIT_STATE"
    sed -i "s#excludesfile = ~/#excludesfile = $HOME/#" "$GC"
}
legacy_gitconfig
OUT=$(bash "$GIT_CONF" upgrade --skip-git-setup --no-backup 2>&1) || fail "git upgrade failed: $OUT"
cmp -s "$R/apps/git/files/.gitconfig" "$GC" || fail "expanded path treated as an edit: $OUT"
legacy_gitconfig
git config --file "$GC" alias.mine status
OUT=$(bash "$GIT_CONF" upgrade --skip-git-setup --no-backup 2>&1) || fail "git upgrade failed: $OUT"
[[ "$(git config --file "$GC" alias.mine)" == status ]] || fail "real edit overwritten"
has_line "Keeping local edit"
pass "legacy gitconfig"

info "Case 24: discarding a staged change makes it an edit again, and it survives"
run pull --force --no-backup
[[ $RC -eq 0 ]] || fail "force sync failed: $OUT"
git -C "$H" status --porcelain | grep -q . && fail "hosts repo not clean: $(git -C "$H" status --porcelain)"
FF_REL="hosts/testhost/apps/scripts/files/fuzzy-find"
echo '# keep me' >> "$FFIND"
add y ""
has_line "Staged $FF_REL"
run status
has_line "local edits:     none"
git -C "$H" reset -q -- "$FF_REL"
rm -f "$H/$FF_REL"
run status
has_line "~/.local/bin/fuzzy-find"
add n
has_line "=== ~/.local/bin/fuzzy-find ==="
echo '# repo update 6' >> "$REPO_FFIND"
commit_repo "update fuzzy-find a fourth time"
do_pull
grep -qF '# keep me' "$FFIND" || fail "discarded edit was overwritten"
has_line "fuzzy-find"
run pull --force --no-backup
[[ $RC -eq 0 ]] || fail "force sync failed: $OUT"
pass "backed-out edit kept"

info "Case 25: .bashrc: existing content is kept, then edits are found and can be saved"
echo '# my own bashrc' > "$HOME/.bashrc"
sed -i 's/^packages:/packages:\n  - bash/' "$H/profiles/base.yaml"
git -C "$H" add -A
git -C "$H" commit -q -m "add bash"
do_pull
has_line "00-local.sh"
cmp -s "$R/apps/bash/files/.bashrc" "$HOME/.bashrc" || fail ".bashrc is not the repo's file"
grep -qF '# my own bashrc' "$HOME/.bashrc.d/00-local.sh" || fail "own content lost"
cut -f3 "$STATE_DIR/deployed/bash.tsv" | grep -qxF "$HOME/.bashrc" || fail ".bashrc not recorded"
run status
has_line "local edits:     none"
echo 'alias mine=1' >> "$HOME/.bashrc"
run status
has_line "~/.bashrc"
add y ""
has_line "Staged hosts/testhost/apps/bash/files/.bashrc"
grep -qxF 'alias mine=1' "$H/hosts/testhost/apps/bash/files/.bashrc" || fail "edit not saved to the layer"
git -C "$H" commit -q -m "my bashrc"
do_pull
[[ "$(grep -cxF 'alias mine=1' "$HOME/.bashrc")" == 1 ]] || fail "edit duplicated or lost"
[[ "$(grep -c 'BEGIN managed' "$HOME/.bashrc")" == 0 ]] || fail "a block was appended"
pass ".bashrc round trip"

info "Case 26: uninstall drops the records"
run uninstall --no-backup
[[ ! -e "$MANIFEST" ]] || fail "manifest left behind"
pass "records removed"

echo
echo "All edit protection and add tests passed"
