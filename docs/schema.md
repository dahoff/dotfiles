# YAML Schema Reference

This document defines every YAML field recognized by the dotfiles system. Keep this in sync when adding or changing config fields.

---

## Profile Schema (`profiles/*.yaml`)

Profiles define the complete set of packages, custom tools, and configs for an environment. Each entry in the `packages:` list represents a single installable item that can have OS packages, custom install scripts, and/or dotfiles config.

### Top-Level Directives

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `extends` | string | No | — | Name of parent profile to inherit from (resolved as `profiles/<name>.yaml`). Supports chaining. |
| `exclude` | array of strings | No | `[]` | Package names to remove from the inherited profile. Mutually exclusive with `include`. |
| `include` | array of strings | No | `[]` | Package names to keep from the inherited profile (all others removed). Mutually exclusive with `exclude`. |
| `extra` | array of objects | No | `[]` | Additional package entries to append after inheritance and filtering. Same format as `packages[]`. |
| `packages` | array of objects | No | `[]` | Ordered list of packages. Present in base profiles; inherited profiles use `exclude`/`include`/`extra` instead. |

### Package Entry Fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `packages[].name` | string | Yes | — | Package identifier. Used for `exclude`/`include` matching. |
| `packages[].apt` | string | No | — | Package name for APT (Debian/Ubuntu). |
| `packages[].dnf` | string | No | — | Package name for DNF (Fedora/RHEL). |
| `packages[].brew` | string | No | — | Package name for Homebrew (macOS). |
| `packages[].custom` | object | No | — | Custom install definition (for tools not in package managers). |
| `packages[].custom.check` | string | Yes | — | Shell command to test if already installed (exit 0 = installed). |
| `packages[].custom.script` | string | Yes | — | Install script path, relative to `packages/`. |
| `packages[].custom.dropin` | string | No | — | Shell drop-in file path (relative to `packages/`), copied to `${SHELL_SCRIPTS_DIR}`. |
| `packages[].config` | object | No | — | Dotfiles config deployment definition. |
| `packages[].config.dir` | string | Yes | — | App module directory (relative to repo root) containing `install.sh` and `files/`. |
| `packages[].config.flags` | string | No | — | Extra flags passed to the app's `install.sh` (e.g., `--append`). |

### Processing Order

dotfiles processes the unified list in three phases:
1. **Phase 1: OS packages** — Collect all `apt`/`dnf`/`brew` values, batch into one package manager call.
2. **Phase 2: Custom installs** — Run each `custom` entry's script (if `check` fails), install dropins.
3. **Phase 3: Configs** — For each entry with `config.dir`, call `<dir>/install.sh deploy [flags]`.

**Example — base profile:**
```yaml
packages:
  - name: git
    apt: git
    dnf: git
    config:
      dir: git

  - name: bash
    config:
      dir: bash
      flags: --append

  - name: lazygit
    custom:
      check: command -v lazygit
      script: custom/lazygit/install.sh
      dropin: custom/lazygit/files/50-lazygit.sh
```

**Example — derived profile:**
```yaml
extends: complete
exclude:
  - claude
  - lazygit
```

**Example — profile with extras:**
```yaml
extends: complete
exclude:
  - claude
extra:
  - name: docker
    apt: docker.io
```

---

## App Config Schema (`<app>/config.yaml`)

Each app module has a `config.yaml` describing its metadata, files, backup policy, requirements, and post-install hooks. These files define *how* to deploy config, not *what* to install (that's the profile's job).

### App Metadata

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `app` | object | Yes | — | Container for app metadata. |
| `app.name` | string | Yes | `"unknown"` | Canonical app name. Used for state tracking and logging. |
| `app.description` | string | No | — | Human-readable description of the app. |

### Files

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `files` | array of objects | No | `[]` | List of files to install from `<app>/files/` to their destinations. |
| `files[].src` | string | Yes | — | Source filename, relative to `<app>/files/`. |
| `files[].dest` | string | Yes | — | Destination path. Supports `${SHELL_SCRIPTS_DIR}` variable (default `~/.bashrc.d`). |
| `files[].mode` | string | Yes | — | File permissions as an octal string (e.g., `'0644'`, `'0755'`). |
| `files[].strategy` | string | No | `replace` | `replace` copies the file over the live one. `merge` (JSON only) deep-merges into the live file with jq `*`: objects merge recursively, arrays and scalars are replaced, keys only in the live file are kept. Can be overridden per host (see Hosts Repo). |

