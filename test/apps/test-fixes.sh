#!/usr/bin/env bash
# test-fixes.sh - the findings of the final review, one section each, every section on its own
# fresh host. Pass section numbers to run only those: test-fixes.sh 4 5

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
echo "Final Review Fixes"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR DOTFILES_RESET DOTFILES_RESET_SNAPSHOTTED DOTFILES_FORCE_PATH
unset DOTFILES_ADD_ASSUME_TTY DOTFILES_INIT_ASSUME_TTY DOTFILES_SSH_OPTS
BASE="/tmp/dotfiles-test-fixes-$$"
trap 'chmod -R u+rwx "$BASE" 2>/dev/null || true; rm -rf "$BASE"' EXIT
rm -rf "$BASE"
mkdir -p "$BASE"
export GIT_TERMINAL_PROMPT=0
export GIT_SETUP_SKIP=true

OUT=""
RC=0
N=0

# A fresh host: a dotfiles repo with one small app (a replaced file, a merged file), and a hosts
# repo whose host "fh" uses the profile "fp". Nothing deployed yet.
fresh() {
    N=$((N + 1))
    T="$BASE/$N"
    mkdir -p "$T/home" "$T/dotfiles" "$T/hosts/hosts/fh" "$T/hosts/profiles" "$T/bin"
    export HOME="$T/home"
    export STATE_DIR="$T/state"
    export XDG_STATE_HOME="$T/xdg-state"
    export DOTFILES_CONFIG="$T/config"
    export GIT_CONFIG_GLOBAL="$T/gitconfig"
    git config --global user.name tester
    git config --global user.email tester@example.com
    git config --global init.defaultBranch main
    R="$T/dotfiles"
    H="$T/hosts"
    (cd "$ROOT_DIR" && tar --exclude=.git --exclude=.worktrees --exclude=.superpowers -cf - .) | (cd "$R" && tar -xf -)
    AD="$R/apps/ad"
    mkdir -p "$AD/files"
    cat > "$AD/config.yaml" <<'EOF'
app:
  name: ad
  description: test app

files:
  - src: a.conf
    dest: ~/ad/a.conf
    mode: '0644'
  - src: settings.json
    dest: ~/ad/settings.json
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
    printf 'a1\n' > "$AD/files/a.conf"
    printf '{"model": "m1", "theme": "t1"}\n' > "$AD/files/settings.json"
    git -C "$R" init -q
    git -C "$R" add -A
    git -C "$R" commit -q -m base
    printf 'packages:\n  - name: ad\n    config:\n      dir: ad\n' > "$H/profiles/fp.yaml"
    printf 'profile: fp\n' > "$H/hosts/fh/host.yaml"
    git -C "$H" init -q
    git -C "$H" add -A
    git -C "$H" commit -q -m base
    printf 'hosts_dir: %s\nhostname: fh\n' "$H" > "$T/config"
    A="$HOME/ad/a.conf"
    S="$HOME/ad/settings.json"
    REC="$STATE_DIR/records/ad"
    HOST_FILES="$H/hosts/fh/apps/ad/files"
    PROFILE_FILES="$H/profiles/fp/apps/ad/files"
}
run() {
    RC=0
    OUT=$("$R/dotfiles" "$@" 2>&1 </dev/null) || RC=$?
}
# dotfiles add with the given answers. A timeout catches a prompt that loops.
add() {
    RC=0
    OUT=$(printf '%s\n' "$@" | DOTFILES_ADD_ASSUME_TTY=1 timeout 120 "$R/dotfiles" add ${ADD_ARGS[@]+"${ADD_ARGS[@]}"} 2>&1) || RC=$?
    [[ $RC -ne 124 ]] || fail "add hung: $OUT"
}
declare -a ADD_ARGS=()
add_all() {
    ADD_ARGS=(--all)
    add "$@"
    ADD_ARGS=()
}
do_pull() {
    run pull --no-fetch "$@"
    [[ $RC -eq 0 ]] || fail "pull failed: $OUT"
}
has_line() {
    printf '%s\n' "$OUT" | grep -qF -- "$1" || fail "missing '$1' in: $OUT"
}
no_line() {
    if printf '%s\n' "$OUT" | grep -qF -- "$1"; then fail "unexpected '$1' in: $OUT"; fi
}
commit_r() {
    git -C "$R" add -A
    git -C "$R" commit -q -m "$1"
}
commit_h() {
    git -C "$H" add -A
    git -C "$H" commit -q -m "$1"
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
# Everything a deploy could have changed
tree_sum() {
    (cd "$T" && find home state -type f -exec cksum {} + 2>/dev/null | sort) || true
}

# ---------------------------------------------------------------------------

section_1() {
    info "1: the installer refuses to deploy over old records, and uninstall still works"
    local cmd before
    fresh
    do_pull
    echo mine >> "$A"
    # An old host: state and deployed/*.tsv, no records. A background sync calls configure.sh.
    rm -rf "$STATE_DIR/records"
    sed -i 's/^  version: .*/  version: oldversion/' "$STATE_DIR/apps/ad.yaml"
    mkdir -p "$STATE_DIR/deployed"
    printf 'abc\ta.conf\t%s\n' "$A" > "$STATE_DIR/deployed/ad.tsv"
    before=$(tree_sum)
    for cmd in deploy upgrade install "deploy --force" "deploy --dry-run"; do
        RC=0
        # shellcheck disable=SC2086
        OUT=$(bash "$R/apps/ad/configure.sh" $cmd 2>&1 </dev/null) || RC=$?
        [[ $RC -ne 0 ]] || fail "configure.sh $cmd deployed over old records: $OUT"
        has_line "dotfiles init"
        has_line "init --remote"
        [[ "$(tree_sum)" == "$before" ]] || fail "configure.sh $cmd changed something: $OUT"
        grep -qx mine <(tail -n1 "$A") || fail "configure.sh $cmd lost the edit"
    done
    pass "deploy, upgrade and install refuse, and change nothing"

    # An app with its own pre-install step, not yet installed: that step mustn't run either
    echo '[user]' > "$HOME/.gitconfig"
    RC=0
    OUT=$(bash "$R/apps/git/configure.sh" deploy --skip-git-setup 2>&1 </dev/null) || RC=$?
    [[ $RC -ne 0 ]] || fail "git's configure.sh deployed: $OUT"
    [[ ! -e "$HOME/.gitconfig.local" && "$(cat "$HOME/.gitconfig")" == '[user]' ]] || fail "git's pre-install step ran: $OUT"
    rm -f "$HOME/.gitconfig"
    pass "an app's own steps don't run"

    # Init's move clears them first, so it still works
    RC=0
    OUT=$("$R/dotfiles" init --yes 2>&1 </dev/null) || RC=$?
    [[ $RC -eq 0 ]] || fail "init failed over old records: $OUT"
    [[ ! -e "$STATE_DIR/deployed" ]] || fail "old records survived init"
    [[ -s "$REC/manifest.tsv" ]] || fail "init left no records"
    grep -rqxF mine "$HOME/.bak/ad" || fail "init took no snapshot of the edit"
    pass "init moves the host on"

    # Uninstall still works on an old host, through configure.sh and through dotfiles
    fresh
    do_pull
    rm -rf "$STATE_DIR/records"
    mkdir -p "$STATE_DIR/deployed"
    printf 'abc\ta.conf\t%s\n' "$A" > "$STATE_DIR/deployed/ad.tsv"
    RC=0
    OUT=$(bash "$R/apps/ad/configure.sh" uninstall 2>&1 </dev/null) || RC=$?
    [[ $RC -eq 0 ]] || fail "uninstall refused: $OUT"
    [[ ! -e "$A" && ! -e "$STATE_DIR/apps/ad.yaml" ]] || fail "uninstall did not remove: $OUT"
    pass "configure.sh uninstall works"
    fresh
    do_pull
    rm -rf "$STATE_DIR/records"
    mkdir -p "$STATE_DIR/deployed"
    printf 'abc\ta.conf\t%s\n' "$A" > "$STATE_DIR/deployed/ad.tsv"
    run uninstall
    [[ $RC -eq 0 ]] || fail "dotfiles uninstall refused: $OUT"
    [[ ! -e "$A" ]] || fail "dotfiles uninstall did not remove: $OUT"
    pass "dotfiles uninstall works"
}

# Make R and H clones of bare origins, and second clones to push from
with_upstreams() {
    git clone -q --bare "$R" "$T/r.git"
    git clone -q --bare "$H" "$T/h.git"
    git -C "$R" remote add origin "$T/r.git"
    git -C "$H" remote add origin "$T/h.git"
    git -C "$R" fetch -q origin
    git -C "$H" fetch -q origin
    git -C "$R" branch -q --set-upstream-to=origin/main main
    git -C "$H" branch -q --set-upstream-to=origin/main main
    git clone -q "$T/r.git" "$T/r2"
    git clone -q "$T/h.git" "$T/h2"
}
push_upstream() {
    echo "$2" > "$T/$1/NEWFILE"
    git -C "$T/$1" add -A
    git -C "$T/$1" commit -q -m new
    git -C "$T/$1" push -q origin HEAD
}

section_2() {
    info "2: status counts commits fetched but not merged, in both repos"
    fresh
    with_upstreams
    do_pull
    run status
    has_line "updates available: none"
    pass "none while level with upstream"

    # Upstream moved, not fetched: status doesn't touch the network
    push_upstream r2 one
    run status
    has_line "updates available: none"
    git -C "$R" fetch -q origin
    run status
    no_line "updates available: none"
    section_has "updates available" "dotfiles repo (1 commit)"
    section_lacks "updates available" "hosts repo"
    has_line "'dotfiles pull' brings them in"
    pass "dotfiles repo counted"

    push_upstream r2 two
    git -C "$R" fetch -q origin
    push_upstream h2 one
    git -C "$H" fetch -q origin
    run status
    section_has "updates available" "dotfiles repo (2 commits)"
    section_has "updates available" "hosts repo (1 commit)"
    pass "both repos counted, with what the apps list says"

    # A new version of an app and an upstream commit sit side by side
    echo a2 > "$AD/files/a.conf"
    commit_r "local a2"
    run status
    section_has "updates available" "ad"
    section_has "updates available" "dotfiles repo (2 commits)"
    git -C "$R" reset -q --hard HEAD~1
    pass "next to the apps"

    git -C "$R" merge -q --ff-only origin/main
    git -C "$H" merge -q --ff-only origin/main
    do_pull
    run status
    has_line "updates available: none"
    pass "merged: none again"

    # Pinned: a detached checkout stays quiet, however far behind
    push_upstream r2 three
    git -C "$R" fetch -q origin
    git -C "$R" checkout -q --detach
    run status
    has_line "updates available: none"
    git -C "$R" checkout -q main
    pass "pinned stays quiet"

    # No upstream
    git -C "$R" branch -q --unset-upstream
    run status
    has_line "updates available: none"
    pass "no upstream stays quiet"

    # No git: a hosts dir that's a plain copy, inside nothing
    fresh
    do_pull
    rm -rf "$H/.git"
    rm -rf "$R/.git"
    run pull --no-fetch
    run status
    [[ $RC -eq 0 ]] || fail "status failed: $OUT"
    has_line "updates available: none"
    pass "no git stays quiet"
}

section_3() {
    info "3: pull --remote takes --force with no PATH; a path as a host is refused first"
    local word
    fresh
    cat > "$T/bin/ssh" <<EOF
#!/bin/sh
echo "\$*" >> "$T/ssh-log"
case "\$*" in
    *"sh -s"*) cat > /dev/null; printf 'dotfiles_repo=/r/dotfiles\nhosts_dir=/r/hosts\n' ;;
    *"mktemp -d"*) echo /tmp/fake-rtmp ;;
    *"[ -x '/r/dotfiles/dotfiles' ]"*) echo exists ;;
