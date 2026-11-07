#!/usr/bin/env bash
# add.sh - dotfiles add: review local edits one by one. Save copies a change into a repo
# layer and stages it; dismiss keeps it local and stops asking until it changes; skip asks
# again next time. It stops at staging: it never commits or pushes, so what you saved still
# goes through your own review in git or lazygit.
#
# Items come from the records (records_items): whole files for a replaced file, single keys
# for a merged one. It only ever looks at files dotfiles manages for this profile, so
# ~/.ssh, ~/.gitconfig.local and ~/.bashrc.d/90-secrets.sh can't be swept in.
#
# Writes go to the real repo paths (HOSTS_DIR, DOTFILES_REPO), never the committed exports
# that deploys read. A save leaves the records alone: only a deploy of committed content
# moves them, so a discarded save becomes an edit again.
# Reads globals from the dotfiles script (PKG_*, LAYER_ROOTS, HOSTS_PROFILE_CHAIN, ...).

# Layers for the current file, highest priority first (filled by add_build_layers): the
# ones a save can go to, every one that takes effect here whether or not it can take a
# save, and why any were left out
declare -a ADD_LABELS=()
declare -a ADD_ROOTS=()
declare -a ADD_EFFECTIVE_ROOTS=()
declare -a ADD_NOT_OFFERED=()
ADD_PUBLIC_ROOT=""
# Repo root -> 1, for each repo something was staged in
declare -A ADD_STAGED=()
# --all: also ask about what was dismissed
ADD_ALL=false

# Reading a merged file by path: values are wrapped, [] is absent and [x] is x. A path that
# runs into a plain value is absent, and writing over one replaces it. Paths are arrays.
ADD_JQ_DEFS='
def at($p):
  if ($p | length) == 0 then [.]
  elif type == "object" and has($p[0]) then .[$p[0]] | at($p[1:])
  else [] end;
def set_at($p; $x):
  if ($p | length) == 0 then $x
  else (if type == "object" then . else {} end) | .[$p[0]] |= set_at($p[1:]; $x) end;
'

# Ask a question. Prompts go to stderr; answers come from /dev/tty (stdin when
# DOTFILES_ADD_ASSUME_TTY=1). An empty answer means DEFAULT. Returns 1 at the end of the
# input, with VAR set to DEFAULT: an unfinished line isn't an answer.
# Usage: add_ask VAR PROMPT DEFAULT
add_ask() {
    # Prefixed: printf -v must reach the caller's variable, not a local of this name
    local _ask_var="$1" _ask_prompt="$2" _ask_default="$3" _ask_reply="" _ask_rc=0
    printf '%s [%s]: ' "$_ask_prompt" "$_ask_default" >&2
    if [[ "${DOTFILES_ADD_ASSUME_TTY:-}" == 1 ]]; then
        IFS= read -r _ask_reply || _ask_rc=1
    else
        IFS= read -r _ask_reply 2>/dev/null </dev/tty || _ask_rc=1
    fi
    if [[ $_ask_rc -ne 0 ]]; then
        echo >&2
        printf -v "$_ask_var" '%s' "$_ask_default"
        return 1
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

# Full sha256 of a file
# Usage: add__hash FILE
add__hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum < "$1" | cut -d' ' -f1
    else
        shasum -a 256 < "$1" | cut -d' ' -f1
    fi
}