### Backup

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `backup` | object | No | — | Backup configuration. |
| `backup.dir` | string | No | `~/.bak/<app.name>` | Directory for storing backups. |
| `backup.max_backups` | integer | No | `3` | Maximum number of timestamped snapshots to retain. Older snapshots are pruned. |

### Requirements and Hooks

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `requirements` | array of strings | No | `[]` | Commands that must exist on the system before installation (checked via `command -v`). |
| `post_install` | array of strings | No | `[]` | Shell commands executed after file installation. Run in order. |

**Example:**
```yaml
app:
  name: git
  description: Global git configuration

files:
  - src: .gitconfig
    dest: ~/.gitconfig
    mode: '0644'

backup:
  dir: ~/.bak/git
  max_backups: 3

requirements:
  - git

post_install:
  - git config --global core.excludesfile ~/.gitignore_global
```

---

## Hosts Repo (`dotfiles-hosts`)

Optional data-only repo, given with `--hosts-repo PATH` or env `DOTFILES_HOSTS_REPO`.

    dotfiles-hosts/
      profiles/<name>.yaml                    # profile, same schema as profiles/*.yaml + files:
      profiles/<name>/apps/<app>/files/<src>  # file overlays for this profile
      hosts/<hostname>/host.yaml              # host settings (required for the directory to apply)
      hosts/<hostname>/apps/<app>/files/<src> # file overlays for this host

`<app>` is the dotfiles app directory (e.g. `claude`); `<src>` is a `src` from that app's `config.yaml`.

### Resolution

- The host name is `--hostname`, else `hostname -s`.
- If `hosts/<hostname>/host.yaml` exists, its `profile:` is the base profile. An explicit `--profile` wins, with a warning.
- A profile name resolves to `dotfiles-hosts/profiles/<name>.yaml` first, then `profiles/<name>.yaml`. A hosts-repo profile that `extends:` its own name continues the lookup in dotfiles.
- `host.yaml`'s `exclude`/`include`/`extra` apply last.

### `host.yaml`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `profile` | string | Yes | Base profile. |
| `exclude` / `include` | array of strings | No | As in profiles (mutually exclusive). |
| `extra` | array of objects | No | As in profiles. Entries reference dotfiles app dirs and `packages/` scripts. |
| `files` | map | No | `<app>/<src>: replace|merge` per-file strategy. |

Hosts-repo profiles accept the same `files:` map.

### File layers and strategy

Layers, lowest to highest: `dotfiles/<app>/files/<src>`, each hosts-repo profile in the chain (base-most first), the host directory.
`replace`: the highest layer that has the file wins. `merge`: live ⊕ all layers in order.
In practice the repo layers are pre-merged and then merged onto the live file: live ⊕ (dotfiles ⊕ profiles ⊕ host). This differs from strict left-to-right only when a lower layer sets a scalar or null and a higher layer sets an object at the same path; the result then keeps more live data.

Running an app's `install.sh` directly deploys the dotfiles layer only (no hosts repo overlays); use `dotfiles sync` with the hosts repo to keep host overlays.
Strategy: last declaration among the app `config.yaml`, the hosts-repo profile `files:` maps (base-most first), and `host.yaml` `files:`.

### Errors

The run aborts before any change if the hosts repo is missing, `host.yaml` lacks `profile:`, a profile isn't found, the `extends` chain cycles, an overlay file or `files:` key names an unknown `src`, `merge` is set on a non-`.json` file, or a strategy other than `replace`/`merge` is used. Overlays for apps not in the package list are ignored with a warning. Invalid JSON during a merge fails only that file, leaves the live file untouched, and is reported in the summary. The app's version is then recorded as `incomplete`, so the next run retries.

### Removing managed keys

`merge` never deletes keys from the live file. To remove a key, delete it from the repo layer and from the live file by hand.

---

## Config file

`${DOTFILES_CONFIG:-~/.config/dotfiles/config}` holds per-host settings. It is optional. It is made of `key=value` lines and is parsed, never sourced. Blank lines and `#` comments are ignored, and one pair of surrounding quotes is stripped from a value. A leading `~` is expanded. Unknown or malformed lines are ignored with a warning. An invalid `auto_sync`, `auto_sync_interval` or `hostname` aborts the command (in `--auto` it is reported, see Report).