esac
exit 0
EOF
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/scp"
    chmod +x "$T/bin/ssh" "$T/bin/scp"
    for word in "$HOME/.tmux.conf" "~/.tmux.conf" "./tmux.conf" "apps/tmux.conf" "~"; do
        rm -f "$T/ssh-log"
        RC=0
        OUT=$(PATH="$T/bin:$PATH" "$R/dotfiles" pull --remote --force "$word" user@host 2>&1 </dev/null) || RC=$?
        [[ $RC -ne 0 ]] || fail "'$word' accepted as a host: $OUT"
        [[ ! -e "$T/ssh-log" ]] || fail "'$word': a host was touched: $(cat "$T/ssh-log")"
        has_line "is not a host"
        has_line "$word"
    done
    pass "a path before a real host: refused, nothing sent"

    # In any position, and with init too
    rm -f "$T/ssh-log"
    RC=0
    OUT=$(PATH="$T/bin:$PATH" "$R/dotfiles" pull --remote user@host "$HOME/x" 2>&1 </dev/null) || RC=$?
    [[ $RC -ne 0 && ! -e "$T/ssh-log" ]] || fail "a path after a real host: rc=$RC $OUT"
    RC=0
    OUT=$(PATH="$T/bin:$PATH" "$R/dotfiles" init --remote --yes user@host "$HOME/x" 2>&1 </dev/null) || RC=$?
    [[ $RC -ne 0 && ! -e "$T/ssh-log" ]] || fail "init --remote with a path: rc=$RC $OUT"
    pass "any position, and init --remote"

    # What stays allowed
    rm -f "$T/ssh-log"
    RC=0
    OUT=$(PATH="$T/bin:$PATH" "$R/dotfiles" pull --remote --force user@host other.example.com 2>&1 </dev/null) || RC=$?
    [[ $RC -eq 0 ]] || fail "plain hosts refused: $OUT"
    [[ "$(grep -c 'pull --no-fetch --force$' "$T/ssh-log")" == 2 ]] || fail "--force not sent to both: $(cat "$T/ssh-log")"
    pass "real hosts still go through, with --force"

    # The local form still takes a path
    do_pull
    echo mine >> "$A"
    do_pull --force "$A"
    cmp -s "$AD/files/a.conf" "$A" || fail "pull --force PATH did not take the repo's"
    pass "pull --force PATH unchanged"

    grep -q '^| `--force \[PATH\]` | `pull` |' "$ROOT_DIR/README.md" || fail "README: --force [PATH] should list only pull"
    grep -q '^| `--force` | `pull --remote` |' "$ROOT_DIR/README.md" || fail "README: no row for pull --remote --force"
    pass "README table"
}

