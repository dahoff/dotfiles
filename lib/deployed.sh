#!/usr/bin/env bash
# deployed.sh - record of what dotfiles last wrote to each live file, used to tell
# a hand edit from a file that is simply behind the repo. Holds hashes, no contents.
#
# One manifest per app: $STATE_DIR/deployed/<app>.tsv, lines HASH<TAB>SRC<TAB>DEST.
# HASH is a sha256, "merge" for a merged file (apps rewrite those, so only the keys
# the repo manages are compared), or "unknown" when a file was found differing from
# the repo with no record of what was deployed.
# Requires STATE_DIR (lib/state.sh).

# Usage: deployed_file APP
deployed_file() {
    echo "$STATE_DIR/deployed/$1.tsv"
}

# Full sha256 of a file
# Usage: deployed_hash FILE
deployed_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Recorded hash for a live file; empty if there is none
# Usage: deployed_get APP DEST
deployed_get() {
    local file
    file=$(deployed_file "$1")
    [[ -f "$file" ]] || return 0
    DEPLOYED_DEST="$2" awk -F'\t' '$3 == ENVIRON["DEPLOYED_DEST"] { print $1; exit }' "$file"
}

# Usage: deployed_set APP SRC DEST HASH
deployed_set() {
    local app="$1" src="$2" dest="$3" hash="$4" file tmp
    file=$(deployed_file "$app")
    mkdir -p "$(dirname "$file")" || return 1
    tmp="$file.tmp.$$"
    {
        if [[ -f "$file" ]]; then
            DEPLOYED_DEST="$dest" awk -F'\t' '$3 != ENVIRON["DEPLOYED_DEST"]' "$file"
        fi
        printf '%s\t%s\t%s\n' "$hash" "$src" "$dest"
    } > "$tmp" && mv "$tmp" "$file"
}

# Drop entries for files the app no longer deploys
# Usage: deployed_prune APP DEST...
deployed_prune() {
    local app="$1" file tmp hash src dest d
    shift
    file=$(deployed_file "$app")
    [[ -f "$file" ]] || return 0
    tmp="$file.tmp.$$"
    : > "$tmp"
    while IFS=$'\t' read -r hash src dest; do
        for d in "$@"; do
            if [[ "$d" == "$dest" ]]; then
                printf '%s\t%s\t%s\n' "$hash" "$src" "$dest" >> "$tmp"
                break
            fi
        done
    done < "$file"
    mv "$tmp" "$file"
}

# Usage: deployed_remove APP
deployed_remove() {
    rm -f "$(deployed_file "$1")"
}

# Number of non-merged files whose live copy differs from the record. Needs no
# stage, so it also works when sync stops early.
deployed_count_edits() {
    local count=0 file hash src dest
    for file in "$STATE_DIR/deployed/"*.tsv; do
        [[ -f "$file" ]] || continue
        while IFS=$'\t' read -r hash src dest; do
            [[ "$hash" != merge && -f "$dest" ]] || continue
            [[ "$(deployed_hash "$dest")" == "$hash" ]] || count=$((count + 1))
        done < "$file"
    done
    echo "$count"
}

# Keys the repo manages that differ in the live file. Lists count as one value.
# Prints KEY<TAB>REPO_JSON<TAB>LIVE_JSON per difference (LIVE_JSON is "(removed)"
# when the key is gone). Fails if jq is missing or either file is not valid JSON.
# Usage: deployed_merge_diff REPO_FILE LIVE_FILE
deployed_merge_diff() {
    command -v jq >/dev/null 2>&1 || return 1
    jq -nr --slurpfile repo "$1" --slurpfile live "$2" '
        def leaves(p): if type == "object" and length > 0
            then to_entries[] | .key as $k | .value | leaves(p + [$k])
            else p end;
        def has_path($p): . as $d | try ($d | getpath($p[:-1]) | has($p[-1])) catch false;
        $repo[0] as $r | $live[0] as $l
        | ($r | leaves([])) as $p | select($p | length > 0)
        | ($r | getpath($p)) as $want
        | (if ($l | has_path($p)) then ($l | getpath($p) | tojson) else "(removed)" end) as $got
        | select(($want | tojson) != $got)
        | "\($p | map(tostring) | join("."))\t\($want | tojson)\t\($got)"
    ' 2>/dev/null
}

# Number of keys in the live file that the repo does not manage
# Usage: deployed_merge_local_count REPO_FILE LIVE_FILE
deployed_merge_local_count() {
    jq -nr --slurpfile repo "$1" --slurpfile live "$2" '
        def leaves(p): if type == "object" and length > 0
            then to_entries[] | .key as $k | .value | leaves(p + [$k])
            else p end;
        def has_path($p): . as $d | try ($d | getpath($p[:-1]) | has($p[-1])) catch false;
        $repo[0] as $r
        | [ $live[0] | leaves([]) | select(length > 0) | . as $p | select(($r | has_path($p)) | not) ] | length
    ' 2>/dev/null || echo 0
}

# Locally edited files of one app, against a fresh stage. Prints KIND<TAB>SRC<TAB>DEST:
#   edited    you changed it and the repo did not
#   conflict  you changed it and the repo did too (or there is no record to tell)
#   merge     a merged file whose repo-managed keys differ (display only)
# Usage: deployed_app_edits APP STAGE_DIR
deployed_app_edits() {
    local app="$1" stage="$2" file hash src dest repo_file live new
    file=$(deployed_file "$app")
    [[ -f "$file" ]] || return 0
    while IFS=$'\t' read -r hash src dest; do
        repo_file="$stage/files/$src"
        [[ -f "$dest" && -f "$repo_file" ]] || continue
        if [[ "$hash" == merge ]]; then
            if [[ -n "$(deployed_merge_diff "$repo_file" "$dest" || true)" ]]; then
                printf 'merge\t%s\t%s\n' "$src" "$dest"
            fi
            continue
        fi
        live=$(deployed_hash "$dest")
        [[ "$live" != "$hash" ]] || continue
        new=$(deployed_hash "$repo_file")
        [[ "$live" != "$new" ]] || continue
        if [[ "$new" == "$hash" ]]; then
            printf 'edited\t%s\t%s\n' "$src" "$dest"
        else
            printf 'conflict\t%s\t%s\n' "$src" "$dest"
        fi
    done < "$file"
}
