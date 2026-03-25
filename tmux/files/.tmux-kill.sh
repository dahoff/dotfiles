#!/usr/bin/env bash
# .tmux-kill.sh - Interactive process killer using fzf
# Launched as a tmux popup via Ctrl+k
#
# Controls:
#   Enter   - kill (SIGTERM)
#   Ctrl-x  - kill -9 (SIGKILL)
#   Ctrl-s  - toggle sort: memory <-> cpu
#   ESC     - cancel

set -euo pipefail

if ! command -v fzf &>/dev/null; then
    echo "fzf is required but not installed"
    read -r -n 1
    exit 1
fi

# Set up passwordless sudo for kill if not already configured
if [[ ! -f /etc/sudoers.d/kill-nopasswd ]]; then
    echo "Setting up passwordless sudo for kill (one-time)..."
    echo "$USER ALL=(ALL) NOPASSWD: /bin/kill, /usr/bin/kill" | sudo tee /etc/sudoers.d/kill-nopasswd >/dev/null
    sudo chmod 0440 /etc/sudoers.d/kill-nopasswd
    echo "Done."
fi

SORT_FILE=$(mktemp)
echo "cpu" > "$SORT_FILE"
trap 'rm -f "$SORT_FILE"' EXIT

# Helper script for reload - fzf calls this to get the process list
RELOAD_CMD="sort=\$(cat $SORT_FILE); if [ \"\$sort\" = mem ]; then echo cpu > $SORT_FILE; ps aux --sort=-%cpu; else echo mem > $SORT_FILE; ps aux --sort=-%mem; fi"

HEADER="Enter=kill | Ctrl-x=kill -9 | Ctrl-s=toggle sort (mem/cpu) | ESC=cancel"

result=$(ps aux --sort=-%cpu | \
    fzf --header="$HEADER" \
        --header-lines=1 \
        --layout=reverse \
        --preview='echo "PID: {2}  CPU: {3}%  MEM: {4}%  CMD: {11..}"' \
        --preview-window=down:3:wrap \
        --expect=ctrl-x \
        --bind="ctrl-k:abort" \
        --bind="ctrl-s:reload($RELOAD_CMD)" \
    || true)

# --expect outputs two lines: the key pressed, then the selected line
key=$(head -1 <<< "$result")
line=$(tail -n +2 <<< "$result")
pid=$(awk '{print $2}' <<< "$line")

if [[ -z "$pid" ]]; then
    exit 0
fi

cmd_name=$(awk '{print $11}' <<< "$line")

if [[ "$key" == "ctrl-x" ]]; then
    echo "Force killing (SIGKILL) PID $pid ($cmd_name)..."
    sudo kill -9 "$pid" 2>&1 || echo "Failed to kill $pid"
else
    echo "Killing (SIGTERM) PID $pid ($cmd_name)..."
    sudo kill "$pid" 2>&1 || echo "Failed to kill $pid"
fi
sleep 1
