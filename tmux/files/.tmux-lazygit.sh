#!/usr/bin/env bash
# .tmux-lazygit.sh - Persistent lazygit popup that toggles on/off
# Opens lazygit in the current pane's directory (passed via display-popup -d).
# Quitting lazygit (q) destroys the session; next Ctrl+l opens fresh.

if ! command -v lazygit &>/dev/null; then
    echo "Error: lazygit is not installed."
    echo "Install: https://github.com/jesseduffield/lazygit#installation"
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
fi

session="_lazygit_$(tmux display-message -p '#S')"

if ! tmux has-session -t "$session" 2>/dev/null; then
    session_id="$(tmux new-session -dP -s "$session" -c "$PWD" -F '#{session_id}' "lazygit")"
    tmux set-option -t "$session_id" key-table lazygit
    tmux set-option -t "$session_id" status off
    session="$session_id"
fi

exec tmux attach-session -t "$session" > /dev/null
