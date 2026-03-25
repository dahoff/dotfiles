# 10-ssh-agent.sh - Fix SSH agent forwarding in tmux
# When reconnecting SSH, the SSH_AUTH_SOCK changes but tmux sessions
# still have the old value. This creates a stable symlink that tmux uses.

if [[ -n "$SSH_AUTH_SOCK" && "$SSH_AUTH_SOCK" != "$HOME/.ssh/ssh_auth_sock" ]]; then
    mkdir -p ~/.ssh
    ln -sf "$SSH_AUTH_SOCK" ~/.ssh/ssh_auth_sock
    export SSH_AUTH_SOCK="$HOME/.ssh/ssh_auth_sock"
fi
