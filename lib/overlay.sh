#!/usr/bin/env bash
# overlay.sh - Compose app files from dotfiles and dotfiles-hosts layers
#
# A staging directory for one app holds:
#   files/<src>   the composed file to deploy (replace: winning layer;
#                 merge: repo layers pre-merged)
#   strategies    "<src> <strategy>" per config.yaml file entry
#   skip          srcs whose repo layers could not be merged
#   version       content hash used as the app version

# Print "src<TAB>strategy" for each files[] entry of an app config.yaml
# Usage: overlay_config_entries config.yaml
overlay_config_entries() {
    local config="$1" line in_files=false src="" strategy=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^files: ]]; then
            in_files=true
            continue
        fi
        [[ "$in_files" == true ]] || continue
        [[ "$line" =~ ^[[:alpha:]] ]] && break

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*src:[[:space:]]*([^[:space:]]+) ]]; then
            if [[ -n "$src" ]]; then
                printf '%s\t%s\n' "$src" "${strategy:-replace}"
            fi
            src="${BASH_REMATCH[1]}"
            strategy=""
        elif [[ "$line" =~ ^[[:space:]]+strategy:[[:space:]]*([^[:space:]#]+) ]]; then
            strategy="${BASH_REMATCH[1]}"
            strategy="${strategy#[\"\']}"
            strategy="${strategy%[\"\']}"
        fi
    done < "$config"

    if [[ -n "$src" ]]; then
        printf '%s\t%s\n' "$src" "${strategy:-replace}"
    fi
    return 0
}

# Check a strategy value for a file
# Usage: overlay_check_strategy <app>/<src> strategy
overlay_check_strategy() {
    local key="$1" strategy="$2"
    case "$strategy" in
        replace)
            return 0
            ;;
        merge)
            if [[ "$key" != *.json ]]; then
                log_error "merge strategy requires a .json file: $key"
                return 1
            fi
            return 0
            ;;
        *)
            log_error "Unknown strategy '$strategy' for $key (use replace or merge)"
            return 1
            ;;
    esac
}

# Print "src strategy" for every config.yaml file entry, in config order,
# applying overrides from a strategies file (last declaration wins)
# Usage: overlay_resolve_strategies app_dir strategies_file
overlay_resolve_strategies() {
    local app_dir="$1" strategies_file="$2"
    local app src strategy key
    app=$(basename "$app_dir")
    local -a order=()
    local -A final=()

    while IFS=$'\t' read -r src strategy; do
        order+=("$src")
        final["$src"]="$strategy"
    done < <(overlay_config_entries "$app_dir/config.yaml")

    while read -r key strategy; do
        [[ "${key%%/*}" == "$app" ]] || continue
        src="${key#*/}"
        if [[ -n "${final[$src]:-}" ]]; then
            final["$src"]="$strategy"
        fi
    done < "$strategies_file"

    for src in "${order[@]}"; do
        echo "$src ${final[$src]}"
    done
}

# Validate overlays and strategies for one app; logs every problem
# Usage: overlay_validate_app app_dir strategies_file [layer_root...]
overlay_validate_app() {
    local app_dir="$1" strategies_file="$2"
    shift 2
    local app src strategy key root f rel ok=0
    app=$(basename "$app_dir")
    local -A known=()

    while IFS=$'\t' read -r src strategy; do
        known["$src"]=1
    done < <(overlay_config_entries "$app_dir/config.yaml")

    for root in "$@"; do
        [[ -d "$root/apps/$app/files" ]] || continue
        while IFS= read -r f; do
            rel="${f#"$root/apps/$app/files/"}"
            if [[ -z "${known[$rel]:-}" ]]; then
                log_error "Overlay file $f: '$rel' is not a src in $app/config.yaml"
                ok=1
            fi
        done < <(find "$root/apps/$app/files" -type f)
    done

    while read -r key strategy; do
        [[ "${key%%/*}" == "$app" ]] || continue
        if [[ -z "${known[${key#*/}]:-}" ]]; then
            log_error "files: entry '$key' is not a src in $app/config.yaml"
            ok=1
        fi
    done < "$strategies_file"

    while read -r src strategy; do
        overlay_check_strategy "$app/$src" "$strategy" || ok=1
    done < <(overlay_resolve_strategies "$app_dir" "$strategies_file")

    return $ok
}

