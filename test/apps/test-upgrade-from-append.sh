#!/usr/bin/env bash
# test-upgrade-from-append.sh - a machine on the last version that appended to ~/.bashrc
# syncs its way to this one. That first sync starts with the old script in memory and runs
# the installers it just pulled, so it needs the real old code.

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
echo "Upgrade From Appended .bashrc Tests"
echo "======================================"
echo

# The last commit with configure_flags: --append
OLD_COMMIT=b6cc3da
if ! git -C "$ROOT_DIR" cat-file -e "$OLD_COMMIT^{commit}" 2>/dev/null; then
    info "Skipped: $OLD_COMMIT isn't available here (a shallow clone or a copy without git)"
    exit 0
fi

unset DOTFILES_HOSTS_DIR TMUX
BASE="/tmp/dotfiles-test-upgrade-$$"
trap 'rm -rf "$BASE"' EXIT
rm -rf "$BASE"

OUT=""
RC=0
N=0

# A sandbox with an origin at the old commit, and this machine's checkout cloned from it
new_machine() {
    N=$((N + 1))
    T="$BASE/$N"
    mkdir -p "$T/home" "$T/state/apps" "$T/author" "$T/tmux"
    export HOME="$T/home"
    export STATE_DIR="$T/state"
    export XDG_STATE_HOME="$T/xdg-state"
    export DOTFILES_CONFIG="$T/config"
    export GIT_CONFIG_GLOBAL="$T/gitconfig"
    export GIT_TERMINAL_PROMPT=0
    export GIT_SETUP_SKIP=true
    export TMUX_TMPDIR="$T/tmux"
    git config --global user.name tester
    git config --global user.email tester@example.com
    git config --global init.defaultBranch main

    A="$T/author"
    git -C "$ROOT_DIR" archive "$OLD_COMMIT" | tar -xf - -C "$A"
    git -C "$A" init -q
    git -C "$A" add -A
    git -C "$A" commit -q -m old
    git clone -q --bare "$A" "$T/origin.git"
    git -C "$A" remote add origin "$T/origin.git"
    git -C "$A" fetch -q origin
    git -C "$A" branch -q -u origin/main
    git clone -q "$T/origin.git" "$T/dotfiles"
    R="$T/dotfiles"

    H="$T/hosts-dir"
    cp -R "$TEST_DIR/fixtures/hosts-dir" "$H"
    # Declared by name, as real profiles do: that is what picks up configure_flags
    sed -i.bak 's/^packages:/packages:\n  - bash/' "$H/profiles/base.yaml"
    rm -f "$H/profiles/base.yaml.bak"
    git -C "$H" init -q
    git -C "$H" add -A
    git -C "$H" commit -q -m base
    printf 'hosts_dir: %s\nhostname: testhost\n' "$H" > "$T/config"

    RCFILE="$HOME/.bashrc"
    LOCAL="$HOME/.bashrc.d/00-local.sh"
}