# Fill the layer lists: this host, its profiles (nearest first), then the default in the
# public repo. A repo with no git is left out, because the next 'pull --remote' would
# replace a save there; so is a pinned public repo or a detached hosts repo, where a commit
# would not land on a branch. The host layer needs a host.yaml in the working copy, committed
# or not: without one, deploys ignore the host directory, so a save there would never take
# effect. Its apps/ directory can be missing: a save creates it.
# Usage: add_build_layers DIR
add_build_layers() {
    local i p host_root offer_hosts=false has_host=false
    ADD_LABELS=()
    ADD_ROOTS=()
    ADD_EFFECTIVE_ROOTS=()
    ADD_NOT_OFFERED=()
    ADD_PUBLIC_ROOT="$DOTFILES_REPO"
    if [[ -n "$HOSTS_DIR" ]]; then
        host_root="$HOSTS_DIR/hosts/$OVERLAY_HOST"
        [[ ! -f "$host_root/host.yaml" ]] || has_host=true
        if versions_is_pinned "$HOSTS_DIR"; then
            ADD_NOT_OFFERED+=("Not offering the hosts repo's layers: it's on a detached HEAD, so a commit there wouldn't land on a branch.")
        elif versions_is_checkout "$HOSTS_DIR"; then
            offer_hosts=true
            if [[ "$has_host" != true ]]; then
                ADD_NOT_OFFERED+=("Not offering this host's layer: $host_root/host.yaml is missing, and without it a file there wouldn't take effect.")
            fi
        fi
        if [[ "$has_host" == true ]]; then
            ADD_EFFECTIVE_ROOTS+=("$host_root")
            if [[ "$offer_hosts" == true ]]; then
                ADD_LABELS+=("host: $OVERLAY_HOST (hosts repo)")
                ADD_ROOTS+=("$host_root")
            fi
        fi
        for (( i = ${#HOSTS_PROFILE_CHAIN[@]} - 1; i >= 0; i-- )); do
            p="${HOSTS_PROFILE_CHAIN[$i]}"
            ADD_EFFECTIVE_ROOTS+=("$HOSTS_DIR/profiles/$p")
            if [[ "$offer_hosts" == true ]]; then
                ADD_LABELS+=("profile: $p (hosts repo)")
                ADD_ROOTS+=("$HOSTS_DIR/profiles/$p")
            fi
        done
    fi
    ADD_EFFECTIVE_ROOTS+=("$ADD_PUBLIC_ROOT")
    if versions_is_pinned "$DOTFILES_REPO"; then
        ADD_NOT_OFFERED+=("Not offering the public repo: this machine is pinned, so a commit there wouldn't land on a branch.")
    elif versions_is_checkout "$DOTFILES_REPO"; then
        ADD_LABELS+=("dotfiles default (PUBLIC repo, all machines)")
        ADD_ROOTS+=("$ADD_PUBLIC_ROOT")
    fi
}

# Why layers are missing from the list, if any are
add__say_not_offered() {
    local reason
    for reason in ${ADD_NOT_OFFERED[@]+"${ADD_NOT_OFFERED[@]}"}; do
        echo "$reason"
    done
}

# True if a layer's file holds the value at PATH_JSON. [] means the whole file holds it,
# compared byte for byte; a key is compared as JSON, whatever the formatting or key order.
# Usage: add__layer_holds LAYER_FILE PATH_JSON LIVE
add__layer_holds() {
    local file="$1" path="$2" live="$3"
    [[ -f "$file" ]] || return 1
    if [[ "$path" == "[]" ]]; then
        cmp -s "$live" "$file"
    else
        jq -ne --argjson p "$path" --slurpfile a "$live" --slurpfile b "$file" "$ADD_JQ_DEFS"'
            ($a[0] | at($p)) as $v | ($v | length) == 1 and ($b[0] | at($p)) == $v' >/dev/null 2>&1
    fi
}

# Succeed if any layer's working copy already holds the live value, committed or not: a
# saved item isn't asked about again, and discarding the save brings it back. A deleted key
# holds nothing. Reads ADD_ROOTS: call add_build_layers first.
# Usage: add_saved_elsewhere APP_DIR SRC PATH_JSON DEST
add_saved_elsewhere() {
    local dir="$1" src="$2" path="$3" dest="$4" root
    [[ -e "$dest" ]] || return 1
    for root in ${ADD_ROOTS[@]+"${ADD_ROOTS[@]}"}; do
        add__layer_holds "$root/apps/$dir/files/$src" "$path" "$dest" && return 0
    done
    return 1
}

# True if a layer's file exists and, for a key, has that key
# Usage: add__layer_has LAYER_FILE PATH_JSON
add__layer_has() {
    local file="$1" path="$2"
    [[ -f "$file" ]] || return 1
    [[ "$path" == "[]" ]] && return 0
    jq -ne --argjson p "$path" --slurpfile b "$file" "$ADD_JQ_DEFS"'
        ($b[0] | at($p) | length) == 1' >/dev/null 2>&1
}

# Index in ADD_ROOTS of the highest layer that has this file, or this key of it; -1 if none
# Usage: add_current_layer DIR SRC [PATH_JSON]
add_current_layer() {
    local dir="$1" src="$2" path="${3:-[]}" i
    for i in "${!ADD_ROOTS[@]}"; do
        if add__layer_has "${ADD_ROOTS[$i]}/apps/$dir/files/$src" "$path"; then
            echo "$i"
            return 0
        fi
    done
    echo -1
}

# Succeed if the winning layer's working copy holds the live value, so that it takes effect
# once committed and a conflict there is answered. Looks at every layer that takes effect,
# offered or not: a layer that can't take a save can still be the one that wins.
# Usage: add__winner_holds DIR SRC PATH_JSON DEST
add__winner_holds() {
    local dir="$1" src="$2" path="$3" dest="$4" root file
    [[ -e "$dest" ]] || return 1
    for root in "${ADD_EFFECTIVE_ROOTS[@]}"; do
        file="$root/apps/$dir/files/$src"
        if add__layer_has "$file" "$path"; then
            add__layer_holds "$file" "$path" "$dest"
            return
        fi
    done
    return 1
}

# The note of what add last wrote to a layer file
# Usage: add__saved_note REAL_TARGET
add__saved_note() {
    local tmp key
    tmp="$WORK_DIR/add-key"
    printf '%s' "$1" > "$tmp"
    key=$(add__hash "$tmp")
    rm -f "$tmp"
    echo "$STATE_DIR/records/.add-saved/$key"
}

# Put NEW at TARGET, in a layer, and stage it. A target with uncommitted changes is skipped
# so a save can't overwrite other work, unless add itself made them: the note left after
# each save says so while the file still matches it. If anything fails the target goes back
# to what it was, so the item stays pending.
# Usage: add__install NEW TARGET
add__install() {
    local new="$1" target="$2" probe real top rel note keep="" recorded=""
    probe=$(dirname "$target")
    while [[ ! -d "$probe" ]]; do probe=$(dirname "$probe"); done
    top=$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null) || top=""
    if [[ -z "$top" ]]; then
        log_warn "$target is not in a git checkout, nothing to stage it in"
        return 1
    fi
    top=$(cd "$top" && pwd -P)
    real="$(cd "$probe" && pwd -P)/${target#"$probe"/}"
    rel="${real#"$top"/}"
    note=$(add__saved_note "$real")

    if [[ -n "$(git --literal-pathspecs -C "$top" status --porcelain -- "$rel" 2>/dev/null)" ]]; then
        [[ -f "$note" ]] && recorded=$(cat "$note")
        if [[ ! -f "$target" || -z "$recorded" || "$(add__hash "$target")" != "$recorded" ]]; then
            log_warn "$target has uncommitted changes; skipped (commit or discard them, then run 'dotfiles add' again)"
            return 1
        fi
    fi

    if ! mkdir -p "$(dirname "$target")" 2>/dev/null; then
        log_warn "Could not create the directory for $target"
        return 1
    fi
    if [[ -e "$target" ]]; then
        keep=$(mktemp "$WORK_DIR/add-keep.XXXXXX") && cp -p "$target" "$keep" || {
            log_warn "Could not read $target"
            return 1
        }
    fi
    if ! cp "$new" "$target" 2>/dev/null || ! git --literal-pathspecs -C "$top" add -- "$rel" 2>/dev/null; then
        if [[ -n "$keep" ]]; then
            if ! cmp -s "$keep" "$target" && ! cp -p "$keep" "$target" 2>/dev/null; then
                log_warn "Could not put $target back; restore it with: git -C $top checkout -- '$rel'"
            fi
        else
            rm -f "$target"
        fi
        log_warn "Could not write and stage $target"
        return 1
    fi

    if ! (
        umask 077
        mkdir -p "$(dirname "$note")" && add__hash "$target" > "$note.tmp.$$" && mv -f "$note.tmp.$$" "$note"
    ) 2>/dev/null; then
        log_warn "Could not note this save, so a further save to $rel will be skipped until you commit"
    fi
    ADD_STAGED["$top"]=1
    log_success "Staged $rel in $top"
}

# Copy a live file into a layer and stage it
# Usage: add_save LIVE TARGET
add_save() {
    add__install "$1" "$2"
}

# Set one key in a layer's JSON and stage it, creating the file if needed. Anything else in
# the file is left as it is. An invalid file is refused, not overwritten.
# Usage: add_save_key LAYER_JSON PATH_JSON VALUE_FILE
add_save_key() {
    local layer="$1" path="$2" value="$3" cur out
    cur=$(mktemp "$WORK_DIR/add-cur.XXXXXX") || return 1
    out=$(mktemp "$WORK_DIR/add-out.XXXXXX") || return 1
    if [[ -e "$layer" ]]; then
        if ! records__is_object "$layer"; then
            log_warn "$layer is not a valid JSON object; fix it, then run 'dotfiles add' again"
            return 1
        fi
        cat "$layer" > "$cur"
    else
        printf '{}\n' > "$cur"
    fi
    # setpath can't go through a plain value, so one in the way goes first
    if ! jq --argjson p "$path" --slurpfile v "$value" '
            reduce range(1; $p | length) as $i (.;
              (getpath($p[:$i]) | type) as $t
              | if $t == "object" or $t == "null" then . else delpaths([$p[:$i]]) end)
            | setpath($p; $v[0])' "$cur" > "$out" 2>/dev/null; then
        log_warn "Could not set the key in $layer"
        return 1
    fi
    # The mode a new layer file gets
    chmod 0644 "$out" 2>/dev/null || true
    add__install "$out" "$layer"
}

# Write CURRENT with PATH_JSON taken from FROM, or removed if FROM doesn't have it. A removal
# takes along the parents it empties that FROM doesn't have either, so a deleted subtree is
# fully reviewed once each of its keys is.
# Usage: add__take CURRENT PATH_JSON FROM OUT
add__take() {
    jq --argjson p "$2" --slurpfile from "$3" "$ADD_JQ_DEFS"'
        ($from[0] | at($p)) as $w
        | if ($w | length) == 1 then set_at($p; $w[0])
          elif (at($p) | length) == 1 then
            delpaths([$p])
            | reduce range(($p | length) - 1; 0; -1) as $i (.;
                if at($p[:$i]) == [{}] and ($from[0] | at($p[:$i])) == []
                then delpaths([$p[:$i]]) else . end)
          else . end' "$1" > "$4" 2>/dev/null
}

# Keep an item local: the review copy takes it from the live file and, for a conflict, the
# repo copy takes it from the stage. Only that item changes. The review copy goes first: if
# the repo copy then fails, the conflict is still there to ask about.
# Usage: add_dismiss APP SRC DEST STAGE_FILE KIND PATH_JSON
add_dismiss() {
    local app="$1" src="$2" dest="$3" stage_file="$4" kind="$5" path="$6" work_v work_r
    if [[ "$path" == "[]" ]]; then
        records_set_review "$app" "$src" "$dest" 2>/dev/null || return 1
        if [[ "$kind" == conflict ]]; then
            records_set_repo "$app" "$src" "$stage_file" 2>/dev/null || return 1
        fi
        return 0
    fi
    work_v=$(mktemp "$WORK_DIR/add-review.XXXXXX") || return 1
    add__take "$(records_review_path "$app" "$src")" "$path" "$dest" "$work_v" || return 1
    if [[ "$kind" == conflict ]]; then
        work_r=$(mktemp "$WORK_DIR/add-repo.XXXXXX") || return 1
        add__take "$(records_repo_path "$app" "$src")" "$path" "$stage_file" "$work_r" || return 1
    fi
    records_set_review "$app" "$src" "$work_v" 2>/dev/null || return 1
    if [[ "$kind" == conflict ]]; then
        records_set_repo "$app" "$src" "$work_r" 2>/dev/null || return 1
    fi
}

# Print the value at PATH_JSON of a JSON file, or (absent)
# Usage: add__show_key FILE PATH_JSON
add__show_key() {
    jq -nr --argjson p "$2" --slurpfile f "$1" "$ADD_JQ_DEFS"'
        $f[0] | at($p) | if length == 1 then .[0] | tojson else "(absent)" end'
}

# Show an item: your change, and for a conflict the repo's change too
# Usage: add__show_item APP SRC DEST STAGE_FILE KIND PATH_JSON
add__show_item() {
    local app="$1" src="$2" dest="$3" stage_file="$4" kind="$5" path="$6" repo_copy
    repo_copy=$(records_repo_path "$app" "$src") || return 1
    echo
    if [[ "$path" == "[]" ]]; then
        echo "=== $(add_tilde "$dest") ==="
    else
        echo "=== $(add_tilde "$dest")  key $path ==="
    fi
    case "$kind" in
        conflict) echo "You and the repo both changed this." ;;
        dismissed) echo "You dismissed this earlier; it stays local unless you save it." ;;
    esac
    if [[ "$path" == "[]" ]]; then
        [[ "$kind" != conflict ]] || echo "Your change:"
        diff -u --label "repo copy" --label "live: $(add_tilde "$dest")" "$repo_copy" "$dest" || true
        if [[ "$kind" == conflict ]]; then
            echo "The repo's change:"
            diff -u --label "repo copy" --label "repo now" "$repo_copy" "$stage_file" || true
        fi
    else
        echo "  repo copy: $(add__show_key "$repo_copy" "$path")"
        echo "  live:      $(add__show_key "$dest" "$path")"
        if [[ "$kind" == conflict ]]; then
            echo "  repo now:  $(add__show_key "$stage_file" "$path")"
        fi
    fi
}

