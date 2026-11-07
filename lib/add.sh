#!/usr/bin/env bash
# add.sh - dotfiles add: walk through local edits and stage the accepted ones in the
# repo layer they belong to. It stops there: it never commits or pushes, so what you
# accepted still goes through your own review in git or lazygit.
#
# It only ever copies files dotfiles already manages, so ~/.ssh, ~/.gitconfig.local and
# ~/.bashrc.d/90-secrets.sh can't be swept in. Merged files are display-only.
# Reads globals from the dotfiles script (PKG_*, LAYER_ROOTS, HOST_YAML, ...).

# Layers for the current file, highest priority first (filled by add_build_layers)
declare -a ADD_LABELS=()
declare -a ADD_ROOTS=()
ADD_PUBLIC_ROOT=""
# Repo root -> newline-separated files staged there
declare -A ADD_STAGED=()

# Ask a question. Prompts go to stderr; answers come from /dev/tty (stdin when
# DOTFILES_ADD_ASSUME_TTY=1). An empty answer means DEFAULT; EOF means DEFAULT too.
# Usage: add_ask VAR PROMPT DEFAULT
add_ask() {
    # Prefixed: printf -v must reach the caller's variable, not a local of this name
    local _ask_var="$1" _ask_prompt="$2" _ask_default="$3" _ask_reply=""
    printf '%s [%s]: ' "$_ask_prompt" "$_ask_default" >&2
    if [[ "${DOTFILES_ADD_ASSUME_TTY:-}" == 1 ]]; then
        IFS= read -r _ask_reply || true
    else
        IFS= read -r _ask_reply </dev/tty || true
    fi
    _ask_reply="${_ask_reply//$'\r'/}"
    printf -v "$_ask_var" '%s' "${_ask_reply:-$_ask_default}"
}

