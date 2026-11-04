#!/usr/bin/env bash
# install-lazygit.sh - Install lazygit from GitHub releases
set -euo pipefail

# Skip if already installed
if command -v lazygit &>/dev/null; then
    echo "lazygit is already installed: $(lazygit --version 2>/dev/null || echo 'unknown version')"
    exit 0
fi

echo "Installing lazygit..."

# Determine architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="arm64"  ;;
    armv7l)  ARCH="armv6"  ;;
    *)
        echo "Error: Unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

OS=$(uname -s)
case "$OS" in
    Linux)  OS="Linux"  ;;
    Darwin) OS="Darwin" ;;
    *)
        echo "Error: Unsupported OS: $OS" >&2
        exit 1
        ;;
esac

# Get latest version
LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": *"v\K[^"]*')

if [[ -z "$LAZYGIT_VERSION" ]]; then
    echo "Error: Failed to determine latest lazygit version" >&2
    exit 1
fi

echo "Latest version: v${LAZYGIT_VERSION}"

# Download and install
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

curl -Lo "$TMPDIR/lazygit.tar.gz" \
    "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_${OS}_${ARCH}.tar.gz"

tar xf "$TMPDIR/lazygit.tar.gz" -C "$TMPDIR" lazygit

sudo install "$TMPDIR/lazygit" -D -t /usr/local/bin/

echo "lazygit v${LAZYGIT_VERSION} installed successfully"
