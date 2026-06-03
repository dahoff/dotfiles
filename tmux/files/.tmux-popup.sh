#!/usr/bin/env bash
# .tmux-popup.sh - Persistent popup shell that toggles on/off
# Based on: https://willhbr.net/2023/02/07/dismissable-popup-shell-in-tmux/
#
# Creates a hidden tmux session per main session. Attaching opens the popup;
# pressing Ctrl+p again detaches (hides it) while keeping the shell alive.

session="_popup_$(tmux display -p '#S')"

if ! tmux has-session -t "$session" 2>/dev/null; then
    session_id="$(tmux new-session -dP -s "$session" -F '#{session_id}')"
    tmux set-option -t "$session_id" key-table popup
    tmux set-option -t "$session_id" status off
    session="$session_id"
else
    # Re-apply settings lost when tmux-resurrect restores the session
    tmux set-option -t "$session" key-table popup
    tmux set-option -t "$session" status off
fi

exec tmux attach-session -t "$session" > /dev/null
