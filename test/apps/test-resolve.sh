#!/usr/bin/env bash
# test-resolve.sh - tool names in profiles: apps/ folders, os-packages.yaml, inline entries

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
echo "Tool Resolution Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_DIR
T="/tmp/dotfiles-test-resolve-$$"
trap 'rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home" "$T/state/apps" "$T/hosts/profiles"
export HOME="$T/home"
export STATE_DIR="$T/state"
export XDG_STATE_HOME="$T/xdg-state"
export DOTFILES_CONFIG="$T/config"
: > "$DOTFILES_CONFIG"
HD="$T/hosts"

# The code under test, copied without .git so sync never pulls the real checkout
DF="$T/dotfiles"
mkdir -p "$DF"
(cd "$ROOT_DIR" && tar --exclude=.git -cf - .) | (cd "$DF" && tar -xf -)
A="$DF/apps"

cat > "$A/os-packages.yaml" <<'EOF'
packages:
  - onepkg   # the same name everywhere
  - name: twopkg
    apt: two-apt
    dnf: two-dnf
    brew: two-brew
  - unlisted
  - bothplaces
EOF

# OS packages only
mkdir -p "$A/foldertool"
cat > "$A/foldertool/config.yaml" <<'EOF'
install:
  apt: folder-apt
  dnf: folder-dnf
  brew: folder-brew
EOF

# Defined twice
mkdir -p "$A/bothplaces"
echo 'install:' > "$A/bothplaces/config.yaml"

# Tool only: install.sh and a drop-in, no configure.sh
mkdir -p "$A/toolonly/files"
cat > "$A/toolonly/config.yaml" <<'EOF'
install:
  check: test -e "$HOME/toolonly-installed"
  dropin: files/50-toolonly.sh
EOF
printf '#!/bin/sh\ntouch "$HOME/toolonly-installed"\n' > "$A/toolonly/install.sh"
chmod +x "$A/toolonly/install.sh"
echo '# toolonly drop-in' > "$A/toolonly/files/50-toolonly.sh"

# install.sh with no check
mkdir -p "$A/nocheck"
echo 'install:' > "$A/nocheck/config.yaml"
printf '#!/bin/sh\nexit 0\n' > "$A/nocheck/install.sh"
chmod +x "$A/nocheck/install.sh"

# Config only, with flags; configure.sh records its arguments
mkdir -p "$A/flagapp"
cat > "$A/flagapp/config.yaml" <<'EOF'
install:
  configure_flags: --append
EOF
printf '#!/bin/sh\necho "$@" > "$HOME/flagapp-args"\n' > "$A/flagapp/configure.sh"
chmod +x "$A/flagapp/configure.sh"

# The real installer, with install: above files:
mkdir -p "$A/deployapp/files"
cat > "$A/deployapp/config.yaml" <<'EOF'
install:
  apt: deploy-apt

app:
  name: deployed-name
  description: test app

files:
  - src: one.conf
    dest: ~/.deploy-one
    mode: '0644'
  - src: two.conf
    dest: ~/.deploy-two
    mode: '0644'

backup:
  dir: ~/.bak/deployapp
  max_backups: 3
EOF
echo one > "$A/deployapp/files/one.conf"
echo two > "$A/deployapp/files/two.conf"
cp "$A/vim/configure.sh" "$A/deployapp/configure.sh"

