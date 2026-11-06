# YAML Schema Reference

This document defines every YAML field recognized by the dotfiles system. Keep this in sync when adding or changing config fields.

---

## Profile Schema (`profiles/*.yaml`)

A profile says which tools an environment gets, by name. How to install and configure a tool lives with the tool, under `apps/`. Defining a tool selects it nowhere: it reaches a host only when a profile or `host.yaml` lists it.

### Top-Level Directives

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `extends` | string | No | — | Name of parent profile to inherit from (resolved as `profiles/<name>.yaml`). Supports chaining. |
| `exclude` | array of strings | No | `[]` | Tool names to remove from the inherited profile. An absent name is ignored. Mutually exclusive with `include`. |
| `include` | array of strings | No | `[]` | Tool names to keep from the inherited profile (all others removed). A name that isn't inherited is an error. Mutually exclusive with `exclude`. |
| `extra` | array | No | `[]` | Additional tools to append after inheritance and filtering. Same format as `packages`. |
| `packages` | array | No | `[]` | Ordered list of tools. Present in base profiles; inherited profiles use `exclude`/`include`/`extra` instead. |

### Entries in `packages` and `extra`

Each entry is a name or an inline definition, and one list may mix them:

```yaml
packages:
  - tmux                 # defined by apps/tmux/ or apps/os-packages.yaml
  - name: docker         # defined right here
    apt: docker.io
```

A plain name resolves to `apps/<name>/` if that folder has a `config.yaml`, otherwise to its entry in `apps/os-packages.yaml`. It's an error, aborting before any change, if a name is defined in neither or in both, or if a tool with an `install.sh` has no `install.check`.

An inline definition replaces any definition of that name, with no merging, and is how a hosts repo adds a tool `dotfiles` doesn't define. An inline entry that defines nothing (`- name: tmux`) is an error, as is a list item or line that can't be read.

A tool listed twice in the final list runs once, at its first position, with the later definition.

| Inline field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Tool name. Used for `exclude`/`include` matching. |
| `apt` | string | No | Package name for APT (Debian/Ubuntu). |
| `dnf` | string | No | Package name for DNF (Fedora/RHEL). |
| `brew` | string | No | Package name for Homebrew (macOS). |
| `custom.check` | string | No | Shell command to test if already installed (exit 0 = installed). Without it, `custom.script` runs on every sync. |
| `custom.script` | string | No | Install script path, relative to `apps/`. |
| `custom.dropin` | string | No | Shell drop-in file path, relative to `apps/`, copied to `${SHELL_SCRIPTS_DIR}` only when `check` passes after the install step (or there is no `check`). |
| `config.dir` | string | No | Folder under `apps/` containing `configure.sh` and `files/`. |
| `config.flags` | string | No | Extra flags passed to `configure.sh` (e.g., `--skip-git-setup`). |

### Processing Order

dotfiles processes the final list in three phases:
1. **Phase 1: OS packages** — Collect all `apt`/`dnf`/`brew` values, batch into one package manager call.
2. **Phase 2: Custom installs** — Run each tool's install script (if its `check` fails), then install its drop-in if `check` now passes (or there is no `check`); otherwise the log says the drop-in is held until the tool is installed.
3. **Phase 3: Configs** — For each tool with a config, call `apps/<name>/configure.sh deploy [flags]`.

**Example — base profile:**
```yaml
packages:
  - git
  - bash
  - lazygit
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
  - htop
  - name: docker
    apt: docker.io
```

---

## Tools (`apps/`)

    apps/
      os-packages.yaml      # tools that need only an OS package
      <name>/
        config.yaml         # what to deploy, plus how to install
        install.sh          # installs the tool (needs install.check)
        configure.sh        # sets up its config
        files/

### `apps/<name>/config.yaml`: `install:`

