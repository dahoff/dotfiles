#!/usr/bin/env bash
# setup.sh - Dotfiles setup orchestrator
# Usage: ./setup.sh <command> [--host HOST | --hosts-file FILE] [--profile NAME] [options]

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/yaml.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/remote.sh"

# Configuration
PROFILES_DIR="$SCRIPT_DIR/profiles"

# Parsed package manifest (parallel arrays)
declare -a PKG_NAMES=()
declare -a PKG_APT=()
declare -a PKG_DNF=()
declare -a PKG_BREW=()
declare -a PKG_CUSTOM_CHECK=()
declare -a PKG_CUSTOM_SCRIPT=()
declare -a PKG_CUSTOM_DROPIN=()
declare -a PKG_CONFIG_DIR=()
declare -a PKG_CONFIG_FLAGS=()

# Command and flags
COMMAND=""
REMOTE_HOST_ARG=""
HOSTS_FILE=""
PROFILE_ARG=""
declare -a GLOBAL_FLAGS=()

# Result tracking: "host|item|ok" or "host|item|FAIL"
declare -a RESULTS=()
EXIT_CODE=0

# Cross-module: shell scripts drop-in directory
SHELL_SCRIPTS_DIR="$HOME/.bashrc.d"

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

# Load unified package manifest from a profile file
# Parses the packages: section into parallel arrays
load_manifest() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config not found: $config_file"
        return 1
    fi

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

    # Save current entry to arrays
    _save_entry() {
        if [[ -n "$current_name" ]]; then
            PKG_NAMES+=("$current_name")
            PKG_APT+=("$current_apt")
            PKG_DNF+=("$current_dnf")
            PKG_BREW+=("$current_brew")
            PKG_CUSTOM_CHECK+=("$current_custom_check")
            PKG_CUSTOM_SCRIPT+=("$current_custom_script")
            PKG_CUSTOM_DROPIN+=("$current_custom_dropin")
            PKG_CONFIG_DIR+=("$current_config_dir")
            PKG_CONFIG_FLAGS+=("$current_config_flags")
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
            # New package entry: "  - name: <name>"
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
                _save_entry
                _reset_entry
                current_name="${BASH_REMATCH[1]}"
                current_name=$(echo "$current_name" | sed 's/[[:space:]]*$//')
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
            # Exit packages section on non-indented, non-packages line
            elif [[ "$line" =~ ^[[:alpha:]] ]]; then
                break
            fi
        fi
    done < "$config_file"

    # Save last entry
    _save_entry

    if [[ ${#PKG_NAMES[@]} -eq 0 ]]; then
        log_error "No packages found in $config_file"
        return 1
    fi

    log_debug "Loaded ${#PKG_NAMES[@]} package(s) from manifest"
    return 0
}

# Resolve profile name to file path
resolve_profile_path() {
    local name="$1"
    echo "$PROFILES_DIR/${name}.yaml"
}

# Load packages from a profile file into PKG_* arrays
# Handles 'extends', 'exclude'/'include', and 'extra' directives
load_profile() {
    local name="$1"
    local profile_path
    profile_path=$(resolve_profile_path "$name")

    if [[ ! -f "$profile_path" ]]; then
        log_error "Profile not found: $profile_path"
        return 1
    fi

    # Check for extends directive and packages section
    local extends_name=""
    local -a exclude_list=()
    local -a include_list=()
    local has_packages=false
    local has_extra=false

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^extends:[[:space:]]*(.*) ]]; then
            extends_name="${BASH_REMATCH[1]}"
            extends_name=$(echo "$extends_name" | sed 's/[[:space:]]*$//')
        elif [[ "$line" =~ ^packages: ]]; then
            has_packages=true
        elif [[ "$line" =~ ^extra: ]]; then
            has_extra=true
        fi
    done < "$profile_path"

    if [[ "$has_packages" == true ]]; then
        # Form 1: full package list — parse directly
        load_manifest "$profile_path"
        return $?
    fi

    if [[ -z "$extends_name" ]]; then
        log_error "Profile '$name' has no 'packages:' list and no 'extends:' directive"
        return 1
    fi

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
    done < "$profile_path"

    # Recursively load the parent profile
    load_profile "$extends_name" || return 1

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
        sed 's/^extra:/packages:/' "$profile_path" > "$tmp_extra"

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
        load_manifest "$tmp_extra" || { rm -f "$tmp_extra"; return 1; }
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
        log_error "No packages remaining after applying profile '$name' filters"
        return 1
    fi

    log_debug "Profile '$name': ${#PKG_NAMES[@]} package(s) after filtering"
    return 0
}

# Load packages for a given profile name
load_packages_for_profile() {
    local profile="${1:-complete}"

    reset_pkg_arrays

    if [[ -d "$PROFILES_DIR" ]]; then
        load_profile "$profile"
    else
        log_error "No profiles directory found: $PROFILES_DIR"
        return 1
    fi
}

# Load hosts from hosts file
# Outputs lines of "host|profile" (profile defaults to "complete")
load_hosts() {
    local hosts_file="$1"
    local hosts=()

    if [[ ! -f "$hosts_file" ]]; then
        log_error "Hosts file not found: $hosts_file"
        return 1
    fi

    local in_hosts=false
    local current_host=""
    local current_profile="complete"

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^hosts: ]]; then
            in_hosts=true
            continue
        fi

        if [[ "$in_hosts" == true ]]; then
            # New host entry: "- host: ..."
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*host:[[:space:]]*(.*) ]]; then
                # Save previous host if exists
                if [[ -n "$current_host" ]]; then
                    hosts+=("${current_host}|${current_profile}")
                fi
                current_host="${BASH_REMATCH[1]}"
                current_host=$(echo "$current_host" | sed 's/[[:space:]]*$//')
                current_profile="complete"
            # Profile field within a host entry
            elif [[ "$line" =~ ^[[:space:]]+profile:[[:space:]]*(.*) ]]; then
                current_profile="${BASH_REMATCH[1]}"
                current_profile=$(echo "$current_profile" | sed 's/[[:space:]]*$//')
            # Legacy format: "- hostname" (no "host:" key)
            elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
                if [[ -n "$current_host" ]]; then
                    hosts+=("${current_host}|${current_profile}")
                fi
                current_host="${BASH_REMATCH[1]}"
                current_host=$(echo "$current_host" | sed 's/[[:space:]]*$//')
                current_profile="complete"
            elif [[ "$line" =~ ^[[:alpha:]] ]]; then
                break
            fi
        fi
    done < "$hosts_file"

    # Save last host
    if [[ -n "$current_host" ]]; then
        hosts+=("${current_host}|${current_profile}")
    fi

    if [[ ${#hosts[@]} -eq 0 ]]; then
        log_error "No hosts found in $hosts_file"
        return 1
    fi

    # Print host|profile pairs, one per line
    printf '%s\n' "${hosts[@]}"
    return 0
}

# Detect package manager
detect_pkg_manager() {
    if command_exists apt-get; then
        echo "apt"
    elif command_exists dnf; then
        echo "dnf"
    elif command_exists brew; then
        echo "brew"
    else
        log_error "No supported package manager found (tried: apt-get, dnf, brew)"
        return 1
    fi
}

# Check if a package is installed
is_pkg_installed() {
    local pkg="$1"
    local manager="$2"
    case "$manager" in
        apt)
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && return 0
            command_exists "$pkg" && return 0
            return 1
            ;;
        dnf)
            rpm -q "$pkg" &>/dev/null && return 0
            command_exists "$pkg" && return 0
            return 1
            ;;
        brew)
            brew list "$pkg" &>/dev/null
            ;;
    esac
}

