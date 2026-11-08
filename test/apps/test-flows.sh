#!/usr/bin/env bash
# test-flows.sh - whole flows through the real dotfiles command, one step after another on one
# host, checking files, records and status after each step. Then the same core on a host with
# no git, reached through a fake ssh that runs the commands here under another HOME.
#
# Only HOME is overridden, so the state, records and config live where they would on a real
# machine, under that HOME.

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
echo "End-to-end Flows"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR DOTFILES_RESET DOTFILES_RESET_SNAPSHOTTED DOTFILES_FORCE_PATH DOTFILES_SSH_OPTS
unset DOTFILES_ADD_ASSUME_TTY DOTFILES_INIT_ASSUME_TTY STATE_DIR XDG_STATE_HOME DOTFILES_CONFIG
T="/tmp/dotfiles-test-flows-$$"
trap 'chmod -R u+rwx "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home" "$T/bin" "$T/seed-r" "$T/seed-h/hosts/fh" "$T/seed-h/profiles"
export HOME="$T/home"
# Outside HOME: the git app manages ~/.gitconfig
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_TERMINAL_PROMPT=0
export GIT_SETUP_SKIP=true
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# The tools are already there, so no install script runs, and sudo can never be reached
for tool in claude lazygit; do
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/$tool"
done
printf '#!/bin/sh\nexit 1\n' > "$T/bin/sudo"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# The repos: bare origins, this machine's clones, and another machine's clones to push from
(cd "$ROOT_DIR" && tar --exclude=.git --exclude=.worktrees --exclude=.superpowers -cf - .) | (cd "$T/seed-r" && tar -xf -)
git -C "$T/seed-r" init -q
git -C "$T/seed-r" add -A
git -C "$T/seed-r" commit -q -m base
git -C "$T/seed-r" tag v1
printf 'packages:\n  - git\n  - scripts\n  - claude\n  - lazygit\n' > "$T/seed-h/profiles/flows.yaml"
printf 'packages:\n  - git\n  - scripts\n  - lazygit\n' > "$T/seed-h/profiles/small.yaml"
printf 'profile: flows\n' > "$T/seed-h/hosts/fh/host.yaml"
git -C "$T/seed-h" init -q
git -C "$T/seed-h" add -A
git -C "$T/seed-h" commit -q -m base
git clone -q --bare "$T/seed-r" "$T/r.git"
git clone -q --bare "$T/seed-h" "$T/h.git"
R="$T/dotfiles"
H="$T/hosts"
git clone -q "$T/r.git" "$R"
git clone -q "$T/h.git" "$H"
git clone -q "$T/r.git" "$T/r2"
git clone -q "$T/h.git" "$T/h2"

STATE="$HOME/.config/dotfiles"
REC="$STATE/records"
SC="$HOME/.local/bin/git-branch-clean"
CM="$HOME/.claude/CLAUDE.md"
CS="$HOME/.claude/settings.json"
LZ="$HOME/.bashrc.d/50-lazygit.sh"
LG="$HOME/.bashrc.d/90-dotfiles.sh"
HOST_SCRIPTS="$H/hosts/fh/apps/scripts/files"
PROFILE_CLAUDE="$H/profiles/flows/apps/claude/files"

