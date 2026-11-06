#!/usr/bin/env bash
# test-hosts.sh - dotfiles with a dotfiles-hosts dir (resolution and overlays)

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

unset DOTFILES_HOSTS_DIR
TEST_STATE="/tmp/dotfiles-test-hoststest"
TEST_HOME="/tmp/home-test-hoststest"
HR="/tmp/hosts-dir-hoststest"
rm -rf "$TEST_STATE" "$TEST_HOME" "$HR"
mkdir -p "$TEST_STATE/apps" "$TEST_HOME"
cp -R "$TEST_DIR/fixtures/hosts-dir" "$HR"
export STATE_DIR="$TEST_STATE"
export HOME="$TEST_HOME"
export XDG_STATE_HOME="$TEST_HOME/.xdg-state"
export DOTFILES_CONFIG="$TEST_HOME/nonexistent-config"
cd "$ROOT_DIR"

# Run dotfiles, capture output and exit code in OUT / RC
run() {
    RC=0
    OUT=$(./dotfiles "$@" 2>&1) || RC=$?
}
packages_line() { echo "$OUT" | grep -o 'Packages: .*' | head -1; }

# Test 0
info "Test 0: a dry run on a fresh install writes nothing under HOME"
mkdir -p "$TEST_HOME/.claude"
echo '{"liveOnly":1}' > "$TEST_HOME/.claude/settings.json"
run pull --dry-run --no-fetch --hostname testhost --hosts-dir "$HR"
[[ $RC -eq 0 ]] || fail "dry-run failed: $OUT"
WROTE=$(cd "$TEST_HOME" && find . -mindepth 1 | sort | tr '\n' ' ')
[[ "$WROTE" == "./.claude ./.claude/settings.json " ]] || fail "dry-run wrote under HOME: $WROTE"
rm -rf "$TEST_HOME/.claude"
pass "dry run left HOME untouched"

# Test 1
info "Test 1: no hosts dir keeps today's resolution"
run pull --dry-run --hostname testhost
[[ $RC -eq 0 ]] || fail "dry-run failed: $OUT"
[[ "$(packages_line)" == "Packages: git bash tmux vim curl fzf jq tree lazygit lazyssh scripts claude" ]] \
    || fail "package list changed: $(packages_line)"
[[ "$OUT" != *"Host directory"* ]] || fail "no host directory without hosts dir"
pass "unchanged without hosts dir"

# Test 2
info "Test 2: hosts-dir profile extending its own name continues in dotfiles"
run pull --dry-run --hosts-dir "$HR" --hostname nohost --profile minimal
[[ $RC -eq 0 ]] || fail "dry-run failed: $OUT"
[[ "$(packages_line)" == "Packages: git bash tmux vim curl fzf jq scripts" ]] \
    || fail "expected dotfiles minimal minus tree: $(packages_line)"
pass "lookup order and self-extend"

# Test 3
info "Test 3: profile only in dotfiles is found"
run pull --dry-run --hosts-dir "$HR" --hostname nohost --profile complete
[[ "$(packages_line)" == "Packages: git bash tmux vim curl fzf jq tree lazygit lazyssh scripts claude" ]] \
    || fail "fallback: $(packages_line)"
pass "dotfiles fallback"

# Test 4
info "Test 4: host directory selects profile"
run pull --dry-run --hosts-dir "$HR" --hostname testhost
[[ "$OUT" == *"Using profile 'base'"* ]] || fail "host.yaml profile not used"
[[ "$OUT" == *"Host directory: hosts/testhost"* ]] || fail "host directory not reported"
[[ "$(packages_line)" == "Packages: claude scripts" ]] || fail "packages: $(packages_line)"
pass "host.yaml profile"

# Test 5
info "Test 5: --profile overrides host.yaml with a warning"
run pull --dry-run --hosts-dir "$HR" --hostname testhost --profile minimal
[[ "$OUT" == *"overrides profile 'base'"* ]] || fail "no override warning"
[[ "$OUT" == *"Using profile 'minimal'"* ]] || fail "--profile did not win"
pass "--profile wins"

