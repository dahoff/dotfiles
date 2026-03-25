#!/usr/bin/env bash
# packages/install.sh - Custom tool installer and drop-in manager
# OS package installation is handled by setup.sh (phase 1).
# This installer manages custom tool scripts and their shell drop-ins.
# Usage: ./install.sh <command> [options]

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="$SCRIPT_DIR"

# Source libraries
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/yaml.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backup.sh"
source "$ROOT_DIR/lib/state.sh"
source "$ROOT_DIR/lib/remote.sh"

# Configuration
FILES_DIR="$APP_DIR/files"

# Global variables
APP_NAME="packages"
APP_VERSION=""
BACKUP_DIR=""
MAX_BACKUPS=3
declare -a CONFIG_FILES=()
declare -a CONFIG_DESTS=()
declare -a CONFIG_MODES=()

# Custom installs (loaded from active profile)
declare -a CUSTOM_NAMES=()
declare -a CUSTOM_CHECKS=()
declare -a CUSTOM_SCRIPTS=()
declare -a CUSTOM_DROPINS=()

# Flags
DRY_RUN=false
NO_BACKUP=false
TEST_MODE=false
FORCE=false
REMOTE_MODE=false

# Cross-module: shell scripts drop-in directory
SHELL_SCRIPTS_DIR="$HOME/.bashrc.d"

# Profiles directory
PROFILES_DIR="$ROOT_DIR/profiles"