# The old code only knows 'sync'; the new version's verb is 'pull'
sync_now() {
    local verb=sync
    grep -q '"pull"' "$R/dotfiles" && verb=pull
    RC=0
    OUT=$("$R/dotfiles" "$verb" "$@" 2>&1 </dev/null) || RC=$?
}
author_push() {
    git -C "$A" add -A
    git -C "$A" commit -q -m "$1"
    git -C "$A" push -q origin main
}
# Publish this version of dotfiles to the sandbox origin
publish_new_version() {
    (cd "$A" && find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +)
    (cd "$ROOT_DIR" && tar --exclude=.git --exclude=test/ssh-key --exclude=test/ssh-key.pub -cf - .) | tar -xf - -C "$A"
    author_push "new version"
}
blocks() {
    grep -c 'BEGIN managed bashrc' "$RCFILE" || true
}
# Still appending, as the old code should
check_old_shape() {
    [[ $RC -eq 0 ]] || fail "$1: old sync failed: $OUT"
    [[ "$(blocks)" == "$2" ]] || fail "$1: expected $2 block(s) from the old code, found $(blocks)"
}
# One file, the repo's, on the new version
check_clean() {
    [[ $RC -eq 0 ]] || fail "$1: sync failed: $OUT"
    [[ "$(git -C "$R" rev-parse HEAD)" == "$(git -C "$A" rev-parse HEAD)" ]] || fail "$1: not on the new version"
    cmp -s "$A/apps/bash/files/.bashrc" "$RCFILE" || fail "$1: .bashrc is not the repo's file"
}
# The steps after the first sync, on any machine: nothing grows, edits are safe
check_settled() {
    local name="$1" before
    before=$(cat "$RCFILE")
    sync_now
    [[ $RC -eq 0 ]] || fail "$name: second sync failed: $OUT"
    [[ "$(cat "$RCFILE")" == "$before" ]] || fail "$name: second sync changed .bashrc"
    RC=0
    OUT=$("$R/dotfiles" status 2>&1 </dev/null) || RC=$?
    printf '%s\n' "$OUT" | grep -qF "local edits:     none" || fail "$name: false edit: $OUT"

    echo '# newer' >> "$A/apps/bash/files/.bashrc"
    author_push "newer bashrc"
    sync_now
    check_clean "$name, repo update"
    [[ "$(blocks)" == 0 ]] || fail "$name: a block came back"

    echo 'alias mine=1' >> "$RCFILE"
    echo '# newer add-on' >> "$A/apps/bash/files/50-fuzzy-find.sh"
    author_push "newer add-on"
    sync_now
    [[ $RC -eq 0 ]] || fail "$name: sync with an edit failed: $OUT"
    grep -qxF 'alias mine=1' "$RCFILE" || fail "$name: hand edit overwritten"
    [[ "$(blocks)" == 0 ]] || fail "$name: a block came back"
    OUT=$("$R/dotfiles" status 2>&1 </dev/null) || true
    printf '%s\n' "$OUT" | grep -qF "~/.bashrc" || fail "$name: hand edit not reported: $OUT"
}

info "Case 1: a managed copy plus a block, the shape of a machine set up from scratch"
new_machine
sync_now
check_old_shape "1" 0
# A config-only change: publishing the new version must not undo a deployed file here
echo '# changed' >> "$A/apps/bash/config.yaml"
author_push "old bash change"
sync_now
check_old_shape "1" 1
publish_new_version
sync_now
check_clean "1"
[[ ! -e "$LOCAL" ]] || fail "1: nothing of the user's to move"
[[ -z "$(find "$HOME/.bak/bash" -name 'bashrc.before-cleanup.*' 2>/dev/null)" ]] || fail "1: no copy needed"
grep -rlF 'BEGIN managed bashrc' "$HOME/.bak/bash" >/dev/null || fail "1: no snapshot of the old file"
check_settled "1"
pass "one copy, and it stays that way"

info "Case 2: the user's own content plus a block"
new_machine
printf '# my own bashrc\nexport MINE=1\n' > "$RCFILE"
sync_now
check_old_shape "2" 1
publish_new_version
sync_now
check_clean "2"
grep -qxF 'export MINE=1' "$LOCAL" || fail "2: own content lost"
[[ "$(grep -cxF 'export MINE=1' "$LOCAL")" == 1 ]] || fail "2: own content duplicated"
check_settled "2"
[[ "$(grep -cxF 'export MINE=1' "$LOCAL")" == 1 ]] || fail "2: own content duplicated later"
pass "own content moved once"

info "Case 3: an older managed copy, with a hand edit"
new_machine
sync_now
check_old_shape "3" 0
echo 'alias edited=1' >> "$RCFILE"
# A config-only change: publishing the new version must not undo a deployed file here
echo '# changed' >> "$A/apps/bash/config.yaml"
author_push "old bash change"
sync_now
check_old_shape "3" 1
publish_new_version
sync_now
check_clean "3"
grep -lxF 'alias edited=1' "$HOME"/.bak/bash/bashrc.before-cleanup.* >/dev/null || fail "3: hand edit not saved"
check_settled "3"
pass "hand edit saved"

info "Case 4: a machine that never appended: nothing to clean up"
new_machine
sync_now
check_old_shape "4" 0
publish_new_version
sync_now
check_clean "4"
[[ ! -e "$LOCAL" ]] || fail "4: nothing of the user's to move"
check_settled "4"
pass "plain install"

info "Case 5: the first sync is a background one"
new_machine
printf '# my own bashrc\nexport MINE=1\n' > "$RCFILE"
sync_now
check_old_shape "5" 1
publish_new_version
rm -f "$XDG_STATE_HOME/dotfiles/last-sync"
sync_now --auto
check_clean "5"
grep -qxF 'export MINE=1' "$LOCAL" || fail "5: own content lost"
check_settled "5"
pass "background upgrade"

echo
echo "All upgrade tests passed"