# Test 6
info "Test 6: host.yaml exclude and extra"
run pull --dry-run --hosts-dir "$HR" --hostname excludehost
[[ "$(packages_line)" == "Packages: claude vim" ]] || fail "exclude/extra: $(packages_line)"
pass "host.yaml exclude/extra"

# Test 7
info "Test 7: env DOTFILES_HOSTS_DIR works like --hosts-dir"
OUT=$(DOTFILES_HOSTS_DIR="$HR" ./dotfiles pull --dry-run --hostname testhost 2>&1) || fail "env run failed"
[[ "$(packages_line)" == "Packages: claude scripts" ]] || fail "env not honored"
pass "env hosts dir"

# Test 8
info "Test 8: missing hosts dir aborts before changes"
run pull --hosts-dir /tmp/does-not-exist-hosts --hostname testhost
[[ $RC -ne 0 ]] || fail "should abort"
[[ ! -d "$HOME/.claude" ]] || fail "changes were made"
pass "missing hosts dir aborts"

# Test 9
info "Test 9: host.yaml without profile: aborts"
run pull --dry-run --hosts-dir "$HR" --hostname noprofile
[[ $RC -ne 0 && "$OUT" == *"has no 'profile:'"* ]] || fail "should abort on missing profile:"
pass "missing profile: aborts"

# Test 10
info "Test 10: unknown profile aborts"
run pull --dry-run --hosts-dir "$HR" --hostname nohost --profile nope
[[ $RC -ne 0 && "$OUT" == *"Profile not found"* ]] || fail "should abort on unknown profile"
pass "unknown profile aborts"

# Test 11
info "Test 11: extends cycle aborts"
run pull --dry-run --hosts-dir "$HR" --hostname nohost --profile cycle-a
[[ $RC -ne 0 && "$OUT" == *"extends cycle"* ]] || fail "cycle not detected: $(echo "$OUT" | tail -3)"
pass "cycle detected"

# Test 12
info "Test 12: host directory without host.yaml is ignored with a warning"
run pull --dry-run --hosts-dir "$HR" --hostname nohostyaml --profile base
[[ $RC -eq 0 && "$OUT" == *"no host.yaml"* ]] || fail "no warning for hosts/nohostyaml"
[[ "$OUT" != *"Host directory"* ]] || fail "directory without host.yaml was used"
pass "host dir without host.yaml ignored"

# Test 13
info "Test 13: removed remote options are rejected"
run pull --host x
[[ $RC -ne 0 && "$OUT" == *"Unknown option"* ]] || fail "--host should be an unknown option: $OUT"
pass "--host rejected"

CL="$HOME/.claude"
seed_settings() {
    mkdir -p "$CL"
    echo '{"model":"live-model","liveOnly":1,"list":[0],"permissions":{"deny":["Bash(rm)"]}}' > "$CL/settings.json"
    echo '{"permissions":{"allow":["Live"]},"liveLocal":1}' > "$CL/settings.local.json"
}

# Test 14
info "Test 14: unknown overlay src aborts before changes"
run pull --no-backup --hosts-dir "$HR" --hostname typo
[[ $RC -ne 0 && "$OUT" == *"setings.json"* ]] || fail "typo overlay not rejected"
[[ ! -d "$CL" ]] || fail "changes were made"
pass "typo overlay aborts"

# Test 15
info "Test 15: merge on a non-JSON file aborts before changes"
run pull --no-backup --hosts-dir "$HR" --hostname mergetxt
[[ $RC -ne 0 && "$OUT" == *"requires a .json file"* ]] || fail "merge on .sh not rejected"
[[ ! -d "$CL" ]] || fail "changes were made"
pass "merge on non-JSON aborts"

