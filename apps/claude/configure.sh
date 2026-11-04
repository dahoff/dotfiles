#!/usr/bin/env bash
# apps/claude/configure.sh - Claude Code configuration installer
# Usage: ./configure.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"

installer_main "$@"