section_4() {
    info "4: 'saved, not committed' only while the layer file is dirty; a committed lower layer has its own label"
    fresh
    # The host layer wins; the profile layer is below it
    mkdir -p "$HOST_FILES"
    printf 'host copy\n' > "$HOST_FILES/a.conf"
    printf '{"model": "host"}\n' > "$HOST_FILES/settings.json"
    commit_h "host layer"
    do_pull
    cmp -s "$HOST_FILES/a.conf" "$A" || fail "host layer not deployed"

    echo mine >> "$A"
    jq '.model = "mine"' "$S" > "$T/s" && cp "$T/s" "$S"
    # a.conf to the profile layer, below the host's; the key too
    add s 2 s 2
    has_line "still wins"
    [[ -n "$(git -C "$H" diff --cached --name-only)" ]] || fail "not staged"
    run status
    section_has "saved, not committed" "~/ad/a.conf"
    section_has "saved, not committed" "~/ad/settings.json"
    has_line "held in a lower layer: none"
    has_line "commit what 'dotfiles add' staged"
    pass "dirty: saved, not committed"

    commit_h "saved below the host"
    do_pull
    run status
    has_line "saved, not committed: none"
    has_line "held in a lower layer:  ("
    has_line "stays local"
    section_has "held in a lower layer" "~/ad/a.conf"
    section_has "held in a lower layer" '~/ad/settings.json  key ["model"]'
    has_line "unreviewed changes: none"
    has_line "conflicts: none"
    has_line "dismissed: none"
    pass "committed below the winner: its own label"

    # Status's instruction was false here; so nothing in plain add
    add q
    no_line "s(ave)"
    no_line "a.conf ==="
    has_line "held in a lower layer"
    has_line "add --all"
    no_line "No local edits"
    run pull --no-fetch
    no_line "have local edits"
    pass "out of plain add, and not counted by pull"

    # add --all offers them, with dismiss
    add_all k k
    has_line "d(ismiss)"
    has_line "=== ~/ad/a.conf ==="
    has_line 'key ["model"]'
    has_line "A lower layer holds this"
    run status
    section_has "held in a lower layer" "~/ad/a.conf"
    pass "add --all offers them; skip leaves them"

    # Dismiss clears the label: it moves to dismissed, where it can be asked about again
    add_all d d
    run status
    has_line "held in a lower layer: none"
    section_has "dismissed" "~/ad/a.conf"
    section_has "dismissed" '~/ad/settings.json  key ["model"]'
    cmp -s "$A" "$REC/review/a.conf" || fail "dismiss did not take the review copy"
    pass "dismiss clears it"

    # A live change after that is a new edit
    echo again >> "$A"
    run status
    section_has "unreviewed changes" "~/ad/a.conf"
    section_lacks "held in a lower layer" "~/ad/a.conf"
    pass "a further change is a new edit"

    # Hand-set to what a committed lower layer holds, with no save at all
    fresh
    mkdir -p "$HOST_FILES" "$PROFILE_FILES"
    printf 'host copy\n' > "$HOST_FILES/a.conf"
    printf 'profile copy\n' > "$PROFILE_FILES/a.conf"
    commit_h "two layers"
    do_pull
    printf 'profile copy\n' > "$A"
    run status
    section_has "held in a lower layer" "~/ad/a.conf"
    has_line "saved, not committed: none"
    # Dirty again, once more for the same layer: saved wins over held
    printf 'profile copy\n# a comment\n' > "$PROFILE_FILES/a.conf"
    printf 'profile copy\n# a comment\n' > "$A"
    run status
    section_has "saved, not committed" "~/ad/a.conf"
    has_line "held in a lower layer: none"
    # Untracked counts as dirty too
    git -C "$H" checkout -q -- .
    rm -rf "$PROFILE_FILES"
    commit_h "no profile layer"
    do_pull
    mkdir -p "$PROFILE_FILES"
    printf 'new\n' > "$PROFILE_FILES/a.conf"
    printf 'new\n' > "$A"
    run status
    section_has "saved, not committed" "~/ad/a.conf"
    pass "dirty or not decides, whatever made it so"

    # Saving where it already is committed is no save: nothing staged
    git -C "$H" add -A
    git -C "$H" commit -q -m "profile layer again"
    run status
    section_has "held in a lower layer" "~/ad/a.conf"
    add_all s 2
    has_line "already holds"
    no_line "Staged"
    [[ -z "$(git -C "$H" diff --cached --name-only)" ]] || fail "something was staged"
    pass "saving to the layer that holds it stages nothing"

    # A save that wins needs no new label: it settles once committed and pulled
    fresh
    mkdir -p "$HOST_FILES"
    printf 'host copy\n' > "$HOST_FILES/a.conf"
    commit_h "host layer"
    do_pull
    echo mine >> "$A"
    add s 1 k
    run status
    section_has "saved, not committed" "~/ad/a.conf"
    commit_h "saved at the winner"
    run status
    has_line "saved, not committed: none"
    has_line "held in a lower layer: none"
    has_line "unreviewed changes: none"
    do_pull
    run status
    has_line "saved, not committed: none"
    has_line "held in a lower layer: none"
    pass "saved at the winner settles"

    # The reset summary follows the labels
    fresh
    mkdir -p "$HOST_FILES" "$PROFILE_FILES"
    printf 'host copy\n' > "$HOST_FILES/a.conf"
    printf 'profile copy\n' > "$PROFILE_FILES/a.conf"
    commit_h "two layers"
    do_pull
    printf 'profile copy\n' > "$A"
    RC=0
    OUT=$(printf '%s\n' "" "" "" "" yes no | DOTFILES_INIT_ASSUME_TTY=1 "$R/dotfiles" init 2>&1) || RC=$?
    [[ $RC -eq 0 ]] || fail "init failed: $OUT"
    has_line "held in a lower layer:"
    has_line "~/ad/a.conf"
    no_line "no local changes would be lost"
    pass "reset summary"
}

