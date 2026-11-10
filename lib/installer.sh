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
source "$ROOT_DIR/lib/records.sh"
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

# Per-run count of files that failed to deploy, and of files with a conflict held back
FILE_FAILURES=0
FILES_HELD=0

# The snapshot installer_snapshot took, for a state file written later
SNAPSHOT_TS=""

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

# Deploy one file; apps may override and call deploy_file_default for the rest
# Usage: deploy_file src dest mode strategy install|upgrade name
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
    local line src
    if [[ -n "$STAGE_DIR" ]]; then
        while IFS= read -r line; do
            src="${line% *}"
            if [[ "$src" == "$1" ]]; then
                echo "${line##* }"
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

# How the records treat edits to this dest: reset, force or, printing nothing, the pull table
# Usage: installer_force_mode dest
installer_force_mode() {
    if [[ "${DOTFILES_RESET:-}" == 1 ]]; then
        echo reset
    elif [[ -n "${DOTFILES_FORCE_PATH:-}" ]]; then
        if [[ "$DOTFILES_FORCE_PATH" == "$1" ]]; then echo force; fi
    elif [[ "$FORCE" == true ]]; then
        echo force
    fi
}

# Deploy one file through the records
# Usage: deploy_file_default src dest mode strategy install|upgrade name
deploy_file_default() {
    local src="$1" dest="$2" mode="$3" strategy="${4:-replace}" verb="${5:-install}" name="${6:-$(basename "$1")}"

    RECORDS_FORCE=$(installer_force_mode "$dest")
    if is_dry_run; then
        records_preview "$APP_NAME" "$name" "$src" "$dest" "$strategy" || return 1
        installer_report_preview "$src" "$dest" "$mode" "$strategy" "$verb"
        return 0
    fi
    records_deploy "$APP_NAME" "$name" "$src" "$dest" "$mode" "$strategy"
}

# Say what a dry run found. A held conflict and a kept edit stay in RECORDS_DEPLOY_RESULT, for
# installer_report_deploy to word as a real pull does and to carry to the summary.
# Usage: installer_report_preview src dest mode strategy install|upgrade
installer_report_preview() {
    local src="$1" dest="$2" mode="$3" strategy="$4" verb="$5"
    case "$RECORDS_DEPLOY_RESULT" in
        keep | conflict) return 0 ;;
        none) log_info "[DRY-RUN] No change: $dest" ;;
        same) log_info "[DRY-RUN] Would update the records of: $dest" ;;
        *)
            if [[ "$strategy" == merge ]]; then
                log_info "[DRY-RUN] Would merge: $src -> $dest (mode: $mode)"
            elif [[ "$verb" == upgrade ]]; then
                log_info "[DRY-RUN] Would update: $src -> $dest"
            else
                log_info "[DRY-RUN] Would install: $src -> $dest (mode: $mode)"
            fi
            ;;
    esac
    RECORDS_DEPLOY_RESULT=""
}

# Report what records_deploy did with one file
# Usage: installer_report_deploy dest strategy verb
installer_report_deploy() {
    local dest="$1" strategy="$2" verb="$3"
    case "$RECORDS_DEPLOY_RESULT" in
        fresh | apply)
            if [[ "$strategy" == merge ]]; then
                log_info "Merging: $(basename "$dest")"
            elif [[ "$verb" == upgrade ]]; then
                log_info "Updating: $(basename "$dest")"
            else
                log_info "Installing: $(basename "$dest")"
            fi
            ;;
        keep)
            log_info "Keeping local edit: $dest"
            ;;
        conflict)
            FILES_HELD=$((FILES_HELD + 1))
            if [[ "$strategy" == merge ]]; then
                log_warn "Keeping your values in $dest, the repo changed them too: $RECORDS_DEPLOY_CONFLICTS"
            else
                log_warn "Keeping your edit to $dest, the repo changed it too"
            fi
            if [[ -n "${DOTFILES_KEPT_FILE:-}" ]]; then
                echo "$dest" >> "$DOTFILES_KEPT_FILE"
            fi
            ;;
    esac
}

# Warn, and carry the message to the pull summary
# Usage: installer_report_warning MESSAGE
installer_report_warning() {
    log_warn "$1"
    if [[ -n "${DOTFILES_WARNINGS_FILE:-}" ]]; then
        echo "$1" >> "$DOTFILES_WARNINGS_FILE"
    fi
}

