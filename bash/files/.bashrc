# ~/.bashrc - Managed by dotfiles installer
# Do not edit directly; customize via ~/.bashrc.d/*.sh drop-in files

# --- Interactive guard ---
case $- in
    *i*) ;;
    *) return;;
esac

# --- Source system defaults ---
[[ -f /etc/bash.bashrc ]] && . /etc/bash.bashrc
if [[ -d /etc/profile.d ]]; then
    for _f in /etc/profile.d/*.sh; do
        [[ -r "$_f" ]] && . "$_f"
    done
    unset _f
fi

# --- History ---
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
HISTTIMEFORMAT='%F %T  '
shopt -s histappend
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }history -a"

# --- Shell options ---
shopt -s checkwinsize
shopt -s globstar 2>/dev/null
shopt -s cdspell 2>/dev/null
shopt -s dirspell 2>/dev/null
shopt -s nocaseglob 2>/dev/null
shopt -s autocd 2>/dev/null
shopt -s cmdhist
stty -ixon 2>/dev/null  # disable Ctrl+S freeze

# --- Prompt ---
_prompt_color() {
    local exit_code=$?
    local reset='\[\033[0m\]'
    local green='\[\033[0;32m\]'
    local blue='\[\033[0;34m\]'
    local red='\[\033[0;31m\]'

    local status_indicator=""
    if [[ $exit_code -ne 0 ]]; then
        status_indicator="${red}[$exit_code] ${reset}"
    fi

    PS1="${status_indicator}${green}\u@\h${reset}:${blue}\w${reset}\$ "
}
PROMPT_COMMAND="_prompt_color${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# Terminal title for xterm/tmux
case "$TERM" in
    xterm*|tmux*|screen*)
        PS1="\[\033]0;\u@\h: \w\007\]$PS1"
        ;;
esac

# --- PATH ---
[[ -d "$HOME/.local/bin" ]] && PATH="$HOME/.local/bin:$PATH"
[[ -d "$HOME/bin" ]] && PATH="$HOME/bin:$PATH"

# --- Exports ---
export EDITOR="${EDITOR:-vim}"
export VISUAL="${VISUAL:-$EDITOR}"
export PAGER="${PAGER:-less}"
export LESS="${LESS:--R --quit-if-one-screen}"

# Colored man pages
export LESS_TERMCAP_mb="${LESS_TERMCAP_mb:-$(printf '\033[1;31m')}"
export LESS_TERMCAP_md="${LESS_TERMCAP_md:-$(printf '\033[1;36m')}"
export LESS_TERMCAP_me="${LESS_TERMCAP_me:-$(printf '\033[0m')}"
export LESS_TERMCAP_se="${LESS_TERMCAP_se:-$(printf '\033[0m')}"
export LESS_TERMCAP_so="${LESS_TERMCAP_so:-$(printf '\033[1;44;33m')}"
export LESS_TERMCAP_ue="${LESS_TERMCAP_ue:-$(printf '\033[0m')}"
export LESS_TERMCAP_us="${LESS_TERMCAP_us:-$(printf '\033[1;32m')}"

# --- Colors ---
if command -v dircolors &>/dev/null; then
    if [[ -r ~/.dircolors ]]; then
        eval "$(dircolors -b ~/.dircolors)"
    else
        eval "$(dircolors -b)"
    fi
fi

alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# --- Aliases ---
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias mkdir='mkdir -pv'

# Safety aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Git shortcuts
alias gs='git status'
alias gl='git log --oneline -20'
alias gd='git diff'

# --- Functions ---

# mkdir + cd
mkcd() {
    mkdir -p "$1" && cd "$1"
}

# Universal archive extractor
extract() {
    if [[ ! -f "$1" ]]; then
        echo "extract: '$1' is not a file" >&2
        return 1
    fi
    case "$1" in
        *.tar.bz2) tar xjf "$1" ;;
        *.tar.gz)  tar xzf "$1" ;;
        *.tar.xz)  tar xJf "$1" ;;
        *.bz2)     bunzip2 "$1" ;;
        *.rar)     unrar x "$1" ;;
        *.gz)      gunzip "$1" ;;
        *.tar)     tar xf "$1" ;;
        *.tbz2)    tar xjf "$1" ;;
        *.tgz)     tar xzf "$1" ;;
        *.zip)     unzip "$1" ;;
        *.Z)       uncompress "$1" ;;
        *.7z)      7z x "$1" ;;
        *)         echo "extract: unsupported format '$1'" >&2; return 1 ;;
    esac
}

# --- Completion ---
if ! shopt -oq posix; then
    if [[ -f /usr/share/bash-completion/bash_completion ]]; then
        . /usr/share/bash-completion/bash_completion
    elif [[ -f /etc/bash_completion ]]; then
        . /etc/bash_completion
    fi
fi

# --- WSL detection ---
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qsi microsoft /proc/version 2>/dev/null; then
    alias clip='clip.exe'
    alias explorer='explorer.exe'
    export BROWSER="${BROWSER:-wslview}"
fi

# --- Drop-in sourcing ---
# Files in ~/.bashrc.d/ are sourced in lexicographic order.
# Naming convention: NN-description.sh (e.g., 50-tmux.sh, 90-secrets.sh)
if [[ -d ~/.bashrc.d ]]; then
    for f in ~/.bashrc.d/*.sh; do
        [[ -r "$f" ]] && . "$f"
    done
    unset f
fi
