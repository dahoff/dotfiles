#!/usr/bin/env bash
# apps/ssh/configure.sh - SSH client config installer
# Usage: ./configure.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"

# The ~/.ssh/config this machine had before the first install, held until it's merged in
SSH_PRIOR=""

# Print the Host aliases a config defines, lowercased, one per line
_ssh_aliases() {
    awk 'tolower($1) == "host" {
        for (i = 2; i <= NF && $i !~ /^#/; i++) print tolower($i)
    }' "$1"
}

# Print the entries of a prior config that the deployed one lacks, ready to append:
#  - a Host block is dropped when every alias on its Host line is already deployed
#  - Match blocks are kept
#  - options before the first Host/Match apply to every host, so they're kept under
#    "Host *", which keeps them global after the deployed blocks
#  - an "Include config.local" line is dropped: the deployed file has its own
# Writes the kept and dropped aliases to KEPT and DROPPED, one per line.
# Usage: _ssh_prior_entries PRIOR DEPLOYED KEPT DROPPED
_ssh_prior_entries() {
    local prior="$1" deployed="$2" kept="$3" dropped="$4"
    awk -v known="$(_ssh_aliases "$deployed" | tr '\n' ' ')" -v kept="$kept" -v dropped="$dropped" '
        BEGIN {
            n = split(known, k, " ")
            for (i = 1; i <= n; i++) have[k[i]] = 1
            in_pre = 1; pre = ""; pre_opts = 0; out = ""; block = ""; keep = 0
            printf "" > kept; printf "" > dropped
        }
        function flush() {
            if (block != "" && keep) out = out block
            block = ""
        }
        tolower($0) ~ /^[[:space:]]*include[[:space:]]+(~\/\.ssh\/)?config\.local[[:space:]]*$/ { next }
        tolower($1) == "host" || tolower($1) == "match" {
            flush(); in_pre = 0; block = $0 "\n"
            if (tolower($1) == "match") { keep = 1; next }
            keep = 0; names = ""
            for (i = 2; i <= NF && $i !~ /^#/; i++) {
                names = names " " $i
                if (!(tolower($i) in have)) keep = 1
            }
            sub(/^ /, "", names)
            print names > (keep ? kept : dropped)
            next
        }
        in_pre {
            pre = pre $0 "\n"
            if ($0 !~ /^[[:space:]]*(#|$)/) pre_opts = 1
            next
        }
        { block = block $0 "\n" }
        END {
            flush()
            if (pre_opts) out = "Host *\n" pre out
            printf "%s", out
        }
    ' "$prior"
}

# First install with a ~/.ssh/config already there: hold it, to merge in after the
# deploy. Left alone when dotfiles already deployed the file (a reset) or when it already
# matches what's about to be deployed.
_hold_prior_ssh_config() {
    local existing="$HOME/.ssh/config"
    [[ -f "$existing" ]] || return 0
    records_knows_dest "$existing" && return 0
    cmp -s "$existing" "$(installer_src config)" && return 0
    if is_dry_run; then
        log_info "[DRY-RUN] Would merge the hosts in the existing ~/.ssh/config into the managed one"
        return 0
    fi
    SSH_PRIOR=$(mktemp) || return 1
    cat "$existing" > "$SSH_PRIOR"
}

# Append the held config's entries the deployed file lacks. They then show as a local
# edit: 'dotfiles add' saves them to a layer, or move the ones for this machine only into
# ~/.ssh/config.local.
_merge_prior_ssh_config() {
    [[ -n "$SSH_PRIOR" ]] || return 0
    local dest="$HOME/.ssh/config" work entries
    work=$(mktemp -d) || return 1
    entries=$(_ssh_prior_entries "$SSH_PRIOR" "$dest" "$work/kept" "$work/dropped") || {
        rm -rf "$work" "$SSH_PRIOR"
        return 1
    }
    if [[ -s "$work/dropped" ]]; then
        log_info "Already in the repo, not merged: $(tr '\n' ' ' < "$work/dropped")"
    fi
    if [[ -n "$entries" ]]; then
        {
            printf '\n# From the ~/.ssh/config this machine had before dotfiles (original: %s/original/).\n' "${BACKUP_DIR/#"$HOME"/\~}"
            printf "# 'dotfiles add' saves them to a repo; move ones for this machine only to ~/.ssh/config.local.\n"
            printf '%s\n' "$entries"
        } >> "$dest"
        log_success "Merged the existing ~/.ssh/config into the managed one: $(tr '\n' ' ' < "$work/kept")"
        log_info "Run 'dotfiles add' to save them to a repo; until then, pulls hold back changes to ~/.ssh/config"
    fi
    rm -rf "$work" "$SSH_PRIOR"
    SSH_PRIOR=""
}

# ~/.ssh is created private, the way ssh-keygen makes it
_ensure_ssh_dir() {
    [[ -d "$HOME/.ssh" ]] && return 0
    is_dry_run && return 0
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
}

app_pre_install() {
    _hold_prior_ssh_config
}

app_pre_deploy() {
    _ensure_ssh_dir
}

app_post_deploy() {
    [[ "$1" == install ]] || return 0
    _merge_prior_ssh_config
}

installer_main "$@"