# Test 16
info "Test 16: overlays for an excluded app warn and are ignored"
run pull --dry-run --hosts-dir "$HR" --hostname excludehost
[[ $RC -eq 0 && "$OUT" == *"Ignoring overlays for 'scripts'"* ]] || fail "no warning for excluded app overlay"
pass "excluded-app overlay warned"

# Test 17
info "Test 17: three-layer replace and merge with live file"
seed_settings
run pull --no-backup --hosts-dir "$HR" --hostname testhost
[[ $RC -eq 0 ]] || fail "deploy failed: $(echo "$OUT" | tail -20)"
[[ "$(cat "$CL/statusline-command.sh")" == "# host statusline" ]] || fail "host layer should win"
[[ "$(cat "$CL/tmux-notify.sh")" == "# profile notify" ]] || fail "profile layer should win over dotfiles"
S="$CL/settings.json"
[[ "$(jq -r .model "$S")" == profile-model ]] || fail "repo key should override live"
[[ "$(jq -r .liveOnly "$S")" == 1 ]] || fail "unmanaged live key lost"
[[ "$(jq -r .profileKey "$S")" == true ]] || fail "profile key missing"
[[ "$(jq -r .hostKey "$S")" == testhost ]] || fail "host key missing"
[[ "$(jq -c .list "$S")" == "[9]" ]] || fail "arrays should be replaced: $(jq -c .list "$S")"
[[ "$(jq -c -S .permissions "$S")" == '{"allow":["Bash(ls)"],"defaultMode":"plan","deny":["Bash(rm)"]}' ]] \
    || fail "objects should merge recursively: $(jq -c -S .permissions "$S")"
[[ "$(jq -r .statusLine.type "$S")" == command ]] || fail "dotfiles key missing"
cmp -s "$CL/settings.local.json" "$ROOT_DIR/apps/claude/files/settings.local.json" \
    || fail "host.yaml replace should override the profile's merge for settings.local.json"
pass "layers and merge correct"

# Test 18
info "Test 18: unchanged inputs skip; a hosts-dir change upgrades only that app"
run pull --no-backup --hosts-dir "$HR" --hostname testhost
[[ "$OUT" == *"claude is already up to date"* ]] || fail "claude should be up to date"
echo "# host statusline v2" > "$HR/hosts/testhost/apps/claude/files/statusline-command.sh"
run pull --no-backup --hosts-dir "$HR" --hostname testhost
[[ "$OUT" == *"claude upgraded successfully"* ]] || fail "hosts-dir change should upgrade claude"
[[ "$OUT" == *"scripts is already up to date"* ]] || fail "scripts should be untouched"
[[ "$(cat "$CL/statusline-command.sh")" == "# host statusline v2" ]] || fail "new overlay not deployed"
pass "content-hash upgrades"

# Test 19
info "Test 19: profile files: strategy applies when the host doesn't override it"
echo '{"liveLocal":1}' > "$CL/settings.local.json"
run pull --no-backup --hosts-dir "$HR" --hostname mergelocal
[[ $RC -eq 0 ]] || fail "deploy failed"
[[ "$(jq -r .liveLocal "$CL/settings.local.json")" == 1 ]] || fail "profile merge strategy not applied"
pass "profile strategy"

# Test 20
info "Test 20: invalid JSON in a layer fails that file only, reported in summary"
seed_settings
cp "$CL/settings.json" "$HOME/settings.before"
run pull --no-backup --hosts-dir "$HR" --hostname badjson
[[ $RC -ne 0 ]] || fail "deploy should report failure"
[[ "$OUT" == *"claude/settings.json: deploy FAILED"* ]] || fail "summary should name the file"
cmp -s "$CL/settings.json" "$HOME/settings.before" || fail "live settings.json modified"
[[ "$(cat "$CL/statusline-command.sh")" == "# profile statusline" ]] || fail "other claude files should deploy"
[[ "$(grep '^  version:' "$STATE_DIR/apps/claude.yaml" | awk '{print $2}')" == incomplete ]] \
    || fail "claude version should be incomplete"
