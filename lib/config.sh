#!/usr/bin/env bash
# config.sh - Per-host config file (~/.config/dotfiles/config)
# key=value lines, parsed (never sourced). Requires lib/logging.sh.

CFG_FILE=""
CFG_DOTFILES_REPO=""
CFG_HOSTS_REPO=""
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
# Returns 1 for an invalid auto_sync or auto_sync_interval value.
# Usage: config_load FILE
config_load() {
    local file="$1"
    CFG_FILE="$file"
    CFG_DOTFILES_REPO=""
    CFG_HOSTS_REPO=""
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

        if [[ "$line" != *=* ]]; then
            log_warn "$file:$n: ignoring line without '=': $line"
            continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"

        if [[ ! "$key" =~ ^[a-z_]+$ ]]; then
            log_warn "$file:$n: ignoring malformed line: $line"
            continue
        fi
        if [[ ${#value} -ge 2 && ( "${value:0:1}" == '"' || "${value:0:1}" == "'" ) \
              && "${value: -1}" == "${value:0:1}" ]]; then
            value="${value:1:${#value}-2}"
        fi
        # Expand a leading ~ (harmless for non-path values)
        if [[ "$value" == "~" ]]; then
            value="$HOME"
        elif [[ "$value" == "~/"* ]]; then
            value="$HOME/${value#\~/}"
        fi

        case "$key" in
            dotfiles_repo) CFG_DOTFILES_REPO="$value" ;;
            hosts_repo) CFG_HOSTS_REPO="$value" ;;
            hostname) CFG_HOSTNAME="$value" ;;
            profile) CFG_PROFILE="$value" ;;
            auto_sync)
                if [[ "$value" == on || "$value" == off ]]; then
                    CFG_AUTO_SYNC="$value"
                else
                    log_error "$file:$n: auto_sync must be 'on' or 'off': $value"
                    rc=1
                fi
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