# Phase 1: Install all OS packages in one batch
run_phase_os_packages() {
    local host="${1:-}"
    local target="${host:-local}"
    local dry_run=false
    for flag in "${GLOBAL_FLAGS[@]}"; do
        [[ "$flag" == "--dry-run" ]] && dry_run=true
    done

    # Detect package manager
    local pkg_manager
    pkg_manager=$(detect_pkg_manager) || return 1
    log_info "[$target] Detected package manager: $pkg_manager"

    # Collect all OS packages for this manager
    local -a pkg_list=()
    for idx in "${!PKG_NAMES[@]}"; do
        local pkg=""
        case "$pkg_manager" in
            apt) pkg="${PKG_APT[$idx]}" ;;
            dnf) pkg="${PKG_DNF[$idx]}" ;;
            brew) pkg="${PKG_BREW[$idx]}" ;;
        esac
        if [[ -n "$pkg" ]]; then
            pkg_list+=("$pkg")
        fi
    done

    if [[ ${#pkg_list[@]} -eq 0 ]]; then
        log_info "[$target] No OS packages to install"
        return 0
    fi

    # Filter to only missing packages
    local -a missing=()
    for pkg in "${pkg_list[@]}"; do
        if ! is_pkg_installed "$pkg" "$pkg_manager"; then
            missing+=("$pkg")
        else
            log_debug "Already installed: $pkg"
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_success "[$target] All OS packages already installed"
        RESULTS+=("$target|os-packages|ok")
        return 0
    fi

    log_info "[$target] Packages to install: ${missing[*]}"

    if [[ "$dry_run" == true ]]; then
        log_info "[$target] [DRY-RUN] Would install ${#missing[@]} package(s) via $pkg_manager"
        RESULTS+=("$target|os-packages|ok")
        return 0
    fi

    case "$pkg_manager" in
        apt)
            sudo apt-get update -qq
            sudo apt-get install -y -qq "${missing[@]}"
            ;;
        dnf)
            sudo dnf install -y -q "${missing[@]}"
            ;;
        brew)
            brew install "${missing[@]}"
            ;;
    esac

    log_success "[$target] Installed ${#missing[@]} OS package(s)"
    RESULTS+=("$target|os-packages|ok")
    return 0
}