# Load custom install definitions from the active profile
load_custom_from_profile() {
    local profile="${DOTFILES_PROFILE:-complete}"
    local profile_path="$PROFILES_DIR/${profile}.yaml"

    if [[ ! -f "$profile_path" ]]; then
        log_debug "Profile not found: $profile_path, checking for extends..."
        # For derived profiles, resolve to parent
        local extends=""
        if [[ -f "$profile_path" ]]; then
            extends=$(grep "^extends:" "$profile_path" 2>/dev/null | sed 's/^extends:[[:space:]]*//' | sed 's/[[:space:]]*$//')
        fi
        if [[ -n "$extends" ]]; then
            profile_path="$PROFILES_DIR/${extends}.yaml"
        fi
    fi

    [[ ! -f "$profile_path" ]] && return 0

    local in_packages=false
    local current_name=""
    local current_check=""
    local current_script=""
    local current_dropin=""
    local in_custom=false

    _save_custom() {
        if [[ -n "$current_name" && -n "$current_script" ]]; then
            CUSTOM_NAMES+=("$current_name")
            CUSTOM_CHECKS+=("$current_check")
            CUSTOM_SCRIPTS+=("$current_script")
            CUSTOM_DROPINS+=("$current_dropin")
        fi
    }

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^packages: ]]; then
            in_packages=true
            continue
        fi

        if [[ "$in_packages" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
                _save_custom
                current_name="${BASH_REMATCH[1]}"
                current_name=$(echo "$current_name" | sed 's/[[:space:]]*$//')
                current_check=""
                current_script=""
                current_dropin=""
                in_custom=false
            elif [[ "$line" =~ ^[[:space:]]+custom:[[:space:]]*$ ]]; then
                in_custom=true
            elif [[ "$in_custom" == true ]]; then
                if [[ "$line" =~ ^[[:space:]]+check:[[:space:]]*(.*) ]]; then
                    current_check="${BASH_REMATCH[1]}"
                    current_check=$(echo "$current_check" | sed 's/[[:space:]]*$//')
                elif [[ "$line" =~ ^[[:space:]]+script:[[:space:]]*(.*) ]]; then
                    current_script="${BASH_REMATCH[1]}"
                    current_script=$(echo "$current_script" | sed 's/[[:space:]]*$//')
                elif [[ "$line" =~ ^[[:space:]]+dropin:[[:space:]]*(.*) ]]; then
                    current_dropin="${BASH_REMATCH[1]}"
                    current_dropin=$(echo "$current_dropin" | sed 's/[[:space:]]*$//')
                fi
            elif [[ "$line" =~ ^[[:alpha:]] ]]; then
                break
            else
                # Non-custom field resets in_custom
                if [[ "$line" =~ ^[[:space:]]+(apt|dnf|brew|config): ]]; then
                    in_custom=false
                fi
            fi
        fi
    done < "$profile_path"

    _save_custom

    log_debug "Loaded ${#CUSTOM_NAMES[@]} custom install(s) from profile"
}

# Load configuration
load_config() {
    log_debug "Loading custom installs from profile"

    BACKUP_DIR=$(abs_path "$HOME/.bak/$APP_NAME")

    load_custom_from_profile

    # Build file lists from custom dropins
    for i in "${!CUSTOM_DROPINS[@]}"; do
        local dropin="${CUSTOM_DROPINS[$i]}"
        if [[ -n "$dropin" ]]; then
            CONFIG_FILES+=("$dropin")
            local dest_name
            dest_name=$(basename "$dropin")
            CONFIG_DESTS+=("$(abs_path "$SHELL_SCRIPTS_DIR/$dest_name")")
            CONFIG_MODES+=("0644")
        fi
    done

    # Ensure shell scripts directory exists if any drop-ins will be deployed
    if [[ ${#CONFIG_DESTS[@]} -gt 0 ]] && ! is_dry_run; then
        ensure_dir "$SHELL_SCRIPTS_DIR" || return 1
    fi

    log_debug "Loaded ${#CONFIG_FILES[@]} drop-in files to install"
    return 0
}

# Run custom install scripts
run_custom_installs() {
    if [[ ${#CUSTOM_NAMES[@]} -eq 0 ]]; then
        return 0
    fi

    for i in "${!CUSTOM_NAMES[@]}"; do
        local name="${CUSTOM_NAMES[$i]}"
        local check="${CUSTOM_CHECKS[$i]}"
        local script="${CUSTOM_SCRIPTS[$i]}"

        # Check if already installed
        if [[ -n "$check" ]] && eval "$check" &>/dev/null; then
            log_debug "Custom install already satisfied: $name"
            continue
        fi

        log_info "Running custom install: $name"

        if is_dry_run; then
            log_info "[DRY-RUN] Would run: $APP_DIR/$script"
            continue
        fi

        if [[ ! -x "$APP_DIR/$script" ]]; then
            log_error "Custom install script not found or not executable: $script"
            return 1
        fi

        bash "$APP_DIR/$script" || {
            log_error "Custom install failed: $name"
            return 1
        }

        log_success "Custom install complete: $name"
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
    log_info "Installing $APP_NAME (custom tools + drop-ins)..."

    # Check if already installed
    if state_is_installed "$APP_NAME"; then
        log_error "$APP_NAME is already installed"
        log_info "Use 'upgrade' to update, or 'uninstall' first"
        return 1
    fi

    # Initialize backup
    if [[ "$NO_BACKUP" != true ]]; then
        backup_init "$APP_NAME" "$BACKUP_DIR" || return 1
    fi

    # Backup original files (drop-ins)
    if [[ "$NO_BACKUP" != true ]]; then
        log_info "Creating original backups..."
        for dest in "${CONFIG_DESTS[@]}"; do
            if [[ -f "$dest" ]]; then
                backup_create_original "$dest" "$BACKUP_DIR" || return 1
            fi
        done
    fi

    # Run custom installs
    run_custom_installs || return 1

    # Install drop-in files
    if [[ ${#CONFIG_FILES[@]} -gt 0 ]]; then
        log_info "Installing drop-in files..."
        for i in "${!CONFIG_FILES[@]}"; do
            local src="$APP_DIR/${CONFIG_FILES[$i]}"
            local dest="${CONFIG_DESTS[$i]}"
            local mode="${CONFIG_MODES[$i]:-0644}"

            if [[ ! -f "$src" ]]; then
                log_error "Source file not found: $src"
                return 1
            fi

            if is_dry_run; then
                log_info "[DRY-RUN] Would install: $src -> $dest (mode: $mode)"
            else
                log_info "Installing: $(basename "$dest")"
                copy_file "$src" "$dest" || return 1
                set_permissions "$dest" "$mode" || return 1
            fi
        done
    fi

    # Create state file
    if ! is_dry_run; then
        state_init || return 1
        local all_files=("${CONFIG_DESTS[@]}")
        state_create "$APP_NAME" "$APP_VERSION" "$BACKUP_DIR" "${all_files[@]}" || return 1
    fi

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

    # Create snapshot backup
    if [[ "$NO_BACKUP" != true ]]; then
        log_info "Creating backup snapshot..."
        local ts
        for dest in "${CONFIG_DESTS[@]}"; do
            if [[ -f "$dest" ]]; then
                ts=$(backup_create_snapshot "$dest" "$BACKUP_DIR")
            fi
        done

        if [[ -n "${ts:-}" ]]; then
            state_add_snapshot "$APP_NAME" "$ts" || log_warn "Failed to update state"
        fi

        backup_prune "$BACKUP_DIR" "$MAX_BACKUPS"
    fi

    # Re-run custom installs unconditionally on upgrade
    for i in "${!CUSTOM_NAMES[@]}"; do
        local name="${CUSTOM_NAMES[$i]}"
        local script="${CUSTOM_SCRIPTS[$i]}"

        log_info "Re-running custom install: $name"

        if is_dry_run; then
            log_info "[DRY-RUN] Would run: $APP_DIR/$script"
            continue
        fi

        bash "$APP_DIR/$script" || {
            log_warn "Custom install script returned non-zero: $name"
        }
    done

    # Update drop-in files
    if [[ ${#CONFIG_FILES[@]} -gt 0 ]]; then
        log_info "Updating drop-in files..."
        for i in "${!CONFIG_FILES[@]}"; do
            local src="$APP_DIR/${CONFIG_FILES[$i]}"
            local dest="${CONFIG_DESTS[$i]}"
            local mode="${CONFIG_MODES[$i]:-0644}"

            if is_dry_run; then
                log_info "[DRY-RUN] Would update: $src -> $dest"
            else
                log_info "Updating: $(basename "$dest")"
                copy_file "$src" "$dest" || return 1
                set_permissions "$dest" "$mode" || return 1
            fi
        done
    fi

    # Update state file
    if ! is_dry_run; then
        sed -i "s/^  version: .*/  version: $APP_VERSION/" \
            "$(state_get_file "$APP_NAME")"
        state_update_files "$APP_NAME" "${CONFIG_DESTS[@]}"
    fi

    log_success "$APP_NAME upgraded successfully!"
    return 0
}

# Uninstall operation
cmd_uninstall() {
    log_info "Uninstalling $APP_NAME..."

    if ! state_is_installed "$APP_NAME"; then
        log_error "$APP_NAME is not installed"
        return 1
    fi

    log_warn "Custom tools (lazygit, etc.) are not uninstalled automatically"

    # Get backup directory from state
    local backup_dir
    backup_dir=$(state_get_backup_dir "$APP_NAME")

    # Get installed files from state (drop-ins only)
    local files
    mapfile -t files < <(state_get_files "$APP_NAME")

    log_info "Restoring ${#files[@]} original file(s)..."

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

    if ! is_dry_run; then
        state_remove "$APP_NAME"
    fi

    log_success "$APP_NAME uninstalled successfully!"
    log_info "Backups preserved at: $backup_dir"
    return 0
}

# Rollback operation
cmd_rollback() {
    local target_ts="${1:-}"

    log_info "Rolling back $APP_NAME..."

    if ! state_is_installed "$APP_NAME"; then
        log_error "$APP_NAME is not installed"
        return 1
    fi

    local backup_dir
    backup_dir=$(state_get_backup_dir "$APP_NAME")

    if [[ -z "$target_ts" ]]; then
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

    if ! backup_verify "$backup_dir" "$target_ts"; then
        log_error "Backup verification failed"
        return 1
    fi

    local files
    mapfile -t files < <(state_get_files "$APP_NAME")

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

    # Show custom install status
    if [[ ${#CUSTOM_NAMES[@]} -gt 0 ]]; then
        echo
        echo "Custom installs:"
        for i in "${!CUSTOM_NAMES[@]}"; do
            local name="${CUSTOM_NAMES[$i]}"
            local check="${CUSTOM_CHECKS[$i]}"
            if [[ -n "$check" ]] && eval "$check" &>/dev/null; then
                echo "  [installed] $name"
            else
                echo "  [missing]   $name"
            fi
        done
    fi

    echo
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

    # Check custom installs
    for i in "${!CUSTOM_NAMES[@]}"; do
        local name="${CUSTOM_NAMES[$i]}"
        local check="${CUSTOM_CHECKS[$i]}"
        if [[ -n "$check" ]] && eval "$check" &>/dev/null; then
            log_success "Custom install present: $name"
        else
            log_error "Custom install missing: $name"
            ((errors++))
        fi
    done

    # Check drop-in files
    local files
    mapfile -t files < <(state_get_files "$APP_NAME")

    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            log_success "Found: $file"
        else
            log_error "Missing file: $file"
            ((errors++))
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

    if [[ -d "$backup_dir/original" ]]; then
        echo "Original backup:"
        echo "  Location: $backup_dir/original"
        ls -lh "$backup_dir/original" 2>/dev/null | tail -n +2 | awk '{print "  " $9 " (" $5 ")"}'
        echo
    fi

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
        local src="$APP_DIR/${CONFIG_FILES[$i]}"
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

# Show usage
usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
  deploy               Install if new, upgrade if exists (idempotent)
  install              Install custom tools and drop-ins
  upgrade              Upgrade existing installation
  uninstall            Remove drop-in files (custom tools are kept)
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

Note: OS package installation is handled by setup.sh, not this installer.

Examples:
  $0 install
  $0 deploy --dry-run
  $0 status
  $0 install --remote user@hostname

EOF
}

# Validate and sanitize command
validate_command() {
    local cmd="$1"

    cmd=$(echo "$cmd" | tr -cd '[:alnum:]-')

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

    for valid_cmd in "${valid_commands[@]}"; do
        if [[ "$cmd" == "$valid_cmd" ]]; then
            echo "$cmd"
            return 0
        fi
    done

    echo "Error: Unknown command '$1'" >&2
    echo "" >&2
    echo "Valid commands:" >&2
    echo "  deploy     - Install if new, upgrade if exists" >&2
    echo "  install    - Install custom tools and drop-ins" >&2
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
                ROLLBACK_TARGET=$(echo "$2" | tr -cd '[:alnum:]_-')
                if [[ -z "$ROLLBACK_TARGET" ]]; then
                    echo "Error: Invalid snapshot name '$2'" >&2
                    exit 1
                fi
                shift 2
                ;;
            --shell-scripts-dir)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --shell-scripts-dir requires a path argument" >&2
                    exit 1
                fi
                SHELL_SCRIPTS_DIR=$(abs_path "$2")
                shift 2
                ;;
            --log)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --log requires a filename argument" >&2
                    exit 1
                fi
                shift
                [[ $# -gt 0 && "$1" != --* ]] && shift || true
                ;;
            --verbose|--quiet)
                shift
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
}

# Execute in remote mode
execute_remote() {
    log_info "Remote installation mode"

    remote_check_connection || exit 1

    local package_file
    package_file=$(remote_package_installer "$APP_DIR") || exit 1

    remote_deploy_installer "$package_file" || {
        rm -f "$package_file"
        exit 1
    }

    local remote_args=()
    local skip_next=false

    for arg in "$@"; do
        if [[ "$skip_next" == true ]]; then
            skip_next=false
            continue
        fi

        if [[ "$arg" == "--remote" ]]; then
            skip_next=true
            continue
        fi

        remote_args+=("$arg")
    done

    local app_name
    app_name=$(basename "$APP_DIR")

    remote_run_installer "$app_name" "${remote_args[@]}"
    local exit_code=$?

    rm -f "$package_file"
    remote_cleanup

    exit $exit_code
}

# Main
main() {
    parse_args "$@"

    log_init "$@"

    if [[ "$REMOTE_MODE" == true ]]; then
        execute_remote "$@"
    fi

    load_config || exit 1

    APP_VERSION=$(cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    state_init || exit 1

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

main "$@"
