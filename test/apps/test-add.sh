#!/usr/bin/env bash
# test-add.sh - keeping local edits through deploys, and dotfiles add: save, dismiss, skip

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

unset DOTFILES_HOSTS_DIR DOTFILES_RESET DOTFILES_FORCE_PATH DOTFILES_ADD_ASSUME_TTY
T="/tmp/dotfiles-test-add-$$"
trap 'chmod -R u+rwx "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
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
(cd "$ROOT_DIR" && tar --exclude=.git --exclude=.worktrees -cf - .) | (cd "$R" && tar -xf -)

# Two small apps for the review cases: plain files, merged files, and awkward names
AD="$R/apps/ad"
mkdir -p "$AD/files/sub dir" "$R/apps/ae/files"
cat > "$AD/config.yaml" <<'EOF'
app:
  name: ad
  description: test app

files:
  - src: a.conf
    dest: ~/ad/a.conf
    mode: '0644'
  - src: b.conf
    dest: ~/ad/b.conf
    mode: '0644'
  - src: my file.conf
    dest: ~/ad/my file.conf
    mode: '0644'
  - src: settings.json
    dest: ~/ad/settings.json
    mode: '0644'
    strategy: merge
  - src: sub dir/it's.json
    dest: ~/ad/sub dir/it's.json
    mode: '0644'
    strategy: merge

backup:
  dir: ~/.bak/ad
  max_backups: 3
EOF
cat > "$AD/configure.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"
installer_main "$@"
EOF
chmod +x "$AD/configure.sh"
cp "$AD/configure.sh" "$R/apps/ae/configure.sh"
cat > "$R/apps/ae/config.yaml" <<'EOF'
app:
  name: ae
  description: second test app

files:
  - src: e.conf
    dest: ~/ad/e.conf
    mode: '0644'

backup:
  dir: ~/.bak/ae
  max_backups: 3
EOF
printf 'a1\n' > "$AD/files/a.conf"
printf 'b1\n' > "$AD/files/b.conf"
printf 's1\n' > "$AD/files/my file.conf"
printf 'e1\n' > "$R/apps/ae/files/e.conf"
cat > "$AD/files/settings.json" <<'EOF'
{
  "model": "m1",
  "theme": "t1",
  "nested": {"x": 1, "y": 2},
  "list": [1, 2],
  "objs": [{"a": 1, "b": 2}],
  "a.b": "dotted",
  "a": {"b": "really nested"},
  "it's \"q\"": "quoted",
  " sp ace ": "spaced"
}
EOF
printf '{"k": 1, "other key": 2}\n' > "$AD/files/sub dir/it's.json"
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" commit -q -m base
BASE_R=$(git -C "$R" rev-parse HEAD)

cp -R "$TEST_DIR/fixtures/hosts-dir" "$H"
mkdir -p "$H/hosts/addhost"
printf 'profile: adp\n' > "$H/hosts/addhost/host.yaml"
printf 'packages:\n  - name: ad\n    config:\n      dir: ad\n  - name: ae\n    config:\n      dir: ae\n' > "$H/profiles/adp.yaml"
git -C "$H" init -q
git -C "$H" add -A
git -C "$H" commit -q -m base
BASE_H=$(git -C "$H" rev-parse HEAD)
cat > "$T/config" <<CFG
hosts_dir: $H
hostname: testhost
CFG

EXTRACT="$HOME/.local/bin/extract"
FFIND="$HOME/.local/bin/fuzzy-find"
REPO_EXTRACT="$R/apps/scripts/files/extract"
REPO_FFIND="$R/apps/scripts/files/fuzzy-find"
MANIFEST="$STATE_DIR/records/scripts/manifest.tsv"

