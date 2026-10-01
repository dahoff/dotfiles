#!/usr/bin/env bash
# sync.sh - sync pipeline helpers: lock, fast-forward pull, self-install, state files
# Requires lib/logging.sh. Used by the dotfiles script.

# Commands run by the single EXIT trap in dotfiles (e.g. removing the mkdir lock)
declare -a SYNC_CLEANUP=()
# Warnings recorded during sync, for the --auto report
declare -a SYNC_WARNINGS=()
SYNC_AUTO="${SYNC_AUTO:-false}"

# Print the state directory, creating it
sync_state_dir() {
    local dir="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles"
    mkdir -p "$dir"
    echo "$dir"
}

# Take an exclusive non-blocking lock, held until the process exits.
# Must be called in the main shell (not via $(...)) so fd 9 stays open.
# Returns 1 if the lock is held elsewhere.
sync_lock() {
    local dir
    dir=$(sync_state_dir)
    if command -v flock >/dev/null 2>&1; then
        if ! { exec 9>"$dir/lock"; } 2>/dev/null; then
            log_error "cannot open lock file $dir/lock"
            exit 1
        fi
        flock -n 9
    else
        # No flock (e.g. macOS): mkdir is atomic
        mkdir "$dir/lock.d" 2>/dev/null || return 1
        SYNC_CLEANUP+=("rmdir '$dir/lock.d' 2>/dev/null || true")
    fi
}

# Fast-forward-only pull of one repo.
# Returns 0 on success or when there is nothing to pull; on failure returns 1
# and prints the reason (first line of git's stderr, max 120 chars) on stdout.
sync_pull_repo() {
    local path="$1"
    git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    git -C "$path" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || return 0

    local -a envs=(GIT_TERMINAL_PROMPT=0)
    if [[ "$SYNC_AUTO" == true && -z "${GIT_SSH_COMMAND:-}" ]]; then
        envs+=("GIT_SSH_COMMAND=ssh -o BatchMode=yes")
    fi

    local before after err
    before=$(git -C "$path" rev-parse HEAD 2>/dev/null || true)
    if ! err=$(env "${envs[@]}" git -C "$path" -c merge.autoStash=false -c rebase.autoStash=false \
        -c pull.rebase=false pull --ff-only --quiet 9>&- 2>&1 >/dev/null); then
        local line
        line=$(printf '%s\n' "$err" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -m1 -v '^$' || true)
        printf '%s\n' "${line:0:120}"
        return 1
    fi
    after=$(git -C "$path" rev-parse HEAD 2>/dev/null || true)
    if [[ "$before" != "$after" ]]; then
        log_info "Pulled $path"
    else
        log_info "Already up to date: $path"
    fi
    return 0
}

# Install the command symlink and the login drop-in
# Usage: sync_self_install DOTFILES_REPO SHELL_SCRIPTS_DIR
sync_self_install() {
    local repo="$1" scripts_dir="$2"
    local src="$repo/lib/login.sh"

    mkdir -p "$HOME/.local/bin"
    ln -sfn "$repo/dotfiles" "$HOME/.local/bin/dotfiles"
    log_debug "Linked $HOME/.local/bin/dotfiles -> $repo/dotfiles"

    mkdir -p "$scripts_dir"
    if ! cmp -s "$src" "$scripts_dir/90-dotfiles.sh"; then
        cp "$src" "$scripts_dir/90-dotfiles.sh"
        chmod 0644 "$scripts_dir/90-dotfiles.sh"
        log_debug "Installed login drop-in: $scripts_dir/90-dotfiles.sh"
    fi
}

# Record that a sync ran
sync_touch_last() {
    local dir
    dir=$(sync_state_dir)
    touch "$dir/last-sync"
}

# Write pending package names, one per line (empty file if none)
sync_write_pending() {
    local dir
    dir=$(sync_state_dir)
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$@" > "$dir/pending"
    else
        : > "$dir/pending"
    fi
}

# Remove a stale report
sync_clear_report() {
    local dir
    dir=$(sync_state_dir)
    rm -f "$dir/report"
}
