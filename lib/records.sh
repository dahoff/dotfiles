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

# How records_deploy treats edits: empty (the pull table), force or reset. Set by the caller.
RECORDS_FORCE=""
# What the last records_deploy did; see there
RECORDS_DEPLOY_RESULT=""
RECORDS_DEPLOY_CONFLICTS="[]"

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
    line=$([[ -f "$file" ]] && RECORDS_SRC="$2" awk -F'\t' '($1 "") == (ENVIRON["RECORDS_SRC"] "") { print $3; exit }' "$file") || line=""
    [[ -n "$line" ]] || return 1
    echo "$line"
}

# The manifest's destination for SRC; fails if SRC has no record
# Usage: records__dest APP SRC
records__dest() {
    local file line
    file=$(records__manifest "$1")
    line=$([[ -f "$file" ]] && RECORDS_SRC="$2" awk -F'\t' '($1 "") == (ENVIRON["RECORDS_SRC"] "") { print $2; exit }' "$file") || line=""
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
                RECORDS_SRC="$src" awk -F'\t' '($1 "") != (ENVIRON["RECORDS_SRC"] "")' "$file"
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

# Where the copies of a forgotten DEST wait, in case another app or source takes it over.
# Usage: records__released_dir DEST
records__released_dir() {
    echo "$STATE_DIR/records/.released/$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}

# Keep the copies of a file no app tracks any more. Best effort: without them, a later
# deploy of the same DEST starts over, after a snapshot.
# Usage: records__release APP SRC DEST STRATEGY
records__release() {
    local dir
    dir=$(records__released_dir "$3")
    (
        umask 077
        rm -rf "$dir"
        mkdir -p "$dir" \
            && cat "$STATE_DIR/records/$1/repo/$2" > "$dir/repo" \
            && cat "$STATE_DIR/records/$1/review/$2" > "$dir/review" \
            && printf '%s\t%s\n' "$3" "$4" > "$dir/meta"
    ) 2>/dev/null || rm -rf "$dir"
}

# Forget one source of APP and its copies, the manifest first
# Usage: records__forget APP SRC
records__forget() {
    local app="$1" src="$2" file tmp
    file=$(records__manifest "$app")
    [[ -f "$file" ]] || return 0
    tmp="$file.tmp.$$"
    if ! (
        umask 077
        RECORDS_SRC="$src" awk -F'\t' '($1 "") != (ENVIRON["RECORDS_SRC"] "")' "$file" > "$tmp"
    ) 2>/dev/null; then
        rm -f "$tmp"
        records__error "could not write $tmp"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        records_remove "$app"
        return
    fi
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    rm -f "$STATE_DIR/records/$app/repo/$src" "$STATE_DIR/records/$app/review/$src"
    find "$STATE_DIR/records/$app/repo" "$STATE_DIR/records/$app/review" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# Forget every source of APP that's gone from its config, once a listed source records the
# same DEST. Until then the old line is the only base there is for that file.
# Usage: records_prune_srcs APP SRC...
records_prune_srcs() {
    local app="$1" file src dest strategy other s listed covered
    records__check_app "$app" || return 1
    shift
    file=$(records__manifest "$app")
    [[ -f "$file" ]] || return 0
    local -a srcs=() dests=()
    while IFS=$'\t' read -r src dest strategy; do
        srcs+=("$src")
        dests+=("$dest")
    done < "$file"
    local i j
    for i in "${!srcs[@]}"; do
        listed=false
        for s in "$@"; do
            [[ "$s" != "${srcs[$i]}" ]] || listed=true
        done
        [[ "$listed" == false ]] || continue
        covered=false
        for j in "${!srcs[@]}"; do
            [[ "${dests[$j]}" == "${dests[$i]}" && "$j" != "$i" ]] || continue
            for s in "$@"; do
                [[ "$s" != "${srcs[$j]}" ]] || covered=true
            done
        done
        if [[ "$covered" == true ]]; then
            records__forget "$app" "${srcs[$i]}" || return 1
        fi
    done
}

# Forget every source of APP whose DEST isn't listed. Its copies move aside, so that another
# app taking the file over still has a base. The manifest goes first, so an interrupted run
# leaves unused copies rather than a line missing its copies.
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
            records__release "$app" "$src" "$dest" "$strategy"
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

# True if dotfiles has written DEST: any app records it, or did until it was dropped
# Usage: records_knows_dest DEST
records_knows_dest() {
    local file src dest strategy
    for file in "$STATE_DIR"/records/*/manifest.tsv; do
        [[ -f "$file" ]] || continue
        while IFS=$'\t' read -r src dest strategy; do
            [[ "$dest" != "$1" ]] || return 0
        done < "$file"
    done
    [[ -f "$(records__released_dir "$1")/meta" ]]
}

# The record SRC can take over for DEST when it has none of its own: the source was renamed,
# or the file moved from another app, so what's live is still judged against what was
# accepted. Needs the same strategy; a switch starts over. Looks in this app, then the others,
# then the copies of a dropped file.
# Usage: records__adopt_source APP SRC DEST STRATEGY
# Prints: OWNER<TAB>OWNER_SRC, or .released<TAB> for a dropped file's copies; nothing if none
records__adopt_source() {
    local app="$1" src="$2" dest="$3" strategy="$4" file owner o_src o_dest o_strategy dir
    for file in "$(records__manifest "$app")" "$STATE_DIR"/records/*/manifest.tsv; do
        [[ -f "$file" ]] || continue
        owner=$(basename "$(dirname "$file")")
        while IFS=$'\t' read -r o_src o_dest o_strategy; do
            [[ "$o_dest" == "$dest" && "$o_strategy" == "$strategy" ]] || continue
            [[ "$owner" != "$app" || "$o_src" != "$src" ]] || continue
            [[ -r "$STATE_DIR/records/$owner/repo/$o_src" && -r "$STATE_DIR/records/$owner/review/$o_src" ]] || continue
            printf '%s\t%s\n' "$owner" "$o_src"
            return 0
        done < "$file"
    done
    dir=$(records__released_dir "$dest")
    [[ -f "$dir/meta" ]] || return 0
    if [[ "$(cat "$dir/meta")" == "$dest"$'\t'"$strategy" ]]; then
        printf '.released\t\n'
    fi
}

# Take over a record when SRC has none of its own (see records__adopt_source)
# Usage: records__adopt APP SRC DEST STRATEGY
records__adopt() {
    local app="$1" src="$2" dest="$3" strategy="$4" found owner o_src dir
    records_is_fresh "$app" "$src" "$dest" "$strategy" || return 0
    found=$(records__adopt_source "$app" "$src" "$dest" "$strategy")
    [[ -n "$found" ]] || return 0
    IFS=$'\t' read -r owner o_src <<< "$found"
    dir=$(records__released_dir "$dest")
    if [[ "$owner" == .released ]]; then
        records_put "$app" "$src" "$dest" "$strategy" "$dir/repo" "$dir/review" || return 1
    else
        records_put "$app" "$src" "$dest" "$strategy" \
            "$STATE_DIR/records/$owner/repo/$o_src" "$STATE_DIR/records/$owner/review/$o_src" || return 1
        records__forget "$owner" "$o_src" || return 1
    fi
    rm -rf "$dir"
}

# True if deploying SRC starts over rather than comparing against its record: no record,
# one for another strategy or destination, or its copies are gone. What's live then may
# never have been ours, so the caller takes a snapshot first.
# Usage: records_is_fresh APP SRC DEST STRATEGY
records_is_fresh() {
    local app="$1" src="$2" dest="$3" strategy="$4" repo review
    repo=$(records_repo_path "$app" "$src") || return 0
    review=$(records_review_path "$app" "$src") || return 0
    [[ "$(records__strategy "$app" "$src")" == "$strategy" ]] || return 0
    [[ "$(records__dest "$app" "$src")" == "$dest" ]] || return 0
    [[ -r "$repo" && -r "$review" ]] || return 0
    return 1
}

# True if a recorded file has edits nobody has reviewed. A file that can't be read for
# that counts as edited.
# Usage: records_has_edits APP SRC DEST
records_has_edits() {
    local items
    items=$(records_items "$1" "$2" "$3" "" false 2>/dev/null) || return 0
    [[ -n "$items" ]]
}

# Usage: records__chmod MODE DEST
records__chmod() {
    chmod "$1" "$2" 2>/dev/null || { records__error "could not set the mode of $2"; return 1; }
}

# Write complete content over a live file, keeping a symlink and the file itself. The
# content goes to a temp file first, beside the live file where possible, so a full disk
# shows before the live file is touched. If the write still fails partway, what was there
# is put back. A file that doesn't exist yet appears in one step, with its mode.
# Usage: records__write_live FROM DEST MODE
records__write_live() {
    local from="$1" dest="$2" mode="$3" dir pattern staged keep=""
    dir=$(dirname "$dest")
    mkdir -p "$dir" 2>/dev/null || { records__error "could not create $dir"; return 1; }
    if [[ -e "$dest" && ! -w "$dest" ]]; then
        records__error "$dest is not writable"
        return 1
    fi
    pattern="$dir/.$(basename "$dest").dotfiles.XXXXXX"
    staged=$(mktemp "$pattern" 2>/dev/null) || staged=$(mktemp) || { records__error "could not create a temp file for $dest"; return 1; }
    if ! { cat "$from" > "$staged" && cmp -s "$from" "$staged"; } 2>/dev/null; then
        rm -f "$staged"
        records__error "could not write a temp copy for $dest"
        return 1
    fi

    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
        if ! { chmod "$mode" "$staged" && mv -f "$staged" "$dest"; } 2>/dev/null; then
            rm -f "$staged"
            records__error "could not create $dest"
            return 1
        fi
        return 0
    fi

    # A dangling symlink has nothing to put back
    if [[ -e "$dest" ]]; then
        keep=$(mktemp "$pattern" 2>/dev/null) || keep=$(mktemp) || { rm -f "$staged"; records__error "could not create a temp file for $dest"; return 1; }
        if ! { cat "$dest" > "$keep" && cmp -s "$dest" "$keep"; } 2>/dev/null; then
            rm -f "$staged" "$keep"
            records__error "could not read $dest"
            return 1
        fi
    fi
    if ! { cat "$staged" > "$dest" && cmp -s "$staged" "$dest"; } 2>/dev/null; then
        rm -f "$staged"
        if [[ -n "$keep" ]]; then
            if ! { cat "$keep" > "$dest" && cmp -s "$keep" "$dest"; } 2>/dev/null; then
                records__error "writing $dest failed and it could not be put back; its old content is at $keep"
                return 1
            fi
            rm -f "$keep"
        fi
        records__error "could not write $dest; it was left as it was"
        return 1
    fi
    rm -f "$staged" ${keep:+"$keep"}
    records__chmod "$mode" "$dest"
}

# Write FROM to DEST unless it already holds that, and set the mode either way
# Usage: records__apply FROM DEST MODE
records__apply() {
    if cmp -s "$1" "$2"; then
        records__chmod "$3" "$2"
    else
        records__write_live "$1" "$2" "$3"
    fi
}

# True if FILE holds exactly one JSON object
records__is_object() {
    jq -se 'length == 1 and (.[0] | type) == "object"' "$1" >/dev/null 2>&1
}

# True if two JSON files hold the same value, whatever their formatting and key order
records__json_same() {
    jq -ne --slurpfile a "$1" --slurpfile b "$2" '$a == $b' >/dev/null 2>&1
}

# Usage: records__deploy_replaced APP SRC NEW DEST MODE
records__deploy_replaced() {
    local app="$1" src="$2" new="$3" dest="$4" mode="$5" repo decision
    if [[ "$RECORDS_FORCE" == reset ]] || records_is_fresh "$app" "$src" "$dest" replace; then
        records__apply "$new" "$dest" "$mode" || return 1
        RECORDS_DEPLOY_RESULT=fresh
        records_put "$app" "$src" "$dest" replace "$new" "$new"
        return
    fi
    repo=$(records_repo_path "$app" "$src") || return 1
    if [[ "$RECORDS_FORCE" == force ]]; then
        decision=apply
    else
        decision=$(records_decide_file "$dest" "$repo" "$new") || return 1
    fi
    RECORDS_DEPLOY_RESULT="$decision"
    case "$decision" in
        apply)
            records__apply "$new" "$dest" "$mode" || return 1
            records_put "$app" "$src" "$dest" replace "$new" "$new"
            ;;
        same)
            records__chmod "$mode" "$dest" || return 1
            records_put "$app" "$src" "$dest" replace "$new" "$new"
            ;;
        none)
            records__chmod "$mode" "$dest"
            ;;
    esac
}

