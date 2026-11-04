#!/usr/bin/env bash
# profile.sh - Profile resolution, package manifest and overlay preparation
# Sourced by dotfiles. Uses globals declared there: PROFILES_DIR, HOSTS_DIR,
# PKG_* arrays, RESOLVED_PROFILE, HOSTS_PROFILE_CHAIN, HOST_YAML, STAGE_ROOT,
# STRATEGIES_FILE, LAYER_ROOTS, WORK_DIR, SCRIPT_DIR.

# Reset all package arrays
reset_pkg_arrays() {
    PKG_NAMES=()
    PKG_APT=()
    PKG_DNF=()
    PKG_BREW=()
    PKG_CUSTOM_CHECK=()
    PKG_CUSTOM_SCRIPT=()
    PKG_CUSTOM_DROPIN=()
    PKG_CONFIG_DIR=()
    PKG_CONFIG_FLAGS=()
}

# Definitions from apps/os-packages.yaml, loaded once
declare -A OSPKG_APT=() OSPKG_DNF=() OSPKG_BREW=()
OSPKG_LOADED=false

# Append one tool to the PKG_* arrays
# Usage: pkg_append name apt dnf brew check script dropin config_dir config_flags
pkg_append() {
    PKG_NAMES+=("$1")
    PKG_APT+=("$2")
    PKG_DNF+=("$3")
    PKG_BREW+=("$4")
    PKG_CUSTOM_CHECK+=("$5")
    PKG_CUSTOM_SCRIPT+=("$6")
    PKG_CUSTOM_DROPIN+=("$7")
    PKG_CONFIG_DIR+=("$8")
    PKG_CONFIG_FLAGS+=("$9")
}

# Load apps/os-packages.yaml into the OSPKG_* maps. A missing file is fine.
load_os_packages() {
    [[ "$OSPKG_LOADED" == true ]] && return 0
    OSPKG_LOADED=true

    local file="$APPS_DIR/os-packages.yaml"
    [[ -f "$file" ]] || return 0

    # Parse into local arrays, leaving the caller's PKG_* alone
    local -a PKG_NAMES=() PKG_APT=() PKG_DNF=() PKG_BREW=()
    local -a PKG_CUSTOM_CHECK=() PKG_CUSTOM_SCRIPT=() PKG_CUSTOM_DROPIN=()
    local -a PKG_CONFIG_DIR=() PKG_CONFIG_FLAGS=()
    load_manifest "$file" "$file" true || return 1

    local idx name
    for idx in "${!PKG_NAMES[@]}"; do
        name="${PKG_NAMES[$idx]}"
        OSPKG_APT["$name"]="${PKG_APT[$idx]}"
        OSPKG_DNF["$name"]="${PKG_DNF[$idx]}"
        OSPKG_BREW["$name"]="${PKG_BREW[$idx]}"
    done
}

