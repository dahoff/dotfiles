#!/usr/bin/env bash
# .tmux-yank.sh - Copy to system clipboard via OSC 52
# Handles popup sessions where OSC 52 doesn't pass through the popup PTY.
# In popup: sends OSC 52 directly to the outer session's terminal.
# In normal panes: no-op (tmux's set-clipboard handles it automatically).

content=$(cat)
session=$(tmux display-message -p '#S')

if [[ "$session" == _popup_* ]]; then
    outer_session="${session#_popup_}"
    tty=$(tmux list-clients -t "=$outer_session" -F '#{client_tty}' 2>/dev/null | head -1)
    if [[ -n "$tty" ]]; then
        encoded=$(printf '%s' "$content" | base64 | tr -d '\n')
        printf '\033]52;c;%s\a' "$encoded" > "$tty"
    fi
fi
