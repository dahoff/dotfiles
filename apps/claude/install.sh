#!/usr/bin/env bash
# install-claude.sh - Install Claude Code CLI via the official installer
set -euo pipefail

if command -v claude &>/dev/null; then
    echo "claude is already installed: $(claude --version 2>/dev/null || echo 'unknown version')"
    exit 0
fi

echo "Installing Claude Code..."

curl -fsSL https://claude.ai/install.sh | bash

if ! command -v claude &>/dev/null; then
    # Installer puts binary in ~/.local/bin — make sure it's discoverable in this shell
    export PATH="$HOME/.local/bin:$PATH"
fi

if command -v claude &>/dev/null; then
    echo "claude installed successfully: $(claude --version 2>/dev/null || echo 'unknown version')"
else
    echo "Error: claude command not found after install. Ensure ~/.local/bin is on PATH." >&2
    exit 1
fi
