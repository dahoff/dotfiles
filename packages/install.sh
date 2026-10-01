#!/usr/bin/env bash
# packages/install.sh - Custom tool installer and drop-in manager
# OS package installation is handled by setup.sh.
# This installer manages custom tool scripts and their shell drop-ins.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$APP_DIR")/lib/installer.sh"

APP_NAME="packages"
FILES_DIR="$APP_DIR"   # drop-in paths are relative to packages/
UPGRADE_ALWAYS=true    # custom installs are re-run on every upgrade

# Custom installs (loaded from active profile)
declare -a CUSTOM_NAMES=()
declare -a CUSTOM_CHECKS=()
declare -a CUSTOM_SCRIPTS=()
declare -a CUSTOM_DROPINS=()

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

# No config.yaml: no requirements and no post_install commands
check_requirements() { return 0; }
run_post_install() { return 0; }

app_pre_deploy() {
    if [[ "$1" == install ]]; then
        run_custom_installs
        return
    fi

    # Re-run custom installs unconditionally on upgrade
    local i
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
}

app_post_uninstall() {
    log_warn "Custom tools (lazygit, etc.) are not uninstalled automatically"
}

app_usage() {
    cat << EOT
Note: OS package installation is handled by setup.sh, not this installer.

EOT
}

installer_main "$@"