OUT=""
RC=0
df() {
    RC=0
    OUT=$("$R/dotfiles" "$@" 2>&1 </dev/null) || RC=$?
}
df_ok() {
    df "$@"
    [[ $RC -eq 0 ]] || fail "dotfiles $* failed ($RC): $OUT"
}
# dotfiles add with the given answers
add() {
    RC=0
    OUT=$(printf '%s\n' "$@" | DOTFILES_ADD_ASSUME_TTY=1 timeout 120 "$R/dotfiles" add ${ADD_ARGS[@]+"${ADD_ARGS[@]}"} 2>&1) || RC=$?
    [[ $RC -ne 124 ]] || fail "add hung: $OUT"
    [[ $RC -eq 0 ]] || fail "add failed ($RC): $OUT"
}
declare -a ADD_ARGS=()
has_line() {
    printf '%s\n' "$OUT" | grep -qF -- "$1" || fail "missing '$1' in: $OUT"
}
no_line() {
    if printf '%s\n' "$OUT" | grep -qF -- "$1"; then fail "unexpected '$1' in: $OUT"; fi
}
section() {
    printf '%s\n' "$OUT" | awk -v l="$1" 'index($0, l ":") == 1 { p = 1; print; next } /^  / && p { print; next } { p = 0 }'
}
section_has() {
    section "$1" | grep -qF -- "$2" || fail "'$2' not under '$1' in: $OUT"
}
section_lacks() {
    if section "$1" | grep -qF -- "$2"; then fail "'$2' under '$1' in: $OUT"; fi
}
# Status with nothing to report
clean() {
    df_ok status
    local label
    for label in "updates available" "unreviewed changes" conflicts dismissed "saved, not committed" \
        "held in a lower layer" "uncommitted files"; do
        has_line "$label: none"
    done
}
# Push a change from the other machine
other() {
    local clone="$1" file="$2" line="$3"
    mkdir -p "$(dirname "$T/$clone/$file")"
    echo "$line" >> "$T/$clone/$file"
    git -C "$T/$clone" add -A
    git -C "$T/$clone" commit -q -m "$line"
    git -C "$T/$clone" push -q origin HEAD
}
# What status lists for add, and what add shows (answering skip to each), must be the same
# items: "PATH" or "PATH  key [...]" lines
status_items() {
    df_ok status
    { section "unreviewed changes"; section conflicts; } | { grep '^  ' || true; } \
        | sed -e 's/^  //' -e 's/  (the repo changed it too)$//' | sort
}
add_items() {
    local answers=()
    local i
    for i in $(seq 1 20); do answers+=(k); done
    add "${answers[@]}"
    printf '%s\n' "$OUT" | sed -n 's/^=== \(.*\) ===$/\1/p' | sort
}
agree() {
    local s a
    s=$(status_items)
    a=$(add_items)
    [[ "$s" == "$a" ]] || fail "status and add disagree: status [$s] add [$a]"
    [[ "$s" == "$1" ]] || fail "expected [$1], status and add both list [$s]"
}
# A file and its record agree: live, repo copy and review copy
recorded() {
    local app="$1" src="$2" live="$3"
    cmp -s "$REC/$app/repo/$src" "$live" || fail "$live: repo copy differs"
    cmp -s "$REC/$app/review/$src" "$live" || fail "$live: review copy differs"
}

# ---------------------------------------------------------------------------
info "Flow 1: fresh init"
mkdir -p "$HOME/.claude"
echo "my original" > "$CM"
printf '[user]\n\tname = flow\n' > "$HOME/.gitconfig"
df_ok init --yes --hosts-dir "$H" --hostname fh
[[ -f "$HOME/.config/dotfiles/config.yaml" ]] || fail "no config"
cmp -s "$R/apps/scripts/files/git-branch-clean" "$SC" || fail "scripts not deployed"
cmp -s "$R/apps/claude/files/CLAUDE.md" "$CM" || fail "CLAUDE.md not deployed"
cmp -s "$R/apps/lazygit/files/50-lazygit.sh" "$LZ" || fail "lazygit drop-in not deployed"
[[ -L "$HOME/.local/bin/dotfiles" ]] || fail "command not linked"
[[ -f "$LG" ]] || fail "no login drop-in"
[[ "$(cat "$HOME/.bak/claude/original/CLAUDE.md")" == "my original" ]] || fail "original not kept"
grep -qF 'name = flow' "$HOME/.gitconfig.local" || fail "old .gitconfig not moved aside"
recorded scripts git-branch-clean "$SC"
recorded claude CLAUDE.md "$CM"
recorded lazygit 50-lazygit.sh "$LZ"
clean
pass "deployed, recorded, status clean"

