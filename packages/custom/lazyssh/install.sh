#!/usr/bin/env bash
# install-lazyssh.sh - Install lazyssh from GitHub releases
set -euo pipefail

# Skip if already installed
if command -v lazyssh &>/dev/null; then
    echo "lazyssh is already installed: $(lazyssh --version 2>/dev/null || echo 'unknown version')"
    exit 0
fi

echo "Installing lazyssh..."

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
LAZYSSH_VERSION=$(curl -s "https://api.github.com/repos/adembc/lazyssh/releases/latest" | grep -Po '"tag_name": *"v\K[^"]*')

if [[ -z "$LAZYSSH_VERSION" ]]; then
    echo "Error: Failed to determine latest lazyssh version" >&2
    exit 1
fi

echo "Latest version: v${LAZYSSH_VERSION}"

# Download and install
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

curl -Lo "$TMPDIR/lazyssh.tar.gz" \
    "https://github.com/adembc/lazyssh/releases/download/v${LAZYSSH_VERSION}/lazyssh_${OS}_${ARCH}.tar.gz"

tar xf "$TMPDIR/lazyssh.tar.gz" -C "$TMPDIR" lazyssh

sudo install "$TMPDIR/lazyssh" -D -t /usr/local/bin/

echo "lazyssh v${LAZYSSH_VERSION} installed successfully"