section_5() {
    info "5: after saving a conflict, add and pull agree with status"
    fresh
    do_pull
    echo mine >> "$A"
    echo a2 > "$AD/files/a.conf"
    commit_r "repo a2"
    do_pull
    has_line "kept your edit to $A"
    has_line "run 'dotfiles add'"
    pass "an unsaved conflict: pull still says add"

    # Save it, at the only layer that wins: the public default
    add s y 3 public
    has_line "Staged apps/ad/files/a.conf"
    run status
    section_has "saved, not committed" "~/ad/a.conf"
    add q
    no_line "No local edits"
    no_line "s(ave)"
    has_line "waiting for a commit"
    has_line "~/ad/a.conf"
    do_pull
    has_line "kept your edit to $A"
    no_line "run 'dotfiles add'"
    has_line "commit"
    no_line "have local edits"
    pass "saved: add and pull say to commit"

    commit_r "saved"
    do_pull
    no_line "kept your edit"
    add q
    has_line "No local edits"
    no_line "waiting for a commit"
    run status
    has_line "saved, not committed: none"
    has_line "conflicts: none"
    pass "committed: settled, and add says so"

    # A merged file: one key saved and one not still needs add
    fresh
    do_pull
    jq '.model = "mine" | .theme = "mine"' "$S" > "$T/s" && cp "$T/s" "$S"
    printf '{"model": "m2", "theme": "t2"}\n' > "$AD/files/settings.json"
    commit_r "repo m2"
    do_pull
    has_line "kept your edit to $S"
    add s 3 public k
    run status
    section_has "saved, not committed" '["model"]'
    section_has "conflicts" '["theme"]'
    do_pull
    has_line "kept your edit to $S"
    has_line "run 'dotfiles add'"
    add s 3 public
    do_pull
    has_line "kept your edit to $S"
    no_line "run 'dotfiles add'"
    has_line "commit"
    pass "a merged file says commit only once every conflict in it is saved"

    # A tool's drop-in goes the same way
    fresh
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/lazygit"
    chmod +x "$T/bin/lazygit"
    export PATH="$T/bin:$PATH"
    printf 'packages:\n  - lazygit\n  - name: ad\n    config:\n      dir: ad\n' > "$H/profiles/fp.yaml"
    commit_h "with lazygit"
    do_pull
    local lz="$HOME/.bashrc.d/50-lazygit.sh"
    echo '# mine' >> "$lz"
    echo '# repo' >> "$R/apps/lazygit/files/50-lazygit.sh"
    commit_r "lazygit v2"
    do_pull
    has_line "kept your edit to $lz"
    has_line "run 'dotfiles add'"
    add s y 1 public
    do_pull
    has_line "kept your edit to $lz"
    no_line "run 'dotfiles add'"
    has_line "commit"
    add q
    has_line "waiting for a commit"
    no_line "No local edits"
    pass "drop-ins too"

    # A save still in the same review doesn't claim to wait twice: the closing message covers it
    fresh
    do_pull
    echo mine >> "$A"
    add s 3 public
    has_line "Staged, not committed"
    no_line "No local edits"
    pass "a save in this very run"
}