# Merge JSON objects left to right with jq's `*` and write the result to out.
# Fails, leaving out untouched, if jq is missing or an input is not a JSON object.
# out may also be one of the inputs.
# Usage: overlay_json_merge out file...
overlay_json_merge() {
    local out="$1"
    shift

    if ! command_exists jq; then
        log_error "jq is required to merge JSON files (strategy: merge); install jq"
        return 1
    fi

    local f
    for f in "$@"; do
        if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
            log_error "Not a valid JSON object: $f"
            return 1
        fi
    done

    local tmp
    tmp=$(mktemp "$(dirname "$out")/.$(basename "$out").merge.XXXXXX") || return 1
    if ! jq -s 'reduce .[] as $x ({}; . * $x)' "$@" > "$tmp"; then
        rm -f "$tmp"
        log_error "jq merge failed for $out"
        return 1
    fi
    mv "$tmp" "$out"
}

# Hash stdin to a short version string
overlay_hash() {
    if command_exists sha256sum; then
        sha256sum
    else
        shasum -a 256
    fi | cut -c1-12
}

# Write stage_dir/version from config.yaml, strategies, skip and staged files
# Usage: overlay_write_version app_dir stage_dir
overlay_write_version() {
    local app_dir="$1" stage_dir="$2" src strategy
    {
        cat "$app_dir/config.yaml"
        if [[ -f "$app_dir/configure.sh" ]]; then cat "$app_dir/configure.sh"; fi
        cat "$stage_dir/strategies" "$stage_dir/skip"
        while read -r src strategy; do
            printf '== %s\n' "$src"
            cat "$stage_dir/files/$src" 2>/dev/null || true
        done < "$stage_dir/strategies"
    } | overlay_hash > "$stage_dir/version"
}

# Build the staging directory for one app
# Usage: overlay_stage_app app_dir stage_dir strategies_file [layer_root...]
# Returns 1 on a fatal error for this app (bad strategy, missing source).
# A merge file whose repo layers can't be merged is listed in stage_dir/skip.
overlay_stage_app() {
    local app_dir="$1" stage_dir="$2" strategies_file="$3"
    shift 3
    local app src strategy root
    app=$(basename "$app_dir")

    mkdir -p "$stage_dir/files" || return 1
    : > "$stage_dir/strategies"
    : > "$stage_dir/skip"

    while read -r src strategy; do
        overlay_check_strategy "$app/$src" "$strategy" || return 1

        local -a layers=()
        if [[ -f "$app_dir/files/$src" ]]; then
            layers+=("$app_dir/files/$src")
        fi
        for root in "$@"; do
            if [[ -f "$root/apps/$app/files/$src" ]]; then
                layers+=("$root/apps/$app/files/$src")
            fi
        done

        if [[ ${#layers[@]} -eq 0 ]]; then
            log_error "Source file not found: $app_dir/files/$src (and no overlay provides it)"
            return 1
        fi

        local out="$stage_dir/files/$src"
        mkdir -p "$(dirname "$out")" || return 1
        echo "$src $strategy" >> "$stage_dir/strategies"

        if [[ "$strategy" == merge ]] && { [[ ${#layers[@]} -gt 1 ]] || command_exists jq; }; then
            if ! overlay_json_merge "$out" "${layers[@]}"; then
                log_error "Cannot merge repo layers for $app/$src; skipping it"
                echo "$src" >> "$stage_dir/skip"
            fi
        else
            cp "${layers[-1]}" "$out" || return 1
        fi
    done < <(overlay_resolve_strategies "$app_dir" "$strategies_file")

    overlay_write_version "$app_dir" "$stage_dir"
}

export -f overlay_config_entries
export -f overlay_check_strategy
export -f overlay_resolve_strategies
export -f overlay_validate_app
export -f overlay_json_merge
export -f overlay_hash
export -f overlay_write_version
export -f overlay_stage_app
