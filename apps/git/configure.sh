#!/usr/bin/env bash
# apps/git/configure.sh - Git configuration installer
# Usage: ./configure.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"

SKIP_GIT_SETUP=false

# Preserve existing ~/.gitconfig by renaming it to ~/.gitconfig.local
# This ensures all user settings (identity, signing, credentials, etc.) survive
# the install. The managed .gitconfig includes .gitconfig.local via [include].
_preserve_existing_gitconfig() {
    local existing="$HOME/.gitconfig"
    local local_config="$HOME/.gitconfig.local"

    if is_dry_run; then
        if [[ -f "$existing" ]] && [[ ! -f "$local_config" ]]; then
            log_info "[DRY-RUN] Would rename ~/.gitconfig -> ~/.gitconfig.local to preserve existing settings"
        fi
        return 0
    fi

    # If .gitconfig.local already exists, the user has already been through this
    if [[ -f "$local_config" ]]; then
        log_info "~/.gitconfig.local already exists, existing settings are preserved"
        return 0
    fi

    # No existing .gitconfig to preserve (fresh machine)
    if [[ ! -f "$existing" ]]; then
        log_info "No existing ~/.gitconfig found (fresh machine)"
        log_info "Run 'git-setup' after install to configure your identity"
        return 0
    fi

    # Rename existing .gitconfig -> .gitconfig.local
    log_info "Preserving existing ~/.gitconfig as ~/.gitconfig.local"
    mv "$existing" "$local_config"
    log_success "Renamed ~/.gitconfig -> ~/.gitconfig.local (all existing settings preserved)"
    log_info "The managed .gitconfig will include ~/.gitconfig.local automatically"
}

# Run git-setup interactively if identity is not yet configured.
# Skipped when: identity already set, --skip-git-setup passed, --dry-run,
# or stdin isn't a TTY (unattended/remote/test contexts can't answer prompts).
_maybe_run_git_setup() {
    local local_config="$HOME/.gitconfig.local"

    local current_name current_email
    current_name=$(git config --file "$local_config" user.name 2>/dev/null || true)
    current_email=$(git config --file "$local_config" user.email 2>/dev/null || true)

    if [[ -n "$current_name" && -n "$current_email" ]]; then
        log_info "Git identity already configured ($current_email), skipping git-setup"
        return 0
    fi

    if [[ "$SKIP_GIT_SETUP" == true || "${GIT_SETUP_SKIP:-false}" == true ]]; then
        log_info "Skipping git-setup (--skip-git-setup); run 'git-setup' manually to configure identity"
        return 0
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would run git-setup (identity not yet configured)"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_warn "No interactive terminal detected; skipping git-setup. Run 'git-setup' manually to configure identity"
        return 0
    fi

    local git_setup_bin="$HOME/.local/bin/git-setup"
    if [[ ! -x "$git_setup_bin" ]]; then
        log_warn "git-setup not found at $git_setup_bin; run it manually to configure git identity"
        return 0
    fi

    log_info "Git identity not configured — running git-setup..."
    "$git_setup_bin"
}

app_parse_arg() {
    if [[ "$1" == "--skip-git-setup" ]]; then
        SKIP_GIT_SETUP=true
        APP_ARG_SHIFT=1
        return 0
    fi
    return 1
}

app_usage() {
    cat << EOT
Git-specific options:
  --skip-git-setup     Skip interactive git identity setup (for unattended deploys)

EOT
}

# Preserve existing .gitconfig before overwriting
app_pre_install() {
    _preserve_existing_gitconfig
}

# An older install ran 'git config --global core.excludesfile' after each deploy,
# which rewrote that line. Same settings, so it isn't a hand edit.
app_matches_repo() {
    [[ "$1" == ".gitconfig" ]] || return 1
    local live want
    live=$(git config --file "$3" --list 2>/dev/null | sed "s#=$HOME/#=~/#") || return 1
    want=$(git config --file "$2" --list 2>/dev/null) || return 1
    [[ "$live" == "$want" ]]
}

# Prompt for git identity on fresh systems
app_post_install() {
    _maybe_run_git_setup
}

app_up_to_date() {
    _maybe_run_git_setup
}

installer_main "$@"
