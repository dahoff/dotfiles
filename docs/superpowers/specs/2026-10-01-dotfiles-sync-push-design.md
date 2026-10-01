# Design: `dotfiles` command, background sync, push, backup simplification

Date: 2026-10-01
Status: sections 1–2 approved in conversation; remaining sections are assumptions the user
delegated ("make reasonable assumptions") — marked **[assumed]** for review.
Scope: sub-project 2 of 3 (see `2026-09-30-dotfiles-hosts-design.md`, "Overall direction").

## Goals

- One command, `dotfiles`, replaces `setup.sh`; it is linked into `~/.local/bin`.
- Configs stay current on every host without the user remembering to sync: opening a terminal
  starts a throttled background sync that pulls both repos and deploys configs.
- Anything needing a password (OS packages, custom tool installs) never runs unattended; it is
  reported at the next terminal instead.
- Hosts that can't reach git get the repos copied over SSH (`dotfiles push`) and apply them with
  the same `dotfiles sync`.
- Per-host settings live in a config file instead of flags.
- The workstation-side remote deploy (`--host`, `--hosts-file`, `lib/remote.sh`, installer
  `--remote`) is removed.
- Backups shrink to what git can't replace; `rollback` goes (undo is a git operation).

## Decisions from the conversation

| Topic | Decision |
|---|---|
| Unattended packages | Background sync deploys configs only; missing packages are reported ("N packages pending (a, b) — run 'dotfiles sync'"). |
| Trigger | A function in a `~/.bashrc.d/` drop-in, run when an interactive shell starts. |
| Repo locations | Default `~/.local/share/dotfiles/dotfiles` and `~/.local/share/dotfiles/dotfiles-hosts`; the config file records actual paths (this machine: `~/git/...`). |
| Push payload | `git archive HEAD` of each repo (committed state only), unpacked into the remote's repo paths, then a full interactive `dotfiles sync` over `ssh -t`. |
| CLI | `setup.sh` becomes `dotfiles`: `sync`, `push`, `status`, `uninstall`, `verify`. `deploy`/`install`/`upgrade` dropped (sync covers them). No `setup.sh` left. |
| Throttle | Default 4 hours, configurable. |
| Backups | Keep originals (uninstall) and pre-overwrite snapshots; drop `rollback`, `backups`, `rollback_*` versions, backup checksum verification. |
| Uncommitted edits | `sync` deploys the working tree as-is (as `setup.sh deploy` does today). |

## Files and locations

| Path | Purpose |
|---|---|
| `dotfiles` (repo root, executable) | The renamed orchestrator (was `setup.sh`). |
| `~/.local/bin/dotfiles` | Symlink to `<dotfiles_repo>/dotfiles`. Created/refreshed by every `dotfiles sync` (self-install). |
| `~/.config/dotfiles/config` | Per-host settings (below). Optional. |
| `~/.config/dotfiles/apps/` | Per-app install state (unchanged). |
| `~/.local/state/dotfiles/` | `lock`, `last-sync` (timestamp file; mtime is what matters), `last-sync.log`, `report`, `pending`. Honors `$XDG_STATE_HOME`. |
| `~/.bashrc.d/90-dotfiles.sh` | Login drop-in. Source: `lib/login.sh` in the repo. Installed by self-install on every sync. |

### Config file `~/.config/dotfiles/config`  **[assumed format]**

`key=value` lines, `#` comments, blank lines ignored. Parsed (never `source`d). `~` expanded at
the start of path values. Unknown keys → warning.

| Key | Default | Meaning |
|---|---|---|
| `dotfiles_repo` | directory containing the running `dotfiles` script | dotfiles checkout |
| `hosts_repo` | `~/.local/share/dotfiles/dotfiles-hosts` if that directory exists, else none | dotfiles-hosts checkout |
| `hostname` | `hosts_local_name` (`hostname -s` → `uname -n`) | selects `hosts/<name>/` |
| `profile` | `complete` | used only when there's no `host.yaml` (same rule as `--profile` today: if set and a `host.yaml` exists, it wins with a warning) |
| `auto_sync` | `on` | `off` disables the background sync (the drop-in still prints reports) |
| `auto_sync_interval` | `4h` | minimum gap between background syncs; `<n>m`, `<n>h`, `<n>d` |

