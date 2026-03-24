#!/usr/bin/env bash
set -euo pipefail

CHEAT="${HOME}/.tmux/.tmux-cheatsheet.txt"

# Display the cheatsheet with color interpretation
# Use echo -e to interpret ANSI escape codes
echo -e "$(cat "$CHEAT")"

# Wait for any key
read -r -n 1 -s
