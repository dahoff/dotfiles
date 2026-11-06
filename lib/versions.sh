#!/usr/bin/env bash
# versions.sh - dotfiles checkout, dotfiles versions, and the version shown by status.
#
# A machine is pinned when its dotfiles checkout is on a detached HEAD: sync_pull_repo
# skips a checkout with no upstream, so it stays on that version until 'dotfiles
# checkout main'. Nothing else records the pin.
#
# This file is also the marker for "new enough": checkout refuses a version without
# it, because that version has no 'dotfiles checkout' to come back with and no pinned
# warning. Do not rename it without updating VERSIONS_MARKER's users.
# Requires lib/logging.sh and lib/sync.sh.

VERSIONS_MARKER="lib/versions.sh"

# True if PATH is the root of a git checkout (a pushed copy is not)
# Usage: versions_is_checkout PATH
versions_is_checkout() {
    local top
    top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    [[ "$(cd "$top" && pwd -P)" == "$(cd "$1" && pwd -P)" ]]
}

# Usage: versions_is_pinned PATH
versions_is_pinned() {
    versions_is_checkout "$1" && ! git -C "$1" symbolic-ref -q HEAD >/dev/null 2>&1
}

# The branch to follow: origin's default, else main
# Usage: versions_default_branch PATH
versions_default_branch() {
    local ref
    ref=$(git -C "$1" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null) || ref=""
    echo "${ref#origin/}" | sed 's/^$/main/'
}

# The tag at HEAD, else its short commit
# Usage: versions_label PATH
versions_label() {
    git -C "$1" describe --tags --exact-match HEAD 2>/dev/null \
        || git -C "$1" rev-parse --short HEAD 2>/dev/null
}

# Warn that sync will not move this machine. Silent for --auto, so new terminals
# don't repeat it every interval; status still shows the pin.
# Usage: versions_warn_pinned PATH
versions_warn_pinned() {
    [[ "${SYNC_AUTO:-false}" != true ]] || return 0
    versions_is_pinned "$1" || return 0
    log_warn "pinned to $(versions_label "$1"): dotfiles itself will not update (run 'dotfiles checkout $(versions_default_branch "$1")' to follow it)"
}

# Fetch branches and tags; a failure is a warning, so offline refs still work
# Usage: versions_fetch PATH
versions_fetch() {
    local err line
    if ! err=$(sync_git_bounded "$1" fetch --quiet --tags origin 9>&- 2>&1 >/dev/null); then
        line=$(printf '%s\n' "$err" | grep -m1 -v '^$' || true)
        log_warn "could not fetch, using what is already here (${line:0:120})"
    fi
}

# One line for status. Uses only what was last fetched: status never touches the network.
# Usage: versions_status_line PATH
versions_status_line() {
    local repo="$1" branch base behind ahead="0" out
    branch=$(versions_default_branch "$repo")
    base="origin/$branch"
    behind=$(git --no-optional-locks -C "$repo" rev-list --count "HEAD..$base" 2>/dev/null) || base=""
    if versions_is_pinned "$repo"; then
        out="$(versions_label "$repo"), pinned (run 'dotfiles checkout $branch' to follow it)"
        [[ -z "$base" ]] || out+=", $behind behind $base"
        printf '%s' "$out"
        return 0
    fi
    out="$(versions_label "$repo") on $(git -C "$repo" symbolic-ref --short -q HEAD)"
    if [[ -z "$base" ]]; then
        printf '%s' "$out"
        return 0
    fi
    ahead=$(git --no-optional-locks -C "$repo" rev-list --count "$base..HEAD" 2>/dev/null) || ahead=0
    if [[ "$behind" -eq 0 && "$ahead" -eq 0 ]]; then
        out+=", up to date with $base"
    else
        [[ "$behind" -eq 0 ]] || out+=", $behind behind $base"
        [[ "$ahead" -eq 0 ]] || out+=", $ahead ahead of $base"
    fi
    printf '%s (as of last fetch)' "$out"
}