| Field | Type | Description |
|-------|------|-------------|
| `install.apt` / `dnf` / `brew` | string | OS package name for that package manager. |
| `install.check` | string | Shell command to test if already installed. Required when `install.sh` exists. |
| `install.dropin` | string | Shell drop-in, relative to the app folder. Requires `install.sh`, and the file must exist. |
| `install.configure_flags` | string | Extra flags passed to `configure.sh`. |

A tool's folder decides its phases: `install.sh` means a custom install, and `configure.sh` means a config phase. A folder without `config.yaml` doesn't define a tool, and selecting a folder that installs and configures nothing is an error.

### `apps/os-packages.yaml`

```yaml
packages:
  - curl                 # the same package name on apt, dnf and brew
  - name: fd             # when package names differ
    apt: fd-find
    dnf: fd-find
    brew: fd
```

---

## App Config Schema (`apps/<app>/config.yaml`)

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
| `files` | array of objects | No | `[]` | List of files to install from `apps/<app>/files/` to their destinations. |
| `files[].src` | string | Yes | — | Source filename, relative to `apps/<app>/files/`. |
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

Optional data-only repo, given with `--hosts-dir PATH` or env `DOTFILES_HOSTS_DIR`.

    dotfiles-hosts/
      profiles/<name>.yaml                    # profile, same schema as profiles/*.yaml + files:
      profiles/<name>/apps/<app>/files/<src>  # file overlays for this profile
      hosts/<hostname>/host.yaml              # host settings (required for the directory to apply)
      hosts/<hostname>/apps/<app>/files/<src> # file overlays for this host

`<app>` is the directory under `apps/` in dotfiles (e.g. `claude`); `<src>` is a `src` from that app's `config.yaml`.

### Resolution

- The host name is `--hostname`, else `hostname -s`.
- If `hosts/<hostname>/host.yaml` exists, its `profile:` is the base profile. An explicit `--profile` wins, with a warning.
- A profile name resolves to `dotfiles-hosts/profiles/<name>.yaml` first, then `profiles/<name>.yaml`. A hosts-dir profile that `extends:` its own name continues the lookup in dotfiles.
- `host.yaml`'s `exclude`/`include`/`extra` apply last.

### `host.yaml`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `profile` | string | Yes | Base profile. |
| `exclude` / `include` | array of strings | No | As in profiles (mutually exclusive). |
| `extra` | array | No | As in profiles. Same format as `packages` in a profile. |
| `files` | map | No | `<app>/<src>: replace|merge` per-file strategy. |

Hosts-repo profiles accept the same `files:` map.

### File layers and strategy

Layers, lowest to highest: `dotfiles/apps/<app>/files/<src>`, each hosts-dir profile in the chain (base-most first), the host directory.
`replace`: the highest layer that has the file wins. `merge`: live ⊕ all layers in order.
In practice the repo layers are pre-merged and then merged onto the live file: live ⊕ (dotfiles ⊕ profiles ⊕ host). This differs from strict left-to-right only when a lower layer sets a scalar or null and a higher layer sets an object at the same path; the result then keeps more live data.

Running an app's `configure.sh` directly deploys the dotfiles layer only (no hosts repo overlays); use `dotfiles sync` with the hosts repo to keep host overlays.
Strategy: last declaration among the app `config.yaml`, the hosts-dir profile `files:` maps (base-most first), and `host.yaml` `files:`.

### Errors

The run aborts before any change if the hosts repo is missing, `host.yaml` lacks `profile:`, a profile isn't found, the `extends` chain cycles, an overlay file or `files:` key names an unknown `src`, `merge` is set on a non-`.json` file, or a strategy other than `replace`/`merge` is used. Overlays for apps not in the package list are ignored with a warning. Invalid JSON during a merge fails only that file, leaves the live file untouched, and is reported in the summary. The app's version is then recorded as `incomplete`, so the next run retries.

### Removing managed keys

`merge` never deletes keys from the live file. To remove a key, delete it from the repo layer and from the live file by hand.

---

## Config file

