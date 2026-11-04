#!/usr/bin/env bash
# test-overlay.sh - Unit tests for lib/overlay.sh and lib/hosts.sh

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
echo "Overlay / Hosts Library Tests"
echo "======================================"
echo

source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/overlay.sh"
source "$ROOT_DIR/lib/hosts.sh"

T="/tmp/dotfiles-test-overlay"
rm -rf "$T"
mkdir -p "$T"

APP="$T/repo/demo"
P1="$T/p1"
H1="$T/h1"
NONE="$T/no-strategies"
: > "$NONE"

mkdir -p "$APP/files" "$P1/apps/demo/files" "$H1/apps/demo/files"
cat > "$APP/config.yaml" << 'EOF'
app:
  name: demo
files:
  - src: a.json
    dest: ~/a.json
    mode: '0644'
    strategy: merge
  - src: b.txt
    dest: ~/b.txt
    mode: '0644'
  - src: c.json
    dest: ~/c.json
    mode: '0644'
EOF
echo '{"base":1,"shared":"base","arr":[1,2],"obj":{"x":1}}' > "$APP/files/a.json"
echo 'base b' > "$APP/files/b.txt"
echo '{"c":"base","baseonly":1}' > "$APP/files/c.json"
echo '{"shared":"profile","obj":{"y":2}}' > "$P1/apps/demo/files/a.json"
echo 'profile b' > "$P1/apps/demo/files/b.txt"
echo '{"arr":[9],"host":true}' > "$H1/apps/demo/files/a.json"
echo 'host b' > "$H1/apps/demo/files/b.txt"
echo '{"c":"host"}' > "$H1/apps/demo/files/c.json"

jqc() { jq -c -S "$@"; }

# Test 1
info "Test 1: overlay_config_entries reads src and strategy"
expected=$'a.json\tmerge\nb.txt\treplace\nc.json\treplace'
[[ "$(overlay_config_entries "$APP/config.yaml")" == "$expected" ]] \
    && pass "config entries parsed" || fail "config entries wrong: $(overlay_config_entries "$APP/config.yaml")"

info "Test 1b: quoted strategy values are accepted"
printf 'files:\n  - src: q1.json\n    strategy: "merge"\n  - src: q2.json\n    strategy: '"'"'merge'"'"'  # c\n' > "$T/quoted.yaml"
[[ "$(overlay_config_entries "$T/quoted.yaml")" == $'q1.json\tmerge\nq2.json\tmerge' ]] \
    || fail "quoted strategies: $(overlay_config_entries "$T/quoted.yaml")"
pass "quoted strategies"

# Test 2
info "Test 2: overlay_json_merge merges objects, replaces arrays, later wins"
overlay_json_merge "$T/m.json" "$APP/files/a.json" "$P1/apps/demo/files/a.json" "$H1/apps/demo/files/a.json"
[[ "$(jqc . "$T/m.json")" == '{"arr":[9],"base":1,"host":true,"obj":{"x":1,"y":2},"shared":"profile"}' ]] \
    && pass "merge result correct" || fail "merge result: $(jqc . "$T/m.json")"

# Test 3
info "Test 3: overlay_json_merge into one of its inputs (live file)"
echo '{"live":1,"shared":"live"}' > "$T/live.json"
overlay_json_merge "$T/live.json" "$T/live.json" "$P1/apps/demo/files/a.json"
[[ "$(jqc . "$T/live.json")" == '{"live":1,"obj":{"y":2},"shared":"profile"}' ]] \
    && pass "in-place merge keeps live keys" || fail "in-place merge: $(jqc . "$T/live.json")"

# Test 4
info "Test 4: invalid JSON fails and leaves output untouched"
echo '{oops' > "$T/bad.json"
echo '{"keep":1}' > "$T/out.json"
if overlay_json_merge "$T/out.json" "$T/out.json" "$T/bad.json" 2>/dev/null; then
    fail "merge with invalid JSON should fail"
fi
[[ "$(cat "$T/out.json")" == '{"keep":1}' ]] && pass "invalid JSON rejected, output untouched" || fail "output modified"

# Test 5
info "Test 5: non-object JSON is rejected"
echo '[]' > "$T/arr.json"
if overlay_json_merge "$T/out.json" "$T/out.json" "$T/arr.json" 2>/dev/null; then
    fail "merge with a JSON array should fail"
fi
pass "non-object JSON rejected"

# Test 6
info "Test 6: missing jq fails with a clear message"
out=$( (PATH=/nonexistent; overlay_json_merge "$T/out.json" "$T/out.json" "$APP/files/a.json") 2>&1 ) && fail "should fail without jq"
[[ "$out" == *"jq is required"* ]] && pass "missing jq reported" || fail "message was: $out"

