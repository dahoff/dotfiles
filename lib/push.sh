#!/usr/bin/env bash
# push.sh - dotfiles push: ship committed repo snapshots to a host over ssh
# Requires lib/logging.sh and lib/hosts.sh (hosts_local_name).
# DOTFILES_SSH_OPTS: extra whitespace-split ssh/scp options (used by tests).

# ssh with the push options. Usage: push_ssh [-t] HOST CMD
push_ssh() {
    local -a tty=()
    if [[ "${1:-}" == "-t" ]]; then
        tty=(-t)
        shift
    fi
    # shellcheck disable=SC2086
    ssh -o ConnectTimeout=10 ${DOTFILES_SSH_OPTS:-} "${tty[@]}" "$@" 9>&-
}

# scp with the push options. Usage: push_scp SRC... HOST:DEST
push_scp() {
    # shellcheck disable=SC2086
    scp -q -o ConnectTimeout=10 ${DOTFILES_SSH_OPTS:-} "$@" 9>&-
}

# Quote a string for a POSIX shell
push_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

# Tar REPO into OUT_TAR: git archive HEAD for a git work tree, else the plain
# directory. Appends a PUSHED marker file either way.
# Usage: push_build_payload REPO OUT_TAR
push_build_payload() {
    local repo="$1" out="$2" top commit="none" marker rc=0
    top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$top" && "$(cd "$top" && pwd -P)" == "$(cd "$repo" && pwd -P)" ]]; then
        git -C "$repo" archive --format=tar HEAD -o "$out" || return 1
        commit=$(git -C "$repo" rev-parse HEAD)
    else
        tar -C "$repo" -cf "$out" --exclude=./PUSHED . || return 1
    fi
    marker=$(mktemp -d "${out}.marker.XXXXXX") || return 1
    printf 'source=%s commit=%s date=%s\n' "$(hosts_local_name)" "$commit" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker/PUSHED"
    tar -rf "$out" -C "$marker" PUSHED || rc=1
    rm -rf "$marker"
    return $rc
}

# Print "dotfiles_repo=<abs>" and "hosts_dir=<abs>" as the remote sees them.
# Usage: push_remote_paths HOST
push_remote_paths() {
    local host="$1"
    push_remote_snippet | push_ssh "$host" "sh -s"
}

