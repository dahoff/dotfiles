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


# A custom .bashrc on the first install: the lines added to the distro's stock file are
# moved to a drop-in the managed .bashrc sources, so they stay loaded. The rest of the
# stock file isn't: rerun after the managed settings, it would undo them.
LOCAL_DROPIN_NAME="00-local.sh"
BASHRC_CARRY=""     # temp file holding the drop-in to write, once the deploy succeeds
BASHRC_CARRY_WHY="" # why nothing was carried over, when something should have been

# Print the lines of FILE that aren't in SKEL, in order (a line diff, so a block the user
# added stays whole). Without SKEL, the whole file. Leading and trailing blank lines go.
# git's diff slides an ambiguous hunk to line up with whole blocks: a plain LCS diff
# matches an appended block's closing "fi" to the stock file's last one, and the stock
# "fi" comes out as added.
# Usage: _bashrc_added_lines FILE SKEL
_bashrc_added_lines() {
    local file="$1" skel="$2"
    if [[ -f "$skel" ]] && command -v git >/dev/null 2>&1; then
        { git -c core.pager=cat diff --no-index --no-color --no-ext-diff --diff-algorithm=histogram \
            -U0 -- "$skel" "$file" || [[ $? -eq 1 ]]; } | awk '/^@@/ { body = 1; next } body && sub(/^\+/, "")'
    elif [[ -f "$skel" ]]; then
        diff --unchanged-line-format= --old-line-format= --new-line-format='%L' "$skel" "$file" || [[ $? -eq 1 ]]
    else
        cat "$file"
    fi | awk 'NF { started = 1; for (; blanks > 0; blanks--) print ""; print; next } started { blanks++ }'
}

# Note a custom .bashrc before the first install replaces it, and stage what to carry
# over. A distro's stock file, an empty one and the file about to be deployed aren't
# worth a warning.
app_pre_deploy() {
    BASHRC_REPLACED=""
    BASHRC_COPY=""
    BASHRC_CARRY=""
    BASHRC_CARRY_WHY=""
    [[ "${1:-}" == install ]] || return 0
    local dest name skel="${DOTFILES_SKEL_BASHRC:-/etc/skel/.bashrc}" added dropin
    for dest in "${CONFIG_DESTS[@]}"; do
        [[ "$(basename "$dest")" == ".bashrc" && -f "$dest" ]] || continue
        [[ -n "$(tr -d '[:space:]' < "$dest")" ]] || continue
        ! { [[ -f "$skel" ]] && cmp -s "$dest" "$skel"; } || continue
        cmp -s "$dest" "$(installer_src .bashrc)" && continue
        name=$(basename "$dest")
        if cmp -s "$dest" "$BACKUP_DIR/original/$name"; then
            BASHRC_COPY="$BACKUP_DIR/original/$name"
        elif [[ -n "${SNAPSHOT_TS:-}" ]] && cmp -s "$dest" "$BACKUP_DIR/$SNAPSHOT_TS/$name"; then
            BASHRC_COPY="$BACKUP_DIR/$SNAPSHOT_TS/$name"
        fi

        added=$(_bashrc_added_lines "$dest" "$skel") || added=""
        # Only blank lines and comments added: nothing that ran is lost
        grep -qvE '^[[:space:]]*(#|$)' <<< "$added" || continue
        BASHRC_REPLACED="$dest"
        dropin="$SHELL_SCRIPTS_DIR/$LOCAL_DROPIN_NAME"
        if [[ -e "$dropin" ]]; then
            BASHRC_CARRY_WHY="$(_bashrc_tilde "$dropin") already exists"
            continue
        fi
        if is_dry_run; then
            log_info "[DRY-RUN] Would move the lines added to $(_bashrc_tilde "$dest") into $(_bashrc_tilde "$dropin")"
            continue
        fi
        BASHRC_CARRY=$(mktemp) || return 1
        {
            echo "# Moved here by dotfiles on $(date +%F), from the ~/.bashrc it replaced:"
            if [[ -f "$skel" ]]; then
                echo "# the lines that weren't in $skel. Sourced by ~/.bashrc."
            else
                echo "# all of it. Sourced by ~/.bashrc."
            fi
            [[ -z "$BASHRC_COPY" ]] || echo "# The whole old file: $(_bashrc_tilde "$BASHRC_COPY")"
            echo "# To stop loading these lines, delete this file (or rename it so it doesn't end in .sh)."
            echo "# dotfiles never changes it, and never copies it into a repo."
            echo
            printf '%s\n' "$added"
        } > "$BASHRC_CARRY"
        if ! bash -n "$BASHRC_CARRY" 2>/dev/null; then
            rm -f "$BASHRC_CARRY"
            BASHRC_CARRY=""
            BASHRC_CARRY_WHY="the added lines don't make a valid script on their own"
        fi
    done
}

# Replace $HOME with ~ for messages
_bashrc_tilde() {
    case "$1" in
        "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Supplements install before state is written, so a failure leaves no state behind
app_post_deploy() {
    install_supplements || return 1
    [[ -n "$BASHRC_REPLACED" ]] && ! is_dry_run || return 0
    local dest_t dropin msg
    dest_t=$(_bashrc_tilde "$BASHRC_REPLACED")
    dropin="$SHELL_SCRIPTS_DIR/$LOCAL_DROPIN_NAME"
    if [[ -n "$BASHRC_CARRY" ]]; then
        cp "$BASHRC_CARRY" "$dropin" && chmod 0644 "$dropin" || {
            rm -f "$BASHRC_CARRY"
            return 1
        }
        rm -f "$BASHRC_CARRY"
        BASHRC_CARRY=""
        msg="$dest_t was replaced. The lines you'd added to it were moved to $(_bashrc_tilde "$dropin"), which is still loaded."
        msg="$msg To stop loading them: rm $(_bashrc_tilde "$dropin")"
        [[ -z "$BASHRC_COPY" ]] || msg="$msg (the old file is at $(_bashrc_tilde "$BASHRC_COPY"))"
        installer_report_notice "$msg"
        return 0
    fi
    msg="$dest_t was replaced; the old content is no longer loaded"
    [[ -z "$BASHRC_CARRY_WHY" ]] || msg="$msg ($BASHRC_CARRY_WHY, so nothing was moved)"
    msg="$msg."
    [[ -z "$BASHRC_COPY" ]] || msg="$msg The old file is at $BASHRC_COPY"
    installer_report_warning "$msg"
}

installer_main "$@"
