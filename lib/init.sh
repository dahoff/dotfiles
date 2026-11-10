#!/usr/bin/env bash
# init.sh - dotfiles init: guided per-host setup that writes the config file
# and runs the first sync. Requires lib/logging.sh, lib/hosts.sh, lib/config.sh
# and lib/sync.sh, and the dotfiles globals SCRIPT_DIR, PROFILES_DIR,
# DEFAULT_HOSTS_DIR.

INIT_YES=false
INIT_NO_SYNC=false
INIT_HOSTS_DIR=""
INIT_HOSTNAME=""
INIT_PROFILE=""
INIT_PROFILE_COMMENTED=false
INIT_UPDATE_CHECK="on"
INIT_INTERVAL="4h"

init_usage() {
    cat >&2 << 'EOF'
Usage: dotfiles init [--hosts-dir URL|PATH|none] [--hostname NAME] [--profile NAME]
                     [--update-check on|off] [--interval <n>m|h|d] [--yes] [--no-sync]
EOF
}

# Read a line from the terminal with readline: Tab completes paths, and editing keys
# work. With PREFILL (bash 4+), the line starts out holding it, to edit or accept.
# Its local has a name no caller uses, so printf -v reaches the caller's VAR.
# Usage: init_tty_read VAR PROMPT [PREFILL]
init_tty_read() {
    local var="$1" prompt="$2" prefill="${3:-}" _tty_line="" rc=0
    if [[ -n "$prefill" && "${BASH_VERSINFO[0]}" -ge 4 ]]; then
        IFS= read -e -r -p "$prompt" -i "$prefill" _tty_line </dev/tty >/dev/tty 2>/dev/tty || rc=$?
    else
        IFS= read -e -r -p "$prompt" _tty_line </dev/tty >/dev/tty 2>/dev/tty || rc=$?
    fi
    printf -v "$var" '%s' "$_tty_line"
    return "$rc"
}

# Ask for a value. Under --yes, VAR is set to DEFAULT without asking.
# Prompts go to the terminal; the answer is read from /dev/tty (stdin, with the prompt
# on stderr, when DOTFILES_INIT_ASSUME_TTY=1). An empty answer means DEFAULT; EOF exits 1.
# With PREFILL set, the default is put on the line to edit instead of shown in brackets
# (a long path is easier to change than to retype).
# Usage: init_ask VAR PROMPT DEFAULT [PREFILL]
init_ask() {
    local var="$1" prompt="$2" default="$3" prefill="${4:-}" answer=""
    if [[ "$INIT_YES" == true ]]; then
        printf -v "$var" '%s' "$default"
        return 0
    fi
    local rc=0
    if [[ "${DOTFILES_INIT_ASSUME_TTY:-}" == 1 ]]; then
        printf '%s [%s]: ' "$prompt" "$default" >&2
        IFS= read -r answer || rc=$?
    elif [[ -n "$prefill" && "${BASH_VERSINFO[0]}" -ge 4 ]]; then
        init_tty_read answer "$prompt: " "$default" || rc=$?
    else
        init_tty_read answer "$prompt [$default]: " || rc=$?
    fi
    if [[ $rc -ne 0 && -z "$answer" ]]; then
        echo >&2
        echo "init: no answer for '$prompt'" >&2
        exit 1
    fi
    answer="${answer//$'\r'/}"
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    printf -v "$var" '%s' "${answer:-$default}"
}

