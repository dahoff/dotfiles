#!/usr/bin/env bash
# installer.sh - Shared app installer core
#
# An app's configure.sh sets APP_DIR, sources this file, redefines any app_*
# hooks (or core functions) it needs, then calls: installer_main "$@"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/yaml.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backup.sh"
source "$ROOT_DIR/lib/state.sh"
source "$ROOT_DIR/lib/deployed.sh"
source "$ROOT_DIR/lib/overlay.sh"

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

# Staging directory (--stage, or built by prepare_stage)
STAGE_DIR=""
STAGING_ENABLED=true   # false for apps without config.yaml (packages)

# Per-run count of files that failed to deploy
FILE_FAILURES=0

# Flags
DRY_RUN=false
NO_BACKUP=false
TEST_MODE=false
FORCE=false

# Cross-module: shell scripts drop-in directory
SHELL_SCRIPTS_DIR="$HOME/.bashrc.d"

# App switches (apps override after sourcing)
UPGRADE_ALWAYS=false               # true: upgrade never skips on matching version

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

# True if a live file with no record is the repo's version in all but form
# Usage: app_matches_repo name src dest
app_matches_repo() { return 1; }

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
installer_src() {
    if [[ -n "$STAGE_DIR" ]]; then
        echo "$STAGE_DIR/files/$1"
    else
        echo "$FILES_DIR/$1"
    fi
}

# Strategy for a config src (replace unless the stage says otherwise)
installer_strategy() {
    local src strategy
    if [[ -n "$STAGE_DIR" ]]; then
        while read -r src strategy; do
            if [[ "$src" == "$1" ]]; then
                echo "$strategy"
                return 0
            fi
        done < "$STAGE_DIR/strategies"
    fi
    echo replace
}

# True if staging could not compose this src
installer_is_skipped() {
    [[ -n "$STAGE_DIR" ]] && grep -qxF "$1" "$STAGE_DIR/skip"
}

# Count a failed file and report it to dotfiles
record_file_failure() {
    FILE_FAILURES=$((FILE_FAILURES + 1))
    if [[ -n "${DOTFILES_FAILURES_FILE:-}" ]]; then
        echo "$(basename "$APP_DIR")/$1" >> "$DOTFILES_FAILURES_FILE"
    fi
}