OUT=""
RC=0
profile() { cat > "$HD/profiles/$1.yaml"; }
# Dry run of a profile on a host with no host.yaml, or of HOST with host.yaml
dry() {
    RC=0
    OUT=$("$DF/dotfiles" sync --dry-run --no-pull --hosts-dir "$HD" --hostname "${2:-nohost}" ${1:+--profile "$1"} 2>&1) || RC=$?
}
packages() { grep -o 'Packages: .*' <<< "$OUT" | head -1 | sed 's/^Packages: //'; }
expect_packages() {
    [[ $RC -eq 0 ]] || fail "$1: exit $RC: $OUT"
    [[ "$(packages)" == "$2" ]] || fail "$1: expected '$2', got '$(packages)'"
}
expect_abort() {
    [[ $RC -ne 0 ]] || fail "$1: expected failure: $OUT"
    grep -qF -- "$2" <<< "$OUT" || fail "$1: no '$2' in: $OUT"
    grep -q 'Phase 1' <<< "$OUT" && fail "$1: reached the install phases: $OUT"
    true
}
# The package manager decides which package name is expected
PM=apt
if ! command -v apt-get >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then PM=dnf; elif command -v brew >/dev/null 2>&1; then PM=brew; fi
fi
sane_home() { [[ -z "$(find "$HOME" -mindepth 1 -print -quit)" ]]; }

info "Case 1: names from a folder, one-line and long os-packages entries"
profile names <<'EOF'
packages:
  - foldertool
  - onepkg
  - twopkg
EOF
dry names
expect_packages "1" "foldertool onepkg twopkg"
grep -qw "folder-$PM" <<< "$OUT" || fail "1: folder package name not used: $OUT"
grep -qw "onepkg" <<< "$(grep -i 'would\|install' <<< "$OUT")" || fail "1: one-line package not installed: $OUT"
grep -qw "two-$PM" <<< "$OUT" || fail "1: long-form package name not used: $OUT"
sane_home || fail "1: dry run wrote under HOME: $(find "$HOME" -mindepth 1)"
pass "folder, one-line and long-form entries resolve"

info "Case 2: a defined tool that nothing lists is not selected"
grep -qw unlisted <<< "$OUT" && fail "2: unlisted tool selected: $OUT"
pass "defining a tool does not select it"

info "Case 3: unknown names abort before any change, naming the tool and the file"
profile typo <<'EOF'
packages:
  - tmuxx
EOF
dry typo
expect_abort "3a" "tmuxx"
grep -qF "profiles/typo.yaml" <<< "$OUT" || fail "3a: file not named: $OUT"
mkdir -p "$HD/hosts/typohost"
cat > "$HD/hosts/typohost/host.yaml" <<'EOF'
profile: names
extra:
  - vimm
EOF
dry "" typohost
expect_abort "3b" "vimm"
grep -qF "hosts/typohost/host.yaml" <<< "$OUT" || fail "3b: real file not named: $OUT"
sane_home || fail "3: wrote under HOME: $(find "$HOME" -mindepth 1)"
pass "unknown names abort"

info "Case 4: a plain name with a slash is unknown, not a path"
profile slash <<'EOF'
packages:
  - ../apps/foldertool
EOF
dry slash
expect_abort "4" "../apps/foldertool"
pass "slash in a name refused"

info "Case 5: defined in a folder and in os-packages.yaml aborts"
profile both <<'EOF'
packages:
  - bothplaces
EOF
dry both
expect_abort "5" "bothplaces"
pass "defined twice aborts"

info "Case 6: install.sh with no check aborts"
profile nocheck <<'EOF'
packages:
  - nocheck
EOF
dry nocheck
expect_abort "6" "nocheck"
pass "missing check aborts"

info "Case 7: a long-form entry with only a name, or an unreadable item, aborts"
profile bare <<'EOF'
packages:
  - name: tmux
EOF
dry bare
expect_abort "7a" "tmux"
profile badline <<'EOF'
packages:
  - nam: tmux
EOF
dry badline
expect_abort "7b" "nam: tmux"
pass "empty and unreadable entries abort"

info "Case 8: an inline entry replaces a folder definition, with no merging"
profile inline <<'EOF'
packages:
  - name: foldertool
    apt: inline-pkg
    dnf: inline-pkg
    brew: inline-pkg
  - onepkg
EOF
dry inline
expect_packages "8" "foldertool onepkg"
grep -qw inline-pkg <<< "$OUT" || fail "8: inline package not used: $OUT"
grep -qw "folder-$PM" <<< "$OUT" && fail "8: folder definition merged: $OUT"
pass "inline replaces"

