#!/usr/bin/env bash
# records.sh - what dotfiles remembers about each managed file, and the three-way
# decision that uses it to apply repo changes without losing local edits.
#
# Layout, under $STATE_DIR/records/<app>/:
#   manifest.tsv   lines SRC<TAB>DEST<TAB>STRATEGY
#   repo/<src>     the last repo version accepted; pull compares against it
#   review/<src>   the live file as of the last review; add compares against it
# Copies are mode 0600 in directories of mode 0700. Names beginning with a dot under
# records/ are not apps.
#
# Sourced by both dotfiles and lib/installer.sh, so it uses neither. Requires STATE_DIR
# (lib/state.sh) and jq.

RECORDS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

records__error() {
    printf 'records: %s\n' "$1" >&2
    return 1
}

# An app name is one path component
records__check_app() {
    case "$1" in
        "" | .* | */* | *$'\t'* | *$'\n'*)
            records__error "bad app name: '$1'" ;;
    esac
}

# A source is a relative path that stays inside the copies directory, and fits a manifest line
records__check_src() {
    case "/$1/" in
        // | //* | */../* | *$'\t'* | *$'\n'*)
            records__error "bad source path: '$1'" ;;
    esac
}

records__manifest() {
    echo "$STATE_DIR/records/$1/manifest.tsv"
}

# Usage: records_repo_path APP SRC
records_repo_path() {
    records__check_app "$1" && records__check_src "$2" || return 1
    echo "$STATE_DIR/records/$1/repo/$2"
}

# Usage: records_review_path APP SRC
records_review_path() {
    records__check_app "$1" && records__check_src "$2" || return 1
    echo "$STATE_DIR/records/$1/review/$2"
}

# Replace a file in one atomic step, following a symlink at FROM. Anything created is private.
# Usage: records__copy FROM TO
records__copy() {
    local from="$1" to="$2" tmp="$2.tmp.$$"
    (
        umask 077
        mkdir -p "$(dirname "$to")" && cat "$from" > "$tmp" && mv -f "$tmp" "$to"
    ) 2>/dev/null && return 0
    rm -f "$tmp"
    records__error "could not write $to"
}

# The manifest's strategy for SRC; fails if SRC has no record
# Usage: records__strategy APP SRC
records__strategy() {
    local file line
    file=$(records__manifest "$1")
    line=$([[ -f "$file" ]] && RECORDS_SRC="$2" awk -F'\t' '$1 == ENVIRON["RECORDS_SRC"] { print $3; exit }' "$file") || line=""
    [[ -n "$line" ]] || return 1
    echo "$line"
}

# Write both copies, then the manifest line: an interrupted run has no line pointing at
# copies that were never written.
# Usage: records_put APP SRC DEST STRATEGY REPO_FILE LIVE_FILE
records_put() {
    local app="$1" src="$2" dest="$3" strategy="$4" repo_file="$5" live_file="$6"
    local repo_copy review_copy file tmp
    repo_copy=$(records_repo_path "$app" "$src") || return 1
    review_copy=$(records_review_path "$app" "$src") || return 1
    case "$dest" in
        "" | *$'\t'* | *$'\n'*) records__error "bad destination: '$dest'"; return 1 ;;
    esac
    case "$strategy" in
        replace | merge) ;;
        *) records__error "unknown strategy: '$strategy'"; return 1 ;;
    esac
    [[ -r "$repo_file" ]] || { records__error "cannot read $repo_file"; return 1; }
    [[ -r "$live_file" ]] || { records__error "cannot read $live_file"; return 1; }

    records__copy "$repo_file" "$repo_copy" || return 1
    records__copy "$live_file" "$review_copy" || return 1

    file=$(records__manifest "$app")
    tmp="$file.tmp.$$"
    if ! (
        umask 077
        {
            if [[ -f "$file" ]]; then
                RECORDS_SRC="$src" awk -F'\t' '$1 != ENVIRON["RECORDS_SRC"]' "$file"
            fi
            printf '%s\t%s\t%s\n' "$src" "$dest" "$strategy"
        } > "$tmp" && mv -f "$tmp" "$file"
    ) 2>/dev/null; then
        rm -f "$tmp"
        records__error "could not write $file"
        return 1
    fi
}

# Usage: records__set_copy APP SRC FILE COPY
records__set_copy() {
    records__strategy "$1" "$2" >/dev/null || { records__error "no record of $1/$2"; return 1; }
    [[ -r "$3" ]] || { records__error "cannot read $3"; return 1; }
    records__copy "$3" "$4"
}

# Replace one copy of a recorded source
# Usage: records_set_repo APP SRC FILE
records_set_repo() {
    local copy
    copy=$(records_repo_path "$1" "$2") || return 1
    records__set_copy "$1" "$2" "$3" "$copy"
}

# Usage: records_set_review APP SRC FILE
records_set_review() {
    local copy
    copy=$(records_review_path "$1" "$2") || return 1
    records__set_copy "$1" "$2" "$3" "$copy"
}

# Usage: records_list APP
records_list() {
    local file
    records__check_app "$1" || return 1
    file=$(records__manifest "$1")
    [[ ! -f "$file" ]] || cat "$file"
}

# Forget every source of APP whose DEST isn't listed, and its copies. The manifest goes
# first, so an interrupted run leaves unused copies rather than a line missing its copies.
# Usage: records_prune APP DEST...
records_prune() {
    local app="$1" file tmp src dest strategy d keep
    local -a drop=()
    records__check_app "$app" || return 1
    shift
    file=$(records__manifest "$app")
    [[ -f "$file" ]] || return 0
    tmp="$file.tmp.$$"
    (umask 077; : > "$tmp") || { records__error "could not write $tmp"; return 1; }
    while IFS=$'\t' read -r src dest strategy; do
        keep=false
        for d in "$@"; do
            [[ "$d" != "$dest" ]] || keep=true
        done
        if [[ "$keep" == true ]]; then
            printf '%s\t%s\t%s\n' "$src" "$dest" "$strategy" >> "$tmp"
        else
            drop+=("$src")
        fi
    done < "$file"
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        records_remove "$app"
        return
    fi
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    for src in ${drop[@]+"${drop[@]}"}; do
        rm -f "$STATE_DIR/records/$app/repo/$src" "$STATE_DIR/records/$app/review/$src"
    done
    find "$STATE_DIR/records/$app/repo" "$STATE_DIR/records/$app/review" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# Usage: records_remove APP
records_remove() {
    records__check_app "$1" || return 1
    rm -rf "${STATE_DIR:?}/records/$1"
}

# True if any app has records
records_any() {
    local file
    for file in "$STATE_DIR"/records/*/manifest.tsv; do
        [[ -s "$file" ]] && return 0
    done
    return 1
}