# Phase 2: Run custom installs
run_phase_custom_installs() {
    local host="${1:-}"
    local target="${host:-local}"
    local dry_run=false
    for flag in "${GLOBAL_FLAGS[@]}"; do
        [[ "$flag" == "--dry-run" ]] && dry_run=true
    done

    local has_custom=false
    for idx in "${!PKG_NAMES[@]}"; do
        local name="${PKG_NAMES[$idx]}"
        local check="${PKG_CUSTOM_CHECK[$idx]}"
        local script="${PKG_CUSTOM_SCRIPT[$idx]}"
        local dropin="${PKG_CUSTOM_DROPIN[$idx]}"

        [[ -z "$script" ]] && continue
        has_custom=true

        # Run install script if tool not already installed
        if [[ -n "$check" ]] && eval "$check" &>/dev/null; then
            log_info "[$target] $name: already installed"
        elif [[ "$dry_run" == true ]]; then
            log_info "[$target] [DRY-RUN] Would run: $SCRIPT_DIR/packages/$script"
        else
            log_info "[$target] Running custom install: $name"

            local script_path="$SCRIPT_DIR/packages/$script"
            if [[ ! -x "$script_path" ]]; then
                log_error "Custom install script not found or not executable: $script_path"
                RESULTS+=("$target|$name|FAIL")
                EXIT_CODE=1
                continue
            fi

            if bash "$script_path"; then
                log_success "[$target] Custom install complete: $name"
            else
                log_error "[$target] Custom install failed: $name"
                RESULTS+=("$target|$name|FAIL")
                EXIT_CODE=1
                continue
            fi
        fi

        # Always install dropin (even if tool was already installed)
        if [[ -n "$dropin" ]]; then
            local dropin_src="$SCRIPT_DIR/packages/$dropin"
            local dropin_dest="$SHELL_SCRIPTS_DIR/$(basename "$dropin")"
            if [[ -f "$dropin_src" ]]; then
                if [[ "$dry_run" == true ]]; then
                    log_info "[$target] [DRY-RUN] Would install dropin: $dropin_dest"
                else
                    mkdir -p "$SHELL_SCRIPTS_DIR"
                    cp "$dropin_src" "$dropin_dest"
                    chmod 0644 "$dropin_dest"
                    log_debug "Installed dropin: $dropin_dest"
                fi
            fi
        fi
    done

    if [[ "$has_custom" == true ]]; then
        RESULTS+=("$target|custom-installs|ok")
    fi
    return 0
}

