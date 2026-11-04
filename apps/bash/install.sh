#!/usr/bin/env bash
# apps/bash/install.sh - Bash configuration installer
# Usage: ./install.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"

# Bash-specific flags
APPEND_MODE=false
SUPPLEMENT_FILES=()

app_parse_arg() {
    case $1 in
        --append)
            APPEND_MODE=true
            APP_ARG_SHIFT=1
            ;;
        --supplement)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "Error: --supplement requires a file argument" >&2
                exit 1
            fi
            local supplement_path
            supplement_path=$(abs_path "$2")
            if [[ ! -f "$supplement_path" ]]; then
                echo "Error: Supplement file not found: $2" >&2
                exit 1
            fi
            SUPPLEMENT_FILES+=("$supplement_path")
            APP_ARG_SHIFT=2
            ;;
        *)
            return 1
            ;;
    esac
}

app_usage() {
    cat << EOT
Bash-specific options:
  --append                   Append to existing .bashrc instead of replacing
  --supplement FILE          Install additional file to drop-in directory
                             (repeatable, e.g. --supplement secrets.sh)

Bash examples:
  $0 install --append
  $0 install --supplement ~/secrets.sh
  $0 install --supplement ~/10-path.sh --supplement ~/90-secrets.sh
  $0 install --shell-scripts-dir ~/.config/bash.d

EOT
}

# Ensure shell scripts directory exists
app_after_load_config() {
    if ! is_dry_run; then
        ensure_dir "$SHELL_SCRIPTS_DIR" || return 1
    fi
}

# Install .bashrc with append mode support
install_bashrc_file() {
    local src="$1"
    local dest="$2"
    local mode="$3"

    if [[ "$APPEND_MODE" == true ]] && [[ -f "$dest" ]]; then
        if is_dry_run; then
            log_info "[DRY-RUN] Would append: $src -> $dest (mode: $mode)"
            return 0
        fi
        log_info "Appending to existing: $(basename "$dest")"
        {
            echo ""
            echo "# --- BEGIN managed bashrc (appended by dotfiles installer) ---"
            cat "$src"
            echo "# --- END managed bashrc ---"
        } >> "$dest"
        set_permissions "$dest" "$mode" || return 1
    else
        if is_dry_run; then
            log_info "[DRY-RUN] Would install: $src -> $dest (mode: $mode)"
            return 0
        fi
        log_info "Installing: $(basename "$dest")"
        copy_file "$src" "$dest" || return 1
        set_permissions "$dest" "$mode" || return 1
    fi
    return 0
}

# Install supplement files to shell scripts directory
install_supplements() {
    if [[ -z "${SUPPLEMENT_FILES[*]+x}" ]]; then
        return 0
    fi

    local count=${#SUPPLEMENT_FILES[@]}
    if [[ $count -eq 0 ]]; then
        return 0
    fi

    log_info "Installing $count supplement file(s)..."

    local supplement
    for supplement in "${SUPPLEMENT_FILES[@]}"; do
        local basename_f
        basename_f=$(basename "$supplement")

        # Warn if file lacks .sh extension
        if [[ "$basename_f" != *.sh ]]; then
            log_warn "Supplement '$basename_f' lacks .sh extension; it will not be sourced by .bashrc"
        fi

        local dest="$SHELL_SCRIPTS_DIR/$basename_f"

        if is_dry_run; then
            log_info "[DRY-RUN] Would install supplement: $supplement -> $dest"
        else
            log_info "Installing supplement: $basename_f -> $SHELL_SCRIPTS_DIR/"
            copy_file "$supplement" "$dest" || return 1
            set_permissions "$dest" "0644" || return 1
        fi
    done

    return 0
}


# Route .bashrc through the append-aware installer
deploy_file() {
    if [[ "$(basename "$1")" == ".bashrc" ]]; then
        install_bashrc_file "$1" "$2" "$3"
    else
        deploy_file_default "$@"
    fi
}

# Supplements install before state is written, so a failure leaves no state behind
app_post_deploy() {
    install_supplements
}

installer_main "$@"
