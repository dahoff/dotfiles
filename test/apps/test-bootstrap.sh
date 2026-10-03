#!/usr/bin/env bash
# test-bootstrap.sh - bootstrap.sh: install git, clone/pull dotfiles, run init

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$TEST_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }

echo "======================================"
echo "Bootstrap Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR DOTFILES_REPO_URL DOTFILES_DIR DOTFILES_BOOTSTRAP_DRY
T="/tmp/dotfiles-test-bootstrap-$$"
trap 'rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home" "$T/state" "$T/nosudo"
export HOME="$T/home"
export STATE_DIR="$T/state"
export XDG_STATE_HOME="$T/xdg-state"
export DOTFILES_CONFIG="$T/config.yaml"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_TERMINAL_PROMPT=0
export DOTFILES_BOOTSTRAP_NO_TTY=1
: > "$GIT_CONFIG_GLOBAL"
# A sudo that always fails, so nothing can reach the real sudo
printf '#!/bin/sh\nexit 1\n' > "$T/nosudo/sudo"
chmod +x "$T/nosudo/sudo"
export PATH="$T/nosudo:$PATH"

# Bare origin holding the code currently on disk
ORIGIN="$T/origin.git"
git clone -q --bare "$ROOT_DIR" "$ORIGIN"
git clone -q "$ORIGIN" "$T/work"
git -C "$T/work" config user.name tester
git -C "$T/work" config user.email tester@example.com
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude .git "$ROOT_DIR"/ "$T/work"/
else
    (cd "$ROOT_DIR" && tar --exclude=.git -cf - .) | (cd "$T/work" && tar -xf -)
fi
git -C "$T/work" add -A
git -C "$T/work" commit -q --allow-empty -m wip
git -C "$T/work" push -q origin HEAD
URL="file://$ORIGIN"

RC=0
OUT=""
run() { RC=0; OUT=$(bash "$ROOT_DIR/bootstrap.sh" "$@" 2>&1 </dev/null) || RC=$?; }

# 1. fresh clone + init (--no-sync: assert checkout and config only)
run --repo "$URL" --dir "$HOME/df" -- --no-sync --hosts-dir none
[[ $RC -eq 0 ]] || fail "1: exit $RC: $OUT"
[[ -x "$HOME/df/dotfiles" ]] || fail "1: dotfiles not executable"
[[ -f "$DOTFILES_CONFIG" ]] || fail "1: config not written"
pass "fresh clone runs init and writes config"

# 2. re-run pulls
run --repo "$URL" --dir "$HOME/df" -- --no-sync --hosts-dir none
[[ $RC -eq 0 ]] || fail "2: exit $RC: $OUT"
[[ "$OUT" == *pull* ]] || fail "2: no pull in output: $OUT"
[[ "$OUT" != *cloning* ]] || fail "2: re-cloned: $OUT"
pass "re-run pulls instead of cloning"

# 3. dir exists but is not a checkout
mkdir -p "$HOME/notrepo"
run --repo "$URL" --dir "$HOME/notrepo" -- --no-sync --hosts-dir none
[[ $RC -eq 1 ]] || fail "3: expected exit 1, got $RC: $OUT"
[[ "$OUT" == *"$HOME/notrepo"* ]] || fail "3: dir not named: $OUT"
pass "non-checkout dir is refused"

# 4. args without -- pass through
rm -f "$DOTFILES_CONFIG"
run --repo "$URL" --dir "$HOME/df" --no-sync --hosts-dir none --hostname bt
[[ $RC -eq 0 ]] || fail "4: exit $RC: $OUT"
grep -q '^hostname: .*bt' "$DOTFILES_CONFIG" || fail "4: hostname not written: $(cat "$DOTFILES_CONFIG")"
pass "arguments without -- reach init"

# 5. no git: dry run names the install command
NOGIT="$T/nogit"
mkdir -p "$NOGIT"
for d in /usr/bin /bin; do
    for f in "$d"/*; do
        n=$(basename "$f")
        [[ "$n" == git ]] && continue
        [[ -e "$NOGIT/$n" ]] || ln -s "$f" "$NOGIT/$n" 2>/dev/null || true
    done
done
RC=0
OUT=$(DOTFILES_BOOTSTRAP_DRY=1 PATH="$NOGIT" bash "$ROOT_DIR/bootstrap.sh" 2>&1 </dev/null) || RC=$?
if [[ -e "$NOGIT/apt-get" || -e "$NOGIT/dnf" || -e "$NOGIT/brew" ]]; then
    [[ $RC -eq 0 ]] || fail "5: exit $RC: $OUT"
    [[ "$OUT" == *"would run:"* && "$OUT" == *install* && "$OUT" == *git* ]] || fail "5: $OUT"
else
    [[ $RC -eq 1 && "$OUT" == *"git is required"* ]] || fail "5: no pkg mgr: $RC $OUT"
fi
pass "missing git prints the install command (dry run)"

# 6. piped from curl: no tty, falls back to --yes
rm -f "$DOTFILES_CONFIG"
RC=0
OUT=$(cat "$ROOT_DIR/bootstrap.sh" | bash -s -- --repo "$URL" --dir "$HOME/df2" --no-sync --hosts-dir none 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "6: exit $RC: $OUT"
[[ -f "$DOTFILES_CONFIG" ]] || fail "6: config not written"
pass "piped run falls back to --yes"

# 7. piped run where git drains stdin (as a credential helper or debconf might)
REALGIT=$(command -v git)
mkdir -p "$T/drain"
cat > "$T/drain/git" <<EOS
#!/bin/sh
case "\$*" in *clone*) cat >/dev/null ;; esac
exec "$REALGIT" "\$@"
EOS
chmod +x "$T/drain/git"
rm -f "$DOTFILES_CONFIG"
RC=0
OUT=$(cat "$ROOT_DIR/bootstrap.sh" | PATH="$T/drain:$PATH" bash -s -- --repo "$URL" --dir "$HOME/df3" --no-sync --hosts-dir none 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "7: exit $RC: $OUT"
[[ -f "$DOTFILES_CONFIG" ]] || fail "7: config not written (script swallowed?): $OUT"
pass "piped run survives a child that reads stdin"

# 8. plain dir inside another checkout is not a checkout
mkdir -p "$HOME/df/sub"
run --repo "$URL" --dir "$HOME/df/sub" -- --no-sync --hosts-dir none
[[ $RC -eq 1 && "$OUT" == *"$HOME/df/sub"* ]] || fail "8: expected exit 1 naming dir, got $RC: $OUT"
pass "subdirectory of a checkout is refused"

# 9. --dir names a regular file
: > "$HOME/afile"
run --repo "$URL" --dir "$HOME/afile" -- --no-sync --hosts-dir none
[[ $RC -eq 1 && "$OUT" == *"$HOME/afile exists and is not a git checkout"* ]] \
    || fail "9: expected exit 1 naming the file, got $RC: $OUT"
[[ "$OUT" != *updating* ]] || fail "9: took the update path: $OUT"
pass "a regular file as --dir is refused"

echo
echo "All bootstrap tests passed"
