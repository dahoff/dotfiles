#!/bin/sh
# tmux-notify.sh - Ring the bell in Claude's tmux pane (called from Claude Code hooks)
# Usage: tmux-notify.sh [message]
#
# Hook stdout isn't the terminal, so the bell is written straight to the pane's tty.
# tmux then flags the window (red "!" in the status bar) and forwards the bell to
# the attached terminal - including over SSH, where Windows Terminal flashes the taskbar.

[ -n "$TMUX_PANE" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

# Stay quiet if you're already looking at this pane: it's the active pane of the
# active window and a client of its session has terminal focus (needs focus-events)
visible=$(tmux display -p -t "$TMUX_PANE" '#{&&:#{pane_active},#{window_active}}' 2>/dev/null)
if [ "$visible" = 1 ]; then
    session=$(tmux display -p -t "$TMUX_PANE" '#{session_id}')
    tmux list-clients -t "$session" -F '#{client_flags}' 2>/dev/null | grep -q focused && exit 0
fi

tty=$(tmux display -p -t "$TMUX_PANE" '#{pane_tty}' 2>/dev/null) || exit 0
[ -w "$tty" ] && printf '\a' > "$tty"

where=$(tmux display -p -t "$TMUX_PANE" '#S:#I #W')
tmux display-message -d 3000 "Claude [$where]: ${1:-done}" 2>/dev/null
exit 0
