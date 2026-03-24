# 50-tmux.sh - Tmux shell aliases and functions
# Installed by tmux module to ~/.bashrc.d/

# Connect to existing tmux session or create a new one
t() {
    local session="${1:-main}"
    tmux attach-session -t "$session" 2>/dev/null || tmux new-session -s "$session"
}

# List tmux sessions
alias tls='tmux list-sessions 2>/dev/null || echo "no sessions"'

# Kill a tmux session
alias tkill='tmux kill-session -t'
