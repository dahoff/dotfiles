#!/usr/bin/env bash
# bootstrap.sh - one-command setup for a fresh machine: install git, clone (or
# update) dotfiles, then run `dotfiles init`.
#
#   curl -fsSL https://raw.githubusercontent.com/dahoff/dotfiles/main/bootstrap.sh | bash
#   curl -fsSL .../bootstrap.sh | bash -s -- --hosts-dir git@github.com:me/dotfiles-hosts.git
#
# Consumes --repo URL and --dir PATH; everything else is passed to `dotfiles init`.
# Env: DOTFILES_REPO_URL, DOTFILES_DIR (defaults), DOTFILES_BOOTSTRAP_DRY=1 (print
# the git install command and stop), DOTFILES_BOOTSTRAP_NO_TTY=1 (never use /dev/tty).

set -euo pipefail

REPO_URL="${DOTFILES_REPO_URL:-https://github.com/dahoff/dotfiles.git}"
DIR="${DOTFILES_DIR:-$HOME/.local/share/dotfiles/dotfiles}"

say() { echo "bootstrap: $*" >&2; }
die() { say "$*"; exit 1; }

args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || die "--repo needs a URL"; REPO_URL="$2"; shift 2 ;;
        --dir)  [[ $# -ge 2 ]] || die "--dir needs a path"; DIR="$2"; shift 2 ;;
        --)     shift ;;
        *)      args+=("$1"); shift ;;
    esac
done

if ! command -v git >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        cmd="sudo apt-get update -qq && sudo apt-get install -y -qq git"
    elif command -v dnf >/dev/null 2>&1; then
        cmd="sudo dnf install -y -q git"
    elif command -v brew >/dev/null 2>&1; then
        cmd="brew install git"
    else
        die "git is required; install it and re-run"
    fi
    if [[ "${DOTFILES_BOOTSTRAP_DRY:-}" == 1 ]]; then
        say "would run: $cmd"
        exit 0
    fi
    say "installing git: $cmd"
    bash -c "$cmd" || die "could not install git; install it and re-run"
fi

if [[ ! -e "$DIR" ]]; then
    say "cloning $REPO_URL into $DIR"
    mkdir -p "$(dirname "$DIR")"
    git clone "$REPO_URL" "$DIR" >&2 || die "clone of $REPO_URL failed"
elif git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    say "updating $DIR (git pull --ff-only)"
    git -C "$DIR" pull --ff-only >&2 || say "warning: pull failed; continuing with the existing checkout"
else
    die "$DIR exists and is not a git checkout"
fi

[[ -x "$DIR/dotfiles" ]] || die "$DIR/dotfiles not found or not executable"

if [[ -z "${DOTFILES_BOOTSTRAP_NO_TTY:-}" ]] && { : </dev/tty; } 2>/dev/null; then
    say "running dotfiles init"
    exec "$DIR/dotfiles" init ${args[@]+"${args[@]}"} </dev/tty
fi

# No terminal to prompt on: accept defaults rather than hang
has_yes=false
for a in ${args[@]+"${args[@]}"}; do [[ "$a" == --yes ]] && has_yes=true; done
if [[ "$has_yes" == true ]]; then
    say "no terminal available; running dotfiles init"
    exec "$DIR/dotfiles" init ${args[@]+"${args[@]}"}
fi
say "no terminal available; running dotfiles init --yes"
exec "$DIR/dotfiles" init --yes ${args[@]+"${args[@]}"}
