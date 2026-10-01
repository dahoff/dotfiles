#!/usr/bin/env bash
# tmux/install.sh - Tmux configuration installer
# Usage: ./install.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$APP_DIR")/lib/installer.sh"

# TPM (Tmux Plugin Manager) bootstrap
TPM_DIR="$HOME/.tmux/plugins/tpm"
TPM_REPO="https://github.com/tmux-plugins/tpm"

bootstrap_tpm() {
    if [[ -d "$TPM_DIR/.git" ]]; then
        log_debug "TPM already present at $TPM_DIR"
        return 0
    fi
    log_info "Cloning TPM into $TPM_DIR"
    if is_dry_run; then
        log_info "[DRY-RUN] git clone --depth 1 $TPM_REPO $TPM_DIR"
        return 0
    fi
    git clone --depth 1 "$TPM_REPO" "$TPM_DIR" || {
        log_error "Failed to clone TPM. Check internet connectivity."
        return 1
    }
}

cleanup_tpm() {
    [[ -d "$HOME/.tmux/plugins" ]] || return 0
    log_info "Removing tmux plugins directory"
    is_dry_run && return 0
    rm -rf "$HOME/.tmux/plugins"
}

# Bootstrap TPM before post-install runs install_plugins.
# Non-fatal: failure (e.g. offline) leaves tmux usable without plugins.
app_post_files() {
    bootstrap_tpm || log_warn "TPM bootstrap failed; plugins will not be installed"
}

# Remove TPM and any plugin clones
app_post_uninstall() {
    cleanup_tpm
}

installer_main "$@"