Precedence: command-line flag > env (`DOTFILES_HOSTS_REPO`, kept for compatibility) > config file >
default. Env `DOTFILES_CONFIG` overrides the config file path (used by tests).

## Commands

```
dotfiles sync [--auto] [--no-pull] [--profile X] [--hostname X] [--hosts-repo P]
              [--dry-run] [--no-backup] [--verbose] [--quiet] [--force] [--log FILE]
              [--skip-git-setup] [--shell-scripts-dir P]
dotfiles push [--dry-run] HOST...
dotfiles status
dotfiles uninstall [--dry-run] [--no-backup]
dotfiles verify
dotfiles help
```

### `dotfiles sync`

1. Load config, apply flags.
2. **Lock**: `flock -n` on `<state>/lock`. If held: `--auto` exits 0 silently; interactive prints
   "dotfiles: sync already running" and exits 1. **[assumed]** If `flock` is missing (macOS), fall
   back to `mkdir <state>/lock.d` as the lock (removed on exit).
3. **Throttle** (`--auto` only): if `auto_sync=off`, or `<state>/last-sync` is younger than the
   interval, exit 0 silently.
4. **Pull** (skipped with `--no-pull`): for each repo that is a git work tree with an upstream,
   `git -C <repo> pull --ff-only --quiet`. Only a repo whose top level is the path itself counts. The pull is bounded so it cannot hold the lock forever: `GIT_SSH_COMMAND="ssh -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"` when unset, `-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30`, and `timeout 300` when available (a timeout is a pull failure). On failure the repo is left untouched (no stash/reset/
   merge) and a warning is recorded: `<path>: pull failed (<first line of git stderr>)`. Repos that
   aren't git work trees (pushed copies) are skipped silently. In `--auto`, git runs with
   `GIT_TERMINAL_PROMPT=0` and `BatchMode=yes` added to the ssh options so it can never prompt.
5. **Self-install**: ensure `~/.local/bin/dotfiles` → the configured `<dotfiles_repo>/dotfiles`
   (the running checkout only when no `dotfiles_repo` is configured, so a run from a worktree never
   re-points it) and copy that repo's `lib/login.sh` to `<shell_scripts_dir>/90-dotfiles.sh` (0644) if different. Skipped in
   `--dry-run`.
6. **Resolve + validate** (sub-project 1 logic). Validation error → abort, recorded.
7. **Apply**:
   - interactive: phase 1 (OS packages), 2 (custom installs), 3 (configs) — as today.
   - `--auto`: phase 3 only, with `GIT_SETUP_SKIP=true`. Phases 1–2 run in **check mode**: compute
     missing OS packages (`is_pkg_installed`) and custom tools whose `check` fails, install
     nothing, record them as pending. Custom-tool drop-ins (no sudo needed) are still deployed in
     `--auto`. **[assumed]**
8. **Record**: touch `<state>/last-sync` (even on failure, so a broken setup isn't retried every
   terminal). `--auto` writes the report (below); stdout/stderr of `--auto` go to
   `<state>/last-sync.log` (overwritten each run). Pending packages are always written to
   `<state>/pending` (one name per line; empty file if none) so `status` can show them.
   An interactive sync clears a stale `report` **[assumed]**.

