#!/usr/bin/env bash
# test-pull-records.sh - dotfiles pull against the records: the pull table, per file and
# per key, across several runs. Every case runs through 'dotfiles pull', in a throwaway
# HOME, from a committed copy of this tree with a test app added.

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
echo "Pull And Records Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR DOTFILES_RESET DOTFILES_FORCE_PATH
T="/tmp/dotfiles-test-pull-records-$$"
trap 'chmod -R u+rwx "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_TERMINAL_PROMPT=0
export GIT_SETUP_SKIP=true
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main

# The repo under test: this tree as it stands, committed, plus the app 'rt'
REPO="$T/repo"
mkdir -p "$REPO"
tar -C "$ROOT_DIR" --exclude=.git --exclude=.worktrees -cf - . | tar -C "$REPO" -xf -
RT="$REPO/apps/rt"
mkdir -p "$RT/files"
cat > "$RT/config.yaml" <<'EOF'
app:
  name: rt
  description: test app

files:
  - src: a.conf
    dest: ~/rt/a.conf
    mode: '0644'
  - src: b.conf
    dest: ~/rt/b.conf
    mode: '0644'
  - src: c.sh
    dest: ~/rt/c.sh
    mode: '0755'
  - src: settings.json
    dest: ~/rt/settings.json
    mode: '0644'
    strategy: merge
  - src: other.json
    dest: ~/rt/other.json
    mode: '0600'
    strategy: merge
  - src: my file.conf
    dest: ~/rt/my file.conf
    mode: '0644'

backup:
  dir: ~/.bak/rt
  max_backups: 3
EOF
cat > "$RT/configure.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"
installer_main "$@"
EOF
chmod +x "$RT/configure.sh"
printf 'a1\n' > "$RT/files/a.conf"
printf 'b1\n' > "$RT/files/b.conf"
printf 'c1\n' > "$RT/files/c.sh"
printf 's1\n' > "$RT/files/my file.conf"
BASE_SETTINGS='{"model":"m1","theme":"t1","nested":{"x":1,"y":2},"list":[1,2],"a.b@c":"dotted"}'
printf '%s\n' "$BASE_SETTINGS" > "$RT/files/settings.json"
printf '{"o":1}\n' > "$RT/files/other.json"
# A second app, after rt in the profile, for files moving between apps
RT2="$REPO/apps/rt2"
mkdir -p "$RT2/files"
cat > "$RT2/config.yaml" <<'EOF'
app:
  name: rt2
  description: second test app

files:
  - src: z.conf
    dest: ~/rt/z.conf
    mode: '0644'
  - src: z.json
    dest: ~/rt/z.json
    mode: '0644'
    strategy: merge

backup:
  dir: ~/.bak/rt2
  max_backups: 3
EOF
cp "$RT/configure.sh" "$RT2/configure.sh"
printf 'z1\n' > "$RT2/files/z.conf"
printf '{"z":1,"y":1}\n' > "$RT2/files/z.json"
printf 'packages:\n  - name: rt\n    config:\n      dir: rt\n  - name: rt2\n    config:\n      dir: rt2\n' > "$REPO/profiles/rt.yaml"
# With a tool to install, to show which runs reach the package phases
printf 'packages:\n  - name: rt\n    config:\n      dir: rt\n  - name: faketool\n    custom:\n      check: "false"\n      script: ../test/fixtures/testtool/install.sh\n' > "$REPO/profiles/rtpkg.yaml"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base
BASE=$(git -C "$REPO" rev-parse HEAD)

export DOTFILES_CONFIG="$T/config"
printf 'hostname: nohost\nprofile: rt\n' > "$DOTFILES_CONFIG"