info "Case 9: a tool listed twice is processed once, at its first position"
profile dup-base <<'EOF'
packages:
  - onepkg
  - twopkg
EOF
mkdir -p "$HD/hosts/duphost"
cat > "$HD/hosts/duphost/host.yaml" <<'EOF'
profile: dup-base
extra:
  - onepkg
  - foldertool
EOF
dry "" duphost
expect_packages "9a" "onepkg twopkg foldertool"
mkdir -p "$HD/hosts/duphost2"
cat > "$HD/hosts/duphost2/host.yaml" <<'EOF'
profile: dup-base
extra:
  - name: onepkg
    apt: later-pkg
    dnf: later-pkg
    brew: later-pkg
EOF
dry "" duphost2
expect_packages "9b" "onepkg twopkg"
grep -qw later-pkg <<< "$OUT" || fail "9b: later definition not used: $OUT"
pass "duplicates collapse"

info "Case 10: include of a name not inherited aborts; exclude of an absent name does not"
profile inc-bad <<'EOF'
extends: dup-base
include:
  - onepkgg
EOF
dry inc-bad
expect_abort "10a" "onepkgg"
profile inc-ok <<'EOF'
extends: dup-base
include:
  - twopkg
EOF
dry inc-ok
expect_packages "10b" "twopkg"
profile exc-absent <<'EOF'
extends: dup-base
exclude:
  - nosuchtool
EOF
dry exc-absent
expect_packages "10c" "onepkg twopkg"
pass "include checked, exclude not"

info "Case 11: a list after extra: is not read as tools, even after a custom: entry"
mkdir -p "$HD/hosts/orderhost"
cat > "$HD/hosts/orderhost/host.yaml" <<'EOF'
profile: dup-base
extra:
  - name: customtool
    custom:
      check: "true"
      script: toolonly/install.sh
exclude:
  - twopkg
EOF
dry "" orderhost
expect_packages "11" "onepkg customtool"
pass "sections end the list"

info "Case 12: no os-packages.yaml: folders resolve and unknown names still abort"
mv "$A/os-packages.yaml" "$T/os-packages.saved"
profile nofile <<'EOF'
packages:
  - foldertool
EOF
dry nofile
expect_packages "12a" "foldertool"
dry names
expect_abort "12b" "onepkg"
mv "$T/os-packages.saved" "$A/os-packages.yaml"
pass "missing os-packages.yaml is fine"

info "Case 13: a real sync: tool only, config only with flags, install: above files:"
profile realrun <<'EOF'
packages:
  - toolonly
  - flagapp
  - name: deployapp
    config:
      dir: deployapp
EOF
RC=0
OUT=$("$DF/dotfiles" sync --no-pull --no-backup --hosts-dir "$HD" --hostname nohost --profile realrun 2>&1) || RC=$?
[[ $RC -eq 0 ]] || fail "13: sync failed: $OUT"
[[ -e "$HOME/toolonly-installed" ]] || fail "13: install.sh not run: $OUT"
[[ -f "$HOME/.bashrc.d/50-toolonly.sh" ]] || fail "13: drop-in not deployed: $OUT"
grep -q 'toolonly: ' <<< "$(grep -E 'toolonly: (deploy|upgrade|install)' <<< "$OUT")" && fail "13: config phase ran for toolonly: $OUT"
grep -qF -- "--append" "$HOME/flagapp-args" || fail "13: flags not passed: $(cat "$HOME/flagapp-args")"
[[ "$(cat "$HOME/.deploy-one")" == one && "$(cat "$HOME/.deploy-two")" == two ]] || fail "13: files not all deployed: $OUT"
[[ -f "$STATE_DIR/apps/deployed-name.yaml" ]] || fail "13: app.name lost: $(ls "$STATE_DIR/apps")"
pass "phases follow what the folder holds"

echo
echo -e "${GREEN}All resolution tests passed${NC}"
