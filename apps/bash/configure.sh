#!/usr/bin/env bash
# apps/bash/configure.sh - Bash configuration installer
# Usage: ./configure.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"

# Bash-specific flags
SUPPLEMENT_FILES=()
BASHRC_REPLACED=""
BASHRC_COPY=""

app_parse_arg() {
    case $1 in
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
  --supplement FILE          Install additional file to drop-in directory
                             (repeatable, e.g. --supplement secrets.sh)

Bash examples:
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


# Note a custom .bashrc before the first install replaces it. A distro's stock file
# and an empty one aren't worth a warning.
app_pre_deploy() {
    BASHRC_REPLACED=""
    BASHRC_COPY=""
    [[ "${1:-}" == install ]] || return 0
    local dest name skel="${DOTFILES_SKEL_BASHRC:-/etc/skel/.bashrc}"
    for dest in "${CONFIG_DESTS[@]}"; do
        [[ "$(basename "$dest")" == ".bashrc" && -f "$dest" ]] || continue
        [[ -n "$(tr -d '[:space:]' < "$dest")" ]] || continue
        ! { [[ -f "$skel" ]] && cmp -s "$dest" "$skel"; } || continue
        BASHRC_REPLACED="$dest"
        name=$(basename "$dest")
        if cmp -s "$dest" "$BACKUP_DIR/original/$name"; then
            BASHRC_COPY="$BACKUP_DIR/original/$name"
        elif [[ -n "${SNAPSHOT_TS:-}" ]] && cmp -s "$dest" "$BACKUP_DIR/$SNAPSHOT_TS/$name"; then
            BASHRC_COPY="$BACKUP_DIR/$SNAPSHOT_TS/$name"
        fi
    done
}

# Supplements install before state is written, so a failure leaves no state behind
app_post_deploy() {
    install_supplements || return 1
    if [[ -n "$BASHRC_REPLACED" ]] && ! is_dry_run; then
        local msg="$BASHRC_REPLACED was replaced; the old content is no longer loaded."
        [[ -z "$BASHRC_COPY" ]] || msg="$msg The old file is at $BASHRC_COPY"
        installer_report_warning "$msg"
    fi
}

installer_main "$@"
