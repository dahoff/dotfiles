#!/usr/bin/env bash
# installer.sh - Shared app installer core
#
# An app's install.sh sets APP_DIR, sources this file, redefines any app_*
# hooks (or core functions) it needs, then calls: installer_main "$@"

ROOT_DIR="$(dirname "$APP_DIR")"

source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/yaml.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backup.sh"
source "$ROOT_DIR/lib/state.sh"
source "$ROOT_DIR/lib/remote.sh"

# Configuration
CONFIG_FILE="$APP_DIR/config.yaml"
FILES_DIR="$APP_DIR/files"

# Global variables (set from config)
APP_NAME=""
APP_VERSION=""
BACKUP_DIR=""
MAX_BACKUPS=3
declare -a CONFIG_FILES=()
declare -a CONFIG_DESTS=()
declare -a CONFIG_MODES=()

# Flags
DRY_RUN=false
NO_BACKUP=false
TEST_MODE=false
FORCE=false
REMOTE_MODE=false

# Cross-module: shell scripts drop-in directory
SHELL_SCRIPTS_DIR="$HOME/.bashrc.d"

# App switches (apps override after sourcing)
UPGRADE_ALWAYS=false               # true: upgrade never skips on matching version
declare -a APP_REMOTE_DROP_ARGS=() # "--flag value" options not forwarded with --remote

# Set by app_parse_arg: number of arguments it consumed
APP_ARG_SHIFT=0

# --- Hooks: apps redefine these after sourcing -----------------------------

# Consume an app-specific option; return 0 and set APP_ARG_SHIFT if handled
app_parse_arg() { return 1; }
# Print app-specific usage lines
app_usage() { :; }
# After config.yaml is loaded
app_after_load_config() { :; }
# install only: after the requirements check, before backups
app_pre_install() { :; }
# install|upgrade ($1): after backups, before files are deployed
app_pre_deploy() { :; }
# install|upgrade ($1): after files are deployed, before state is written
app_post_deploy() { :; }
# install|upgrade ($1): after files are deployed and state is written
app_post_files() { :; }
# install|upgrade ($1): after post_install commands ran
app_post_install() { :; }
# upgrade found nothing to do
app_up_to_date() { :; }
# uninstall: after files were restored/removed, before state is removed
app_post_uninstall() { :; }
# --remote: before packaging
app_pre_remote() { :; }

# Deploy one file; apps may override and call deploy_file_default for the rest
# Usage: deploy_file src dest mode strategy install|upgrade
deploy_file() { deploy_file_default "$@"; }

# ---------------------------------------------------------------------------