info "Flow 1: a local edit, and a pull that keeps it"
echo "# my edit" >> "$SC"
EDITED_SC=$(cat "$SC")
agree "~/.local/bin/git-branch-clean"
other r2 apps/claude/files/CLAUDE.md "# repo change 1"
df_ok pull
[[ "$(cat "$SC")" == "$EDITED_SC" ]] || fail "pull lost the edit"
grep -qF "# repo change 1" "$CM" || fail "the repo's change didn't arrive"
recorded claude CLAUDE.md "$CM"
cmp -s "$R/apps/scripts/files/git-branch-clean" "$REC/scripts/repo/git-branch-clean" || fail "repo copy moved"
has_line "1 file(s) have local edits"
agree "~/.local/bin/git-branch-clean"
df_ok status
has_line "updates available: none"
pass "kept, the rest updated"

info "Flow 1: the repo changes the same file: a conflict"
other r2 apps/scripts/files/git-branch-clean "# repo change 2"
df_ok pull
[[ "$(cat "$SC")" == "$EDITED_SC" ]] || fail "conflict lost the edit"
has_line "kept your edit to $SC"
has_line "run 'dotfiles add'"
! grep -qF "# repo change 2" "$REC/scripts/repo/git-branch-clean" || fail "repo copy took the held version"
df_ok status
section_has conflicts "~/.local/bin/git-branch-clean  (the repo changed it too)"
has_line "scripts   conflict held back"
agree "~/.local/bin/git-branch-clean"
# The conflict turns off the early stop
df_ok pull
no_line "Already up to date (use --force"
has_line "kept your edit to $SC"
pass "held, flagged, and status and add agree"

info "Flow 1: save it to this host's layer, then commit and pull"
add s y 1
has_line "Saving the whole file undoes the repo's change"
has_line "This creates the file in that layer"
has_line "Staged hosts/fh/apps/scripts/files/git-branch-clean"
cmp -s "$SC" "$HOST_SCRIPTS/git-branch-clean" || fail "not saved to the host layer"
df_ok status
section_has "saved, not committed" "~/.local/bin/git-branch-clean"
has_line "conflicts: none"
section_has "uncommitted files, not deployed" "hosts/fh/apps/scripts/files/git-branch-clean"
add
has_line "waiting for a commit"
no_line "No local edits"
df_ok pull --no-fetch
has_line "kept your edit to $SC"
has_line "commit it there"
no_line "have local edits"
git -C "$H" commit -q -m "keep my git-branch-clean here"
git -C "$H" push -q origin HEAD
df_ok pull
no_line "kept your edit"
[[ "$(cat "$SC")" == "$EDITED_SC" ]] || fail "the committed save changed the file"
recorded scripts git-branch-clean "$SC"
add
has_line "No local edits"
clean
pass "saved, committed, pulled: clean"

# ---------------------------------------------------------------------------
info "Flow 2: dismiss a key, then add --all"
jq '.model = "mine"' "$CS" > "$T/cs" && cp "$T/cs" "$CS"
agree '~/.claude/settings.json  key ["model"]'
add d
df_ok status
section_has dismissed '~/.claude/settings.json  key ["model"]'
has_line "unreviewed changes: none"
cmp -s "$CS" "$REC/claude/review/settings.json" || fail "dismiss did not take the review copy"
other r2 apps/claude/files/CLAUDE.md "# repo change 3"
df_ok pull
[[ "$(jq -r .model "$CS")" == mine ]] || fail "pull lost the dismissed value"
no_line "have local edits"
agree ""
ADD_ARGS=(--all)
add s 2
ADD_ARGS=()
has_line "You dismissed this earlier"
has_line "Staged profiles/flows/apps/claude/files/settings.json"
[[ "$(jq -r .model "$PROFILE_CLAUDE/settings.json")" == mine ]] || fail "not saved to the profile layer"
[[ "$(jq -c keys "$PROFILE_CLAUDE/settings.json")" == '["model"]' ]] || fail "saved more than the key"
df_ok status
section_has "saved, not committed" '~/.claude/settings.json  key ["model"]'
git -C "$H" commit -q -m "my model"
git -C "$H" push -q origin HEAD
df_ok pull
[[ "$(jq -r .model "$CS")" == mine ]] || fail "value changed"
[[ "$(jq -r .model "$REC/claude/repo/settings.json")" == mine ]] || fail "repo copy didn't take the saved value"
clean
pass "dismissed, asked again, saved, clean"

