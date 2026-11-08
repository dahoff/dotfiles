#!/usr/bin/env bash
# apps/ssh/configure.sh - SSH client config installer
# Usage: ./configure.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"

# Keep an existing ~/.ssh/config as ~/.ssh/config.local, which the managed config
# Includes, so no host stops working on the first install (as apps/git does for
# ~/.gitconfig). Left alone when dotfiles already deployed the file, when config.local
# exists, or when the file already matches what's about to be deployed.
_preserve_existing_ssh_config() {
    local existing="$HOME/.ssh/config"
    local local_config="$HOME/.ssh/config.local"

    [[ -f "$existing" ]] || return 0
    records_knows_dest "$existing" && return 0
    if [[ -e "$local_config" ]]; then
        log_info "~/.ssh/config.local already exists; ~/.ssh/config is replaced (original kept in $BACKUP_DIR)"
        return 0
    fi
    if cmp -s "$existing" "$(installer_src config)"; then
        return 0
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would rename ~/.ssh/config -> ~/.ssh/config.local to preserve existing hosts"
        return 0
    fi
    log_info "Preserving existing ~/.ssh/config as ~/.ssh/config.local"
    mv "$existing" "$local_config"
    chmod 600 "$local_config"
    log_success "Renamed ~/.ssh/config -> ~/.ssh/config.local (the managed config Includes it)"
    log_info "lazyssh doesn't list hosts from config.local: to share them, move them into ~/.ssh/config and run 'dotfiles add'"
}

# ~/.ssh is created private, the way ssh-keygen makes it
_ensure_ssh_dir() {
    [[ -d "$HOME/.ssh" ]] && return 0
    is_dry_run && return 0
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
}

app_pre_install() {
    _preserve_existing_ssh_config
}

app_pre_deploy() {
    _ensure_ssh_dir
}

installer_main "$@"