# Replace $HOME with ~ for display
add_tilde() {
    case "$1" in
        "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Fill ADD_LABELS/ADD_ROOTS: this host, its profiles (nearest first), then the
# default in the public repo, which is left out when pinned or not a git checkout
# (a commit there would not land on a branch).
# Usage: add_build_layers DIR
add_build_layers() {
    local dir="$1" i p
    ADD_LABELS=()
    ADD_ROOTS=()
    if [[ -n "$HOST_YAML" ]]; then
        ADD_LABELS+=("host: $OVERLAY_HOST (hosts repo)")
        ADD_ROOTS+=("$HOSTS_DIR/hosts/$OVERLAY_HOST")
    fi
    for (( i = ${#HOSTS_PROFILE_CHAIN[@]} - 1; i >= 0; i-- )); do
        p="${HOSTS_PROFILE_CHAIN[$i]}"
        ADD_LABELS+=("profile: $p (hosts repo)")
        ADD_ROOTS+=("$HOSTS_DIR/profiles/$p")
    done
    ADD_PUBLIC_ROOT="$DOTFILES_REPO"
    if versions_is_checkout "$DOTFILES_REPO" && ! versions_is_pinned "$DOTFILES_REPO"; then
        ADD_LABELS+=("dotfiles default (PUBLIC repo, all machines)")
        ADD_ROOTS+=("$ADD_PUBLIC_ROOT")
    fi
}

# Index in ADD_ROOTS of the highest layer that has this file; -1 if none does
# Usage: add_current_layer DIR SRC
add_current_layer() {
    local dir="$1" src="$2" i
    for i in "${!ADD_ROOTS[@]}"; do
        if [[ -f "${ADD_ROOTS[$i]}/apps/$dir/files/$src" ]]; then
            echo "$i"
            return 0
        fi
    done
    echo -1
}

# Copy the live file into the layer and stage it. Skips a target with uncommitted
# changes, so accepting an edit can't overwrite other work in the repo.
# Usage: add_save LIVE TARGET
add_save() {
    local live="$1" target="$2" top rel probe
    probe=$(dirname "$target")
    while [[ ! -d "$probe" ]]; do probe=$(dirname "$probe"); done
    top=$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$top" && -e "$target" ]]; then
        rel="${target#"$(cd "$top" && pwd -P)"/}"
        if ! git -C "$top" diff --quiet -- "$rel" || ! git -C "$top" diff --cached --quiet -- "$rel"; then
            log_warn "$target has uncommitted changes; skipped (commit or discard them, then run 'dotfiles add' again)"
            return 1
        fi
    fi
    mkdir -p "$(dirname "$target")" || return 1
    cp "$live" "$target" || return 1
    if [[ -z "$top" ]]; then
        log_info "Copied to $target (not a git checkout, nothing to stage)"
        return 0
    fi
    rel="${target#"$(cd "$top" && pwd -P)"/}"
    if ! git -C "$top" add -- "$rel" 2>/dev/null; then
        log_warn "Copied to $target, but could not stage it"
        return 0
    fi
    ADD_STAGED["$top"]+="  $rel"$'\n'
    log_success "Staged $rel in $top"
}

# Show a merged file's differences. Nothing can be accepted from here.
# Usage: add_show_merged DIR SRC DEST STAGE
add_show_merged() {
    local dir="$1" src="$2" dest="$3" stage="$4" key want got n i layer_path=""
    echo
    echo "=== $(add_tilde "$dest") (merged, showing keys the repo manages) ==="
    while IFS=$'\t' read -r key want got; do
        echo "  $key"
        echo "  - $want"
        echo "  + $got"
    done < <(deployed_merge_diff "$stage/files/$src" "$dest" || true)
    n=$(deployed_merge_local_count "$stage/files/$src" "$dest")
    echo "  $n local keys not shown or copied"
    i=$(add_current_layer "$dir" "$src")
    if [[ "$i" -ge 0 ]]; then
        layer_path="${ADD_ROOTS[$i]}/apps/$dir/files/$src"
    else
        layer_path="$DOTFILES_REPO/apps/$dir/files/$src"
    fi
    echo "  Merged files can't be accepted here; edit $layer_path by hand"
}

# Walk through one edited file
# Returns 2 when the user quits.
# Usage: add_review_file DIR KIND SRC DEST STAGE
add_review_file() {
    local dir="$1" kind="$2" src="$3" dest="$4" stage="$5" answer i
    echo
    echo "=== $(add_tilde "$dest") ==="
    diff -u --label "repo: $dir/$src" --label "live: $(add_tilde "$dest")" "$stage/files/$src" "$dest" || true
    if [[ "$kind" == conflict ]]; then
        log_warn "The repo version also changed since this was deployed; saving replaces it with yours"
    fi

    add_ask answer "Save this change? y(es) n(o) q(uit)" "n"
    case "$answer" in
        y|Y|yes) ;;
        q|Q|quit) return 2 ;;
        *) return 0 ;;
    esac

    if [[ ${#ADD_ROOTS[@]} -eq 0 ]]; then
        log_warn "Nowhere to save it: no hosts repo is set up here, and the public default isn't available while pinned or without git"
        return 0
    fi

    local current default=0
    current=$(add_current_layer "$dir" "$src")
    # Back where it came from, unless that is the public repo
    if [[ "$current" -ge 0 && "${ADD_ROOTS[$current]}" != "$ADD_PUBLIC_ROOT" ]]; then
        default="$current"
    fi

    echo "Save $(add_tilde "$dest") to:"
    for i in "${!ADD_LABELS[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${ADD_LABELS[$i]}"
    done
    add_ask answer "Layer" "$((default + 1))"
    if ! [[ "$answer" =~ ^[0-9]+$ ]] || (( answer < 1 || answer > ${#ADD_ROOTS[@]} )); then
        log_warn "No such layer; skipped"
        return 0
    fi
    i=$((answer - 1))

    if [[ "${ADD_ROOTS[$i]}" == "$ADD_PUBLIC_ROOT" ]]; then
        add_ask answer "This goes to a PUBLIC repo. Type 'public' to confirm" "no"
        if [[ "$answer" != public ]]; then
            log_info "Skipped"
            return 0
        fi
    fi
    if [[ "$current" -ge 0 && "$i" -gt "$current" ]]; then
        log_warn "${ADD_LABELS[$current]} has its own copy, so this won't change the file on this machine"
    elif [[ "$i" -lt "$current" || "$current" -lt 0 ]] && [[ "${ADD_ROOTS[$i]}" != "$ADD_PUBLIC_ROOT" ]]; then
        log_warn "This layer now has its own copy: later changes to lower layers won't reach machines using it"
    fi

    # The record stays as it is: the next deploy updates it. Until then the layer's copy
    # matches the live file, so it isn't an edit, and discarding the staged change makes
    # it one again instead of letting the next update overwrite it.
    add_save "$dest" "${ADD_ROOTS[$i]}/apps/$dir/files/$src" || true
}

# dotfiles add
cmd_add() {
    if is_dry_run; then
        echo "dotfiles add has no dry run; answer 'n' to look without saving, or see 'dotfiles status'" >&2
        exit 1
    fi
    if ! sync_lock; then
        echo "dotfiles: pull already running" >&2
        exit 1
    fi
    local host
    host="${HOSTNAME_ARG:-$(hosts_local_name)}"
    OVERLAY_HOST="$host"
    load_packages_for_profile "$PROFILE_ARG" "$host" || exit 1
    prepare_overlays "add" || { log_error "Invalid overlay configuration"; exit 1; }

    if [[ ! -t 0 && "${DOTFILES_ADD_ASSUME_TTY:-}" != 1 ]]; then
        echo "dotfiles add is interactive; run it in a terminal" >&2
        exit 1
    fi

    local idx dir app stage kind src dest found=false rc=0 line
    for idx in "${!PKG_NAMES[@]}"; do
        dir="${PKG_CONFIG_DIR[$idx]}"
        [[ -n "$dir" && -f "$APPS_DIR/$dir/config.yaml" ]] || continue
        yaml_load "$APPS_DIR/$dir/config.yaml"
        app=$(yaml_get app.name)
        [[ -n "$app" ]] || app=$(basename "$dir")
        stage="$STAGE_ROOT/apps/$dir"
        overlay_stage_app "$APPS_DIR/$dir" "$stage" "$STRATEGIES_FILE" "${LAYER_ROOTS[@]}" 2>/dev/null || continue
        add_build_layers "$dir"

        local -a edits=()
        mapfile -t edits < <(deployed_app_edits "$app" "$stage")
        for line in ${edits[@]+"${edits[@]}"}; do
            IFS=$'\t' read -r kind src dest <<< "$line"
            found=true
            if [[ "$kind" == merge ]]; then
                add_show_merged "$dir" "$src" "$dest" "$stage"
                continue
            fi
            rc=0
            add_review_file "$dir" "$kind" "$src" "$dest" "$stage" || rc=$?
            [[ $rc -ne 2 ]] || break 2
        done
    done

    if [[ "$found" != true ]]; then
        log_success "No local edits"
    fi
    if [[ ${#ADD_STAGED[@]} -gt 0 ]]; then
        echo
        echo "Staged, not committed. Review, commit and push these yourself:"
        local top
        for top in "${!ADD_STAGED[@]}"; do
            echo "$top"
            printf '%s' "${ADD_STAGED[$top]}"
            echo "  git -C $top diff --cached   (or: lazygit -p $top)"
        done
    fi
    exit 0
}
