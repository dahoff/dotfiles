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

# Modification time of a file in epoch seconds (GNU stat, then BSD stat)
sync_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# For --auto: succeed if a sync should run now.
# Fails when auto_sync is off, or last-sync is younger than AUTO_SYNC_SECONDS.
# Reads globals AUTO_SYNC and AUTO_SYNC_SECONDS.
sync_should_run_auto() {
    [[ "${AUTO_SYNC:-on}" == "off" ]] && return 1
    local dir last now
    dir=$(sync_state_dir)
    [[ -e "$dir/last-sync" ]] || return 0
    last=$(sync_mtime "$dir/last-sync") || return 0
    now=$(date +%s)
    # A negative age (mtime in the future, clock skew) runs the sync
    (( now >= last && now - last < AUTO_SYNC_SECONDS )) && return 1
    return 0
}

# Join arguments with ", "
sync_join() {
    local out="" item
    for item in "$@"; do
        out+="${out:+, }$item"
    done
    printf '%s' "$out"
}

# Write <state>/report for --auto, or remove it when there is nothing to say.
# Usage: sync_write_report LOG UPDATED_CSV PENDING_CSV
#   LOG          path shown in "see <log>" suffixes
#   UPDATED_CSV  comma-separated names of updated apps ("" if none)
#   PENDING_CSV  comma-separated names of pending packages ("" if none)
# Warnings come from the global SYNC_WARNINGS, failures from FAIL entries in
# the global RESULTS ("target|item|FAIL"). Lines, in order: updated, pending,
# warnings, failed. Written to report.tmp, then moved into place.
sync_write_report() {
    local log="$1" updated_csv="${2:-}" pending_csv="${3:-}"
    local dir report tmp
    dir=$(sync_state_dir)
    report="$dir/report"
    tmp="$dir/report.tmp"
    : > "$tmp"

    local -a items=()
    if [[ -n "$updated_csv" ]]; then
        IFS=',' read -r -a items <<< "$updated_csv"
        printf 'dotfiles: updated %s\n' "$(sync_join "${items[@]}")" >> "$tmp"
    fi
    if [[ -n "$pending_csv" ]]; then
        IFS=',' read -r -a items <<< "$pending_csv"
        local noun="packages"
        [[ ${#items[@]} -eq 1 ]] && noun="package"
        printf "dotfiles: %d %s pending (%s) — run 'dotfiles sync'\n" \
            "${#items[@]}" "$noun" "$(sync_join "${items[@]}")" >> "$tmp"
    fi
    local w
    for w in "${SYNC_WARNINGS[@]}"; do
        printf 'dotfiles: %s — see %s\n' "$w" "$log" >> "$tmp"
    done
    local -a failed=()
    local result target item status
    for result in "${RESULTS[@]}"; do
        IFS='|' read -r target item status <<< "$result"
        [[ "$status" == "FAIL" ]] && failed+=("$item")
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        printf 'dotfiles: sync failed (%s) — see %s\n' "$(sync_join "${failed[@]}")" "$log" >> "$tmp"
    fi

    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$report"
    else
        rm -f "$tmp" "$report"
    fi
}