# The pull table for a replaced file. A live file that's gone is restored by the deploy.
# Usage: records_decide_file LIVE REPO_COPY NEW
# Prints: apply, none, keep, same or conflict
records_decide_file() {
    local live="$1" repo="$2" new="$3"
    [[ -r "$repo" ]] || { records__error "cannot read $repo"; return 1; }
    [[ -r "$new" ]] || { records__error "cannot read $new"; return 1; }
    if [[ ! -e "$live" ]]; then
        echo apply
    elif cmp -s "$live" "$repo"; then
        if cmp -s "$new" "$repo"; then echo none; else echo apply; fi
    elif cmp -s "$new" "$repo"; then
        echo keep
    elif cmp -s "$live" "$new"; then
        echo same
    else
        echo conflict
    fi
}

# The pull table for a merged file, per key: see lib/merge3.jq. A missing LIVE fails, so
# restoring a deleted merged file is up to the caller.
# Usage: records_merge3 BASE NEW LIVE REVIEW
# Prints: {live, repo, review, conflicts, applied}
records_merge3() {
    jq -nc \
        --slurpfile base "$1" --slurpfile new "$2" \
        --slurpfile live "$3" --slurpfile review "$4" \
        -f "$RECORDS_LIB_DIR/merge3.jq"
}

