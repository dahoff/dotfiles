#!/usr/bin/env bash
# .tmux-lazydocker.sh - Persistent lazydocker popup that toggles on/off
# Opens lazydocker in the current pane's directory (passed via display-popup -d),
# so a docker-compose project there is picked up.
# Quitting lazydocker (q) destroys the session; next ` d opens fresh.

if ! command -v lazydocker &>/dev/null; then
    echo "Error: lazydocker is not installed."
    echo "Install: https://github.com/jesseduffield/lazydocker#installation"
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
fi

session="_lazydocker_$(tmux display-message -p '#S')"

# A session not running lazydocker (e.g. restored as a bare shell) is stale
if tmux has-session -t "=$session" 2>/dev/null &&
    [[ "$(tmux display-message -p -t "=$session:" '#{pane_current_command}')" != lazydocker ]]; then
    tmux kill-session -t "=$session"
fi

if ! tmux has-session -t "$session" 2>/dev/null; then
    session_id="$(tmux new-session -dP -s "$session" -c "$PWD" -F '#{session_id}' "lazydocker")"
    tmux set-option -t "$session_id" key-table lazydocker
    tmux set-option -t "$session_id" status off
    session="$session_id"
else
    # Re-apply settings lost when tmux-resurrect restores the session
    tmux set-option -t "$session" key-table lazydocker
    tmux set-option -t "$session" status off
fi

exec tmux attach-session -t "$session" > /dev/null
