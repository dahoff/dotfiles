#!/usr/bin/env bash
# yaml.sh - Simple bash-native YAML parser
# Handles simple YAML files (no complex nesting, arrays, or multiline)
# Sufficient for our config.yaml needs

# Parse YAML file and output key=value pairs
# Usage: yaml_parse file.yaml [prefix]
yaml_parse() {
    local yaml_file="$1"
    local prefix="${2:-}"
    local indent=0
    local current_key=""

    [[ ! -f "$yaml_file" ]] && {
        echo "ERROR: YAML file not found: $yaml_file" >&2
        return 1
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Remove trailing comments
        line="${line%%#*}"

        # Calculate indentation
        local spaces="${line%%[^[:space:]]*}"
        local indent_level=$((${#spaces} / 2))

        # Remove leading/trailing whitespace
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # Parse key: value
        if [[ "$line" =~ ^([^:]+):(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Clean up key and value
            key=$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

            # Build full key with prefix
            if [[ $indent_level -eq 0 ]]; then
                current_key="$key"
            else
                current_key="${prefix}${key}"
            fi

            # Output key=value if value is not empty
            if [[ -n "$value" ]]; then
                echo "${current_key}=${value}"
            fi
        # Parse list items (- item)
        elif [[ "$line" =~ ^-[[:space:]]+(.+)$ ]]; then
            local item="${BASH_REMATCH[1]}"
            echo "${current_key}[]=${item}"
        fi
    done < "$yaml_file"
}

# Get a specific value from parsed YAML
# Usage: yaml_get key [default_value]
yaml_get() {
    local key="$1"
    local default="${2:-}"

    # Look for key in $YAML_DATA (associative array)
    if [[ -n "${YAML_DATA[$key]:-}" ]]; then
        echo "${YAML_DATA[$key]}"
    else
        echo "$default"
    fi
}

# Load YAML file into associative array
# Usage: yaml_load file.yaml
yaml_load() {
    local yaml_file="$1"

    # Declare global associative array
    declare -gA YAML_DATA

    # Parse and load
    while IFS='=' read -r key value; do
        YAML_DATA["$key"]="$value"
    done < <(yaml_parse "$yaml_file")
}

# Get array items from YAML
# Usage: yaml_get_array key
yaml_get_array() {
    local key="$1"
    local pattern="${key}\\[\\]="

    for k in "${!YAML_DATA[@]}"; do
        if [[ "$k" =~ ^${key}\[\]$ ]]; then
            echo "${YAML_DATA[$k]}"
        fi
    done
}

# Simple YAML validator
# Usage: yaml_validate file.yaml
yaml_validate() {
    local yaml_file="$1"

    [[ ! -f "$yaml_file" ]] && {
        echo "ERROR: File not found: $yaml_file" >&2
        return 1
    }

    # Basic validation - check for syntax errors
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Check for basic YAML syntax
        if [[ ! "$line" =~ ^[[:space:]]*([-[:alnum:]_]+:.*|-.+)$ ]]; then
            echo "ERROR: Invalid YAML syntax at line $line_num: $line" >&2
            return 1
        fi
    done < "$yaml_file"

    return 0
}

# Export functions
export -f yaml_parse
export -f yaml_get
export -f yaml_load
export -f yaml_get_array
export -f yaml_validate