section_6() {
    info "6: a non-executable install script: says chmod and commit, with the repo's path"
    local line
    fresh
    mkdir -p "$R/apps/tt"
    printf 'app:\n  name: tt\n\ninstall:\n  check: test -e %s\n' "$T/tt-installed" > "$R/apps/tt/config.yaml"
    printf '#!/bin/sh\n: > %s\n' "$T/tt-installed" > "$R/apps/tt/install.sh"
    chmod -x "$R/apps/tt/install.sh"
    commit_r "tt"
    printf 'packages:\n  - tt\n' > "$H/profiles/fp.yaml"
    commit_h "tt in the profile"
    run pull --no-fetch
    [[ $RC -ne 0 ]] || fail "pull passed: $OUT"
    has_line "apps/tt/install.sh"
    has_line "chmod +x apps/tt/install.sh"
    has_line "commit"
    line=$(printf '%s\n' "$OUT" | grep -F 'install.sh' | head -n1)
    [[ "$line" != *"/export/"* ]] || fail "a temp path in: $line"
    pass "names the repo path and says what to do"

    # An uncommitted chmod changes nothing, as the message says
    chmod +x "$R/apps/tt/install.sh"
    run pull --no-fetch
    [[ $RC -ne 0 ]] || fail "pull passed on an uncommitted chmod: $OUT"
    has_line "commit"
    commit_r "tt executable"
    run pull --no-fetch
    [[ $RC -eq 0 ]] || fail "pull failed once committed: $OUT"
    [[ -e "$T/tt-installed" ]] || fail "the script did not run: $OUT"
    pass "only the commit fixes it"

    # The dry run names it the same way
    rm -f "$T/tt-installed"
    run pull --no-fetch --dry-run
    has_line "Would run: apps/tt/install.sh"
    no_line "/export/"
    pass "the dry run names the repo path too"

    grep -qF 'chmod +x apps/<app>/install.sh` and commit' "$ROOT_DIR/README.md" || fail "README troubleshooting line not fixed"
    grep -qF 'and commit it' "$ROOT_DIR/README.md" || fail "README: the chmod example doesn't say to commit"
    pass "README"
}