# dotfiles versions: tags, newest first
cmd_versions() {
    local repo="$SCRIPT_DIR"
    if ! versions_is_checkout "$repo"; then
        log_error "$repo is not a git checkout, so it has no versions to list"
        exit 1
    fi
    versions_fetch "$repo"

    local head tag sha date note found=false
    head=$(git -C "$repo" rev-parse HEAD)
    while IFS=$'\t' read -r tag date; do
        found=true
        sha=$(git -C "$repo" rev-parse "$tag^{commit}")
        note=""
        if [[ "$sha" == "$head" ]]; then
            note="  (current)"
        elif ! git -C "$repo" cat-file -e "$sha:$VERSIONS_MARKER" 2>/dev/null; then
            note="  (too old to check out)"
        fi
        printf '%-20s %s  %s%s\n' "$tag" "${date:--}" "${sha:0:7}" "$note"
    done < <(git -C "$repo" tag --list --sort=-creatordate --format='%(refname:short)%09%(creatordate:short)')
    if [[ "$found" != true ]]; then
        echo "No tagged versions yet. Create one with: git tag v1.0 && git push origin v1.0"
    fi
    exit 0
}

# dotfiles checkout REF: switch this machine to a tag or commit (pinned), or a branch
# (following it), then deploy using the code of the version switched to.
cmd_checkout() {
    local repo="$SCRIPT_DIR" ref="$CHECKOUT_REF" target branch=false

    if ! versions_is_checkout "$repo"; then
        log_error "$repo is not a git checkout, so it can't switch versions (a pushed copy has no history)"
        exit 1
    fi
    if ! is_dry_run && ! sync_lock; then
        echo "dotfiles: sync already running" >&2
        exit 1
    fi
    if [[ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
        log_error "$repo has uncommitted changes; commit or discard them before switching versions"
        exit 1
    fi

    versions_fetch "$repo"

    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
        branch=true
        target="refs/remotes/origin/$ref"
    elif git -C "$repo" show-ref --verify --quiet "refs/heads/$ref"; then
        branch=true
        target="refs/heads/$ref"
    elif ! target=$(git -C "$repo" rev-parse --verify --quiet "$ref^{commit}"); then
        log_error "Unknown version '$ref' (see 'dotfiles versions')"
        exit 1
    fi

    if ! git -C "$repo" cat-file -e "$target:$VERSIONS_MARKER" 2>/dev/null; then
        log_error "'$ref' is too old: it has no 'dotfiles checkout' to switch back with and would not warn that it is pinned"
        exit 1
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would switch to $ref and deploy it"
        exit 0
    fi

    if [[ "$branch" == true ]]; then
        git -C "$repo" checkout --quiet "$ref" 9>&- || { log_error "Could not switch to $ref"; exit 1; }
        sync_pull_one "$repo"
        log_success "Now following $ref at $(versions_label "$repo")"
    else
        git -C "$repo" checkout --quiet --detach "$target" 9>&- || { log_error "Could not switch to $ref"; exit 1; }
        log_success "Pinned to $(versions_label "$repo")"
    fi

    # Deploy with the new version's own code. Only flags reach this point: settings
    # have not been resolved, so the config file is still read by the sync below.
    local -a sync_args=(sync --no-pull)
    [[ -z "$PROFILE_ARG" ]] || sync_args+=(--profile "$PROFILE_ARG")
    [[ -z "$HOSTS_DIR" ]] || sync_args+=(--hosts-dir "$HOSTS_DIR")
    [[ -z "$HOSTNAME_ARG" ]] || sync_args+=(--hostname "$HOSTNAME_ARG")
    sync_args+=(${GLOBAL_FLAGS[@]+"${GLOBAL_FLAGS[@]}"})
    sync_unlock
    local rc=0
    "$repo/dotfiles" "${sync_args[@]}" || rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "Switched to $ref, but deploying it failed; run 'dotfiles sync' to retry"
    fi
    exit $rc
}