Exit code: 0 on success; 1 if anything failed (same as today's `setup.sh`).

#### Report (`<state>/report`)

Written only by `--auto`, and only when there is something to say. One line per item, each
prefixed `dotfiles: `:

- `updated <app>, <app>` — apps that installed or upgraded (not "already up to date").
- `N package(s) pending (a, b) — run 'dotfiles sync'`
- `<path>: pull failed (<reason>) — see <state>/last-sync.log`
- `sync failed (<item>, <item>) — see <state>/last-sync.log` — failed RESULTS items.

To produce `updated …`, the orchestrator needs to know which apps changed. **[assumed]**
Mechanism: installers export nothing new; instead the orchestrator compares each app's state
version before and after running its installer (`state_get_version`); a change, or a newly
created state file, means "updated".

### Login drop-in (`lib/login.sh` → `~/.bashrc.d/90-dotfiles.sh`)

```bash
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
    mkdir -p "$state" 2>/dev/null
    if command -v setsid >/dev/null 2>&1; then
        (setsid dotfiles sync --auto </dev/null >"$state/launch.log" 2>&1 &)
    else
        (dotfiles sync --auto </dev/null >"$state/launch.log" 2>&1 &)
    fi
}
[[ $- == *i* ]] && _dotfiles_login
unset -f _dotfiles_login
```

All throttling/lock/config logic lives in `dotfiles sync --auto`, so the drop-in stays trivial.
`setsid` is used when available; otherwise the call runs in a plain background subshell. Output goes
to `<state>/launch.log` (overwritten each time) so failures before the sync log exists are visible.
A config error in `--auto` is reported as `sync failed (config)` (default 4h throttle applies).

### `dotfiles push HOST...`

For each HOST (sequentially; `user@host` accepted; ssh options from `~/.ssh/config`, plus env
`DOTFILES_SSH_OPTS` for tests):

1. Build a payload in a temp dir: `dotfiles.tar` = `git archive HEAD` of the local dotfiles repo
   (if it isn't a git work tree — e.g. this host itself was pushed to — tar the directory as-is);
   same for the hosts repo if one is configured. Add a `PUSHED` marker file to each tree:
   `source=<local hostname> commit=<sha or "none"> date=<ISO time>`.
2. `ssh HOST` once to learn remote paths: read the remote config file (if any) for
   `dotfiles_repo`/`hosts_repo`, defaulting to `~/.local/share/dotfiles/{dotfiles,dotfiles-hosts}`.
   **[assumed]** A tiny inline POSIX-sh snippet does this (remote may not have the repo yet).
3. Refuse if a remote target directory is a git work tree (contains `.git`): "HOST:<path> is a git
   checkout; run 'dotfiles sync' there instead" (that host can pull itself). Counts as failure.
   Likewise refuse an existing target that has no `PUSHED` marker and is not an empty directory:
   "HOST:<path> exists and is not a pushed dotfiles copy; refusing to replace it".
4. Copy the payload (`scp`), then on the remote: unpack each tarball into `<path>.new`, then
   replace atomically-ish: `rm -rf <path>.old; mv <path> <path>.old (if exists); mv <path>.new
   <path>; rm -rf <path>.old`. Remove the remote temp dir.
5. `ssh -t HOST '<dotfiles_repo>/dotfiles sync --no-pull'` — full interactive sync (packages,
   sudo prompts) using the remote's own config and its own hostname for `hosts/<name>/`.
6. Per-host result into the summary; a failed host doesn't stop the next one. Exit 1 if any
   host failed.

`--dry-run`: build the payload and print what would be copied where; run the remote sync with
`--dry-run`. **[assumed]**

### `dotfiles status`  **[assumed content]**

Read-only; never pulls or fetches. Prints:

```
dotfiles repo:   ~/git/dotfiles  (git main @ a736870, dirty)
hosts repo:      ~/.local/share/dotfiles/dotfiles-hosts  (pushed from koi, commit 1b2c3d4, 2026-10-01T09:00)
config:          ~/.config/dotfiles/config
host:            koi  (hosts/koi/host.yaml)   profile: complete
auto sync:       on, every 4h — last run 2h ago (ok)
pending:         htop, lazygit
apps:
  bash     up to date
  claude   update available
  tmux     not installed
```

"update available" = installed state version ≠ the version a fresh stage would produce (stages
each app in a temp dir; no changes made). Missing repos/config are shown, not errors. Exit 0.

### `dotfiles uninstall`, `dotfiles verify`

Unchanged behavior from `setup.sh uninstall|verify` (run each app installer's `uninstall` /
`verify` for the resolved package list).

## Removed

- `setup.sh` (replaced by `dotfiles`; no wrapper).
- `--host`, `--hosts-file`, `--continue-on-error`, `hosts.yaml` support (`load_hosts`), the remote
  branch of `run_on_target`, workstation-side `hosts_normalize_name` use.
- `lib/remote.sh`. Push gets its own small `lib/push.sh` (ssh/scp wrappers honoring
  `DOTFILES_SSH_OPTS`).
- Installer `--remote` mode (`execute_remote`, `app_pre_remote`, `APP_REMOTE_DROP_ARGS`,
  `installer_version`'s `.version` file branch, `remote_package_installer`).
- Commands `deploy`, `install`, `upgrade` at the orchestrator level. App installers keep their
  own `install`/`upgrade`/`deploy` (the orchestrator calls `deploy`).

## Backup simplification

Kept:
- `original` backup on first install (used by `uninstall`).
- Timestamped snapshot of live files before each upgrade overwrite; pruned to `max_backups`.

Removed:
- Installer commands `rollback` and `backups` (and `--to`).
- `rollback_<ts>` state versions.
- `.checksums` files, `backup_verify`, and `verify`'s backup check (`verify` still checks
  installed files exist).
- Unused helpers left only for those (`backup_restore` is kept: `uninstall` uses it to restore
  originals; `backup_list_snapshots`/`backup_get_latest` removed if unused).

Undoing a bad change is documented as: `git revert <commit>` and push (every host picks it up),
or locally `git checkout <old> && dotfiles sync --no-pull` for a one-off check (the next pull
will fail fast-forward until you return to the branch — reported, not destructive).

## Errors

| Condition | Behavior |
|---|---|
| Config file has a malformed line | Warning naming the line; line ignored |
| `dotfiles_repo` in config doesn't exist | Abort |
| `hosts_repo` in config doesn't exist | Abort (same as `--hosts-repo` today) |
| Lock held | `--auto`: silent exit 0; interactive: message, exit 1 |
| Pull fails | Repo untouched; warning in output/report; sync continues |
| Validation fails | Abort before changes; `--auto` reports `sync failed (overlays)` |
| Push: remote target is a git checkout | That host fails with message; next host continues |
| Push: ssh/scp fails | That host fails; next host continues |

## Testing

Existing harness (`test/`), sandboxed HOME/STATE_DIR/XDG_STATE_HOME/DOTFILES_CONFIG:

- Config parsing: defaults, values, `~` expansion, malformed line warning, flag precedence.
- `sync` happy path equals today's `deploy` (existing test-setup/test-hosts integration tests move
  to `dotfiles sync`).
- Self-install: symlink and drop-in created; idempotent.
- `--auto`: throttle (fresh `last-sync` → no-op), `auto_sync=off`, lock held → no-op, config-only
  (a profile with an OS package that's missing → nothing installed, `pending` + report line),
  report "updated" lines, report pull failure (local bare repo as origin with a diverged commit),
  last-sync touched on failure.
- Pull: fast-forward from a local bare origin; non-git repo skipped; dirty conflicting tree →
  untouched + warning.
- Login drop-in: prints and deletes report; non-interactive shell does nothing;
  `DOTFILES_NO_AUTO_SYNC` respected (no sync started).
- Status: output sections present; "update available" after changing a fixture layer.
- Push (Docker, `DOTFILES_SSH_OPTS`): first push to a fresh container deploys configs (claude merge
  keeps live keys, host overlay applied via remote hostname → use `hostname` key in a remote
  config file written by the test); second push replaces trees (file removed locally is gone
  remotely); refusal when remote path is a git checkout.
- Backups: uninstall still restores originals; upgrade still snapshots + prunes; `rollback`/
  `backups` are rejected as unknown commands.

## Out of scope

`dotfiles init`, `bootstrap.sh`, `push --init` (sub-project 3); drift detection and
`dotfiles commit` (deferred notes); systemd/cron triggers; Windows/macOS-specific work beyond the
`flock` fallback.