`${DOTFILES_CONFIG:-~/.config/dotfiles/config.yaml}` holds per-host settings. It is optional. It is a flat YAML mapping of `key: value` lines and is parsed, never sourced:

    hosts_dir: ~/.local/share/dotfiles/dotfiles-hosts
    hostname: koi
    profile: complete
    auto_sync: on          # on/off (also true/false/yes/no)
    auto_sync_interval: 4h

- Only the first `: ` splits key from value, so a value may contain `: `.
- Blank lines and full-line `#` comments are ignored. A trailing ` #...` is a comment when the value is unquoted; a `#` inside quotes is kept. CRLF line ends are tolerated.
- One pair of matching quotes is stripped from a value. A leading `~` is expanded.
- Indented lines and list items (`- x`) are ignored with a warning, as are unknown keys and lines without `key: value`. The warning names `file:line`.
- An invalid `auto_sync`, `auto_sync_interval` or `hostname` aborts the command (in `--auto` it is reported, see Report).

The dotfiles repo is always the checkout the running `dotfiles` script lives in; there is no setting for it.

| Key | Default | Meaning |
|---|---|---|
| `hosts_dir` | `~/.local/share/dotfiles/dotfiles-hosts` if that directory exists, else none | dotfiles-hosts checkout |
| `hostname` | `hostname -s`, then `uname -n` | selects `hosts/<name>/`. Same rules as `--hostname`: non-empty, no `/`, not `.` or `..`. |
| `profile` | `complete` | used when there is no `host.yaml`; with one, it overrides it with a warning (same as `--profile`) |
| `auto_sync` | `on` | `off` disables the background sync. `true`/`yes` and `false`/`no` are accepted and normalized to `on`/`off`. |
| `auto_sync_interval` | `4h` | minimum gap between background syncs: `<n>m`, `<n>h` or `<n>d` |

Precedence: command-line flag > env `DOTFILES_HOSTS_DIR` (hosts dir only) > config file > default.

---

## Commands

    dotfiles <command> [options]

