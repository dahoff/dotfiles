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
INIT_AUTO_SYNC="on"
INIT_INTERVAL="4h"

init_usage() {
    cat >&2 << 'EOF'
Usage: dotfiles init [--hosts-dir URL|PATH|none] [--hostname NAME] [--profile NAME]
                     [--auto-sync on|off] [--interval <n>m|h|d] [--yes] [--no-sync]
EOF
}

# Ask for a value. Under --yes, VAR is set to DEFAULT without asking.
# Prompts go to stderr; the answer is read from /dev/tty (stdin when
# DOTFILES_INIT_ASSUME_TTY=1). An empty answer means DEFAULT; EOF exits 1.
# Usage: init_ask VAR PROMPT DEFAULT
init_ask() {
    local var="$1" prompt="$2" default="$3" answer=""
    if [[ "$INIT_YES" == true ]]; then
        printf -v "$var" '%s' "$default"
        return 0
    fi
    printf '%s [%s]: ' "$prompt" "$default" >&2
    local rc=0
    if [[ "${DOTFILES_INIT_ASSUME_TTY:-}" == 1 ]]; then
        IFS= read -r answer || rc=$?
    else
        IFS= read -r answer </dev/tty || rc=$?
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
# user has no key. It has no passphrase: background sync pulls with
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

# Turn a hosts repo answer into INIT_HOSTS_DIR: none -> empty, a URL -> clone
# (or pull) at DEFAULT_HOSTS_DIR, a path -> absolute directory.
# Returns 1 for an invalid value; a failed clone exits 1.
# Usage: init_set_hosts_dir VALUE
init_set_hosts_dir() {
    local value="$1"
    if [[ "$value" == none ]]; then
        INIT_HOSTS_DIR=""
        return 0
    fi

    if init_is_url "$value"; then
        local target="$DEFAULT_HOSTS_DIR"
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

# Check a profile name resolves to a profile file (hosts repo first)
# Usage: init_validate_profile NAME
init_validate_profile() {
    local name="$1" path
    init_validate_profile_name "$name" || return 1
    path=$(hosts_resolve_profile_path "$PROFILES_DIR" "$INIT_HOSTS_DIR" "$name")
    if [[ ! -f "$path" ]]; then
        log_error "profile '$name' not found ($path)"
        return 1
    fi
}

# Print the profile names found in the hosts repo, then the dotfiles repo,
# comma-separated without duplicates
# Usage: init_list_profiles
init_list_profiles() {
    local list="" dir f name
    for dir in ${INIT_HOSTS_DIR:+"$INIT_HOSTS_DIR/profiles"} "$PROFILES_DIR"; do
        for f in "$dir"/*.yaml; do
            [[ -f "$f" ]] || continue
            name="${f##*/}"
            name="${name%.yaml}"
            [[ ", $list, " == *", $name, "* ]] || list+="${list:+, }$name"
        done
    done
    echo "${list:-none}"
}

# Check an auto sync value: on or off
init_validate_auto_sync() {
    case "$1" in
        on|off) return 0 ;;
        *) log_error "auto sync must be 'on' or 'off': $1"; return 1 ;;
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
    local var="$1" flag_value="$2" flag_given="$3" prompt="$4" default="$5" check="$6"
    local value
    while true; do
        if [[ "$flag_given" == true ]]; then
            value="$flag_value"
        else
            init_ask value "$prompt" "$default"
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
        echo "auto_sync: $INIT_AUTO_SYNC"
        echo "auto_sync_interval: $INIT_INTERVAL"
    } > "$tmp"

    if [[ -f "$file" ]] && ! cmp -s <(grep -v '^# Written by dotfiles init on ' "$file") \
                                    <(grep -v '^# Written by dotfiles init on ' "$tmp"); then
        cp -p "$file" "$file.bak"
        INIT_BACKED_UP=true
    fi
    mv "$tmp" "$file"
}

# dotfiles init [flags]: exits with init's exit code
init_main() {
    local f_hosts="" f_hostname="" f_profile="" f_auto="" f_interval=""
    local g_hosts=false g_hostname=false g_profile=false g_auto=false g_interval=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hosts-dir|--hostname|--profile|--auto-sync|--interval)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: $1 requires a value" >&2
                    init_usage
                    exit 1
                fi
                case "$1" in
                    --hosts-dir) f_hosts="$2"; g_hosts=true ;;
                    --hostname) f_hostname="$2"; g_hostname=true ;;
                    --profile) f_profile="$2"; g_profile=true ;;
                    --auto-sync) f_auto="$2"; g_auto=true ;;
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
    local d_hosts="none"
    if [[ -n "$CFG_HOSTS_DIR" ]]; then
        d_hosts="$CFG_HOSTS_DIR"
    elif [[ -d "$DEFAULT_HOSTS_DIR" ]]; then
        d_hosts="$DEFAULT_HOSTS_DIR"
    fi
    local d_hostname="${CFG_HOSTNAME:-$(hosts_local_name)}"
    local d_profile="${CFG_PROFILE:-complete}"

    # Hosts repo
    local hosts_answer
    init_choose hosts_answer "$f_hosts" "$g_hosts" \
        "Hosts repo (none, a git URL or a path)" "$d_hosts" init_set_hosts_dir

    # Hostname
    init_choose INIT_HOSTNAME "$f_hostname" "$g_hostname" "Hostname" "$d_hostname" init_validate_hostname
    local host_yaml=""
    if [[ -n "$INIT_HOSTS_DIR" ]]; then
        if [[ -f "$INIT_HOSTS_DIR/hosts/$INIT_HOSTNAME/host.yaml" ]]; then
            host_yaml="$INIT_HOSTS_DIR/hosts/$INIT_HOSTNAME/host.yaml"
            echo "hosts/$INIT_HOSTNAME/host.yaml found (profile: $(hosts_read_scalar "$host_yaml" profile))"
        else
            local available="" d
            for d in "$INIT_HOSTS_DIR"/hosts/*/; do
                [[ -d "$d" ]] || continue
                d="${d%/}"
                available+="${available:+, }${d##*/}"
            done
            echo "no hosts/$INIT_HOSTNAME/ in $INIT_HOSTS_DIR; available: ${available:-none}"
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
    fi

    # Background sync
    init_choose INIT_AUTO_SYNC "$f_auto" "$g_auto" "Background sync (on/off)" \
        "$CFG_AUTO_SYNC" init_validate_auto_sync
    init_choose INIT_INTERVAL "$f_interval" "$g_interval" "Background sync interval (<n>m|h|d)" \
        "$CFG_AUTO_SYNC_INTERVAL" init_validate_interval

    init_write_config "$config_file"
    echo "Wrote $config_file"
    [[ "$INIT_BACKED_UP" != true ]] || echo "previous config saved as $config_file.bak"

    local rc=0
    if [[ "$INIT_NO_SYNC" != true ]]; then
        "$DOTFILES_REPO/dotfiles" pull || rc=$?
    fi

    # host.yaml selects the profile only when no explicit profile overrides it
    local how="profile $INIT_PROFILE"
    [[ -z "$host_yaml" || "$INIT_PROFILE_COMMENTED" != true ]] || how="host.yaml"
    echo "dotfiles: $INIT_HOSTNAME configured ($how)"
    if [[ "$INIT_AUTO_SYNC" == on ]]; then
        echo "background sync every $INIT_INTERVAL"
    else
        echo "background sync off"
    fi
    echo "open a new terminal to load the new shell setup"
    exit $rc
}