# ---------------------------------------------------------------------------
info "Flow 3: --force PATH takes one file and leaves the others"
echo "# cm edit" >> "$CM"
echo "# lz edit" >> "$LZ"
agree "$(printf '%s\n' "~/.bashrc.d/50-lazygit.sh" "~/.claude/CLAUDE.md" | sort)"
df_ok pull --force "$CM"
cmp -s "$REC/claude/repo/CLAUDE.md" "$CM" || fail "--force PATH did not take the repo's"
! grep -qF "# cm edit" "$CM" || fail "the edit is still there"
grep -rqF "# cm edit" "$HOME/.bak/claude" || fail "no snapshot of the edit"
grep -qF "# lz edit" "$LZ" || fail "--force PATH touched another file"
agree "~/.bashrc.d/50-lazygit.sh"
add d
df_ok status
section_has dismissed "~/.bashrc.d/50-lazygit.sh"
# Undone by hand: the same as the repo's again, so nothing to list
cp "$R/apps/lazygit/files/50-lazygit.sh" "$LZ"
clean
pass "one file taken, with a snapshot"

# ---------------------------------------------------------------------------
info "Flow 4: a profile switch and back"
echo "# while away" >> "$CM"
EDITED_CM=$(cat "$CM")
df_ok init --yes --profile small
df_ok status
has_line "profile: small"
no_line "claude "
[[ "$(cat "$CM")" == "$EDITED_CM" ]] || fail "switching away changed CLAUDE.md"
[[ -f "$REC/claude/manifest.tsv" ]] || fail "claude's records went"
cmp -s "$R/apps/scripts/files/extract" "$HOME/.local/bin/extract" || fail "scripts changed"
section_lacks "unreviewed changes" "CLAUDE.md"
df_ok init --yes --profile flows
df_ok status
has_line "profile: flows"
[[ "$(cat "$CM")" == "$EDITED_CM" ]] || fail "switching back lost the edit"
[[ "$(jq -r .model "$CS")" == mine ]] || fail "switching back lost the saved value"
agree "~/.claude/CLAUDE.md"
df_ok pull --force "$CM"
clean
pass "away and back, edits kept"

# ---------------------------------------------------------------------------
info "Flow 5: checkout a tag and back, with an edit held across"
echo "# held across" >> "$CM"
EDITED_CM=$(cat "$CM")
df_ok checkout v1
has_line "Pinned to v1"
[[ "$(cat "$CM")" == "$EDITED_CM" ]] || fail "checkout lost the edit"
has_line "kept your edit to $CM"
[[ "$(git -C "$R" rev-parse HEAD)" == "$(git -C "$R" rev-parse v1)" ]] || fail "not at v1"
cmp -s "$T/seed-r/apps/claude/files/CLAUDE.md" "$REC/claude/repo/CLAUDE.md" && fail "repo copy took v1's"
grep -qF "# repo change 3" "$R/apps/claude/files/CLAUDE.md" && fail "the tag has the later change"
df_ok status
has_line "pinned"
section_has conflicts "~/.claude/CLAUDE.md"
df_ok pull
has_line "pinned to v1"
[[ "$(cat "$CM")" == "$EDITED_CM" ]] || fail "a pinned pull lost the edit"
df_ok checkout main
has_line "Now following main"
[[ "$(cat "$CM")" == "$EDITED_CM" ]] || fail "checkout main lost the edit"
no_line "kept your edit"
df_ok status
has_line "conflicts: none"
agree "~/.claude/CLAUDE.md"
add d
df_ok status
section_has dismissed "~/.claude/CLAUDE.md"
df_ok pull --force "$CM"
clean
pass "pinned and back, the edit held all along"