| Command | What it does |
|---|---|
| `init` | Guided per-host setup: asks a few questions, writes the config file, then runs the first sync. See Setting up a new machine. |
| `sync` | Pulls the dotfiles and hosts repos (fast-forward only), self-installs, then installs packages and deploys app configs. Idempotent: it installs what is new and upgrades what changed. |
| `push HOST...` | Ships the repos to each HOST over ssh and runs `dotfiles sync --no-pull` there. Meant for hosts without access to the repos. |
| `status` | Read-only. Shows the repos (branch and commit, or the pushed copy's `PUSHED` line), the version, host and profile, auto sync state, pending packages, per-app state and local edits. |
| `versions` | Lists tagged versions, newest first. See Versions. |
| `checkout REF` | Switches to a tag or commit, deploys it and stays there. See Versions. |
| `add` | Reviews local edits one by one and stages the accepted ones in a repo layer. See Local edits. |
| `uninstall` | Removes the deployed configs and restores the originals (unless `--no-backup`). Installs nothing and leaves tools in place. |
| `verify` | Checks every installation. Installs nothing. |
| `help` | Prints the usage text. |

### `sync`

- Pull is `git pull --ff-only` and nothing else. A failed pull (diverged, no network, no access) is a warning, not a failure: the repo is left untouched, the sync continues with what is checked out, and the exit code stays 0. A repo that is not a git work tree, or has no upstream branch, is skipped silently.
- `--no-pull` skips the pull of both repos.
- After the pull and self-install, a sync stops early with `Already up to date` when nothing changed since the last complete sync: the same commits, hosts dir, host, profile and shell scripts dir, with no uncommitted changes in either repo. It does not then check packages, tools or deployed files, so use `--force` to put back a deleted file (`--force` redeploys everything). A sync counts as complete only if nothing failed or is pending, every custom script has a check, and it was not an `--auto` run. Repos without git history (a pushed copy, a plain directory) never stop early. `--auto` runs can stop early too. `dotfiles uninstall` clears the record. It lives in `last-complete` in the state directory.
- `--auto` is the background mode used by the login drop-in (see Background sync). It never prompts. It installs OS packages and runs custom install scripts only when sudo works without a password and the run has no terminal; otherwise it only checks them and applies configs. Without `setsid` (macOS, for example) the run keeps the login terminal, so background sync never installs: it only reminds you, and a manual `dotfiles sync` does the install.
- A sync takes a lock in the state directory. A second concurrent sync exits with `dotfiles: sync already running` (an `--auto` run exits silently).
- `--dry-run` previews without changing anything: no lock, no pull, no self-install, and the state files are not touched.
- The other flags (`--profile`, `--hosts-dir`, `--hostname`, `--no-backup`, `--verbose`, `--quiet`, `--force`, `--skip-git-setup`, `--shell-scripts-dir`, `--log`) are listed in `dotfiles help`.

### `push`

    dotfiles push [--dry-run] HOST...

- Sends `git archive HEAD` of the dotfiles repo (and the hosts repo, if one is in use), so only committed state is shipped; uncommitted changes are not. If the source is not a git work tree, the plain directory is sent. Each snapshot gets a `PUSHED` file recording the source host, commit and time.
- The remote dotfiles path is where the remote `~/.local/bin/dotfiles` link points: the link is followed to its final target, and if that is a file named `dotfiles` in a directory containing `lib/`, the directory is used; otherwise (no link, a dangling link, some other target) the default `~/.local/share/dotfiles/dotfiles`. The remote hosts dir is `hosts_dir` from the remote `config.yaml` (`${DOTFILES_CONFIG:-~/.config/dotfiles/config.yaml}`), parsed the same way as `config_load`, else the default `~/.local/share/dotfiles/dotfiles-hosts`. A relative `hosts_dir` there is ignored with a warning.
- A remote target that is a git checkout is refused (run `dotfiles sync` there instead). An existing target is replaced only if it holds a `PUSHED` marker or is an empty directory; anything else is refused with `<host>:<path> exists and is not a pushed dotfiles copy; refusing to replace it`, so a wrong remote config line cannot delete user data. An existing pushed copy is replaced by swapping the directory, and the old copy is restored if the swap fails.
- It then runs `<remote dotfiles repo>/dotfiles sync --no-pull` with `ssh -t`, so prompts such as sudo work. The remote exit status is the push result. With several hosts, a failure on one is reported and the rest still run; the exit code is non-zero if any failed.
- `--dry-run` reports what would be sent and, if the remote already has dotfiles, runs a remote `sync --no-pull --dry-run`. Nothing is copied.
- `push --init` sets up a host that has no dotfiles yet. See Setting up a new machine.

### Versions

    dotfiles versions
    dotfiles checkout [--dry-run] REF

- `versions` marks the current tag, and any tag too old to check out (one from before `checkout` existed).
- `checkout` takes a tag, a commit or a branch. It refuses a checkout with uncommitted changes, an unknown ref and a version that is too old, leaving everything where it was. If the fetch fails, it uses what is already here. It then runs the new version's own `dotfiles sync --no-pull`.
- A tag or commit pins the machine: the checkout is left on a detached HEAD, which `sync` doesn't pull. A manual `sync` warns that it is pinned, even when nothing changed. `--auto` stays pinned without warning.
- `dotfiles checkout main` follows `main` again, with the latest commits.

### Local edits

- Each deploy records a hash of every file it wrote in `<state dir>/deployed/<app>.tsv`. The records hold hashes, not contents.
- An update leaves a file alone if its live copy differs from the record. If the repo changed the same file, it warns as well. With no record to compare, as on a machine that was behind when records were introduced, an older deployed file looks the same as an edit. `--force` takes the repo's version; the upgrade snapshot keeps yours unless `--no-backup` is given.
- `status` lists edited files, and a manual `sync` counts them.
- Merged files are expected to change, so only the keys the repo manages are compared.

`dotfiles add` shows a diff of each edit and asks whether to save it, then which layer to save it to: this host, a profile, or the default in the public repo.

- It copies the file into that layer and stages it. It never commits or pushes, so you review it again in git or lazygit.
- It only offers files dotfiles already manages, so `~/.ssh`, `~/.gitconfig.local` and your own drop-ins can't be swept in.
- Saving to the public default needs typing `public`, and isn't offered while pinned or without git.
- A target with uncommitted changes is skipped. A layer above the existing copy shadows lower layers from then on, and it warns when that happens.
- Merged files are display-only: the same key can be set in several layers, and copying the whole file would pull in local keys.
- There is no dry run: answer `n` to look without saving.

### `~/.bashrc`

`~/.bashrc` is an ordinary managed file: edit protection and `add` apply to it. A host-specific change can be saved as a host copy with `add`, which then shadows later changes to the public `.bashrc` on that host.

On first install, what is already in `~/.bashrc` moves to `<shell scripts dir>/00-local.sh`, which dotfiles doesn't manage. It loads after the managed file, so its settings win. A distro's unchanged `/etc/skel/.bashrc` isn't moved, because loading it last would override the managed prompt and aliases; the backup still has it.

Versions that appended to `~/.bashrc` are cleaned up the same way on the first deploy: the appended blocks go, and content outside them moves to `00-local.sh`. If a managed part differs from the repo, it may hold hand edits, so the old file is saved as `bashrc.before-cleanup.<timestamp>` in the app's backup directory, even with `--no-backup`, and sync warns.

### Self-install

A real `sync` (not `--dry-run`) installs two things, so the checkout becomes the installed command:

- `~/.local/bin/dotfiles`, a symlink to the running checkout's `dotfiles` script. It is created only when missing or dangling. A valid link to another checkout, or a regular file, is left alone with a warning (`~/.local/bin/dotfiles points at <X>; leaving it (remove the link to switch to <REPO>)`), so running a sync from another checkout (a worktree, say) never re-points the installed command.
- `<shell scripts dir>/90-dotfiles.sh` (default `~/.bashrc.d/`), a copy of `lib/login.sh` taken from the repo the link resolves to. It is managed by dotfiles; do not edit it.

`~/.local/bin` must be on `PATH`.

---

## Setting up a new machine

### Bootstrap

On a fresh machine, one command installs git if needed (apt, dnf or brew; it may ask for sudo), clones dotfiles to `~/.local/share/dotfiles/dotfiles`, and runs `dotfiles init`:

    curl -fsSL https://raw.githubusercontent.com/dahoff/dotfiles/main/bootstrap.sh | bash

Pass init flags after `bash -s --`, for example the hosts repo:

    curl -fsSL https://raw.githubusercontent.com/dahoff/dotfiles/main/bootstrap.sh | bash -s -- --hosts-dir git@github.com:me/dotfiles-hosts.git

`bootstrap.sh` consumes `--repo URL` and `--dir PATH` (or env `DOTFILES_REPO_URL`, `DOTFILES_DIR`) to choose where dotfiles is cloned from and to; every other argument goes to `dotfiles init`. If the target directory is already a checkout it is updated with a fast-forward-only pull; any other existing path is an error. Init reads its answers from `/dev/tty`, so the prompts work even though the script itself arrives on stdin. With no terminal at all, bootstrap runs `init --yes` instead of hanging.

### `init`

    dotfiles init [--hosts-dir URL|PATH|none] [--hostname NAME] [--profile NAME]
                  [--auto-sync on|off] [--interval <n>m|h|d] [--yes] [--no-sync]

Init asks for the hosts repo, hostname, profile, auto sync and interval, writes the config file and runs a sync. A flag answers its question without asking. Before the profile question it lists the profile names found in the hosts repo, then the dotfiles repo. It ends with a summary and a reminder to open a new terminal.

- `--hosts-dir`: a URL (contains `://`, or looks like `user@host:path`) is cloned to `~/.local/share/dotfiles/dotfiles-hosts`; a path must be an existing directory; `none` means no hosts repo. A failed clone exits 1 and writes nothing, except when an interactive run fails over ssh: init then shows a public key (your existing `~/.ssh/id_ed25519`, `id_ecdsa` or `id_rsa`, or a new `id_ed25519` with no passphrase, since background sync can't answer one) and where to add it, and retries when you press Enter (`q` stops). If the default hosts path already holds a pushed (non-checkout) copy, a URL is refused with an error naming the path; the copy is never deleted.
- `--hostname`: same rules as everywhere else (no `/`, not `.` or `..`); the prompt applies them too.
- `--profile`: a profile already set in the config stays active even if `hosts/<hostname>/host.yaml` exists.
- `--yes` accepts every default (or flag value) without prompting. `--no-sync` writes the config and skips the first sync.
- Without a terminal and without `--yes`, init exits 1 with `init is interactive; pass --yes to accept defaults`.

Init writes `${DOTFILES_CONFIG:-~/.config/dotfiles/config.yaml}` in the format described under Config file, with the header `# Written by dotfiles init on <date>`. It is written to `<config>.tmp` and then moved into place.

Re-running init is safe. The defaults offered are the values already in the config, so accepting every answer (or `--yes`) changes nothing. When the new content differs from an existing file, the old one is kept as `<config>.bak`; when nothing changed, no `.bak` is made. Run `dotfiles init` again whenever you want to change a setting.

### `push --init`

    dotfiles push --init [--yes] [--hostname NAME] [--profile NAME] [--auto-sync on|off] [--interval <n>m|h|d] HOST...

For a host that cannot reach the repos. It ships the repos as `push` does, then runs `dotfiles init` there (with `ssh -t`, so it can prompt) instead of `sync --no-pull`. The flags above are forwarded to the remote init and are valid only with `--init`; `--hostname` also needs exactly one HOST. A malformed value is refused before anything is shipped; whether a `--profile` exists is checked by the remote init, after shipping. When a hosts payload is shipped, the remote init gets `--hosts-dir <remote path>`; otherwise the remote keeps its own default. An existing remote config supplies the defaults, so `--yes` on a configured host does not wipe hand-set values such as `profile`.

---

## Background sync

The drop-in `90-dotfiles.sh` runs in interactive shells only. In each new terminal it:

1. Prints the report left by the previous background sync (if any), then deletes it.
2. While `pending` in the state directory is non-empty, prints at every terminal:

       dotfiles: lazygit, htop not installed (needs sudo) — run 'dotfiles sync'

   A sync that installs everything leaves `pending` empty, and the reminder stops.
3. Unless `DOTFILES_NO_AUTO_SYNC` is set to a non-empty value, or `dotfiles` is not on `PATH`, starts `dotfiles sync --auto` detached in the background (`setsid` when available, else a plain background subshell). Its output goes to `launch.log` in the state directory (overwritten each time), so failures before `last-sync.log` exists are visible.

`sync --auto` then:

- Pulls with a bounded git: ssh `ConnectTimeout=10`, `ServerAliveInterval=15`, `ServerAliveCountMax=2` (plus `BatchMode=yes`) unless `GIT_SSH_COMMAND` is set, `http.lowSpeedLimit=1000`/`http.lowSpeedTime=30`, and `timeout 300` where available. A timeout is a pull failure (warning). Only a repo whose top level is the path itself is pulled; a pushed copy inside a tracked directory is skipped.
- Exits at once, changing nothing, if `auto_sync: off` or the last sync is younger than `auto_sync_interval` (default `4h`). `auto_sync_interval: 0m` means always sync. A `last-sync` timestamp in the future (clock skew) does not throttle.
- Otherwise checks for passwordless sudo, then pulls both repos. The check needs both: the run has no terminal (`/dev/tty` cannot be opened; sudo reads passwords from the terminal, not stdin, and a run started without `setsid` may keep the login terminal), and `sudo -n true` succeeds (stdin `/dev/null`, the lock's fd closed, so it can never prompt or hang). `DOTFILES_TEST_HAS_TTY=1` is a test hook that makes the run act as if it had a terminal.
  - If the check passes, phases 1 and 2 run for real with stdin `/dev/null` for every install command. apt and dnf run as `sudo -n` (apt with `DEBIAN_FRONTEND=noninteractive`), and custom install scripts find a `sudo` shim first on `PATH` (`sudo-shim/` in the state directory) that always adds `-n`, so a `sudo` inside them fails instead of prompting. The log notes `passwordless sudo: installing packages`.
  - If not (or there is no `sudo`), phases 1 and 2 only check: nothing is installed, and missing packages and custom tools are recorded as pending.
  - Either way, whatever is still missing afterwards is pending, and a custom tool's drop-in is deployed only once its `check` passes.
- Writes its output to `last-sync.log`, touches `last-sync` even when it fails (so a broken sync does not retry in every terminal), and writes the report.

### Report

`report` holds one line per finding, each prefixed `dotfiles: `, in the order below. The file is absent when there is nothing to say.

| Line | Meaning |
|---|---|
| `dotfiles: updated a, b` | Apps whose config was successfully updated. |
| `dotfiles: <path>: pull failed (<reason>) — see <log>` | A pull failed; the repo was left as it was. |
| `dotfiles: sync failed (<items>) — see <log>` | Items that failed. An early abort before any app ran (missing hosts dir, ...) reports `sync failed (setup)`. An unusable config file (bad `auto_sync`, `auto_sync_interval` or `hostname`) reports `sync failed (config)` with the error text in the log. The config cannot supply the interval then, so the default `4h` throttle applies: the error is reported at most once per 4 hours. |

`<log>` is `last-sync.log`. A manual (non-`--auto`) sync removes a stale report. Pending packages are not in the report; the reminder above shows them at every terminal instead.

### State directory

`${XDG_STATE_HOME:-~/.local/state}/dotfiles/`:

| File | Content |
|---|---|
| `lock` | Lock held while a sync runs (a `lock.d/` directory where `flock` is unavailable). |
| `last-sync` | Empty file; its modification time is the last sync and drives the throttle. |
| `last-sync.log` | Output of the last `--auto` run. |
| `launch.log` | Output of the login drop-in's launch of `dotfiles sync --auto`; overwritten each time. |
| `report` | Message shown at the next terminal, removed once shown. |
| `sudo-shim/sudo` | Written by an `--auto` run that installs: runs the real `sudo` with `-n`, put first on `PATH` for install commands. |
| `pending` | Packages still to install, one per line. Shown by `dotfiles status` and by the reminder at every terminal. Refreshed by each real sync; empty when nothing is missing. |

### Turning it off

- Permanently: `auto_sync: off` in the config file.
- For one shell: `DOTFILES_NO_AUTO_SYNC=1` in the environment before the shell starts, for example `DOTFILES_NO_AUTO_SYNC=1 bash`.

---

## Undoing a change

Sync follows the repo, so undo in the repo:

- Revert and publish: `git revert <commit>` in the dotfiles (or hosts) repo, push it, and let each host pull on its next sync (or run `dotfiles sync`). For hosts that receive pushes, push again.
- Roll one host back without publishing: `dotfiles checkout <tag-or-commit>`. Return later with `dotfiles checkout main`. See Versions.

---

## Backups

The app's backup policy (`backup.dir`, default `~/.bak/<app>/`) applies before a deployed file is overwritten:

- `original/` keeps the file as it was before dotfiles first touched it.
- `<timestamp>/` holds snapshots of earlier versions, up to `backup.max_backups` (default `3`); older ones are pruned.
- `--no-backup` skips creating them.

No command restores them. To restore, copy the file back by hand, for example `cp ~/.bak/git/original/.gitconfig ~/.gitconfig`. `dotfiles uninstall` restores the originals for you.