| Key | Default | Meaning |
|---|---|---|
| `dotfiles_repo` | the directory of the running `dotfiles` | dotfiles checkout. It must exist. The running code is always `SCRIPT_DIR`; a different value only produces a warning (it matters for `push` and `init`). |
| `hosts_repo` | `~/.local/share/dotfiles/dotfiles-hosts` if that directory exists, else none | dotfiles-hosts checkout |
| `hostname` | `hostname -s`, then `uname -n` | selects `hosts/<name>/`. Same rules as `--hostname`: non-empty, no `/`, not `.` or `..`. |
| `profile` | `complete` | used when there is no `host.yaml`; with one, it overrides it with a warning (same as `--profile`) |
| `auto_sync` | `on` | `off` disables the background sync |
| `auto_sync_interval` | `4h` | minimum gap between background syncs: `<n>m`, `<n>h` or `<n>d` |

Precedence: command-line flag > env `DOTFILES_HOSTS_REPO` (hosts repo only) > config file > default.

---

## Commands

    dotfiles <command> [options]

| Command | What it does |
|---|---|
| `sync` | Pulls the dotfiles and hosts repos (fast-forward only), self-installs, then installs packages and deploys app configs. Idempotent: it installs what is new and upgrades what changed. |
| `push HOST...` | Ships the repos to each HOST over ssh and runs `dotfiles sync --no-pull` there. Meant for hosts without access to the repos. |
| `status` | Read-only. Shows the repos (branch and commit, or the pushed copy's `PUSHED` line), host and profile, auto sync state, pending packages and per-app state. |
| `uninstall` | Removes the deployed configs and restores the originals (unless `--no-backup`). |
| `verify` | Checks every installation. |
| `help` | Prints the usage text. |

### `sync`

- Pull is `git pull --ff-only` and nothing else. A failed pull (diverged, no network, no access) is a warning, not a failure: the repo is left untouched, the sync continues with what is checked out, and the exit code stays 0. A repo that is not a git work tree, or has no upstream branch, is skipped silently.
- `--no-pull` skips the pull of both repos.
- `--auto` is the background mode used by the login drop-in (see Background sync). It never installs OS packages or runs custom install scripts, never prompts, and applies configs only.
- A sync takes a lock in the state directory. A second concurrent sync exits with `dotfiles: sync already running` (an `--auto` run exits silently).
- `--dry-run` previews without changing anything: no lock, no pull, no self-install, and the state files are not touched.
- The other flags (`--profile`, `--hosts-repo`, `--hostname`, `--no-backup`, `--verbose`, `--quiet`, `--force`, `--skip-git-setup`, `--shell-scripts-dir`, `--log`) are listed in `dotfiles help`.

### `push`

    dotfiles push [--dry-run] HOST...

- Sends `git archive HEAD` of the dotfiles repo (and the hosts repo, if one is in use), so only committed state is shipped; uncommitted changes are not. If the source is not a git work tree, the plain directory is sent. Each snapshot gets a `PUSHED` file recording the source host, commit and time.
- The remote repo paths come from the remote config file (`dotfiles_repo`, `hosts_repo`), parsed the same way as `config_load`, else the default paths. A relative path there is ignored with a warning.
- A remote target that is a git checkout is refused (run `dotfiles sync` there instead). An existing target is replaced only if it holds a `PUSHED` marker or is an empty directory; anything else is refused with `<host>:<path> exists and is not a pushed dotfiles copy; refusing to replace it`, so a wrong remote config line cannot delete user data. An existing pushed copy is replaced by swapping the directory, and the old copy is restored if the swap fails.
- It then runs `<remote dotfiles_repo>/dotfiles sync --no-pull` with `ssh -t`, so prompts such as sudo work. The remote exit status is the push result. With several hosts, a failure on one is reported and the rest still run; the exit code is non-zero if any failed.
- `--dry-run` reports what would be sent and, if the remote already has dotfiles, runs a remote `sync --no-pull --dry-run`. Nothing is copied.
- `push --init` (bootstrapping a host that has no dotfiles yet) is not available.

### Self-install

A real `sync` (not `--dry-run`) installs two things, so the checkout becomes the installed command:

- `~/.local/bin/dotfiles`, a symlink to `<dotfiles_repo>/dotfiles` when the config sets `dotfiles_repo` and that checkout has a `dotfiles` script. Only when no `dotfiles_repo` is configured does it point at the running checkout. Running a sync from another checkout (a worktree, say) therefore never re-points the installed command; it only warns.
- `<shell scripts dir>/90-dotfiles.sh` (default `~/.bashrc.d/`), a copy of `lib/login.sh` taken from the same repo as the symlink target. It is managed by dotfiles; do not edit it.

`~/.local/bin` must be on `PATH`.

---

## Background sync

The drop-in `90-dotfiles.sh` runs in interactive shells only. In each new terminal it:

1. Prints the report left by the previous background sync (if any), then deletes it.
2. Unless `DOTFILES_NO_AUTO_SYNC` is set to a non-empty value, or `dotfiles` is not on `PATH`, starts `dotfiles sync --auto` detached in the background (`setsid` when available, else a plain background subshell). Its output goes to `launch.log` in the state directory (overwritten each time), so failures before `last-sync.log` exists are visible.

`sync --auto` then:

- Pulls with a bounded git: ssh `ConnectTimeout=10`, `ServerAliveInterval=15`, `ServerAliveCountMax=2` (plus `BatchMode=yes`) unless `GIT_SSH_COMMAND` is set, `http.lowSpeedLimit=1000`/`http.lowSpeedTime=30`, and `timeout 300` where available. A timeout is a pull failure (warning). Only a repo whose top level is the path itself is pulled; a pushed copy inside a tracked directory is skipped.
- Exits at once, changing nothing, if `auto_sync=off` or the last sync is younger than `auto_sync_interval` (default `4h`). `auto_sync_interval=0m` means always sync. A `last-sync` timestamp in the future (clock skew) does not throttle.
- Otherwise pulls both repos, then applies configs only. It never installs OS packages or runs custom install scripts, and never prompts. Missing packages are recorded as pending instead.
- Writes its output to `last-sync.log`, touches `last-sync` even when it fails (so a broken sync does not retry in every terminal), and writes the report.

### Report

`report` holds one line per finding, each prefixed `dotfiles: `, in the order below. The file is absent when there is nothing to say.

| Line | Meaning |
|---|---|
| `dotfiles: updated a, b` | Apps whose config was successfully updated. |
| `dotfiles: N package(s) pending (a, b) — run 'dotfiles sync'` | Packages or custom tools not installed, left for a manual sync. |
| `dotfiles: <path>: pull failed (<reason>) — see <log>` | A pull failed; the repo was left as it was. |
| `dotfiles: sync failed (<items>) — see <log>` | Items that failed. An early abort before any app ran (missing hosts repo, ...) reports `sync failed (setup)`. An unusable config file (bad `auto_sync`, `auto_sync_interval` or `hostname`, missing `dotfiles_repo`) reports `sync failed (config)` with the error text in the log. The config cannot supply the interval then, so the default `4h` throttle applies: the error is reported at most once per 4 hours. |

`<log>` is `last-sync.log`. A manual (non-`--auto`) sync removes a stale report.

### State directory

`${XDG_STATE_HOME:-~/.local/state}/dotfiles/`:

| File | Content |
|---|---|
| `lock` | Lock held while a sync runs (a `lock.d/` directory where `flock` is unavailable). |
| `last-sync` | Empty file; its modification time is the last sync and drives the throttle. |
| `last-sync.log` | Output of the last `--auto` run. |
| `launch.log` | Output of the login drop-in's launch of `dotfiles sync --auto`; overwritten each time. |
| `report` | Message shown at the next terminal, removed once shown. |
| `pending` | Packages still to install, one per line. Shown by `dotfiles status`. Refreshed by each real sync. |

### Turning it off

- Permanently: `auto_sync=off` in the config file.
- For one shell: `DOTFILES_NO_AUTO_SYNC=1` in the environment before the shell starts, for example `DOTFILES_NO_AUTO_SYNC=1 bash`.

---

## Undoing a change

Sync follows the repo, so undo in the repo:

- Revert and publish: `git revert <commit>` in the dotfiles (or hosts) repo, push it, and let each host pull on its next sync (or run `dotfiles sync`). For hosts that receive pushes, push again.
- Roll one host back without publishing: `git checkout <old-commit>` in the repo, then `dotfiles sync --no-pull`. Return later with `git checkout <branch>`.

---

## Backups

The app's backup policy (`backup.dir`, default `~/.bak/<app>/`) applies before a deployed file is overwritten:

- `original/` keeps the file as it was before dotfiles first touched it.
- `<timestamp>/` holds snapshots of earlier versions, up to `backup.max_backups` (default `3`); older ones are pruned.
- `--no-backup` skips creating them.

No command restores them. To restore, copy the file back by hand, for example `cp ~/.bak/git/original/.gitconfig ~/.gitconfig`. `dotfiles uninstall` restores the originals for you.
