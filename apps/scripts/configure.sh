#!/usr/bin/env bash
# apps/scripts/configure.sh - Utility scripts installer
# Usage: ./configure.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"

installer_main "$@"