# Test 7
info "Test 7: stage with no layers copies dotfiles files"
overlay_stage_app "$APP" "$T/s0" "$NONE"
cmp -s "$T/s0/files/b.txt" "$APP/files/b.txt" || fail "b.txt not staged"
[[ "$(cat "$T/s0/strategies")" == $'a.json merge\nb.txt replace\nc.json replace' ]] || fail "strategies: $(cat "$T/s0/strategies")"
[[ "$(cat "$T/s0/version")" =~ ^[0-9a-f]{12}$ ]] || fail "version: $(cat "$T/s0/version")"
[[ ! -s "$T/s0/skip" ]] || fail "skip should be empty"
pass "no-layer stage correct"

# Test 8
info "Test 8: stage with profile and host layers"
overlay_stage_app "$APP" "$T/s1" "$NONE" "$P1" "$H1"
[[ "$(cat "$T/s1/files/b.txt")" == "host b" ]] || fail "replace should pick host layer"
[[ "$(jqc . "$T/s1/files/a.json")" == '{"arr":[9],"base":1,"host":true,"obj":{"x":1,"y":2},"shared":"profile"}' ]] \
    || fail "a.json: $(jqc . "$T/s1/files/a.json")"
[[ "$(jqc . "$T/s1/files/c.json")" == '{"c":"host"}' ]] || fail "c.json should be replaced by host layer"
pass "layered stage correct"

# Test 9
info "Test 9: strategy overrides, last declaration wins"
printf 'demo/c.json merge\n' > "$T/strat1"
overlay_stage_app "$APP" "$T/s2" "$T/strat1" "$P1" "$H1"
[[ "$(jqc . "$T/s2/files/c.json")" == '{"baseonly":1,"c":"host"}' ]] || fail "c.json merge: $(jqc . "$T/s2/files/c.json")"
printf 'demo/c.json merge\ndemo/c.json replace\n' > "$T/strat2"
overlay_stage_app "$APP" "$T/s3" "$T/strat2" "$P1" "$H1"
[[ "$(jqc . "$T/s3/files/c.json")" == '{"c":"host"}' ]] || fail "later replace should win"
pass "strategy precedence correct"

# Test 10
info "Test 10: version is stable, changes with a layer, ignores other apps"
overlay_stage_app "$APP" "$T/s4" "$NONE" "$P1" "$H1"
[[ "$(cat "$T/s1/version")" == "$(cat "$T/s4/version")" ]] || fail "version not stable"
mkdir -p "$T/repo/other/files" && echo x > "$T/repo/other/files/x"
overlay_stage_app "$APP" "$T/s5" "$NONE" "$P1" "$H1"
[[ "$(cat "$T/s1/version")" == "$(cat "$T/s5/version")" ]] || fail "unrelated app changed version"
echo 'host b2' > "$H1/apps/demo/files/b.txt"
overlay_stage_app "$APP" "$T/s6" "$NONE" "$P1" "$H1"
[[ "$(cat "$T/s1/version")" != "$(cat "$T/s6/version")" ]] || fail "layer change did not change version"
echo 'host b' > "$H1/apps/demo/files/b.txt"
echo '# installer v1' > "$APP/configure.sh"
overlay_stage_app "$APP" "$T/s8" "$NONE" "$P1" "$H1"
echo '# installer v2' > "$APP/configure.sh"
overlay_stage_app "$APP" "$T/s9" "$NONE" "$P1" "$H1"
[[ "$(cat "$T/s8/version")" != "$(cat "$T/s9/version")" ]] || fail "configure.sh change did not change version"
[[ "$(cat "$T/s1/version")" != "$(cat "$T/s8/version")" ]] || fail "configure.sh presence did not change version"
rm -f "$APP/configure.sh"
pass "version behaves"

# Test 11
info "Test 11: missing source in every layer fails the stage"
mv "$APP/files/b.txt" "$T/b.txt.bak"
if overlay_stage_app "$APP" "$T/s7" "$NONE" 2>/dev/null; then
    mv "$T/b.txt.bak" "$APP/files/b.txt"
    fail "stage should fail when no layer has b.txt"
fi
mv "$T/b.txt.bak" "$APP/files/b.txt"
pass "missing source detected"

# Test 12
info "Test 12: invalid JSON in a layer skips only that file"
mkdir -p "$T/hbad/apps/demo/files"
echo '{bad' > "$T/hbad/apps/demo/files/a.json"
overlay_stage_app "$APP" "$T/s8" "$NONE" "$T/hbad" 2>/dev/null || fail "stage should continue"
[[ "$(cat "$T/s8/skip")" == "a.json" ]] || fail "skip: $(cat "$T/s8/skip")"
[[ -f "$T/s8/files/b.txt" ]] || fail "other files should still be staged"
pass "bad layer skipped"