# What add should ask about for one file, conflicts first. An item is an edit since the
# last review, unless it matches the repo copy, which counts as reviewed. Dismissed items
# differ from the repo copy but match the review copy, and show only when ALL is true.
# Conflicts always show. A deleted live file has no items: the next deploy restores it.
# With no STAGE_FILE (the repo dropped the file), nothing can conflict with the repo.
# Usage: records_items APP SRC DEST STAGE_FILE ALL
# Prints: KIND<TAB>PATH_JSON lines; KIND is edited, conflict or dismissed, and PATH_JSON
# is [] for a replaced file.
records_items() {
    local app="$1" src="$2" dest="$3" stage="$4" all="$5"
    local repo review strategy new
    repo=$(records_repo_path "$app" "$src") || return 1
    review=$(records_review_path "$app" "$src") || return 1
    strategy=$(records__strategy "$app" "$src") || { records__error "no record of $app/$src"; return 1; }
    [[ -r "$repo" ]] || { records__error "cannot read $repo"; return 1; }
    [[ -r "$review" ]] || { records__error "cannot read $review"; return 1; }
    [[ -e "$dest" ]] || return 0
    new="$stage"
    [[ -e "$new" ]] || new="$repo"

    if [[ "$strategy" == merge ]]; then
        records__items_merged "$dest" "$repo" "$new" "$review" "$all"
        return
    fi

    local decision
    decision=$(records_decide_file "$dest" "$repo" "$new") || return 1
    if [[ "$decision" == conflict ]]; then
        printf 'conflict\t[]\n'
    elif ! cmp -s "$dest" "$repo"; then
        if ! cmp -s "$dest" "$review"; then
            printf 'edited\t[]\n'
        elif [[ "$all" == true ]]; then
            printf 'dismissed\t[]\n'
        fi
    fi
}

# Usage: records__items_merged LIVE REPO NEW REVIEW ALL
records__items_merged() {
    local live="$1" repo="$2" new="$3" review="$4" all="$5" conflicts
    conflicts=$(records_merge3 "$repo" "$new" "$live" "$review" | jq -c .conflicts) || return 1
    [[ -n "$conflicts" ]] || return 1
    jq -nr \
        --slurpfile live "$live" --slurpfile repo "$repo" --slurpfile review "$review" \
        --argjson conflicts "$conflicts" --arg all "$all" '
        def at($p):
          if ($p | length) == 0 then [.]
          elif type == "object" and has($p[0]) then .[$p[0]] | at($p[1:])
          else [] end;
        def child($k): if length == 1 then .[0] | at([$k]) else [] end;
        def big: length == 1 and (.[0] | type) == "object" and (.[0] | length) > 0;
        def any_object: length == 1 and (.[0] | type) == "object";
        # The smallest paths where wrapped values differ: into objects on both sides, or
        # into the only side present, so a new subtree is one path per key.
        def diff($l; $r; $p):
          if $l == $r then empty
          elif ($l | any_object) and ($r | any_object)
            or ($l == [] and ($r | big)) or ($r == [] and ($l | big)) then
            ((($l[0] // {}) | keys_unsorted) + (($r[0] // {}) | keys_unsorted) | unique)[] as $k
            | diff($l | child($k); $r | child($k); $p + [$k])
          else $p end;
        def is_prefix($a; $b): $b[:($a | length)] == $a;
        def near_conflict($p):
          any($conflicts[]; is_prefix(.; $p) or is_prefix($p; .));
        def item($kind): "\($kind)\t\(tojson)";
        $live[0] as $l | $repo[0] as $b | $review[0] as $v
        | ($conflicts[] | item("conflict")),
          (diff([$l]; [$v]; []) as $p
            | select(($l | at($p)) != ($b | at($p)) and (near_conflict($p) | not))
            | $p | item("edited")),
          (if $all == "true" then
             diff([$l]; [$b]; []) as $p
             | select(($l | at($p)) == ($v | at($p)) and (near_conflict($p) | not))
             | $p | item("dismissed")
           else empty end)
    '
}