# Something the user should know that isn't a problem: logged, and listed under Notes in
# the pull's summary
# Usage: installer_report_notice MESSAGE
installer_report_notice() {
    log_info "$1"
    if [[ -n "${DOTFILES_NOTICES_FILE:-}" ]]; then
        echo "$1" >> "$DOTFILES_NOTICES_FILE"
    fi
}

# Save what a file is about to replace as its original, once. A file with a record came
# from dotfiles, not from the machine.
# Usage: installer_save_original dest
installer_save_original() {
    [[ -f "$1" ]] || return 0
    records_knows_dest "$1" && return 0
    backup_create_original "$1" "$BACKUP_DIR"
}

# Take one snapshot of the given files that exist, and note it in the state if there is one
# Usage: installer_snapshot dest...
installer_snapshot() {
    SNAPSHOT_TS=""
    [[ $# -gt 0 ]] || return 0
    if is_dry_run; then
        log_info "[DRY-RUN] Would create a backup snapshot"
        return 0
    fi
    local dest ts="" snap_ts
    log_info "Creating backup snapshot..."
    backup_init "$APP_NAME" "$BACKUP_DIR" || return 1
    snap_ts=$(timestamp)
    for dest in "$@"; do
        if [[ -f "$dest" ]]; then
            ts=$(backup_create_snapshot "$dest" "$BACKUP_DIR" "$snap_ts") || return 1
        fi
    done
    SNAPSHOT_TS="$ts"
    if [[ -n "$ts" ]] && state_is_installed "$APP_NAME"; then
        state_add_snapshot "$APP_NAME" "$ts" || log_warn "Failed to update state"
    fi
    backup_prune "$BACKUP_DIR" "$MAX_BACKUPS"
}

# True if config file number i starts over instead of comparing against its record
# Usage: installer_is_fresh i
installer_is_fresh() {
    records_is_fresh "$APP_NAME" "${CONFIG_FILES[$1]}" "${CONFIG_DESTS[$1]}" "$(installer_strategy "${CONFIG_FILES[$1]}")"
}

# The dests an upgrade snapshots: all of them, unless --no-backup, which --force and a reset
# override. With --no-backup, a file that starts over still gets one.
installer_snapshot_dests() {
    local i
    # init took the one snapshot of a reset before anything changed: a second would use up
    # another of the few slots. A reset run on its own still snapshots here.
    [[ "${DOTFILES_RESET:-}" != 1 || "${DOTFILES_RESET_SNAPSHOTTED:-}" != 1 ]] || return 0
    if [[ "$NO_BACKUP" != true || "$FORCE" == true || "${DOTFILES_RESET:-}" == 1 ]]; then
        printf '%s\n' ${CONFIG_DESTS[@]+"${CONFIG_DESTS[@]}"}
        return 0
    fi
    for i in "${!CONFIG_FILES[@]}"; do
        if installer_is_fresh "$i"; then
            printf '%s\n' "${CONFIG_DESTS[$i]}"
        fi
    done
}

# True if every config file has a record to compare against
installer_has_records() {
    local i
    for i in "${!CONFIG_FILES[@]}"; do
        if installer_is_fresh "$i"; then
            return 1
        fi
    done
}

# Warn about recorded files this app no longer deploys there, if they hold unreviewed
# edits. They stay in place, and records_prune forgets them.
installer_warn_removed() {
    local src dest strategy
    while IFS=$'\t' read -r src dest strategy; do
        list_contains "$dest" ${CONFIG_DESTS[@]+"${CONFIG_DESTS[@]}"} && continue
        [[ -e "$dest" ]] || continue
        if records_has_edits "$APP_NAME" "$src" "$dest"; then
            installer_report_warning "$dest is no longer managed by $APP_NAME and has unreviewed edits; it was left in place"
        fi
    done < <(records_list "$APP_NAME")
}

# Deploy config file number i. A failed file is counted and skipped; a missing source fails.
# Usage: installer_deploy_one i install|upgrade
installer_deploy_one() {
    local i="$1" verb="$2"
    local name="${CONFIG_FILES[$i]}"
    local dest="${CONFIG_DESTS[$i]}"
    local mode="${CONFIG_MODES[$i]:-0644}"
    local src strategy
    src=$(installer_src "$name")

    if installer_is_skipped "$name"; then
        log_error "Skipping $name: its repo layers could not be merged"
        record_file_failure "$name"
        return 0
    fi
    if [[ ! -f "$src" ]]; then
        log_error "Source file not found: $src"
        return 1
    fi
    strategy=$(installer_strategy "$name")
    RECORDS_DEPLOY_RESULT=""
    if deploy_file "$src" "$dest" "$mode" "$strategy" "$verb" "$name"; then
        installer_report_deploy "$dest" "$strategy" "$verb"
    else
        log_error "Failed to deploy $name; the next pull tries it again"
        record_file_failure "$name"
    fi
}

# Deploy every config file. A failed file is counted and skipped; the
# others continue. A missing source aborts.
# Usage: deploy_all_files install|upgrade
deploy_all_files() {
    local verb="$1" i
    FILE_FAILURES=0
    FILES_HELD=0
    is_dry_run || installer_warn_removed
    for i in "${!CONFIG_FILES[@]}"; do
        installer_deploy_one "$i" "$verb" || return 1
    done
    if ! is_dry_run; then
        records_prune "$APP_NAME" ${CONFIG_DESTS[@]+"${CONFIG_DESTS[@]}"}
        records_prune_srcs "$APP_NAME" ${CONFIG_FILES[@]+"${CONFIG_FILES[@]}"}
    fi
}

# Version recorded in state: incomplete when any file failed, conflict:VERSION when any file
# or key was held back. Neither matches a real version, so the next pull looks again; the
# version after "conflict:" lets status tell a further repo update from the held one.
installed_version() {
    if [[ $FILE_FAILURES -gt 0 ]]; then
        echo incomplete
    elif [[ $FILES_HELD -gt 0 ]]; then
        echo "conflict:$APP_VERSION"
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
    if [[ -n "${DOTFILES_FORCE_PATH:-}" ]]; then
        if ! list_contains "$DOTFILES_FORCE_PATH" ${CONFIG_DESTS[@]+"${CONFIG_DESTS[@]}"}; then
            log_debug "$APP_NAME doesn't manage $DOTFILES_FORCE_PATH"
            return 0
        fi
        if state_is_installed "$APP_NAME"; then
            cmd_force_path
            return
        fi
    fi
    if state_is_installed "$APP_NAME"; then
        log_info "$APP_NAME already installed, upgrading..."
        cmd_upgrade
    else
        cmd_install
    fi
}

# After pull --force PATH: a state that says conflicts are held, for this very repo version,
# says so no more once none are left, or status would go on reporting the one just taken.
# Left alone when the repo has moved on since, or when a file can't be compared.
installer_settle_conflict_state() {
    local i src dest items
    [[ "$(state_get_version "$APP_NAME" 2>/dev/null)" == "conflict:$APP_VERSION" ]] || return 0
    for i in "${!CONFIG_FILES[@]}"; do
        src="${CONFIG_FILES[$i]}"
        dest="${CONFIG_DESTS[$i]}"
        installer_is_skipped "$src" && return 0
        items=$(records_items "$APP_NAME" "$src" "$dest" "$(installer_src "$src")" false 2>/dev/null) || return 0
        [[ $'\n'"$items" != *$'\n'conflict$'\t'* ]] || return 0
    done
    state_set_version "$APP_NAME" "$APP_VERSION"
}

# pull --force PATH: take the repo's version of that one file, leaving the others for the
# next pull. The state stays as it was, because the others weren't looked at, except that
# a held conflict that was the last one is let go.
cmd_force_path() {
    local dest="$DOTFILES_FORCE_PATH" i
    local -a managed=()
    log_info "Taking the repo's version of $dest..."
    if ! is_dry_run; then
        backup_init "$APP_NAME" "$BACKUP_DIR" || return 1
        mapfile -t managed < <(state_get_files "$APP_NAME")
        if ! list_contains "$dest" ${managed[@]+"${managed[@]}"}; then
            installer_save_original "$dest" || return 1
        fi
    fi
    installer_snapshot "$dest" || return 1
    FILE_FAILURES=0
    for i in "${!CONFIG_FILES[@]}"; do
        if [[ "${CONFIG_DESTS[$i]}" == "$dest" ]]; then
            installer_deploy_one "$i" upgrade || return 1
        fi
    done
    [[ $FILE_FAILURES -eq 0 ]] || return 1
    is_dry_run || installer_settle_conflict_state
    return 0
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

    # The originals and a snapshot, even with --no-backup: nothing else holds what's about
    # to be replaced.
    backup_init "$APP_NAME" "$BACKUP_DIR" || return 1
    log_info "Creating original backups..."
    for dest in "${CONFIG_DESTS[@]}"; do
        installer_save_original "$dest" || return 1
    done
    installer_snapshot "${CONFIG_DESTS[@]}" || return 1
    local install_snapshot="$SNAPSHOT_TS"

    app_pre_deploy install || return 1

    log_info "Installing configuration files..."
    deploy_all_files install || return 1
    app_post_deploy install || return 1

    # Create state file
    if ! is_dry_run; then
        state_init || return 1
        state_create "$APP_NAME" "$(installed_version)" "$BACKUP_DIR" "${CONFIG_DESTS[@]}" || return 1
        if [[ -n "$install_snapshot" ]]; then
            state_add_snapshot "$APP_NAME" "$install_snapshot" || log_warn "Failed to update state"
        fi
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

    # Skip if already at this version, with records to show for it
    if [[ "$UPGRADE_ALWAYS" != true ]]; then
        local installed_version
        installed_version=$(state_get_version "$APP_NAME")
        if [[ "$installed_version" == "$APP_VERSION" && "$FORCE" != true && "${DOTFILES_RESET:-}" != 1 ]] && installer_has_records; then
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

    # Files new to this app since install: what they replace is an original, kept even with
    # --no-backup. Files already in state are skipped: their live copy came from dotfiles.
    backup_init "$APP_NAME" "$BACKUP_DIR" || return 1
    local -a managed=()
    mapfile -t managed < <(state_get_files "$APP_NAME")
    for dest in "${CONFIG_DESTS[@]}"; do
        if ! list_contains "$dest" ${managed[@]+"${managed[@]}"}; then
            installer_save_original "$dest" || return 1
        fi
    done

    local -a snapshot_dests=()
    mapfile -t snapshot_dests < <(installer_snapshot_dests)
    installer_snapshot ${snapshot_dests[@]+"${snapshot_dests[@]}"} || return 1

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

# Name the files uninstall would restore or remove that differ from the repo's version, the
# unreviewed and the dismissed alike. Without records there is nothing to compare with, so
# every file is a candidate.
installer_warn_uninstall_changes() {
    local src dest strategy items tracked=false
    local -a changed=()
    while IFS=$'\t' read -r src dest strategy; do
        tracked=true
        [[ -e "$dest" ]] || continue
        # A file that can't be compared counts as changed
        items=$(records_items "$APP_NAME" "$src" "$dest" "" true 2>/dev/null) || items=changed
        [[ -z "$items" ]] || changed+=("$dest")
    done < <(records_list "$APP_NAME")
    if [[ "$tracked" != true ]]; then
        log_warn "No records of what dotfiles deployed for $APP_NAME, so local changes can't be told apart; a snapshot of every managed file is taken first"
    elif [[ ${#changed[@]} -gt 0 ]]; then
        log_warn "Local changes in these files will be replaced or removed; a snapshot of them is taken first:"
        for dest in "${changed[@]}"; do
            log_warn "  $dest"
        done
    fi
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

    # Local changes would be lost: say which, and keep a copy of every managed file first,
    # whatever --no-backup says. Nothing is restored if that fails.
    installer_warn_uninstall_changes
    if ! installer_snapshot ${files[@]+"${files[@]}"}; then
        log_error "Could not take a snapshot of the managed files, so nothing was restored or removed"
        return 1
    fi

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
        records_remove "$APP_NAME"
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
  --force              Take the repo's version of every file, keeping local-only keys
                       in merged files; always takes a snapshot first
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

# An old host's background sync runs git pull, then this code. With no records to compare
# against, every file would count as fresh and an edit nobody reviewed would be overwritten.
# init's move clears the old records first. Uninstall doesn't deploy, and still works.
installer_refuse_old_records() {
    compgen -G "$STATE_DIR/deployed/*.tsv" >/dev/null || return 0
    log_error "This host still has records from an older version, in $STATE_DIR/deployed; nothing was deployed"
    echo "Run 'dotfiles init' to start fresh records (or 'dotfiles init --remote' from another machine)." >&2
    exit 1
}

# Main
installer_main() {
    # Parse arguments
    parse_args "$@"

    # Initialize logging
    log_init "$@"

    if list_contains "$COMMAND" deploy install upgrade; then
        installer_refuse_old_records
    fi

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