OUT=""
RC=0
run() {
    RC=0
    OUT=$("$R/dotfiles" "$@" 2>&1 </dev/null) || RC=$?
}
# Run dotfiles add, answering the prompts with the given lines. No answers means no input
# at all. A timeout catches a prompt that loops at the end of its input.
add() {
    RC=0
    if [[ $# -eq 0 ]]; then
        OUT=$(DOTFILES_ADD_ASSUME_TTY=1 timeout 120 "$R/dotfiles" add ${ADD_ARGS[@]+"${ADD_ARGS[@]}"} 2>&1 </dev/null) || RC=$?
    else
        OUT=$(printf '%s\n' "$@" | DOTFILES_ADD_ASSUME_TTY=1 timeout 120 "$R/dotfiles" add ${ADD_ARGS[@]+"${ADD_ARGS[@]}"} 2>&1) || RC=$?
    fi
    [[ $RC -ne 124 ]] || fail "add hung: $OUT"
}
declare -a ADD_ARGS=()
add_all() {
    ADD_ARGS=(--all)
    add "$@"
    ADD_ARGS=()
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

# ---------------------------------------------------------------------------
# Deploys keep local edits
# ---------------------------------------------------------------------------

do_pull

info "Case 1: every managed file has a record, merged files marked"
[[ -f "$MANIFEST" ]] || fail "no manifest"
grep -qF "$EXTRACT" "$MANIFEST" || fail "extract not recorded"
cmp -s "$STATE_DIR/records/scripts/repo/extract" "$REPO_EXTRACT" || fail "wrong repo copy"
cmp -s "$STATE_DIR/records/scripts/review/extract" "$EXTRACT" || fail "wrong review copy"
[[ "$(grep -F "/settings.json" "$STATE_DIR/records/claude/manifest.tsv" | cut -f3)" == merge ]] || fail "merge file not marked"
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

info "Case 4: both changed: the edit is kept and flagged in the pull summary"
echo '# repo update 3' >> "$REPO_EXTRACT"
commit_repo "update extract"
run pull --no-fetch
[[ $RC -eq 0 ]] || fail "pull failed: $OUT"
[[ "$(cat "$EXTRACT")" == "$EDITED" ]] || fail "edit overwritten by pull"
has_line "kept your edit to $EXTRACT"
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
cmp -s "$STATE_DIR/records/scripts/repo/extract" "$REPO_EXTRACT" || fail "record not updated"
cmp -s "$STATE_DIR/records/scripts/review/extract" "$REPO_EXTRACT" || fail "review copy not updated"
pass "matching edit"

info "Case 7: a host with records from an older version is told to run init"
mkdir -p "$STATE_DIR/deployed"
printf 'abc\textract\t%s\n' "$EXTRACT" > "$STATE_DIR/deployed/scripts.tsv"
echo '# edit before records' >> "$EXTRACT"
EDITED=$(cat "$EXTRACT")
run pull --no-backup
[[ $RC -ne 0 ]] || fail "pull ran over old records: $OUT"
has_line "dotfiles init"
[[ "$(cat "$EXTRACT")" == "$EDITED" ]] || fail "edit changed"
add
[[ $RC -ne 0 ]] || fail "add ran over old records: $OUT"
has_line "dotfiles init"
no_line "No local edits"
rm -rf "$STATE_DIR/deployed"
pass "old records refused"

info "Case 8: no record and a changed repo: a fresh deploy, and the snapshot has the edit"
rm -rf "$STATE_DIR/records/scripts"
echo '# repo update 6' >> "$REPO_EXTRACT"
commit_repo "update extract with no records"
run pull --no-backup --force
[[ $RC -eq 0 ]] || fail "pull failed: $OUT"
cmp -s "$REPO_EXTRACT" "$EXTRACT" || fail "not deployed fresh"
grep -rlF '# edit before records' "$HOME/.bak/scripts" >/dev/null || fail "no snapshot of the edit"
add
has_line "No local edits"
pass "fresh deploy keeps a snapshot"

info "Case 9: dry run keeps edits and writes nothing"
echo '# dry' >> "$EXTRACT"
EDITED=$(cat "$EXTRACT")
BEFORE=$(cat "$MANIFEST" "$STATE_DIR/records/scripts/repo/extract" "$STATE_DIR/records/scripts/review/extract")
echo '# repo update 7' >> "$REPO_EXTRACT"
commit_repo "dry update"
run pull --dry-run --no-backup
[[ $RC -eq 0 ]] || fail "dry run failed: $OUT"
[[ "$(cat "$EXTRACT")" == "$EDITED" ]] || fail "dry run changed the file"
[[ "$(cat "$MANIFEST" "$STATE_DIR/records/scripts/repo/extract" "$STATE_DIR/records/scripts/review/extract")" == "$BEFORE" ]] \
    || fail "dry run wrote records"
run pull --force --no-backup
pass "dry run"

info "Case 10: add and sync refuse without a terminal; pull still works"
echo '# add test' >> "$EXTRACT"
BEFORE=$(cat "$STATE_DIR/records/scripts/review/extract")
RC=0
OUT=$(cd "$T" && "$R/dotfiles" add 2>&1 </dev/null) || RC=$?
[[ $RC -ne 0 ]] || fail "add ran without a terminal"
has_line "interactive"
RC=0
OUT=$(cd "$T" && "$R/dotfiles" sync 2>&1 </dev/null) || RC=$?
[[ $RC -ne 0 ]] || fail "sync ran without a terminal"
has_line "needs a terminal"
no_line "Phase 1"
[[ "$(cat "$STATE_DIR/records/scripts/review/extract")" == "$BEFORE" ]] || fail "records changed"
do_pull
grep -qF '# add test' "$EXTRACT" || fail "pull lost the edit"
pass "refused, nothing changed"
run pull --force --no-backup

info "Case 21: unmanaged files are never offered"
mkdir -p "$HOME/.bashrc.d" "$HOME/.ssh"
echo 'export KEY=secret' > "$HOME/.bashrc.d/90-secrets.sh"
echo 'PRIVATE' > "$HOME/.ssh/id_test"
add k k k
no_line "90-secrets"
no_line "id_test"
pass "unmanaged ignored"

info "Case 22: git: a fresh deploy stays identical, so it shows no false edit"
GC="$HOME/.gitconfig"
GIT_CONF="$R/apps/git/configure.sh"
bash "$GIT_CONF" install --skip-git-setup --no-backup >/dev/null 2>&1 || fail "git install failed"
cmp -s "$R/apps/git/files/.gitconfig" "$GC" || fail "deploying changed ~/.gitconfig"
pass "gitconfig untouched after deploy"

info "Case 23: git: a real edit is kept by an upgrade"
GIT_STATE="$STATE_DIR/apps/git.yaml"
sed -i "s/^  version: .*/  version: oldversion/" "$GIT_STATE"
git config --file "$GC" alias.mine status
OUT=$(bash "$GIT_CONF" upgrade --skip-git-setup --no-backup 2>&1) || fail "git upgrade failed: $OUT"
[[ "$(git config --file "$GC" alias.mine)" == status ]] || fail "real edit overwritten"
has_line "Keeping local edit"
pass "git edit kept"

info "Case 25: .bashrc: the original is kept, then edits are found and can be saved"
echo '# my own bashrc' > "$HOME/.bashrc"
sed -i 's/^packages:/packages:\n  - name: bash\n    config:\n      dir: bash/' "$H/profiles/base.yaml"
git -C "$H" add -A
git -C "$H" commit -q -m "add bash"
do_pull
has_line "no longer loaded"
cmp -s "$R/apps/bash/files/.bashrc" "$HOME/.bashrc" || fail ".bashrc is not the repo's file"
[[ ! -e "$HOME/.bashrc.d/00-local.sh" ]] || fail "00-local.sh was created"
grep -qF "# my own bashrc" "$HOME/.bak/bash/original/.bashrc" || fail "original lost"
cut -f2 "$STATE_DIR/records/bash/manifest.tsv" | grep -qxF "$HOME/.bashrc" || fail ".bashrc not recorded"
run status
has_line "local edits:     none"
echo 'alias mine=1' >> "$HOME/.bashrc"
run status
has_line "~/.bashrc"
add s ""
has_line "Staged hosts/testhost/apps/bash/files/.bashrc"
grep -qxF 'alias mine=1' "$H/hosts/testhost/apps/bash/files/.bashrc" || fail "edit not saved to the layer"
git -C "$H" commit -q -m "my bashrc"
do_pull
[[ "$(grep -cxF 'alias mine=1' "$HOME/.bashrc")" == 1 ]] || fail "edit duplicated or lost"
[[ "$(grep -c 'BEGIN managed' "$HOME/.bashrc" || true)" == 0 ]] || fail "a block was appended"
add
has_line "No local edits"
pass ".bashrc round trip"

info "Case 26: uninstall drops the records"
run uninstall --no-backup
[[ ! -e "$MANIFEST" ]] || fail "manifest left behind"
pass "records removed"

# ---------------------------------------------------------------------------
# The review: every case starts from a fresh host and the repos as they were
# ---------------------------------------------------------------------------

cat > "$T/config" <<CFG
hosts_dir: $H
hostname: addhost
CFG

N=0
fresh() {
    N=$((N + 1))
    export HOME="$T/r$N/home" STATE_DIR="$T/r$N/state" XDG_STATE_HOME="$T/r$N/xdg"
    mkdir -p "$HOME"
    git -C "$R" reset -q --hard "$BASE_R"
    git -C "$R" clean -qfd
    git -C "$H" reset -q --hard "$BASE_H"
    git -C "$H" clean -qfd
    A="$HOME/ad/a.conf"
    B="$HOME/ad/b.conf"
    S="$HOME/ad/settings.json"
    SP="$HOME/ad/my file.conf"
    Q="$HOME/ad/sub dir/it's.json"
    REC="$STATE_DIR/records/ad"
    do_pull
}
LH="$H/hosts/addhost/apps/ad/files"
LP="$H/profiles/adp/apps/ad/files"
LR="$AD/files"
HOST_A="$LH/a.conf"
PROF_A="$LP/a.conf"
PUB_A="$LR/a.conf"
# A checksum of every record but the note of what add saved
recs() {
    (cd "$STATE_DIR/records" && find . -type f ! -path './.add-saved/*' -print0 | sort -z | xargs -0 cksum)
}
# Edit the merged file. Usage: edit_s JQ_FILTER
edit_s() {
    jq "$1" "$S" > "$T/edit.json"
    cat "$T/edit.json" > "$S"
}
# Commit a repo change to the app. Usage: repo_set SRC CONTENT
repo_set() {
    printf '%s\n' "$2" > "$LR/$1"
    git -C "$R" add -A
    git -C "$R" commit -q -m "repo change"
}
repo_s() {
    jq "$1" "$LR/settings.json" > "$T/edit.json"
    cat "$T/edit.json" > "$LR/settings.json"
    git -C "$R" add -A
    git -C "$R" commit -q -m "repo change"
}
hosts_clean() { [[ -z "$(git -C "$H" status --porcelain)" ]] || fail "$1: hosts repo changed: $(git -C "$H" status --porcelain)"; }
public_clean() { [[ -z "$(git -C "$R" status --porcelain)" ]] || fail "$1: public repo changed: $(git -C "$R" status --porcelain)"; }
staged_in() { git -c core.quotepath=off -C "$1" diff --cached --name-only; }

info "Review: the prompt offers save, dismiss and skip; skip asks again"
fresh
echo mine >> "$A"
RS=$(recs)
add k
[[ $RC -eq 0 ]] || fail "add failed: $OUT"
has_line "=== ~/ad/a.conf ==="
has_line "+mine"
has_line "--- repo copy"
has_line "s(ave)"
has_line "d(ismiss)"
has_line "k(skip)"
has_line "q(uit)"
[[ "$(recs)" == "$RS" ]] || fail "skip changed the records"
hosts_clean "skip"
public_clean "skip"
add ""
has_line "+mine"
[[ "$(recs)" == "$RS" ]] || fail "an empty answer changed the records"
add k
has_line "+mine"
pass "skip keeps the item pending; empty means skip"

info "Review: a wrong answer asks again, and the end of the input stops it"
add what also-no k
has_line "Not an option: what"
has_line "Not an option: also-no"
[[ "$(recs)" == "$RS" ]] || fail "records changed"
add what
[[ $RC -eq 0 ]] || fail "add failed: $OUT"
[[ "$(recs)" == "$RS" ]] || fail "records changed"
pass "re-asked"

info "Review: q stops the review, and what's unanswered is asked next time"
fresh
echo mine >> "$A"
echo mine >> "$B"
RS=$(recs)
add q
has_line "=== ~/ad/a.conf ==="
no_line "=== ~/ad/b.conf ==="
has_line "asked again next time"
[[ "$(recs)" == "$RS" ]] || fail "q changed the records"
add d q
has_line "=== ~/ad/b.conf ==="
[[ "$(recs)" != "$RS" ]] || fail "the dismiss before q was not kept"
cmp -s "$REC/review/a.conf" "$A" || fail "dismiss lost"
add k
no_line "=== ~/ad/a.conf ==="
has_line "=== ~/ad/b.conf ==="
pass "q quits"

info "Review: EOF leaves records unchanged and the item pending, at every prompt"
fresh
echo mine >> "$A"
edit_s '.model = "mine"'
RS=$(recs)
add
[[ $RC -eq 0 ]] || fail "add failed at EOF: $OUT"
[[ "$(recs)" == "$RS" ]] || fail "EOF changed the records"
add s
[[ "$(recs)" == "$RS" ]] || fail "EOF at the layer prompt changed the records"
hosts_clean "EOF at the layer prompt"
add s 3
[[ "$(recs)" == "$RS" ]] || fail "EOF at the public prompt changed the records"
public_clean "EOF at the public prompt"
RC=0
OUT=$(printf 'd' | DOTFILES_ADD_ASSUME_TTY=1 timeout 120 "$R/dotfiles" add 2>&1) || RC=$?
[[ $RC -eq 0 && "$(recs)" == "$RS" ]] || fail "an unfinished line counted as an answer: $OUT"
add k k
has_line "=== ~/ad/a.conf ==="
has_line 'key ["model"]'
pass "EOF is a quit"

info "Review: dismiss updates that item only, and asks again when the value changes"
fresh
echo mine >> "$A"
echo mine >> "$B"
REPO_BEFORE=$(cat "$REC/repo/a.conf")
add d k
[[ $RC -eq 0 ]] || fail "add failed: $OUT"
cmp -s "$REC/review/a.conf" "$A" || fail "review copy not updated"
[[ "$(cat "$REC/repo/a.conf")" == "$REPO_BEFORE" ]] || fail "a dismiss of an edit touched the repo copy"
cmp -s "$REC/review/b.conf" "$LR/b.conf" || fail "the skipped item's review copy changed"
[[ "$(stat -c %a "$REC/review/a.conf")" == 600 ]] || fail "review copy is not private"
hosts_clean "dismiss"
public_clean "dismiss"
add k
no_line "=== ~/ad/a.conf ==="
has_line "=== ~/ad/b.conf ==="
echo again >> "$A"
add k k
has_line "=== ~/ad/a.conf ==="
pass "dismissed until it changes"

info "Review: --all asks again about a dismissed item; a dismissal stays through pull"
fresh
echo mine >> "$A"
add d
RS=$(recs)
add_all k
[[ $RC -eq 0 ]] || fail "add --all failed: $OUT"
has_line "=== ~/ad/a.conf ==="
has_line "You dismissed this earlier"
[[ "$(recs)" == "$RS" ]] || fail "skipping a dismissed item changed the records"
add_all d
[[ "$(recs)" == "$RS" ]] || fail "dismissing it again changed the records"
add_all s 1
cmp -s "$HOST_A" "$A" || fail "a dismissed item could not be saved"
run pull --no-backup --no-fetch
[[ $RC -eq 0 ]] || fail "pull failed: $OUT"
grep -qx mine "$A" || fail "the dismissed edit was lost"
no_line "kept your edit"
if run pull --all 2>/dev/null; [[ $RC -eq 0 ]]; then fail "--all accepted by pull"; fi
pass "--all"

info "Review: dismissing a replaced-file conflict stops the warning on the next pull"
fresh
echo mine >> "$A"
repo_set a.conf 'a2'
run pull --no-backup --no-fetch
has_line "kept your edit to $A"
LIVE_BEFORE=$(cat "$A")
add d
has_line "The repo's change"
has_line "+a2"
has_line "+mine"
cmp -s "$REC/review/a.conf" "$A" || fail "review copy not updated"
cmp -s "$REC/repo/a.conf" "$LR/a.conf" || fail "repo copy not taken from the stage"
add
has_line "No local edits"
run pull --no-backup --no-fetch
[[ $RC -eq 0 ]] || fail "pull failed: $OUT"
no_line "kept your edit"
[[ "$(cat "$A")" == "$LIVE_BEFORE" ]] || fail "the live file moved"
run status
no_line "the repo changed it too"
repo_set a.conf 'a3'
run pull --no-backup --no-fetch
has_line "kept your edit to $A"
pass "conflict dismissed; a later repo change conflicts again"

info "Review: dismissing a merged conflict changes only that key"
fresh
edit_s '.model = "mine" | .theme = "mine too"'
repo_s '.model = "m2" | .list = [7]'
run pull --no-backup --no-fetch
has_line 'Keeping your values'
add
[[ "$(jq -r .model "$REC/review/settings.json")" == m1 ]] || fail "EOF changed the review copy"
add d k
has_line 'key ["model"]'
has_line 'repo now'
has_line '"m2"'
[[ "$(jq -r .model "$REC/review/settings.json")" == mine ]] || fail "review copy lacks the key"
[[ "$(jq -r .model "$REC/repo/settings.json")" == m2 ]] || fail "repo copy lacks the stage's key"
[[ "$(jq -r .theme "$REC/review/settings.json")" == t1 ]] || fail "another key's review changed"
[[ "$(jq -r .theme "$REC/repo/settings.json")" == t1 ]] || fail "another key's repo copy changed"
run pull --no-backup --no-fetch
no_line "Keeping your values"
[[ "$(jq -r .model "$S")" == mine && "$(jq -r .theme "$S")" == "mine too" ]] || fail "live moved"
pass "per key"

info "Review: a key changing between object and plain value is a conflict on the subtree"
fresh
edit_s '.nested = {"x": 1, "y": 2, "mine": 3}'
repo_s '.nested = 5'
run pull --no-backup --no-fetch
has_line 'Keeping your values'
add k
has_line 'key ["nested"]'
no_line 'key ["nested","mine"]'
add d
[[ "$(jq -c .nested "$REC/repo/settings.json")" == 5 ]] || fail "repo copy: $(jq -c .nested "$REC/repo/settings.json")"
[[ "$(jq -c .nested.mine "$REC/review/settings.json")" == 3 ]] || fail "review copy"
run pull --no-backup --no-fetch
no_line "Keeping your values"
pass "structural conflict"

info "Review: saving asks for a layer, offers each one, and stages only that layer"
fresh
echo mine >> "$A"
HEAD_H=$(git -C "$H" rev-parse HEAD)
HEAD_R=$(git -C "$R" rev-parse HEAD)
RS=$(recs)
add s 1
[[ $RC -eq 0 ]] || fail "add failed: $OUT"
has_line "Save ~/ad/a.conf to:"
has_line "1) host: addhost (hosts repo)"
has_line "2) profile: adp (hosts repo)"
has_line "3) dotfiles default (PUBLIC repo"
cmp -s "$A" "$HOST_A" || fail "not in the host layer"
[[ "$(staged_in "$H")" == "hosts/addhost/apps/ad/files/a.conf" ]] || fail "not staged: $(staged_in "$H")"
[[ "$(git -C "$H" rev-parse HEAD)" == "$HEAD_H" ]] || fail "add committed"
[[ ! -e "$PROF_A" ]] || fail "wrote the profile layer"
public_clean "host save"
[[ "$(recs)" == "$RS" ]] || fail "a save touched the records"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
add s 2
cmp -s "$A" "$PROF_A" || fail "not in the profile layer"
[[ "$(staged_in "$H")" == "profiles/adp/apps/ad/files/a.conf" ]] || fail "not staged: $(staged_in "$H")"
[[ ! -e "$HOST_A" ]] || fail "wrote the host layer"
public_clean "profile save"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
add s 3 public
cmp -s "$A" "$PUB_A" || fail "not in the public layer"
[[ "$(staged_in "$R")" == "apps/ad/files/a.conf" ]] || fail "not staged: $(staged_in "$R")"
[[ "$(git -C "$R" rev-parse HEAD)" == "$HEAD_R" ]] || fail "add committed"
hosts_clean "public save"
git -C "$R" reset -q --hard
add s 9
has_line "No such layer"
hosts_clean "a bad layer"
public_clean "a bad layer"
add s q b
hosts_clean "q at the layer prompt"
no_line "=== ~/ad/b.conf ==="
pass "layers"

info "Review: saving a replaced file to a layer without a copy says it's created and masks"
fresh
echo mine >> "$A"
add s 1
has_line "creates the file in that layer"
has_line "masks any copy in lower layers"
pass "created"

info "Review: saving below a layer with the same file or key says the higher layer wins"
fresh
mkdir -p "$LH"
printf 'host version\n' > "$HOST_A"
jq -n '{model: "host model"}' > "$LH/settings.json"
git -C "$H" add -A
git -C "$H" commit -q -m "host copies"
do_pull
cmp -s "$HOST_A" "$A" || fail "host copy not deployed"
echo mine >> "$A"
edit_s '.model = "mine"'
add s 2 s 2
has_line "host: addhost (hosts repo) still wins, so on this host the change stays local"
cmp -s "$A" "$PROF_A" || fail "not saved to the profile"
[[ "$(jq -r .model "$LP/settings.json")" == mine ]] || fail "key not saved to the profile"
add
has_line "No local edits"
git -C "$H" commit -q -m "saved low"
do_pull
grep -qx mine "$A" || fail "the live value moved"
[[ "$(jq -r .model "$S")" == mine ]] || fail "the live key moved"
add
has_line "No local edits"
pass "higher layer wins"

info "Review: the default layer is the one that has it, unless that's the public repo"
fresh
echo mine >> "$A"
add s ""
cmp -s "$A" "$HOST_A" || fail "default is not the first layer"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
printf 'profile version\n' > "$T/p"
mkdir -p "$LP"
cp "$T/p" "$PROF_A"
git -C "$H" add -A
git -C "$H" commit -q -m "profile copy"
do_pull
add s y ""
cmp -s "$A" "$PROF_A" || fail "default is not the layer with the file"
[[ ! -e "$HOST_A" ]] || fail "wrote the host layer"
pass "defaults"

info "Review: a second save works if only add changed the file; other edits are skipped"
fresh
echo first >> "$A"
add s 1
echo second >> "$A"
add s 1
has_line "Staged hosts/addhost/apps/ad/files/a.conf"
no_line "uncommitted changes"
cmp -s "$A" "$HOST_A" || fail "second save lost"
saved=$(find "$STATE_DIR/records/.add-saved" -type f | head -1)
[[ -n "$saved" ]] || fail "no note of the save"
[[ "$(stat -c %a "$saved")" == 600 && "$(stat -c %a "$STATE_DIR/records/.add-saved")" == 700 ]] || fail "the note is not private"
echo 'hand edit' >> "$HOST_A"
HAND=$(cat "$HOST_A")
echo third >> "$A"
RS=$(recs)
add s 1
has_line "uncommitted changes; skipped"
[[ "$(cat "$HOST_A")" == "$HAND" ]] || fail "other work overwritten"
[[ "$(recs)" == "$RS" ]] || fail "records changed"
add k
has_line "=== ~/ad/a.conf ==="
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
mkdir -p "$LH"
echo 'never tracked' > "$HOST_A"
add s 1
has_line "uncommitted changes; skipped"
[[ "$(cat "$HOST_A")" == 'never tracked' ]] || fail "an untracked file was overwritten"
pass "second save"

info "Review: two merged keys saved to one new layer file in one run"
fresh
edit_s '.model = "m-mine" | .theme = "t-mine"'
add s 1 s 1
no_line "uncommitted changes"
[[ "$(jq -c . "$LH/settings.json")" == '{"model":"m-mine","theme":"t-mine"}' ]] || fail "layer: $(cat "$LH/settings.json")"
pass "both keys"

info "Review: a saved item isn't asked again, until the save is discarded"
fresh
echo mine >> "$A"
edit_s '.model = "mine"'
add s 1 s 1
add
has_line "No local edits"
add_all
has_line "No local edits"
run pull --no-backup --no-fetch
no_line "local edits"
grep -qx mine "$A" || fail "a staged save changed live"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
add k k
has_line "=== ~/ad/a.conf ==="
has_line 'key ["model"]'
run status
has_line "~/ad/a.conf"
repo_set b.conf 'b2'
do_pull
grep -qx mine "$A" || fail "the discarded edit was overwritten"
has_line "2 file(s) have local edits"
pass "asked again after git reset --hard, and still safe"

info "Review: after commit and pull, a saved item is clean"
fresh
echo mine >> "$A"
edit_s '.model = "mine"'
add s 1 s 1
git -C "$H" commit -q -m "saved"
do_pull
no_line "local edits"
cmp -s "$A" "$HOST_A" || fail "live differs from the layer"
cmp -s "$REC/repo/a.conf" "$HOST_A" || fail "repo copy is not the layer's"
cmp -s "$REC/review/a.conf" "$A" || fail "review copy is not live"
[[ "$(jq -r .model "$REC/repo/settings.json")" == mine ]] || fail "repo copy lacks the key"
add_all
has_line "No local edits"
run status
has_line "local edits:     none"
pass "clean after commit and pull"

info "Review: a merged save writes only that key, creating the layer's JSON if needed"
fresh
edit_s '.model = "mine" | .theme = "t2" | .nested.x = 9 | .newkey = {"deep": [1]}'
add s 1 k k k
[[ "$(jq -c . "$LH/settings.json")" == '{"model":"mine"}' ]] || fail "layer: $(cat "$LH/settings.json")"
[[ "$(staged_in "$H")" == "hosts/addhost/apps/ad/files/settings.json" ]] || fail "not staged: $(staged_in "$H")"
public_clean "merged save"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
mkdir -p "$LH"
printf '{"hostKey": "keep", "model": "old"}\n' > "$LH/settings.json"
git -C "$H" add -A
git -C "$H" commit -q -m "host settings"
add s 1 k k k
[[ "$(jq -c . "$LH/settings.json")" == '{"hostKey":"keep","model":"mine"}' ]] || fail "layer: $(cat "$LH/settings.json")"
pass "only that key"

info "Review: an invalid layer JSON refuses the save and leaves it alone"
fresh
edit_s '.model = "mine"'
mkdir -p "$LH"
printf 'not json\n' > "$LH/settings.json"
git -C "$H" add -A
git -C "$H" commit -q -m "bad json in the working copy only"
git -C "$H" reset -q --soft HEAD~1
git -C "$H" reset -q
RS=$(recs)
add s 1
has_line "not a valid JSON object"
[[ "$(cat "$LH/settings.json")" == 'not json' ]] || fail "layer changed"
[[ -z "$(staged_in "$H")" ]] || fail "staged something"
[[ "$(recs)" == "$RS" ]] || fail "records changed"
add k
has_line 'key ["model"]'
pass "refused"

info "Review: a deleted key offers only dismiss and skip, says why, and dismiss keeps it deleted"
fresh
edit_s 'del(.model)'
add s k
has_line "You deleted this repo-managed key"
has_line "Saving isn't possible"
has_line "d(ismiss)"
no_line "s(ave)"
has_line "Not an option: s"
hosts_clean "deleted key"
public_clean "deleted key"
add d
[[ "$(jq 'has("model")' "$REC/review/settings.json")" == false ]] || fail "still in the review copy"
add
has_line "No local edits"
repo_s '.theme = "t2"'
do_pull
[[ "$(jq 'has("model")' "$S")" == false ]] || fail "the deleted key came back"
[[ "$(jq -r .theme "$S")" == t2 ]] || fail "the other key did not update"
no_line "local edits"
add_all k
has_line 'key ["model"]'
has_line "(absent)"
pass "deleted key"

info "Review: deleting a repo-managed subtree is asked once per key, and doesn't come back"
fresh
edit_s 'del(.nested)'
add d d
add
has_line "No local edits"
[[ "$(jq 'has("nested")' "$REC/review/settings.json")" == false ]] || fail "left an empty object in the review copy"
pass "subtree"

info "Review: a deleted key in conflict with the repo can be dismissed too"
fresh
edit_s 'del(.model)'
repo_s '.model = "m2"'
run pull --no-backup --no-fetch
has_line "Keeping your values"
add d
has_line "You deleted this repo-managed key"
[[ "$(jq -r .model "$REC/repo/settings.json")" == m2 ]] || fail "repo copy"
run pull --no-backup --no-fetch
no_line "Keeping your values"
[[ "$(jq 'has("model")' "$S")" == false ]] || fail "came back"
pass "deleted, in conflict"

info "Review: an array save warns; reordered object keys in an array aren't an edit"
fresh
edit_s '.objs = [{"b": 2, "a": 1}]'
add
has_line "No local edits"
run status
has_line "local edits:     none"
edit_s '.list = [1, 2, 3]'
add s 1
has_line "hides later repo changes"
[[ "$(jq -c .list "$LH/settings.json")" == '[1,2,3]' ]] || fail "array not saved whole"
fresh
edit_s '.objs = [{"b": 9, "a": 1}]'
mkdir -p "$LH"
printf '{"objs":[{"a":1,"b":9}]}\n' > "$LH/settings.json"
git -C "$H" add -A
add
has_line "No local edits"
pass "arrays"

info "Review: a replaced-file conflict shows both changes and needs confirmation to save"
fresh
echo mine >> "$A"
repo_set a.conf 'a2'
RS=$(recs)
add s n
has_line "Your change"
has_line "+mine"
has_line "The repo's change"
has_line "+a2"
has_line "undoes the repo's change"
[[ ! -e "$HOST_A" ]] || fail "saved without confirmation"
[[ "$(recs)" == "$RS" ]] || fail "records changed"
add s
[[ ! -e "$HOST_A" ]] || fail "saved at EOF"
add s y 1
cmp -s "$A" "$HOST_A" || fail "not saved after confirmation"
add
has_line "No local edits"
add_all k
has_line "=== ~/ad/a.conf ==="
git -C "$H" commit -q -m "yours"
do_pull
no_line "kept your edit"
add_all
has_line "No local edits"
pass "conflict confirmed"

info "Review: the public layer shows the value and needs the word"
fresh
echo mine >> "$A"
edit_s '.model = "mine"'
add s 3 no s 3 no
has_line "PUBLIC repo"
has_line "mine"
public_clean "without the word"
add s 3 public s 3 public
[[ "$(jq -r .model "$LR/settings.json")" == mine ]] || fail "key not in the public repo"
cmp -s "$A" "$PUB_A" || fail "file not in the public repo"
[[ "$(staged_in "$R" | sort | tr '\n' ' ')" == "apps/ad/files/a.conf apps/ad/files/settings.json " ]] || fail "not staged: $(staged_in "$R")"
pass "public confirmed"

info "Review: the public repo isn't offered when pinned or without git"
fresh
echo mine >> "$A"
git -C "$R" commit -q --allow-empty -m "for the pin"
git -C "$R" checkout -q --detach
add s 1
no_line "dotfiles default (PUBLIC"
has_line "1) host: addhost"
cmp -s "$A" "$HOST_A" || fail "not saved"
git -C "$R" checkout -q main
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
mv "$R/.git" "$T/r.git"
add s 1
mv "$T/r.git" "$R/.git"
no_line "dotfiles default (PUBLIC"
has_line "1) host: addhost"
pass "public hidden"

info "Review: with no git anywhere, add only offers dismiss"
fresh
echo mine >> "$A"
mv "$R/.git" "$T/r.git"
mv "$H/.git" "$T/h.git"
RC=0
add s d
has_line "Saving isn't possible here"
no_line "s(ave)"
has_line "Not an option: s"
cmp -s "$REC/review/a.conf" "$A" || fail "dismiss failed"
[[ ! -e "$HOST_A" ]] || fail "saved"
[[ ! -e "$STATE_DIR/records/.add-saved" ]] || fail "a save was noted"
mv "$T/r.git" "$R/.git"
mv "$T/h.git" "$H/.git"
pass "dismiss only"

info "Review: hosts repo with no git: only the public layer"
fresh
echo mine >> "$A"
mv "$H/.git" "$T/h.git"
add s ""  no
mv "$T/h.git" "$H/.git"
has_line "1) dotfiles default (PUBLIC"
no_line "host: addhost"
no_line "profile: adp"
public_clean "without the word"
pass "no host layers without git"

info "Review: the host layer is offered with no host directory in the commit; a save creates it"
fresh
echo mine >> "$A"
OUT=$(printf 's\n1\n' | DOTFILES_ADD_ASSUME_TTY=1 "$R/dotfiles" add --hostname brandnew --profile adp 2>&1) || fail "add failed: $OUT"
has_line "1) host: brandnew (hosts repo)"
cmp -s "$A" "$H/hosts/brandnew/apps/ad/files/a.conf" || fail "host dir not created"
[[ "$(staged_in "$H")" == "hosts/brandnew/apps/ad/files/a.conf" ]] || fail "not staged: $(staged_in "$H")"
pass "new host directory"

info "Review: the closing message lists staged files per repo, on every way out"
fresh
echo mine >> "$A"
echo mine >> "$B"
add k k
no_line "Staged, not committed"
add s 1 q
has_line "Staged, not committed"
has_line "Commit and push"
has_line "other hosts won't get"
has_line "$H"
has_line "hosts/addhost/apps/ad/files/a.conf"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
add s 1
has_line "Staged, not committed"
has_line "hosts/addhost/apps/ad/files/a.conf"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
add s 1 s 3 public
has_line "Staged, not committed"
has_line "hosts/addhost/apps/ad/files/a.conf"
has_line "apps/ad/files/b.conf"
printf '%s\n' "$OUT" | grep -qxF "$R" || fail "public repo not named on its own line: $OUT"
printf '%s\n' "$OUT" | grep -qxF "$H" || fail "hosts repo not named on its own line: $OUT"
git -C "$H" reset -q --hard
git -C "$H" clean -qfd
git -C "$R" reset -q --hard
# Killed while waiting at a prompt
mkfifo "$T/answers"
DOTFILES_ADD_ASSUME_TTY=1 "$R/dotfiles" add > "$T/killed.out" 2>&1 < "$T/answers" &
ADD_PID=$!
exec 7> "$T/answers"
printf 's\n1\n' >&7
for _ in $(seq 1 100); do
    git -C "$H" diff --cached --quiet || break
    sleep 0.1
done
sleep 0.5
kill -TERM "$ADD_PID"
wait "$ADD_PID" || true
exec 7>&-
rm -f "$T/answers"
grep -qF "Staged, not committed" "$T/killed.out" || fail "no closing message when killed: $(cat "$T/killed.out")"
pass "closing message"

info "Review: first install: keys and files already there aren't offered"
N=$((N + 1))
export HOME="$T/r$N/home" STATE_DIR="$T/r$N/state" XDG_STATE_HOME="$T/r$N/xdg"
mkdir -p "$HOME/ad"
git -C "$R" reset -q --hard "$BASE_R"
git -C "$H" reset -q --hard "$BASE_H"
git -C "$H" clean -qfd
printf '{"mine": "existing", "model": "theirs", "tree": {"k": 1}}\n' > "$HOME/ad/settings.json"
printf 'old a\n' > "$HOME/ad/a.conf"
do_pull
add
has_line "No local edits"
[[ "$(jq -r .mine "$HOME/ad/settings.json")" == existing ]] || fail "existing key lost"
run status
has_line "local edits:     none"
pass "existing content isn't an edit"

info "Review: Claude Code rewriting settings.json: each value asked once, pull never blocked"
fresh
jq -S '.model = "claude-picked" | .feedbackSurveyState = {"lastShown": 5} | .tipsHistory = 3' "$S" > "$T/rewrite.json"
cat "$T/rewrite.json" > "$S"
repo_set a.conf 'a2'
run pull --no-backup --no-fetch
[[ $RC -eq 0 ]] || fail "pull blocked: $OUT"
grep -qx a2 "$A" || fail "pull did not apply the rest"
[[ "$(jq -r .model "$S")" == claude-picked ]] || fail "the value was overwritten"
has_line "1 file(s) have local edits"
add d d d
has_line 'key ["model"]'
has_line 'key ["feedbackSurveyState","lastShown"]'
has_line 'key ["tipsHistory"]'
add
has_line "No local edits"
run pull --no-backup --no-fetch
[[ $RC -eq 0 ]] || fail "pull blocked: $OUT"
no_line "local edits"
jq '.tipsHistory = 4' "$S" > "$T/rewrite.json"
cat "$T/rewrite.json" > "$S"
add d
has_line 'key ["tipsHistory"]'
no_line 'key ["model"]'
pass "asked once"

info "Review: an edit already equal to the repo's new version, or set back, is reviewed"
fresh
echo a2 > "$A"
edit_s '.model = "m2"'
repo_set a.conf a2
repo_s '.model = "m2"'
add
has_line "No local edits"
add_all
has_line "No local edits"
run pull --no-backup --no-fetch
no_line "kept your"
cmp -s "$REC/repo/a.conf" "$A" || fail "records not updated"
[[ "$(jq -r .model "$REC/review/settings.json")" == m2 ]] || fail "review not updated"
fresh
echo mine >> "$A"
edit_s '.model = "mine"'
add d d
cp "$LR/a.conf" "$A"
edit_s '.model = "m1"'
add_all
has_line "No local edits"
pass "no prompt"

info "Review: paths and keys with spaces, dots and quotes"
fresh
echo mine >> "$SP"
add s 1
has_line "=== ~/ad/my file.conf ==="
cmp -s "$SP" "$LH/my file.conf" || fail "file with a space not saved"
[[ "$(staged_in "$H")" == "hosts/addhost/apps/ad/files/my file.conf" ]] || fail "not staged: $(staged_in "$H")"
has_line "hosts/addhost/apps/ad/files/my file.conf"
git -C "$H" commit -q -m "spaced"
do_pull
no_line "local edits"
echo more >> "$SP"
add d
cmp -s "$REC/review/my file.conf" "$SP" || fail "dismiss with a space"
jq '.k = 2' "$Q" > "$T/q.json"
cat "$T/q.json" > "$Q"
add s 1
has_line "=== ~/ad/sub dir/it's.json"
[[ "$(jq -c . "$LH/sub dir/it's.json")" == '{"k":2}' ]] || fail "layer: $(cat "$LH/sub dir/it's.json")"
[[ "$(staged_in "$H")" == "hosts/addhost/apps/ad/files/sub dir/it's.json" ]] || fail "not staged: $(staged_in "$H")"
git -C "$H" commit -q -m "quoted"
do_pull
no_line "local edits"
fresh
edit_s '."a.b" = "dotted2" | .a.b = "nested2" | .["it'"'"'s \"q\""] = "quoted2" | .[" sp ace "] = "spaced2"'
add d s 1 s 1 s 1
has_line 'key [" sp ace "]'
has_line 'key ["a","b"]'
has_line 'key ["a.b"]'
has_line 'key ["it'"'"'s \"q\""]'
[[ "$(jq -r '.[" sp ace "]' "$REC/review/settings.json")" == spaced2 ]] || fail "dismiss of a spaced key"
[[ "$(jq -r '.a.b' "$REC/review/settings.json")" == "really nested" ]] || fail "dismiss touched a nested key"
[[ "$(jq -r '."a.b"' "$REC/review/settings.json")" == dotted ]] || fail "dismiss touched a dotted key"
[[ "$(jq -S -c . "$LH/settings.json")" == '{"a":{"b":"nested2"},"a.b":"dotted2","it'"'"'s \"q\"":"quoted2"}' ]] \
    || fail "layer: $(jq -S -c . "$LH/settings.json")"
add
has_line "No local edits"
git -C "$H" commit -q -m "keys"
do_pull
no_line "local edits"
pass "awkward names"

info "Review: a failed dismiss keeps that item pending and changes no other record"
fresh
echo mine >> "$A"
jq '.k = 2' "$Q" > "$T/q.json"
cat "$T/q.json" > "$Q"
QBEFORE=$(cat "$REC/review/sub dir/it's.json")
chmod 500 "$REC/review/sub dir"
add d d
has_line "stays pending"
chmod 700 "$REC/review/sub dir"
[[ "$(cat "$REC/review/sub dir/it's.json")" == "$QBEFORE" ]] || fail "the failed item's review copy changed"
cmp -s "$REC/review/a.conf" "$A" || fail "the other item was not dismissed"
add k
no_line "=== ~/ad/a.conf ==="
has_line "it's.json"
pass "dismiss failure"

info "Review: a conflict whose repo copy can't be written stays a conflict"
fresh
echo mine >> "$A"
repo_set a.conf a2
echo mine >> "$B"
REPO_A=$(cat "$REC/repo/a.conf")
REPO_B=$(cat "$REC/repo/b.conf")
REVIEW_B=$(cat "$REC/review/b.conf")
chmod 500 "$REC/repo"
add d k
has_line "stays pending"
chmod 700 "$REC/repo"
[[ "$(cat "$REC/repo/a.conf")" == "$REPO_A" ]] || fail "repo copy changed"
[[ "$(cat "$REC/repo/b.conf")" == "$REPO_B" && "$(cat "$REC/review/b.conf")" == "$REVIEW_B" ]] || fail "another item's record changed"
add k k
has_line "The repo's change"
pass "conflict dismiss failure"

info "Review: a merged dismiss that fails leaves both copies; another key still works"
fresh
edit_s '.model = "mine" | .theme = "mine"'
RS=$(recs)
chmod 500 "$REC/review"
add d d
has_line "stays pending"
chmod 700 "$REC/review"
[[ "$(recs)" == "$RS" ]] || fail "a record changed"
add d k
[[ "$(jq -r .model "$REC/review/settings.json")" == mine ]] || fail "model not dismissed"
[[ "$(jq -r .theme "$REC/review/settings.json")" == t1 ]] || fail "theme dismissed"
pass "merged dismiss failure"

info "Review: a save that can't stage is undone, stays pending, and other items go on"
fresh
echo mine >> "$A"
echo mine >> "$B"
RS=$(recs)
: > "$H/.git/index.lock"
add s 1 d
rm -f "$H/.git/index.lock"
has_line "stays pending"
[[ ! -e "$HOST_A" ]] || fail "the unstaged copy stayed in the layer"
no_line "Staged, not committed"
cmp -s "$REC/review/b.conf" "$B" || fail "the other item was not dismissed"
cmp -s "$REC/review/a.conf" "$LR/a.conf" || fail "the failed item's review copy changed"
add k
has_line "=== ~/ad/a.conf ==="
# An existing copy is put back
mkdir -p "$LH"
printf 'committed\n' > "$HOST_A"
git -C "$H" add -A
git -C "$H" commit -q -m "host copy"
: > "$H/.git/index.lock"
add s 1 k
rm -f "$H/.git/index.lock"
[[ "$(cat "$HOST_A")" == committed ]] || fail "the layer's copy was not put back"
hosts_clean "failed save"
pass "stage failure"

info "Review: a layer that can't be written stays pending; so does a merged key"
fresh
echo mine >> "$A"
edit_s '.model = "mine"'
RS=$(recs)
mkdir -p "$(dirname "$LH")"
printf 'not a dir\n' > "$LH"
add s 1 s 1
has_line "stays pending"
[[ "$(cat "$LH")" == 'not a dir' ]] || fail "changed"
[[ "$(recs)" == "$RS" ]] || fail "records changed"
rm -f "$LH"
add k k
has_line "=== ~/ad/a.conf ==="
has_line 'key ["model"]'
pass "write failure"

info "Review: a file that can't be compared is left out; the others are still offered"
fresh
printf 'not json\n' > "$S"
echo mine >> "$A"
RS=$(recs)
add d
has_line "=== ~/ad/a.conf ==="
has_line "settings.json"
[[ "$(cat "$S")" == 'not json' ]] || fail "live changed"
no_line "No local edits"
pass "invalid live JSON"

info "Review: add has no dry run, and refuses a second run"
RC=0
OUT=$(DOTFILES_ADD_ASSUME_TTY=1 "$R/dotfiles" add --dry-run 2>&1 </dev/null) || RC=$?
[[ $RC -ne 0 ]] || fail "dry run accepted"
has_line "no dry run"
pass "no dry run"

if command -v script >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    info "Review: on a real terminal, answers come from it, and its end of input stops the review"
    fresh
    echo mine >> "$A"
    RS=$(recs)
    RC=0
    OUT=$(: | timeout 60 script -qec "$R/dotfiles add" /dev/null 2>&1) || RC=$?
    [[ $RC -ne 124 ]] || fail "add hung on a terminal: $OUT"
    [[ "$(recs)" == "$RS" ]] || fail "the end of input changed the records: $OUT"
    RC=0
    OUT=$(printf 'd\n' | timeout 60 script -qec "$R/dotfiles add" /dev/null 2>&1) || RC=$?
    [[ $RC -eq 0 ]] || fail "add failed on a terminal: $OUT"
    has_line "s(ave)"
    cmp -s "$REC/review/a.conf" "$A" || fail "the answer didn't arrive: $OUT"
    pass "terminal"
fi

info "Scope: an app no longer in the profile isn't counted, listed or offered"
fresh
E="$HOME/ad/e.conf"
echo mine >> "$E"
printf 'packages:\n  - name: ad\n    config:\n      dir: ad\n' > "$H/profiles/adp.yaml"
git -C "$H" add -A
git -C "$H" commit -q -m "drop ae"
do_pull
no_line "local edits"
run pull --no-backup --no-fetch
has_line "Already up to date"
no_line "local edits"
run status
has_line "local edits:     none"
add
has_line "No local edits"
echo mine >> "$A"
run pull --no-backup --no-fetch
has_line "Already up to date"
has_line "1 file(s) have local edits"
pass "profile scope"

info "Scope: the count leaves out what's saved, which add can't clear"
fresh
echo mine >> "$A"
run pull --no-backup --no-fetch
has_line "1 file(s) have local edits"
add s 1
run pull --no-backup --no-fetch
no_line "local edits"
pass "count"

info "Status: a key named after a kind isn't mistaken for it"
fresh
edit_s '.conflict = 1'
run status
has_line "~/ad/settings.json"
no_line "the repo changed it too"
pass "status note"

# ---------------------------------------------------------------------------
# sync
# ---------------------------------------------------------------------------

UP_R="$T/up-r.git"
UP_H="$T/up-h.git"
AUTHOR="$T/author"
drop_remotes() {
    git -C "$R" remote remove origin 2>/dev/null || true
    git -C "$H" remote remove origin 2>/dev/null || true
}
set_up_remotes() {
    # First: fresh pulls, and must not bring in the last case's upstream
    drop_remotes
    fresh
    rm -rf "$UP_R" "$UP_H" "$AUTHOR"
    git -C "$R" branch -q -M main
    git clone -q --bare "$R" "$UP_R"
    git clone -q --bare "$H" "$UP_H"
    git -C "$R" remote add origin "$UP_R"
    git -C "$H" remote add origin "$UP_H"
    git -C "$R" fetch -q origin
    git -C "$H" fetch -q origin
    git -C "$R" branch -q -u origin/main main
    git -C "$H" branch -q -u origin/main main
    git clone -q "$UP_R" "$AUTHOR"
}
# Usage: author_set CONTENT: a commit upstream to a.conf
author_set() {
    printf '%s\n' "$1" > "$AUTHOR/apps/ad/files/a.conf"
    git -C "$AUTHOR" add -A
    git -C "$AUTHOR" commit -q -m "upstream change"
    git -C "$AUTHOR" push -q
}
sync_ans() {
    RC=0
    OUT=$(printf '%s\n' "$@" | DOTFILES_ADD_ASSUME_TTY=1 timeout 120 "$R/dotfiles" sync --no-backup 2>&1) || RC=$?
    [[ $RC -ne 124 ]] || fail "sync hung: $OUT"
}

info "Sync: fetched commits reach add, so it shows an incoming conflict"
set_up_remotes
echo mine >> "$A"
author_set 'upstream'
sync_ans d
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
has_line "The repo's change"
has_line "+upstream"
grep -qx mine "$A" || fail "the edit was lost"
cmp -s "$REC/repo/a.conf" "$LR/a.conf" || fail "repo copy not the fetched version"
no_line "kept your edit"
[[ "$(git -C "$R" rev-parse HEAD)" == "$(git -C "$AUTHOR" rev-parse HEAD)" ]] || fail "not fast-forwarded"
pass "incoming conflict"

info "Sync: skipping the conflict still pulls, and pull warns"
set_up_remotes
echo mine >> "$A"
author_set 'upstream'
sync_ans k
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
has_line "kept your edit to $A"
grep -qx mine "$A" || fail "the edit was lost"
pass "skipped conflict"

info "Sync: a network failure is a warning; add and pull still run"
set_up_remotes
echo mine >> "$A"
git -C "$R" remote set-url origin "$T/no-such-remote.git"
sync_ans d
[[ $RC -eq 0 ]] || fail "sync failed: $OUT"
has_line "could not update"
has_line "=== ~/ad/a.conf ==="
has_line "pull failed"
cmp -s "$REC/review/a.conf" "$A" || fail "add did not run"
pass "network failure"

info "Sync: diverged: add still runs, then pull stops with the commands"
set_up_remotes
echo mine >> "$A"
author_set 'upstream'
git -C "$R" commit -q --allow-empty -m "local commit"
sync_ans k
[[ $RC -ne 0 ]] || fail "pull should stop: $OUT"
has_line "=== ~/ad/a.conf ==="
has_line "git pull --rebase"
no_line "Phase 1"
grep -qx mine "$A" || fail "the edit was lost"
pass "diverged"

info "Sync: --no-fetch leaves HEAD, and a pinned repo isn't moved"
set_up_remotes
author_set 'upstream'
HEAD_R=$(git -C "$R" rev-parse HEAD)
RC=0
OUT=$(DOTFILES_ADD_ASSUME_TTY=1 "$R/dotfiles" sync --no-fetch --no-backup 2>&1 </dev/null) || RC=$?
[[ $RC -eq 0 && "$(git -C "$R" rev-parse HEAD)" == "$HEAD_R" ]] || fail "--no-fetch moved HEAD: $OUT"
git -C "$R" checkout -q --detach
sync_ans
[[ $RC -eq 0 && "$(git -C "$R" rev-parse HEAD)" == "$HEAD_R" ]] || fail "a pinned repo moved: $OUT"
git -C "$R" checkout -q main
pass "no-fetch and pinned"
drop_remotes

echo
echo "All edit protection and add tests passed"
