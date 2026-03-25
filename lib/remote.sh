#!/usr/bin/env bash
# remote.sh - Remote installation support via SSH/SCP

# Remote configuration
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_TMP_DIR="/tmp/dotfiles-install"
REMOTE_TIMEOUT=30

# Parse remote host specification
# Usage: remote_parse_host user@host
remote_parse_host() {
    local host_spec="$1"

    if [[ "$host_spec" =~ ^([^@]+)@(.+)$ ]]; then
        REMOTE_USER="${BASH_REMATCH[1]}"
        REMOTE_HOST="${BASH_REMATCH[2]}"
    else
        REMOTE_HOST="$host_spec"
        REMOTE_USER="$USER"
    fi

    log_debug "Remote host: $REMOTE_USER@$REMOTE_HOST"
}

# Check if remote host is reachable
# Usage: remote_check_connection
remote_check_connection() {
    log_info "Testing connection to $REMOTE_USER@$REMOTE_HOST..."

    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" "echo 'Connection test'" &>/dev/null; then
        log_success "Connection successful"
        return 0
    else
        log_error "Cannot connect to $REMOTE_USER@$REMOTE_HOST"
        log_info "Make sure SSH keys are set up or use ssh-copy-id"
        return 1
    fi
}

# Execute command on remote host
# Usage: remote_exec "command"
remote_exec() {
    local cmd="$1"

    log_debug "Remote exec: $cmd"

    ssh -o ConnectTimeout=$REMOTE_TIMEOUT "$REMOTE_USER@$REMOTE_HOST" "$cmd"
}

# Copy file/directory to remote host
# Usage: remote_copy_to local_path remote_path
remote_copy_to() {
    local local_path="$1"
    local remote_path="$2"

    log_debug "Copying to remote: $local_path -> $remote_path"

    scp -r -o ConnectTimeout=$REMOTE_TIMEOUT "$local_path" "$REMOTE_USER@$REMOTE_HOST:$remote_path" || {
        log_error "Failed to copy to remote: $local_path"
        return 1
    }

    return 0
}

# Copy file from remote host
# Usage: remote_copy_from remote_path local_path
remote_copy_from() {
    local remote_path="$1"
    local local_path="$2"

    log_debug "Copying from remote: $remote_path -> $local_path"

    scp -r -o ConnectTimeout=$REMOTE_TIMEOUT "$REMOTE_USER@$REMOTE_HOST:$remote_path" "$local_path" || {
        log_error "Failed to copy from remote: $remote_path"
        return 1
    }

    return 0
}

# Create remote directory
# Usage: remote_mkdir path
remote_mkdir() {
    local path="$1"

    remote_exec "mkdir -p '$path'" || {
        log_error "Failed to create remote directory: $path"
        return 1
    }

    return 0
}

# Check if remote file exists
# Usage: remote_file_exists path
remote_file_exists() {
    local path="$1"

    remote_exec "test -f '$path'" &>/dev/null
}

# Check if remote directory exists
# Usage: remote_dir_exists path
remote_dir_exists() {
    local path="$1"

    remote_exec "test -d '$path'" &>/dev/null
}

# Package installer for remote deployment
# Usage: remote_package_installer app_dir
remote_package_installer() {
    local app_dir="$1"
    local app_name
    local package_file

    app_name=$(basename "$app_dir")
    package_file="/tmp/${app_name}-installer-$(timestamp).tar.gz"

    log_info "Packaging installer: $app_name"

    # Create package with app files and libraries
    local root_dir
    root_dir=$(dirname "$app_dir")

    # Write version file so remote installs know the current version
    # (remote has no .git directory, so git rev-parse would fail)
    local version
    version=$(cd "$root_dir" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo "$version" > "$app_dir/.version"

    tar -czf "$package_file" \
        -C "$root_dir" \
        "$(basename "$app_dir")" \
        lib/ \
        2>/dev/null || {
        rm -f "$app_dir/.version"
        log_error "Failed to create package"
        return 1
    }

    # Clean up version file from local tree
    rm -f "$app_dir/.version"

    log_debug "Package created: $package_file"
    echo "$package_file"
}

# Deploy installer to remote host
# Usage: remote_deploy_installer package_file
remote_deploy_installer() {
    local package_file="$1"

    log_info "Deploying to $REMOTE_USER@$REMOTE_HOST..."

    # Create remote temporary directory
    remote_mkdir "$REMOTE_TMP_DIR" || return 1

    # Copy package to remote
    remote_copy_to "$package_file" "$REMOTE_TMP_DIR/" || return 1

    # Extract on remote
    local package_name
    package_name=$(basename "$package_file")

    log_info "Extracting on remote host..."
    remote_exec "cd '$REMOTE_TMP_DIR' && tar -xzf '$package_name'" || {
        log_error "Failed to extract package on remote"
        return 1
    }

    log_success "Deployment complete"
    return 0
}

# Execute installer on remote host
# Usage: remote_run_installer app_name command [args...]
remote_run_installer() {
    local app_name="$1"
    local command="$2"
    shift 2
    local args=("$@")

    local installer_path="$REMOTE_TMP_DIR/$app_name/install.sh"

    log_info "Running remote installer: $command ${args[*]}"

    # Build command with proper escaping
    local cmd="cd '$REMOTE_TMP_DIR/$app_name' && bash install.sh $command"

    # Add arguments
    for arg in "${args[@]}"; do
        cmd="$cmd '$arg'"
    done

    # Execute on remote
    remote_exec "$cmd"
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_success "Remote operation completed successfully"
    else
        log_error "Remote operation failed with exit code: $exit_code"
    fi

    return $exit_code
}

# Cleanup remote temporary directory
# Usage: remote_cleanup
remote_cleanup() {
    log_debug "Cleaning up remote temporary directory"

    remote_exec "rm -rf '$REMOTE_TMP_DIR'" || {
        log_warn "Failed to cleanup remote directory"
    }
}

# Check if we're running in remote mode
is_remote_mode() {
    [[ -n "$REMOTE_HOST" ]]
}

# Export functions
export -f remote_parse_host
export -f remote_check_connection
export -f remote_exec
export -f remote_copy_to
export -f remote_copy_from
export -f remote_mkdir
export -f remote_file_exists
export -f remote_dir_exists
export -f remote_package_installer
export -f remote_deploy_installer
export -f remote_run_installer
export -f remote_cleanup
export -f is_remote_mode
