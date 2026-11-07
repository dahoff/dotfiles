#!/usr/bin/env bash
# sync.sh - sync pipeline helpers: lock, fast-forward pull, self-install, state files
# Requires lib/logging.sh. Used by the dotfiles script.

# Commands run by the single EXIT trap in dotfiles (e.g. removing the mkdir lock)
declare -a SYNC_CLEANUP=()
# Warnings recorded during a pull, listed in its summary
declare -a SYNC_WARNINGS=()
# BatchMode for ssh: the background update check must never prompt
SYNC_BATCH="${SYNC_BATCH:-false}"

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

# Release the lock early, for a child process that takes it itself
sync_unlock() {
    exec 9>&-
    local cmd
    for cmd in ${SYNC_CLEANUP[@]+"${SYNC_CLEANUP[@]}"}; do
        eval "$cmd" || true
    done
    SYNC_CLEANUP=()
}

# Run git against the network, bounded so a stalled transfer cannot hold the lock
# forever and credentials never prompt.
# Usage: sync_git_bounded PATH GIT_ARGS...
sync_git_bounded() {
    local path="$1"
    shift
    # LC_ALL=C: callers match git's messages
    local -a envs=(GIT_TERMINAL_PROMPT=0 LC_ALL=C)
    if [[ -z "${GIT_SSH_COMMAND:-}" ]]; then
        local ssh_cmd="ssh -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
        [[ "$SYNC_BATCH" == true ]] && ssh_cmd+=" -o BatchMode=yes"
        envs+=("GIT_SSH_COMMAND=$ssh_cmd")
    fi
    local -a wrap=()
    command -v timeout >/dev/null 2>&1 && wrap=(timeout 300)
    env "${envs[@]}" ${wrap[@]+"${wrap[@]}"} git -C "$path" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 "$@"
}

