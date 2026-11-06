#!/usr/bin/env bash
# apps/bash/configure.sh - Bash configuration installer
# Usage: ./configure.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"

# Bash-specific flags
SUPPLEMENT_FILES=()

BASHRC_HEADER="# ~/.bashrc - Managed by dotfiles installer"
# What older versions wrapped around each copy they appended to ~/.bashrc
BASHRC_BEGIN="# --- BEGIN managed bashrc (appended by dotfiles installer) ---"
BASHRC_END="# --- END managed bashrc ---"

app_parse_arg() {
    case $1 in
        --append)
            # Removed. Still accepted: during the sync that pulls this change, the
            # dotfiles script already in memory may pass it from the old config.yaml.
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

# True if the live file still has blocks appended by an older version
# Usage: bashrc_has_blocks FILE
bashrc_has_blocks() {
    [[ -f "$1" ]] && grep -qxF -- "$BASHRC_BEGIN" "$1"
}

# An appended .bashrc is the repo's file in all but form: replacing it isn't
# overwriting an edit, because bashrc_preserve keeps what isn't ours
app_matches_repo() {
    [[ "$1" == ".bashrc" ]] && bashrc_has_blocks "$3"
}

# Keep what isn't ours before an existing .bashrc is replaced.
#  - Your own content moves to the drop-in 00-local.sh. It keeps working, but now loads
#    after the managed file instead of before it, so its settings win.
#  - A distro's stock file isn't moved: loading it last would override the managed
#    prompt and aliases. The original backup still has it.
#  - A managed copy is dropped. If it differs from the repo it may hold hand edits, which
#    can't be told apart from an older version, so the whole file is saved first.
# Usage: bashrc_preserve SRC DEST
bashrc_preserve() {
    local src="$1" dest="$2" repo tmp part head="" outside="" kept="" differs=false
    local skel="${DOTFILES_SKEL_BASHRC:-/etc/skel/.bashrc}"
    repo=$(cat "$src")
    tmp=$(mktemp -d) || return 1
    BASHRC_BEGIN="$BASHRC_BEGIN" BASHRC_END="$BASHRC_END" awk -v dir="$tmp" '
        $0 == ENVIRON["BASHRC_BEGIN"] { inside = 1; seen = 1; n++; file = dir "/block." n; printf "" > file; next }
        inside && $0 == ENVIRON["BASHRC_END"] { inside = 0; close(file); next }
        inside { print > file; next }
        seen { print > (dir "/outside"); next }
        { print > (dir "/head") }
    ' "$dest" || { rm -rf "$tmp"; return 1; }

    [[ ! -f "$tmp/head" ]] || head=$(cat "$tmp/head")
    [[ ! -f "$tmp/outside" ]] || outside=$(cat "$tmp/outside")
    if [[ "${head%%$'\n'*}" == "$BASHRC_HEADER" ]]; then
        [[ "$head" == "$repo" ]] || differs=true
    elif [[ -n "${head//[[:space:]]/}" ]] && ! { [[ -f "$skel" ]] && [[ "$head" == "$(cat "$skel")" ]]; }; then
        kept="$head"
    fi
    for part in "$tmp"/block.*; do
        [[ -f "$part" ]] || continue
        [[ "$(cat "$part")" == "$repo" ]] || differs=true
    done
    if [[ -n "${outside//[[:space:]]/}" ]]; then
        kept="${kept:+$kept$'\n'}$outside"
    fi
    rm -rf "$tmp"

    local local_file="$SHELL_SCRIPTS_DIR/00-local.sh" saved
    if is_dry_run; then
        [[ -z "$kept" ]] || log_info "[DRY-RUN] Would move your .bashrc content to $local_file"
        [[ "$differs" != true ]] || log_info "[DRY-RUN] Would save a copy of $dest first: its managed part differs from the repo"
        return 0
    fi
    if [[ "$differs" == true ]]; then
        saved="$BACKUP_DIR/bashrc.before-cleanup.$(timestamp)"
        ensure_dir "$BACKUP_DIR" || return 1
        cp -p "$dest" "$saved" || return 1
        installer_report_warning "$dest differed from the repo, so hand edits may be gone from it; the old file is at $saved"
    fi
    if [[ -n "$kept" ]] && ! { [[ -f "$local_file" ]] && [[ "$(cat "$local_file")" == *"$kept"* ]]; }; then
        (
            umask 077
            {
                echo "# Moved here from ~/.bashrc by dotfiles. This file is yours; dotfiles won't change it."
                printf '%s\n' "$kept"
            } >> "$local_file"
        ) || return 1
        installer_report_warning "moved your own .bashrc content to $local_file; it now loads after the managed file"
    fi
}

# Replace .bashrc like any other file, keeping what isn't ours the first time
deploy_bashrc() {
    local dest="$2" verb="${5:-install}"
    if [[ -f "$dest" ]] && { [[ "$verb" == install ]] || bashrc_has_blocks "$dest"; }; then
        bashrc_preserve "$1" "$dest" || return 1
    fi
    deploy_file_default "$@"
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


# Route .bashrc through the step that keeps existing content
deploy_file() {
    if [[ "$(basename "$1")" == ".bashrc" ]]; then
        deploy_bashrc "$@"
    else
        deploy_file_default "$@"
    fi
}

# Supplements install before state is written, so a failure leaves no state behind
app_post_deploy() {
    install_supplements
}

installer_main "$@"
