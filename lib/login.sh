# 90-dotfiles.sh - show the last background sync report; start a background sync
# Managed by dotfiles; do not edit.
_dotfiles_login() {
    local state="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles"
    if [[ -s "$state/report" ]]; then
        cat "$state/report"
        rm -f "$state/report"
    fi
    [[ -n "${DOTFILES_NO_AUTO_SYNC:-}" ]] && return 0
    command -v dotfiles >/dev/null 2>&1 || return 0
    (setsid dotfiles sync --auto </dev/null >/dev/null 2>&1 &)
}
[[ $- == *i* ]] && _dotfiles_login
unset -f _dotfiles_login
