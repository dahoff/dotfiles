#!/usr/bin/env bash
# .tmux-split.sh - Toggle a persistent split-pane shell
#
# Creates a bottom split pane. Pressing Ctrl+s again hides it (shell keeps
# running in a hidden window). Ctrl+s again restores it. Type 'exit' to destroy.

hidden="_split"

# Case 1: Pane is hidden in a background window → restore it
if tmux list-windows -F '#{window_name}' | grep -qxF "$hidden"; then
    tmux join-pane -v -l 50% -s "=${hidden}.0"
    split_id=$(tmux show-environment SPLIT_PANE 2>/dev/null | cut -d= -f2)
    [[ -n "$split_id" ]] && tmux select-pane -t "$split_id" 2>/dev/null
    exit 0
fi

# Case 2: Split pane is visible → hide it to a background window
split_id=$(tmux show-environment SPLIT_PANE 2>/dev/null | cut -d= -f2)
if [[ -n "$split_id" ]] && tmux list-panes -F '#{pane_id}' | grep -qxF "$split_id"; then
    window_id=$(tmux break-pane -d -s "$split_id" -n "$hidden" -P -F '#{window_id}')
    tmux set-option -wt "$window_id" automatic-rename off
    tmux set-option -wt "$window_id" window-status-format ""
    tmux set-option -wt "$window_id" window-status-current-format ""
    exit 0
fi

# Case 3: No split exists → create one
new_pane=$(tmux split-window -v -l 50% -P -F '#{pane_id}')
tmux set-environment SPLIT_PANE "$new_pane"