# Same rules as --hostname: non-empty, no '/', not '.' or '..'
# Usage: init_validate_hostname NAME
init_validate_hostname() {
    local name="$1"
    if [[ -z "$name" || "$name" == */* || "$name" == . || "$name" == .. ]]; then
        log_error "invalid hostname '$name' (must be a plain name without '/')"
        return 1
    fi
}

# True if VALUE is a git URL (has :// or is scp-like user@host:path)
init_is_url() {
    [[ "$1" == *"://"* || "$1" =~ ^[^/[:space:]]+@[^:/[:space:]]+: ]]
}

# True if URL is cloned over ssh: ssh:// or scp-like user@host:path
init_is_ssh_url() {
    [[ "$1" == ssh://* || "$1" =~ ^[^/[:space:]]+@[^:/[:space:]]+: ]]
}

# Print the host name of an ssh URL
init_ssh_url_host() {
    local host="${1#ssh://}"
    host="${host#*@}"
    host="${host%%/*}"
    echo "${host%%:*}"
}

# Print the path of the public key to use, creating ~/.ssh/id_ed25519 if the
# user has no key. It has no passphrase: the background update check fetches with
# BatchMode=yes and could not answer one. An existing key is never replaced.
init_ssh_public_key() {
    local key="$HOME/.ssh/id_ed25519" t
    for t in ed25519 ecdsa rsa; do
        if [[ -f "$HOME/.ssh/id_$t.pub" ]]; then
            echo "$HOME/.ssh/id_$t.pub"
            return 0
        fi
    done
    if [[ -e "$key" ]]; then
        log_error "$key has no public key file; create it with: ssh-keygen -y -f $key > $key.pub"
        return 1
    fi
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        log_error "ssh-keygen not found; install an ssh client"
        return 1
    fi
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" || return 1
    ssh-keygen -q -t ed25519 -N "" -C "dotfiles $(hosts_local_name)" -f "$key" </dev/null || return 1
    echo "$key.pub"
}

# Show the public key and where to add it after an ssh clone failed
# Usage: init_show_ssh_key URL
init_show_ssh_key() {
    local host pub
    host=$(init_ssh_url_host "$1")
    pub=$(init_ssh_public_key) || return 1
    echo
    if [[ "$host" == github.com ]]; then
        echo "To clone $1, add this SSH key at https://github.com/settings/keys:"
    else
        echo "To clone $1, add this SSH key to your account on $host:"
    fi
    echo
    cat "$pub"
    echo
}

# Where a hosts repo given as a URL is cloned: next to the dotfiles checkout, as
# ~/git/dotfiles and ~/git/dotfiles-hosts. A bootstrap install's checkout is
# ~/.local/share/dotfiles/dotfiles, so there it is DEFAULT_HOSTS_DIR.
init_sibling_hosts_dir() {
    echo "$(dirname "$SCRIPT_DIR")/dotfiles-hosts"
}

# Turn a hosts repo answer into INIT_HOSTS_DIR: none -> empty, a URL -> clone
# (or pull) next to the dotfiles checkout, a path -> absolute directory.
# Returns 1 for an invalid value; a failed clone exits 1.
# Usage: init_set_hosts_dir VALUE
init_set_hosts_dir() {
    local value="$1"
    if [[ "$value" == none ]]; then
        INIT_HOSTS_DIR=""
        return 0
    fi

    if init_is_url "$value"; then
        local target
        target=$(init_sibling_hosts_dir)
        if [[ -e "$target" || -L "$target" ]]; then
            local top="" origin=""
            top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)
            if [[ -n "$top" && "$(cd "$top" && pwd -P)" == "$(cd "$target" && pwd -P)" ]]; then
                origin=$(git -C "$target" config --get remote.origin.url 2>/dev/null || true)
            fi
            if [[ -z "$origin" || "$origin" != "$value" ]]; then
                log_error "$target already exists and is not a checkout of $value; leaving it." \
                    "Pass --hosts-dir $target to use it, or --hosts-dir none"
                return 1
            fi
            local reason
            if ! reason=$(sync_pull_repo "$target"); then
                log_warn "$target: pull failed ($reason); using it as it is"
            fi
        else
            log_info "Cloning $value into $target"
            mkdir -p "$(dirname "$target")"
            local -a envs=()
            [[ "$INIT_YES" == true ]] && envs=(GIT_TERMINAL_PROMPT=0)
            local retry
            while ! env ${envs[@]+"${envs[@]}"} git clone -q "$value" "$target"; do
                retry=q
                if [[ "$INIT_YES" != true ]] && init_is_ssh_url "$value" && init_show_ssh_key "$value"; then
                    init_ask retry "Press Enter to retry, or q to stop" retry
                fi
                if [[ "$retry" == q ]]; then
                    log_error "could not clone $value. Fix access to it, or run" \
                        "'dotfiles init --remote' from a machine that has the hosts repo"
                    exit 1
                fi
            done
        fi
        INIT_HOSTS_DIR="$target"
        return 0
    fi

    # A path; expand a leading ~ (answers typed at the prompt are not expanded)
    if [[ "$value" == "~" ]]; then
        value="$HOME"
    elif [[ "$value" == "~/"* ]]; then
        value="$HOME/${value#\~/}"
    fi
    if [[ ! -d "$value" ]]; then
        log_error "hosts dir not found or not a directory: $value"
        return 1
    fi
    INIT_HOSTS_DIR="$(cd "$value" && pwd)"
}

# Check the form of a profile name, without looking for the profile
# Usage: init_validate_profile_name NAME
init_validate_profile_name() {
    local name="$1"
    if [[ -z "$name" || "$name" == */* ]]; then
        log_error "invalid profile name '$name'"
        return 1
    fi
}

# Print the directory the hosts repo deploys from: its committed content, or the directory
# itself when there is no git. Nothing for no hosts repo. Fails when it can't be exported.
init_hosts_tree() {
    [[ -n "$INIT_HOSTS_DIR" ]] || return 0
    repo_committed_tree "$INIT_HOSTS_DIR"
}