# A fresh deploy of a merged file: live * repo, keeping the keys that are there. They aren't
# offered for review, so the review copy is what live becomes.
# Usage: records__fresh_merged APP SRC NEW DEST MODE WORK
records__fresh_merged() {
    local app="$1" src="$2" new="$3" dest="$4" mode="$5" work="$6"
    if [[ -s "$dest" ]]; then
        if ! jq -s '.[0] * .[1]' "$dest" "$new" > "$work/live" 2>/dev/null || ! records__is_object "$work/live"; then
            records__error "could not merge $dest"
            return 1
        fi
        if records__json_same "$dest" "$work/live"; then
            records__chmod "$mode" "$dest" || return 1
        else
            records__write_live "$work/live" "$dest" "$mode" || return 1
        fi
    else
        cat "$new" > "$work/live" || return 1
        records__apply "$new" "$dest" "$mode" || return 1
    fi
    RECORDS_DEPLOY_RESULT=fresh
    records_put "$app" "$src" "$dest" merge "$new" "$work/live"
}

# Usage: records__deploy_merged APP SRC NEW DEST MODE WORK
records__deploy_merged() {
    local app="$1" src="$2" new="$3" dest="$4" mode="$5" work="$6" repo review
    command -v jq >/dev/null 2>&1 || { records__error "jq is required to merge JSON files (strategy: merge); install jq"; return 1; }
    records__is_object "$new" || { records__error "not a valid JSON object: $new"; return 1; }
    if [[ "$RECORDS_FORCE" == reset ]]; then
        records__apply "$new" "$dest" "$mode" || return 1
        RECORDS_DEPLOY_RESULT=fresh
        records_put "$app" "$src" "$dest" merge "$new" "$new"
        return
    fi
    if [[ -s "$dest" ]] && ! records__is_object "$dest"; then
        records__error "not a valid JSON object: $dest"
        return 1
    fi
    # A deleted or empty live file comes back as a fresh deploy: the three-way merge needs one
    if [[ ! -s "$dest" ]] || records_is_fresh "$app" "$src" "$dest" merge; then
        records__fresh_merged "$app" "$src" "$new" "$dest" "$mode" "$work"
        return
    fi

    repo=$(records_repo_path "$app" "$src") || return 1
    review=$(records_review_path "$app" "$src") || return 1
    if ! records_merge3 "$repo" "$new" "$dest" "$review" > "$work/out" 2>/dev/null; then
        records__error "could not compare $dest with its records"
        return 1
    fi
    if [[ "$RECORDS_FORCE" == force ]]; then
        # The repo's values over what the merge left: local-only keys stay, and stay flagged
        if ! jq --slurpfile new "$new" '{
                live: (.live * $new[0]),
                repo: $new[0],
                review: (.review * $new[0]),
                conflicts: []
            }' "$work/out" > "$work/forced" 2>/dev/null; then
            records__error "could not merge $dest"
            return 1
        fi
        mv -f "$work/forced" "$work/out" || return 1
    fi
    if ! { jq .live "$work/out" > "$work/live" && jq .repo "$work/out" > "$work/repo" \
        && jq .review "$work/out" > "$work/review"; } 2>/dev/null \
        || ! records__is_object "$work/live"; then
        records__error "could not merge $dest"
        return 1
    fi
    RECORDS_DEPLOY_CONFLICTS=$(jq -c .conflicts "$work/out") || return 1
    if records__json_same "$dest" "$work/live"; then
        RECORDS_DEPLOY_RESULT=none
        records__chmod "$mode" "$dest" || return 1
    else
        RECORDS_DEPLOY_RESULT=apply
        records__write_live "$work/live" "$dest" "$mode" || return 1
    fi
    [[ "$RECORDS_DEPLOY_CONFLICTS" == "[]" ]] || RECORDS_DEPLOY_RESULT=conflict
    records_put "$app" "$src" "$dest" merge "$work/repo" "$work/review"
}