# Phase 3: Deploy configs via app installers
run_phase_configs() {
    local host="${1:-}"
    local target="${host:-local}"

    for idx in "${!PKG_NAMES[@]}"; do
        local name="${PKG_NAMES[$idx]}"
        local dir="${PKG_CONFIG_DIR[$idx]}"
        local flags="${PKG_CONFIG_FLAGS[$idx]}"

        [[ -z "$dir" ]] && continue

        local installer="$SCRIPT_DIR/$dir/install.sh"

        if [[ ! -f "$installer" ]]; then
            log_error "Installer not found: $installer"
            RESULTS+=("$target|$name|FAIL")
            EXIT_CODE=1
            continue
        fi

        # Build command
        local cmd_args=("$COMMAND")

        # Add --remote if deploying to remote host
        if [[ -n "$host" ]]; then
            cmd_args+=("--remote" "$host")
        fi

        # Add per-package config flags
        if [[ -n "$flags" ]]; then
            # shellcheck disable=SC2206
            cmd_args+=($flags)
        fi

        # Add global flags
        cmd_args+=("${GLOBAL_FLAGS[@]}")

        log_info "[$target] $name: $COMMAND"
        log_debug "Running: $installer ${cmd_args[*]}"

        if bash "$installer" "${cmd_args[@]}"; then
            RESULTS+=("$target|$name|ok")
        else
            log_error "[$target] $name: $COMMAND failed"
            RESULTS+=("$target|$name|FAIL")
            EXIT_CODE=1
        fi
    done
}

# Run all phases for a target (local or remote host)
# Usage: run_all [host] [profile]
run_all() {
    local host="${1:-}"
    local profile="${2:-complete}"
    local target="${host:-local}"

    # Load profile-specific package list
    load_packages_for_profile "$profile" || return 1
    log_info "[$target] Using profile '$profile' (${#PKG_NAMES[@]} package(s))"

    # For remote hosts, check connectivity first
    if [[ -n "$host" ]]; then
        remote_parse_host "$host"
        if ! remote_check_connection; then
            log_error "[$target] Host unreachable, skipping"
            for idx in "${!PKG_NAMES[@]}"; do
                RESULTS+=("$target|${PKG_NAMES[$idx]}|FAIL")
            done
            EXIT_CODE=1
            return 1
        fi
    fi

    # Phase 1: OS packages (batch install)
    log_info "[$target] Phase 1: OS packages"
    run_phase_os_packages "$host" || true

    # Phase 2: Custom installs
    log_info "[$target] Phase 2: Custom installs"
    run_phase_custom_installs "$host" || true

    # Phase 3: Config deployments
    log_info "[$target] Phase 3: Config deployments"
    run_phase_configs "$host"
}

# Print summary report
print_summary() {
    echo
    echo "======================================"
    echo "Setup Summary"
    echo "======================================"
    echo

    local total=0
    local passed=0
    local failed=0

    for result in "${RESULTS[@]}"; do
        total=$((total + 1))
        local target item status
        IFS='|' read -r target item status <<< "$result"

        if [[ "$status" == "ok" ]]; then
            passed=$((passed + 1))
            log_success "[$target] $item: $COMMAND"
        else
            failed=$((failed + 1))
            log_error "[$target] $item: $COMMAND FAILED"
        fi
    done

    echo
    echo "Total: $total  Passed: $passed  Failed: $failed"

    if [[ $failed -eq 0 ]]; then
        log_success "All operations completed successfully!"
    else
        log_error "$failed operation(s) failed"
    fi
}