# Copy (replace) or merge (JSON) one file into place
# Usage: deploy_file_default src dest mode strategy install|upgrade
deploy_file_default() {
    local src="$1" dest="$2" mode="$3" strategy="${4:-replace}" verb="${5:-install}"

    if [[ "$strategy" == merge ]]; then
        if is_dry_run; then
            log_info "[DRY-RUN] Would merge: $src -> $dest (mode: $mode)"
            return 0
        fi
        log_info "Merging: $(basename "$dest")"
        ensure_dir "$(dirname "$dest")" || return 1
        if [[ -s "$dest" ]]; then
            overlay_json_merge "$dest" "$dest" "$src" || return 1
        else
            copy_file "$src" "$dest" || return 1
        fi
        set_permissions "$dest" "$mode"
        return
    fi

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

# True if the live file holds an edit an upgrade must not overwrite. Only a file
# dotfiles already deployed counts: anything else is an original, and is backed up
# and replaced. --force overwrites (the upgrade snapshot still has the edit).
# Usage: installer_keep_edit name src dest strategy verb
installer_keep_edit() {
    local name="$1" src="$2" dest="$3" strategy="$4" verb="$5"
    [[ "$verb" == upgrade && "$FORCE" != true && "$strategy" != merge && -f "$dest" ]] || return 1
    grep -qxF -- "$dest" < <(state_get_files "$APP_NAME") || return 1

    local live new recorded
    live=$(deployed_hash "$dest")
    new=$(deployed_hash "$src")
    [[ "$live" != "$new" ]] || return 1
    recorded=$(deployed_get "$APP_NAME" "$dest")
    [[ "$live" != "$recorded" && "$recorded" != merge ]] || return 1
    if [[ -z "$recorded" ]] && app_matches_repo "$name" "$src" "$dest"; then
        return 1
    fi

    if [[ "$recorded" == "$new" ]]; then
        log_info "Keeping local edit: $dest"
        return 0
    fi
    # The repo changed too, or nothing says what was deployed: the safe mistake is
    # leaving the file behind the repo, not losing an edit
    log_warn "Keeping local edit: $dest (the repo version changed too; 'dotfiles add' saves yours, 'dotfiles pull --force' takes the repo's)"
    if ! is_dry_run; then
        [[ -n "$recorded" ]] || deployed_set "$APP_NAME" "$name" "$dest" unknown
        if [[ -n "${DOTFILES_KEPT_FILE:-}" ]]; then
            echo "$dest" >> "$DOTFILES_KEPT_FILE"
        fi
    fi
    return 0
}

# Warn, and carry the message to the sync summary and the --auto report
# Usage: installer_report_warning MESSAGE
installer_report_warning() {
    log_warn "$1"
    if [[ -n "${DOTFILES_WARNINGS_FILE:-}" ]]; then
        echo "$1" >> "$DOTFILES_WARNINGS_FILE"
    fi
}

# Record what an upgrade just wrote
# Usage: installer_record_deploy name dest strategy
installer_record_deploy() {
    is_dry_run && return 0
    if [[ "$3" == merge ]]; then
        deployed_set "$APP_NAME" "$1" "$2" merge
    else
        deployed_set "$APP_NAME" "$1" "$2" "$(deployed_hash "$2")"
    fi
}

# A machine installed before records existed: when the state says this version is
# deployed, the stage is exactly what was written, so record that.
installer_baseline() {
    is_dry_run && return 0
    [[ "$(state_get_version "$APP_NAME")" == "$APP_VERSION" ]] || return 0
    local i name dest src strategy
    for i in "${!CONFIG_FILES[@]}"; do
        name="${CONFIG_FILES[$i]}"
        dest="${CONFIG_DESTS[$i]}"
        src=$(installer_src "$name")
        [[ -f "$src" && -z "$(deployed_get "$APP_NAME" "$dest")" ]] || continue
        strategy=$(installer_strategy "$name")
        if [[ "$strategy" == merge ]]; then
            deployed_set "$APP_NAME" "$name" "$dest" merge
        else
            deployed_set "$APP_NAME" "$name" "$dest" "$(deployed_hash "$src")"
        fi
    done
}

# Deploy every config file. A failed file is counted and skipped; the
# others continue. A missing source aborts.
# Usage: deploy_all_files install|upgrade
deploy_all_files() {
    local verb="$1" i
    FILE_FAILURES=0
    for i in "${!CONFIG_FILES[@]}"; do
        local name="${CONFIG_FILES[$i]}"
        local dest="${CONFIG_DESTS[$i]}"
        local mode="${CONFIG_MODES[$i]:-0644}"
        local src
        src=$(installer_src "$name")

        if installer_is_skipped "$name"; then
            log_error "Skipping $name: its repo layers could not be merged"
            record_file_failure "$name"
            continue
        fi
        if [[ ! -f "$src" ]]; then
            log_error "Source file not found: $src"
            return 1
        fi
        local strategy
        strategy=$(installer_strategy "$name")
        if installer_keep_edit "$name" "$src" "$dest" "$strategy" "$verb"; then
            continue
        fi
        if deploy_file "$src" "$dest" "$mode" "$strategy" "$verb"; then
            installer_record_deploy "$name" "$dest" "$strategy"
        else
            log_error "Failed to deploy $name; left $dest as it was"
            record_file_failure "$name"
        fi
    done
    is_dry_run || deployed_prune "$APP_NAME" "${CONFIG_DESTS[@]}"
}

# Version recorded in state: incomplete when any file failed
installed_version() {
    if [[ $FILE_FAILURES -gt 0 ]]; then
        echo incomplete
    else
        echo "$APP_VERSION"
    fi
}

# Version of what would be deployed
installer_version() {
    if [[ -n "$STAGE_DIR" ]]; then
        cat "$STAGE_DIR/version"
    else
        (cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    fi
}

# Commands that deploy files need a stage
command_needs_stage() {
    list_contains "$COMMAND" deploy install upgrade diff
}

# Stage this app's own files (dotfiles layer only) when no --stage was given
prepare_stage() {
    [[ "$STAGING_ENABLED" == true && -z "$STAGE_DIR" ]] || return 0
    local tmp
    tmp=$(mktemp -d) || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    STAGE_DIR="$tmp/stage"
    overlay_stage_app "$APP_DIR" "$STAGE_DIR" /dev/null
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
        state_create "$APP_NAME" "$(installed_version)" "$BACKUP_DIR" "${CONFIG_DESTS[@]}" || return 1
    fi

    app_post_files install || return 1

    # Run post-install commands
    run_post_install

    app_post_install install

    if [[ $FILE_FAILURES -gt 0 ]]; then
        log_error "$APP_NAME installed with $FILE_FAILURES failed file(s)"
        return 1
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

    installer_baseline

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

    # Files new to this app since install: what they replace is an original.
    # Files already in state are skipped: their live copy came from dotfiles.
    if [[ "$NO_BACKUP" != true ]]; then
        backup_init "$APP_NAME" "$BACKUP_DIR" || return 1
        local -a managed=()
        mapfile -t managed < <(state_get_files "$APP_NAME")
        for dest in "${CONFIG_DESTS[@]}"; do
            if [[ -f "$dest" ]] && ! list_contains "$dest" ${managed[@]+"${managed[@]}"}; then
                backup_create_original "$dest" "$BACKUP_DIR" || return 1
            fi
        done
    fi

    # Create snapshot backup
    if [[ "$NO_BACKUP" != true ]] && is_dry_run; then
        log_info "[DRY-RUN] Would create a backup snapshot"
    elif [[ "$NO_BACKUP" != true ]]; then
        log_info "Creating backup snapshot..."
        local ts="" snap_ts
        snap_ts=$(timestamp)
        for dest in "${CONFIG_DESTS[@]}"; do
            if [[ -f "$dest" ]]; then
                ts=$(backup_create_snapshot "$dest" "$BACKUP_DIR" "$snap_ts")
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
        state_set_version "$APP_NAME" "$(installed_version)"
        state_update_files "$APP_NAME" "${CONFIG_DESTS[@]}"
    fi

    app_post_files upgrade || return 1

    # Run post-install commands
    run_post_install

    app_post_install upgrade

    if [[ $FILE_FAILURES -gt 0 ]]; then
        log_error "$APP_NAME upgraded with $FILE_FAILURES failed file(s)"
        return 1
    fi
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
        deployed_remove "$APP_NAME"
    fi

    log_success "$APP_NAME uninstalled successfully!"
    log_info "Backups preserved at: $backup_dir"
    log_info "Shell scripts directory left intact: $SHELL_SCRIPTS_DIR"
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

    if [[ $errors -eq 0 ]]; then
        log_success "Verification passed!"
        return 0
    else
        log_error "Verification failed with $errors error(s)"
        return 1
    fi
}

# Diff operation
cmd_diff() {
    log_info "Showing differences for $APP_NAME..."
    echo

    local has_diff=false

    for i in "${!CONFIG_FILES[@]}"; do
        local name="${CONFIG_FILES[$i]}"
        local src dest="${CONFIG_DESTS[$i]}"
        src=$(installer_src "$name")

        if [[ ! -f "$dest" ]]; then
            echo "File not installed: $dest"
            has_diff=true
            continue
        fi

        local want="$src" tmp=""
        if [[ "$(installer_strategy "$name")" == merge && -s "$dest" ]]; then
            tmp=$(mktemp)
            if overlay_json_merge "$tmp" "$dest" "$src"; then
                want="$tmp"
            fi
        fi

        echo "=== $(basename "$dest") ==="
        if diff -u "$dest" "$want" 2>/dev/null; then
            echo "No differences"
        else
            has_diff=true
        fi
        [[ -n "$tmp" ]] && rm -f "$tmp"
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
                eval "$cmd" &>/dev/null 9>&- || log_warn "Post-install command failed: $cmd"
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
  status               Show installation status
  verify               Verify installation integrity
  diff                 Show differences between installed and new
  help                 Show this help message

Options:
  --dry-run            Show what would be done without making changes
  --test-mode          Run in test mode (sandbox)
  --no-backup          Skip creating backups
  --log FILE           Log to file
  --verbose            Verbose output
  --quiet              Minimal output
  --force              Force operation without prompts
  --stage DIR          Deploy files composed by dotfiles (internal)
  --shell-scripts-dir PATH   Set drop-in directory (default: ~/.bashrc.d)

Examples:
  $0 install
  $0 upgrade --no-backup

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
        "status"
        "verify"
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
    echo "  status     - Show installation status" >&2
    echo "  verify     - Verify installation integrity" >&2
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
            --stage)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --stage requires a directory argument" >&2
                    exit 1
                fi
                if [[ ! -f "$2/version" ]]; then
                    echo "Error: Not a staging directory: $2" >&2
                    exit 1
                fi
                STAGE_DIR=$(abs_path "$2")
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

# Main
installer_main() {
    # Parse arguments
    parse_args "$@"

    # Initialize logging
    log_init "$@"

    # Compose files to deploy
    if command_needs_stage; then
        prepare_stage || exit 1
    fi

    # Load configuration
    load_config || exit 1
    app_after_load_config || exit 1

    APP_VERSION=$(installer_version)

    # Initialize state
    is_dry_run || state_init || exit 1

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
        status)
            cmd_status
            ;;
        verify)
            cmd_verify
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
