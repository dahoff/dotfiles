#!/usr/bin/env bash
# test-records.sh - lib/records.sh and lib/merge3.jq: saved copies and the three-way decision

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
echo "Records Tests"
echo "======================================"
echo

T="/tmp/dotfiles-test-records-$$"
trap 'chmod -R u+rwx "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
rm -rf "$T"
mkdir -p "$T/home" "$T/state" "$T/in"
export HOME="$T/home"
export STATE_DIR="$T/state"
R="$STATE_DIR/records"

# shellcheck source=../../lib/records.sh
source "$ROOT_DIR/lib/records.sh"

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# JSON equality: object key order doesn't count, array order does
json_eq() { jq -ne --argjson a "$1" --argjson b "$2" '$a == $b' >/dev/null; }

m3_field() {
    local name="$1" round="$2" field="$3" want="$4" got
    got=$(jq -c ".$field" <<<"$M3_OUT")
    json_eq "$got" "$want" || fail "$name ($round): $field is $got, expected $want"
}
# Runs records_merge3 and asserts all five fields. Then runs it again on what it
# produced, as the next pull would: nothing may move, the same conflicts are
# reported and nothing is applied a second time.
# Usage: m3 NAME BASE NEW LIVE REVIEW EXP_LIVE EXP_REPO EXP_REVIEW EXP_CONFLICTS EXP_APPLIED
m3() {
    local name="$1" d="$T/in/m3"
    rm -rf "$d"; mkdir -p "$d"
    printf '%s' "$2" > "$d/base"; printf '%s' "$3" > "$d/new"
    printf '%s' "$4" > "$d/live"; printf '%s' "$5" > "$d/review"
    M3_OUT=$(records_merge3 "$d/base" "$d/new" "$d/live" "$d/review") || fail "$name: failed"
    m3_field "$name" first live "$6"
    m3_field "$name" first repo "$7"
    m3_field "$name" first review "$8"
    m3_field "$name" first conflicts "$9"
    m3_field "$name" first applied "${10}"

    jq -c .repo <<<"$M3_OUT" > "$d/base"
    jq -c .live <<<"$M3_OUT" > "$d/live"
    jq -c .review <<<"$M3_OUT" > "$d/review"
    M3_OUT=$(records_merge3 "$d/base" "$d/new" "$d/live" "$d/review") || fail "$name: second run failed"
    m3_field "$name" second live "$6"
    m3_field "$name" second repo "$7"
    m3_field "$name" second review "$8"
    m3_field "$name" second conflicts "$9"
    m3_field "$name" second applied '[]'
    pass "$name"
}

# Writes files holding each text, in order: f1, f2, ...
files() {
    local i=1 text
    for text in "$@"; do
        printf '%s' "$text" > "$T/in/f$i"
        i=$((i + 1))
    done
}
f() { echo "$T/in/f$1"; }

decide() {
    local got
    got=$(records_decide_file "$2" "$3" "$4") || fail "$1: failed"
    [[ "$got" == "$5" ]] || fail "$1: got '$got', expected '$5'"
    pass "$1"
}

# --- The library stands alone ---

