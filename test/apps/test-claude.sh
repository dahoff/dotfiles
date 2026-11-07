#!/usr/bin/env bash
# test-claude.sh - Claude module tests (settings.json merge strategy)

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
echo "Claude Module Tests"
echo "======================================"
echo

TEST_STATE="/tmp/dotfiles-test-claudetest"
TEST_HOME="/tmp/home-test-claudetest"
rm -rf "$TEST_STATE" "$TEST_HOME"
mkdir -p "$TEST_STATE/apps" "$TEST_HOME/.claude"
export STATE_DIR="$TEST_STATE"
export HOME="$TEST_HOME"
export XDG_STATE_HOME="$TEST_HOME/.xdg-state"
export DOTFILES_CONFIG="$TEST_HOME/nonexistent-config"

REPO_SETTINGS="$ROOT_DIR/apps/claude/files/settings.json"
LIVE="$HOME/.claude/settings.json"
cd "$ROOT_DIR/apps/claude"

state_version() { grep "^  version:" "$STATE_DIR/apps/claude.yaml" | awk '{print $2}'; }

# Test 1
info "Test 1: config declares merge for settings.json"
[[ "$(sed -n '/src: settings.json/,/src:/p' config.yaml)" == *"strategy: merge"* ]] \
    && pass "settings.json uses merge" || fail "settings.json strategy is not merge"

# Test 2
info "Test 2: deploy merges into an existing live file"
echo '{"model":"live-model","liveOnly":1,"enabledPlugins":{"x@y":true}}' > "$LIVE"
./configure.sh deploy --no-backup &>/dev/null || fail "deploy failed"
[[ "$(jq -r .liveOnly "$LIVE")" == 1 ]] || fail "unmanaged live key lost"
[[ "$(jq -c .enabledPlugins "$LIVE")" == '{"x@y":true}' ]] || fail "unmanaged live object lost"
[[ "$(jq -c .model "$LIVE")" == "$(jq -c .model "$REPO_SETTINGS")" ]] || fail "repo key not applied"
cmp -s "$HOME/.claude/statusline-command.sh" files/statusline-command.sh || fail "replace file not deployed"
pass "merge keeps live keys, applies repo keys"

# Test 3
info "Test 3: version is a content hash; redeploy is a no-op"
[[ "$(state_version)" =~ ^[0-9a-f]{12}$ ]] || fail "version: $(state_version)"
out=$(./configure.sh deploy --no-backup 2>&1) || fail "redeploy failed"
[[ "$out" == *"already up to date"* ]] || fail "redeploy should skip"
pass "content-hash version"

# Test 4
info "Test 4: diff of a merged file compares against the merge result"
out=$(./configure.sh diff 2>&1) || true
[[ "$out" == *"No differences found"* ]] || fail "diff should be clean after deploy"
pass "merge-aware diff"

# Test 5
info "Test 5: invalid live JSON fails that file only, live untouched, retried next run"
echo '{oops' > "$LIVE"
cp "$LIVE" "$HOME/live.bak"
echo "# stale" > "$HOME/.claude/statusline-command.sh"
rc=0
./configure.sh upgrade --force --no-backup &>/dev/null || rc=$?
[[ $rc -ne 0 ]] || fail "upgrade should fail"
cmp -s "$LIVE" "$HOME/live.bak" || fail "live file was modified"
cmp -s "$HOME/.claude/statusline-command.sh" files/statusline-command.sh || fail "other files should still deploy"
[[ "$(state_version)" == incomplete ]] || fail "version should be 'incomplete', got $(state_version)"
echo '{"liveOnly":2}' > "$LIVE"
out=$(./configure.sh deploy --no-backup 2>&1) || fail "retry failed: $out"
[[ "$out" != *"already up to date"* ]] || fail "incomplete install was skipped"
[[ "$(jq -r .liveOnly "$LIVE")" == 2 ]] || fail "retry did not merge"
pass "per-file failure handled and retried"

# Test 6
info "Test 6: non-object live JSON fails and is left untouched"
echo '[]' > "$LIVE"
./configure.sh upgrade --force --no-backup &>/dev/null && fail "upgrade should fail on []"
[[ "$(cat "$LIVE")" == "[]" ]] || fail "live [] was modified"
pass "non-object rejected"

