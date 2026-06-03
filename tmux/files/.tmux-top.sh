#!/usr/bin/env bash
# .tmux-top.sh - Persistent top popup that toggles on/off
# Creates a hidden tmux session running top. Pressing Ctrl+t again
# detaches (hides it) while keeping top alive in the background.

session="_top_$(tmux display -p '#S')"

if ! tmux has-session -t "$session" 2>/dev/null; then
    session_id="$(tmux new-session -dP -s "$session" -F '#{session_id}' "top")"
    tmux set-option -t "$session_id" key-table popup
    tmux set-option -t "$session_id" status off
    session="$session_id"
else
    # Re-apply settings lost when tmux-resurrect restores the session
    tmux set-option -t "$session" key-table popup
    tmux set-option -t "$session" status off
fi

exec tmux attach-session -t "$session" > /dev/null