# Check a profile name resolves to a profile file (hosts repo first)
# Usage: init_validate_profile NAME
init_validate_profile() {
    local name="$1" path htree dtree
    init_validate_profile_name "$name" || return 1
    # Only committed profiles deploy
    htree=$(init_hosts_tree) || return 1
    dtree=$(repo_committed_tree "$SCRIPT_DIR") || return 1
    path=$(hosts_resolve_profile_path "$dtree/profiles" "$htree" "$name")
    if [[ ! -f "$path" ]]; then
        log_error "profile '$name' not found ($path)"
        return 1
    fi
}

# Print the profile names found in the hosts repo, then the dotfiles repo,
# comma-separated without duplicates
# Usage: init_list_profiles
init_list_profiles() {
    local list="" dir f name htree dtree
    htree=$(init_hosts_tree 2>/dev/null) || htree=""
    dtree=$(repo_committed_tree "$SCRIPT_DIR" 2>/dev/null) || dtree="$SCRIPT_DIR"
    for dir in ${htree:+"$htree/profiles"} "$dtree/profiles"; do
        for f in "$dir"/*.yaml; do
            [[ -f "$f" ]] || continue
            name="${f##*/}"
            name="${name%.yaml}"
            [[ ", $list, " == *", $name, "* ]] || list+="${list:+, }$name"
        done
    done
    echo "${list:-none}"
}

# Check a yes/no answer
init_validate_yes_no() {
    case "$1" in
        y|Y|yes|Yes|YES|n|N|no|No|NO) return 0 ;;
        *) log_error "answer yes or no: $1"; return 1 ;;
    esac
}

# Create hosts/INIT_HOSTNAME/host.yaml selecting INIT_PROFILE, and commit it (only
# committed content deploys). Nothing is pushed. A hosts dir without git just gets
# the file.
init_create_host_yaml() {
    local rel="hosts/$INIT_HOSTNAME/host.yaml"
    mkdir -p "$INIT_HOSTS_DIR/hosts/$INIT_HOSTNAME" || return 1
    printf 'profile: %s\n' "$(init_yaml_value "$INIT_PROFILE")" > "$INIT_HOSTS_DIR/$rel" || return 1
    if ! git -C "$INIT_HOSTS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Created $rel in $INIT_HOSTS_DIR"
        return 0
    fi
    if ! git -C "$INIT_HOSTS_DIR" add -- "$rel" ||
       ! git -C "$INIT_HOSTS_DIR" commit -q -m "hosts: add $INIT_HOSTNAME (profile: $INIT_PROFILE)" -- "$rel"; then
        log_error "could not commit $rel in $INIT_HOSTS_DIR"
        return 1
    fi
    echo "Created and committed $rel in $INIT_HOSTS_DIR. Push it so it isn't lost: git -C $INIT_HOSTS_DIR push"
}

# Check an update check value: on or off
init_validate_update_check() {
    case "$1" in
        on|off) return 0 ;;
        *) log_error "update check must be 'on' or 'off': $1"; return 1 ;;
    esac
}

# Check an interval: <n>m, <n>h or <n>d
init_validate_interval() {
    config_interval_seconds "$1" >/dev/null && return 0
    log_error "interval must be <n>m, <n>h or <n>d: $1"
    return 1
}

# Get one value: the flag if given, else ask with DEFAULT. CHECK (a command
# taking the value) validates it; an invalid answer is asked again, an invalid
# flag or --yes value exits 1.
# Usage: init_choose VAR FLAG_VALUE FLAG_GIVEN PROMPT DEFAULT CHECK
init_choose() {
    local var="$1" flag_value="$2" flag_given="$3" prompt="$4" default="$5" check="$6" prefill="${7:-}"
    local value
    while true; do
        if [[ "$flag_given" == true ]]; then
            value="$flag_value"
        else
            init_ask value "$prompt" "$default" "$prefill"
            # A wrong answer is asked again with what was typed, to fix it
            [[ -z "$prefill" ]] || default="$value"
        fi
        if "$check" "$value"; then
            printf -v "$var" '%s' "$value"
            return 0
        fi
        [[ "$flag_given" != true && "$INIT_YES" != true ]] || exit 1
    done
}

