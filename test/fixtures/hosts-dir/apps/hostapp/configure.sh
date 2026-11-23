#!/usr/bin/env bash
# hostapp/configure.sh - test app defined in the hosts repo
# Usage: ./configure.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run by dotfiles, ../../lib is dotfiles' code. To run it by hand, set DOTFILES_LIB to the lib/ of your dotfiles checkout.
source "${DOTFILES_LIB:-$APP_DIR/../../lib}/installer.sh"

installer_main "$@"