info "Sourcing"
OUT=$(cd / && env -i PATH="$PATH" HOME="$HOME" STATE_DIR="$STATE_DIR" bash -c '
    set -euo pipefail
    source "$1"
    declare -F records_merge3 records_decide_file records_items records_put >/dev/null
    echo sourced' _ "$ROOT_DIR/lib/records.sh") || fail "does not source on its own under set -euo pipefail"
[[ "$OUT" == sourced ]] || fail "sourcing printed something: $OUT"
pass "sources alone under set -euo pipefail, printing nothing"

# A relative source path must still find merge3.jq after a cd
files '{"a":1}' '{"a":2}' '{"a":1}' '{"a":1}'
OUT=$(cd "$ROOT_DIR/lib" && bash -c 'source ./records.sh && cd / && records_merge3 "$@"' _ "$(f 1)" "$(f 2)" "$(f 3)" "$(f 4)") \
    || fail "relative source lost merge3.jq"
json_eq "$(jq -c .live <<<"$OUT")" '{"a":2}' || fail "relative source: $OUT"
pass "finds merge3.jq whatever the cwd"

# --- records_decide_file ---

info "records_decide_file: the pull table"
files 'old' 'new' 'mine'
decide "not changed, repo changed: apply"      "$(f 1)" "$(f 1)" "$(f 2)" apply
decide "not changed, repo not changed: none"   "$(f 1)" "$(f 1)" "$(f 1)" none
decide "changed, repo not changed: keep"       "$(f 3)" "$(f 1)" "$(f 1)" keep
decide "changed, repo to same value: same"     "$(f 2)" "$(f 1)" "$(f 2)" same
decide "changed, repo to other value: conflict" "$(f 3)" "$(f 1)" "$(f 2)" conflict

info "records_decide_file: edges"
decide "a deleted live file is restored, repo unchanged" "$T/in/absent" "$(f 1)" "$(f 1)" apply
decide "a deleted live file is restored, repo changed"   "$T/in/absent" "$(f 1)" "$(f 2)" apply
files '' 'x'
decide "empty repo copy, live and new empty: none"  "$(f 1)" "$(f 1)" "$(f 1)" none
decide "new is empty, live untouched: apply"        "$(f 2)" "$(f 2)" "$(f 1)" apply
decide "live emptied, repo unchanged: keep"         "$(f 1)" "$(f 2)" "$(f 2)" keep
files 'x' $'x\n'
decide "a trailing newline counts as a change" "$(f 2)" "$(f 1)" "$(f 1)" keep
printf 'a\0b' > "$T/in/b1"; printf 'a\0c' > "$T/in/b2"
decide "binary contents compare whole" "$T/in/b2" "$T/in/b1" "$T/in/b1" keep
mkdir -p "$T/in/sp ace"; printf 'one' > "$T/in/sp ace/a b"; printf 'two' > "$T/in/sp ace/c d"
decide "paths with spaces" "$T/in/sp ace/a b" "$T/in/sp ace/a b" "$T/in/sp ace/c d" apply

files 'x'
if OUT=$(records_decide_file "$(f 1)" "$T/in/absent" "$(f 1)" 2>/dev/null); then fail "missing repo copy accepted: $OUT"; fi
[[ -z "$OUT" ]] || fail "missing repo copy printed a decision: $OUT"
if OUT=$(records_decide_file "$(f 1)" "$(f 1)" "$T/in/absent" 2>/dev/null); then fail "missing new accepted: $OUT"; fi
[[ -z "$OUT" ]] || fail "missing new printed a decision: $OUT"
pass "a missing repo copy or new file fails with no decision"

# --- records_merge3 ---

info "records_merge3: the pull table"
#  name                                   base      new       live      review    -> live      repo      review    conflicts applied
m3 "not changed, repo changed: applied"   '{"k":1}' '{"k":2}' '{"k":1}' '{"k":1}'    '{"k":2}' '{"k":2}' '{"k":2}' '[]' '[["k"]]'
m3 "not changed, repo not changed"        '{"k":1}' '{"k":1}' '{"k":1}' '{"k":1}'    '{"k":1}' '{"k":1}' '{"k":1}' '[]' '[]'
m3 "changed, repo not changed: kept"      '{"k":1}' '{"k":1}' '{"k":9}' '{"k":1}'    '{"k":9}' '{"k":1}' '{"k":1}' '[]' '[]'
m3 "changed, repo to same value: records" '{"k":1}' '{"k":2}' '{"k":2}' '{"k":1}'    '{"k":2}' '{"k":2}' '{"k":2}' '[]' '[]'
m3 "changed, repo elsewhere: conflict"    '{"k":1}' '{"k":2}' '{"k":9}' '{"k":1}'    '{"k":9}' '{"k":1}' '{"k":1}' '[["k"]]' '[]'

info "records_merge3: the review copy"
m3 "conflict leaves an already-reviewed edit alone" \
    '{"k":1}' '{"k":2}' '{"k":9}' '{"k":9}'    '{"k":9}' '{"k":1}' '{"k":9}' '[["k"]]' '[]'
m3 "an unrelated apply leaves an unreviewed edit visible" \
    '{"mine":1,"up":1}' '{"mine":1,"up":2}' '{"mine":9,"up":1}' '{"mine":1,"up":1}' \
    '{"mine":9,"up":2}' '{"mine":1,"up":2}' '{"mine":1,"up":2}' '[]' '[["up"]]'
m3 "a dismissed edit stays reviewed when the repo moves another key" \
    '{"mine":1,"up":1}' '{"mine":1,"up":2}' '{"mine":9,"up":1}' '{"mine":9,"up":1}' \
    '{"mine":9,"up":2}' '{"mine":1,"up":2}' '{"mine":9,"up":2}' '[]' '[["up"]]'
m3 "review missing keys that live has: they stay missing" \
    '{"k":1}' '{"k":2}' '{"k":1,"local":true,"o":{"x":1}}' '{"k":1}' \
    '{"k":2,"local":true,"o":{"x":1}}' '{"k":2}' '{"k":2}' '[]' '[["k"]]'
m3 "review missing the applied key gains it" \
    '{"k":1}' '{"k":2}' '{"k":1}' '{}'    '{"k":2}' '{"k":2}' '{"k":2}' '[]' '[["k"]]'
m3 "review missing a key the repo drops is left alone" \
    '{"k":1}' '{}' '{"k":1}' '{"z":0}'    '{}' '{}' '{"z":0}' '[]' '[["k"]]'
m3 "review scalar in the way of an applied nested key is replaced" \
    '{}' '{"a":{"x":1}}' '{}' '{"a":5}'    '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[]' '[["a","x"]]'
m3 "review scalar in the way of a removed nested key is left alone" \
    '{"a":{"x":1}}' '{"a":{}}' '{"a":{"x":1}}' '{"a":5}'    '{"a":{}}' '{"a":{}}' '{"a":5}' '[]' '[["a","x"]]'
m3 "a both-sides value updates a differing review copy" \
    '{"k":1}' '{"k":2}' '{"k":2}' '{"k":7}'    '{"k":2}' '{"k":2}' '{"k":2}' '[]' '[]'

info "records_merge3: empty objects"
m3 "all files empty"            '{}' '{}' '{}' '{}'    '{}' '{}' '{}' '[]' '[]'
m3 "all empty but live has keys" '{}' '{}' '{"l":1}' '{}'    '{"l":1}' '{}' '{}' '[]' '[]'
m3 "repo {} doesn't flag or remove live children" \
    '{"a":{}}' '{"a":{}}' '{"a":{"x":1}}' '{"a":{}}'    '{"a":{"x":1}}' '{"a":{}}' '{"a":{}}' '[]' '[]'
m3 "repo first adds {}: nothing to manage, live children stay" \
    '{}' '{"a":{}}' '{"a":{"x":1}}' '{}'    '{"a":{"x":1}}' '{"a":{}}' '{}' '[]' '[]'
m3 "repo first adds {}: live is not given one" \
    '{}' '{"a":{}}' '{}' '{}'    '{}' '{"a":{}}' '{}' '[]' '[]'
m3 "repo's {} replaced by a scalar, live still {}: applied" \
    '{"a":{}}' '{"a":1}' '{"a":{}}' '{"a":{}}'    '{"a":1}' '{"a":1}' '{"a":1}' '[]' '[["a"]]'
m3 "repo's {} replaced by a scalar, live has children: conflict" \
    '{"a":{}}' '{"a":1}' '{"a":{"x":1}}' '{"a":{"x":1}}'    '{"a":{"x":1}}' '{"a":{}}' '{"a":{"x":1}}' '[["a"]]' '[]'
m3 "scalar replaced by repo's {}, live unchanged: applied" \
    '{"a":1}' '{"a":{}}' '{"a":1}' '{"a":1}'    '{"a":{}}' '{"a":{}}' '{"a":{}}' '[]' '[["a"]]'
m3 "scalar replaced by repo's {}, live edited: conflict" \
    '{"a":1}' '{"a":{}}' '{"a":2}' '{"a":1}'    '{"a":2}' '{"a":1}' '{"a":1}' '[["a"]]' '[]'

info "records_merge3: values that look like absence"
for v in false 0 '""' '[]' null; do
    m3 "$v is a value: repo adds it" \
        '{}' "{\"k\":$v}" '{}' '{}'    "{\"k\":$v}" "{\"k\":$v}" "{\"k\":$v}" '[]' '[["k"]]'
    m3 "$v is a value: repo drops it, live unchanged" \
        "{\"k\":$v}" '{}' "{\"k\":$v}" "{\"k\":$v}"    '{}' '{}' '{}' '[]' '[["k"]]'
    m3 "$v is a value: live deleted it, repo unchanged" \
        "{\"k\":$v}" "{\"k\":$v}" '{}' "{\"k\":$v}"    '{}' "{\"k\":$v}" "{\"k\":$v}" '[]' '[]'
    m3 "$v is a value: live added it, repo adds another" \
        '{}' '{"k":"r"}' "{\"k\":$v}" '{}'    "{\"k\":$v}" '{}' '{}' '[["k"]]' '[]'
    m3 "$v is a value: repo changes it, live deleted it" \
        "{\"k\":$v}" '{"k":"r"}' '{}' "{\"k\":$v}"    '{}' "{\"k\":$v}" "{\"k\":$v}" '[["k"]]' '[]'
    m3 "$v is a value: applied over" \
        "{\"k\":$v}" '{"k":"r"}' "{\"k\":$v}" "{\"k\":$v}"    '{"k":"r"}' '{"k":"r"}' '{"k":"r"}' '[]' '[["k"]]'
    m3 "$v is a value: live replaced it with an object, repo unchanged" \
        "{\"k\":$v}" "{\"k\":$v}" '{"k":{"z":true}}' "{\"k\":$v}" \
        '{"k":{"z":true}}' "{\"k\":$v}" "{\"k\":$v}" '[]' '[]'
done
m3 "false and 0 and \"\" and null are all different values" \
    '{"a":false,"b":0,"c":"","d":null}' '{"a":0,"b":"","c":null,"d":false}' \
    '{"a":false,"b":0,"c":"","d":null}' '{"a":false,"b":0,"c":"","d":null}' \
    '{"a":0,"b":"","c":null,"d":false}' '{"a":0,"b":"","c":null,"d":false}' '{"a":0,"b":"","c":null,"d":false}' \
    '[]' '[["a"],["b"],["c"],["d"]]'
m3 "null vs absent: repo drops a null, live already lacks it: both sides" \
    '{"k":null}' '{}' '{}' '{"k":null}'    '{}' '{}' '{}' '[]' '[]'
m3 "null vs absent: live set to null while the repo drops the key: conflict, kept" \
    '{"k":1}' '{}' '{"k":null}' '{"k":1}'    '{"k":null}' '{"k":1}' '{"k":1}' '[["k"]]' '[]'
m3 "null vs absent: repo sets null, live deleted it: conflict" \
    '{"k":1}' '{"k":null}' '{}' '{"k":1}'    '{}' '{"k":1}' '{"k":1}' '[["k"]]' '[]'

info "records_merge3: both sides"
m3 "added by both, equal" \
    '{}' '{"k":1}' '{"k":1}' '{}'    '{"k":1}' '{"k":1}' '{"k":1}' '[]' '[]'
m3 "added by both, different: repo stays without it" \
    '{}' '{"k":1}' '{"k":2}' '{}'    '{"k":2}' '{}' '{}' '[["k"]]' '[]'
m3 "added by both, nested and equal" \
    '{}' '{"a":{"b":{"k":1}}}' '{"a":{"b":{"k":1}}}' '{}' \
    '{"a":{"b":{"k":1}}}' '{"a":{"b":{"k":1}}}' '{"a":{"b":{"k":1}}}' '[]' '[]'
m3 "added by both, nested and different" \
    '{}' '{"a":{"k":1,"o":2}}' '{"a":{"k":9}}' '{}' \
    '{"a":{"k":9,"o":2}}' '{"a":{"o":2}}' '{"a":{"o":2}}' '[["a","k"]]' '[["a","o"]]'
m3 "deleted by both" \
    '{"k":1,"z":0}' '{"z":0}' '{"z":0}' '{"k":1,"z":0}'    '{"z":0}' '{"z":0}' '{"z":0}' '[]' '[]'
m3 "deleted by both, nested" \
    '{"a":{"k":1}}' '{"a":{}}' '{"a":{}}' '{"a":{"k":1}}'    '{"a":{}}' '{"a":{}}' '{"a":{}}' '[]' '[]'

info "records_merge3: keys the repo drops"
m3 "dropped and unchanged: removed" \
    '{"k":1,"z":0}' '{"z":0}' '{"k":1,"z":0}' '{"k":1,"z":0}'    '{"z":0}' '{"z":0}' '{"z":0}' '[]' '[["k"]]'
m3 "dropped and edited: kept, and held as a conflict" \
    '{"k":1,"z":0}' '{"z":0}' '{"k":9,"z":0}' '{"k":1,"z":0}' \
    '{"k":9,"z":0}' '{"k":1,"z":0}' '{"k":1,"z":0}' '[["k"]]' '[]'
m3 "dropped, its parent becomes empty in the repo: live keeps an empty parent" \
    '{"a":{"k":1}}' '{"a":{}}' '{"a":{"k":1}}' '{"a":{"k":1}}'    '{"a":{}}' '{"a":{}}' '{"a":{}}' '[]' '[["a","k"]]'
m3 "dropped along with its parent: live keeps an empty parent" \
    '{"a":{"k":1}}' '{}' '{"a":{"k":1}}' '{"a":{"k":1}}'    '{"a":{}}' '{}' '{"a":{}}' '[]' '[["a","k"]]'
m3 "dropped with its parent, a local sibling stays" \
    '{"a":{"k":1}}' '{}' '{"a":{"k":1,"mine":2}}' '{"a":{"k":1}}'    '{"a":{"mine":2}}' '{}' '{"a":{}}' '[]' '[["a","k"]]'
m3 "dropped with its parent while edited: the base value comes back to repo" \
    '{"a":{"k":1}}' '{}' '{"a":{"k":9}}' '{"a":{"k":1}}'    '{"a":{"k":9}}' '{"a":{"k":1}}' '{"a":{"k":1}}' '[["a","k"]]' '[]'
m3 "repo's whole file emptied: everything unchanged is removed, edits kept" \
    '{"a":1,"b":{"c":2,"d":3}}' '{}' '{"a":1,"b":{"c":2,"d":9},"l":1}' '{"a":1,"b":{"c":2,"d":3}}' \
    '{"b":{"d":9},"l":1}' '{"b":{"d":3}}' '{"b":{"d":3}}' '[["b","d"]]' '[["a"],["b","c"]]'

info "records_merge3: object and plain value"
m3 "repo object to scalar, live unchanged: one conflict, subtree untouched" \
    '{"a":{"x":1,"y":2}}' '{"a":5}' '{"a":{"x":1,"y":2}}' '{"a":{"x":1,"y":2}}' \
    '{"a":{"x":1,"y":2}}' '{"a":{"x":1,"y":2}}' '{"a":{"x":1,"y":2}}' '[["a"]]' '[]'
m3 "repo scalar to object, live unchanged: one conflict, value untouched" \
    '{"a":5}' '{"a":{"x":1,"y":2}}' '{"a":5}' '{"a":5}' \
    '{"a":5}' '{"a":5}' '{"a":5}' '[["a"]]' '[]'
m3 "repo object to scalar, live already that scalar: records only" \
    '{"a":{"x":1}}' '{"a":5}' '{"a":5}' '{"a":{"x":1}}' \
    '{"a":5}' '{"a":5}' '{"a":5}' '[]' '[]'
m3 "repo scalar to object, live already that object: records only" \
    '{"a":5}' '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":5}' \
    '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[]' '[]'
m3 "repo scalar to object, live the same with reordered keys: records only" \
    '{"a":5}' '{"a":{"x":1,"y":2}}' '{"a":{"y":2,"x":1}}' '{"a":5}' \
    '{"a":{"y":2,"x":1}}' '{"a":{"x":1,"y":2}}' '{"a":{"x":1,"y":2}}' '[]' '[]'
m3 "repo object to array, live already that array: records only" \
    '{"a":{"x":1}}' '{"a":[1]}' '{"a":[1]}' '{"a":{"x":1}}' \
    '{"a":[1]}' '{"a":[1]}' '{"a":[1]}' '[]' '[]'
m3 "records only replaces a review copy that holds something else there" \
    '{"a":{"x":1}}' '{"a":5}' '{"a":5}' '{"a":{"y":7},"z":0}' \
    '{"a":5}' '{"a":5}' '{"a":5,"z":0}' '[]' '[]'
m3 "records only, deep in the tree, siblings still apply" \
    '{"t":{"a":{"b":1},"s":1}}' '{"t":{"a":5,"s":2}}' '{"t":{"a":5,"s":1}}' '{"t":{"a":{"b":1},"s":1}}' \
    '{"t":{"a":5,"s":2}}' '{"t":{"a":5,"s":2}}' '{"t":{"a":5,"s":2}}' '[]' '[["t","s"]]'
m3 "repo object to scalar, live a different scalar: conflict" \
    '{"a":{"x":1}}' '{"a":5}' '{"a":6}' '{"a":{"x":1}}' \
    '{"a":6}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[["a"]]' '[]'
m3 "repo scalar to object, live a different object: conflict" \
    '{"a":5}' '{"a":{"x":1}}' '{"a":{"x":1,"y":2}}' '{"a":5}' \
    '{"a":{"x":1,"y":2}}' '{"a":5}' '{"a":5}' '[["a"]]' '[]'
m3 "repo object to scalar, live edited inside the object: one conflict at the top" \
    '{"a":{"x":1}}' '{"a":5}' '{"a":{"x":2}}' '{"a":{"x":1}}' \
    '{"a":{"x":2}}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[["a"]]' '[]'
m3 "repo drops an object, live made it a scalar: conflict, kept" \
    '{"a":{"x":1}}' '{}' '{"a":5}' '{"a":{"x":1}}' \
    '{"a":5}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[["a"]]' '[]'
m3 "repo object to array is object to plain value" \
    '{"a":{"x":1}}' '{"a":[1]}' '{"a":{"x":1}}' '{"a":{"x":1}}' \
    '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[["a"]]' '[]'
m3 "repo object to null is object to plain value" \
    '{"a":{"x":1}}' '{"a":null}' '{"a":{"x":1}}' '{"a":{"x":1}}' \
    '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[["a"]]' '[]'
m3 "live object to scalar, repo unchanged: yours is kept, no conflict" \
    '{"a":{"x":1,"y":2}}' '{"a":{"x":1,"y":2}}' '{"a":5}' '{"a":{"x":1,"y":2}}' \
    '{"a":5}' '{"a":{"x":1,"y":2}}' '{"a":{"x":1,"y":2}}' '[]' '[]'
m3 "live object to scalar, repo unchanged, deep: siblings still apply" \
    '{"t":{"a":{"b":{"c":1}},"s":1}}' '{"t":{"a":{"b":{"c":1}},"s":2}}' '{"t":{"a":5,"s":1}}' '{"t":{"a":{"b":{"c":1}},"s":1}}' \
    '{"t":{"a":5,"s":2}}' '{"t":{"a":{"b":{"c":1}},"s":2}}' '{"t":{"a":{"b":{"c":1}},"s":2}}' '[]' '[["t","s"]]'
m3 "live scalar to object, repo unchanged: yours is kept, no conflict" \
    '{"a":5}' '{"a":5}' '{"a":{"x":1}}' '{"a":5}' \
    '{"a":{"x":1}}' '{"a":5}' '{"a":5}' '[]' '[]'
m3 "live scalar to object, repo changes the scalar: conflict" \
    '{"a":5}' '{"a":6}' '{"a":{"x":1}}' '{"a":5}' \
    '{"a":{"x":1}}' '{"a":5}' '{"a":5}' '[["a"]]' '[]'
m3 "live object to array blocks the keys below it" \
    '{"a":{"x":1}}' '{"a":{"x":2}}' '{"a":[1]}' '{"a":{"x":1}}' \
    '{"a":[1]}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[["a"]]' '[]'
m3 "live object to null, repo unchanged: yours is kept, no conflict" \
    '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":null}' '{"a":{"x":1}}' \
    '{"a":null}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[]' '[]'
m3 "live object to null, repo changes inside: conflict" \
    '{"a":{"x":1}}' '{"a":{"x":2}}' '{"a":null}' '{"a":{"x":1}}' \
    '{"a":null}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[["a"]]' '[]'
m3 "live scalar in the way of a key the repo adds below it" \
    '{}' '{"a":{"x":1}}' '{"a":5}' '{}' \
    '{"a":5}' '{}' '{}' '[["a"]]' '[]'
m3 "topmost path only, deep in the tree" \
    '{"t":{"a":{"b":{"c":1,"d":2}}}}' '{"t":{"a":{"b":{"c":1,"d":3}}}}' '{"t":{"a":7}}' '{"t":{"a":{"b":{"c":1,"d":2}}}}' \
    '{"t":{"a":7}}' '{"t":{"a":{"b":{"c":1,"d":2}}}}' '{"t":{"a":{"b":{"c":1,"d":2}}}}' '[["t","a"]]' '[]'
m3 "repo object to scalar deep in the tree, siblings still apply" \
    '{"t":{"a":{"b":1},"s":1}}' '{"t":{"a":5,"s":2}}' '{"t":{"a":{"b":1},"s":1}}' '{"t":{"a":{"b":1},"s":1}}' \
    '{"t":{"a":{"b":1},"s":2}}' '{"t":{"a":{"b":1},"s":2}}' '{"t":{"a":{"b":1},"s":2}}' '[["t","a"]]' '[["t","s"]]'
m3 "repo keys added under a held subtree wait with it" \
    '{"a":{"x":1}}' '{"a":{"x":1,"new":2}}' '{"a":5}' '{"a":{"x":1}}' \
    '{"a":5}' '{"a":{"x":1}}' '{"a":{"x":1}}' '[["a"]]' '[]'
m3 "a live object over a repo scalar is untouched by a repo change elsewhere" \
    '{"a":5,"b":1}' '{"a":5,"b":2}' '{"a":{"x":1},"b":1}' '{"a":5,"b":1}' \
    '{"a":{"x":1},"b":2}' '{"a":5,"b":2}' '{"a":5,"b":2}' '[]' '[["b"]]'

info "records_merge3: paths"
m3 "a.b@c and nested a -> b@c stay distinct: only the dotted key changes" \
    '{"a.b@c":1,"a":{"b@c":1}}' '{"a.b@c":2,"a":{"b@c":1}}' '{"a.b@c":1,"a":{"b@c":1}}' '{"a.b@c":1,"a":{"b@c":1}}' \
    '{"a.b@c":2,"a":{"b@c":1}}' '{"a.b@c":2,"a":{"b@c":1}}' '{"a.b@c":2,"a":{"b@c":1}}' '[]' '[["a.b@c"]]'
m3 "a.b@c and nested a -> b@c stay distinct: only the nested key changes" \
    '{"a.b@c":1,"a":{"b@c":1}}' '{"a.b@c":1,"a":{"b@c":2}}' '{"a.b@c":1,"a":{"b@c":1}}' '{"a.b@c":1,"a":{"b@c":1}}' \
    '{"a.b@c":1,"a":{"b@c":2}}' '{"a.b@c":1,"a":{"b@c":2}}' '{"a.b@c":1,"a":{"b@c":2}}' '[]' '[["a","b@c"]]'
m3 "a.b@c and nested a -> b@c stay distinct: conflict on one, apply on the other" \
    '{"a.b@c":1,"a":{"b@c":1}}' '{"a.b@c":2,"a":{"b@c":2}}' '{"a.b@c":9,"a":{"b@c":1}}' '{"a.b@c":1,"a":{"b@c":1}}' \
    '{"a.b@c":9,"a":{"b@c":2}}' '{"a.b@c":1,"a":{"b@c":2}}' '{"a.b@c":1,"a":{"b@c":2}}' '[["a.b@c"]]' '[["a","b@c"]]'
m3 "a key with spaces" \
    '{"my key":1}' '{"my key":2}' '{"my key":1}' '{"my key":1}' \
    '{"my key":2}' '{"my key":2}' '{"my key":2}' '[]' '[["my key"]]'
m3 "a key with double and single quotes" \
    '{"a\"b'"'"'c":1}' '{"a\"b'"'"'c":2}' '{"a\"b'"'"'c":9}' '{"a\"b'"'"'c":1}' \
    '{"a\"b'"'"'c":9}' '{"a\"b'"'"'c":1}' '{"a\"b'"'"'c":1}' '[["a\"b'"'"'c"]]' '[]'
m3 "a key with a tab, nested under a key with a newline" \
    '{"n\nl":{"t\tb":1}}' '{"n\nl":{"t\tb":2}}' '{"n\nl":{"t\tb":1}}' '{"n\nl":{"t\tb":1}}' \
    '{"n\nl":{"t\tb":2}}' '{"n\nl":{"t\tb":2}}' '{"n\nl":{"t\tb":2}}' '[]' '[["n\nl","t\tb"]]'
m3 "an empty key" \
    '{"":1}' '{"":2}' '{"":1}' '{"":1}'    '{"":2}' '{"":2}' '{"":2}' '[]' '[[""]]'
m3 "keys that look like jq or numbers" \
    '{".[]":1,"0":1,"$x":1}' '{".[]":2,"0":2,"$x":2}' '{".[]":1,"0":1,"$x":1}' '{".[]":1,"0":1,"$x":1}' \
    '{".[]":2,"0":2,"$x":2}' '{".[]":2,"0":2,"$x":2}' '{".[]":2,"0":2,"$x":2}' '[]' '[["$x"],[".[]"],["0"]]'
D5='{"a":{"b":{"c":{"d":{"e":1}}}}}'
m3 "deep nesting, applied" \
    "$D5" '{"a":{"b":{"c":{"d":{"e":2}}}}}' "$D5" "$D5" \
    '{"a":{"b":{"c":{"d":{"e":2}}}}}' '{"a":{"b":{"c":{"d":{"e":2}}}}}' '{"a":{"b":{"c":{"d":{"e":2}}}}}' '[]' '[["a","b","c","d","e"]]'
m3 "deep nesting, conflict" \
    "$D5" '{"a":{"b":{"c":{"d":{"e":2}}}}}' '{"a":{"b":{"c":{"d":{"e":9}}}}}' "$D5" \
    '{"a":{"b":{"c":{"d":{"e":9}}}}}' "$D5" "$D5" '[["a","b","c","d","e"]]' '[]'
m3 "deep nesting, repo adds into a branch live lacks" \
    '{}' "$D5" '{"a":{"z":1}}' '{}' \
    '{"a":{"z":1,"b":{"c":{"d":{"e":1}}}}}' "$D5" "$D5" '[]' '[["a","b","c","d","e"]]'

info "records_merge3: arrays and key order"
m3 "an array reordered by the repo is a change" \
    '{"k":[1,2]}' '{"k":[2,1]}' '{"k":[1,2]}' '{"k":[1,2]}'    '{"k":[2,1]}' '{"k":[2,1]}' '{"k":[2,1]}' '[]' '[["k"]]'
m3 "an array reordered by you is a change" \
    '{"k":[1,2]}' '{"k":[1,2]}' '{"k":[2,1]}' '{"k":[1,2]}'    '{"k":[2,1]}' '{"k":[1,2]}' '{"k":[1,2]}' '[]' '[]'
m3 "an array reordered by both, differently, is a conflict" \
    '{"k":[1,2,3]}' '{"k":[3,2,1]}' '{"k":[2,1,3]}' '{"k":[1,2,3]}' \
    '{"k":[2,1,3]}' '{"k":[1,2,3]}' '{"k":[1,2,3]}' '[["k"]]' '[]'
m3 "objects inside an array are one value" \
    '{"k":[{"a":1}]}' '{"k":[{"a":2}]}' '{"k":[{"a":1}]}' '{"k":[{"a":1}]}' \
    '{"k":[{"a":2}]}' '{"k":[{"a":2}]}' '{"k":[{"a":2}]}' '[]' '[["k"]]'
m3 "objects inside an array with reordered keys are equal" \
    '{"k":[{"a":1,"b":2}]}' '{"k":[{"b":2,"a":1}]}' '{"k":[{"b":2,"a":1}]}' '{"k":[{"a":1,"b":2}]}' \
    '{"k":[{"a":1,"b":2}]}' '{"k":[{"a":1,"b":2}]}' '{"k":[{"a":1,"b":2}]}' '[]' '[]'
m3 "objects with reordered keys, in every file, are not changed" \
    '{"o":{"a":1,"b":2}}' '{"o":{"b":2,"a":1}}' '{"o":{"a":1,"b":2}}' '{"o":{"b":2,"a":1}}' \
    '{"o":{"a":1,"b":2}}' '{"o":{"a":1,"b":2}}' '{"o":{"a":1,"b":2}}' '[]' '[]'
files '{"o":{"a":1,"b":2}}' '{"o":{"b":2,"a":1}}' '{"z":1,"o":{"b":2,"a":1}}' '{"o":{"a":1,"b":2}}'
OUT=$(records_merge3 "$(f 1)" "$(f 2)" "$(f 3)" "$(f 4)")
[[ "$(jq -c .applied <<<"$OUT")" == '[]' ]] || fail "reordered keys applied something: $OUT"
[[ "$(jq -c .live <<<"$OUT")" == '{"z":1,"o":{"b":2,"a":1}}' ]] || fail "live's key order moved: $OUT"
pass "live's own key order is kept when nothing applies"

info "records_merge3: several things at once"
m3 "apply, keep, same, conflict, drop and add together" \
    '{"apply":1,"keep":1,"same":1,"clash":1,"drop":1,"o":{"n":1}}' \
    '{"apply":2,"keep":1,"same":2,"clash":2,"add":1,"o":{"n":2}}' \
    '{"apply":1,"keep":9,"same":2,"clash":9,"drop":1,"o":{"n":1},"local":0}' \
    '{"apply":1,"keep":1,"same":1,"clash":1,"drop":1,"o":{"n":1},"stale":0}' \
    '{"apply":2,"keep":9,"same":2,"clash":9,"add":1,"o":{"n":2},"local":0}' \
    '{"apply":2,"keep":1,"same":2,"clash":1,"add":1,"o":{"n":2}}' \
    '{"apply":2,"keep":1,"same":2,"clash":1,"add":1,"o":{"n":2},"stale":0}' \
    '[["clash"]]' '[["add"],["apply"],["drop"],["o","n"]]'

info "records_merge3: a conflict clears once resolved by hand"
files '{"k":1}' '{"k":2}' '{"k":2}' '{"k":1}'
OUT=$(records_merge3 "$(f 1)" "$(f 2)" "$(f 3)" "$(f 4)")
[[ "$(jq -c .conflicts <<<"$OUT")" == '[]' && "$(jq -c .repo <<<"$OUT")" == '{"k":2}' ]] || fail "setting yours to the repo's value: $OUT"
files '{"k":1}' '{"k":2}' '{"k":1}' '{"k":9}'
OUT=$(records_merge3 "$(f 1)" "$(f 2)" "$(f 3)" "$(f 4)")
[[ "$(jq -c .live <<<"$OUT")" == '{"k":2}' && "$(jq -c .conflicts <<<"$OUT")" == '[]' ]] || fail "reverting the edit: $OUT"
pass "matching the repo's value or reverting the edit both clear a conflict"

info "records_merge3: bad input"
merge3_refuses() {
    local name="$1" out
    shift
    if out=$(records_merge3 "$@" 2>/dev/null); then fail "$name: accepted: $out"; fi
    [[ -z "$out" ]] || fail "$name: printed output: $out"
    pass "$name fails and prints no result"
}
files '{"a":1}' 'not json' '' '[1]' '5' '{"a":1}{"b":2}' 'null'
G="$(f 1)"
merge3_refuses "missing live"     "$G" "$G" "$T/in/absent" "$G"
merge3_refuses "missing base"     "$T/in/absent" "$G" "$G" "$G"
merge3_refuses "missing new"      "$G" "$T/in/absent" "$G" "$G"
merge3_refuses "missing review"   "$G" "$G" "$G" "$T/in/absent"
merge3_refuses "invalid JSON"     "$G" "$G" "$(f 2)" "$G"
merge3_refuses "empty live"       "$G" "$G" "$(f 3)" "$G"
merge3_refuses "array at the top" "$G" "$(f 4)" "$G" "$G"
merge3_refuses "number at the top" "$(f 5)" "$G" "$G" "$G"
merge3_refuses "two documents"    "$G" "$G" "$G" "$(f 6)"
merge3_refuses "null at the top"  "$G" "$G" "$(f 7)" "$G"

# --- Copies and the manifest ---

info "records_put and the layout"
files 'repo text' 'live text'
chmod 644 "$(f 1)" "$(f 2)"
records_put app1 "sub dir/my file.conf" "$HOME/my file.conf" replace "$(f 1)" "$(f 2)" || fail "put failed"
REPO_COPY="$R/app1/repo/sub dir/my file.conf"
REVIEW_COPY="$R/app1/review/sub dir/my file.conf"
[[ "$(records_repo_path app1 "sub dir/my file.conf")" == "$REPO_COPY" ]] || fail "repo path wrong"
[[ "$(records_review_path app1 "sub dir/my file.conf")" == "$REVIEW_COPY" ]] || fail "review path wrong"
[[ "$(cat "$REPO_COPY")" == "repo text" ]] || fail "repo copy content"
[[ "$(cat "$REVIEW_COPY")" == "live text" ]] || fail "review copy content"
[[ "$(cat "$R/app1/manifest.tsv")" == "sub dir/my file.conf"$'\t'"$HOME/my file.conf"$'\t'replace ]] || fail "manifest: $(cat "$R/app1/manifest.tsv")"
pass "copies and manifest line written, with spaces and a subdirectory"

for p in "$R" "$R/app1" "$R/app1/repo" "$R/app1/repo/sub dir" "$R/app1/review" "$R/app1/review/sub dir"; do
    [[ "$(mode_of "$p")" == 700 ]] || fail "$p is mode $(mode_of "$p")"
done
for p in "$REPO_COPY" "$REVIEW_COPY" "$R/app1/manifest.tsv"; do
    [[ "$(mode_of "$p")" == 600 ]] || fail "$p is mode $(mode_of "$p")"
done
pass "copies are 0600 and directories 0700"

(
    umask 000
    records_put umaskapp a/b/c x replace "$(f 1)" "$(f 2)"
    records_set_repo umaskapp a/b/c "$(f 2)"
) || fail "put under umask 000 failed"
for p in "$R/umaskapp" "$R/umaskapp/repo" "$R/umaskapp/repo/a" "$R/umaskapp/repo/a/b" "$R/umaskapp/review/a/b"; do
    [[ "$(mode_of "$p")" == 700 ]] || fail "umask 000: $p is mode $(mode_of "$p")"
done
for p in "$R/umaskapp/repo/a/b/c" "$R/umaskapp/review/a/b/c" "$R/umaskapp/manifest.tsv"; do
    [[ "$(mode_of "$p")" == 600 ]] || fail "umask 000: $p is mode $(mode_of "$p")"
done
pass "modes hold whatever the umask"

files 'r2' 'l2'
records_put app1 "sub dir/my file.conf" "$HOME/moved" merge "$(f 1)" "$(f 2)"
[[ "$(wc -l < "$R/app1/manifest.tsv")" -eq 1 ]] || fail "second put duplicated the line"
[[ "$(records_list app1)" == "sub dir/my file.conf"$'\t'"$HOME/moved"$'\t'merge ]] || fail "second put: $(records_list app1)"
[[ "$(cat "$REPO_COPY")" == r2 && "$(cat "$REVIEW_COPY")" == l2 ]] || fail "second put kept old copies"
[[ "$(mode_of "$REPO_COPY")" == 600 ]] || fail "second put changed the mode"
pass "putting again replaces the line and the copies"

records_put app1 other.txt "$HOME/other.txt" replace "$(f 1)" "$(f 2)"
[[ "$(records_list app1 | wc -l)" -eq 2 ]] || fail "second source should add a line"
pass "another source adds a line"

ln -s "$(f 1)" "$T/in/link"
records_put app1 linked "$HOME/linked" replace "$T/in/link" "$T/in/link"
[[ ! -L "$R/app1/repo/linked" && "$(cat "$R/app1/repo/linked")" == r2 ]] || fail "a symlink source must be copied as content"
records_prune app1 "$HOME/moved" "$HOME/other.txt"
pass "a symlink source is copied by content"

printf 'a\0b' > "$T/in/bin"; : > "$T/in/empty"
records_put binapp bin "$HOME/bin" replace "$T/in/bin" "$T/in/empty"
cmp -s "$T/in/bin" "$R/binapp/repo/bin" || fail "binary copy differs"
[[ -f "$R/binapp/review/bin" && ! -s "$R/binapp/review/bin" ]] || fail "empty copy should exist and be empty"
records_remove binapp
pass "binary and empty files copy exactly"

info "records_set_repo and records_set_review"
files 'only repo' 'only review'
records_set_repo app1 other.txt "$(f 1)"
[[ "$(cat "$R/app1/repo/other.txt")" == "only repo" && "$(cat "$R/app1/review/other.txt")" == l2 ]] || fail "set_repo touched review"
records_set_review app1 other.txt "$(f 2)"
[[ "$(cat "$R/app1/review/other.txt")" == "only review" && "$(cat "$R/app1/repo/other.txt")" == "only repo" ]] || fail "set_review touched repo"
[[ "$(mode_of "$R/app1/review/other.txt")" == 600 && "$(mode_of "$R/app1/repo/other.txt")" == 600 ]] || fail "set changed modes"
records_set_review app1 other.txt "$R/app1/review/other.txt"
[[ "$(cat "$R/app1/review/other.txt")" == "only review" ]] || fail "setting a copy from itself lost it"
pass "each replaces only its own copy"

if records_set_repo app1 other.txt "$T/in/absent" 2>/dev/null; then fail "missing file accepted"; fi
[[ "$(cat "$R/app1/repo/other.txt")" == "only repo" ]] || fail "failed set damaged the copy"
if records_set_review app1 nosuch "$(f 1)" 2>/dev/null; then fail "set on an unrecorded source accepted"; fi
[[ ! -e "$R/app1/review/nosuch" ]] || fail "set on an unrecorded source wrote a copy"
pass "a missing file or unrecorded source fails and changes nothing"

info "Failures partway through"
BEFORE=$(records_list app1)
if records_put app1 other.txt "$HOME/other.txt" replace "$T/in/absent" "$(f 1)" 2>/dev/null; then fail "missing repo file accepted"; fi
if records_put app1 other.txt "$HOME/other.txt" replace "$(f 1)" "$T/in/absent" 2>/dev/null; then fail "missing live file accepted"; fi
if records_put newapp x "$HOME/x" replace "$T/in/absent" "$(f 1)" 2>/dev/null; then fail "missing repo file accepted"; fi
[[ "$(records_list app1)" == "$BEFORE" ]] || fail "failed put changed the manifest"
[[ "$(cat "$R/app1/repo/other.txt")" == "only repo" && "$(cat "$R/app1/review/other.txt")" == "only review" ]] || fail "failed put changed copies"
[[ ! -e "$R/newapp/manifest.tsv" && -z "$(records_list newapp)" ]] || fail "failed put left a record"
pass "records_put with a missing input changes nothing"

if records_put app1 other.txt "$HOME/other.txt" bogus "$(f 1)" "$(f 2)" 2>/dev/null; then fail "unknown strategy accepted"; fi
[[ "$(records_list app1)" == "$BEFORE" ]] || fail "unknown strategy changed the manifest"
if records_put app1 $'tab\tsrc' "$HOME/x" replace "$(f 1)" "$(f 2)" 2>/dev/null; then fail "a tab in SRC accepted"; fi
if records_put app1 x $'tab\tdest' replace "$(f 1)" "$(f 2)" 2>/dev/null; then fail "a tab in DEST accepted"; fi
if records_put app1 $'new\nline' "$HOME/x" replace "$(f 1)" "$(f 2)" 2>/dev/null; then fail "a newline in SRC accepted"; fi
[[ "$(records_list app1)" == "$BEFORE" ]] || fail "a bad name changed the manifest"
pass "an unknown strategy, or a tab or newline in a name, is refused"

for bad in "" /abs/path ../escape a/../../escape .. a/..; do
    if records_put app1 "$bad" "$HOME/x" replace "$(f 1)" "$(f 2)" 2>/dev/null; then fail "SRC '$bad' accepted"; fi
    if records_repo_path app1 "$bad" >/dev/null 2>&1; then fail "path for SRC '$bad' printed"; fi
done
for bad in "" . .. a/b .add-saved; do
    if records_put "$bad" x "$HOME/x" replace "$(f 1)" "$(f 2)" 2>/dev/null; then fail "APP '$bad' accepted"; fi
done
[[ ! -e "$T/state/escape" && ! -e "$STATE_DIR/records/escape" ]] || fail "escaped the records dir"
pass "names that would leave the records directory are refused"

if [[ $EUID -ne 0 ]]; then
    records_put rofail one "$HOME/one" replace "$(f 1)" "$(f 2)"
    LIST_BEFORE=$(records_list rofail)
    chmod 500 "$R/rofail/review"
    files 'newer repo' 'newer live'
    if records_put rofail one "$HOME/moved" merge "$(f 1)" "$(f 2)" 2>/dev/null; then fail "put through a read-only dir succeeded"; fi
    chmod 700 "$R/rofail/review"
    [[ "$(records_list rofail)" == "$LIST_BEFORE" ]] || fail "manifest changed before the copies were written"
    [[ "$(cat "$R/rofail/review/one")" != "newer live" ]] || fail "review written through read-only dir"
    [[ -z "$(find "$R/rofail" -name '*.tmp.*')" ]] || fail "temp file left behind"
    records_put rofail one "$HOME/moved" merge "$(f 1)" "$(f 2)" || fail "retry failed"
    [[ "$(records_list rofail)" == one$'\t'"$HOME/moved"$'\t'merge && "$(cat "$R/rofail/review/one")" == "newer live" ]] || fail "retry result"
    records_remove rofail
    pass "a write failure leaves the manifest alone, no temp file, and a retry works"
fi

info "records_list, records_prune, records_remove, records_any"
rm -rf "$R"
if records_any; then fail "records_any with no records dir"; fi
[[ -z "$(records_list ghost)" ]] || fail "listing an unknown app printed"
records_list ghost || fail "listing an unknown app failed"
records_prune ghost "$HOME/x" || fail "pruning an unknown app failed"
records_remove ghost || fail "removing an unknown app failed"
[[ ! -d "$R/ghost" ]] || fail "housekeeping created a record"
pass "housekeeping on an unknown app is a quiet no-op"

mkdir -p "$R/.add-saved" && echo x > "$R/.add-saved/manifest.tsv"
if records_any; then fail "records_any counted a dot directory"; fi
mkdir -p "$R/emptyapp" && : > "$R/emptyapp/manifest.tsv"
if records_any; then fail "records_any counted an empty manifest"; fi
rm -rf "$R/emptyapp" && mkdir -p "$R/noman"
if records_any; then fail "records_any counted a dir with no manifest"; fi
pass "records_any ignores dot directories, empty manifests and bare directories"

files 'r' 'l'
records_put pa "keep me" "$HOME/keep me" replace "$(f 1)" "$(f 2)"
records_put pa "gone/deep/file" "$HOME/gone file" replace "$(f 1)" "$(f 2)"
records_put pa 'back\slash' "$HOME/back\\slash" replace "$(f 1)" "$(f 2)"
records_any || fail "records_any with records"
pass "records_any succeeds with a record"

records_prune pa "$HOME/keep me" "$HOME/back\\slash"
[[ "$(records_list pa)" == "keep me"$'\t'"$HOME/keep me"$'\t'replace$'\n''back\slash'$'\t'"$HOME/back\\slash"$'\t'replace ]] || fail "prune: $(records_list pa)"
[[ -f "$R/pa/repo/keep me" && -f "$R/pa/review/keep me" && -f "$R/pa/repo/back\\slash" ]] || fail "prune removed a kept copy"
[[ ! -e "$R/pa/repo/gone" && ! -e "$R/pa/review/gone" ]] || fail "prune left the dropped copy or its empty directories"
[[ "$(mode_of "$R/pa/manifest.tsv")" == 600 ]] || fail "prune changed the manifest's mode"
pass "records_prune keeps the given dests and removes the others' copies and directories"

records_prune pa "$HOME/keep me" "$HOME/back\\slash"
[[ "$(records_list pa | wc -l)" -eq 2 ]] || fail "second prune changed something"
pass "pruning again changes nothing"

records_prune pa
[[ ! -e "$R/pa" ]] || fail "pruning everything should remove the record"
if records_any; then fail "records_any after pruning everything"; fi
pass "pruning with no dests removes the app's record"

records_put pb f "$HOME/f" replace "$(f 1)" "$(f 2)"
records_put pc f "$HOME/f" replace "$(f 1)" "$(f 2)"
records_remove pb
[[ ! -e "$R/pb" && -f "$R/pc/manifest.tsv" ]] || fail "remove took the wrong app"
records_any || fail "records_any with one app left"
for bad in "" . .. ../state a/b; do
    if records_remove "$bad" 2>/dev/null; then fail "records_remove '$bad' accepted"; fi
done
[[ -f "$R/pc/manifest.tsv" && -d "$STATE_DIR" ]] || fail "a bad records_remove deleted something"
pass "records_remove removes one app, and refuses a name that isn't one"
rm -rf "$R"

# --- records_items ---

# Usage: items_is NAME APP SRC DEST STAGE ALL EXPECTED
items_is() {
    local got
    got=$(records_items "$2" "$3" "$4" "$5" "$6") || fail "$1: failed"
    [[ "$got" == "$7" ]] || fail "$1: got [$got], expected [$7]"
    pass "$1"
}
# Sets up one record and its live file. Usage: rec APP SRC STRATEGY REPO REVIEW LIVE STAGE
rec() {
    local app="$1" src="$2" strategy="$3"
    LIVE="$T/home/live-$app"
    STAGE="$T/in/stage-$app"
    printf '%s' "$4" > "$T/in/r"; printf '%s' "$5" > "$T/in/v"
    records_put "$app" "$src" "$LIVE" "$strategy" "$T/in/r" "$T/in/v"
    printf '%s' "$6" > "$LIVE"; printf '%s' "$7" > "$STAGE"
}
TAB=$'\t'

info "records_items: replaced files"
rec rf f replace old old old old
items_is "clean: nothing"                            rf f "$LIVE" "$STAGE" false ""
items_is "clean, all: nothing"                       rf f "$LIVE" "$STAGE" true  ""
rec rf f replace old reviewed old old
items_is "live equals the repo copy, review differs: nothing" rf f "$LIVE" "$STAGE" false ""
items_is "the same with all: nothing"                rf f "$LIVE" "$STAGE" true  ""
rec rf f replace old old mine old
items_is "unreviewed edit"                           rf f "$LIVE" "$STAGE" false "edited${TAB}[]"
items_is "unreviewed edit with all"                  rf f "$LIVE" "$STAGE" true  "edited${TAB}[]"
rec rf f replace old mine mine old
items_is "dismissed: hidden"                         rf f "$LIVE" "$STAGE" false ""
items_is "dismissed: shown with all"                 rf f "$LIVE" "$STAGE" true  "dismissed${TAB}[]"
rec rf f replace old mine mine2 old
items_is "changed again after a dismiss"             rf f "$LIVE" "$STAGE" false "edited${TAB}[]"
rec rf f replace old old mine new
items_is "conflict"                                  rf f "$LIVE" "$STAGE" false "conflict${TAB}[]"
items_is "conflict with all"                         rf f "$LIVE" "$STAGE" true  "conflict${TAB}[]"
rec rf f replace old mine mine new
items_is "conflict on a reviewed value is still returned" rf f "$LIVE" "$STAGE" false "conflict${TAB}[]"
rec rf f replace old old mine mine
items_is "live already matches the new repo version: reviewed" rf f "$LIVE" "$STAGE" true ""
rec rf f replace old old old new
items_is "repo moved, live didn't: nothing"          rf f "$LIVE" "$STAGE" false ""
rm "$LIVE"
items_is "live deleted: nothing, the next deploy restores it" rf f "$LIVE" "$STAGE" true ""
rec rf f replace old old mine new
rm "$STAGE"
items_is "file gone from the repo: an edit still shows" rf f "$LIVE" "$STAGE" false "edited${TAB}[]"
rec "sp" "sub dir/my file" replace old old mine new
items_is "a source with a space and a subdirectory"  sp "sub dir/my file" "$LIVE" "$STAGE" false "conflict${TAB}[]"

info "records_items: merged files"
rec mg s.json merge '{"a":1}' '{"a":1}' '{"a":1}' '{"a":1}'
items_is "clean: nothing"                            mg s.json "$LIVE" "$STAGE" true ""
rec mg s.json merge '{"a":1}' '{"a":9,"z":3}' '{"a":1}' '{"a":1}'
items_is "live equals the repo copy, review differs: nothing" mg s.json "$LIVE" "$STAGE" false ""
items_is "the same with all: nothing"                mg s.json "$LIVE" "$STAGE" true ""
rec mg s.json merge '{"o":{"b":1,"a":2}}' '{"o":{"b":1,"a":2}}' '{"o":{"a":2,"b":1}}' '{"o":{"a":2,"b":1}}'
items_is "reordered object keys aren't an edit"      mg s.json "$LIVE" "$STAGE" true ""
rec mg s.json merge '{"k":[1,2]}' '{"k":[1,2]}' '{"k":[2,1]}' '{"k":[1,2]}'
items_is "a reordered array is one edit"             mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"k\"]"
rec mg s.json merge '{"a":1}' '{"a":1}' '{"a":1,"o":{"x":1,"y":{"z":2}}}' '{"a":1}'
items_is "a new subtree is one item per key" mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"o\",\"x\"]"$'\n'"edited${TAB}[\"o\",\"y\",\"z\"]"
rec mg s.json merge '{"a":1,"b":2}' '{"a":1,"b":2}' '{"b":2}' '{"a":1,"b":2}'
items_is "a deleted key is an edit"                  mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"a\"]"
rec mg s.json merge '{"a":1,"b":2}' '{"b":2}' '{"b":2}' '{"a":1,"b":2}'
items_is "a deleted and dismissed key is hidden"     mg s.json "$LIVE" "$STAGE" false ""
items_is "a deleted and dismissed key shows with all" mg s.json "$LIVE" "$STAGE" true "dismissed${TAB}[\"a\"]"
rec mg s.json merge '{}' '{"l":null}' '{}' '{}'
items_is "null in review, absent in live and repo: nothing" mg s.json "$LIVE" "$STAGE" true ""
rec mg s.json merge '{}' '{}' '{"l":null}' '{}'
items_is "null differs from absent"                  mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"l\"]"
rec mg s.json merge '{}' '{}' '{"e":{}}' '{}'
items_is "a new empty object is an edit"             mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"e\"]"
rec mg s.json merge '{"a":{}}' '{"a":{}}' '{"a":{"x":1}}' '{"a":{}}'
items_is "a child under repo's {} is an edit"        mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"a\",\"x\"]"
rec mg s.json merge '{"a":{}}' '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":{}}'
items_is "reviewed child under repo's {}: hidden"    mg s.json "$LIVE" "$STAGE" false ""
items_is "reviewed child under repo's {}: shown with all" mg s.json "$LIVE" "$STAGE" true "dismissed${TAB}[\"a\",\"x\"]"
rec mg s.json merge '{"a":5}' '{"a":5}' '{"a":{"x":1}}' '{"a":5}'
items_is "scalar to object is one edit at the top"   mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"a\"]"
rec mg s.json merge '{"a.b@c":1,"a":{"b@c":1}}' '{"a.b@c":1,"a":{"b@c":1}}' '{"a.b@c":9,"a":{"b@c":1}}' '{"a.b@c":1,"a":{"b@c":1}}'
items_is "a dotted key stays one key"                mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"a.b@c\"]"
rec mg s.json merge '{"t\tb":1}' '{"t\tb":1}' '{"t\tb":2}' '{"t\tb":1}'
OUT=$(records_items mg s.json "$LIVE" "$STAGE" false)
[[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 && "$(printf '%s' "$OUT" | cut -f1)" == edited ]] || fail "tab in a key split the line: $OUT"
json_eq "$(printf '%s' "$OUT" | cut -f2)" '["t\tb"]' || fail "tab in a key: path is $OUT"
pass "a key with a tab keeps the line's two columns"

rec mg s.json merge '{"k":1}' '{"k":1}' '{"k":9}' '{"k":2}'
items_is "conflict"                                  mg s.json "$LIVE" "$STAGE" false "conflict${TAB}[\"k\"]"
rec mg s.json merge '{"k":1}' '{"k":9}' '{"k":9}' '{"k":2}'
items_is "conflict on a reviewed value is still returned" mg s.json "$LIVE" "$STAGE" false "conflict${TAB}[\"k\"]"
items_is "and only once with all"                    mg s.json "$LIVE" "$STAGE" true "conflict${TAB}[\"k\"]"
rec mg s.json merge '{"a":{"x":1,"y":2}}' '{"a":{"x":1,"y":2}}' '{"a":{"x":1,"y":2}}' '{"a":5}'
items_is "repo object to scalar, live equal to repo copy: the conflict still shows" mg s.json "$LIVE" "$STAGE" false "conflict${TAB}[\"a\"]"
rec mg s.json merge '{"a":{"x":1,"y":2}}' '{"a":{"x":1,"y":2}}' '{"a":7}' '{"a":{"x":1,"y":2}}'
items_is "live object to scalar, repo unchanged: one edit at the top, no conflict" mg s.json "$LIVE" "$STAGE" true "edited${TAB}[\"a\"]"
rec mg s.json merge '{"a":{"x":1,"y":2}}' '{"a":7}' '{"a":7}' '{"a":{"x":1,"y":2}}'
items_is "live object to scalar, dismissed: hidden"  mg s.json "$LIVE" "$STAGE" false ""
items_is "live object to scalar, dismissed: shown with all" mg s.json "$LIVE" "$STAGE" true "dismissed${TAB}[\"a\"]"
rec mg s.json merge '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":5}' '{"a":5}'
items_is "live already the repo's new scalar: reviewed, no conflict" mg s.json "$LIVE" "$STAGE" true ""
rec mg s.json merge '{"k":1,"j":1}' '{"k":1,"j":1}' '{"k":2,"j":9}' '{"k":2,"j":1}'
items_is "a key already the repo's new value is reviewed, another isn't" mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"j\"]"
rec mg s.json merge '{"k":1}' '{"k":3}' '{"k":2}' '{"k":2}'
items_is "a key matching the repo's new value: nothing even with all" mg s.json "$LIVE" "$STAGE" true ""
rec mg s.json merge '{"k":[{"a":1,"b":2}]}' '{"k":[{"a":1,"b":2}]}' '{"k":[{"b":2,"a":1}]}' '{"k":[{"a":1,"b":2}]}'
items_is "reordered object keys inside an array aren't an edit" mg s.json "$LIVE" "$STAGE" true ""

info "records_items: a plain value in the repo where live has an object"
rec mg s.json merge '{"a":5}' '{"a":{"x":1,"y":2}}' '{"a":{"x":1}}' '{"a":5}'
items_is "a key removed under the object is an edit, at the top" mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"a\"]"
rec mg s.json merge '{"a":5}' '{"a":{"x":1}}' '{"a":{}}' '{"a":5}'
items_is "the object emptied is an edit, at the top" mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"a\"]"
rec mg s.json merge '{"a":5}' '{"a":{"x":1}}' '{"a":{"x":2}}' '{"a":5}'
items_is "a changed key under the object is one edit at the top" mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"a\"]"
rec mg s.json merge '{"a":5}' '{"a":{"x":1}}' '{"a":{"x":1,"y":2}}' '{"a":5}'
items_is "a new key under the object is one edit at the top" mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"a\"]"
rec mg s.json merge '{"a":5}' '{"a":{"x":1}}' '{}' '{"a":5}'
items_is "the whole object deleted is an edit at the top" mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"a\"]"
rec mg s.json merge '{"t":{"a":5}}' '{"t":{"a":{"x":1,"y":2}}}' '{"t":{"a":{"x":1}}}' '{"t":{"a":5}}'
items_is "the same, deeper" mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"t\",\"a\"]"
rec mg s.json merge '{"a":5}' '{"a":{"x":1,"y":2}}' '{"a":{"x":1}}' '{"a":{"x":1}}'
items_is "the repo moved to the live object: reviewed" mg s.json "$LIVE" "$STAGE" true ""
rec mg s.json merge '{"a":{"x":1}}' '{"a":{"x":1,"y":2}}' '{"a":{"x":1}}' '{"a":{"x":1}}'
items_is "no plain value: a removed local key matches the repo, nothing" mg s.json "$LIVE" "$STAGE" true ""

info "records_items: a sibling edit near a conflict, with a scalar above it in the review copy"
rec mg s.json merge '{"a":{"x":1}}' '{"a":5}' '{"a":{"x":9,"y":2}}' '{"a":{"x":3}}'
items_is "the sibling shows beside the conflict" mg s.json "$LIVE" "$STAGE" false "conflict${TAB}[\"a\",\"x\"]"$'\n'"edited${TAB}[\"a\",\"y\"]"
rec mg s.json merge '{"t":{"a":{"x":1}}}' '{"t":5}' '{"t":{"a":{"x":9},"b":2}}' '{"t":{"a":{"x":3}}}'
items_is "two levels up: only the sibling" mg s.json "$LIVE" "$STAGE" false "conflict${TAB}[\"t\",\"a\",\"x\"]"$'\n'"edited${TAB}[\"t\",\"b\"]"
rec mg s.json merge '{"a":{"x":1}}' '{"a":5}' '{"a":{"x":9}}' '{"a":{"x":3}}'
items_is "no sibling: only the conflict" mg s.json "$LIVE" "$STAGE" false "conflict${TAB}[\"a\",\"x\"]"
rec mg s.json merge '{"a":{"x":1},"z":1}' '{"a":{"x":1,"y":2},"z":1}' '{"a":{"x":9,"y":3},"z":1}' '{"a":{"x":3},"z":1}'
items_is "no scalar: a sibling already showed" mg s.json "$LIVE" "$STAGE" false "conflict${TAB}[\"a\",\"x\"]"$'\n'"edited${TAB}[\"a\",\"y\"]"
rec mg s.json merge '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":5}' '{"a":{"x":2}}'
items_is "live object to scalar, repo changes inside: one conflict, no edit" mg s.json "$LIVE" "$STAGE" true "conflict${TAB}[\"a\"]"

info "records_items: dismissing a structural conflict stops the warning"
# Dismiss updates the item in the review copy, and in the repo copy from the stage (Task 7)
dismiss_a() {
    jq -c --slurpfile stage "$STAGE" \
        '.a = $stage[0].a' "$R/mg/repo/s.json" > "$T/in/r"
    jq -c --slurpfile live "$LIVE" \
        '.a = $live[0].a' "$R/mg/review/s.json" > "$T/in/v"
    records_set_repo mg s.json "$T/in/r"
    records_set_review mg s.json "$T/in/v"
}
pull_conflicts() {
    records_merge3 "$R/mg/repo/s.json" "$STAGE" "$LIVE" "$R/mg/review/s.json" | jq -c .conflicts
}
dismiss_stops() {
    local name="$1"
    items_is "$name: a conflict before the dismiss" mg s.json "$LIVE" "$STAGE" false "conflict${TAB}[\"a\"]"
    [[ "$(pull_conflicts)" == '[["a"]]' ]] || fail "$name: pull before dismiss: $(pull_conflicts)"
    dismiss_a
    [[ "$(pull_conflicts)" == '[]' ]] || fail "$name: pull after dismiss: $(pull_conflicts)"
    items_is "$name: nothing after the dismiss" mg s.json "$LIVE" "$STAGE" false ""
    items_is "$name: dismissed with all" mg s.json "$LIVE" "$STAGE" true "dismissed${TAB}${2:-[\"a\"]}"
    local out
    out=$(records_merge3 "$R/mg/repo/s.json" "$STAGE" "$LIVE" "$R/mg/review/s.json")
    json_eq "$(jq -c .live <<<"$out")" "$(cat "$LIVE")" || fail "$name: live moved after the dismiss: $out"
    json_eq "$(jq -c .repo <<<"$out")" "$(cat "$STAGE")" || fail "$name: repo moved after the dismiss: $out"
    json_eq "$(jq -c .review <<<"$out")" "$(cat "$R/mg/review/s.json")" || fail "$name: review moved after the dismiss: $out"
    [[ "$(jq -c .applied <<<"$out")" == '[]' ]] || fail "$name: applied after the dismiss: $out"
    pass "$name: the next pull changes nothing"
}
# repo:     copy              review/live         stage
rec mg s.json merge '{"a":5}' '{"a":5}' '{"a":5}' '{"a":{"x":1}}'
dismiss_stops "repo scalar to object, live unchanged"
rec mg s.json merge '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":{"x":1}}' '{"a":5}'
dismiss_stops "repo object to scalar, live unchanged"
rec mg s.json merge '{"a":{"x":1}}' '{"a":6}' '{"a":6}' '{"a":5}'
dismiss_stops "repo object to scalar, live a different scalar"
rec mg s.json merge '{"a":5}' '{"a":{"x":2}}' '{"a":{"x":2}}' '{"a":{"x":1}}'
dismiss_stops "repo scalar to object, live a different object" '["a","x"]'
rec mg s.json merge '{"a":{"x":1}}' '{"a":7}' '{"a":7}' '{"a":{"x":2}}'
dismiss_stops "live object to scalar, repo changes inside"
rec mg s.json merge '{"k":1}' '{"k":1,"old":3}' '{"k":1,"mine":2,"old":3}' '{"k":2}'
items_is "a key only the repo moved isn't an item; an unreviewed one is" mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"mine\"]"
items_is "with all, the reviewed one shows too"      mg s.json "$LIVE" "$STAGE" true "edited${TAB}[\"mine\"]"$'\n'"dismissed${TAB}[\"old\"]"
rec mg s.json merge '{"c":1,"e":1,"d":1}' '{"c":1,"e":1,"d":7}' '{"c":9,"e":2,"d":7}' '{"c":2,"e":1,"d":1}'
items_is "conflicts, then edits, then dismissed"     mg s.json "$LIVE" "$STAGE" true "conflict${TAB}[\"c\"]"$'\n'"edited${TAB}[\"e\"]"$'\n'"dismissed${TAB}[\"d\"]"
items_is "ALL must be true to show dismissed"        mg s.json "$LIVE" "$STAGE" false "conflict${TAB}[\"c\"]"$'\n'"edited${TAB}[\"e\"]"
rec mg s.json merge '{"k":1}' '{"k":1}' '{"k":9}' '{"k":2}'
rm "$STAGE"
items_is "file gone from the repo: an edit shows, no conflict" mg s.json "$LIVE" "$STAGE" false "edited${TAB}[\"k\"]"
rec mg s.json merge '{"k":1}' '{"k":1}' '{"k":9}' '{"k":1}'
rm "$LIVE"
items_is "live deleted: nothing, the next deploy restores it" mg s.json "$LIVE" "$STAGE" true ""

info "records_items: running it changes nothing"
rec mg s.json merge '{"k":1,"e":1}' '{"k":1,"e":1}' '{"k":9,"e":2}' '{"k":2,"e":1}'
A=$(cat "$R/mg/repo/s.json" "$R/mg/review/s.json" "$R/mg/manifest.tsv" "$LIVE")
records_items mg s.json "$LIVE" "$STAGE" true >/dev/null
[[ "$(cat "$R/mg/repo/s.json" "$R/mg/review/s.json" "$R/mg/manifest.tsv" "$LIVE")" == "$A" ]] || fail "records_items changed something"
pass "records and live are left as they were"

info "records_items: bad input"
rec mg s.json merge '{"k":1}' '{"k":1}' 'not json' '{"k":1}'
if OUT=$(records_items mg s.json "$LIVE" "$STAGE" true 2>/dev/null); then fail "invalid live accepted: $OUT"; fi
[[ -z "$OUT" ]] || fail "invalid live printed items: $OUT"
rec mg s.json merge '{"k":1}' '{"k":1}' '{"k":1}' 'not json'
if OUT=$(records_items mg s.json "$LIVE" "$STAGE" true 2>/dev/null); then fail "invalid stage accepted: $OUT"; fi
[[ -z "$OUT" ]] || fail "invalid stage printed items: $OUT"
pass "invalid JSON fails with no items"
if records_items nosuch s.json "$LIVE" "$STAGE" true 2>/dev/null; then fail "unknown app accepted"; fi
if records_items mg nosuch "$LIVE" "$STAGE" true 2>/dev/null; then fail "unknown source accepted"; fi
pass "an unrecorded source fails"
rec rf f replace old old mine new
rm "$R/rf/review/f"
if records_items rf f "$LIVE" "$STAGE" true 2>/dev/null; then fail "missing review copy accepted"; fi
pass "a missing copy fails instead of reporting an edit"

info "manifest: sources that look like the same number stay apart"
rm -rf "$R/num"
files one point-one live
records_put num 1 "$T/d1" replace "$(f 1)" "$(f 3)"
records_put num 1.0 "$T/d2" replace "$(f 2)" "$(f 3)"
records_put num 1e0 "$T/d3" merge "$(f 2)" "$(f 3)"
[[ "$(records_list num | wc -l)" -eq 3 ]] || fail "a line was dropped: $(records_list num)"
records_put num 1 "$T/d1b" replace "$(f 1)" "$(f 3)"
[[ "$(records_list num | wc -l)" -eq 3 ]] || fail "updating 1 touched another line: $(records_list num)"
[[ "$(records__strategy num 1.0)" == replace && "$(records__strategy num 1e0)" == merge ]] || fail "strategy of the wrong line"
[[ "$(records__dest num 1.0)" == "$T/d2" && "$(records__dest num 1)" == "$T/d1b" ]] || fail "dest of the wrong line"
pass "1, 1.0 and 1e0 are three sources"

info "records_prune_srcs: gone sources go once another source records their dest"
rm -rf "$R/ps"
files one
records_put ps old "$T/same" replace "$(f 1)" "$(f 1)"
records_put ps gone "$T/alone" replace "$(f 1)" "$(f 1)"
records_put ps 1 "$T/n" replace "$(f 1)" "$(f 1)"
records_prune_srcs ps new 1 || fail "failed"
[[ "$(records_list ps | wc -l)" -eq 3 ]] || fail "a line with no successor went: $(records_list ps)"
records_put ps new "$T/same" replace "$(f 1)" "$(f 1)"
records_prune_srcs ps new 1 || fail "failed"
[[ "$(records_list ps | cut -f1 | sort | paste -sd' ' -)" == "1 gone new" ]] || fail "lines: $(records_list ps)"
[[ ! -e "$R/ps/repo/old" && ! -e "$R/ps/review/old" ]] || fail "copies left"
records_prune_srcs nosuch x || fail "an unknown app failed"
pass "records_prune_srcs"

info "records_deploy: results and records, one file at a time"
RD="$T/rd"
rm -rf "$RD" "$R/d"
mkdir -p "$RD"
files new1 new2 new3
D="$RD/sub/dir/f"
records_deploy d f "$(f 1)" "$D" 0640 replace || fail "fresh failed"
[[ "$RECORDS_DEPLOY_RESULT" == fresh && "$(cat "$D")" == new1 && "$(mode_of "$D")" == 640 ]] || fail "fresh: $RECORDS_DEPLOY_RESULT"
records_deploy d f "$(f 1)" "$D" 0640 replace || fail "none failed"
[[ "$RECORDS_DEPLOY_RESULT" == none ]] || fail "none: $RECORDS_DEPLOY_RESULT"
records_deploy d f "$(f 2)" "$D" 0600 replace || fail "apply failed"
[[ "$RECORDS_DEPLOY_RESULT" == apply && "$(cat "$D")" == new2 && "$(mode_of "$D")" == 600 ]] || fail "apply: $RECORDS_DEPLOY_RESULT"
printf mine > "$D"
records_deploy d f "$(f 2)" "$D" 0600 replace || fail "keep failed"
[[ "$RECORDS_DEPLOY_RESULT" == keep && "$(cat "$D")" == mine && "$(cat "$R/d/review/f")" == new2 ]] || fail "keep: $RECORDS_DEPLOY_RESULT"
records_deploy d f "$(f 3)" "$D" 0600 replace || fail "conflict failed"
[[ "$RECORDS_DEPLOY_RESULT" == conflict && "$(cat "$D")" == mine && "$(cat "$R/d/repo/f")" == new2 ]] || fail "conflict: $RECORDS_DEPLOY_RESULT"
RECORDS_FORCE=force records_deploy d f "$(f 3)" "$D" 0600 replace || fail "force failed"
[[ "$RECORDS_DEPLOY_RESULT" == apply && "$(cat "$D")" == new3 && "$(cat "$R/d/repo/f")" == new3 && "$(cat "$R/d/review/f")" == new3 ]] || fail "force: $RECORDS_DEPLOY_RESULT"
if records_deploy d f "$RD/no-such" "$D" 0600 replace 2>/dev/null; then fail "missing source accepted"; fi
if records_deploy d f "$(f 3)" "$D" 0600 bogus 2>/dev/null; then fail "unknown strategy accepted"; fi
if records_deploy d ../x "$(f 3)" "$D" 0600 replace 2>/dev/null; then fail "bad source accepted"; fi
[[ "$(cat "$D")" == new3 ]] || fail "live changed"
pass "replaced file results"

info "records_deploy: merged file results"
rm -rf "$R/m"
DJ="$RD/s.json"
files '{"a":1,"b":1}' '{"a":2,"b":2}' '{"a":3,"b":2}' 'not json' '[1]' '{} {}'
records_deploy m s.json "$(f 1)" "$DJ" 0644 merge || fail "fresh failed"
[[ "$RECORDS_DEPLOY_RESULT" == fresh && "$RECORDS_DEPLOY_CONFLICTS" == "[]" ]] || fail "fresh: $RECORDS_DEPLOY_RESULT"
printf '{"a":9,"b":1,"l":1}' > "$DJ"
records_deploy m s.json "$(f 2)" "$DJ" 0644 merge || fail "conflict failed"
[[ "$RECORDS_DEPLOY_RESULT" == conflict && "$RECORDS_DEPLOY_CONFLICTS" == '[["a"]]' ]] || fail "conflict: $RECORDS_DEPLOY_RESULT $RECORDS_DEPLOY_CONFLICTS"
json_eq "$(cat "$DJ")" '{"a":9,"b":2,"l":1}' || fail "live: $(cat "$DJ")"
json_eq "$(cat "$R/m/repo/s.json")" '{"a":1,"b":2}' || fail "repo copy: $(cat "$R/m/repo/s.json")"
RECORDS_FORCE=force records_deploy m s.json "$(f 3)" "$DJ" 0644 merge || fail "force failed"
[[ "$RECORDS_DEPLOY_RESULT" == apply && "$RECORDS_DEPLOY_CONFLICTS" == "[]" ]] || fail "force: $RECORDS_DEPLOY_RESULT"
json_eq "$(cat "$DJ")" '{"a":3,"b":2,"l":1}' || fail "forced live: $(cat "$DJ")"
json_eq "$(cat "$R/m/review/s.json")" '{"a":3,"b":2}' || fail "forced review: $(cat "$R/m/review/s.json")"
RECORDS_FORCE=reset records_deploy m s.json "$(f 3)" "$DJ" 0644 merge || fail "reset failed"
json_eq "$(cat "$DJ")" '{"a":3,"b":2}' || fail "reset live: $(cat "$DJ")"
for bad in 4 5 6; do
    if records_deploy m s.json "$(f $bad)" "$DJ" 0644 merge 2>/dev/null; then fail "bad repo JSON $bad accepted"; fi
done
json_eq "$(cat "$R/m/repo/s.json")" '{"a":3,"b":2}' || fail "records moved on a bad source"
cp "$(f 4)" "$DJ"
if records_deploy m s.json "$(f 3)" "$DJ" 0644 merge 2>/dev/null; then fail "invalid live accepted"; fi
[[ "$(cat "$DJ")" == "not json" ]] || fail "invalid live touched"
printf '{}\n{}\n' > "$DJ"
if records_deploy m s.json "$(f 3)" "$DJ" 0644 merge 2>/dev/null; then fail "two documents in live accepted"; fi
[[ "$(cat "$DJ")" == $'{}\n{}' ]] || fail "two documents touched"
printf '{}' > "$R/m/review/s.json"
printf 'broken' > "$R/m/repo/s.json"
printf '{"a":1}' > "$DJ"
if records_deploy m s.json "$(f 3)" "$DJ" 0644 merge 2>/dev/null; then fail "corrupt repo copy accepted"; fi
[[ "$(cat "$DJ")" == '{"a":1}' && "$(cat "$R/m/repo/s.json")" == broken ]] || fail "corrupt repo copy: something moved"
pass "merged file results"

info "records_deploy: a write that fails partway puts the live file back"
rm -rf "$R/p"
DP="$RD/p"
files old new
records_deploy p f "$(f 1)" "$DP" 0644 replace || fail "fresh failed"
# Copying the staged temp file over the live one writes part of it and fails, the way a
# full disk would, with the live file already truncated. Putting it back works.
cat() {
    if [[ "${1:-}" == "$RD/."* && ! -e "$RD/tripped" ]]; then
        : > "$RD/tripped"
        printf 'ne'
        return 1
    fi
    command cat "$@"
}
RC=0
records_deploy p f "$(f 2)" "$DP" 0644 replace 2>/dev/null || RC=$?
unset -f cat
[[ $RC -ne 0 ]] || fail "a failed write reported success"
[[ -e "$RD/tripped" ]] || fail "the failure was never injected"
[[ "$(cat "$DP")" == old ]] || fail "live not put back: $(cat "$DP")"
[[ "$(cat "$R/p/repo/f")" == old && "$(cat "$R/p/review/f")" == old ]] || fail "records advanced"
[[ -z "$(find "$RD" -maxdepth 1 -name '.p.dotfiles.*')" ]] || fail "temp files left: $(find "$RD" -name '.p.*')"
records_deploy p f "$(f 2)" "$DP" 0644 replace || fail "retry failed"
[[ "$(cat "$DP")" == new && "$(cat "$R/p/repo/f")" == new ]] || fail "retry did not apply"
pass "partial write recovered"

info "records_deploy: when the live file can't be put back, its old content stays in a temp file"
files old new
rm -rf "$R/p2"
DP="$RD/p2"
records_deploy p2 f "$(f 1)" "$DP" 0644 replace || fail "fresh failed"
# Neither the write nor putting it back works
cat() {
    if [[ "${1:-}" == "$RD/."* ]]; then
        printf 'x'
        return 1
    fi
    command cat "$@"
}
RC=0
MSG=$(records_deploy p2 f "$(f 2)" "$DP" 0644 replace 2>&1) || RC=$?
unset -f cat
[[ $RC -ne 0 ]] || fail "a failed write reported success"
[[ "$MSG" == *"could not be put back"* ]] || fail "not explained: $MSG"
KEPT="${MSG##*content is at }"
KEPT="${KEPT%%$'\n'*}"
[[ "$(cat "$KEPT")" == old ]] || fail "old content lost: '$KEPT'"
[[ "$(cat "$R/p2/repo/f")" == old ]] || fail "records advanced"
rm -f "$KEPT"
pass "old content kept and named"

echo
pass "All records tests passed"