# Test 13
info "Test 13: overlay_validate_app"
overlay_validate_app "$APP" "$NONE" "$P1" "$H1" || fail "valid overlays rejected"
mkdir -p "$T/htypo/apps/demo/files" && echo x > "$T/htypo/apps/demo/files/a.jsno"
out=$(overlay_validate_app "$APP" "$NONE" "$T/htypo" 2>&1) && fail "unknown overlay src accepted"
[[ "$out" == *"a.jsno"* ]] || fail "message should name the file: $out"
printf 'demo/zzz.json merge\n' > "$T/strat3"
overlay_validate_app "$APP" "$T/strat3" 2>/dev/null && fail "unknown files: key accepted"
printf 'demo/b.txt merge\n' > "$T/strat4"
overlay_validate_app "$APP" "$T/strat4" 2>/dev/null && fail "merge on non-json accepted"
printf 'demo/b.txt copy\n' > "$T/strat5"
overlay_validate_app "$APP" "$T/strat5" 2>/dev/null && fail "unknown strategy accepted"
printf 'other/x merge\n' > "$T/strat6"
overlay_validate_app "$APP" "$T/strat6" || fail "keys for other apps must be ignored here"
pass "validation correct"

# Test 14
info "Test 14: hosts_normalize_name"
[[ "$(hosts_normalize_name user@web1.example.com)" == web1 ]] || fail "user@fqdn"
[[ "$(hosts_normalize_name web1)" == web1 ]] || fail "bare"
[[ "$(hosts_normalize_name web1.lan)" == web1 ]] || fail "domain"
[[ "$(hosts_normalize_name user@10.0.0.5)" == 10.0.0.5 ]] || fail "IPv4 must stay whole"
pass "host names normalized"

# Test 15
info "Test 15: hosts_resolve_profile_path"
mkdir -p "$T/hr/profiles" "$T/df/profiles"
touch "$T/hr/profiles/minimal.yaml" "$T/df/profiles/minimal.yaml" "$T/df/profiles/complete.yaml"
[[ "$(hosts_resolve_profile_path "$T/df/profiles" "$T/hr" minimal false)" == "$T/hr/profiles/minimal.yaml" ]] || fail "hosts first"
[[ "$(hosts_resolve_profile_path "$T/df/profiles" "$T/hr" minimal true)" == "$T/df/profiles/minimal.yaml" ]] || fail "skip hosts"
[[ "$(hosts_resolve_profile_path "$T/df/profiles" "$T/hr" complete false)" == "$T/df/profiles/complete.yaml" ]] || fail "fallback"
[[ "$(hosts_resolve_profile_path "$T/df/profiles" "" minimal false)" == "$T/df/profiles/minimal.yaml" ]] || fail "no hosts repo"
pass "profile lookup order"

# Test 16
info "Test 16: hosts_read_scalar and hosts_parse_files_map"
cat > "$T/host.yaml" << 'EOF'
# comment
profile: complete   # trailing comment
exclude:
  - lazyssh
files:
  claude/settings.json: merge
  tmux/.tmux.conf: replace
EOF
[[ "$(hosts_read_scalar "$T/host.yaml" profile)" == complete ]] || fail "profile scalar"
[[ -z "$(hosts_read_scalar "$T/host.yaml" missing)" ]] || fail "missing scalar"
[[ "$(hosts_parse_files_map "$T/host.yaml")" == $'claude/settings.json merge\ntmux/.tmux.conf replace' ]] \
    || fail "files map: $(hosts_parse_files_map "$T/host.yaml")"
printf 'files:\n  settings.json: merge\n' > "$T/badmap.yaml"
hosts_parse_files_map "$T/badmap.yaml" >/dev/null 2>&1 && fail "key without app/ accepted"
pass "host.yaml parsing"

info "Test 17: hosts_local_name works without a hostname binary"
mkdir -p "$T/nobin" && ln -sf "$(command -v uname)" "$T/nobin/uname"
if PATH="$T/nobin" command -v hostname >/dev/null 2>&1; then fail "test setup: hostname still on PATH"; fi
nm=$(PATH="$T/nobin" hosts_local_name) || fail "hosts_local_name failed without hostname"
[[ "$nm" == "$(uname -n | cut -d. -f1)" && -n "$nm" ]] || fail "unexpected name: '$nm'"
pass "hosts_local_name fallback"

rm -rf "$T"
echo
echo "======================================"
echo -e "${GREEN}All 18 overlay/hosts library tests passed!${NC}"
echo "======================================"
