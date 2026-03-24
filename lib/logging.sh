#!/usr/bin/env bash
# logging.sh - Logging utilities for dotfiles installer
# Provides console and optional file logging with levels

# Configuration
LOG_FILE=""
LOG_LEVEL="INFO"  # ERROR, WARN, INFO, DEBUG
LOG_VERBOSE=false
LOG_QUIET=false

# Colors
if [[ -t 1 ]]; then  # Only use colors if stdout is a terminal
    COLOR_RESET='\033[0m'
    COLOR_RED='\033[0;31m'
    COLOR_YELLOW='\033[0;33m'
    COLOR_GREEN='\033[0;32m'
    COLOR_BLUE='\033[0;34m'
    COLOR_GRAY='\033[0;90m'
else
    COLOR_RESET=''
    COLOR_RED=''
    COLOR_YELLOW=''
    COLOR_GREEN=''
    COLOR_BLUE=''
    COLOR_GRAY=''
fi

# Initialize logging
# Usage: log_init [--log FILE] [--verbose] [--quiet]
log_init() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --log)
                LOG_FILE="$2"
                shift 2
                ;;
            --verbose)
                LOG_VERBOSE=true
                LOG_LEVEL="DEBUG"
                shift
                ;;
            --quiet)
                LOG_QUIET=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Create log file if specified
    if [[ -n "$LOG_FILE" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        touch "$LOG_FILE" || {
            echo "ERROR: Cannot create log file: $LOG_FILE" >&2
            return 1
        }
    fi
}

# Get current timestamp
_log_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Write to log file
_log_to_file() {
    local level="$1"
    local message="$2"

    if [[ -n "$LOG_FILE" ]]; then
        echo "$(_log_timestamp) [$level] $message" >> "$LOG_FILE"
    fi
}

# Log functions
log_error() {
    local message="$*"
    _log_to_file "ERROR" "$message"
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $message" >&2
}

log_warn() {
    local message="$*"
    _log_to_file "WARN" "$message"
    if [[ "$LOG_QUIET" != true ]]; then
        echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $message" >&2
    fi
}

log_info() {
    local message="$*"
    _log_to_file "INFO" "$message"
    if [[ "$LOG_QUIET" != true ]]; then
        echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $message" >&2
    fi
}

log_success() {
    local message="$*"
    _log_to_file "SUCCESS" "$message"
    if [[ "$LOG_QUIET" != true ]]; then
        echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $message" >&2
    fi
}

log_debug() {
    local message="$*"
    _log_to_file "DEBUG" "$message"
    if [[ "$LOG_VERBOSE" == true ]]; then
        echo -e "${COLOR_GRAY}[DEBUG]${COLOR_RESET} $message" >&2
    fi
}

# Log command execution
log_cmd() {
    local cmd="$*"
    log_debug "Executing: $cmd"
    _log_to_file "CMD" "$cmd"
}

# Export functions
export -f log_init
export -f log_error
export -f log_warn
export -f log_info
export -f log_success
export -f log_debug
export -f log_cmd