section_7() {
    info "7: the docs say what the code does"
    local readme="$ROOT_DIR/README.md" schema="$ROOT_DIR/docs/schema.md"
    ! grep -qF 'A merge never deletes a key' "$readme" || fail "README: merge never deletes"
    grep -qF 'removes a key' "$readme" || fail "README: no word on a key the repo removes"
    ! grep -qF '`merge` never deletes keys' "$schema" || fail "schema: merge never deletes"
    ! grep -qF 'restores the originals (unless `--no-backup`)' "$schema" || fail "schema: uninstall --no-backup"
    if sed -n '/^### State directory/,/^---/p' "$schema" | grep -q '^| `records/`'; then
        fail "schema: records/ still under the XDG state dir"
    fi
    if grep -qF '<state dir>/records' "$schema"; then fail "schema: records under <state dir>"; fi
    grep -qF '$STATE_DIR/records/<app>/' "$schema" || fail "schema: records path"
    pass "text"

    # What the merge text claims: a removed key goes if unchanged, stays if edited
    fresh
    printf '{"model": "m1", "theme": "t1", "gone": 1, "kept": 1}\n' > "$AD/files/settings.json"
    commit_r "more keys"
    do_pull
    jq '.kept = 2' "$S" > "$T/s" && cp "$T/s" "$S"
    printf '{"model": "m1", "theme": "t1"}\n' > "$AD/files/settings.json"
    commit_r "less keys"
    do_pull
    [[ "$(jq -c 'has("gone")' "$S")" == false ]] || fail "an unchanged repo-removed key stayed"
    [[ "$(jq -c .kept "$S")" == 2 ]] || fail "an edited repo-removed key went"
    pass "a removed key goes if unchanged, stays if edited"

    # The README's line on ~/.gitconfig: check it's true
    grep -qF 'uninstall' "$readme" || fail "README: uninstall"
    grep -qE '~/\.gitconfig.*~/\.gitconfig\.local' <(sed -n '/^### uninstall/,/^### /p' "$readme") || fail "README: no line on .gitconfig"
    fresh
    printf 'packages:\n  - name: git\n    config:\n      dir: git\n' > "$H/profiles/fp.yaml"
    commit_h "git"
    printf '[user]\n  name = me\n' > "$HOME/.gitconfig"
    do_pull
    [[ "$(cat "$HOME/.gitconfig.local")" == $'[user]\n  name = me' ]] || fail "existing .gitconfig not moved aside: $OUT"
    grep -qF 'gitconfig.local' "$HOME/.gitconfig" || fail "managed .gitconfig doesn't include .gitconfig.local"
    run uninstall
    [[ $RC -eq 0 ]] || fail "uninstall failed: $OUT"
    [[ ! -e "$HOME/.gitconfig" ]] || fail "uninstall left ~/.gitconfig: $(cat "$HOME/.gitconfig")"
    [[ "$(cat "$HOME/.gitconfig.local")" == $'[user]\n  name = me' ]] || fail "uninstall changed .gitconfig.local"
    pass "uninstall removes ~/.gitconfig and leaves ~/.gitconfig.local"
}

