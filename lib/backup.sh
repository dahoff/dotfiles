#!/usr/bin/env bash
# backup.sh - Backup and restore functionality

# Create backup directory structure
# Usage: backup_init app_name backup_dir
backup_init() {
    local app_name="$1"
    local backup_dir="$2"

    log_debug "Initializing backup for $app_name at $backup_dir"

    # Create backup directory
    ensure_dir "$backup_dir" || return 1

    # Create original backup directory if it doesn't exist
    local original_dir="$backup_dir/original"
    if [[ ! -d "$original_dir" ]]; then
        ensure_dir "$original_dir" || return 1
        log_debug "Created original backup directory: $original_dir"
    fi

    return 0
}

# Check if file has original backup
# Usage: backup_has_original backup_dir filename
backup_has_original() {
    local backup_dir="$1"
    local filename="$2"

    [[ -f "$backup_dir/original/$filename" ]]
}

# Create original backup (only if doesn't exist)
# Usage: backup_create_original source_file backup_dir
backup_create_original() {
    local source_file="$1"
    local backup_dir="$2"
    local filename

    filename=$(basename "$source_file")

    # Skip if original backup already exists
    if backup_has_original "$backup_dir" "$filename"; then
        log_debug "Original backup already exists: $filename"
        return 0
    fi

    # Skip if source file doesn't exist
    if [[ ! -f "$source_file" ]]; then
        log_debug "Source file doesn't exist, skipping backup: $source_file"
        return 0
    fi

    local dest="$backup_dir/original/$filename"

    log_info "Creating original backup: $filename"

    copy_file "$source_file" "$dest" || return 1

    # Store checksum
    local checksum_file="$backup_dir/original/.checksums"
    echo "$(checksum "$dest") $filename" >> "$checksum_file"

    return 0
}

# Create timestamped backup
# Usage: backup_create_snapshot source_file backup_dir
backup_create_snapshot() {
    local source_file="$1"
    local backup_dir="$2"
    local ts
    local filename

    ts=$(timestamp)
    filename=$(basename "$source_file")

    # Skip if source file doesn't exist
    if [[ ! -f "$source_file" ]]; then
        log_debug "Source file doesn't exist, skipping backup: $source_file"
        return 0
    fi

    local snapshot_dir="$backup_dir/$ts"
    ensure_dir "$snapshot_dir" || return 1

    local dest="$snapshot_dir/$filename"

    log_info "Creating backup snapshot: $filename -> $ts"

    copy_file "$source_file" "$dest" || return 1

    # Store checksum
    local checksum_file="$snapshot_dir/.checksums"
    echo "$(checksum "$dest") $filename" >> "$checksum_file"

    echo "$ts"  # Return timestamp
}

# List all backup snapshots (excluding original)
# Usage: backup_list_snapshots backup_dir
backup_list_snapshots() {
    local backup_dir="$1"

    [[ ! -d "$backup_dir" ]] && return 0

    find "$backup_dir" -mindepth 1 -maxdepth 1 -type d ! -name "original" -exec basename {} \; | sort
}

# Prune old backups (keep max N, never delete original)
# Usage: backup_prune backup_dir max_count
backup_prune() {
    local backup_dir="$1"
    local max_count="$2"
    local snapshots
    local count

    snapshots=($(backup_list_snapshots "$backup_dir"))
    count=${#snapshots[@]}

    log_debug "Found $count backup snapshots (max: $max_count)"

    # If we're at or under the limit, nothing to do
    if [[ $count -le $max_count ]]; then
        return 0
    fi

    # Calculate how many to delete
    local to_delete=$((count - max_count))

    log_info "Pruning $to_delete old backup(s)"

    # Delete oldest snapshots (first in sorted list)
    for ((i=0; i<to_delete; i++)); do
        local snapshot="${snapshots[$i]}"
        local snapshot_path="$backup_dir/$snapshot"

        log_debug "Deleting old backup: $snapshot"

        if is_dry_run; then
            log_info "[DRY-RUN] Would delete: $snapshot_path"
        else
            rm -rf "$snapshot_path" || {
                log_warn "Failed to delete backup: $snapshot_path"
            }
        fi
    done

    return 0
}

# Restore from backup
# Usage: backup_restore backup_dir timestamp dest_file
backup_restore() {
    local backup_dir="$1"
    local timestamp="$2"
    local dest_file="$3"
    local filename

    filename=$(basename "$dest_file")

    # Determine source based on timestamp
    local source_file
    if [[ "$timestamp" == "original" ]]; then
        source_file="$backup_dir/original/$filename"
    else
        source_file="$backup_dir/$timestamp/$filename"
    fi

    if [[ ! -f "$source_file" ]]; then
        log_error "Backup file not found: $source_file"
        return 1
    fi

    log_info "Restoring from backup: $filename (from $timestamp)"

    if is_dry_run; then
        log_info "[DRY-RUN] Would restore: $source_file -> $dest_file"
        return 0
    fi

    copy_file "$source_file" "$dest_file" || return 1

    return 0
}

# Get latest backup timestamp
# Usage: backup_get_latest backup_dir
backup_get_latest() {
    local backup_dir="$1"

    backup_list_snapshots "$backup_dir" | tail -1
}

# Verify backup integrity
# Usage: backup_verify backup_dir timestamp
backup_verify() {
    local backup_dir="$1"
    local timestamp="$2"
    local backup_path
    local checksum_file

    if [[ "$timestamp" == "original" ]]; then
        backup_path="$backup_dir/original"
    else
        backup_path="$backup_dir/$timestamp"
    fi

    checksum_file="$backup_path/.checksums"

    if [[ ! -f "$checksum_file" ]]; then
        log_warn "No checksum file found for backup: $timestamp"
        return 1
    fi

    local errors=0

    while read -r expected_sum filename; do
        local file_path="$backup_path/$filename"

        if [[ ! -f "$file_path" ]]; then
            log_error "Missing file in backup: $filename"
            ((errors++))
            continue
        fi

        local actual_sum
        actual_sum=$(checksum "$file_path")

        if [[ "$actual_sum" != "$expected_sum" ]]; then
            log_error "Checksum mismatch: $filename"
            ((errors++))
        fi
    done < "$checksum_file"

    if [[ $errors -eq 0 ]]; then
        log_debug "Backup verification passed: $timestamp"
        return 0
    else
        log_error "Backup verification failed: $errors error(s)"
        return 1
    fi
}

# Export functions
export -f backup_init
export -f backup_has_original
export -f backup_create_original
export -f backup_create_snapshot
export -f backup_list_snapshots
export -f backup_prune
export -f backup_restore
export -f backup_get_latest
export -f backup_verify
