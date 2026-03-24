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
SETUP_CONFIG="$SCRIPT_DIR/setup.yaml"
PROFILES_DIR="$SCRIPT_DIR/profiles"

# Parsed app manifest (parallel arrays)
declare -a APP_NAMES=()
declare -a APP_DIRS=()
declare -a APP_FLAGS=()

# Command and flags
COMMAND=""
REMOTE_HOST_ARG=""
HOSTS_FILE=""
PROFILE_ARG=""
declare -a GLOBAL_FLAGS=()

# Result tracking: "host|app|ok" or "host|app|FAIL"
declare -a RESULTS=()
EXIT_CODE=0

# Load app manifest from setup.yaml
load_manifest() {
    if [[ ! -f "$SETUP_CONFIG" ]]; then
        log_error "Setup config not found: $SETUP_CONFIG"
        return 1
    fi

    local in_apps=false
    local current_name=""
    local current_dir=""
    local current_flags=""

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^apps: ]]; then
            in_apps=true
            continue
        fi

        if [[ "$in_apps" == true ]]; then
            # New app entry
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                # Save previous app if exists
                if [[ -n "$current_name" ]]; then
                    APP_NAMES+=("$current_name")
                    APP_DIRS+=("$current_dir")
                    APP_FLAGS+=("$current_flags")
                fi
                current_name=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*//')
                current_dir=""
                current_flags=""
            elif [[ "$line" =~ ^[[:space:]]*dir: ]]; then
                current_dir=$(echo "$line" | sed 's/^[[:space:]]*dir:[[:space:]]*//')
            elif [[ "$line" =~ ^[[:space:]]*flags: ]]; then
                current_flags=$(echo "$line" | sed 's/^[[:space:]]*flags:[[:space:]]*//')
            elif [[ "$line" =~ ^[[:alpha:]] ]]; then
                break
            fi
        fi
    done < "$SETUP_CONFIG"

    # Save last app
    if [[ -n "$current_name" ]]; then
        APP_NAMES+=("$current_name")
        APP_DIRS+=("$current_dir")
        APP_FLAGS+=("$current_flags")
    fi

    if [[ ${#APP_NAMES[@]} -eq 0 ]]; then
        log_error "No apps found in $SETUP_CONFIG"
        return 1
    fi

    log_debug "Loaded ${#APP_NAMES[@]} app(s) from manifest"
    return 0
}

# Resolve profile name to file path
resolve_profile_path() {
    local name="$1"
    echo "$PROFILES_DIR/${name}.yaml"
}

# Load apps from a profile file into APP_NAMES/APP_DIRS/APP_FLAGS
# Handles 'extends' and 'exclude'/'include' directives
load_profile() {
    local name="$1"
    local profile_path
    profile_path=$(resolve_profile_path "$name")

    if [[ ! -f "$profile_path" ]]; then
        log_error "Profile not found: $profile_path"
        return 1
    fi

    # Check for extends directive
    local extends_name=""
    local -a exclude_list=()
    local -a include_list=()
    local has_apps=false

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^extends:[[:space:]]*(.*) ]]; then
            extends_name="${BASH_REMATCH[1]}"
            extends_name=$(echo "$extends_name" | sed 's/[[:space:]]*$//')
        elif [[ "$line" =~ ^apps: ]]; then
            has_apps=true
        fi
    done < "$profile_path"

    if [[ "$has_apps" == true ]]; then
        # Form 1: full app list — parse like load_manifest but from profile file
        local old_config="$SETUP_CONFIG"
        SETUP_CONFIG="$profile_path"
        load_manifest
        local rc=$?
        SETUP_CONFIG="$old_config"
        return $rc
    fi

    if [[ -z "$extends_name" ]]; then
        log_error "Profile '$name' has no 'apps:' list and no 'extends:' directive"
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

    # Apply filters
    if [[ ${#exclude_list[@]} -gt 0 ]]; then
        local -a filtered_names=()
        local -a filtered_dirs=()
        local -a filtered_flags=()
        for idx in "${!APP_NAMES[@]}"; do
            local skip=false
            for exc in "${exclude_list[@]}"; do
                if [[ "${APP_NAMES[$idx]}" == "$exc" ]]; then
                    skip=true
                    break
                fi
            done
            if [[ "$skip" == false ]]; then
                filtered_names+=("${APP_NAMES[$idx]}")
                filtered_dirs+=("${APP_DIRS[$idx]}")
                filtered_flags+=("${APP_FLAGS[$idx]}")
            fi
        done
        APP_NAMES=("${filtered_names[@]}")
        APP_DIRS=("${filtered_dirs[@]}")
        APP_FLAGS=("${filtered_flags[@]}")
    elif [[ ${#include_list[@]} -gt 0 ]]; then
        local -a filtered_names=()
        local -a filtered_dirs=()
        local -a filtered_flags=()
        for idx in "${!APP_NAMES[@]}"; do
            for inc in "${include_list[@]}"; do
                if [[ "${APP_NAMES[$idx]}" == "$inc" ]]; then
                    filtered_names+=("${APP_NAMES[$idx]}")
                    filtered_dirs+=("${APP_DIRS[$idx]}")
                    filtered_flags+=("${APP_FLAGS[$idx]}")
                    break
                fi
            done
        done
        APP_NAMES=("${filtered_names[@]}")
        APP_DIRS=("${filtered_dirs[@]}")
        APP_FLAGS=("${filtered_flags[@]}")
    fi

    if [[ ${#APP_NAMES[@]} -eq 0 ]]; then
        log_error "No apps remaining after applying profile '$name' filters"
        return 1
    fi

    log_debug "Profile '$name': ${#APP_NAMES[@]} app(s) after filtering"
    return 0
}

# Load apps for a given profile name, with fallback to setup.yaml
load_apps_for_profile() {
    local profile="${1:-complete}"

    # Reset app arrays
    APP_NAMES=()
    APP_DIRS=()
    APP_FLAGS=()

    if [[ -d "$PROFILES_DIR" ]]; then
        load_profile "$profile"
    else
        # Fallback: no profiles directory, use setup.yaml
        log_debug "No profiles directory found, falling back to $SETUP_CONFIG"
        load_manifest
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

# Run a single app's installer
# Usage: run_app index [host]
run_app() {
    local idx="$1"
    local host="${2:-}"

    local name="${APP_NAMES[$idx]}"
    local dir="${APP_DIRS[$idx]}"
    local flags="${APP_FLAGS[$idx]}"
    local installer="$SCRIPT_DIR/$dir/install.sh"
    local target="${host:-local}"

    if [[ ! -f "$installer" ]]; then
        log_error "Installer not found: $installer"
        RESULTS+=("$target|$name|FAIL")
        return 1
    fi

    # Build command
    local cmd_args=("$COMMAND")

    # Add --remote if deploying to remote host
    if [[ -n "$host" ]]; then
        cmd_args+=("--remote" "$host")
    fi

    # Add per-app flags
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
        return 0
    else
        log_error "[$target] $name: $COMMAND failed"
        RESULTS+=("$target|$name|FAIL")
        EXIT_CODE=1
        return 1
    fi
}

# Run all apps for a target (local or remote host)
# Usage: run_all_apps [host] [profile]
run_all_apps() {
    local host="${1:-}"
    local profile="${2:-complete}"
    local target="${host:-local}"

    # Load profile-specific app list
    load_apps_for_profile "$profile" || return 1
    log_info "[$target] Using profile '$profile' (${#APP_NAMES[@]} app(s))"

    # For remote hosts, check connectivity first
    if [[ -n "$host" ]]; then
        remote_parse_host "$host"
        if ! remote_check_connection; then
            log_error "[$target] Host unreachable, skipping"
            for idx in "${!APP_NAMES[@]}"; do
                RESULTS+=("$target|${APP_NAMES[$idx]}|FAIL")
            done
            EXIT_CODE=1
            return 1
        fi
    fi

    for idx in "${!APP_NAMES[@]}"; do
        run_app "$idx" "$host" || true  # continue on failure
    done
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
        local target app status
        IFS='|' read -r target app status <<< "$result"

        if [[ "$status" == "ok" ]]; then
            passed=$((passed + 1))
            log_success "[$target] $app: $COMMAND"
        else
            failed=$((failed + 1))
            log_error "[$target] $app: $COMMAND FAILED"
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
  install              Install all applications
  upgrade              Upgrade all applications
  uninstall            Uninstall all applications
  status               Show status for all applications
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
  ./setup.sh status                      # Check all apps locally
  ./setup.sh uninstall --no-backup       # Remove all apps

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
            run_all_apps "$host" "$profile"
        done
    elif [[ -n "$REMOTE_HOST_ARG" ]]; then
        # Single remote host
        local profile="${PROFILE_ARG:-complete}"
        run_all_apps "$REMOTE_HOST_ARG" "$profile"
    else
        # Local mode
        local profile="${PROFILE_ARG:-complete}"
        run_all_apps "" "$profile"
    fi

    # Print summary
    print_summary

    exit $EXIT_CODE
}

main "$@"