section_8() {
    info "8: a dry run says what the real pull would, for a conflict and for a kept edit"
    local before
    fresh
    do_pull
    # A kept edit: the repo changes something else, so the app redeploys
    echo mine >> "$A"
    printf '{"model": "m1", "theme": "t2"}\n' > "$AD/files/settings.json"
    commit_r "theme"
    before=$(tree_sum)
    run pull --no-fetch --dry-run
    [[ $RC -eq 0 ]] || fail "dry run failed: $OUT"
    [[ "$(tree_sum)" == "$before" ]] || fail "the dry run changed something"
    has_line "Keeping local edit: $A"
    no_line "Would update: "
    has_line "Would merge"
    pass "a kept edit"

    # A conflict in a replaced file
    echo a2 > "$AD/files/a.conf"
    commit_r "a2"
    before=$(tree_sum)
    run pull --no-fetch --dry-run
    [[ "$(tree_sum)" == "$before" ]] || fail "the dry run changed something"
    has_line "Keeping your edit to $A, the repo changed it too"
    has_line "kept your edit to $A"
    no_line "Would update"
    local dry_lines real_lines
    dry_lines=$(printf '%s\n' "$OUT" | grep -F 'kept your edit' | sed 's/.*kept your/kept your/')
    run pull --no-fetch
    real_lines=$(printf '%s\n' "$OUT" | grep -F 'kept your edit' | sed 's/.*kept your/kept your/')
    [[ "$dry_lines" == "$real_lines" ]] || fail "dry '$dry_lines' real '$real_lines'"
    pass "a conflict: the same words as the real pull"

    # A conflict in a merged file
    jq '.model = "mine"' "$S" > "$T/s" && cp "$T/s" "$S"
    printf '{"model": "m2", "theme": "t2"}\n' > "$AD/files/settings.json"
    commit_r "m2"
    before=$(tree_sum)
    run pull --no-fetch --dry-run
    [[ "$(tree_sum)" == "$before" ]] || fail "the dry run changed something"
    has_line "Keeping your values in $S, the repo changed them too"
    has_line '["model"]'
    no_line "Would merge"
    pass "a merged conflict"

    # --force would take the repo's: then it does say so
    run pull --no-fetch --dry-run --force
    has_line "Would update: "
    no_line "Keeping your edit"
    has_line "Would merge"
    run pull --no-fetch --dry-run --force "$A"
    has_line "Would update: "
    no_line "Keeping your edit"
    pass "--force and --force PATH"

    # Applying and no change
    fresh
    do_pull
    echo a2 > "$AD/files/a.conf"
    commit_r "a2"
    run pull --no-fetch --dry-run
    has_line "Would update: "
    no_line "Keeping"
    has_line "No change: $S"
    pass "an unedited file updates; nothing to do says so"

    # An invalid live file: the real pull fails that file, and so does the preview
    printf 'not json' > "$S"
    RC=0
    run pull --no-fetch --dry-run
    has_line "not a valid JSON object"
    pass "invalid JSON"

    # A renamed source compares against the record it takes over
    fresh
    do_pull
    echo mine >> "$A"
    git -C "$R" mv apps/ad/files/a.conf apps/ad/files/b.conf
    sed -i 's/src: a.conf/src: b.conf/' "$AD/config.yaml"
    echo a2 > "$AD/files/b.conf"
    commit_r "renamed and changed"
    before=$(tree_sum)
    run pull --no-fetch --dry-run
    [[ "$(tree_sum)" == "$before" ]] || fail "the dry run changed something"
    has_line "Keeping your edit to $A, the repo changed it too"
    run pull --no-fetch
    has_line "Keeping your edit to $A, the repo changed it too"
    pass "a renamed source"

    # Drop-ins, a tool's and the login one
    fresh
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/lazygit"
    chmod +x "$T/bin/lazygit"
    export PATH="$T/bin:$PATH"
    printf 'packages:\n  - lazygit\n' > "$H/profiles/fp.yaml"
    commit_h "with lazygit"
    do_pull
    local lz="$HOME/.bashrc.d/50-lazygit.sh" lg="$HOME/.bashrc.d/90-dotfiles.sh"
    echo '# mine' >> "$lz"
    echo '# mine' >> "$lg"
    run pull --no-fetch --dry-run
    has_line "Keeping local edit: $lz"
    has_line "Keeping local edit: $lg"
    no_line "Would install dropin: $lz"
    echo '# repo' >> "$R/apps/lazygit/files/50-lazygit.sh"
    echo '# repo' >> "$R/lib/login.sh"
    commit_r "drop-ins v2"
    before=$(tree_sum)
    run pull --no-fetch --dry-run
    [[ "$(tree_sum)" == "$before" ]] || fail "the dry run changed something"
    has_line "kept your edit to $lz"
    has_line "kept your edit to $lg"
    pass "drop-ins"

    # A first dry run creates nothing, drop-ins and link included
    fresh
    before=$(tree_sum)
    run pull --no-fetch --dry-run
    [[ $RC -eq 0 ]] || fail "dry run failed: $OUT"
    [[ "$(tree_sum)" == "$before" ]] || fail "the dry run changed something"
    [[ ! -e "$HOME/.local/bin/dotfiles" ]] || fail "the dry run linked the command"
    has_line "Would install: "
    pass "a first dry run writes nothing"
}

section_9() {
    info "9: dotfiles help matches the README"
    fresh
    run help
    no_line "last sync"
    no_line "force the operation without prompts"
    no_line "uninstall --no-backup"
    has_line "Switch to a tag, commit or branch"
    has_line "keeps your local edits"
    has_line "--force without a PATH"
    has_line "dotfiles uninstall "
    has_line "always takes a snapshot"
    pass "help"
}