# ---------------------------------------------------------------------------
info "Flow 6: reset"
echo "# before reset" >> "$SC"
jq '.flowLocal = 1' "$CS" > "$T/cs" && cp "$T/cs" "$CS"
RC=0
OUT=$(printf '%s\n' "" "" "" "" yes reset | DOTFILES_INIT_ASSUME_TTY=1 "$R/dotfiles" init 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "reset failed ($RC): $OUT"
has_line "This would be lost:"
has_line "~/.local/bin/git-branch-clean"
has_line '["flowLocal"]'
has_line "local-only keys"
cmp -s "$HOST_SCRIPTS/git-branch-clean" "$SC" || fail "git-branch-clean is not the host layer's"
[[ "$(jq -c 'has("flowLocal")' "$CS")" == false ]] || fail "a local-only key survived the reset"
[[ "$(jq -r .model "$CS")" == mine ]] || fail "the profile layer's value is gone"
for f in CLAUDE.md settings.json settings.local.json; do
    recorded claude "$f" "$HOME/.claude/$f"
done
recorded scripts git-branch-clean "$SC"
grep -rqF "# before reset" "$HOME/.bak/scripts" || fail "no snapshot before the reset"
grep -rqF "flowLocal" "$HOME/.bak/claude" || fail "no snapshot of the merged file"
clean
pass "reset to the layers, snapshotted, clean"

# ---------------------------------------------------------------------------
info "Flow 7: uninstall, reinstall, and the original restored"
echo "# before uninstall" >> "$SC"
df_ok uninstall
has_line "$SC"
[[ "$(cat "$CM")" == "my original" ]] || fail "CLAUDE.md original not restored: $(cat "$CM")"
[[ ! -e "$SC" && ! -e "$HOME/.gitconfig" ]] || fail "deployed files left behind"
grep -qF 'name = flow' "$HOME/.gitconfig.local" || fail ".gitconfig.local changed"
[[ ! -e "$REC/claude" && ! -e "$REC/scripts" && ! -e "$STATE/apps/claude.yaml" ]] || fail "records or state left behind"
grep -rqF "# before uninstall" "$HOME/.bak/scripts" || fail "no snapshot before uninstall"
df_ok pull
cmp -s "$REC/claude/repo/CLAUDE.md" "$CM" || fail "reinstall didn't deploy CLAUDE.md"
[[ "$(cat "$HOME/.bak/claude/original/CLAUDE.md")" == "my original" ]] || fail "the original changed"
clean
df_ok uninstall
[[ "$(cat "$CM")" == "my original" ]] || fail "second uninstall didn't restore the original"
pass "originals restored, twice"

# ---------------------------------------------------------------------------
# The same core on a host with no git: its repos are pushed copies, and git isn't installed
# ---------------------------------------------------------------------------
RH="$T/rhome"
RBIN="$T/rbin"
mkdir -p "$RH" "$RBIN"
cp "$T/bin/claude" "$T/bin/lazygit" "$T/bin/sudo" "$RBIN/"
printf '#!/bin/sh\necho "git: not installed" >&2\nexit 127\n' > "$RBIN/git"
chmod +x "$RBIN/"*
# Runs the command here as the remote would: its own HOME, nothing of this shell's
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 && "\$1" == -* ]]; do
    case "\$1" in
        -o|-p|-i) shift 2 ;;
        *) shift ;;
    esac
done
shift
exec env -i HOME="$RH" PATH="$RBIN:/usr/local/bin:/usr/bin:/bin" TERM=dumb bash -c "\$*"
EOF
cat > "$T/bin/scp" <<'EOF'
#!/usr/bin/env bash
files=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) shift 2 ;;
        -*) shift ;;
        *) files+=("$1"); shift ;;
    esac