# Load configuration from config.yaml
load_config() {
    log_debug "Loading configuration from: $CONFIG_FILE"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        return 1
    fi

    # Validate YAML
    yaml_validate "$CONFIG_FILE" || return 1

    # Parse config
    yaml_load "$CONFIG_FILE"

    # Extract values
    APP_NAME=$(yaml_get "name" "unknown")
    BACKUP_DIR=$(abs_path "$(yaml_get "dir" "$HOME/.bak/$APP_NAME")")
    MAX_BACKUPS=$(yaml_get "max_backups" "3")

    log_debug "App: $APP_NAME v$APP_VERSION"
    log_debug "Backup dir: $BACKUP_DIR"
    log_debug "Max backups: $MAX_BACKUPS"
    log_debug "Shell scripts dir: $SHELL_SCRIPTS_DIR"

    # Load files configuration
    local in_files=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^files: ]]; then
            in_files=true
            continue
        fi

        if [[ "$in_files" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*src: ]]; then
                local src
                src=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*src:[[:space:]]*//')
                CONFIG_FILES+=("$src")
            elif [[ "$line" =~ ^[[:space:]]*dest: ]]; then
                local dest
                dest=$(echo "$line" | sed 's/^[[:space:]]*dest:[[:space:]]*//')
                # Resolve ${SHELL_SCRIPTS_DIR} placeholder
                dest="${dest//\$\{SHELL_SCRIPTS_DIR\}/$SHELL_SCRIPTS_DIR}"
                dest=$(abs_path "$dest")
                CONFIG_DESTS+=("$dest")
            elif [[ "$line" =~ ^[[:space:]]*mode: ]]; then
                local mode
                mode=$(echo "$line" | sed "s/^[[:space:]]*mode:[[:space:]]*['\"]*//" | sed "s/['\"].*//")
                CONFIG_MODES+=("$mode")
            elif [[ "$line" =~ ^[[:alpha:]] ]]; then
                break
            fi
        fi
    done < "$CONFIG_FILE"

    # Ensure shell scripts directory exists if any files target it
    local d
    for d in "${CONFIG_DESTS[@]}"; do
        if [[ "$d" == "$SHELL_SCRIPTS_DIR"/* ]] && ! is_dry_run; then
            ensure_dir "$SHELL_SCRIPTS_DIR" || return 1
            break
        fi
    done

    log_debug "Loaded ${#CONFIG_FILES[@]} files to install"

    return 0
}

# Check requirements
check_requirements() {
    log_info "Checking requirements..."

    local missing=()

    # Extract requirements from config
    local in_requirements=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^requirements: ]]; then
            in_requirements=true
            continue
        fi

        if [[ "$in_requirements" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*- ]]; then
                local req
                req=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')

                if ! command_exists "$req"; then
                    missing+=("$req")
                    log_error "Required command not found: $req"
                fi
            elif [[ "$line" =~ ^[[:alpha:]] ]]; then
                break
            fi
        fi
    done < "$CONFIG_FILE"

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing requirements: ${missing[*]}"
        return 1
    fi

    log_success "All requirements satisfied"
    return 0
}

# Path of the file to deploy for a config src
installer_src() { echo "$FILES_DIR/$1"; }

# Strategy for a config src
installer_strategy() { echo replace; }

# Copy one file into place
# Usage: deploy_file_default src dest mode strategy install|upgrade
deploy_file_default() {
    local src="$1" dest="$2" mode="$3" verb="${5:-install}"

    if [[ "$verb" == upgrade ]]; then
        if is_dry_run; then
            log_info "[DRY-RUN] Would update: $src -> $dest"
            return 0
        fi
        log_info "Updating: $(basename "$dest")"
    else
        if is_dry_run; then
            log_info "[DRY-RUN] Would install: $src -> $dest (mode: $mode)"
            return 0
        fi
        log_info "Installing: $(basename "$dest")"
    fi
    copy_file "$src" "$dest" || return 1
    set_permissions "$dest" "$mode"
}

# Deploy every config file
# Usage: deploy_all_files install|upgrade
deploy_all_files() {
    local verb="$1" i
    for i in "${!CONFIG_FILES[@]}"; do
        local name="${CONFIG_FILES[$i]}"
        local dest="${CONFIG_DESTS[$i]}"
        local mode="${CONFIG_MODES[$i]:-0644}"
        local src
        src=$(installer_src "$name")

        if [[ ! -f "$src" ]]; then
            log_error "Source file not found: $src"
            return 1
        fi
        deploy_file "$src" "$dest" "$mode" "$(installer_strategy "$name")" "$verb" || return 1
    done
}

# Deploy operation (idempotent: install if new, upgrade if exists)
cmd_deploy() {
    if state_is_installed "$APP_NAME"; then
        log_info "$APP_NAME already installed, upgrading..."
        cmd_upgrade
    else
        cmd_install
    fi
}

# Install operation
cmd_install() {
    log_info "Installing $APP_NAME..."

    # Check if already installed
    if state_is_installed "$APP_NAME"; then
        log_error "$APP_NAME is already installed"
        log_info "Use 'upgrade' to update, or 'uninstall' first"
        return 1
    fi

    # Check requirements
    check_requirements || return 1

    app_pre_install || return 1

    # Initialize backup
    if [[ "$NO_BACKUP" != true ]]; then
        backup_init "$APP_NAME" "$BACKUP_DIR" || return 1
    fi

    # Backup original files
    if [[ "$NO_BACKUP" != true ]]; then
        log_info "Creating original backups..."
        for dest in "${CONFIG_DESTS[@]}"; do
            if [[ -f "$dest" ]]; then
                backup_create_original "$dest" "$BACKUP_DIR" || return 1
            fi
        done
    fi

    app_pre_deploy install || return 1

    log_info "Installing configuration files..."
    deploy_all_files install || return 1
    app_post_deploy install || return 1

    # Create state file
    if ! is_dry_run; then
        state_init || return 1
        state_create "$APP_NAME" "$APP_VERSION" "$BACKUP_DIR" "${CONFIG_DESTS[@]}" || return 1
    fi

    app_post_files install || return 1

    # Run post-install commands
    run_post_install

    app_post_install install

    log_success "$APP_NAME installed successfully!"
    return 0
}

# Upgrade operation
cmd_upgrade() {
    log_info "Upgrading $APP_NAME..."

    # Check if installed
    if ! state_is_installed "$APP_NAME"; then
        log_error "$APP_NAME is not installed"
        log_info "Use 'install' first"
        return 1
    fi

    # Skip if already at this version
    if [[ "$UPGRADE_ALWAYS" != true ]]; then
        local installed_version
        installed_version=$(state_get_version "$APP_NAME")
        if [[ "$installed_version" == "$APP_VERSION" ]] && [[ "$FORCE" != true ]]; then
            local all_present=true
            for dest in "${CONFIG_DESTS[@]}"; do
                if [[ ! -f "$dest" ]]; then
                    log_warn "Expected file missing, re-applying: $dest"
                    all_present=false
                    break
                fi
            done
            if [[ "$all_present" == true ]]; then
                log_info "$APP_NAME is already up to date ($APP_VERSION)"
                app_up_to_date
            return 0
            fi
        fi
    fi

    # Create snapshot backup
    if [[ "$NO_BACKUP" != true ]]; then
        log_info "Creating backup snapshot..."
        local ts
        for dest in "${CONFIG_DESTS[@]}"; do
            if [[ -f "$dest" ]]; then
                ts=$(backup_create_snapshot "$dest" "$BACKUP_DIR")
            fi
        done

        # Add snapshot to state
        if [[ -n "${ts:-}" ]]; then
            state_add_snapshot "$APP_NAME" "$ts" || log_warn "Failed to update state"
        fi

        # Prune old backups
        backup_prune "$BACKUP_DIR" "$MAX_BACKUPS"
    fi

    app_pre_deploy upgrade || return 1

    log_info "Updating configuration files..."
    deploy_all_files upgrade || return 1
    app_post_deploy upgrade || return 1

    # Update state file (version + file list)
    if ! is_dry_run; then
        state_set_version "$APP_NAME" "$APP_VERSION"
        state_update_files "$APP_NAME" "${CONFIG_DESTS[@]}"
    fi

    app_post_files upgrade || return 1

    # Run post-install commands
    run_post_install

    app_post_install upgrade

    log_success "$APP_NAME upgraded successfully!"
    return 0
}

# Uninstall operation
cmd_uninstall() {
    log_info "Uninstalling $APP_NAME..."

    # Check if installed
    if ! state_is_installed "$APP_NAME"; then
        log_error "$APP_NAME is not installed"
        return 1
    fi

    # Get backup directory from state
    local backup_dir
    backup_dir=$(state_get_backup_dir "$APP_NAME")

    # Get installed files from state
    local files
    mapfile -t files < <(state_get_files "$APP_NAME")

    log_info "Restoring ${#files[@]} original file(s)..."

    # Restore original files
    for file in "${files[@]}"; do
        if backup_has_original "$backup_dir" "$(basename "$file")"; then
            backup_restore "$backup_dir" "original" "$file" || log_warn "Failed to restore: $file"
        else
            log_info "Removing: $file (no original backup)"
            if ! is_dry_run; then
                rm -f "$file"
            fi
        fi
    done

    app_post_uninstall

    # Remove state file
    if ! is_dry_run; then
        state_remove "$APP_NAME"
    fi

    log_success "$APP_NAME uninstalled successfully!"
    log_info "Backups preserved at: $backup_dir"
    log_info "Shell scripts directory left intact: $SHELL_SCRIPTS_DIR"
    return 0
}

# Rollback operation
cmd_rollback() {
    local target_ts="${1:-}"

    log_info "Rolling back $APP_NAME..."

    # Check if installed
    if ! state_is_installed "$APP_NAME"; then
        log_error "$APP_NAME is not installed"
        return 1
    fi

    # Get backup directory
    local backup_dir
    backup_dir=$(state_get_backup_dir "$APP_NAME")

    # Determine rollback target
    if [[ -z "$target_ts" ]]; then
        # Rollback to previous (latest snapshot)
        target_ts=$(backup_get_latest "$backup_dir")
        if [[ -z "$target_ts" ]]; then
            log_error "No snapshots available to rollback to"
            return 1
        fi
        log_info "Rolling back to previous snapshot: $target_ts"
    elif [[ "$target_ts" == "original" ]]; then
        log_info "Rolling back to original configuration"
    else
        log_info "Rolling back to snapshot: $target_ts"
    fi

    # Verify backup exists
    if ! backup_verify "$backup_dir" "$target_ts"; then
        log_error "Backup verification failed"
        return 1
    fi

    # Get files to restore
    local files
    mapfile -t files < <(state_get_files "$APP_NAME")

    # Restore files
    for file in "${files[@]}"; do
        backup_restore "$backup_dir" "$target_ts" "$file" || log_warn "Failed to restore: $file"
    done

    # Update version to reflect rollback state so upgrade detects a change
    state_set_version "$APP_NAME" "rollback_${target_ts}"

    log_success "Rollback complete!"
    return 0
}

# Status operation
cmd_status() {
    log_info "Status for $APP_NAME:"
    echo

    if ! state_is_installed "$APP_NAME"; then
        echo "Status: Not installed"
        return 0
    fi

    echo "Status: Installed"
    echo

    # Show state
    state_show "$APP_NAME"

    return 0
}

# Verify operation
cmd_verify() {
    log_info "Verifying $APP_NAME installation..."

    if ! state_is_installed "$APP_NAME"; then
        log_error "$APP_NAME is not installed"
        return 1
    fi

    local errors=0

    # Check each file
    local files
    mapfile -t files < <(state_get_files "$APP_NAME")

    for file in "${files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "Missing file: $file"
            ((errors++))
        else
            log_success "Found: $file"
        fi
    done

    # Verify backups
    local backup_dir
    backup_dir=$(state_get_backup_dir "$APP_NAME")

    if [[ -d "$backup_dir/original" ]]; then
        log_info "Verifying original backup..."
        if backup_verify "$backup_dir" "original"; then
            log_success "Original backup verified"
        else
            ((errors++))
        fi
    fi

    if [[ $errors -eq 0 ]]; then
        log_success "Verification passed!"
        return 0
    else
        log_error "Verification failed with $errors error(s)"
        return 1
    fi
}

# List backups operation
cmd_backups() {
    log_info "Backups for $APP_NAME:"
    echo

    if ! state_is_installed "$APP_NAME"; then
        echo "Not installed"
        return 0
    fi

    local backup_dir
    backup_dir=$(state_get_backup_dir "$APP_NAME")

    # Show original
    if [[ -d "$backup_dir/original" ]]; then
        echo "Original backup:"
        echo "  Location: $backup_dir/original"
        ls -lh "$backup_dir/original" 2>/dev/null | tail -n +2 | awk '{print "  " $9 " (" $5 ")"}'
        echo
    fi

    # Show snapshots
    local snapshots
    mapfile -t snapshots < <(backup_list_snapshots "$backup_dir")

    if [[ ${#snapshots[@]} -gt 0 ]]; then
        echo "Snapshots:"
        for ts in "${snapshots[@]}"; do
            echo "  $ts"
            ls -lh "$backup_dir/$ts" 2>/dev/null | tail -n +2 | awk '{print "    " $9 " (" $5 ")"}'
        done
    else
        echo "No snapshots"
    fi

    return 0
}

# Diff operation
cmd_diff() {
    log_info "Showing differences for $APP_NAME..."
    echo

    local has_diff=false

    for i in "${!CONFIG_FILES[@]}"; do
        local src="$FILES_DIR/${CONFIG_FILES[$i]}"
        local dest="${CONFIG_DESTS[$i]}"

        if [[ ! -f "$dest" ]]; then
            echo "File not installed: $dest"
            has_diff=true
            continue
        fi

        echo "=== $(basename "$dest") ==="
        if diff -u "$dest" "$src" 2>/dev/null; then
            echo "No differences"
        else
            has_diff=true
        fi
        echo
    done

    if [[ "$has_diff" == false ]]; then
        log_info "No differences found"
    fi

    return 0
}

# Run post-install commands
run_post_install() {
    if is_dry_run; then
        return 0
    fi

    # Extract post-install commands
    local in_post_install=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^post_install: ]]; then
            in_post_install=true
            continue
        fi

        if [[ "$in_post_install" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*- ]]; then
                local cmd
                cmd=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')
                log_debug "Running post-install: $cmd"
                eval "$cmd" &>/dev/null || log_warn "Post-install command failed: $cmd"
            elif [[ "$line" =~ ^[[:alpha:]] ]]; then
                break
            fi
        fi
    done < "$CONFIG_FILE"
}

# Show usage
usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
  deploy               Install if new, upgrade if exists (idempotent)
  install              Install $APP_NAME configuration
  upgrade              Upgrade existing installation
  uninstall            Uninstall and restore original files
  rollback [TIMESTAMP] Rollback to previous or specific backup
  status               Show installation status
  verify               Verify installation integrity
  backups              List available backups
  diff                 Show differences between installed and new
  help                 Show this help message

Options:
  --remote HOST        Execute on remote host (user@host or host)
  --dry-run            Show what would be done without making changes
  --test-mode          Run in test mode (sandbox)
  --no-backup          Skip creating backups
  --log FILE           Log to file
  --verbose            Verbose output
  --quiet              Minimal output
  --force              Force operation without prompts
  --shell-scripts-dir PATH   Set drop-in directory (default: ~/.bashrc.d)

Examples:
  $0 install
  $0 upgrade --no-backup
  $0 rollback
  $0 rollback --to 20240225_120000
  $0 rollback --to original
  $0 install --remote user@hostname
  $0 status --remote hostname

EOF
    app_usage
}

# Validate and sanitize command
validate_command() {
    local cmd="$1"

    # Sanitize input - remove any special characters
    cmd=$(echo "$cmd" | tr -cd '[:alnum:]-')

    # List of valid commands
    local valid_commands=(
        "deploy"
        "install"
        "upgrade"
        "uninstall"
        "rollback"
        "status"
        "verify"
        "backups"
        "diff"
        "help"
        "-h"
        "--help"
    )

    # Check if command is valid
    for valid_cmd in "${valid_commands[@]}"; do
        if [[ "$cmd" == "$valid_cmd" ]]; then
            echo "$cmd"
            return 0
        fi
    done

    # Invalid command
    echo "Error: Unknown command '$1'" >&2
    echo "" >&2
    echo "Valid commands:" >&2
    echo "  deploy     - Install if new, upgrade if exists" >&2
    echo "  install    - Install configuration" >&2
    echo "  upgrade    - Upgrade to new version" >&2
    echo "  uninstall  - Remove installation" >&2
    echo "  rollback   - Restore previous version" >&2
    echo "  status     - Show installation status" >&2
    echo "  verify     - Verify installation integrity" >&2
    echo "  backups    - List available backups" >&2
    echo "  diff       - Show differences" >&2
    echo "  help       - Show usage information" >&2
    return 1
}

# Parse arguments
parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    # Validate command FIRST before any other operations
    COMMAND=$(validate_command "$1") || exit 1
    shift

    while [[ $# -gt 0 ]]; do
        case $1 in
            --remote)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --remote requires a host argument" >&2
                    exit 1
                fi
                REMOTE_MODE=true
                remote_parse_host "$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                export DRY_RUN
                shift
                ;;
            --test-mode)
                TEST_MODE=true
                export TEST_MODE
                shift
                ;;
            --no-backup)
                NO_BACKUP=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --to)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --to requires a snapshot name" >&2
                    exit 1
                fi
                # Sanitize snapshot name - allow alphanumeric, dash, underscore
                ROLLBACK_TARGET=$(echo "$2" | tr -cd '[:alnum:]_-')
                if [[ -z "$ROLLBACK_TARGET" ]]; then
                    echo "Error: Invalid snapshot name '$2'" >&2
                    exit 1
                fi
                shift 2
                ;;
            --log)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --log requires a filename argument" >&2
                    exit 1
                fi
                # Handled by log_init, but skip the filename argument
                shift
                [[ $# -gt 0 && "$1" != --* ]] && shift || true
                ;;
            --verbose|--quiet)
                # Handled by log_init
                shift
                ;;
            --shell-scripts-dir)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --shell-scripts-dir requires a path argument" >&2
                    exit 1
                fi
                SHELL_SCRIPTS_DIR=$(abs_path "$2")
                shift 2
                ;;
            *)
                if app_parse_arg "$@"; then
                    shift "$APP_ARG_SHIFT"
                else
                    echo "Error: Unknown option: $1" >&2
                    usage
                    exit 1
                fi
                ;;
        esac
    done
}

# Execute in remote mode
execute_remote() {
    log_info "Remote installation mode"

    # Check connection
    remote_check_connection || exit 1

    app_pre_remote

    # Skip if remote is already at current version
    remote_skip_if_current "$APP_DIR" "$COMMAND" "$FORCE" && exit 0

    # Package installer
    local package_file
    package_file=$(remote_package_installer "$APP_DIR") || exit 1

    # Deploy to remote
    remote_deploy_installer "$package_file" || {
        rm -f "$package_file"
        exit 1
    }

    # Build remote arguments (exclude --remote)
    local remote_args=()
    local skip_next=false

    for arg in "$@"; do
        if [[ "$skip_next" == true ]]; then
            skip_next=false
            continue
        fi

        if [[ "$arg" == "--remote" ]] || list_contains "$arg" "${APP_REMOTE_DROP_ARGS[@]}"; then
            skip_next=true
            continue
        fi

        remote_args+=("$arg")
    done

    # Execute installer on remote
    local app_name
    app_name=$(basename "$APP_DIR")

    remote_run_installer "$app_name" "${remote_args[@]}"
    local exit_code=$?

    # Cleanup
    rm -f "$package_file"
    remote_cleanup

    exit $exit_code
}

# Main
installer_main() {
    # Parse arguments
    parse_args "$@"

    # Initialize logging
    log_init "$@"

    # Handle remote mode
    if [[ "$REMOTE_MODE" == true ]]; then
        execute_remote "$@"
        # Never returns (exits in execute_remote)
    fi

    # Load configuration
    load_config || exit 1
    app_after_load_config || exit 1

    # Set version from git hash
    # Use .version file if present (remote deploys), otherwise git hash
    if [[ -f "$APP_DIR/.version" ]]; then
        APP_VERSION=$(< "$APP_DIR/.version")
    else
        APP_VERSION=$(cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    fi

    # Initialize state
    state_init || exit 1

    # Execute command
    case "$COMMAND" in
        deploy)
            cmd_deploy
            ;;
        install)
            cmd_install
            ;;
        upgrade)
            cmd_upgrade
            ;;
        uninstall)
            cmd_uninstall
            ;;
        rollback)
            cmd_rollback "${ROLLBACK_TARGET:-}"
            ;;
        status)
            cmd_status
            ;;
        verify)
            cmd_verify
            ;;
        backups)
            cmd_backups
            ;;
        diff)
            cmd_diff
            ;;
        help|--help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            usage
            exit 1
            ;;
    esac
}