pass "bad layer isolated"

# Test 21
info "Test 21: --hostname rejects path-like values"
for bad in "../x" "a/b" "." ".."  ""; do
    run pull --dry-run --hostname "$bad"
    [[ $RC -ne 0 ]] || fail "--hostname '$bad' accepted"
    [[ "$OUT" == *"invalid --hostname"* || "$OUT" == *"requires a name"* ]] || fail "no message for '$bad': $OUT"
done
pass "hostname validated"

# Test 22
info "Test 22: an extends profile's overlay reaches its hosts, and only its hosts"
mkdir -p "$HR/profiles/layered/apps/claude/files" "$HR/hosts/layeredhost" "$HR/hosts/plainhost"
cat > "$HR/profiles/cfgonly.yaml" <<'EOF'
packages:
  - name: claude
    config:
      dir: claude
EOF
echo 'extends: cfgonly' > "$HR/profiles/layered.yaml"
echo '# layered statusline' > "$HR/profiles/layered/apps/claude/files/statusline-command.sh"
echo 'profile: layered' > "$HR/hosts/layeredhost/host.yaml"
echo 'profile: cfgonly' > "$HR/hosts/plainhost/host.yaml"
# Each host gets its own HOME and state, so neither sees the other's deploy
for h in layeredhost plainhost; do
    mkdir -p "$TEST_HOME-$h" "$TEST_STATE-$h/apps"
    RC=0
    OUT=$(HOME="$TEST_HOME-$h" STATE_DIR="$TEST_STATE-$h" XDG_STATE_HOME="$TEST_HOME-$h/.xdg-state" \
        ./dotfiles pull --no-fetch --no-backup --hosts-dir "$HR" --hostname "$h" 2>&1) || RC=$?
    [[ $RC -eq 0 ]] || fail "$h: sync failed: $OUT"
done
[[ "$(cat "$TEST_HOME-layeredhost/.claude/statusline-command.sh")" == "# layered statusline" ]] \
    || fail "extends profile's overlay not deployed"
cmp -s "$TEST_HOME-plainhost/.claude/statusline-command.sh" "$ROOT_DIR/apps/claude/files/statusline-command.sh" \
    || fail "a host on another profile should keep the base file"
rm -rf "$TEST_HOME-layeredhost" "$TEST_STATE-layeredhost" "$TEST_HOME-plainhost" "$TEST_STATE-plainhost"
pass "overlay limited to the extends profile's hosts"

# Test 23: the shape of personal -> complete. A dry run can't show the deployed
# file, but a misnamed overlay only aborts if this profile's layer is in use.
info "Test 23: a profile extending complete contributes its overlay layer"
mkdir -p "$HR/profiles/oncomplete/apps/claude/files"
echo 'extends: complete' > "$HR/profiles/oncomplete.yaml"
run pull --dry-run --no-fetch --hosts-dir "$HR" --hostname nohost --profile oncomplete
[[ $RC -eq 0 ]] || fail "extends complete failed: $OUT"
[[ "$(packages_line)" == "Packages: git bash tmux vim curl fzf jq tree lazygit lazyssh scripts claude" ]] \
    || fail "extends complete changed the list: $(packages_line)"
echo '# wrong name' > "$HR/profiles/oncomplete/apps/claude/files/statusbar.sh"
run pull --dry-run --no-fetch --hosts-dir "$HR" --hostname nohost --profile oncomplete
[[ $RC -ne 0 && "$OUT" == *"statusbar.sh"* ]] || fail "overlay layer of a profile extending complete not used: $OUT"
pass "extends complete keeps the profile's layer"

rm -rf "$TEST_STATE" "$TEST_HOME" "$HR"
echo
echo "======================================"
echo -e "${GREEN}All hosts dir tests passed!${NC}"
echo "======================================"