# Append the tool NAME, defined by a folder in apps/ or by os-packages.yaml, to
# the PKG_* arrays. Logs an error naming SOURCE and returns 1 if it can't.
# Usage: resolve_tool name source
resolve_tool() {
    local name="$1" source="$2"
    local dir="$APPS_DIR/$name" in_folder=false in_os=false

    if [[ "$name" != */* && "$name" != . && "$name" != .. ]]; then
        [[ -f "$dir/config.yaml" ]] && in_folder=true
        [[ -n "${OSPKG_APT[$name]+x}" ]] && in_os=true
    fi

    if [[ "$in_folder" == true && "$in_os" == true ]]; then
        log_error "Tool '$name' in $source is defined twice: apps/$name/ and apps/os-packages.yaml"
        return 1
    fi
    if [[ "$in_os" == true ]]; then
        pkg_append "$name" "${OSPKG_APT[$name]}" "${OSPKG_DNF[$name]}" "${OSPKG_BREW[$name]}" "" "" "" "" ""
        return 0
    fi
    if [[ "$in_folder" != true ]]; then
        log_error "Unknown tool '$name' in $source: no apps/$name/config.yaml, and not in apps/os-packages.yaml"
        return 1
    fi

    # The install: section of the tool's config.yaml
    local line key value in_install=false
    local apt="" dnf="" brew="" check="" dropin="" flags=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^install:[[:space:]]*$ ]]; then
            in_install=true
        elif [[ "$line" =~ ^[[:alpha:]] ]]; then
            in_install=false
        elif [[ "$in_install" == true && "$line" =~ ^[[:space:]]+(apt|dnf|brew|check|dropin|configure_flags):[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%%[[:space:]]#*}"
            value="${value%"${value##*[![:space:]]}"}"
            case "$key" in
                apt) apt="$value" ;;
                dnf) dnf="$value" ;;
                brew) brew="$value" ;;
                check) check="$value" ;;
                dropin) dropin="$value" ;;
                configure_flags) flags="$value" ;;
            esac
        fi
    done < "$dir/config.yaml"

    local script="" config_dir=""
    if [[ -f "$dir/install.sh" ]]; then
        if [[ -z "$check" ]]; then
            log_error "Tool '$name' in $source: apps/$name/install.sh needs install.check in its config.yaml"
            return 1
        fi
        script="$name/install.sh"
    fi
    [[ -f "$dir/configure.sh" ]] && config_dir="$name"
    [[ -n "$dropin" ]] && dropin="$name/$dropin"

    pkg_append "$name" "$apt" "$dnf" "$brew" "$check" "$script" "$dropin" "$config_dir" "$flags"
}

# Keep each tool once, at its first position, with its last definition
dedupe_packages() {
    local -A pos=()
    local -a keep=()
    local idx name
    for idx in "${!PKG_NAMES[@]}"; do
        name="${PKG_NAMES[$idx]}"
        if [[ -z "${pos[$name]+x}" ]]; then
            keep+=("$idx")
            pos["$name"]="$idx"
        else
            # The first position now takes this later definition
            local first="${pos[$name]}"
            PKG_APT[$first]="${PKG_APT[$idx]}"
            PKG_DNF[$first]="${PKG_DNF[$idx]}"
            PKG_BREW[$first]="${PKG_BREW[$idx]}"
            PKG_CUSTOM_CHECK[$first]="${PKG_CUSTOM_CHECK[$idx]}"
            PKG_CUSTOM_SCRIPT[$first]="${PKG_CUSTOM_SCRIPT[$idx]}"
            PKG_CUSTOM_DROPIN[$first]="${PKG_CUSTOM_DROPIN[$idx]}"
            PKG_CONFIG_DIR[$first]="${PKG_CONFIG_DIR[$idx]}"
            PKG_CONFIG_FLAGS[$first]="${PKG_CONFIG_FLAGS[$idx]}"
        fi
    done

    local arr i
    for arr in PKG_NAMES PKG_APT PKG_DNF PKG_BREW PKG_CUSTOM_CHECK PKG_CUSTOM_SCRIPT \
               PKG_CUSTOM_DROPIN PKG_CONFIG_DIR PKG_CONFIG_FLAGS; do
        local -n ref="$arr"
        local -a kept=()
        for i in "${keep[@]}"; do
            kept+=("${ref[$i]}")
        done
        ref=("${kept[@]}")
        unset -n ref
    done
}

# Load the packages: section of a file into the parallel PKG_* arrays. An entry
# is a plain name (resolve_tool) or the long form (- name: ...). With DEFINITIONS
# true, a plain name is an OS package with that name on every package manager.
# Usage: load_manifest file [source_for_errors] [definitions]
load_manifest() {
    local config_file="$1" source="${2:-$1}" definitions="${3:-false}"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config not found: $config_file"
        return 1
    fi

    [[ "$definitions" == true ]] || load_os_packages || return 1

    local in_packages=false
    local current_name=""
    local current_apt=""
    local current_dnf=""
    local current_brew=""
    local current_custom_check=""
    local current_custom_script=""
    local current_custom_dropin=""
    local current_config_dir=""
    local current_config_flags=""
    local in_custom=false
    local in_config=false
    local bad_entry=false

    # Save current entry to arrays
    _save_entry() {
        if [[ -n "$current_name" ]]; then
            if [[ -z "$current_apt$current_dnf$current_brew$current_custom_script$current_custom_dropin$current_config_dir" ]]; then
                log_error "Entry '$current_name' in $source defines nothing; to use a defined tool, write: - $current_name"
                bad_entry=true
            fi
            pkg_append "$current_name" "$current_apt" "$current_dnf" "$current_brew" \
                "$current_custom_check" "$current_custom_script" "$current_custom_dropin" \
                "$current_config_dir" "$current_config_flags"
        fi
    }

    _reset_entry() {
        current_name=""
        current_apt=""
        current_dnf=""
        current_brew=""
        current_custom_check=""
        current_custom_script=""
        current_custom_dropin=""
        current_config_dir=""
        current_config_flags=""
        in_custom=false
        in_config=false
    }

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^packages: ]]; then
            in_packages=true
            continue
        fi

        if [[ "$in_packages" == true ]]; then
            # A top-level key ends the section
            [[ "$line" =~ ^[[:alpha:]] ]] && break
            # New package entry: "  - name: <name>"
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
                _save_entry
                _reset_entry
                current_name="${BASH_REMATCH[1]}"
                current_name=$(echo "$current_name" | sed 's/[[:space:]]*$//')
            # Plain name: "  - <name>", optionally followed by a comment
            elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+([^[:space:]#]+)[[:space:]]*(#.*)?$ ]]; then
                local plain="${BASH_REMATCH[1]}"
                _save_entry
                _reset_entry
                if [[ "$definitions" == true ]]; then
                    pkg_append "$plain" "$plain" "$plain" "$plain" "" "" "" "" ""
                else
                    resolve_tool "$plain" "$source" || return 1
                fi
            # Any other list item can't be read
            elif [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
                log_error "Cannot read '$line' in $source"
                return 1
            # Top-level fields (2-4 space indent, no dash)
            elif [[ "$line" =~ ^[[:space:]]+apt:[[:space:]]*(.*) ]] && [[ "$in_custom" == false ]] && [[ "$in_config" == false ]]; then
                current_apt="${BASH_REMATCH[1]}"
                current_apt=$(echo "$current_apt" | sed 's/[[:space:]]*$//')
            elif [[ "$line" =~ ^[[:space:]]+dnf:[[:space:]]*(.*) ]] && [[ "$in_custom" == false ]] && [[ "$in_config" == false ]]; then
                current_dnf="${BASH_REMATCH[1]}"
                current_dnf=$(echo "$current_dnf" | sed 's/[[:space:]]*$//')
            elif [[ "$line" =~ ^[[:space:]]+brew:[[:space:]]*(.*) ]] && [[ "$in_custom" == false ]] && [[ "$in_config" == false ]]; then
                current_brew="${BASH_REMATCH[1]}"
                current_brew=$(echo "$current_brew" | sed 's/[[:space:]]*$//')
            # Entering custom: subsection
            elif [[ "$line" =~ ^[[:space:]]+custom:[[:space:]]*$ ]]; then
                in_custom=true
                in_config=false
            # Entering config: subsection
            elif [[ "$line" =~ ^[[:space:]]+config:[[:space:]]*$ ]]; then
                in_config=true
                in_custom=false
            # Custom sub-fields (deeper indent)
            elif [[ "$in_custom" == true ]]; then
                if [[ "$line" =~ ^[[:space:]]+check:[[:space:]]*(.*) ]]; then
                    current_custom_check="${BASH_REMATCH[1]}"
                    current_custom_check=$(echo "$current_custom_check" | sed 's/[[:space:]]*$//')
                elif [[ "$line" =~ ^[[:space:]]+script:[[:space:]]*(.*) ]]; then
                    current_custom_script="${BASH_REMATCH[1]}"
                    current_custom_script=$(echo "$current_custom_script" | sed 's/[[:space:]]*$//')
                elif [[ "$line" =~ ^[[:space:]]+dropin:[[:space:]]*(.*) ]]; then
                    current_custom_dropin="${BASH_REMATCH[1]}"
                    current_custom_dropin=$(echo "$current_custom_dropin" | sed 's/[[:space:]]*$//')
                fi
            # Config sub-fields (deeper indent)
            elif [[ "$in_config" == true ]]; then
                if [[ "$line" =~ ^[[:space:]]+dir:[[:space:]]*(.*) ]]; then
                    current_config_dir="${BASH_REMATCH[1]}"
                    current_config_dir=$(echo "$current_config_dir" | sed 's/[[:space:]]*$//')
                elif [[ "$line" =~ ^[[:space:]]+flags:[[:space:]]*(.*) ]]; then
                    current_config_flags="${BASH_REMATCH[1]}"
                    current_config_flags=$(echo "$current_config_flags" | sed 's/[[:space:]]*$//')
                fi
            fi
        fi
    done < "$config_file"

    # Save last entry
    _save_entry
    [[ "$bad_entry" == false ]] || return 1

    [[ "$definitions" == true ]] && return 0
    if [[ ${#PKG_NAMES[@]} -eq 0 ]]; then
        log_error "No packages found in $source"
        return 1
    fi

    log_debug "Loaded ${#PKG_NAMES[@]} package(s) from manifest"
    return 0
}

# Resolve profile name to file path (hosts dir first unless skip_hosts)
# Usage: resolve_profile_path name [skip_hosts]
resolve_profile_path() {
    hosts_resolve_profile_path "$PROFILES_DIR" "$HOSTS_DIR" "$1" "${2:-false}"
}

# Apply exclude/include/extra from a profile or host.yaml to PKG_* arrays
# Usage: apply_profile_modifiers file label
apply_profile_modifiers() {
    local file="$1" label="$2"
    local -a exclude_list=()
    local -a include_list=()
    local has_extra=false
    local line
    grep -q '^extra:' "$file" && has_extra=true

    # Parse exclude/include lists
    local in_exclude=false
    local in_include=false
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^exclude: ]]; then
            in_exclude=true
            in_include=false
            continue
        elif [[ "$line" =~ ^include: ]]; then
            in_include=true
            in_exclude=false
            continue
        elif [[ "$line" =~ ^[[:alpha:]] ]]; then
            in_exclude=false
            in_include=false
        fi

        if [[ "$in_exclude" == true && "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
            local item="${BASH_REMATCH[1]}"
            item=$(echo "$item" | sed 's/[[:space:]]*$//')
            exclude_list+=("$item")
        elif [[ "$in_include" == true && "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
            local item="${BASH_REMATCH[1]}"
            item=$(echo "$item" | sed 's/[[:space:]]*$//')
            include_list+=("$item")
        fi
    done < "$file"

    # Apply exclude filter
    if [[ ${#exclude_list[@]} -gt 0 ]]; then
        local -a filtered_names=() filtered_apt=() filtered_dnf=() filtered_brew=()
        local -a filtered_cc=() filtered_cs=() filtered_cd=()
        local -a filtered_cdir=() filtered_cflags=()
        for idx in "${!PKG_NAMES[@]}"; do
            local skip=false
            for exc in "${exclude_list[@]}"; do
                if [[ "${PKG_NAMES[$idx]}" == "$exc" ]]; then
                    skip=true
                    break
                fi
            done
            if [[ "$skip" == false ]]; then
                filtered_names+=("${PKG_NAMES[$idx]}")
                filtered_apt+=("${PKG_APT[$idx]}")
                filtered_dnf+=("${PKG_DNF[$idx]}")
                filtered_brew+=("${PKG_BREW[$idx]}")
                filtered_cc+=("${PKG_CUSTOM_CHECK[$idx]}")
                filtered_cs+=("${PKG_CUSTOM_SCRIPT[$idx]}")
                filtered_cd+=("${PKG_CUSTOM_DROPIN[$idx]}")
                filtered_cdir+=("${PKG_CONFIG_DIR[$idx]}")
                filtered_cflags+=("${PKG_CONFIG_FLAGS[$idx]}")
            fi
        done
        PKG_NAMES=("${filtered_names[@]}")
        PKG_APT=("${filtered_apt[@]}")
        PKG_DNF=("${filtered_dnf[@]}")
        PKG_BREW=("${filtered_brew[@]}")
        PKG_CUSTOM_CHECK=("${filtered_cc[@]}")
        PKG_CUSTOM_SCRIPT=("${filtered_cs[@]}")
        PKG_CUSTOM_DROPIN=("${filtered_cd[@]}")
        PKG_CONFIG_DIR=("${filtered_cdir[@]}")
        PKG_CONFIG_FLAGS=("${filtered_cflags[@]}")
    elif [[ ${#include_list[@]} -gt 0 ]]; then
        local inc_name known
        for inc_name in "${include_list[@]}"; do
            known=false
            for idx in "${!PKG_NAMES[@]}"; do
                [[ "${PKG_NAMES[$idx]}" == "$inc_name" ]] && known=true
            done
            if [[ "$known" != true ]]; then
                log_error "include '$inc_name' in $file: not in the inherited package list"
                return 1
            fi
        done
        local -a filtered_names=() filtered_apt=() filtered_dnf=() filtered_brew=()
        local -a filtered_cc=() filtered_cs=() filtered_cd=()
        local -a filtered_cdir=() filtered_cflags=()
        for idx in "${!PKG_NAMES[@]}"; do
            for inc in "${include_list[@]}"; do
                if [[ "${PKG_NAMES[$idx]}" == "$inc" ]]; then
                    filtered_names+=("${PKG_NAMES[$idx]}")
                    filtered_apt+=("${PKG_APT[$idx]}")
                    filtered_dnf+=("${PKG_DNF[$idx]}")
                    filtered_brew+=("${PKG_BREW[$idx]}")
                    filtered_cc+=("${PKG_CUSTOM_CHECK[$idx]}")
                    filtered_cs+=("${PKG_CUSTOM_SCRIPT[$idx]}")
                    filtered_cd+=("${PKG_CUSTOM_DROPIN[$idx]}")
                    filtered_cdir+=("${PKG_CONFIG_DIR[$idx]}")
                    filtered_cflags+=("${PKG_CONFIG_FLAGS[$idx]}")
                    break
                fi
            done
        done
        PKG_NAMES=("${filtered_names[@]}")
        PKG_APT=("${filtered_apt[@]}")
        PKG_DNF=("${filtered_dnf[@]}")
        PKG_BREW=("${filtered_brew[@]}")
        PKG_CUSTOM_CHECK=("${filtered_cc[@]}")
        PKG_CUSTOM_SCRIPT=("${filtered_cs[@]}")
        PKG_CUSTOM_DROPIN=("${filtered_cd[@]}")
        PKG_CONFIG_DIR=("${filtered_cdir[@]}")
        PKG_CONFIG_FLAGS=("${filtered_cflags[@]}")
    fi

    # Apply extra: append additional packages
    if [[ "$has_extra" == true ]]; then
        # Create a temp file with extra: renamed to packages: for reuse of load_manifest
        local tmp_extra
        tmp_extra=$(mktemp)
        sed 's/^extra:/packages:/' "$file" > "$tmp_extra"

        # Save current arrays
        local -a save_names=("${PKG_NAMES[@]}")
        local -a save_apt=("${PKG_APT[@]}")
        local -a save_dnf=("${PKG_DNF[@]}")
        local -a save_brew=("${PKG_BREW[@]}")
        local -a save_cc=("${PKG_CUSTOM_CHECK[@]}")
        local -a save_cs=("${PKG_CUSTOM_SCRIPT[@]}")
        local -a save_cd=("${PKG_CUSTOM_DROPIN[@]}")
        local -a save_cdir=("${PKG_CONFIG_DIR[@]}")
        local -a save_cflags=("${PKG_CONFIG_FLAGS[@]}")

        reset_pkg_arrays
        load_manifest "$tmp_extra" "$file" || { rm -f "$tmp_extra"; return 1; }
        rm -f "$tmp_extra"

        # Merge: restore saved + append extras
        local -a extra_names=("${PKG_NAMES[@]}")
        local -a extra_apt=("${PKG_APT[@]}")
        local -a extra_dnf=("${PKG_DNF[@]}")
        local -a extra_brew=("${PKG_BREW[@]}")
        local -a extra_cc=("${PKG_CUSTOM_CHECK[@]}")
        local -a extra_cs=("${PKG_CUSTOM_SCRIPT[@]}")
        local -a extra_cd=("${PKG_CUSTOM_DROPIN[@]}")
        local -a extra_cdir=("${PKG_CONFIG_DIR[@]}")
        local -a extra_cflags=("${PKG_CONFIG_FLAGS[@]}")

        PKG_NAMES=("${save_names[@]}" "${extra_names[@]}")
        PKG_APT=("${save_apt[@]}" "${extra_apt[@]}")
        PKG_DNF=("${save_dnf[@]}" "${extra_dnf[@]}")
        PKG_BREW=("${save_brew[@]}" "${extra_brew[@]}")
        PKG_CUSTOM_CHECK=("${save_cc[@]}" "${extra_cc[@]}")
        PKG_CUSTOM_SCRIPT=("${save_cs[@]}" "${extra_cs[@]}")
        PKG_CUSTOM_DROPIN=("${save_cd[@]}" "${extra_cd[@]}")
        PKG_CONFIG_DIR=("${save_cdir[@]}" "${extra_cdir[@]}")
        PKG_CONFIG_FLAGS=("${save_cflags[@]}" "${extra_cflags[@]}")
    fi

    if [[ ${#PKG_NAMES[@]} -eq 0 ]]; then
        log_error "No packages remaining after applying profile '$label' filters"
        return 1
    fi
    return 0
}

# Load packages from a profile file into PKG_* arrays
# Handles 'extends', 'exclude'/'include', and 'extra' directives.
# A hosts-dir profile that extends its own name continues the lookup in dotfiles.
# Usage: load_profile name [skip_hosts] [depth]
load_profile() {
    local name="$1" skip_hosts="${2:-false}" depth="${3:-0}"

    if [[ $depth -gt 10 ]]; then
        log_error "Profile chain too deep at '$name' (extends cycle?)"
        return 1
    fi

    local profile_path
    profile_path=$(resolve_profile_path "$name" "$skip_hosts")

    if [[ ! -f "$profile_path" ]]; then
        log_error "Profile not found: $profile_path"
        return 1
    fi

    local from_hosts=false
    if [[ -n "$HOSTS_DIR" && "$profile_path" == "$HOSTS_DIR/profiles/"* ]]; then
        from_hosts=true
    fi

    local extends_name=""
    local has_packages=false
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^extends:[[:space:]]*(.*) ]]; then
            extends_name="${BASH_REMATCH[1]}"
            extends_name=$(echo "$extends_name" | sed 's/[[:space:]]*$//')
        elif [[ "$line" =~ ^packages: ]]; then
            has_packages=true
        fi
    done < "$profile_path"

    if [[ "$has_packages" == true ]]; then
        # Form 1: full package list
        load_manifest "$profile_path" || return 1
    else
        if [[ -z "$extends_name" ]]; then
            log_error "Profile '$name' has no 'packages:' list and no 'extends:' directive"
            return 1
        fi
        local parent_skip=false
        if [[ "$from_hosts" == true && "$extends_name" == "$name" ]]; then
            parent_skip=true
        fi
        load_profile "$extends_name" "$parent_skip" $((depth + 1)) || return 1
        apply_profile_modifiers "$profile_path" "$name" || return 1
    fi

    if [[ "$from_hosts" == true ]]; then
        HOSTS_PROFILE_CHAIN+=("$name")
    fi
    log_debug "Profile '$name': ${#PKG_NAMES[@]} package(s) after filtering"
    return 0
}

# Resolve host and profile, load packages into PKG_* arrays
# Usage: load_packages_for_profile profile_arg hostname
#   profile_arg: explicit profile ("" = not given)
# Sets RESOLVED_PROFILE, HOSTS_PROFILE_CHAIN, HOST_YAML
load_packages_for_profile() {
    local profile_arg="$1" hostname="$2"

    reset_pkg_arrays
    HOSTS_PROFILE_CHAIN=()
    HOST_YAML=""

    if [[ ! -d "$PROFILES_DIR" ]]; then
        log_error "No profiles directory found: $PROFILES_DIR"
        return 1
    fi

    if [[ -n "$HOSTS_DIR" ]]; then
        local host_dir="$HOSTS_DIR/hosts/$hostname"
        if [[ -f "$host_dir/host.yaml" ]]; then
            HOST_YAML="$host_dir/host.yaml"
        elif [[ -d "$host_dir" ]]; then
            log_warn "Ignoring hosts/$hostname/: no host.yaml"
        fi
    fi

    if [[ -z "$HOST_YAML" ]]; then
        RESOLVED_PROFILE="${profile_arg:-complete}"
        load_profile "$RESOLVED_PROFILE" || return 1
        dedupe_packages
        return 0
    fi

    local host_profile
    host_profile=$(hosts_read_scalar "$HOST_YAML" profile)
    if [[ -z "$host_profile" ]]; then
        log_error "$HOST_YAML has no 'profile:'"
        return 1
    fi

    RESOLVED_PROFILE="$host_profile"
    if [[ -n "$profile_arg" ]]; then
        log_warn "Explicit profile '$profile_arg' overrides profile '$host_profile' from hosts/$hostname/host.yaml"
        RESOLVED_PROFILE="$profile_arg"
    fi

    load_profile "$RESOLVED_PROFILE" || return 1
    apply_profile_modifiers "$HOST_YAML" "host $hostname" || return 1
    dedupe_packages
}

# Collect layer roots and the strategies file, then validate every app's
# overlays. Runs before any change; returns 1 to abort.
# Usage: prepare_overlays target
prepare_overlays() {
    local target="$1"
    STAGE_ROOT="$WORK_DIR/$target"
    STRATEGIES_FILE="$STAGE_ROOT/strategies"
    LAYER_ROOTS=()
    mkdir -p "$STAGE_ROOT" || return 1
    : > "$STRATEGIES_FILE"

    local p
    for p in "${HOSTS_PROFILE_CHAIN[@]}"; do
        LAYER_ROOTS+=("$HOSTS_DIR/profiles/$p")
        hosts_parse_files_map "$HOSTS_DIR/profiles/$p.yaml" >> "$STRATEGIES_FILE" || return 1
    done
    if [[ -n "$HOST_YAML" ]]; then
        LAYER_ROOTS+=("$(dirname "$HOST_YAML")")
        hosts_parse_files_map "$HOST_YAML" >> "$STRATEGIES_FILE" || return 1
    fi

    local -a dirs=()
    local idx
    for idx in "${!PKG_NAMES[@]}"; do
        [[ -n "${PKG_CONFIG_DIR[$idx]}" ]] && dirs+=("${PKG_CONFIG_DIR[$idx]}")
    done

    local root app_path app
    for root in "${LAYER_ROOTS[@]}"; do
        [[ -d "$root/apps" ]] || continue
        for app_path in "$root"/apps/*/; do
            [[ -d "$app_path" ]] || continue
            app=$(basename "$app_path")
            if ! list_contains "$app" "${dirs[@]}"; then
                log_warn "[$target] Ignoring overlays for '$app' in ${root#"$HOSTS_DIR"/}: not in the package list"
            fi
        done
    done

    local key strategy
    while read -r key strategy; do
        app="${key%%/*}"
        if ! list_contains "$app" "${dirs[@]}"; then
            log_warn "[$target] Ignoring files: entry '$key': '$app' not in the package list"
        fi
    done < "$STRATEGIES_FILE"

    local dir ok=0
    for dir in "${dirs[@]}"; do
        [[ -f "$APPS_DIR/$dir/config.yaml" ]] || continue
        overlay_validate_app "$APPS_DIR/$dir" "$STRATEGIES_FILE" "${LAYER_ROOTS[@]}" || ok=1
    done
    return $ok
}