# Choose a layer and save the item there. A failure leaves it pending for next time.
# Returns 2 when the user quits or the input ends.
# Usage: add__save_item DIR SRC DEST STAGE_FILE KIND PATH_JSON
add__save_item() {
    local dir="$1" src="$2" dest="$3" kind="$5" path="$6" answer i current default=0 target value=""

    if [[ "$path" == "[]" && "$kind" == conflict ]]; then
        log_warn "Saving the whole file undoes the repo's change shown above"
        add_ask answer "Save it anyway? y(es) n(o)" "n" || return 2
        case "$answer" in
            y|Y|yes) ;;
            q|Q|quit) return 2 ;;
            *) log_info "Skipped"; return 0 ;;
        esac
    fi

    current=$(add_current_layer "$dir" "$src" "$path")
    # Back where it came from, unless that is the public repo
    if [[ "$current" -ge 0 && "${ADD_ROOTS[$current]}" != "$ADD_PUBLIC_ROOT" ]]; then
        default="$current"
    fi
    add__say_not_offered
    echo "Save $(add_tilde "$dest") to:"
    for i in "${!ADD_LABELS[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${ADD_LABELS[$i]}"
    done
    add_ask answer "Layer" "$((default + 1))" || return 2
    case "$answer" in
        q|Q|quit) return 2 ;;
    esac
    if ! [[ "$answer" =~ ^[0-9]+$ ]] || (( 10#$answer < 1 || 10#$answer > ${#ADD_ROOTS[@]} )); then
        log_warn "No such layer; skipped"
        return 0
    fi
    i=$((10#$answer - 1))
    target="${ADD_ROOTS[$i]}/apps/$dir/files/$src"

    if [[ "$path" != "[]" ]]; then
        value=$(mktemp "$WORK_DIR/add-value.XXXXXX") || return 0
        if ! jq --argjson p "$path" 'getpath($p)' "$dest" > "$value" 2>/dev/null; then
            log_warn "Could not read the value from $dest; it stays pending"
            return 0
        fi
    fi

    if [[ "${ADD_ROOTS[$i]}" == "$ADD_PUBLIC_ROOT" ]]; then
        echo "This goes to the PUBLIC repo:"
        if [[ "$path" == "[]" ]]; then
            cat "$dest"
        else
            echo "  $path = $(jq -c . "$value")"
        fi
        add_ask answer "Type 'public' to confirm" "no" || return 2
        case "$answer" in
            public) ;;
            q|Q|quit) return 2 ;;
            *) log_info "Skipped"; return 0 ;;
        esac
    fi

    if [[ "$current" -ge 0 && "$i" -gt "$current" ]]; then
        log_warn "${ADD_LABELS[$current]} still wins, so on this host the change stays local"
    fi
    if [[ "$path" == "[]" ]]; then
        if [[ ! -e "$target" ]]; then
            log_info "This creates the file in that layer, which masks any copy in lower layers from then on"
        fi
    elif [[ "$(jq -r 'type' "$value")" == array ]]; then
        log_warn "An array is saved as one value: this hides later repo changes to this list"
    fi

    if [[ "$path" == "[]" ]]; then
        add_save "$dest" "$target" || log_warn "Not saved; it stays pending"
    else
        add_save_key "$target" "$path" "$value" || log_warn "Not saved; it stays pending"
    fi
    return 0
}