# Deploy one file by the pull table, writing records only after the live write succeeds.
# With RECORDS_FORCE=force it takes the repo's version, keeping local-only keys of a merged
# file; with RECORDS_FORCE=reset the file becomes the repo's exactly. On failure the live
# file and its records are as they were, except when the records fail after the write,
# which the next run settles because live then already matches the repo. Sets
# RECORDS_DEPLOY_RESULT to fresh, apply, none, keep, same or conflict, and
# RECORDS_DEPLOY_CONFLICTS to the held paths of a merged file, as a JSON array.
# Usage: records_deploy APP SRC SRC_PATH DEST MODE STRATEGY
records_deploy() {
    local app="$1" src="$2" new="$3" dest="$4" mode="$5" strategy="$6" work rc=0
    RECORDS_DEPLOY_RESULT=""
    RECORDS_DEPLOY_CONFLICTS="[]"
    records__check_app "$app" && records__check_src "$src" || return 1
    [[ -r "$new" ]] || { records__error "cannot read $new"; return 1; }
    if [[ -e "$dest" && ! -f "$dest" ]]; then
        records__error "$dest is not a regular file"
        return 1
    fi
    case "$strategy" in
        replace | merge)
            if [[ "$RECORDS_FORCE" != reset ]]; then
                records__adopt "$app" "$src" "$dest" "$strategy" || return 1
            fi
            ;;
    esac
    case "$strategy" in
        replace)
            records__deploy_replaced "$app" "$src" "$new" "$dest" "$mode"
            ;;
        merge)
            work=$(mktemp -d) || { records__error "could not create a temp directory"; return 1; }
            records__deploy_merged "$app" "$src" "$new" "$dest" "$mode" "$work" || rc=$?
            rm -rf "$work"
            return "$rc"
            ;;
        *)
            records__error "unknown strategy: '$strategy'"
            return 1
            ;;
    esac
}