# Print the POSIX sh snippet that locates the remote dotfiles checkout and
# hosts dir. The dotfiles checkout is where ~/.local/bin/dotfiles points (the
# link is followed to its final target, whose basename must be "dotfiles" and
# whose directory must contain lib/), else the default. hosts_dir is read from
# the remote config.yaml with the same rules as config_load (lib/config.sh):
# CRLF stripped, blank and '#' lines skipped, indented lines and list items
# ignored, the first ': ' splits key from value, a quoted value may be followed
# by ' # comment' (quotes stripped, '#' inside kept), an unquoted value is cut
# at the first whitespace+'#', leading ~ expanded, last occurrence wins. A
# value that is not absolute falls back to the default with a warning on
# stderr. Plain sh (dash) only: the remote may not have dotfiles yet.
push_remote_snippet() {
    cat <<'SNIPPET'
cfg="${DOTFILES_CONFIG:-$HOME/.config/dotfiles/config.yaml}"
d=; h=
lnk="$HOME/.local/bin/dotfiles"
if [ -L "$lnk" ]; then
    t=$lnk; n=0
    while [ -L "$t" ] && [ "$n" -lt 40 ]; do
        n=$((n + 1))
        r=$(readlink "$t")
        case "$r" in /*) t=$r ;; *) t="$(dirname "$t")/$r" ;; esac
    done
    if [ ! -L "$t" ] && [ "$(basename "$t")" = dotfiles ] && [ -d "$(dirname "$t")/lib" ]; then
        d=$(cd "$(dirname "$t")" && pwd -P)
    fi
fi
if [ -f "$cfg" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
        l=$(printf '%s' "$l" | tr -d '\r')
        case "$l" in ''|'#'*) continue ;; esac
        case "$l" in
            ' '*|'	'*|'- '*|-) continue ;;
            *': '*) k=${l%%: *}; v=${l#*: } ;;
            *:) k=${l%:}; v= ;;
            *) continue ;;
        esac
        k=$(printf '%s' "$k" | sed 's/[[:space:]]*$//')
        [ "$k" = hosts_dir ] || continue
        v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//')
        if printf '%s\n' "$v" | grep -Eq "^(\"[^\"]*\"|'[^']*')([[:space:]]+#.*)?[[:space:]]*\$"; then
            c=${v%"${v#?}"}
            v=${v#?}
            v=${v%%"$c"*}
        else
            v=$(printf '%s' "$v" | sed -e 's/^#.*$//' -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//')
        fi
        case "$v" in
            "~") v=$HOME ;;
            "~/"*) v="$HOME/${v#"~/"}" ;;
        esac
        h=$v
    done < "$cfg"
fi
if [ -n "$h" ]; then
    case "$h" in /*) ;; *) echo "dotfiles: ignoring non-absolute hosts_dir in $cfg: $h" >&2; h= ;; esac
fi
[ -n "$d" ] || d="$HOME/.local/share/dotfiles/dotfiles"
[ -n "$h" ] || h="$HOME/.local/share/dotfiles/dotfiles-hosts"
printf 'dotfiles_repo=%s\nhosts_dir=%s\n' "$d" "$h"
SNIPPET
}

# Push both repos to HOST and run the sync there, or with INIT=true the remote
# 'dotfiles init' with INIT_FLAGS. Returns the remote exit code.
# Usage: push_host HOST INIT(true|false) [DRY_RUN(true|false) [INIT_FLAG...]]
push_host() {
    local host="$1" init="$2" dry_run="${3:-false}"
    local -a init_flags=("${@:4}")

    local dir="$WORK_DIR/push"
    mkdir -p "$dir"
    # Built once per run, so every host gets the same snapshot
    if [[ ! -f "$dir/dotfiles.tar" ]]; then
        if ! push_build_payload "$DOTFILES_REPO" "$dir/dotfiles.tar"; then
            log_error "[$host] could not build the dotfiles payload"
            return 1
        fi
        if [[ -n "$HOSTS_DIR" ]] && ! push_build_payload "$HOSTS_DIR" "$dir/hosts.tar"; then
            log_error "[$host] could not build the hosts payload"
            return 1
        fi
    fi

    local paths line rdot="" rhosts=""
    if ! paths=$(push_remote_paths "$host"); then
        log_error "[$host] ssh failed"
        return 1
    fi
    while IFS= read -r line; do
        case "$line" in
            dotfiles_repo=*) rdot="${line#*=}" ;;
            hosts_dir=*) rhosts="${line#*=}" ;;
        esac
    done <<< "$paths"
    if [[ -z "$rdot" || -z "$rhosts" ]]; then
        log_error "[$host] could not determine the remote repo paths"
        return 1
    fi

    local -a tars=("$dir/dotfiles.tar") targets=("$rdot")
    if [[ -f "$dir/hosts.tar" ]]; then
        tars+=("$dir/hosts.tar")
        targets+=("$rhosts")
    fi

    # Refuse git checkouts (they pull for themselves); note if the repo exists
    local state i check=""
    for i in "${!targets[@]}"; do
        check+="[ -e $(push_quote "${targets[$i]}/.git") ] && echo $(push_quote "git ${targets[$i]}"); "
    done
    # An existing non-git target may only be replaced if it is a pushed copy or empty
    local q
    for i in "${!targets[@]}"; do
        q=$(push_quote "${targets[$i]}")
        check+="if [ -e $q ] && [ ! -e $q/.git ] && [ ! -f $q/PUSHED ] && { [ ! -d $q ] || [ -n \"\$(ls -A $q 2>/dev/null)\" ]; }; then echo $(push_quote "foreign ${targets[$i]}"); fi; "
    done
    check+="[ -x $(push_quote "$rdot/dotfiles") ] && echo exists; true"
    if ! state=$(push_ssh "$host" "$check"); then
        log_error "[$host] ssh failed"
        return 1
    fi
    local refused=false exists=false
    while IFS= read -r line; do
        if [[ "$line" == "git "* ]]; then
            log_error "$host:${line#git } is a git checkout; run 'dotfiles sync' there instead"
            refused=true
        elif [[ "$line" == "foreign "* ]]; then
            log_error "$host:${line#foreign } exists and is not a pushed dotfiles copy; refusing to replace it"
            refused=true
        elif [[ "$line" == "exists" ]]; then
            exists=true
        fi
    done <<< "$state"
    [[ "$refused" == false ]] || return 1

    if [[ "$dry_run" == true ]]; then
        for i in "${!tars[@]}"; do
            echo "Would push $(basename "${tars[$i]}") ($(du -h "${tars[$i]}" | cut -f1)) to $host:${targets[$i]}"
        done
        if [[ "$init" == true ]]; then
            echo "Would run dotfiles init on $host"
        elif [[ "$exists" == true ]]; then
            push_ssh -t "$host" "$(push_quote "$rdot/dotfiles") sync --no-pull --dry-run"
        else
            echo "Would run dotfiles sync on $host"
        fi
        return $?
    fi

    local rtmp
    if ! rtmp=$(push_ssh "$host" "mktemp -d") || [[ -z "$rtmp" ]]; then
        log_error "[$host] could not create a remote temp dir"
        return 1
    fi
    # scp's remote side is parsed by the remote (or sftp), so it is not quoted:
    # require the mktemp path to be plain characters instead
    if [[ "$rtmp" != /* || "$rtmp" == *[!A-Za-z0-9/._-]* ]]; then
        log_error "[$host] unsupported remote temp dir '$rtmp' (set TMPDIR to a plain path)"
        push_ssh "$host" "rm -rf $(push_quote "$rtmp")" || true
        return 1
    fi
    if ! push_scp "${tars[@]}" "$host:$rtmp/"; then
        log_error "[$host] scp failed"
        push_ssh "$host" "rm -rf $(push_quote "$rtmp")" || true
        return 1
    fi

    local unpack="" p t
    for i in "${!tars[@]}"; do
        p=$(push_quote "${targets[$i]}")
        t=$(push_quote "$rtmp/$(basename "${tars[$i]}")")
        unpack+="mkdir -p \"\$(dirname $p)\" && rm -rf $p.new && mkdir $p.new && tar -xf $t -C $p.new || { rm -rf $p.new; exit 1; }
rm -rf $p.old
if [ -e $p ]; then mv $p $p.old || { rm -rf $p.new; exit 1; }; fi
if ! mv $p.new $p; then
    if [ -e $p.old ]; then mv $p.old $p; fi
    rm -rf $p.new; exit 1
fi
rm -rf $p.old
"
    done
    unpack+="rm -rf $(push_quote "$rtmp")"
    if ! push_ssh "$host" "$unpack"; then
        log_error "[$host] could not unpack the payload"
        push_ssh "$host" "rm -rf $(push_quote "$rtmp")" || true
        return 1
    fi

    if [[ "$init" == true ]]; then
        # The hosts dir is the one just shipped; with none shipped there is none
        local cmd f
        cmd="$(push_quote "$rdot/dotfiles") init --hosts-dir "
        if [[ -f "$dir/hosts.tar" ]]; then
            cmd+=$(push_quote "$rhosts")
        else
            cmd+=$(push_quote none)
        fi
        for f in ${init_flags[@]+"${init_flags[@]}"}; do
            cmd+=" $(push_quote "$f")"
        done
        log_info "[$host] Running dotfiles init"
        push_ssh -t "$host" "$cmd"
        return $?
    fi

    log_info "[$host] Running dotfiles sync"
    push_ssh -t "$host" "$(push_quote "$rdot/dotfiles") sync --no-pull"
}