N=0
OUT=""
RC=0
fresh() {
    N=$((N + 1))
    export HOME="$T/h$N" STATE_DIR="$T/s$N" XDG_STATE_HOME="$T/x$N"
    mkdir -p "$HOME"
    git -C "$REPO" reset -q --hard "$BASE"
    LIVE="$HOME/rt"
    R="$STATE_DIR/records/rt"
    COMPLETE="$XDG_STATE_HOME/dotfiles/last-complete"
}
# Runs a pull; output in OUT, exit code in RC
pull() {
    RC=0
    OUT=$("$REPO/dotfiles" pull --no-fetch --no-backup --skip-git-setup "$@" 2>&1) || RC=$?
}
pull_ok() {
    pull "$@"
    [[ $RC -eq 0 ]] || fail "pull $* failed ($RC): $OUT"
}
fresh_installed() {
    fresh
    pull_ok
}
# Commit content for files of the app. Usage: repo_set SRC CONTENT [SRC CONTENT...]
repo_set() {
    while [[ $# -gt 0 ]]; do
        printf '%s\n' "$2" > "$RT/files/$1"
        git -C "$REPO" add -A "apps/rt/files"
        shift 2
    done
    git -C "$REPO" commit -q -m change
}
# A commit that changes only the file c.sh, so the app runs again in full
repo_unrelated() { repo_set c.sh "c-$RANDOM$RANDOM"; }
settings() { jq -c "$BASE_SETTINGS * ($1)" <<<'null' ; }

has() { [[ "$OUT" == *"$1"* ]] || fail "${2:-expected '$1'}: $OUT"; }
hasnt() { [[ "$OUT" != *"$1"* ]] || fail "${2:-unexpected '$1'}: $OUT"; }
content() { [[ "$(cat "$1")" == "$2" ]] || fail "${3:-$1}: holds '$(cat "$1" 2>&1)', expected '$2'"; }
same() { cmp -s "$1" "$2" || fail "${3:-$1 differs from $2}: '$(cat "$1" 2>&1)' vs '$(cat "$2" 2>&1)'"; }
# JSON equality, ignoring key order
json() {
    jq -e --argjson want "$2" '. == $want' "$1" >/dev/null 2>&1 || fail "${3:-$1}: holds $(jq -c . "$1" 2>&1), expected $2"
}
# The value at a jq path of a JSON file
jv() { jq -c "$2" "$1"; }
state() { grep '^  version:' "$STATE_DIR/apps/rt.yaml" | awk '{print $2}'; }
complete_written() { [[ -s "$COMPLETE" ]] || fail "$1: last-complete should be written: $OUT"; }
complete_absent() { [[ ! -e "$COMPLETE" ]] || fail "$1: last-complete should not be written: $OUT"; }
# What add would see for a file, from the records as they stand
items() {
    (
        source "$REPO/lib/records.sh"
        records_items rt "$1" "$2" "${3:-}" "${4:-false}"
    )
}
flagged() {
    local got
    got=$(items "$1" "$LIVE/$1")
    [[ "$got" == *edited* ]] || fail "$1: edit should stay flagged, items: '$got'"
}
snapshot_with() {
    local file="$1" text="$2" f
    while IFS= read -r f; do
        grep -qF -- "$text" "$f" && return 0
    done < <(find "$HOME/.bak/rt" -mindepth 2 -type f -name "$file" ! -path '*/original/*' 2>/dev/null)
    fail "no snapshot of $file holding '$text': $(find "$HOME/.bak" -type f 2>&1)"
}
no_snapshot_of() {
    [[ -z "$(find "$HOME/.bak/rt" -mindepth 2 -type f -name "$1" ! -path '*/original/*' 2>/dev/null)" ]] \
        || fail "unexpected snapshot of $1: $(find "$HOME/.bak" -type f)"
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# --- Replaced files: the table ------------------------------------------------

info "First pull: fresh deploy, both copies recorded and private"
fresh
pull_ok
content "$LIVE/a.conf" a1
json "$LIVE/settings.json" "$BASE_SETTINGS"
same "$R/repo/a.conf" "$RT/files/a.conf"
same "$R/review/a.conf" "$LIVE/a.conf"
json "$R/repo/settings.json" "$BASE_SETTINGS"
json "$R/review/settings.json" "$BASE_SETTINGS"
[[ "$(mode_of "$R/repo/a.conf")" == 600 && "$(mode_of "$R/review/a.conf")" == 600 ]] || fail "copies not 0600"
[[ "$(mode_of "$R/repo")" == 700 && "$(mode_of "$R/review")" == 700 ]] || fail "copy dirs not 0700"
[[ "$(mode_of "$LIVE/c.sh")" == 755 && "$(mode_of "$LIVE/other.json")" == 600 ]] || fail "modes not set"
grep -qF "$(printf 'a.conf\t%s\treplace' "$LIVE/a.conf")" "$R/manifest.tsv" || fail "manifest lacks a.conf"
grep -qF "$(printf 'settings.json\t%s\tmerge' "$LIVE/settings.json")" "$R/manifest.tsv" || fail "manifest lacks settings.json"
[[ "$(state)" =~ ^[0-9a-f]{12}$ ]] || fail "state version: $(state)"
complete_written "first pull"
[[ ! -d "$STATE_DIR/deployed" ]] || fail "old records written"
pass "fresh deploy recorded"

info "Replaced: repo change on an untouched file applies, records follow"
fresh_installed
repo_set a.conf a2
pull_ok
content "$LIVE/a.conf" a2
content "$R/repo/a.conf" a2
content "$R/review/a.conf" a2
complete_written "applied"
pass "no edit, repo change: applied"

info "Replaced: nothing changed does nothing"
fresh_installed
touch -d '2001-01-01' "$LIVE/a.conf"
repo_unrelated
pull_ok
[[ "$(stat -c %Y "$LIVE/a.conf")" == "$(date -d '2001-01-01' +%s)" ]] || fail "untouched file was rewritten"
content "$LIVE/a.conf" a1
pass "no edit, no repo change: live not rewritten"

info "Replaced: edit, repo unchanged, keeps it across pulls and stays flagged"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_unrelated
pull_ok
content "$LIVE/a.conf" mine
content "$R/repo/a.conf" a1
content "$R/review/a.conf" a1
flagged a.conf
has "1 file(s) have local edits"
hasnt "kept your edit" "not a conflict"
complete_written "kept"
repo_unrelated
pull_ok
content "$LIVE/a.conf" mine
flagged a.conf
pass "edit, no repo change: kept and flagged"

info "Replaced: edit equal to the repo's new value updates records only"
fresh_installed
echo a2 > "$LIVE/a.conf"
touch -d '2001-01-01' "$LIVE/a.conf"
repo_set a.conf a2
pull_ok
[[ "$(stat -c %Y "$LIVE/a.conf")" == "$(date -d '2001-01-01' +%s)" ]] || fail "live rewritten"
content "$R/repo/a.conf" a2
content "$R/review/a.conf" a2
hasnt "kept your edit"
[[ -z "$(items a.conf "$LIVE/a.conf")" ]] || fail "still flagged: $(items a.conf "$LIVE/a.conf")"
complete_written "same"
pass "edit, repo moved to it: records only"

info "Replaced: conflict keeps yours, warns on every pull, blocks last-complete"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_set a.conf a2
for run in 1 2 3; do
    pull_ok
    content "$LIVE/a.conf" mine "run $run"
    content "$R/repo/a.conf" a1 "run $run"
    content "$R/review/a.conf" a1 "run $run"
    has "kept your edit to $LIVE/a.conf"
    complete_absent "conflict run $run"
    [[ "$(state)" == conflict:* ]] || fail "state: $(state)"
done
RC=0
OUT=$("$REPO/dotfiles" status 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "status failed: $OUT"
grep -E '^ +rt +.*conflict' <<<"$OUT" >/dev/null || fail "status does not show the conflict: $OUT"
[[ "$(items a.conf "$LIVE/a.conf" "$RT/files/a.conf")" == *conflict* ]] || fail "add would not see the conflict"
pass "conflict repeats and stops nothing else"

info "Replaced: after a conflict, reverting by hand applies the repo's version"
echo a1 > "$LIVE/a.conf"
pull_ok
content "$LIVE/a.conf" a2
content "$R/repo/a.conf" a2
content "$R/review/a.conf" a2
hasnt "kept your edit"
complete_written "resolved"
[[ "$(state)" != conflict:* ]] || fail "state still conflict"
rm "$LIVE/a.conf"
pull_ok
has "Already up to date"
[[ ! -e "$LIVE/a.conf" ]] || fail "early stop should not restore"
pass "hand revert resolves it, next pull stops early"

info "Replaced: conflict, then the repo goes back to the old value"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_set a.conf a2
pull_ok
has "kept your edit"
repo_set a.conf a1
pull_ok
content "$LIVE/a.conf" mine
content "$R/repo/a.conf" a1
hasnt "kept your edit"
[[ "$(state)" != conflict:* ]] || fail "state: $(state)"
complete_written "repo reverted"
flagged a.conf
pass "repo revert ends the conflict, edit stays and is flagged"

info "Replaced: conflict, then the repo moves to your value"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_set a.conf a2
pull_ok
repo_set a.conf mine
pull_ok
content "$LIVE/a.conf" mine
content "$R/repo/a.conf" mine
hasnt "kept your edit"
complete_written "repo agreed"
pass "repo agrees: settled"

info "Replaced: conflict, then the repo moves again, conflict stays against the last accepted copy"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_set a.conf a2
pull_ok
repo_set a.conf a3
pull_ok
content "$LIVE/a.conf" mine
content "$R/repo/a.conf" a1
has "kept your edit"
echo a1 > "$LIVE/a.conf"
pull_ok
content "$LIVE/a.conf" a3
pass "last accepted stays the base"

info "Replaced: conflict, then the live file is deleted: the repo's version comes back"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_set a.conf a2
pull_ok
rm "$LIVE/a.conf"
pull_ok
content "$LIVE/a.conf" a2
content "$R/repo/a.conf" a2
hasnt "kept your edit"
pass "deleted conflict restored"

info "A repo change to another file of the app leaves an edit alone"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_set b.conf b2
pull_ok
content "$LIVE/a.conf" mine
content "$LIVE/b.conf" b2
content "$R/repo/a.conf" a1
content "$R/review/a.conf" a1
content "$R/repo/b.conf" b2
flagged a.conf
hasnt "kept your edit"
pass "other file updates, edit untouched"

info "Dismiss-like state for a replaced file: review matches live"
fresh_installed
echo mine > "$LIVE/a.conf"
cp "$LIVE/a.conf" "$R/review/a.conf"
[[ -z "$(items a.conf "$LIVE/a.conf")" ]] || fail "dismissed item shows"
repo_unrelated
pull_ok
content "$LIVE/a.conf" mine
content "$R/review/a.conf" mine
content "$R/repo/a.conf" a1
[[ -z "$(items a.conf "$LIVE/a.conf")" ]] || fail "dismissed item came back"
hasnt "local edits"
# The repo then changes it: a conflict all the same
repo_set a.conf a2
pull_ok
content "$LIVE/a.conf" mine
has "kept your edit"
# Dismissing the conflict accepts the repo's version as the starting point
cp "$RT/files/a.conf" "$R/repo/a.conf"
pull_ok
content "$LIVE/a.conf" mine
hasnt "kept your edit"
[[ "$(state)" != conflict:* ]] || fail "state: $(state)"
complete_written "dismissed conflict"
# And a later repo change conflicts again, against that version
repo_set a.conf a3
pull_ok
content "$LIVE/a.conf" mine
has "kept your edit"
pass "dismiss-like states hold across pulls"

# --- Merged files: the table per key -------------------------------------------

info "Merged: an untouched key follows, an edit and a local-only key stay"
fresh_installed
jq '.theme = "mine" | .localOnly = 1' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_set settings.json "$(settings '{"model":"m2"}')"
pull_ok
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "model not applied"
[[ "$(jv "$LIVE/settings.json" .theme)" == '"mine"' ]] || fail "edit lost"
[[ "$(jv "$LIVE/settings.json" .localOnly)" == 1 ]] || fail "local-only key lost"
[[ "$(jv "$R/repo/settings.json" .model)" == '"m2"' ]] || fail "repo copy model"
[[ "$(jv "$R/review/settings.json" .model)" == '"m2"' ]] || fail "review model"
[[ "$(jv "$R/review/settings.json" .theme)" == '"t1"' ]] || fail "review took the unreviewed edit"
[[ "$(jv "$R/review/settings.json" .localOnly)" == null ]] || fail "review took the local-only key"
hasnt "kept your edit"
complete_written "merged keep"
pass "per-key apply, keep and local-only"

info "An unrelated repo change doesn't overwrite a settings.json edit, and it stays flagged"
fresh_installed
jq '.theme = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
cp "$LIVE/settings.json" "$T/edited"
touch -d '2001-01-01' "$LIVE/settings.json"
repo_unrelated
pull_ok
same "$LIVE/settings.json" "$T/edited"
[[ "$(stat -c %Y "$LIVE/settings.json")" == "$(date -d '2001-01-01' +%s)" ]] || fail "live rewritten with nothing to apply"
[[ "$(items settings.json "$LIVE/settings.json")" == *'edited	["theme"]'* ]] || fail "not flagged: $(items settings.json "$LIVE/settings.json")"
has "1 file(s) have local edits"
repo_set b.conf b2
pull_ok
same "$LIVE/settings.json" "$T/edited"
[[ "$(items settings.json "$LIVE/settings.json")" == *'edited	["theme"]'* ]] || fail "flag lost after a second pull"
pass "unrelated change leaves the edit alone"

info "Merged: hand formatting survives when nothing applies"
fresh_installed
printf '{\n"model":   "m1", "theme":"t1","nested":{"y":2,"x":1},\n"list":[1,2],"a.b@c":"dotted"}\n' > "$LIVE/settings.json"
cp "$LIVE/settings.json" "$T/formatted"
repo_unrelated
pull_ok
same "$LIVE/settings.json" "$T/formatted"
pass "not rewritten"

info "Merged: edit equal to the repo's new value updates records only"
fresh_installed
jq '.model = "m2"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_set settings.json "$(settings '{"model":"m2"}')"
pull_ok
[[ "$(jv "$R/repo/settings.json" .model)" == '"m2"' && "$(jv "$R/review/settings.json" .model)" == '"m2"' ]] || fail "records"
hasnt "kept your edit"
[[ -z "$(items settings.json "$LIVE/settings.json")" ]] || fail "flagged"
pass "merged same"

info "Merged: a conflict keeps yours per key, others apply, repeats on every pull"
fresh_installed
jq '.model = "mine" | .localOnly = 1' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_set settings.json "$(settings '{"model":"m2","theme":"t2"}')"
for run in 1 2 3; do
    pull_ok
    [[ "$(jv "$LIVE/settings.json" .model)" == '"mine"' ]] || fail "run $run: conflict overwritten"
    [[ "$(jv "$LIVE/settings.json" .theme)" == '"t2"' ]] || fail "run $run: other key not applied"
    [[ "$(jv "$LIVE/settings.json" .localOnly)" == 1 ]] || fail "run $run: local-only key lost"
    [[ "$(jv "$R/repo/settings.json" .model)" == '"m1"' ]] || fail "run $run: repo copy took the held value"
    [[ "$(jv "$R/repo/settings.json" .theme)" == '"t2"' ]] || fail "run $run: repo copy missed the applied value"
    [[ "$(jv "$R/review/settings.json" .model)" == '"m1"' ]] || fail "run $run: review took the held value"
    has "kept your edit to $LIVE/settings.json"
    has '"model"' "run $run: key not named"
    complete_absent "merged conflict run $run"
    [[ "$(state)" == conflict:* ]] || fail "state: $(state)"
done
[[ "$(items settings.json "$LIVE/settings.json" "$RT/files/settings.json")" == *'conflict	["model"]'* ]] || fail "add would not see it"
pass "per-key conflict"

info "Merged: reverting the key by hand applies the repo's value"
jq '.model = "m1"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
pull_ok
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "not applied"
[[ "$(jv "$R/repo/settings.json" .model)" == '"m2"' ]] || fail "repo copy"
hasnt "kept your edit"
complete_written "merged resolved"
[[ "$(state)" != conflict:* ]] || fail "state"
pass "merged conflict resolved by hand"

info "Merged: conflict, then the repo goes back to the old value"
fresh_installed
jq '.model = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_set settings.json "$(settings '{"model":"m2"}')"
pull_ok
has "kept your edit"
repo_set settings.json "$BASE_SETTINGS"
pull_ok
[[ "$(jv "$LIVE/settings.json" .model)" == '"mine"' ]] || fail "edit lost"
hasnt "kept your edit"
complete_written "merged repo reverted"
[[ "$(items settings.json "$LIVE/settings.json")" == *'edited	["model"]'* ]] || fail "edit no longer flagged"
pass "merged repo revert"

info "Merged: a dismiss-like state holds, and a later repo change conflicts"
fresh_installed
jq '.theme = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
cp "$LIVE/settings.json" "$R/review/settings.json"
[[ -z "$(items settings.json "$LIVE/settings.json")" ]] || fail "dismissed key shows"
repo_set settings.json "$(settings '{"model":"m2"}')"
pull_ok
[[ "$(jv "$LIVE/settings.json" .theme)" == '"mine"' && "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "live"
[[ "$(jv "$R/review/settings.json" .theme)" == '"mine"' ]] || fail "review lost the dismissal"
[[ -z "$(items settings.json "$LIVE/settings.json")" ]] || fail "dismissed key came back: $(items settings.json "$LIVE/settings.json")"
repo_set settings.json "$(settings '{"model":"m2","theme":"t2"}')"
pull_ok
[[ "$(jv "$LIVE/settings.json" .theme)" == '"mine"' ]] || fail "dismissed edit overwritten"
has "kept your edit"
pass "merged dismiss-like state"

info "Merged: a key the repo stops managing goes if unchanged, stays if edited"
fresh_installed
jq '.theme = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_set settings.json '{"nested":{"x":1,"y":2},"list":[1,2],"a.b@c":"dotted","theme":"t1"}'
pull_ok
[[ "$(jv "$LIVE/settings.json" 'has("model")')" == false ]] || fail "unchanged key not removed"
[[ "$(jv "$R/repo/settings.json" 'has("model")')" == false ]] || fail "repo copy keeps it"
[[ "$(jv "$LIVE/settings.json" .theme)" == '"mine"' ]] || fail "edit lost"
repo_set settings.json '{"nested":{"x":1,"y":2},"list":[1,2],"a.b@c":"dotted"}'
pull_ok
[[ "$(jv "$LIVE/settings.json" .theme)" == '"mine"' ]] || fail "edited dropped key lost"
has "kept your edit"
pass "dropped keys"

info "Merged: a deleted repo-managed key stays deleted; a dotted key and an array are one value"
fresh_installed
jq 'del(.theme) | .list = [9] | .["a.b@c"] = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_unrelated
pull_ok
[[ "$(jv "$LIVE/settings.json" 'has("theme")')" == false ]] || fail "deleted key came back"
[[ "$(jv "$LIVE/settings.json" .list)" == '[9]' ]] || fail "array edit lost"
[[ "$(jv "$LIVE/settings.json" '.["a.b@c"]')" == '"mine"' ]] || fail "dotted edit lost"
repo_set settings.json "$(settings '{"a.b@c":"new","list":[1,2,3]}' | jq -c '.list=[1,2,3]')"
pull_ok
[[ "$(jv "$LIVE/settings.json" '.["a.b@c"]')" == '"mine"' ]] || fail "dotted conflict overwritten"
[[ "$(jv "$LIVE/settings.json" .list)" == '[9]' ]] || fail "array conflict overwritten"
has '["a.b@c"]' "path not shown as an array"
pass "deleted, dotted and array values"

info "Merged: an object turned plain by the repo over an edit conflicts on the subtree"
fresh_installed
jq '.nested.x = 99 | .nested.local = 1' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_set settings.json "$(settings '{}' | jq -c '.nested = "plain"')"
pull_ok
[[ "$(jv "$LIVE/settings.json" .nested.x)" == 99 && "$(jv "$LIVE/settings.json" .nested.local)" == 1 ]] || fail "subtree overwritten"
has "kept your edit"
has '["nested"]'
pass "structural conflict"

# --- --force -------------------------------------------------------------------

info "--force: takes the repo's version, keeps local-only keys, always snapshots"
fresh_installed
echo mine > "$LIVE/a.conf"
jq '.model = "mine" | .localOnly = 1 | .nested.z = 5' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_set a.conf a2 settings.json "$(settings '{"model":"m2"}')"
pull_ok
has "kept your edit"
pull_ok --force
content "$LIVE/a.conf" a2
content "$R/repo/a.conf" a2
content "$R/review/a.conf" a2
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "managed value not forced"
[[ "$(jv "$LIVE/settings.json" .localOnly)" == 1 && "$(jv "$LIVE/settings.json" .nested.z)" == 5 ]] || fail "local-only key lost"
[[ "$(jv "$R/repo/settings.json" .model)" == '"m2"' && "$(jv "$R/review/settings.json" .model)" == '"m2"' ]] || fail "records"
[[ "$(jv "$R/review/settings.json" .localOnly)" == null ]] || fail "review took an unreviewed local-only key"
[[ "$(items settings.json "$LIVE/settings.json")" == *'edited	["localOnly"]'* ]] || fail "local-only edit no longer flagged"
snapshot_with a.conf mine
snapshot_with settings.json mine
hasnt "kept your edit"
[[ "$(state)" != conflict:* ]] || fail "state"
complete_written "--force"
pull_ok
has "Already up to date"
content "$LIVE/a.conf" a2
pass "--force resolves conflicts with a snapshot under --no-backup"

info "--force: an edit with no repo change is overwritten too, and a repo-dropped edit stays"
fresh_installed
echo mine > "$LIVE/b.conf"
jq '.theme = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
pull_ok --force
content "$LIVE/b.conf" b1
[[ "$(jv "$LIVE/settings.json" .theme)" == '"t1"' ]] || fail "managed edit not forced"
snapshot_with b.conf mine
jq '.theme = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_set settings.json '{"model":"m1","nested":{"x":1,"y":2},"list":[1,2],"a.b@c":"dotted"}'
pull_ok --force
[[ "$(jv "$LIVE/settings.json" .theme)" == '"mine"' ]] || fail "key the repo dropped should stay"
[[ "$(jv "$R/repo/settings.json" 'has("theme")')" == false ]] || fail "repo copy"
pass "--force overwrites managed values only"

info "--force restores a deleted live file; invalid live JSON still fails"
fresh_installed
rm "$LIVE/a.conf" "$LIVE/settings.json"
pull_ok --force
content "$LIVE/a.conf" a1
json "$LIVE/settings.json" "$BASE_SETTINGS"
echo '{oops' > "$LIVE/settings.json"
pull --force
[[ $RC -eq 1 ]] || fail "should fail: $OUT"
content "$LIVE/settings.json" '{oops'
content "$LIVE/a.conf" a1
pass "--force restores; invalid JSON untouched"

info "--force --dry-run changes nothing and takes no snapshot"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_set a.conf a2
pull_ok --force --dry-run
content "$LIVE/a.conf" mine
content "$R/repo/a.conf" a1
[[ ! -d "$HOME/.bak/rt" ]] || [[ -z "$(find "$HOME/.bak/rt" -mindepth 2 -type f ! -path '*/original/*')" ]] || fail "dry run took a snapshot"
pass "dry run"

info "--force PATH: only that file, with several in conflict"
fresh_installed
echo mine-a > "$LIVE/a.conf"
echo mine-b > "$LIVE/b.conf"
jq '.model = "mine" | .localOnly = 1' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_set a.conf a2 b.conf b2 settings.json "$(settings '{"model":"m2"}')"
pull_ok
pull_ok --force "$LIVE/a.conf"
content "$LIVE/a.conf" a2
content "$R/repo/a.conf" a2
content "$R/review/a.conf" a2
content "$LIVE/b.conf" mine-b
content "$R/repo/b.conf" b1
[[ "$(jv "$LIVE/settings.json" .model)" == '"mine"' ]] || fail "other file forced"
[[ "$(jv "$R/repo/settings.json" .model)" == '"m1"' ]] || fail "other file's record moved"
snapshot_with a.conf mine-a
no_snapshot_of b.conf
no_snapshot_of settings.json
complete_absent "--force PATH"
pull_ok
content "$LIVE/a.conf" a2
content "$LIVE/b.conf" mine-b
has "kept your edit to $LIVE/b.conf"
has "kept your edit to $LIVE/settings.json"
hasnt "kept your edit to $LIVE/a.conf"
complete_absent "remaining conflicts"
[[ "$(state)" == conflict:* ]] || fail "state: $(state)"
pull_ok --force "$LIVE/settings.json"
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "not forced"
[[ "$(jv "$LIVE/settings.json" .localOnly)" == 1 ]] || fail "local-only key lost"
snapshot_with settings.json mine
content "$LIVE/b.conf" mine-b
pull_ok --force "$LIVE/b.conf"
content "$LIVE/b.conf" b2
pull_ok
hasnt "kept your edit"
[[ "$(state)" != conflict:* ]] || fail "state after the last conflict: $(state)"
complete_written "all forced"
pass "--force PATH one file at a time"

info "--force PATH leaves another file's pending repo change for the next pull"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_set a.conf a2 b.conf b2
pull_ok --force "$LIVE/a.conf"
content "$LIVE/a.conf" a2
content "$LIVE/b.conf" b1
content "$R/repo/b.conf" b1
pull_ok
content "$LIVE/b.conf" b2
complete_written "next pull"
pass "only that file changes"

info "--force PATH: relative paths, a space, a deleted file"
fresh_installed
echo mine > "$LIVE/a.conf"
echo mine > "$LIVE/my file.conf"
ORIG_PWD="$PWD"
cd "$LIVE"
pull_ok --force a.conf
cd "$ORIG_PWD"
content "$LIVE/a.conf" a1
content "$LIVE/my file.conf" mine
pull_ok --force "$LIVE/my file.conf"
content "$LIVE/my file.conf" s1
rm "$LIVE/b.conf"
cd "$LIVE"
pull_ok --force ./b.conf
cd "$ORIG_PWD"
content "$LIVE/b.conf" b1
pass "path forms"

info "--force PATH: an unmanaged path exits 1 and changes nothing"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_set a.conf a2
echo x > "$HOME/unmanaged"
for bad in "$HOME/unmanaged" "$HOME/nope" "$LIVE"; do
    pull --force "$bad"
    [[ $RC -eq 1 ]] || fail "$bad: expected exit 1, got $RC: $OUT"
    has "not managed" "$bad: no reason"
    content "$LIVE/a.conf" mine
    content "$R/repo/a.conf" a1
done
pass "unmanaged path refused"

info "--force PATH with another bare option after it, and bare --force before one"
fresh_installed
echo mine > "$LIVE/a.conf"
echo mine > "$LIVE/b.conf"
RC=0
OUT=$("$REPO/dotfiles" pull --force "$LIVE/a.conf" --no-fetch --no-backup --skip-git-setup 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "failed: $OUT"
content "$LIVE/a.conf" a1
content "$LIVE/b.conf" mine
RC=0
OUT=$("$REPO/dotfiles" pull --force --no-fetch --no-backup --skip-git-setup 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "failed: $OUT"
content "$LIVE/b.conf" b1
RC=0
OUT=$("$REPO/dotfiles" status --force "$LIVE/a.conf" 2>&1) || RC=$?
[[ $RC -ne 0 ]] || fail "only pull takes a path: $OUT"
pass "option parsing"

# --- First install -------------------------------------------------------------

info "First install over existing files: live * repo, both copies, original and snapshot"
fresh
mkdir -p "$LIVE"
echo '{"model":"old","localOnly":1,"nested":{"x":7,"z":8}}' > "$LIVE/settings.json"
cp "$LIVE/settings.json" "$T/orig-settings"
echo old-a > "$LIVE/a.conf"
pull_ok
[[ "$(jv "$LIVE/settings.json" .model)" == '"m1"' ]] || fail "repo value not applied"
[[ "$(jv "$LIVE/settings.json" .localOnly)" == 1 && "$(jv "$LIVE/settings.json" .nested.z)" == 8 ]] || fail "live keys lost"
[[ "$(jv "$LIVE/settings.json" .nested.x)" == 1 ]] || fail "nested repo value not applied"
json "$R/repo/settings.json" "$BASE_SETTINGS"
same "$R/review/settings.json" "$LIVE/settings.json"
content "$LIVE/a.conf" a1
same "$HOME/.bak/rt/original/settings.json" "$T/orig-settings"
content "$HOME/.bak/rt/original/a.conf" old-a
snapshot_with settings.json '"old"'
snapshot_with a.conf old-a
[[ -z "$(items settings.json "$LIVE/settings.json")" ]] || fail "existing keys offered: $(items settings.json "$LIVE/settings.json")"
[[ "$(items settings.json "$LIVE/settings.json" "" true)" == *dismissed* ]] || fail "add --all should list them"
pass "first install keeps the original under --no-backup"

info "First install over a non-object or invalid live file fails that file only, and retries"
fresh
mkdir -p "$LIVE"
echo '[]' > "$LIVE/settings.json"
pull
[[ $RC -eq 1 ]] || fail "expected failure: $OUT"
content "$LIVE/settings.json" '[]'
content "$LIVE/a.conf" a1
[[ ! -e "$R/repo/settings.json" ]] || fail "records written"
[[ "$(state)" == incomplete ]] || fail "state: $(state)"
complete_absent "failed install"
echo '{"k":1}' > "$LIVE/settings.json"
pull_ok
[[ "$(jv "$LIVE/settings.json" .k)" == 1 && "$(jv "$LIVE/settings.json" .model)" == '"m1"' ]] || fail "retry"
pass "first install failure retried"

info "A file new to an installed app is a first install for that file"
fresh_installed
mkdir -p "$RT/files"
printf 'n1\n' > "$RT/files/n.conf"
sed -i 's#^backup:#  - src: n.conf\n    dest: ~/rt/n.conf\n    mode: '"'"'0644'"'"'\n\nbackup:#' "$RT/config.yaml"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "new file"
echo precious > "$LIVE/n.conf"
pull_ok
content "$LIVE/n.conf" n1
content "$HOME/.bak/rt/original/n.conf" precious
snapshot_with n.conf precious
content "$R/repo/n.conf" n1
pass "new file: original and snapshot"

info "Records lost on an installed app: an edit still gets a snapshot before it's replaced"
fresh_installed
echo mine > "$LIVE/a.conf"
rm -rf "$STATE_DIR/records" "$COMPLETE"
pull_ok
content "$LIVE/a.conf" a1
snapshot_with a.conf mine
content "$R/repo/a.conf" a1
[[ -f "$R/repo/settings.json" ]] || fail "records not rebuilt"
# One file's copy gone: only that file starts over
echo mine-b > "$LIVE/b.conf"
echo mine > "$LIVE/c.sh"
rm "$R/repo/b.conf" "$COMPLETE"
pull_ok
content "$LIVE/b.conf" b1
snapshot_with b.conf mine-b
content "$LIVE/c.sh" mine
content "$R/repo/b.conf" b1
pass "lost records"

info "State lost, records kept: an edit is still protected"
fresh_installed
echo mine > "$LIVE/a.conf"
rm -rf "$STATE_DIR/apps" "$COMPLETE"
repo_set a.conf a2
pull_ok
content "$LIVE/a.conf" mine
has "kept your edit"
[[ -e "$HOME/.bak/rt/original/a.conf" ]] && [[ "$(cat "$HOME/.bak/rt/original/a.conf")" != mine ]] && fail "bad original"
[[ ! -e "$HOME/.bak/rt/original/b.conf" ]] || fail "a deployed file saved as an original"
pass "state lost"

# --- Live file forms -----------------------------------------------------------

info "A live symlink stays a symlink, replaced and merged, on update, first install and --force"
fresh_installed
mkdir -p "$HOME/elsewhere"
mv "$LIVE/a.conf" "$HOME/elsewhere/a"
ln -s "$HOME/elsewhere/a" "$LIVE/a.conf"
mv "$LIVE/settings.json" "$HOME/elsewhere/s"
ln -s "$HOME/elsewhere/s" "$LIVE/settings.json"
repo_set a.conf a2 settings.json "$(settings '{"model":"m2"}')"
pull_ok
[[ -L "$LIVE/a.conf" && -L "$LIVE/settings.json" ]] || fail "link replaced by a file"
content "$HOME/elsewhere/a" a2
[[ "$(jv "$HOME/elsewhere/s" .model)" == '"m2"' ]] || fail "merged not written through"
echo mine > "$LIVE/a.conf"
jq '.model = "mine"' "$LIVE/settings.json" > "$T/s" && cat "$T/s" > "$LIVE/settings.json"
pull_ok --force
[[ -L "$LIVE/a.conf" && -L "$LIVE/settings.json" ]] || fail "link replaced under --force"
content "$HOME/elsewhere/a" a2
[[ "$(jv "$HOME/elsewhere/s" .model)" == '"m2"' ]] || fail "force not written through"
snapshot_with a.conf mine
[[ ! -L "$HOME/.bak/rt/original/a.conf" ]] || fail "snapshot is a link"
# A dangling link is written through as well
rm "$HOME/elsewhere/a"
repo_set a.conf a3
pull_ok
[[ -L "$LIVE/a.conf" ]] || fail "dangling link replaced"
content "$HOME/elsewhere/a" a3
# First install
fresh
mkdir -p "$LIVE" "$HOME/elsewhere"
echo old > "$HOME/elsewhere/a"
ln -s "$HOME/elsewhere/a" "$LIVE/a.conf"
echo '{"k":1}' > "$HOME/elsewhere/s"
ln -s "$HOME/elsewhere/s" "$LIVE/settings.json"
pull_ok
[[ -L "$LIVE/a.conf" && -L "$LIVE/settings.json" ]] || fail "link replaced on first install"
content "$HOME/elsewhere/a" a1
[[ "$(jv "$HOME/elsewhere/s" .k)" == 1 && "$(jv "$HOME/elsewhere/s" .model)" == '"m1"' ]] || fail "first install not written through"
content "$HOME/.bak/rt/original/a.conf" old
pass "symlinks written through"

info "A src with a space deploys, follows the repo and conflicts"
fresh_installed
content "$LIVE/my file.conf" s1
content "$R/repo/my file.conf" s1
grep -qF "$(printf 'my file.conf\t%s\treplace' "$LIVE/my file.conf")" "$R/manifest.tsv" || fail "manifest"
repo_set "my file.conf" s2
pull_ok
content "$LIVE/my file.conf" s2
echo mine > "$LIVE/my file.conf"
repo_set "my file.conf" s3
pull_ok
content "$LIVE/my file.conf" mine
has "kept your edit to $LIVE/my file.conf"
[[ "$(cat "$STATE_DIR/apps/rt.yaml")" == *"$LIVE/my file.conf"* ]] || fail "state file"
pass "space in src"

info "Modes: new, updated and a mode change in the repo; kept edits and conflicts left alone"
fresh_installed
[[ "$(mode_of "$LIVE/other.json")" == 600 ]] || fail "merged mode"
chmod 0600 "$LIVE/a.conf"
repo_set a.conf a2
pull_ok
[[ "$(mode_of "$LIVE/a.conf")" == 644 ]] || fail "mode not set on update: $(mode_of "$LIVE/a.conf")"
sed -i '/src: b.conf/,/mode:/s/0644/0640/' "$RT/config.yaml"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m mode
pull_ok
[[ "$(mode_of "$LIVE/b.conf")" == 640 ]] || fail "repo's mode change not followed: $(mode_of "$LIVE/b.conf")"
content "$LIVE/b.conf" b1
chmod 0600 "$LIVE/c.sh"
echo mine > "$LIVE/c.sh"
repo_set c.sh c2
pull_ok
[[ "$(mode_of "$LIVE/c.sh")" == 600 ]] || fail "conflict's mode changed"
pass "modes"

# --- Strategy switches, removals, deletions ------------------------------------

info "Switching replace to merge snapshots, then a fresh merge keeps the live keys"
fresh_installed
printf '{"f":1}\n' > "$RT/files/sw.json"
sed -i 's#^backup:#  - src: sw.json\n    dest: ~/rt/sw.json\n    mode: '"'"'0644'"'"'\n\nbackup:#' "$RT/config.yaml"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m sw
pull_ok
echo '{"f":1,"mine":2}' > "$LIVE/sw.json"
sed -i '/dest: ~\/rt\/sw.json/a\    strategy: merge' "$RT/config.yaml"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "to merge"
pull_ok
[[ "$(jv "$LIVE/sw.json" .mine)" == 2 && "$(jv "$LIVE/sw.json" .f)" == 1 ]] || fail "fresh merge: $(cat "$LIVE/sw.json")"
snapshot_with sw.json mine
grep -qF "$(printf 'sw.json\t%s\tmerge' "$LIVE/sw.json")" "$R/manifest.tsv" || fail "manifest strategy"
json "$R/review/sw.json" '{"f":1,"mine":2}'
[[ -z "$(items sw.json "$LIVE/sw.json")" ]] || fail "flagged after a fresh deploy"
info "Switching merge to replace snapshots, then a fresh deploy replaces the file"
rm -rf "$HOME/.bak"
sed -i '/dest: ~\/rt\/sw.json/{n;/strategy: merge/d}' "$RT/config.yaml"
if grep -A3 'src: sw.json' "$RT/config.yaml" | grep -q strategy; then fail "fixture: strategy not removed"; fi
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "to replace"
pull_ok
json "$LIVE/sw.json" '{"f":1}'
snapshot_with sw.json mine
grep -qF "$(printf 'sw.json\t%s\treplace' "$LIVE/sw.json")" "$R/manifest.tsv" || fail "manifest strategy"
pass "strategy switches"

info "A switch to merge over invalid JSON fails that file and retries as a switch"
fresh_installed
printf '{"f":1}\n' > "$RT/files/sw.json"
sed -i 's#^backup:#  - src: sw.json\n    dest: ~/rt/sw.json\n    mode: '"'"'0644'"'"'\n\nbackup:#' "$RT/config.yaml"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m sw
pull_ok
echo 'not json' > "$LIVE/sw.json"
sed -i '/dest: ~\/rt\/sw.json/a\    strategy: merge' "$RT/config.yaml"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "to merge"
pull
[[ $RC -eq 1 ]] || fail "expected failure: $OUT"
content "$LIVE/sw.json" 'not json'
grep -qF "$(printf 'sw.json\t%s\treplace' "$LIVE/sw.json")" "$R/manifest.tsv" || fail "record moved"
echo '{"mine":1}' > "$LIVE/sw.json"
pull_ok
[[ "$(jv "$LIVE/sw.json" .mine)" == 1 && "$(jv "$LIVE/sw.json" .f)" == 1 ]] || fail "retry"
pass "failed switch retried"

info "A file removed from the repo stays, no longer tracked, warned about if edited"
fresh_installed
echo mine > "$LIVE/a.conf"
sed -i '/src: a.conf/,/mode:/d;/src: b.conf/,/mode:/d' "$RT/config.yaml"
git -C "$REPO" rm -q -r --cached apps/rt/files/a.conf apps/rt/files/b.conf
rm "$RT/files/a.conf" "$RT/files/b.conf"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "drop files"
pull_ok
content "$LIVE/a.conf" mine
content "$LIVE/b.conf" b1
has "$LIVE/a.conf" "no warning for the edited file"
has "unreviewed edits" "no warning for the edited file"
if grep -q "unreviewed edits.*b.conf\|b.conf.*unreviewed edits" <<<"$OUT"; then fail "warned about an unedited file: $OUT"; fi
if grep -q '^a.conf' "$R/manifest.tsv"; then fail "still tracked"; fi
[[ ! -e "$R/repo/a.conf" && ! -e "$R/review/a.conf" ]] || fail "copies left"
complete_written "removed"
repo_unrelated
pull_ok
hasnt "unreviewed edits" "warned twice about a file no longer tracked"
pass "removed replaced file"

info "A merged file removed from the repo stays, warned about if a key was edited"
fresh_installed
jq '.theme = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
cp "$LIVE/settings.json" "$T/edited"
sed -i '/src: settings.json/,/strategy:/d;/src: other.json/,/strategy:/d' "$RT/config.yaml"
git -C "$REPO" rm -q --cached apps/rt/files/settings.json apps/rt/files/other.json
rm "$RT/files/settings.json" "$RT/files/other.json"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "drop merged"
pull_ok
same "$LIVE/settings.json" "$T/edited"
has "unreviewed edits"
[[ "$OUT" == *"$LIVE/settings.json"* ]] || fail "not named: $OUT"
if grep -q 'unreviewed edits.*other.json' <<<"$OUT"; then fail "warned about an unedited file: $OUT"; fi
[[ -f "$LIVE/other.json" ]] || fail "removed from disk"
pass "removed merged file"

info "A dest moved in config deploys fresh at the new place; the old file stays and is warned about"
fresh_installed
echo mine > "$LIVE/a.conf"
echo precious > "$LIVE/a-moved.conf"
sed -i 's#dest: ~/rt/a.conf#dest: ~/rt/a-moved.conf#' "$RT/config.yaml"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m move
pull_ok
content "$LIVE/a.conf" mine
content "$LIVE/a-moved.conf" a1
snapshot_with a-moved.conf precious
content "$HOME/.bak/rt/original/a-moved.conf" precious
has "unreviewed edits"
grep -qF "$(printf 'a.conf\t%s\treplace' "$LIVE/a-moved.conf")" "$R/manifest.tsv" || fail "manifest"
pass "moved dest"

info "A deleted live file comes back with the next full deploy, replaced and merged"
fresh_installed
jq '.localOnly = 1' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
rm "$LIVE/a.conf" "$LIVE/settings.json"
repo_set settings.json "$(settings '{"model":"m2"}')"
pull_ok
content "$LIVE/a.conf" a1
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "merged content"
[[ "$(jv "$LIVE/settings.json" 'has("localOnly")')" == false ]] || fail "local-only key came back"
json "$R/repo/settings.json" "$(cat "$RT/files/settings.json")"
hasnt "kept your edit"
# With no repo change at all the app-level check still restores it, once the early stop is past
rm "$LIVE/b.conf"
rm -f "$COMPLETE"
pull_ok
content "$LIVE/b.conf" b1
# An empty merged file counts as deleted
: > "$LIVE/settings.json"
pull_ok --force
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "empty live file"
pass "deleted files return"

# --- Failures ------------------------------------------------------------------

info "Invalid live JSON fails only that file, leaves it untouched, retried next pull"
fresh_installed
echo '{oops' > "$LIVE/settings.json"
repo_set a.conf a2 settings.json "$(settings '{"model":"m2"}')" other.json '{"o":2}'
for run in 1 2; do
    pull
    [[ $RC -eq 1 ]] || fail "run $run: expected failure: $OUT"
    content "$LIVE/settings.json" '{oops' "run $run"
    content "$LIVE/a.conf" a2 "run $run"
    json "$LIVE/other.json" '{"o":2}'
    [[ "$(jv "$R/repo/settings.json" .model)" == '"m1"' ]] || fail "run $run: records advanced"
    [[ "$(state)" == incomplete ]] || fail "run $run: state $(state)"
    complete_absent "invalid run $run"
done
echo "$BASE_SETTINGS" > "$LIVE/settings.json"
pull_ok
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "not retried"
[[ "$(state)" != incomplete ]] || fail "state"
complete_written "retried"
pass "invalid live JSON"

info "Invalid layer JSON fails only that file, retried once fixed"
fresh_installed
jq '.theme = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
cp "$LIVE/settings.json" "$T/edited"
repo_set a.conf a2 settings.json '{broken'
pull
[[ $RC -eq 1 ]] || fail "expected failure: $OUT"
same "$LIVE/settings.json" "$T/edited"
content "$LIVE/a.conf" a2
[[ "$(jv "$R/repo/settings.json" .model)" == '"m1"' ]] || fail "records advanced"
complete_absent "bad layer"
repo_set settings.json "$(settings '{"model":"m2"}')"
pull_ok
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' && "$(jv "$LIVE/settings.json" .theme)" == '"mine"' ]] || fail "retry"
pass "invalid layer JSON"

info "A failed write doesn't advance that file's records; the others proceed; retried"
if [[ "$(id -u)" == 0 ]]; then
    info "skipped as root: permissions don't stop root"
else
fresh_installed
chmod 0444 "$LIVE/a.conf"
chmod 0444 "$LIVE/settings.json"
repo_set a.conf a2 b.conf b2 settings.json "$(settings '{"model":"m2"}')" other.json '{"o":2}'
for run in 1 2; do
    pull
    [[ $RC -eq 1 ]] || fail "run $run: expected failure: $OUT"
    content "$LIVE/a.conf" a1 "run $run"
    content "$R/repo/a.conf" a1 "run $run"
    content "$R/review/a.conf" a1 "run $run"
    [[ "$(jv "$LIVE/settings.json" .model)" == '"m1"' ]] || fail "run $run: merged written"
    [[ "$(jv "$R/repo/settings.json" .model)" == '"m1"' ]] || fail "run $run: merged record advanced"
    [[ "$(jv "$R/review/settings.json" .model)" == '"m1"' ]] || fail "run $run: merged review advanced"
    content "$LIVE/b.conf" b2 "run $run"
    content "$R/repo/b.conf" b2 "run $run"
    json "$LIVE/other.json" '{"o":2}'
    json "$R/repo/other.json" '{"o":2}'
    [[ "$(state)" == incomplete ]] || fail "run $run: state $(state)"
    complete_absent "failed write run $run"
    has "rt/a.conf" "run $run: not named"
done
chmod 0644 "$LIVE/a.conf" "$LIVE/settings.json"
pull_ok
content "$LIVE/a.conf" a2
content "$R/repo/a.conf" a2
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "merged retry"
complete_written "after retry"
pass "failed write isolated and retried"
fi

info "A live path that isn't a regular file fails, whatever the decision"
fresh_installed
rm "$LIVE/a.conf"
mkdir "$LIVE/a.conf"
repo_set b.conf b2
pull
[[ $RC -eq 1 ]] || fail "expected failure: $OUT"
[[ -d "$LIVE/a.conf" ]] || fail "directory replaced"
content "$LIVE/b.conf" b2
rmdir "$LIVE/a.conf"
pull_ok
content "$LIVE/a.conf" a1
pass "directory at dest"

info "Records that can't be written fail the file, and the next pull settles it"
if [[ "$(id -u)" == 0 ]]; then
    info "skipped as root: permissions don't stop root"
else
fresh_installed
repo_set a.conf a2 settings.json "$(settings '{"model":"m2"}')"
chmod 0500 "$R/repo"
pull
chmod 0700 "$R/repo"
[[ $RC -eq 1 ]] || fail "expected failure: $OUT"
content "$LIVE/a.conf" a2
complete_absent "no records"
content "$R/repo/a.conf" a1
pull_ok
content "$LIVE/a.conf" a2
content "$R/repo/a.conf" a2
content "$R/review/a.conf" a2
[[ "$(jv "$R/repo/settings.json" .model)" == '"m2"' ]] || fail "merged records"
[[ "$(jv "$R/review/settings.json" .model)" == '"m2"' ]] || fail "merged review"
hasnt "kept your edit"
complete_written "settled"
pass "lost record write recovers"
fi

# --- Killed runs ---------------------------------------------------------------

# A run killed after the live writes and before any record: put the records and state
# back as they were before the run.
info "A run killed before any record is written recovers, keeping an edit elsewhere"
fresh_installed
echo mine > "$LIVE/b.conf"
jq '.localOnly = 1' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
repo_set a.conf a2 settings.json "$(settings '{"model":"m2"}')"
rm -rf "$T/before"
mkdir "$T/before"
cp -Rp "$STATE_DIR/records" "$STATE_DIR/apps" "$T/before/"
pull_ok
rm -rf "$STATE_DIR/records" "$STATE_DIR/apps"
cp -Rp "$T/before/records" "$T/before/apps" "$STATE_DIR/"
rm -f "$COMPLETE"
pull_ok
content "$LIVE/a.conf" a2
content "$R/repo/a.conf" a2
content "$R/review/a.conf" a2
content "$LIVE/b.conf" mine
content "$R/repo/b.conf" b1
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' && "$(jv "$LIVE/settings.json" .localOnly)" == 1 ]] || fail "merged"
[[ "$(jv "$R/repo/settings.json" .model)" == '"m2"' && "$(jv "$R/review/settings.json" .model)" == '"m2"' ]] || fail "merged records"
[[ "$(jv "$R/review/settings.json" .localOnly)" == null ]] || fail "unreviewed key marked reviewed"
hasnt "kept your edit"
complete_written "recovered"
pass "killed before records"

info "A run killed partway: one file's records written, the next not, the state not yet"
fresh_installed
repo_set a.conf a2 b.conf b2
rm -rf "$T/before"
mkdir "$T/before"
cp -Rp "$STATE_DIR/apps" "$T/before/"
cp "$R/review/b.conf" "$T/before/review-b"
cp "$R/repo/b.conf" "$T/before/repo-b"
pull_ok
# a.conf finished; b.conf was written but its record wasn't; the state is the old one
cp -p "$T/before/repo-b" "$R/repo/b.conf"
cp -p "$T/before/review-b" "$R/review/b.conf"
rm -rf "$STATE_DIR/apps"
cp -Rp "$T/before/apps" "$STATE_DIR/"
rm -f "$COMPLETE"
pull_ok
content "$LIVE/a.conf" a2
content "$LIVE/b.conf" b2
content "$R/repo/b.conf" b2
content "$R/review/b.conf" b2
hasnt "kept your edit"
complete_written "partial"
pass "killed partway"

info "A first install killed partway: no state, some records; a deployed file isn't an original"
fresh_installed
rm -rf "$STATE_DIR/apps" "$COMPLETE" "$HOME/.bak"
rm "$LIVE/b.conf"
rm -f "$R/repo/b.conf" "$R/review/b.conf"
sed -i '/^b.conf/d' "$R/manifest.tsv"
pull_ok
content "$LIVE/b.conf" b1
content "$R/repo/b.conf" b1
[[ ! -e "$HOME/.bak/rt/original/a.conf" ]] || fail "a file dotfiles wrote was saved as an original"
[[ -f "$STATE_DIR/apps/rt.yaml" ]] || fail "no state"
complete_written "first install recovered"
pass "first install killed"

info "A temp file left by a dead run doesn't confuse anything; none left by a normal one"
fresh_installed
repo_set a.conf a2 settings.json "$(settings '{"model":"m2"}')"
pull_ok
[[ -z "$(find "$LIVE" -name '.*' -type f)" ]] || fail "temp files beside the live files: $(find "$LIVE" -name '.*')"
[[ -z "$(find "$STATE_DIR/records" -name '*.tmp*')" ]] || fail "temp files in the records"
pass "no temp files"

# --- Profile and host ----------------------------------------------------------

info "Changing profile or host counts as a repo change"
fresh
HOSTS="$T/hosts$N"
mkdir -p "$HOSTS/profiles/rtb/apps/rt/files" "$HOSTS/hosts/h2/apps/rt/files"
printf 'extends: rt\n' > "$HOSTS/profiles/rtb.yaml"
printf 'a-rtb\n' > "$HOSTS/profiles/rtb/apps/rt/files/a.conf"
printf 'b-rtb\n' > "$HOSTS/profiles/rtb/apps/rt/files/b.conf"
printf '{"model":"m-rtb"}\n' > "$HOSTS/profiles/rtb/apps/rt/files/settings.json"
printf 'profile: rt\n' > "$HOSTS/hosts/h2/host.yaml"
printf 'b-h2\n' > "$HOSTS/hosts/h2/apps/rt/files/b.conf"
git -C "$HOSTS" init -q
git -C "$HOSTS" add -A
git -C "$HOSTS" commit -q -m hosts
pull_ok --hosts-dir "$HOSTS"
content "$LIVE/a.conf" a1
# Untouched a.conf and b.conf follow; an edited key conflicts, another applies
echo mine > "$LIVE/b.conf"
jq '.model = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
pull_ok --hosts-dir "$HOSTS" --profile rtb
content "$LIVE/a.conf" a-rtb
content "$R/repo/a.conf" a-rtb
content "$LIVE/b.conf" mine
has "kept your edit to $LIVE/b.conf"
has "kept your edit to $LIVE/settings.json"
[[ "$(jv "$LIVE/settings.json" .model)" == '"mine"' ]] || fail "merged conflict overwritten"
# Back again: b.conf's conflict ends, since the repo is back at the last accepted version
pull_ok --hosts-dir "$HOSTS" --profile rt
content "$LIVE/a.conf" a1
content "$LIVE/b.conf" mine
hasnt "kept your edit"
# A host layer: the edit conflicts, and setting it back follows the host
pull_ok --hosts-dir "$HOSTS" --hostname h2
content "$LIVE/b.conf" mine
has "kept your edit to $LIVE/b.conf"
echo b1 > "$LIVE/b.conf"
pull_ok --hosts-dir "$HOSTS" --hostname h2
content "$LIVE/b.conf" b-h2
content "$R/repo/b.conf" b-h2
pass "profile and host"

# --- Renamed sources and files moving between apps ------------------------------

# Rename a file of the app in the repo and in config.yaml, keeping its dest; commit.
# Usage: repo_rename OLD NEW
repo_rename() {
    git -C "$REPO" mv "apps/rt/files/$1" "apps/rt/files/$2"
    sed -i "s#src: $1\$#src: $2#" "$RT/config.yaml"
    git -C "$REPO" add -A apps/rt
    git -C "$REPO" commit -q -m "rename $1"
}
# How many pulls in a row report exactly N edited files, to catch a phantom
edits_line() {
    if [[ "$1" == 0 ]]; then hasnt "file(s) have local edits"; else has "$1 file(s) have local edits"; fi
}

info "Renaming a src, same dest: an edit stays, flagged; no stale record or phantom edit"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_rename a.conf a2.conf
pull_ok
content "$LIVE/a.conf" mine
content "$R/repo/a2.conf" a1
content "$R/review/a2.conf" a1
[[ ! -e "$R/repo/a.conf" && ! -e "$R/review/a.conf" ]] || fail "old copies left"
[[ "$(grep -cF "$LIVE/a.conf" "$R/manifest.tsv")" == 1 ]] || fail "manifest: $(cat "$R/manifest.tsv")"
grep -qF "$(printf 'a2.conf\t%s\treplace' "$LIVE/a.conf")" "$R/manifest.tsv" || fail "manifest: $(cat "$R/manifest.tsv")"
edits_line 1
hasnt "kept your edit"
hasnt "unreviewed edits"
flagged_src() { [[ "$(items "$1" "$2")" == *edited* ]] || fail "$1: not flagged: $(items "$1" "$2")"; }
flagged_src a2.conf "$LIVE/a.conf"
RC=0
OUT=$("$REPO/dotfiles" status 2>&1) || RC=$?
has "$(printf '~/rt/a.conf')" "status doesn't list the edit"
# The repo then changes it: a conflict, and a hand revert applies it
repo_set a2.conf a3
pull_ok
content "$LIVE/a.conf" mine
has "kept your edit to $LIVE/a.conf"
echo a1 > "$LIVE/a.conf"
pull_ok
content "$LIVE/a.conf" a3
hasnt "kept your edit"
edits_line 0
repo_unrelated
pull_ok
edits_line 0
pass "rename keeps the edit"

info "Renaming a src along with a repo change over an edit is a conflict; untouched follows"
fresh_installed
echo mine > "$LIVE/a.conf"
git -C "$REPO" mv apps/rt/files/a.conf apps/rt/files/a2.conf
git -C "$REPO" mv apps/rt/files/b.conf apps/rt/files/b2.conf
sed -i 's#src: a.conf$#src: a2.conf#;s#src: b.conf$#src: b2.conf#' "$RT/config.yaml"
printf 'a2\n' > "$RT/files/a2.conf"
printf 'b2\n' > "$RT/files/b2.conf"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "rename and change"
pull_ok
content "$LIVE/a.conf" mine
content "$R/repo/a2.conf" a1
has "kept your edit to $LIVE/a.conf"
content "$LIVE/b.conf" b2
content "$R/repo/b2.conf" b2
complete_absent "rename conflict"
pass "rename with a change"

info "Renaming a merged src: per-key rules go on, local-only keys stay"
fresh_installed
jq '.theme = "mine" | .localOnly = 1' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
git -C "$REPO" mv apps/rt/files/settings.json apps/rt/files/settings2.json
sed -i 's#src: settings.json$#src: settings2.json#' "$RT/config.yaml"
settings '{"model":"m2"}' > "$RT/files/settings2.json"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "rename merged"
pull_ok
[[ "$(jv "$LIVE/settings.json" .theme)" == '"mine"' && "$(jv "$LIVE/settings.json" .localOnly)" == 1 ]] || fail "edit lost"
[[ "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "repo change not applied"
[[ "$(jv "$R/repo/settings2.json" .model)" == '"m2"' ]] || fail "records"
[[ "$(jv "$R/review/settings2.json" .theme)" == '"t1"' ]] || fail "review took the edit"
[[ ! -e "$R/repo/settings.json" ]] || fail "old copy left"
edits_line 1
pass "rename of a merged file"

info "A rename whose deploy fails keeps the old base for the retry"
fresh_installed
jq '.theme = "mine"' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
git -C "$REPO" mv apps/rt/files/settings.json apps/rt/files/settings2.json
sed -i 's#src: settings.json$#src: settings2.json#' "$RT/config.yaml"
printf '{broken\n' > "$RT/files/settings2.json"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "rename, bad layer"
pull
[[ $RC -eq 1 ]] || fail "expected failure: $OUT"
[[ "$(jv "$LIVE/settings.json" .theme)" == '"mine"' ]] || fail "live touched"
[[ -e "$R/repo/settings.json" ]] || fail "the only base was pruned"
settings '{"model":"m2"}' > "$RT/files/settings2.json"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "fixed"
pull_ok
[[ "$(jv "$LIVE/settings.json" .theme)" == '"mine"' && "$(jv "$LIVE/settings.json" .model)" == '"m2"' ]] || fail "retry"
[[ ! -e "$R/repo/settings.json" ]] || fail "old copy left"
pass "failed rename retried"

info "A rename with a strategy switch starts over, with a snapshot, and leaves no stale record"
fresh_installed
echo '{"mine":1}' > "$LIVE/a.conf"
git -C "$REPO" mv apps/rt/files/a.conf apps/rt/files/a2.json
sed -i 's#src: a.conf$#src: a2.json#' "$RT/config.yaml"
sed -i '/dest: ~\/rt\/a.conf/a\    strategy: merge' "$RT/config.yaml"
printf '{"a":1}\n' > "$RT/files/a2.json"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "rename and switch"
pull_ok
json "$LIVE/a.conf" '{"mine":1,"a":1}'
snapshot_with a.conf mine
[[ "$(grep -cF "$LIVE/a.conf" "$R/manifest.tsv")" == 1 ]] || fail "manifest: $(cat "$R/manifest.tsv")"
[[ ! -e "$R/repo/a.conf" ]] || fail "old copy left"
pass "rename and switch"

# Move a file between the test apps, keeping its dest; commit.
# Usage: repo_move FROM_DIR TO_DIR SRC DEST [STRATEGY]
repo_move() {
    local from="$1" to="$2" src="$3" dest="$4" strategy="${5:-}" entry
    git -C "$REPO" mv "apps/$from/files/$src" "apps/$to/files/$src"
    if [[ -n "$strategy" ]]; then
        sed -i "/src: $src\$/,/strategy:/d" "$REPO/apps/$from/config.yaml"
    else
        sed -i "/src: $src\$/,/mode:/d" "$REPO/apps/$from/config.yaml"
    fi
    entry="  - src: $src\n    dest: $dest\n    mode: '0644'"
    [[ -z "$strategy" ]] || entry+="\n    strategy: $strategy"
    sed -i "s#^backup:#$entry\n\nbackup:#" "$REPO/apps/$to/config.yaml"
    git -C "$REPO" add -A "apps/$from" "apps/$to"
    git -C "$REPO" commit -q -m "move $src"
}
R2() { echo "$STATE_DIR/records/rt2"; }

info "A dest moved to an app that runs later: the edit stays, flagged, with no phantom edit"
fresh_installed
echo mine > "$LIVE/b.conf"
repo_move rt rt2 b.conf '~/rt/b.conf'
pull_ok
content "$LIVE/b.conf" mine
content "$(R2)/repo/b.conf" b1
content "$(R2)/review/b.conf" b1
if grep -qF "$LIVE/b.conf" "$R/manifest.tsv"; then fail "old app still tracks it"; fi
grep -qF "$LIVE/b.conf" "$(R2)/manifest.tsv" || fail "new app doesn't track it"
edits_line 1
[[ ! -e "$HOME/.bak/rt2/original/b.conf" ]] || fail "a file dotfiles wrote was saved as an original"
repo_unrelated
pull_ok
content "$LIVE/b.conf" mine
edits_line 1
hasnt "unreviewed edits" "warned again"
printf 'b2\n' > "$RT2/files/b.conf"
git -C "$REPO" add -A apps/rt2
git -C "$REPO" commit -q -m "b2"
pull_ok
content "$LIVE/b.conf" mine
has "kept your edit to $LIVE/b.conf"
echo b1 > "$LIVE/b.conf"
pull_ok
content "$LIVE/b.conf" b2
edits_line 0
[[ -z "$(find "$STATE_DIR/records/.released" -type f 2>/dev/null)" ]] || fail "released copies left"
pass "moved to a later app"

info "A dest moved to an app that runs earlier: the same"
fresh_installed
echo mine > "$LIVE/z.conf"
repo_move rt2 rt z.conf '~/rt/z.conf'
pull_ok
content "$LIVE/z.conf" mine
content "$R/repo/z.conf" z1
if grep -qF "$LIVE/z.conf" "$(R2)/manifest.tsv"; then fail "old app still tracks it"; fi
edits_line 1
hasnt "unreviewed edits" "old app warned about a file the new app holds"
repo_set z.conf z2
pull_ok
content "$LIVE/z.conf" mine
has "kept your edit to $LIVE/z.conf"
pass "moved to an earlier app"

info "A merged dest moved between apps keeps its per-key rules"
fresh_installed
jq '.z = 9 | .localOnly = 1' "$LIVE/z.json" > "$T/s" && cp "$T/s" "$LIVE/z.json"
repo_move rt2 rt z.json '~/rt/z.json' merge
pull_ok
[[ "$(jv "$LIVE/z.json" .z)" == 9 && "$(jv "$LIVE/z.json" .localOnly)" == 1 ]] || fail "edit lost: $(cat "$LIVE/z.json")"
[[ "$(jv "$R/repo/z.json" .z)" == 1 ]] || fail "repo copy"
edits_line 1
repo_set z.json '{"z":2,"y":2}'
pull_ok
[[ "$(jv "$LIVE/z.json" .z)" == 9 ]] || fail "conflict overwritten"
[[ "$(jv "$LIVE/z.json" .y)" == 2 ]] || fail "other key not applied"
has "kept your edit to $LIVE/z.json"
pass "merged file moved between apps"

info "A file dropped, then added back later: an edit made meanwhile isn't overwritten"
fresh_installed
GOOD_CONFIG="$RT/config.yaml"
cp "$GOOD_CONFIG" "$T/config-before"
echo mine > "$LIVE/a.conf"
sed -i '/src: a.conf/,/mode:/d' "$GOOD_CONFIG"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m drop
pull_ok
content "$LIVE/a.conf" mine
cp "$T/config-before" "$GOOD_CONFIG"
git -C "$REPO" add -A apps/rt
git -C "$REPO" commit -q -m "add back"
pull_ok
content "$LIVE/a.conf" mine
content "$R/repo/a.conf" a1
edits_line 1
pass "added back"

# --- --force PATH touches that file and nothing else -------------------------------

# Everything a run could change outside the repo, with modification times
fingerprint() {
    find "$HOME" "$STATE_DIR" "$XDG_STATE_HOME" -printf '%p %y %T@\n' 2>/dev/null | sort
}

info "--force PATH runs no package phase, no self-install, and keeps the pending list"
fresh
NOSUDO="$T/nosudo"
mkdir -p "$NOSUDO"
printf '#!/bin/sh\nexit 1\n' > "$NOSUDO/sudo"
chmod +x "$NOSUDO/sudo"
export DOTFILES_TEST_MARKER="$T/marker$N"
PATH="$NOSUDO:$PATH" pull --profile rtpkg
[[ -e "$DOTFILES_TEST_MARKER" ]] || fail "fixture: the package phase should run: $OUT"
grep -qx faketool "$XDG_STATE_HOME/dotfiles/pending" || fail "fixture: faketool should be pending"
rm -f "$DOTFILES_TEST_MARKER" "$HOME/.local/bin/dotfiles" "$HOME/.bashrc.d/90-dotfiles.sh"
echo mine > "$LIVE/a.conf"
PATH="$NOSUDO:$PATH" pull --profile rtpkg --force "$LIVE/a.conf"
[[ $RC -eq 0 ]] || fail "failed: $OUT"
content "$LIVE/a.conf" a1
hasnt "Phase 1"
hasnt "Phase 2"
[[ ! -e "$DOTFILES_TEST_MARKER" ]] || fail "a custom install ran"
[[ ! -e "$HOME/.local/bin/dotfiles" && ! -e "$HOME/.bashrc.d/90-dotfiles.sh" ]] || fail "self-install ran"
grep -qx faketool "$XDG_STATE_HOME/dotfiles/pending" || fail "pending list lost"
unset DOTFILES_TEST_MARKER
pass "--force PATH leaves packages alone"

info "An unmanaged --force PATH changes nothing at all"
fresh_installed
rm -f "$HOME/.bashrc.d/90-dotfiles.sh" "$HOME/.local/bin/dotfiles"
echo x > "$HOME/unmanaged"
fingerprint > "$T/fp-before"
sleep 1
pull --force "$HOME/unmanaged"
[[ $RC -eq 1 ]] || fail "expected exit 1: $OUT"
has "not managed"
hasnt "Phase"
fingerprint > "$T/fp-after"
cmp -s "$T/fp-before" "$T/fp-after" || fail "something changed: $(diff "$T/fp-before" "$T/fp-after")"
complete_written "unmanaged PATH"
pass "unmanaged PATH: nothing changed"

# --- Reset, uninstall, old records, dry run ------------------------------------

info "DOTFILES_RESET=1: every file becomes the repo's exactly, with a snapshot and fresh records"
fresh_installed
echo mine > "$LIVE/a.conf"
jq '.model = "mine" | .localOnly = 1' "$LIVE/settings.json" > "$T/s" && cp "$T/s" "$LIVE/settings.json"
echo '{oops' > "$LIVE/other.json"
DOTFILES_RESET=1 pull_ok
content "$LIVE/a.conf" a1
json "$LIVE/settings.json" "$(cat "$RT/files/settings.json")"
json "$LIVE/other.json" "$(cat "$RT/files/other.json")"
json "$R/repo/settings.json" "$(cat "$RT/files/settings.json")"
json "$R/review/settings.json" "$(cat "$RT/files/settings.json")"
snapshot_with a.conf mine
snapshot_with settings.json localOnly
snapshot_with other.json oops
[[ "$(state)" != conflict && "$(state)" != incomplete ]] || fail "state: $(state)"
complete_written "reset"
pass "reset"

info "uninstall removes the records; the next pull is a first install"
fresh_installed
[[ -d "$R" ]] || fail "records missing"
RC=0
OUT=$("$REPO/dotfiles" uninstall --no-backup 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "uninstall failed: $OUT"
[[ ! -d "$R" ]] || fail "records left"
[[ ! -e "$LIVE/a.conf" ]] || fail "file left"
pull_ok
content "$LIVE/a.conf" a1
content "$R/repo/a.conf" a1
pass "uninstall"

info "pull refuses old-format records and points at init"
fresh_installed
mkdir -p "$STATE_DIR/deployed"
printf 'hash\ta.conf\t%s\n' "$LIVE/a.conf" > "$STATE_DIR/deployed/rt.tsv"
rm -f "$COMPLETE"
repo_set a.conf a2
pull
[[ $RC -eq 1 ]] || fail "expected exit 1: $OUT"
has "dotfiles init"
content "$LIVE/a.conf" a1
pull --dry-run
[[ $RC -eq 1 ]] || fail "dry run: expected exit 1: $OUT"
pull --force
[[ $RC -eq 1 ]] || fail "--force: expected exit 1: $OUT"
content "$LIVE/a.conf" a1
rm "$STATE_DIR/deployed/rt.tsv"
pull_ok
content "$LIVE/a.conf" a2
pass "old records refused"

info "A dry run changes neither live files nor records"
fresh_installed
echo mine > "$LIVE/a.conf"
repo_set a.conf a2 b.conf b2
find "$STATE_DIR" -type f -exec cksum {} + | sort > "$T/state-before"
pull_ok --dry-run
find "$STATE_DIR" -type f -exec cksum {} + | sort > "$T/state-after"
cmp -s "$T/state-before" "$T/state-after" || fail "dry run changed the state: $(diff "$T/state-before" "$T/state-after")"
content "$LIVE/a.conf" mine
content "$LIVE/b.conf" b1
pass "dry run"

echo
echo -e "${GREEN}All pull and records tests passed${NC}"