# Test 7
info "Test 7: empty live file is treated as absent"
: > "$LIVE"
./configure.sh upgrade --force --no-backup &>/dev/null || fail "upgrade failed on empty live file"
[[ "$(jq -c -S . "$LIVE")" == "$(jq -c -S . "$REPO_SETTINGS")" ]] || fail "empty live should become repo settings"
pass "empty live file handled"

# Test 8
info "Test 8: dry-run reports merge and changes nothing"
echo '{"liveOnly":3}' > "$LIVE"
# Snapshot dirs are named to the second: a new one must not land in an existing dir
sleep 1
HOME_BEFORE=$(find "$HOME" | sort)
STATE_BEFORE=$(find "$STATE_DIR" -type f -exec cat {} + 2>/dev/null)
out=$(./configure.sh upgrade --force --dry-run 2>&1) || fail "dry-run failed: $out"
[[ "$out" == *"Would merge"* ]] || fail "dry-run should say 'Would merge'"
[[ "$(cat "$LIVE")" == '{"liveOnly":3}' ]] || fail "dry-run modified live file"
[[ "$(find "$HOME" | sort)" == "$HOME_BEFORE" ]] || fail "dry-run wrote under HOME: $(diff <(echo "$HOME_BEFORE") <(find "$HOME" | sort))"
[[ "$(find "$STATE_DIR" -type f -exec cat {} + 2>/dev/null)" == "$STATE_BEFORE" ]] || fail "dry-run changed the app state"
pass "dry-run merge"

# Test 9
info "Test 9: missing jq fails the app with a clear message"
NOJQ="$HOME/nojq-bin"
mkdir -p "$NOJQ"
for f in /usr/bin/* /bin/*; do
    [[ "$(basename "$f")" == jq ]] && continue
    ln -sf "$f" "$NOJQ/" 2>/dev/null || true
done
out=$(PATH="$NOJQ" ./configure.sh upgrade --force --no-backup 2>&1) && fail "should fail without jq"
[[ "$out" == *"jq is required"* ]] || fail "message was: $out"
[[ "$(cat "$LIVE")" == '{"liveOnly":3}' ]] || fail "live file changed without jq"
pass "missing jq reported"

# Test 10
info "Test 10: a settings edit survives an upgrade, and a conflict is held per key"
echo '{"liveOnly":4}' > "$LIVE"
./configure.sh upgrade --force --no-backup &>/dev/null || fail "force failed"
jq '.model = "my-model"' "$LIVE" > "$HOME/edited" && cat "$HOME/edited" > "$LIVE"
RECORD="$STATE_DIR/records/claude/repo/settings.json"
# The repo's settings as a later version would have them, through a stage
STAGE="$HOME/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/files"
cp -R files/. "$STAGE/files/"
jq '.model = "repo-model-2" | .newKey = 1' files/settings.json > "$STAGE/files/settings.json"
sed -n 's/^  - src: \(.*\)$/\1 replace/p' config.yaml > "$STAGE/strategies"
sed -i 's/^settings.json replace$/settings.json merge/' "$STAGE/strategies"
: > "$STAGE/skip"
echo stage-v2 > "$STAGE/version"
KEPT="$HOME/kept"
: > "$KEPT"
out=$(DOTFILES_KEPT_FILE="$KEPT" ./configure.sh deploy --stage "$STAGE" --no-backup 2>&1) || fail "deploy failed: $out"
[[ "$(jq -r .model "$LIVE")" == my-model ]] || fail "edit overwritten"
[[ "$(jq -r .newKey "$LIVE")" == 1 ]] || fail "new key not applied"
[[ "$(jq -r .liveOnly "$LIVE")" == 4 ]] || fail "local-only key lost"
[[ "$(jq -r .model "$RECORD")" == "$(jq -r .model "$REPO_SETTINGS")" ]] || fail "repo copy took the held value"
[[ "$(cat "$KEPT")" == "$LIVE" ]] || fail "kept file: $(cat "$KEPT")"
[[ "$(state_version)" == conflict ]] || fail "version: $(state_version)"
[[ "$out" == *'["model"]'* ]] || fail "key not named: $out"
pass "conflict held per key"

./configure.sh uninstall &>/dev/null || true
[[ ! -d "$STATE_DIR/records/claude" ]] || fail "uninstall left the records"
rm -rf "$TEST_STATE" "$TEST_HOME"

echo
echo "======================================"
echo -e "${GREEN}All 10 claude module tests passed!${NC}"
echo "======================================"