# Show usage
usage() {
    cat << 'EOF'
Usage: ./setup.sh <command> [--host HOST | --hosts-file FILE] [options]

Commands:
  deploy               Install if new, upgrade if exists (idempotent)
  install              Install all packages and configs
  upgrade              Upgrade all packages and configs
  uninstall            Uninstall all configs
  status               Show status for all configs
  verify               Verify all installations
  help                 Show this help message

Target options (mutually exclusive):
  --host HOST          Execute on a single remote host
  --hosts-file FILE    Execute on all hosts listed in file
  (neither)            Execute locally

Profile options:
  --profile NAME       Use a specific profile (default: complete)
                       Profiles are defined in profiles/<name>.yaml
                       Ignored when using --hosts-file (hosts define their own profiles)

Options (passed through to each app's installer):
  --dry-run            Show what would be done without making changes
  --no-backup          Skip creating backups
  --verbose            Verbose output
  --quiet              Minimal output
  --force              Force operation without prompts
  --shell-scripts-dir PATH  Set drop-in directory (default: ~/.bashrc.d)
  --log FILE           Log to file

Examples:
  ./setup.sh deploy                      # Local deploy (uses profiles/complete.yaml)
  ./setup.sh deploy --profile minimal    # Local deploy with minimal profile
  ./setup.sh deploy --dry-run            # Preview what would happen
  ./setup.sh deploy --host user@server   # Deploy to remote host
  ./setup.sh deploy --hosts-file hosts.yaml  # Deploy to all hosts (per-host profiles)
  ./setup.sh status                      # Check all configs locally
  ./setup.sh uninstall --no-backup       # Remove all configs

EOF
}

# Validate command
validate_command() {
    local cmd="$1"

    cmd=$(echo "$cmd" | tr -cd '[:alnum:]-')

    local valid_commands=(
        "deploy"
        "install"
        "upgrade"
        "uninstall"
        "status"
        "verify"
        "help"
        "-h"
        "--help"
    )

    for valid_cmd in "${valid_commands[@]}"; do
        if [[ "$cmd" == "$valid_cmd" ]]; then
            echo "$cmd"
            return 0
        fi
    done

    echo "Error: Unknown command '$1'" >&2
    echo "" >&2
    echo "Valid commands: deploy, install, upgrade, uninstall, status, verify, help" >&2
    return 1
}

# Parse arguments
parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    COMMAND=$(validate_command "$1") || exit 1
    shift

    while [[ $# -gt 0 ]]; do
        case $1 in
            --host)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --host requires a host argument" >&2
                    exit 1
                fi
                if [[ -n "$HOSTS_FILE" ]]; then
                    echo "Error: --host and --hosts-file are mutually exclusive" >&2
                    exit 1
                fi
                REMOTE_HOST_ARG="$2"
                shift 2
                ;;
            --hosts-file)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --hosts-file requires a file argument" >&2
                    exit 1
                fi
                if [[ -n "$REMOTE_HOST_ARG" ]]; then
                    echo "Error: --host and --hosts-file are mutually exclusive" >&2
                    exit 1
                fi
                HOSTS_FILE="$2"
                shift 2
                ;;
            --profile)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --profile requires a profile name" >&2
                    exit 1
                fi
                PROFILE_ARG="$2"
                shift 2
                ;;
            --dry-run|--no-backup|--verbose|--quiet|--force)
                GLOBAL_FLAGS+=("$1")
                shift
                ;;
            --shell-scripts-dir)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --shell-scripts-dir requires a path argument" >&2
                    exit 1
                fi
                SHELL_SCRIPTS_DIR="$2"
                GLOBAL_FLAGS+=("$1" "$2")
                shift 2
                ;;
            --log)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --log requires a filename argument" >&2
                    exit 1
                fi
                GLOBAL_FLAGS+=("$1" "$2")
                shift 2
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
}

# Main
main() {
    parse_args "$@"

    # Initialize logging
    log_init "$@"

    # Handle help
    if [[ "$COMMAND" == "help" || "$COMMAND" == "--help" || "$COMMAND" == "-h" ]]; then
        usage
        exit 0
    fi

    # Determine execution mode
    if [[ -n "$HOSTS_FILE" ]]; then
        # Multi-host mode — each host defines its own profile
        if [[ ! -f "$HOSTS_FILE" ]]; then
            log_error "Hosts file not found: $HOSTS_FILE"
            exit 1
        fi
        local host_entries
        mapfile -t host_entries < <(load_hosts "$HOSTS_FILE")
        if [[ ${#host_entries[@]} -eq 0 ]]; then
            log_error "No hosts found in $HOSTS_FILE"
            exit 1
        fi

        log_info "Deploying to ${#host_entries[@]} host(s)..."
        for entry in "${host_entries[@]}"; do
            local host profile
            IFS='|' read -r host profile <<< "$entry"
            run_all "$host" "$profile"
        done
    elif [[ -n "$REMOTE_HOST_ARG" ]]; then
        # Single remote host
        local profile="${PROFILE_ARG:-complete}"
        run_all "$REMOTE_HOST_ARG" "$profile"
    else
        # Local mode
        local profile="${PROFILE_ARG:-complete}"
        run_all "" "$profile"
    fi

    # Print summary
    print_summary

    exit $EXIT_CODE
}

main "$@"