# What records_deploy would do with one file, changing nothing: sets RECORDS_DEPLOY_RESULT
# and RECORDS_DEPLOY_CONFLICTS the same way, and fails where it would, so a dry run says what
# the real pull would. Reads RECORDS_FORCE.
# Usage: records_preview APP SRC SRC_PATH DEST STRATEGY
records_preview() {
    local app="$1" src="$2" new="$3" dest="$4" strategy="$5" repo review found owner o_src dir out
    RECORDS_DEPLOY_RESULT=""
    RECORDS_DEPLOY_CONFLICTS="[]"
    records__check_app "$app" && records__check_src "$src" || return 1
    [[ -r "$new" ]] || { records__error "cannot read $new"; return 1; }
    if [[ -e "$dest" && ! -f "$dest" ]]; then
        records__error "$dest is not a regular file"
        return 1
    fi
    if [[ "$strategy" == merge ]]; then
        command -v jq >/dev/null 2>&1 || { records__error "jq is required to merge JSON files (strategy: merge); install jq"; return 1; }
        records__is_object "$new" || { records__error "not a valid JSON object: $new"; return 1; }
    fi
    RECORDS_DEPLOY_RESULT=fresh
    [[ "$RECORDS_FORCE" != reset ]] || return 0
    if [[ "$strategy" == merge && -s "$dest" ]] && ! records__is_object "$dest"; then
        RECORDS_DEPLOY_RESULT=""
        records__error "not a valid JSON object: $dest"
        return 1
    fi
    repo=$(records_repo_path "$app" "$src") || return 1
    review=$(records_review_path "$app" "$src") || return 1
    if records_is_fresh "$app" "$src" "$dest" "$strategy"; then
        found=$(records__adopt_source "$app" "$src" "$dest" "$strategy")
        [[ -n "$found" ]] || return 0
        IFS=$'\t' read -r owner o_src <<< "$found"
        if [[ "$owner" == .released ]]; then
            dir=$(records__released_dir "$dest")
            repo="$dir/repo"
            review="$dir/review"
        else
            repo="$STATE_DIR/records/$owner/repo/$o_src"
            review="$STATE_DIR/records/$owner/review/$o_src"
        fi
    fi
    if [[ "$strategy" == merge ]]; then
        [[ -s "$dest" ]] || return 0
        RECORDS_DEPLOY_RESULT=apply
        [[ "$RECORDS_FORCE" != force ]] || return 0
        if ! out=$(records_merge3 "$repo" "$new" "$dest" "$review" 2>/dev/null); then
            RECORDS_DEPLOY_RESULT=""
            records__error "could not compare $dest with its records"
            return 1
        fi
        RECORDS_DEPLOY_CONFLICTS=$(jq -c .conflicts <<< "$out") || return 1
        if [[ "$RECORDS_DEPLOY_CONFLICTS" != "[]" ]]; then
            RECORDS_DEPLOY_RESULT=conflict
        elif jq -ne --slurpfile a "$dest" --argjson b "$(jq -c .live <<< "$out")" '$a[0] == $b' >/dev/null 2>&1; then
            RECORDS_DEPLOY_RESULT=none
        fi
    elif [[ "$RECORDS_FORCE" == force ]]; then
        RECORDS_DEPLOY_RESULT=apply
    else
        RECORDS_DEPLOY_RESULT=$(records_decide_file "$dest" "$repo" "$new") || { RECORDS_DEPLOY_RESULT=""; return 1; }
    fi
}

