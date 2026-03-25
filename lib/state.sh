#!/usr/bin/env bash
# state.sh - State file management for tracking installations

# State directory
STATE_DIR="${STATE_DIR:-$HOME/.config/dotfiles}"
STATE_APPS_DIR="$STATE_DIR/apps"

# Initialize state directory
state_init() {
    log_debug "Initializing state directory: $STATE_DIR"

    ensure_dir "$STATE_DIR" || return 1
    ensure_dir "$STATE_APPS_DIR" || return 1

    return 0
}

# Get state file path for app
# Usage: state_get_file app_name
state_get_file() {
    local app_name="$1"
    echo "$STATE_APPS_DIR/$app_name.yaml"
}

# Check if app is installed
# Usage: state_is_installed app_name
state_is_installed() {
    local app_name="$1"
    local state_file

    state_file=$(state_get_file "$app_name")

    [[ -f "$state_file" ]]
}

# Create new state file
# Usage: state_create app_name version backup_dir files[@]
state_create() {
    local app_name="$1"
    local version="$2"
    local backup_dir="$3"
    shift 3
    local files=("$@")
    local state_file

    state_file=$(state_get_file "$app_name")

    log_debug "Creating state file: $state_file"

    # Create state YAML
    cat > "$state_file" << EOF
app:
  name: $app_name
  version: $version
  installed: true
  install_date: $(timestamp_readable)

backup:
  dir: $backup_dir
  original: $backup_dir/original

files:
EOF

    # Add files
    for file in "${files[@]}"; do
        echo "  - $file" >> "$state_file"
    done

    # Add empty backups section
    cat >> "$state_file" << EOF

snapshots: []
EOF

    return 0
}

# Update state file
# Usage: state_update app_name key value
state_update() {
    local app_name="$1"
    local key="$2"
    local value="$3"
    local state_file

    state_file=$(state_get_file "$app_name")

    if [[ ! -f "$state_file" ]]; then
        log_error "State file not found: $state_file"
        return 1
    fi

    # Simple key=value update (works for top-level keys)
    # For now, just track in comments - full YAML editing is complex
    log_debug "Updating state: $app_name.$key = $value"

    return 0
}

# Add backup snapshot to state
# Usage: state_add_snapshot app_name timestamp
state_add_snapshot() {
    local app_name="$1"
    local timestamp="$2"
    local state_file

    state_file=$(state_get_file "$app_name")

    if [[ ! -f "$state_file" ]]; then
        log_error "State file not found: $state_file"
        return 1
    fi

    log_debug "Adding snapshot to state: $timestamp"

    # Append to snapshots section
    sed -i "/^snapshots:/a\\  - $timestamp" "$state_file" 2>/dev/null || \
    sed -i '' "/^snapshots:/a\\
  - $timestamp
" "$state_file"

    return 0
}

# Get list of installed files from state
# Usage: state_get_files app_name
state_get_files() {
    local app_name="$1"
    local state_file

    state_file=$(state_get_file "$app_name")

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    # Extract files from state
    yaml_load "$state_file"

    # Get array items under 'files'
    local in_files=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^files: ]]; then
            in_files=true
            continue
        fi

        if [[ "$in_files" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*- ]]; then
                # Extract file path
                local file
                file=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')
                echo "$file"
            elif [[ "$line" =~ ^[[:alpha:]] ]]; then
                # Hit next section, stop
                break
            fi
        fi
    done < "$state_file"
}

# Get backup directory from state
# Usage: state_get_backup_dir app_name
state_get_backup_dir() {
    local app_name="$1"
    local state_file

    state_file=$(state_get_file "$app_name")

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    # Extract backup dir
    grep "^[[:space:]]*dir:" "$state_file" | head -1 | awk '{print $2}'
}

# Get list of snapshots from state
# Usage: state_get_snapshots app_name
state_get_snapshots() {
    local app_name="$1"
    local state_file

    state_file=$(state_get_file "$app_name")

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    # Extract snapshots
    local in_snapshots=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^snapshots: ]]; then
            in_snapshots=true
            continue
        fi

        if [[ "$in_snapshots" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*- ]]; then
                local snapshot
                snapshot=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')
                [[ -n "$snapshot" ]] && echo "$snapshot"
            elif [[ "$line" =~ ^[[:alpha:]] ]]; then
                break
            fi
        fi
    done < "$state_file"
}

# Remove state file
# Usage: state_remove app_name
state_remove() {
    local app_name="$1"
    local state_file

    state_file=$(state_get_file "$app_name")

    if [[ -f "$state_file" ]]; then
        log_debug "Removing state file: $state_file"
        rm -f "$state_file"
    fi

    return 0
}

# Show state information
# Usage: state_show app_name
state_show() {
    local app_name="$1"
    local state_file

    state_file=$(state_get_file "$app_name")

    if [[ ! -f "$state_file" ]]; then
        echo "Not installed"
        return 1
    fi

    cat "$state_file"
}

# Update file list in state file
# Usage: state_update_files app_name files[@]
state_update_files() {
    local app_name="$1"
    shift
    local files=("$@")
    local state_file

    state_file=$(state_get_file "$app_name")

    if [[ ! -f "$state_file" ]]; then
        log_error "State file not found: $state_file"
        return 1
    fi

    log_debug "Updating file list in state: $app_name (${#files[@]} files)"

    # Replace the files section: keep everything before "files:" and after the
    # list items, inserting the new file list in between.
    local tmp_file="${state_file}.tmp"
    local section="before"  # before | files | after
    {
        while IFS= read -r line; do
            case "$section" in
                before)
                    echo "$line"
                    if [[ "$line" =~ ^files: ]]; then
                        section="files"
                        for file in "${files[@]}"; do
                            echo "  - $file"
                        done
                    fi
                    ;;
                files)
                    # Skip old file entries; stop at next section
                    if [[ "$line" =~ ^[[:alpha:]] || "$line" == "" ]]; then
                        section="after"
                        echo "$line"
                    fi
                    ;;
                after)
                    echo "$line"
                    ;;
            esac
        done < "$state_file"
    } > "$tmp_file" && mv "$tmp_file" "$state_file"
}

# Set version in state file
# Usage: state_set_version app_name version
state_set_version() {
    local app_name="$1"
    local version="$2"
    local state_file
    state_file=$(state_get_file "$app_name")
    [[ -f "$state_file" ]] || return 1
    sed -i "s/^  version: .*/  version: $version/" "$state_file"
}

# Get version from state file
# Usage: state_get_version app_name
state_get_version() {
    local app_name="$1"
    local state_file
    state_file=$(state_get_file "$app_name")
    [[ -f "$state_file" ]] || return 1
    grep "^  version:" "$state_file" | head -1 | awk '{print $2}'
}

# Export functions
export -f state_init
export -f state_get_file
export -f state_is_installed
export -f state_set_version
export -f state_get_version
export -f state_update_files
export -f state_create
export -f state_update
export -f state_add_snapshot
export -f state_get_files
export -f state_get_backup_dir
export -f state_get_snapshots
export -f state_remove
export -f state_show