# Fast-forward-only pull of one repo.
# Returns 0 on success or when there is nothing to pull. On failure prints the
# reason (first line of git's stderr, max 120 chars) on stdout and returns 2 when
# the pull is blocked (diverged, or local changes would be overwritten), else 1.
sync_pull_repo() {
    local path="$1"
    # Only a repo rooted at PATH itself (a pushed copy inside a tracked $HOME is not)
    sync_is_rooted_repo "$path" || return 0
    git -C "$path" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || return 0

    local before after err
    before=$(git -C "$path" rev-parse HEAD 2>/dev/null || true)
    if ! err=$(sync_git_bounded "$path" -c merge.autoStash=false -c rebase.autoStash=false \
        -c pull.rebase=false pull --ff-only --quiet 9>&- 2>&1 >/dev/null); then
        local line
        line=$(printf '%s\n' "$err" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -m1 -v '^$' || true)
        printf '%s\n' "${line:0:120}"
        printf '%s\n' "$err" | grep -qiE 'would be overwritten|Not possible to fast-forward|diverg' && return 2
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

# Succeed if PATH is the root of its own git repo (a pushed copy inside a
# tracked $HOME is not)
sync_is_rooted_repo() {
    local top
    top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    [[ "$(cd "$top" && pwd -P)" == "$(cd "$1" && pwd -P)" ]]
}

# Print the directory to deploy PATH from: an export of its HEAD, so only committed
# content deploys. A repo with no git (or a pushed copy inside another repo) is
# deployed as it stands, so PATH itself is printed. Fails, with an error, for a git
# repo that cannot be exported (no commits). The export is made once per path in
# $WORK_DIR and reused. Exported files keep their modes; export-ignore applies.
# Usage: repo_committed_tree PATH
repo_committed_tree() {
    local path="$1"
    if ! sync_is_rooted_repo "$path"; then
        printf '%s\n' "$path"
        return 0
    fi
    local key out
    key=$(printf '%s' "$(cd "$path" && pwd -P)" | cksum | cut -d' ' -f1)
    out="$WORK_DIR/export/$key"
    if [[ ! -f "$out/.exported" ]]; then
        if ! git -C "$path" rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then
            log_error "$path has no commits, so there is nothing to deploy from it (commit something there first)"
            return 1
        fi
        rm -rf "$out"
        mkdir -p "$out"
        if ! { git -C "$path" archive HEAD | tar -x -C "$out"; } 2>/dev/null; then
            rm -rf "$out"
            log_error "could not export the committed files of $path"
            return 1
        fi
        : > "$out/.exported"
    fi
    printf '%s\n' "$out"
}

# Warn about uncommitted changes in a git repo rooted at PATH: they are not
# deployed. Names up to 10 files. Silent for a clean repo or one with no git.
# Usage: repo_warn_dirty PATH
repo_warn_dirty() {
    local path="$1" line n=0 shown=""
    sync_is_rooted_repo "$path" || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        n=$((n + 1))
        [[ $n -gt 10 ]] || shown+="${shown:+, }${line:3}"
    done < <(git --no-optional-locks -C "$path" status --porcelain -uall 2>/dev/null)
    [[ $n -gt 0 ]] || return 0
    [[ $n -le 10 ]] || shown+=", and $((n - 10)) more"
    log_warn "$path has uncommitted changes that are not deployed: $shown"
}

# Install the command symlink and the login drop-in.
# The symlink is created only when missing or dangling; a valid link to another
# checkout, or a regular file, is left alone with a warning. The drop-in is
# copied from the repo the link resolves to.
# Usage: sync_self_install DOTFILES_REPO SHELL_SCRIPTS_DIR
sync_self_install() {
    local repo="$1" scripts_dir="$2"
    local link="$HOME/.local/bin/dotfiles"
    local src_repo="$repo"

    mkdir -p "$HOME/.local/bin"
    if [[ -L "$link" && -e "$link" ]]; then
        local current wanted
        current=$(readlink -f "$link")
        wanted=$(readlink -f "$repo/dotfiles")
        if [[ "$current" != "$wanted" ]]; then
            log_warn "~/.local/bin/dotfiles points at $current; leaving it (remove the link to switch to $repo)"
            src_repo="$(dirname "$current")"
        fi
    elif [[ -e "$link" ]]; then
        log_warn "~/.local/bin/dotfiles is not a symlink; leaving it (remove it to link $repo/dotfiles)"
    else
        ln -sfn "$repo/dotfiles" "$link"
        log_debug "Linked $link -> $repo/dotfiles"
    fi
    # From the committed content: an uncommitted edit does not reach the drop-in
    local tree src
    tree=$(repo_committed_tree "$src_repo") || return 0
    src="$tree/lib/login.sh"
    if [[ ! -f "$src" ]]; then
        tree=$(repo_committed_tree "$repo") || return 0
        src="$tree/lib/login.sh"
    fi

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

# Print the commit of a git repo rooted at PATH; what deploys is HEAD, whatever
# the working tree holds. Fails for anything else (not a repo, a pushed copy, no
# commits): those cannot be told from a commit.
sync_head() {
    sync_is_rooted_repo "$1" || return 1
    git -C "$1" rev-parse HEAD 2>/dev/null
}

# Print one line identifying what a sync would deploy, or fail when that cannot
# be told from the repos (see sync_head), so the sync must run in full.
# Reads globals DOTFILES_REPO, HOSTS_DIR, HOSTNAME_ARG, PROFILE_ARG and SHELL_SCRIPTS_DIR.
sync_fingerprint() {
    local dotfiles_head hosts_head="none"
    dotfiles_head=$(sync_head "$DOTFILES_REPO") || return 1
    if [[ -n "$HOSTS_DIR" ]]; then
        hosts_head=$(sync_head "$HOSTS_DIR") || return 1
    fi
    printf '%s %s %s %s %s %s\n' "$dotfiles_head" "$hosts_head" "$HOSTS_DIR" \
        "${HOSTNAME_ARG:-$(hosts_local_name)}" "$PROFILE_ARG" "$SHELL_SCRIPTS_DIR"
}

# Forget the last complete sync, so the next one runs in full
sync_forget_complete() {
    rm -f "$(sync_state_dir)/last-complete"
}

# Succeed if the last complete sync recorded this fingerprint
sync_is_complete() {
    local fingerprint="$1" recorded=""
    [[ -n "$fingerprint" ]] || return 1
    recorded=$(cat "$(sync_state_dir)/last-complete" 2>/dev/null) || return 1
    [[ "$recorded" == "$fingerprint" ]]
}

# Record a finished sync, if the next one may be skipped: nothing failed or is
# pending, and no custom script without a check (those run on every sync).
# Reads globals EXIT_CODE, PENDING, PKG_NAMES and PKG_CUSTOM_*.
sync_record_complete() {
    local fingerprint="$1" idx
    [[ -n "$fingerprint" && "$EXIT_CODE" -eq 0 && ${#PENDING[@]} -eq 0 ]] || return 0
    for idx in "${!PKG_NAMES[@]}"; do
        [[ -n "${PKG_CUSTOM_SCRIPT[$idx]}" && -z "${PKG_CUSTOM_CHECK[$idx]}" ]] && return 0
    done
    printf '%s\n' "$fingerprint" > "$(sync_state_dir)/last-complete"
}

# Modification time of a file in epoch seconds (GNU stat, then BSD stat)
sync_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Succeed if an update check should run now.
# Fails when update_check is off, or last-check is younger than UPDATE_CHECK_SECONDS.
# Reads globals UPDATE_CHECK and UPDATE_CHECK_SECONDS.
sync_check_due() {
    [[ "${UPDATE_CHECK:-on}" == "off" ]] && return 1
    local dir last now
    dir=$(sync_state_dir)
    [[ -e "$dir/last-check" ]] || return 0
    last=$(sync_mtime "$dir/last-check") || return 0
    now=$(date +%s)
    # A negative age (mtime in the future, clock skew) runs the check
    (( now >= last && now - last < UPDATE_CHECK_SECONDS )) && return 1
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

# Fetch one repo and print how many commits its upstream has that HEAD lacks.
# Fails, printing nothing, for anything that cannot be told: not a checkout of its
# own (no git, or a copy inside another repo), pinned, no upstream, or a failed fetch.
# Usage: sync_updates_behind PATH
sync_updates_behind() {
    local path="$1"
    versions_is_checkout "$path" || return 1
    ! versions_is_pinned "$path" || return 1
    git -C "$path" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || return 1
    sync_git_bounded "$path" fetch --quiet </dev/null 9>&- >/dev/null 2>&1 || return 1
    git -C "$path" rev-list --count 'HEAD..@{u}' 2>/dev/null
}

# The background update check: fetch the dotfiles and hosts repos and, when either has
# new commits upstream, write <state>/report. Never changes HEAD, the working tree,
# the live files or any package; the login drop-in shows the report once.
# Throttled on <state>/last-check, which is touched by every attempt, a failed fetch
# included, so an offline machine does not retry at every terminal. An existing
# report is left alone when there is nothing new to say.
# Reads globals DOTFILES_REPO and HOSTS_DIR, and those of sync_check_due.
sync_check_updates() {
    sync_check_due || return 0
    local dir
    dir=$(sync_state_dir)
    touch "$dir/last-check"

    local -a ahead=()
    local count
    SYNC_BATCH=true
    count=$(sync_updates_behind "$DOTFILES_REPO") || count=0
    [[ "$count" -gt 0 ]] && ahead+=("dotfiles")
    if [[ -n "$HOSTS_DIR" && -d "$HOSTS_DIR" ]]; then
        count=$(sync_updates_behind "$HOSTS_DIR") || count=0
        [[ "$count" -gt 0 ]] && ahead+=("hosts")
    fi
    [[ ${#ahead[@]} -gt 0 ]] || return 0

    printf "dotfiles: updates available (%s) — run 'dotfiles pull'\n" "$(sync_join "${ahead[@]}")" > "$dir/report.tmp"
    mv "$dir/report.tmp" "$dir/report"
}