done
dest="${files[-1]}"
unset 'files[-1]'
cp "${files[@]}" "${dest#*:}"
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp"
RDF="$RH/.local/share/dotfiles/dotfiles/dotfiles"
RSC="$RH/.local/bin/git-branch-clean"
RCM="$RH/.claude/CLAUDE.md"
on_host() {
    RC=0
    OUT=$(env -i HOME="$RH" PATH="$RBIN:/usr/local/bin:/usr/bin:/bin" TERM=dumb "$@" 2>&1 </dev/null) || RC=$?
}
host_status() {
    on_host "$RDF" status
    [[ $RC -eq 0 ]] || fail "remote status failed: $OUT"
}

info "No git: init --remote"
# The local repos as they are now
git -C "$R" pull -q --ff-only
git -C "$H" pull -q --ff-only
df_ok init --remote --yes --hostname fh user@nogit
[[ -f "$RH/.local/share/dotfiles/dotfiles/PUSHED" ]] || fail "not pushed"
[[ ! -e "$RH/.local/share/dotfiles/dotfiles/.git" ]] || fail "the pushed copy has git"
cmp -s "$HOST_SCRIPTS/git-branch-clean" "$RSC" || fail "scripts not deployed there"
[[ -s "$RH/.config/dotfiles/records/scripts/manifest.tsv" ]] || fail "no records there"
host_status
has_line "(pushed: "
has_line "unreviewed changes: none"
has_line "conflicts: none"
has_line "uncommitted files: none"
pass "set up"

info "No git: a local edit there survives pull --remote"
echo "# remote edit" >> "$RCM"
EDITED_RCM=$(cat "$RCM")
other r2 apps/scripts/files/extract "# repo change 4"
git -C "$R" pull -q --ff-only
df_ok pull --remote user@nogit
[[ "$(cat "$RCM")" == "$EDITED_RCM" ]] || fail "pull --remote lost the edit"
grep -qF "# repo change 4" "$RH/.local/bin/extract" || fail "the update didn't arrive"
has_line "local edits"
host_status
section_has "unreviewed changes" "~/.claude/CLAUDE.md"
pass "kept"

info "No git: a conflict shows here, and add there offers only dismiss"
other r2 apps/claude/files/CLAUDE.md "# repo change 5"
git -C "$R" pull -q --ff-only
df_ok pull --remote user@nogit
[[ "$(cat "$RCM")" == "$EDITED_RCM" ]] || fail "the conflict lost the edit"
has_line "kept your edit to $RCM"
host_status
section_has conflicts "~/.claude/CLAUDE.md"
RC=0
OUT=$(printf 's\nd\n' | env -i HOME="$RH" PATH="$RBIN:/usr/local/bin:/usr/bin:/bin" TERM=dumb DOTFILES_ADD_ASSUME_TTY=1 "$RDF" add 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "remote add failed: $OUT"
has_line "Dismiss or skip?"
has_line "Not an option: s"
no_line "Staged"
host_status
has_line "conflicts: none"
section_has dismissed "~/.claude/CLAUDE.md"
df_ok pull --remote user@nogit
no_line "kept your edit"
[[ "$(cat "$RCM")" == "$EDITED_RCM" ]] || fail "the dismissed edit went"
pass "conflict, dismissed there, kept"

info "No git: pull --remote --force takes every file, with a snapshot"
df_ok pull --remote --force user@nogit
grep -qF "# repo change 5" "$RCM" || fail "--force did not take the repo's"
! grep -qF "# remote edit" "$RCM" || fail "the edit is still there"
grep -rqF "# remote edit" "$RH/.bak/claude" || fail "no snapshot there"
host_status
has_line "unreviewed changes: none"
has_line "dismissed: none"
has_line "conflicts: none"
pass "forced, snapshotted, clean"

info "No git: uninstall there"
on_host "$RDF" uninstall
[[ $RC -eq 0 ]] || fail "remote uninstall failed: $OUT"
[[ ! -e "$RSC" && ! -e "$RCM" ]] || fail "files left there"
pass "uninstalled"

echo
echo -e "${GREEN}All flow tests passed${NC}"
