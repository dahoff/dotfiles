#!/usr/bin/env bash
# test-hosts.sh - setup.sh with a dotfiles-hosts repo (resolution and overlays)

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
echo "Hosts Repo Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_REPO
TEST_STATE="/tmp/dotfiles-test-hoststest"
TEST_HOME="/tmp/home-test-hoststest"
HR="/tmp/hosts-repo-hoststest"
rm -rf "$TEST_STATE" "$TEST_HOME" "$HR"
mkdir -p "$TEST_STATE/apps" "$TEST_HOME"
cp -R "$TEST_DIR/fixtures/hosts-repo" "$HR"
export STATE_DIR="$TEST_STATE"
export HOME="$TEST_HOME"
cd "$ROOT_DIR"

# Run setup.sh, capture output and exit code in OUT / RC
run() {
    RC=0
    OUT=$(./setup.sh "$@" 2>&1) || RC=$?
}
packages_line() { echo "$OUT" | grep -o 'Packages: .*' | head -1; }

# Test 1
info "Test 1: no hosts repo keeps today's resolution"
run deploy --dry-run --hostname testhost
[[ $RC -eq 0 ]] || fail "dry-run failed: $OUT"
[[ "$(packages_line)" == "Packages: git bash tmux vim curl fzf jq tree lazygit lazyssh scripts claude" ]] \
    || fail "package list changed: $(packages_line)"
[[ "$OUT" != *"Host directory"* ]] || fail "no host directory without hosts repo"
pass "unchanged without hosts repo"

# Test 2
info "Test 2: hosts-repo profile extending its own name continues in dotfiles"
run deploy --dry-run --hosts-repo "$HR" --hostname nohost --profile minimal
[[ $RC -eq 0 ]] || fail "dry-run failed: $OUT"
[[ "$(packages_line)" == "Packages: git bash tmux vim curl fzf jq scripts" ]] \
    || fail "expected dotfiles minimal minus tree: $(packages_line)"
pass "lookup order and self-extend"

# Test 3
info "Test 3: profile only in dotfiles is found"
run deploy --dry-run --hosts-repo "$HR" --hostname nohost --profile complete
[[ "$(packages_line)" == "Packages: git bash tmux vim curl fzf jq tree lazygit lazyssh scripts claude" ]] \
    || fail "fallback: $(packages_line)"
pass "dotfiles fallback"

# Test 4
info "Test 4: host directory selects profile"
run deploy --dry-run --hosts-repo "$HR" --hostname testhost
[[ "$OUT" == *"Using profile 'base'"* ]] || fail "host.yaml profile not used"
[[ "$OUT" == *"Host directory: hosts/testhost"* ]] || fail "host directory not reported"
[[ "$(packages_line)" == "Packages: claude scripts" ]] || fail "packages: $(packages_line)"
pass "host.yaml profile"

# Test 5
info "Test 5: --profile overrides host.yaml with a warning"
run deploy --dry-run --hosts-repo "$HR" --hostname testhost --profile minimal
[[ "$OUT" == *"overrides profile 'base'"* ]] || fail "no override warning"
[[ "$OUT" == *"Using profile 'minimal'"* ]] || fail "--profile did not win"
pass "--profile wins"

# Test 6
info "Test 6: host.yaml exclude and extra"
run deploy --dry-run --hosts-repo "$HR" --hostname excludehost
[[ "$(packages_line)" == "Packages: claude vim" ]] || fail "exclude/extra: $(packages_line)"
pass "host.yaml exclude/extra"

# Test 7
info "Test 7: env DOTFILES_HOSTS_REPO works like --hosts-repo"
OUT=$(DOTFILES_HOSTS_REPO="$HR" ./setup.sh deploy --dry-run --hostname testhost 2>&1) || fail "env run failed"
[[ "$(packages_line)" == "Packages: claude scripts" ]] || fail "env not honored"
pass "env hosts repo"

# Test 8
info "Test 8: missing hosts repo aborts before changes"
run deploy --hosts-repo /tmp/does-not-exist-hosts --hostname testhost
[[ $RC -ne 0 ]] || fail "should abort"
[[ ! -d "$HOME/.claude" ]] || fail "changes were made"
pass "missing hosts repo aborts"

# Test 9
info "Test 9: host.yaml without profile: aborts"
run deploy --dry-run --hosts-repo "$HR" --hostname noprofile
[[ $RC -ne 0 && "$OUT" == *"has no 'profile:'"* ]] || fail "should abort on missing profile:"
pass "missing profile: aborts"

# Test 10
info "Test 10: unknown profile aborts"
run deploy --dry-run --hosts-repo "$HR" --hostname nohost --profile nope
[[ $RC -ne 0 && "$OUT" == *"Profile not found"* ]] || fail "should abort on unknown profile"
pass "unknown profile aborts"

# Test 11
info "Test 11: extends cycle aborts"
run deploy --dry-run --hosts-repo "$HR" --hostname nohost --profile cycle-a
[[ $RC -ne 0 && "$OUT" == *"extends cycle"* ]] || fail "cycle not detected: $(echo "$OUT" | tail -3)"
pass "cycle detected"

# Test 12
info "Test 12: host directory without host.yaml is ignored with a warning"
run deploy --dry-run --hosts-repo "$HR" --hostname nohostyaml --profile base
[[ $RC -eq 0 && "$OUT" == *"no host.yaml"* ]] || fail "no warning for hosts/nohostyaml"
[[ "$OUT" != *"Host directory"* ]] || fail "directory without host.yaml was used"
pass "host dir without host.yaml ignored"

# Test 13
info "Test 13: --hostname with --hosts-file is rejected"
run deploy --hosts-file /tmp/x.yaml --hostname a
[[ $RC -ne 0 ]] || fail "should reject --hostname with --hosts-file"
pass "--hostname/--hosts-file exclusive"

# (Task 6 adds overlay tests here)

rm -rf "$TEST_STATE" "$TEST_HOME" "$HR"
echo
echo "======================================"
echo -e "${GREEN}All hosts repo tests passed!${NC}"
echo "======================================"
