#!/usr/bin/env bash
# .tmux-top.sh - Persistent system monitor popup that toggles on/off
# Runs htop when installed, otherwise top, in a hidden tmux session.
# Pressing Ctrl+t again closes it; quitting (q) destroys the session.

session="_top_$(tmux display -p '#S')"

# htop handles its own mouse, so it gets a key-table without the popup's
# mouse-to-copy-mode bindings
table_for() { [[ "$1" == htop ]] && echo htop || echo popup; }

if ! tmux has-session -t "$session" 2>/dev/null; then
    if command -v htop &>/dev/null; then cmd=htop; else cmd=top; fi
    session_id="$(tmux new-session -dP -s "$session" -F '#{session_id}' "$cmd")"
    tmux set-option -t "$session_id" key-table "$(table_for "$cmd")"
    tmux set-option -t "$session_id" status off
    session="$session_id"
else
    # Re-apply settings lost when tmux-resurrect restores the session
    cmd="$(tmux display-message -p -t "=$session:" '#{pane_current_command}')"
    tmux set-option -t "$session" key-table "$(table_for "$cmd")"
    tmux set-option -t "$session" status off
fi

exec tmux attach-session -t "$session" > /dev/null
