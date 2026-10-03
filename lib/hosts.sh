#!/usr/bin/env bash
# hosts.sh - dotfiles-hosts dir helpers (profile lookup, host.yaml parsing)

# Host name used for hosts/<name>/: strips user@ and the domain.
# IPv4 addresses are kept whole.
# Usage: hosts_normalize_name [user@]host[.domain]
hosts_normalize_name() {
    local h="${1#*@}"
    if [[ "$h" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        echo "$h"
    else
        echo "${h%%.*}"
    fi
}

# Short host name of this machine (no hard dependency on `hostname`)
hosts_local_name() {
    local h
    h=$(hostname -s 2>/dev/null) || h=$(uname -n 2>/dev/null) || h=""
    echo "${h%%.*}"
}

# Resolve a profile name: hosts dir first (unless skip_hosts), then dotfiles
# Usage: hosts_resolve_profile_path profiles_dir hosts_dir name skip_hosts
hosts_resolve_profile_path() {
    local profiles_dir="$1" hosts_dir="$2" name="$3" skip_hosts="${4:-false}"
    if [[ -n "$hosts_dir" && "$skip_hosts" != true && -f "$hosts_dir/profiles/$name.yaml" ]]; then
        echo "$hosts_dir/profiles/$name.yaml"
    else
        echo "$profiles_dir/$name.yaml"
    fi
}

# Print the value of a top-level "key: value" line (empty if absent)
# Usage: hosts_read_scalar file key
hosts_read_scalar() {
    local file="$1" key="$2" line v
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^${key}:[[:space:]]*([^#]*) ]]; then
            v="${BASH_REMATCH[1]}"
            v="${v%"${v##*[![:space:]]}"}"
            v="${v#[\"\']}"
            v="${v%[\"\']}"
            echo "$v"
            return 0
        fi
    done < "$file"
    return 0
}

# Print "<app>/<src> <strategy>" for each entry of a top-level files: map
# Usage: hosts_parse_files_map file
hosts_parse_files_map() {
    local file="$1" line in_files=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ "$line" =~ ^files:[[:space:]]*$ ]]; then
            in_files=true
            continue
        fi
        [[ "$in_files" == true ]] || continue
        [[ "$line" =~ ^[[:alpha:]] ]] && break

        if [[ "$line" =~ ^[[:space:]]+([^[:space:]:/]+/[^[:space:]:]+):[[:space:]]*([[:alnum:]_-]+)[[:space:]]*(#.*)?$ ]]; then
            echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        else
            log_error "$file: invalid files: entry (expected '<app>/<src>: <strategy>'): $line"
            return 1
        fi
    done < "$file"
    return 0
}

export -f hosts_normalize_name
export -f hosts_local_name
export -f hosts_resolve_profile_path
export -f hosts_read_scalar
export -f hosts_parse_files_map
