#!/usr/bin/env bash
# config.sh - Per-host config file (~/.config/dotfiles/config.yaml)
# Flat YAML "key: value" lines, parsed (never sourced). Requires lib/logging.sh.

CFG_FILE=""
CFG_HOSTS_DIR=""
CFG_HOSTNAME=""
CFG_PROFILE=""
CFG_AUTO_SYNC="on"
CFG_AUTO_SYNC_INTERVAL="4h"

# Print the seconds for "<n>m|h|d"; return 1 for anything else.
# Usage: config_interval_seconds STR
config_interval_seconds() {
    local s="${1:-}"
    [[ "$s" =~ ^([0-9]+)([mhd])$ ]] || return 1
    local n="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
        m) echo $((10#$n * 60)) ;;
        h) echo $((10#$n * 3600)) ;;
        d) echo $((10#$n * 86400)) ;;
    esac
}

# Parse FILE into the CFG_* globals (defaults when missing).
# Returns 1 for an invalid auto_sync, auto_sync_interval or hostname value.
# Usage: config_load FILE
config_load() {
    local file="$1"
    CFG_FILE="$file"
    CFG_HOSTS_DIR=""
    CFG_HOSTNAME=""
    CFG_PROFILE=""
    CFG_AUTO_SYNC="on"
    CFG_AUTO_SYNC_INTERVAL="4h"

    [[ -f "$file" ]] || return 0

    local rc=0 n=0 line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue

        if [[ "$line" =~ ^[[:space:]] || "$line" == "- "* || "$line" == "-" ]]; then
            log_warn "$file:$n: ignoring indented line or list item (only flat 'key: value' is supported): $line"
            continue
        fi
        # Only the first ': ' (or a trailing ':') splits key from value
        if [[ "$line" == *": "* ]]; then
            key="${line%%: *}"
            value="${line#*: }"
        elif [[ "$line" == *: ]]; then
            key="${line%:}"
            value=""
        else
            log_warn "$file:$n: ignoring line without 'key: value': $line"
            continue
        fi
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"

        if [[ ! "$key" =~ ^[a-z_]+$ ]]; then
            log_warn "$file:$n: ignoring malformed line: $line"
            continue
        fi
        if [[ "$value" =~ ^(\"[^\"]*\"|\'[^\']*\')([[:space:]]+#.*)?[[:space:]]*$ ]]; then
            # Quoted: strip the pair; '#' inside the quotes is kept
            value="${BASH_REMATCH[1]}"
            value="${value:1:${#value}-2}"
        else
            # Unquoted: a trailing ' #...' is a comment
            if [[ "$value" == *[[:space:]]"#"* ]]; then
                value="${value%%[[:space:]]#*}"
            elif [[ "$value" == "#"* ]]; then
                value=""
            fi
            value="${value%"${value##*[![:space:]]}"}"
        fi
        # Expand a leading ~ (harmless for non-path values)
        if [[ "$value" == "~" ]]; then
            value="$HOME"
        elif [[ "$value" == "~/"* ]]; then
            value="$HOME/${value#\~/}"
        fi

        case "$key" in
            hosts_dir) CFG_HOSTS_DIR="$value" ;;
            hostname)
                if [[ -z "$value" || "$value" == */* || "$value" == . || "$value" == .. ]]; then
                    log_error "$file:$n: hostname must be a plain name without '/': $value"
                    rc=1
                else
                    CFG_HOSTNAME="$value"
                fi
                ;;
            profile) CFG_PROFILE="$value" ;;
            auto_sync)
                case "$value" in
                    on|true|yes) CFG_AUTO_SYNC=on ;;
                    off|false|no) CFG_AUTO_SYNC=off ;;
                    *)
                        log_error "$file:$n: auto_sync must be on/off (or true/false/yes/no): $value"
                        rc=1
                        ;;
                esac
                ;;
            auto_sync_interval)
                if config_interval_seconds "$value" >/dev/null; then
                    CFG_AUTO_SYNC_INTERVAL="$value"
                else
                    log_error "$file:$n: auto_sync_interval must be <n>m, <n>h or <n>d: $value"
                    rc=1
                fi
                ;;
            *) log_warn "$file:$n: ignoring unknown key '$key': $line" ;;
        esac
    done < "$file"
    return $rc
}