# Ask about one item. Returns 2 when the user quits or the input ends.
# Usage: add_review_item APP DIR SRC DEST STAGE_FILE KIND PATH_JSON
add_review_item() {
    local app="$1" dir="$2" src="$3" dest="$4" stage_file="$5" kind="$6" path="$7"
    local answer no_save="" options

    add__show_item "$app" "$src" "$dest" "$stage_file" "$kind" "$path" || return 0

    if [[ "$path" != "[]" && "$(add__show_key "$dest" "$path")" == "(absent)" ]]; then
        no_save="You deleted this repo-managed key. Saving isn't possible; dismiss keeps it deleted."
    elif [[ ${#ADD_ROOTS[@]} -eq 0 ]]; then
        no_save="Saving isn't possible here: no repo on this host can take it. To keep this edit elsewhere, copy it by hand."
    elif grep -qxF -- "$src" "${stage_file%/files/"$src"}/skip" 2>/dev/null; then
        no_save="A layer's committed copy of this file is not a valid JSON object, so there is no repo version to compare with: saving isn't possible, and a conflict with the repo can't be seen. Fix that layer and commit it."
    elif [[ ! -e "$stage_file" ]]; then
        no_save="The repo no longer provides this file, so there's nowhere to save it."
    fi
    if [[ -n "$no_save" ]]; then
        echo "$no_save"
        [[ ${#ADD_ROOTS[@]} -ne 0 ]] || add__say_not_offered
        options="Dismiss or skip? d(ismiss) k(skip) q(uit)"
    else
        options="Save, dismiss or skip? s(ave) d(ismiss) k(skip) q(uit)"
    fi

    while true; do
        add_ask answer "$options" "k" || return 2
        case "$answer" in
            s|S|save)
                if [[ -z "$no_save" ]]; then
                    add__save_item "$dir" "$src" "$dest" "$stage_file" "$kind" "$path"
                    return
                fi
                ;;
            d|D|dismiss)
                add_dismiss "$app" "$src" "$dest" "$stage_file" "$kind" "$path" \
                    || log_warn "Could not update the records of $(add_tilde "$dest"); it stays pending"
                return 0
                ;;
            k|K|skip) return 0 ;;
            q|Q|quit) return 2 ;;
        esac
        echo "Not an option: $answer" >&2
    done
}

# The items of one file that add asks about: what records_items says, less what a layer's
# working copy already holds. A conflict needs the winning layer to hold it: anywhere lower,
# pull would go on warning about it, so add has to go on asking.
# Usage: add_file_items APP DIR SRC DEST STAGE_FILE ALL
add_file_items() {
    local app="$1" dir="$2" src="$3" dest="$4" stage_file="$5" all="$6" items kind path
    items=$(records_items "$app" "$src" "$dest" "$stage_file" "$all" 2>/dev/null) || return 1
    [[ -n "$items" ]] || return 0
    while IFS=$'\t' read -r kind path; do
        if [[ "$kind" == conflict ]]; then
            add__winner_holds "$dir" "$src" "$path" "$dest" && continue
        else
            add_saved_elsewhere "$dir" "$src" "$path" "$dest" && continue
        fi
        printf '%s\t%s\n' "$kind" "$path"
    done <<< "$items"
}

# The name an app's records and state go under: the same lookup as the installer's. The
# parser's keys are flat and it keeps what earlier files set, so this starts clean.
# Usage: add_app_name DIR
add_app_name() {
    unset YAML_DATA
    yaml_load "$APPS_DIR/$1/config.yaml"
    yaml_get name unknown
}

# Number of files that have something for add to ask about, among the apps in this profile:
# what pull points at must be something add can clear. Comparing against the records alone,
# so it works after a pull that stopped early.
add_count_edits() {
    local idx dir app src dest strategy items count=0
    if [[ ${#PKG_NAMES[@]} -eq 0 ]]; then
        OVERLAY_HOST="${HOSTNAME_ARG:-$(hosts_local_name)}"
        load_packages_for_profile "$PROFILE_ARG" "$OVERLAY_HOST" >/dev/null 2>&1 || { echo 0; return 0; }
    fi
    for idx in "${!PKG_NAMES[@]}"; do
        dir="${PKG_CONFIG_DIR[$idx]}"
        [[ -n "$dir" && -f "$APPS_DIR/$dir/config.yaml" ]] || continue
        app=$(add_app_name "$dir")
        add_build_layers "$dir"
        while IFS=$'\t' read -r src dest strategy; do
            # A file that can't be read for that counts as edited
            items=$(add_file_items "$app" "$dir" "$src" "$dest" "" false) || items=edited
            [[ -z "$items" ]] || count=$((count + 1))
        done < <(records_list "$app")
    done
    echo "$count"
}

# When the review ends, however it ends: what's staged in each repo, and what to do next.
# Run from the EXIT trap (SYNC_CLEANUP).
add_closing_message() {
    [[ ${#ADD_STAGED[@]} -gt 0 ]] || return 0
    local top file
    echo
    echo "Staged, not committed. Commit and push these yourself; other hosts won't get them until you do:"
    for top in "${!ADD_STAGED[@]}"; do
        echo "$top"
        while IFS= read -r -d '' file; do
            printf '  %s\n' "$file"
        done < <(git -C "$top" diff --cached --name-only -z 2>/dev/null)
        echo "  git -C $top diff --cached   (or: lazygit -p $top)"
    done
}

# dotfiles add
cmd_add() {
    if is_dry_run; then
        echo "dotfiles add has no dry run; answer 'k' to look without saving, or see 'dotfiles status'" >&2
        exit 1
    fi
    if [[ ! -t 0 && "${DOTFILES_ADD_ASSUME_TTY:-}" != 1 ]]; then
        echo "dotfiles add is interactive; run it in a terminal" >&2
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
    SYNC_CLEANUP+=("add_closing_message")

    local idx dir app stage src dest strategy items found=false rc=0 line kind path
    for idx in "${!PKG_NAMES[@]}"; do
        dir="${PKG_CONFIG_DIR[$idx]}"
        [[ -n "$dir" && -f "$APPS_DIR/$dir/config.yaml" ]] || continue
        app=$(add_app_name "$dir")
        stage="$STAGE_ROOT/apps/$dir"
        if ! overlay_stage_app "$APPS_DIR/$dir" "$stage" "$STRATEGIES_FILE" "${LAYER_ROOTS[@]}" 2>/dev/null; then
            found=true
            log_warn "Could not put together the repo's files for $app, so its edits aren't offered"
            continue
        fi
        add_build_layers "$dir"

        local -a entries=()
        mapfile -t entries < <(records_list "$app")
        for line in ${entries[@]+"${entries[@]}"}; do
            IFS=$'\t' read -r src dest strategy <<< "$line"
            if ! items=$(add_file_items "$app" "$dir" "$src" "$dest" "$stage/files/$src" "$ADD_ALL"); then
                found=true
                log_warn "Could not compare $(add_tilde "$dest") with its records, so it isn't offered (is it valid JSON?)"
                continue
            fi
            [[ -n "$items" ]] || continue
            found=true
            local -a item_lines=()
            mapfile -t item_lines <<< "$items"
            for line in "${item_lines[@]}"; do
                IFS=$'\t' read -r kind path <<< "$line"
                rc=0
                add_review_item "$app" "$dir" "$src" "$dest" "$stage/files/$src" "$kind" "$path" || rc=$?
                if [[ $rc -eq 2 ]]; then
                    echo
                    echo "Stopped: anything unanswered is asked again next time"
                    exit 0
                fi
            done
        done
    done

    if [[ "$found" != true ]]; then
        log_success "No local edits"
    fi
    exit 0
}
