#!/usr/bin/env bash
# vim/install.sh - Vim configuration installer
# Usage: ./install.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$APP_DIR")/lib/installer.sh"

installer_main "$@"