# Format a config value; quoted when a bare value would be misread
init_yaml_value() {
    local v="$1"
    if [[ "$v" == *"#"* || "$v" == [\"\']* || "$v" == *[[:space:]] ]]; then
        printf '"%s"' "$v"
    else
        printf '%s' "$v"
    fi
}

# Write the config from the INIT_* globals: to FILE.tmp, then moved into place.
# An existing FILE that differs (ignoring the header date) is kept as FILE.bak.
# Sets INIT_BACKED_UP=true when a backup was made.
# Usage: init_write_config FILE
INIT_BACKED_UP=false
init_write_config() {
    local file="$1" tmp="$1.tmp"
    INIT_BACKED_UP=false
    mkdir -p "$(dirname "$file")"
    {
        echo "# Written by dotfiles init on $(date -u +%Y-%m-%d)"
        if [[ -n "$INIT_HOSTS_DIR" ]]; then
            echo "hosts_dir: $(init_yaml_value "$INIT_HOSTS_DIR")"
        else
            echo "# hosts_dir:"
        fi
        echo "hostname: $(init_yaml_value "$INIT_HOSTNAME")"
        if [[ "$INIT_PROFILE_COMMENTED" == true ]]; then
            echo "# profile: $(init_yaml_value "$INIT_PROFILE")  # hosts/$INIT_HOSTNAME/host.yaml selects the profile"
        else
            echo "profile: $(init_yaml_value "$INIT_PROFILE")"
        fi
        echo "update_check: $INIT_UPDATE_CHECK"
        echo "update_check_interval: $INIT_INTERVAL"
    } > "$tmp"

    if [[ -f "$file" ]] && ! cmp -s <(grep -v '^# Written by dotfiles init on ' "$file") \
                                    <(grep -v '^# Written by dotfiles init on ' "$tmp"); then
        cp -p "$file" "$file.bak"
        INIT_BACKED_UP=true
    fi
    mv "$tmp" "$file"
}

# Read one line for a question about a reset. Unlike init_ask, no answer is not an
# error: EOF, or a terminal that can't be read, returns 1 with VAR empty, and the caller
# takes that as no.
# Usage: init_read_line VAR PROMPT
init_read_line() {
    local var="$1" line_in="" rc=0
    if [[ "${DOTFILES_INIT_ASSUME_TTY:-}" == 1 ]]; then
        printf '%s' "$2" >&2
        IFS= read -r line_in || rc=$?
    else
        init_tty_read line_in "$2" 2>/dev/null || rc=$?
    fi
    if [[ $rc -ne 0 && -z "$line_in" ]]; then
        echo >&2
        printf -v "$var" '%s' ""
        return 1
    fi
    line_in="${line_in//$'\r'/}"
    line_in="${line_in#"${line_in%%[![:space:]]*}"}"
    line_in="${line_in%"${line_in##*[![:space:]]}"}"
    printf -v "$var" '%s' "$line_in"
}

# The src and dest of each file an app's config.yaml deploys, as SRC<TAB>DEST lines
# Usage: init_config_dests CONFIG_YAML
init_config_dests() {
    local line src="" d in_files=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^files: ]]; then
            in_files=true
            continue
        fi
        [[ "$in_files" == true ]] || continue
        [[ "$line" =~ ^[[:alpha:]] ]] && break
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*src:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
            src="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*dest:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
            d="${BASH_REMATCH[1]}"
            d="${d//\$\{SHELL_SCRIPTS_DIR\}/$SHELL_SCRIPTS_DIR}"
            printf '%s\t%s\n' "$src" "$(abs_path "$d")"
        fi
    done < "$1"
}

# What this profile manages, from the config just written, one per line, tab separated:
#   app NAME           an app that deploys files, or a tool with a drop-in
#   config APP DEST    a file a profile app deploys
#   dropin APP DEST    a drop-in
#   unrecorded DEST    a file there with no record of what dotfiles wrote, that differs
#                      from what would deploy: a reset overwrites it
# Nothing, and a failure, when the profile or its overlays can't be loaded.
init_profile_info() {
    (
        resolve_settings >/dev/null 2>&1 || exit 1
        OVERLAY_HOST="${HOSTNAME_ARG:-$(hosts_local_name)}"
        load_packages_for_profile "$PROFILE_ARG" "$OVERLAY_HOST" >/dev/null 2>&1 || exit 1
        prepare_overlays reset >/dev/null 2>&1 || exit 1
        profile_app_names
        local idx dir app stage src dest stage_file reason unit_dir
        for idx in "${!PKG_NAMES[@]}"; do
            dir="${PKG_CONFIG_DIR[$idx]}"
            [[ -n "$dir" && -f "$APPS_DIR/$dir/config.yaml" ]] || continue
            app=$(add_app_name "$dir")
            stage="$STAGE_ROOT/apps/$dir"
            overlay_stage_app "$APPS_DIR/$dir" "$stage" "$STRATEGIES_FILE" "${LAYER_ROOTS[@]}" >/dev/null 2>&1 || exit 1
            while IFS=$'\t' read -r src dest; do
                printf 'config\t%s\t%s\n' "$app" "$dest"
                [[ -f "$dest" && -f "$stage/files/$src" ]] || continue
                ! grep -qxF "$src" "$stage/skip" || continue
                records_knows_dest "$dest" || cmp -s "$dest" "$stage/files/$src" || printf 'unrecorded\t%s\n' "$dest"
            done < <(init_config_dests "$APPS_DIR/$dir/config.yaml")
        done
        while IFS=$'\t' read -r app unit_dir src dest stage_file reason; do
            printf 'dropin\t%s\t%s\n' "$app" "$dest"
            [[ -f "$dest" && "$stage_file" != "-" && -f "$stage_file" ]] || continue
            records_knows_dest "$dest" || cmp -s "$dest" "$stage_file" || printf 'unrecorded\t%s\n' "$dest"
        done < <(add_dropin_units 2>/dev/null)
    )
}

# Every managed file there is a trace of, as APP<TAB>DEST lines: the records, the old
# records, the files the state names, and this profile's drop-ins.
# Usage: init_managed_files
init_managed_files() {
    local dir app src dest strategy hash f line kind
    for dir in "$STATE_DIR"/records/*/; do
        [[ -f "$dir/manifest.tsv" ]] || continue
        app=$(basename "$dir")
        while IFS=$'\t' read -r src dest strategy; do
            printf '%s\t%s\n' "$app" "$dest"
        done < "$dir/manifest.tsv"
    done
    for f in "$STATE_DIR"/deployed/*.tsv; do
        [[ -f "$f" ]] || continue
        app=$(basename "$f" .tsv)
        while IFS=$'\t' read -r hash src dest; do
            [[ -z "$dest" ]] || printf '%s\t%s\n' "$app" "$dest"
        done < "$f"
    done
    for f in "$STATE_DIR"/apps/*.yaml; do
        [[ -f "$f" ]] || continue
        app=$(basename "$f" .yaml)
        while IFS= read -r line; do
            [[ -z "$line" ]] || printf '%s\t%s\n' "$app" "$line"
        done < <(state_get_files "$app" 2>/dev/null || true)
    done
    while IFS=$'\t' read -r kind app dest; do
        [[ "$kind" == dropin || "$kind" == config ]] || continue
        printf '%s\t%s\n' "$app" "$dest"
    done < <(init_profile_info || true)
}

# One snapshot of every managed file that exists, before anything changes. Each app's
# files go to its own backup folder, as the installers' snapshots do. Returns 1 if one
# can't be taken, with nothing else changed.
# Usage: init_snapshot_managed
init_snapshot_managed() {
    local ts line app dest dir="" last="" taken=false key
    local -a pairs=()
    local -A seen=()
    ts=$(timestamp)
    mapfile -t pairs < <(init_managed_files | sort -u)
    # A snapshot keeps files by name: two files of one app with the same name would share
    # a path, and one would be lost. Stop before anything is taken or changed.
    for line in ${pairs[@]+"${pairs[@]}"}; do
        app="${line%%$'\t'*}"
        dest="${line#*$'\t'}"
        [[ -f "$dest" ]] || continue
        key="$app/$(basename "$dest")"
        if [[ -n "${seen[$key]:-}" && "${seen[$key]}" != "$dest" ]]; then
            log_error "$app has two managed files named $(basename "$dest") (${seen[$key]} and $dest)," \
                "which would share one snapshot path; nothing was changed"
            return 1
        fi
        seen[$key]="$dest"
    done
    for line in ${pairs[@]+"${pairs[@]}"}; do
        app="${line%%$'\t'*}"
        dest="${line#*$'\t'}"
        [[ -f "$dest" ]] || continue
        if [[ "$app" != "$last" ]]; then
            if [[ "$taken" == true ]]; then
                state_add_snapshot "$last" "$ts" 2>/dev/null || true
                echo "Snapshot of the $last files: $(add_tilde "$dir/$ts")"
            fi
            dir=""
            if state_is_installed "$app"; then
                dir=$(state_get_backup_dir "$app" 2>/dev/null || true)
            fi
            [[ -n "$dir" ]] || dir="$HOME/.bak/$app"
            if ! backup_init "$app" "$dir"; then
                log_error "Could not set up $dir for the snapshot"
                return 1
            fi
            last="$app"
            taken=false
        fi
        if ! backup_create_snapshot "$dest" "$dir" "$ts" >/dev/null; then
            log_error "Could not take a snapshot of $dest"
            return 1
        fi
        taken=true
    done
    if [[ "$taken" == true ]]; then
        state_add_snapshot "$last" "$ts" 2>/dev/null || true
        echo "Snapshot of the $last files: $(add_tilde "$dir/$ts")"
    fi
    return 0
}

# Print what a reset would lose: the unreviewed, conflicting and dismissed changes status
# reports, the keys only this host has in merged files, and the files of apps this profile
# no longer manages, which a reset leaves alone but stops tracking.
# Usage: init_reset_summary
init_reset_summary() {
    local n=0 dir app src dest strategy repo keys key info items lines="" kind
    # Status knows which is which, against the content that would deploy
    if [[ -n "$INIT_LOST_REPORT" ]]; then
        printf '%s\n' "$INIT_LOST_REPORT"
        n=$((n + 1))
    fi
    info=$(init_profile_info 2>/dev/null) || info=""

    # Keys only this host has, in files that were deployed as a merge: the record holds
    # what the repo had
    for dir in "$STATE_DIR"/records/*/; do
        [[ -f "$dir/manifest.tsv" ]] || continue
        app=$(basename "$dir")
        while IFS=$'\t' read -r src dest strategy; do
            [[ "$strategy" == merge && -f "$dest" ]] || continue
            repo="$STATE_DIR/records/$app/repo/$src"
            [[ -r "$repo" ]] || continue
            keys=$(jq -nr --slurpfile l "$dest" --slurpfile b "$repo" '
                def lo($l; $b; $p):
                  if ($l | type) == "object" and ($b | type) == "object" then
                    ($l | keys_unsorted[]) as $k
                    | if $b | has($k) then lo($l[$k]; $b[$k]; $p + [$k]) else ($p + [$k] | tojson) end
                  else empty end;
                lo($l[0]; $b[0]; [])' 2>/dev/null) || keys=""
            [[ -n "$keys" ]] || continue
            echo "local-only keys, not in the repo's last deployed version (a reset removes them):"
            while IFS= read -r key; do
                printf '  %s  key %s\n' "$(add_tilde "$dest")" "$key"
            done <<< "$keys"
            n=$((n + 1))
        done < "$dir/manifest.tsv"
    done

    # Files dotfiles never wrote, that the reset overwrites: no record, so nothing above
    # could name them
    lines=""
    while IFS=$'\t' read -r kind dest; do
        [[ "$kind" != unrecorded ]] || lines+="  $(add_tilde "$dest")"$'\n'
    done <<< "$info"
    if [[ -n "$lines" ]]; then
        echo "files dotfiles has no record of writing, that differ from the repo's (a reset overwrites them):"
        printf '%s' "$lines"
        n=$((n + 1))
    fi
    lines=""

    # Apps this profile doesn't manage
    if [[ -n "$info" ]]; then
        info+=$'\n'
        for dir in "$STATE_DIR"/records/*/; do
            [[ -f "$dir/manifest.tsv" ]] || continue
            app=$(basename "$dir")
            [[ $'\n'"$info" != *$'\n'"app"$'\t'"$app"$'\n'* && $'\n'"$info" != *$'\n'"dropin"$'\t'"$app"$'\t'* ]] || continue
            while IFS=$'\t' read -r src dest strategy; do
                [[ -e "$dest" ]] || continue
                items=$(records_items "$app" "$src" "$dest" "" true 2>/dev/null) || items=edited
                [[ -z "$items" ]] || lines+="  $(add_tilde "$dest")  ($app)"$'\n'
            done < "$dir/manifest.tsv"
        done
        if [[ -n "$lines" ]]; then
            echo "files of apps this profile doesn't manage, with local edits (left in place, no longer tracked):"
            printf '%s' "$lines"
            n=$((n + 1))
        fi
    fi
    [[ $n -gt 0 ]] || echo "no local changes would be lost"
}

# What status says about local changes, in INIT_LOST_REPORT: the unreviewed, conflicting,
# dismissed, saved-not-committed and held-lower lists, without status' notes. Returns 1 when status
# can't tell (it prints no such section when the profile or overlays don't load).
INIT_LOST_REPORT=""
init_status_report() {
    local out
    INIT_LOST_REPORT=""
    out=$("$DOTFILES_REPO/dotfiles" status 2>/dev/null </dev/null) || out=""
    grep -q '^unreviewed changes:' <<< "$out" || return 1
    INIT_LOST_REPORT=$(awk '
        /^[^ ]/ {
            show = ($0 ~ /^(unreviewed changes|conflicts|dismissed|saved, not committed|held in a lower layer):  \(/)
            if (show) sub(/:  \(.*$/, ":")
        }
        show { print }' <<< "$out")
}

# Bring the repos up to date the way pull does (fast-forward only), before a reset is listed
# and snapshotted: the pull that follows must not find anything new to manage. A blocked
# update (diverged, or local changes in the way) stops with nothing changed; a failure like
# the network is a warning, and the reset is judged on what is here. A pinned checkout and a
# repo with no git don't move.
init_update_repos() {
    local repo reason rc
    if ! sync_lock; then
        echo "dotfiles: pull already running" >&2
        exit 1
    fi
    for repo in "$DOTFILES_REPO" ${INIT_HOSTS_DIR:+"$INIT_HOSTS_DIR"}; do
        rc=0
        reason=$(sync_pull_repo "$repo") || rc=$?
        [[ $rc -ne 0 ]] || continue
        if [[ $rc -eq 2 ]]; then
            log_error "$repo: pull blocked ($reason); nothing was deployed, but the settings are saved"
            echo "Commit or set aside your changes there, then bring it up to date:" >&2
            echo "  cd $repo && git pull --rebase" >&2
            echo "Push if the repo has commits of its own, then run: dotfiles init" >&2
            exit 1
        fi
        log_warn "$repo: pull failed ($reason); a reset would be judged on what is here"
    done
    sync_unlock
    # Exports of the committed content made before the update are out of date
    rm -rf "${WORK_DIR:?}/export"
}

# Ask whether to reset. Returns 0 only when confirmed: the question defaults to no, and
# anything but 'reset' at the confirmation cancels.
init_confirm_reset() {
    local answer=""
    init_read_line answer "Reset every managed file to the repo layers? [no]: " || return 1
    case "$answer" in
        y|Y|yes|YES|Yes) ;;
        *) return 1 ;;
    esac
    {
        echo "A reset replaces every managed file with what the repo layers deploy, and starts fresh records."
        echo "This would be lost:"
        init_reset_summary
        echo "00-local.sh and .gitconfig.local are not touched. A snapshot of every managed file is taken first."
    } >&2
    init_read_line answer "Type 'reset' to go ahead: " || return 1
    [[ "$answer" == reset ]]
}

# dotfiles init [flags]: exits with init's exit code
init_main() {
    local f_hosts="" f_hostname="" f_profile="" f_update="" f_interval=""
    local g_hosts=false g_hostname=false g_profile=false g_update=false g_interval=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hosts-dir|--hostname|--profile|--update-check|--interval)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: $1 requires a value" >&2
                    init_usage
                    exit 1
                fi
                case "$1" in
                    --hosts-dir) f_hosts="$2"; g_hosts=true ;;
                    --hostname) f_hostname="$2"; g_hostname=true ;;
                    --profile) f_profile="$2"; g_profile=true ;;
                    --update-check) f_update="$2"; g_update=true ;;
                    --interval) f_interval="$2"; g_interval=true ;;
                esac
                shift 2
                ;;
            --yes) INIT_YES=true; shift ;;
            --no-sync) INIT_NO_SYNC=true; shift ;;
            -h|--help) init_usage; exit 0 ;;
            *)
                echo "Error: Unknown init option: $1" >&2
                init_usage
                exit 1
                ;;
        esac
    done

    if [[ "$INIT_YES" != true && ! -t 0 && "${DOTFILES_INIT_ASSUME_TTY:-}" != 1 ]]; then
        echo "init is interactive; pass --yes to accept defaults" >&2
        exit 1
    fi

    DOTFILES_REPO="$SCRIPT_DIR"
    local config_file="${DOTFILES_CONFIG:-$HOME/.config/dotfiles/config.yaml}"

    # Defaults: the existing config (invalid values fall back to the built-in defaults)
    if ! config_load "$config_file"; then
        log_warn "$config_file has invalid values; using defaults for them"
    fi
    # A hosts repo next to this checkout, or where an older init cloned one
    local d_hosts="none"
    if [[ -n "$CFG_HOSTS_DIR" ]]; then
        d_hosts="$CFG_HOSTS_DIR"
    elif [[ -d "$(init_sibling_hosts_dir)" ]]; then
        d_hosts="$(init_sibling_hosts_dir)"
    elif [[ -d "$DEFAULT_HOSTS_DIR" ]]; then
        d_hosts="$DEFAULT_HOSTS_DIR"
    fi
    local d_hostname="${CFG_HOSTNAME:-$(hosts_local_name)}"
    local d_profile="${CFG_PROFILE:-complete}"

    # Hosts repo
    local hosts_answer
    init_choose hosts_answer "$f_hosts" "$g_hosts" \
        "Hosts repo (none, a git URL or a path)" "$d_hosts" init_set_hosts_dir prefill

    # Hostname
    init_choose INIT_HOSTNAME "$f_hostname" "$g_hostname" "Hostname" "$d_hostname" init_validate_hostname prefill
    local host_yaml=""
    if [[ -n "$INIT_HOSTS_DIR" ]]; then
        # Only committed content deploys, so that is what selects the profile
        local htree
        htree=$(init_hosts_tree) || exit 1
        if [[ -f "$htree/hosts/$INIT_HOSTNAME/host.yaml" ]]; then
            host_yaml="$htree/hosts/$INIT_HOSTNAME/host.yaml"
            echo "hosts/$INIT_HOSTNAME/host.yaml found (profile: $(hosts_read_scalar "$host_yaml" profile))"
        elif [[ -f "$INIT_HOSTS_DIR/hosts/$INIT_HOSTNAME/host.yaml" ]]; then
            log_error "hosts/$INIT_HOSTNAME/host.yaml in $INIT_HOSTS_DIR is not committed, so a pull would not use it."
            echo "Commit it, then run init again." >&2
            exit 1
        else
            echo "No hosts/$INIT_HOSTNAME/host.yaml in $INIT_HOSTS_DIR yet"
        fi
    fi

    # Profile: asked only when no host.yaml selects it. With a host.yaml, an
    # explicit profile (--profile, or an uncommented profile: in the existing
    # config) still overrides it at sync time, so it is kept uncommented.
    if [[ -n "$host_yaml" ]]; then
        if [[ "$g_profile" == true || -n "$CFG_PROFILE" ]]; then
            INIT_PROFILE_COMMENTED=false
            init_choose INIT_PROFILE "${f_profile:-$CFG_PROFILE}" true "Profile" "" init_validate_profile
            log_warn "profile '$INIT_PROFILE' overrides profile '$(hosts_read_scalar "$host_yaml" profile)'" \
                "from hosts/$INIT_HOSTNAME/host.yaml"
        else
            INIT_PROFILE_COMMENTED=true
            INIT_PROFILE="$d_profile"
        fi
    else
        INIT_PROFILE_COMMENTED=false
        [[ "$g_profile" == true || "$INIT_YES" == true ]] || echo "profiles: $(init_list_profiles)"
        init_choose INIT_PROFILE "$f_profile" "$g_profile" "Profile" "$d_profile" init_validate_profile
        # Offer this host its own entry, which then selects the profile. Not under
        # --yes: that never writes to the hosts repo.
        if [[ -n "$INIT_HOSTS_DIR" && "$INIT_YES" != true ]]; then
            local create
            init_choose create "" false \
                "Create hosts/$INIT_HOSTNAME/host.yaml with profile: $INIT_PROFILE (yes/no)" yes init_validate_yes_no
            if [[ "$create" == [yY]* ]]; then
                init_create_host_yaml || exit 1
                INIT_PROFILE_COMMENTED=true
            fi
        fi
    fi

    # Update check
    init_choose INIT_UPDATE_CHECK "$f_update" "$g_update" "Update check (on/off)" \
        "$CFG_UPDATE_CHECK" init_validate_update_check
    # The interval is only asked when the check is on; off keeps the saved one
    if [[ "$INIT_UPDATE_CHECK" == on || "$g_interval" == true ]]; then
        init_choose INIT_INTERVAL "$f_interval" "$g_interval" "Update check interval (<n>m|h|d)" \
            "$CFG_UPDATE_CHECK_INTERVAL" init_validate_interval
    else
        INIT_INTERVAL="$CFG_UPDATE_CHECK_INTERVAL"
    fi

    init_write_config "$config_file"
    echo "Wrote $config_file"
    [[ "$INIT_BACKED_UP" != true ]] || echo "previous config saved as $config_file.bak"

    local rc=0
    if [[ "$INIT_NO_SYNC" != true ]]; then
        local reset=false
        if compgen -G "$STATE_DIR/deployed/*.tsv" >/dev/null; then
            # Records from an older version: no reset to offer. Everything managed is
            # snapshotted, then the old records go and the pull deploys fresh ones.
            echo "This host has records from an older version. Taking a snapshot of every managed file," \
                "then starting fresh records: replaced files take the repo's version, merged files keep your own keys."
            if ! init_snapshot_managed; then
                log_error "Could not take a snapshot of the managed files, so nothing was changed"
                exit 1
            fi
            rm -rf "${STATE_DIR:?}/deployed"
            sync_forget_complete
        elif [[ "$INIT_YES" != true ]] && records_any; then
            init_update_repos
            if ! init_status_report; then
                log_warn "Can't tell what a reset would lose: 'dotfiles status' can't load the profile and overlays." \
                    "No reset is offered; running a normal pull. Fix the configuration and run init again to reset"
            elif init_confirm_reset; then
                if ! init_snapshot_managed; then
                    log_error "Could not take a snapshot of the managed files, so nothing was reset"
                    exit 1
                fi
                reset=true
            else
                echo "Not resetting; running a normal pull" >&2
            fi
        fi
        if [[ "$reset" == true ]]; then
            # The repos were updated above, before the summary and the snapshot
            DOTFILES_RESET=1 DOTFILES_RESET_SNAPSHOTTED=1 "$DOTFILES_REPO/dotfiles" pull --no-fetch || rc=$?
        else
            env -u DOTFILES_RESET "$DOTFILES_REPO/dotfiles" pull || rc=$?
        fi
    fi

    # host.yaml selects the profile only when no explicit profile overrides it
    local how="profile $INIT_PROFILE"
    [[ -z "$host_yaml" || "$INIT_PROFILE_COMMENTED" != true ]] || how="host.yaml"
    echo "dotfiles: $INIT_HOSTNAME configured ($how)"
    if [[ "$INIT_UPDATE_CHECK" == on ]]; then
        echo "update check every $INIT_INTERVAL"
    else
        echo "update check off"
    fi
    echo "open a new terminal to load the new shell setup"
    exit $rc
}
