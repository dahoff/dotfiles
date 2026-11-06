# 90-dotfiles.sh - show the last background sync report and the packages still
# needing sudo; start a background sync
# Managed by dotfiles; do not edit.
_dotfiles_login() {
    local state="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles"
    if [[ -s "$state/report" ]]; then
        cat "$state/report"
        rm -f "$state/report"
    fi
    # Reminder at every terminal while packages are pending (bash only: runs at each shell start)
    if [[ -s "$state/pending" ]]; then
        local names="" name
        while IFS= read -r name || [[ -n "$name" ]]; do
            [[ -n "$name" ]] && names+="${names:+, }$name"
        done < "$state/pending"
        [[ -n "$names" ]] && printf "dotfiles: %s not installed (needs sudo) — run 'dotfiles pull'\n" "$names"
    fi
    [[ -n "${DOTFILES_NO_AUTO_SYNC:-}" ]] && return 0
    command -v dotfiles >/dev/null 2>&1 || return 0
    mkdir -p "$state" 2>/dev/null
    # launch.log is overwritten each time; it shows failures before the sync log exists
    if command -v setsid >/dev/null 2>&1; then
        (setsid dotfiles pull --auto </dev/null >"$state/launch.log" 2>&1 &)
    else
        (dotfiles pull --auto </dev/null >"$state/launch.log" 2>&1 &)
    fi
}
[[ $- == *i* ]] && _dotfiles_login
unset -f _dotfiles_login