# What add should ask about for one file, conflicts first. An item is an edit since the
# last review, unless it matches the repo copy or the repo's new version, which both count
# as reviewed. Dismissed items differ from the repo copy but match the review copy, and show
# only when ALL is true. Conflicts always show. A deleted live file has no items: the next
# deploy restores it. With no STAGE_FILE (the repo dropped the file), nothing can conflict
# with the repo.
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
    case "$decision" in
        conflict) printf 'conflict\t[]\n' ;;
        keep)
            if ! cmp -s "$dest" "$review"; then
                printf 'edited\t[]\n'
            elif [[ "$all" == true ]]; then
                printf 'dismissed\t[]\n'
            fi
            ;;
    esac
}

# Usage: records__items_merged LIVE REPO NEW REVIEW ALL
records__items_merged() {
    local live="$1" repo="$2" new="$3" review="$4" all="$5" conflicts
    conflicts=$(records_merge3 "$repo" "$new" "$live" "$review" | jq -c .conflicts) || return 1
    [[ -n "$conflicts" ]] || return 1
    jq -nr \
        --slurpfile live "$live" --slurpfile repo "$repo" --slurpfile new "$new" --slurpfile review "$review" \
        --argjson conflicts "$conflicts" --arg all "$all" '
        def at($p):
          if ($p | length) == 0 then [.]
          elif type == "object" and has($p[0]) then .[$p[0]] | at($p[1:])
          else [] end;
        def child($k): if length == 1 then .[0] | at([$k]) else [] end;
        def big: length == 1 and (.[0] | type) == "object" and (.[0] | length) > 0;
        def any_object: length == 1 and (.[0] | type) == "object";
        def kids: if any_object then .[0] | keys_unsorted else [] end;
        def is_prefix($a; $b): $b[:($a | length)] == $a;
        def near_conflict($p):
          any($conflicts[]; is_prefix(.; $p) or is_prefix($p; .));
        def above_conflict($p):
          any($conflicts[]; is_prefix($p; .) and . != $p);
        # The smallest paths where wrapped values differ: into objects on both sides, or
        # into the only side present, so a new subtree is one path per key. Also into a
        # live object held apart from a plain value above a conflict, or the conflict would
        # hide its siblings.
        def diff($l; $r; $p):
          if $l == $r then empty
          elif ($l | any_object) and ($r | any_object)
            or ($l == [] and ($r | big)) or ($r == [] and ($l | big))
            or (($l | any_object) and above_conflict($p)) then
            (($l | kids) + ($r | kids) | unique)[] as $k
            | diff($l | child($k); $r | child($k); $p + [$k])
          else $p end;
        # Under a plain value in the repo the whole value is the item: what is under it
        # means nothing to the repo, so comparing there would miss a change.
        def whole($b; $p):
          first((range(1; $p | length) as $i
                 | $p[:$i]
                 | select(. as $q | $b | at($q) | length == 1 and (.[0] | type) != "object")),
                $p);
        def item($kind): "\($kind)\t\(tojson)";
        $live[0] as $l | $repo[0] as $b | $new[0] as $n | $review[0] as $v
        | def settled($p): ($l | at($p)) == ($b | at($p)) or ($l | at($p)) == ($n | at($p));
          ($conflicts[] | item("conflict")),
          (([diff([$l]; [$v]; []) as $p | whole($b; $p)] | unique)[] as $p
            | select((settled($p) or near_conflict($p)) | not)
            | $p | item("edited")),
          (if $all == "true" then
             diff([$l]; [$b]; []) as $p
             | select(($l | at($p)) == ($v | at($p)) and ((settled($p) or near_conflict($p)) | not))
             | $p | item("dismissed")
           else empty end)
    '
}