section_10() {
    info "10: no phantom dismissed item when the repo removes a nested key"
    local out
    merge() {
        jq -nc --argjson base "[$1]" --argjson new "[$2]" --argjson live "[$3]" --argjson review "[$4]" \
            -f "$ROOT_DIR/lib/merge3.jq"
    }
    # The parent the removal empties goes, from live and review
    out=$(merge '{"p":{"k":1}}' '{}' '{"p":{"k":1}}' '{"p":{"k":1}}')
    [[ "$(jq -c .live <<< "$out")" == '{}' ]] || fail "live: $out"
    [[ "$(jq -c .review <<< "$out")" == '{}' ]] || fail "review: $out"
    [[ "$(jq -c .repo <<< "$out")" == '{}' ]] || fail "repo: $out"
    # Up through every level it empties
    out=$(merge '{"p":{"q":{"k":1}}}' '{}' '{"p":{"q":{"k":1}}}' '{"p":{"q":{"k":1}}}')
    [[ "$(jq -c .live <<< "$out")" == '{}' ]] || fail "deep live: $out"
    # Two removed keys under one parent
    out=$(merge '{"p":{"a":1,"b":2}}' '{}' '{"p":{"a":1,"b":2}}' '{"p":{"a":1,"b":2}}')
    [[ "$(jq -c .live <<< "$out")" == '{}' ]] || fail "two keys: $out"
    # A parent the user put something in stays
    out=$(merge '{"p":{"k":1}}' '{}' '{"p":{"k":1,"mine":2}}' '{"p":{"k":1}}')
    [[ "$(jq -c .live <<< "$out")" == '{"p":{"mine":2}}' ]] || fail "user's key: $out"
    # A parent the repo still has stays, even empty
    out=$(merge '{"p":{"k":1,"o":2}}' '{"p":{"o":2}}' '{"p":{"k":1,"o":2}}' '{"p":{"k":1,"o":2}}')
    [[ "$(jq -c .live <<< "$out")" == '{"p":{"o":2}}' ]] || fail "repo sibling: $out"
    out=$(merge '{"p":{"k":1}}' '{"p":{}}' '{"p":{"k":1}}' '{"p":{"k":1}}')
    [[ "$(jq -c .live <<< "$out")" == '{"p":{}}' ]] || fail "repo's empty parent: $out"
    out=$(merge '{"p":{"q":{"k":1}}}' '{"p":{"r":1}}' '{"p":{"q":{"k":1}}}' '{"p":{"q":{"k":1}}}')
    [[ "$(jq -c .live <<< "$out")" == '{"p":{"r":1}}' ]] || fail "repo keeps the upper parent: $out"
    # An edited value under the removal stays, parent and all
    out=$(merge '{"p":{"k":1}}' '{}' '{"p":{"k":2}}' '{"p":{"k":2}}')
    [[ "$(jq -c .live <<< "$out")" == '{"p":{"k":2}}' ]] || fail "edited value: $out"
    # A key named with a dot is not a path
    out=$(merge '{"a.b":{"k":1},"a":{"b":{"k":1}}}' '{"a":{"b":{"k":1}}}' '{"a.b":{"k":1},"a":{"b":{"k":1}}}' '{"a.b":{"k":1},"a":{"b":{"k":1}}}')
    [[ "$(jq -c .live <<< "$out")" == '{"a":{"b":{"k":1}}}' ]] || fail "dotted key: $out"
    pass "merge3 cases"

    # Through the real commands
    fresh
    printf '{"model": "m1", "p": {"q": {"k": 1}}, "u": {"k": 1}}\n' > "$AD/files/settings.json"
    commit_r "nested"
    do_pull
    jq '.u.mine = 2' "$S" > "$T/s" && cp "$T/s" "$S"
    add d
    printf '{"model": "m1"}\n' > "$AD/files/settings.json"
    commit_r "nested keys removed"
    do_pull
    [[ "$(jq -c . "$S")" == '{"model":"m1","u":{"mine":2}}' ]] || fail "live: $(cat "$S")"
    run status
    section_lacks "dismissed" '["p"'
    section_has "dismissed" '["u","mine"]'
    has_line "unreviewed changes: none"
    add_all k
    no_line '["p"'
    no_line '["u"]'
    pass "status and add --all list only the user's key"
}

section_11() {
    info "11: a blocked update in init doesn't claim nothing changed: the config was written"
    fresh
    with_upstreams
    do_pull
    # Diverged from upstream
    push_upstream r2 one
    echo mine > "$R/LOCALFILE"
    commit_r "a commit here"
    RC=0
    OUT=$(printf '%s\n' "" "" "" "4h" "2h" | DOTFILES_INIT_ASSUME_TTY=1 "$R/dotfiles" init 2>&1) || RC=$?
    [[ $RC -ne 0 ]] || fail "init passed: $OUT"
    has_line "pull blocked"
    no_line "nothing was changed"
    has_line "nothing was deployed"
    has_line "settings are saved"
    grep -q '^update_check_interval: ' "$T/config" || fail "no config: $(cat "$T/config")"
    pass "reworded"
}

section_12() {
    info "12: sync rejects --force"
    fresh
    do_pull
    echo mine >> "$A"
    local args
    for args in "--force" "--force --dry-run" "--no-fetch --force"; do
        RC=0
        # shellcheck disable=SC2086
        OUT=$(printf 'd\n' | DOTFILES_ADD_ASSUME_TTY=1 "$R/dotfiles" sync $args 2>&1) || RC=$?
        [[ $RC -ne 0 ]] || fail "sync $args passed: $OUT"
        has_line "sync doesn't take --force"
        has_line "dotfiles pull --force"
        no_line "Phase"
    done
    grep -qx mine <(tail -n1 "$A") || fail "the edit went"
    RC=0
    OUT=$(printf 'd\n' | DOTFILES_ADD_ASSUME_TTY=1 "$R/dotfiles" sync --force "$A" 2>&1) || RC=$?
    [[ $RC -ne 0 ]] || fail "sync --force PATH passed: $OUT"
    pass "rejected"
}

section_13() {
    info "13: dead code is gone"
    ! grep -rq 'records_has_dest' "$ROOT_DIR/lib" "$ROOT_DIR/dotfiles" "$ROOT_DIR/test/run-core-tests.sh" || fail "records_has_dest is still there"
    [[ "$(grep -c 'HELD_CONFLICTS+=' "$ROOT_DIR/dotfiles")" == 1 ]] || fail "the kept-edit loop isn't folded into note_kept_edit"
    pass "gone"
}

section_14() {
    info "14: the terminal case in test-add.sh says when it's skipped"
    grep -qF 'Skipping the terminal case' "$TEST_DIR/apps/test-add.sh" || fail "no notice"
    pass "notice"
}

if [[ $# -gt 0 ]]; then
    for s in "$@"; do
        "section_$s"
    done
else
    for s in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        "section_$s"
    done
fi

echo
echo -e "${GREEN}All final review fix tests passed${NC}"
