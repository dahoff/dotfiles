#!/usr/bin/env bash
# utils.sh - Common utility functions for dotfiles installer

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Check if file exists
file_exists() {
    [[ -f "$1" ]]
}

# Check if directory exists
dir_exists() {
    [[ -d "$1" ]]
}

# Create directory if it doesn't exist
ensure_dir() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        log_debug "Creating directory: $dir"
        mkdir -p "$dir" || {
            log_error "Failed to create directory: $dir"
            return 1
        }
    fi
    return 0
}

# Copy file with verification
copy_file() {
    local src="$1"
    local dest="$2"

    log_debug "Copying: $src -> $dest"

    # Ensure destination directory exists
    ensure_dir "$(dirname "$dest")" || return 1

    # Copy file
    cp "$src" "$dest" || {
        log_error "Failed to copy: $src -> $dest"
        return 1
    }

    # Verify copy
    if ! cmp -s "$src" "$dest"; then
        log_error "Copy verification failed: $dest"
        return 1
    fi

    return 0
}

# Set file permissions
set_permissions() {
    local file="$1"
    local mode="$2"

    log_debug "Setting permissions: $file -> $mode"

    chmod "$mode" "$file" || {
        log_error "Failed to set permissions on: $file"
        return 1
    }

    return 0
}

# Check if file is executable
is_executable() {
    [[ -x "$1" ]]
}

# Get file size in bytes
get_file_size() {
    local file="$1"

    if file_exists "$file"; then
        stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null
    else
        echo 0
    fi
}

# Check available disk space (in KB)
get_free_space() {
    local path="$1"

    df -k "$path" | awk 'NR==2 {print $4}'
}

# Confirm action with user
confirm() {
    local prompt="$1"
    local default="${2:-n}"  # y or n

    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]"
    else
        prompt="$prompt [y/N]"
    fi

    read -r -p "$prompt " response

    response="${response:-$default}"

    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Generate timestamp
timestamp() {
    date '+%Y%m%d_%H%M%S'
}

# Get human-readable timestamp
timestamp_readable() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Calculate checksum of file
checksum() {
    local file="$1"

    if file_exists "$file"; then
        md5sum "$file" 2>/dev/null | awk '{print $1}' || \
        md5 -q "$file" 2>/dev/null
    fi
}

# Verify checksum
verify_checksum() {
    local file="$1"
    local expected="$2"
    local actual

    actual=$(checksum "$file")

    [[ "$actual" == "$expected" ]]
}

# Check if running in test mode
is_test_mode() {
    [[ "${TEST_MODE:-false}" == true ]]
}

# Check if running in dry-run mode
is_dry_run() {
    [[ "${DRY_RUN:-false}" == true ]]
}

# Get absolute path
abs_path() {
    local path="$1"

    # Expand ~ to home directory
    path="${path/#\~/$HOME}"

    # Get absolute path
    if [[ -d "$path" ]]; then
        (cd "$path" && pwd)
    elif [[ -f "$path" ]]; then
        local dir
        local base
        dir=$(cd "$(dirname "$path")" && pwd)
        base=$(basename "$path")
        echo "$dir/$base"
    else
        echo "$path"
    fi
}

# Cleanup function (for traps)
cleanup() {
    log_debug "Cleanup called"
    # Override in main script if needed
}

# Export functions
export -f command_exists
export -f file_exists
export -f dir_exists
export -f ensure_dir
export -f copy_file
export -f set_permissions
export -f is_executable
export -f get_file_size
export -f get_free_space
export -f confirm
export -f timestamp
export -f timestamp_readable
export -f checksum
export -f verify_checksum
export -f is_test_mode
export -f is_dry_run
export -f abs_path
export -f cleanup
