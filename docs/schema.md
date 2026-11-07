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
| `custom.check` | string | No | Shell command to test if already installed (exit 0 = installed). Without it, `custom.script` runs on every pull. |
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

Running an app's `configure.sh` directly deploys the dotfiles layer only (no hosts repo overlays); use `dotfiles pull` with the hosts repo to keep host overlays.
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
    update_check: on       # on/off (also true/false/yes/no)
    update_check_interval: 4h

- Only the first `: ` splits key from value, so a value may contain `: `.
- Blank lines and full-line `#` comments are ignored. A trailing ` #...` is a comment when the value is unquoted; a `#` inside quotes is kept. CRLF line ends are tolerated.
- One pair of matching quotes is stripped from a value. A leading `~` is expanded.
- Indented lines and list items (`- x`) are ignored with a warning, as are unknown keys and lines without `key: value`. The warning names `file:line`.
- An invalid `update_check`, `update_check_interval` or `hostname` aborts the command.
- `auto_sync` and `auto_sync_interval` are the old names of the two update check keys. They still load, and `init` writes the new names.

The dotfiles repo is always the checkout the running `dotfiles` script lives in; there is no setting for it.

| Key | Default | Meaning |
|---|---|---|
| `hosts_dir` | `~/.local/share/dotfiles/dotfiles-hosts` if that directory exists, else none | dotfiles-hosts checkout |
| `hostname` | `hostname -s`, then `uname -n` | selects `hosts/<name>/`. Same rules as `--hostname`: non-empty, no `/`, not `.` or `..`. |
| `profile` | `complete` | used when there is no `host.yaml`; with one, it overrides it with a warning (same as `--profile`) |
| `update_check` | `on` | `off` disables the update check that new terminals start. `true`/`yes` and `false`/`no` are accepted and normalized to `on`/`off`. |
| `update_check_interval` | `4h` | minimum gap between update checks: `<n>m`, `<n>h` or `<n>d` |

Precedence: command-line flag > env `DOTFILES_HOSTS_DIR` (hosts dir only) > config file > default.

---

## Commands

    dotfiles <command> [options]

| Command | What it does |
|---|---|
| `init` | Guided per-host setup: asks a few questions, writes the config file, then runs the first `pull`. On a host already set up, it can reset. See Setting up a new machine. |
| `pull` | Fetches the dotfiles and hosts repos (fast-forward only), self-installs, then installs packages and deploys app configs. Keeps local edits and holds back conflicts. |
| `pull --remote HOST...` | Sends this machine's committed repos to each HOST over ssh and runs `dotfiles pull --no-fetch` there. See Remote hosts. |
| `init --remote HOST...` | The same, but runs `dotfiles init` there. First-time setup of a host that can't reach the repos. |
| `sync` | Fast-forwards both repos, runs `add`, then `pull`. Needs a terminal. |
| `status` | Read-only. Shows the repos (branch and commit, or the pushed copy's `PUSHED` line), the version, host and profile, update check state, pending packages, per-app state, and the lists described under Local edits. |
| `versions` | Lists tagged versions, newest first. See Versions. |
| `checkout REF` | Switches to a tag or commit, deploys it and stays there. See Versions. |
| `add` | Reviews local edits and conflicts one by one and stages the accepted ones in a repo layer. See Local edits. |
| `add --all` | The same, and asks again about dismissed edits. |
| `uninstall` | Removes the deployed configs and restores the originals (unless `--no-backup`). Lists your local changes first and always takes a snapshot; if that fails, nothing is restored. Installs nothing and leaves tools in place. |
| `verify` | Checks every installation. Installs nothing. |
| `help` | Prints the usage text. |

`dotfiles push` is gone. Running it prints which commands replace it: `pull --remote` (was `push`) and `init --remote` (was `push --init`). A host set up with the old `push` has records from the older version, so run `init --remote` on it once (after reviewing its edits, if it has git) before using `pull --remote`.

### `pull`

- The fetch is `git pull --ff-only` and nothing else. A failed fetch (no network, no access) is a warning, not a failure: the repo is left untouched, the pull continues with what is checked out, and the exit code stays 0. A repo that is not a git work tree, or has no upstream branch, is skipped silently.
- A fetch that is blocked, because the repo has diverged or local changes are in the way, stops the pull before anything is deployed. It prints the commands to fix it: commit or set aside your changes, `git pull --rebase`, push if the repo has commits of its own, then `dotfiles pull`.
- `--no-fetch` skips the fetch of both repos. `checkout` and `pull --remote` use it.
- Only committed repo content is deployed: what `HEAD` holds, whatever the working tree says. A repo with uncommitted files is named in a warning, and `status` lists them as `uncommitted files:`. A repo with no git deploys as it stands.
- After the fetch and self-install, a pull stops early with `Already up to date` when nothing changed since the last complete pull: the same commits, hosts dir, host, profile and shell scripts dir. An open conflict turns the early stop off, so later pulls evaluate it again. The early stop does not check packages, tools or deployed files, so use `--force` to put back a deleted file. A pull counts as complete only if nothing failed, is pending or was held back as a conflict, every custom script has a check, and it was not a `--force PATH` run. Repos without git history (a pushed copy, a plain directory) never stop early. `dotfiles uninstall` clears the record. It lives in `last-complete` in the state directory.
- A pull takes a lock in the state directory. A second concurrent one exits with `dotfiles: pull already running`.
- `--dry-run` previews without changing anything: no lock, no fetch, no self-install, and the state files are not touched.
- `--force` takes the repo's version of every file, keeping local-only keys in merged files, and always takes a snapshot first.
- `--force PATH` does the same for one file only and touches nothing else, packages included. `PATH` is a deployed config file or a drop-in (a tool's, or `90-dotfiles.sh`). It refuses a path that isn't managed here.
- The other flags (`--profile`, `--hosts-dir`, `--hostname`, `--no-backup`, `--verbose`, `--quiet`, `--skip-git-setup`, `--shell-scripts-dir`, `--log`) are listed in `dotfiles help`.

### `sync`

`sync` runs `add`, then `pull`, each as its own process with its own lock. It first fast-forwards both repos, so that `add` compares against the incoming commits and sees conflicts they cause. A failure there is a warning, and `add` still runs on what is checked out; the `pull` reports it again. With no terminal it refuses, because `add` asks questions; `pull` works unattended. `--no-fetch` skips the update before `add` and the fetch in `pull`. `--dry-run` previews the `pull`; `add` has no dry run. Quitting `add` partway does not stop the `pull`, which keeps conflicts and unanswered edits.

### Remote hosts

    dotfiles pull --remote [--dry-run] [--force] HOST...
    dotfiles init --remote [--dry-run] [init flags] HOST...

- Sends `git archive HEAD` of the dotfiles repo (and the hosts repo, if one is in use), so only committed state is shipped; uncommitted changes are not. If the source is not a git work tree, the plain directory is sent. Each snapshot gets a `PUSHED` file recording the source host, commit and time. `pull --remote` warns when a repo here is behind its upstream, because the host gets what is committed here.
- The remote dotfiles path is where the remote `~/.local/bin/dotfiles` link points: the link is followed to its final target, and if that is a file named `dotfiles` in a directory containing `lib/`, the directory is used; otherwise (no link, a dangling link, some other target) the default `~/.local/share/dotfiles/dotfiles`. The remote hosts dir is `hosts_dir` from the remote `config.yaml` (`${DOTFILES_CONFIG:-~/.config/dotfiles/config.yaml}`), parsed the same way as `config_load`, else the default `~/.local/share/dotfiles/dotfiles-hosts`. A relative `hosts_dir` there is ignored with a warning.
- A remote target that is a git checkout is refused (run `dotfiles pull` there instead). An existing target is replaced only if it holds a `PUSHED` marker or is an empty directory; anything else is refused with `<host>:<path> exists and is not a pushed dotfiles copy; refusing to replace it`, so a wrong remote config line cannot delete user data. An existing pushed copy is replaced by swapping the directory, and the old copy is restored if the swap fails.
- It then runs `<remote dotfiles repo>/dotfiles pull --no-fetch` (or `init`) with `ssh -t`, so prompts such as sudo work, and conflicts show in your terminal. The remote exit status is the result. With several hosts, a failure on one is reported and the rest still run; the exit code is non-zero if any failed. `--force` is passed through to the remote pull.
- `--dry-run` reports what would be sent and, if the remote already has dotfiles, runs a remote `pull --no-fetch --dry-run`. Nothing is copied.
- A host with no git can't keep a save made by `add`: the next send replaces the directory. `add` there offers dismiss only. Copy an edit back by hand.
- `init --remote` sets up a host that has no dotfiles yet. See Setting up a new machine.

### Versions

    dotfiles versions
    dotfiles checkout [--dry-run] REF

- `versions` marks the current tag, and any tag too old to check out (one from before the records of local edits existed).
- `checkout` takes a tag, a commit or a branch. It refuses a checkout with uncommitted changes, an unknown ref and a version that is too old, leaving everything where it was. If the fetch fails, it uses what is already here. It then runs the new version's own `dotfiles pull --no-fetch`.
- A tag or commit pins the machine: the checkout is left on a detached HEAD, which `pull` doesn't fetch. A manual `pull` warns that it is pinned, even when nothing changed. The update check stays pinned without warning.
- `dotfiles checkout main` follows `main` again, with the latest commits.

### Local edits

Each managed file, or each key of a merged JSON file, has two saved copies in `<state dir>/records/<app>/`, mode `0600` in directories of mode `0700`:

| Copy | Path | Holds | Used by |
|---|---|---|---|
| Repo copy | `repo/<src>` | The last repo version accepted | `pull`, to see what the repo changed |
| Review copy | `review/<src>` | The live file as of your last review | `add`, to see what's new |

`manifest.tsv` in the same folder lists each file's source, destination and strategy. Merged JSON is compared per key, everything else per file, and arrays as one value.

`pull` asks of each file or key whether you changed it (live against repo copy) and whether the repo did (repo now against repo copy):

| You changed it | The repo changed it | `pull` does |
|---|---|---|
| No | Yes | Applies it |
| No | No | Nothing |
| Yes | No | Keeps yours |
| Yes | Yes, to your value | Updates its records only |
| Yes | Yes, to something else | **Conflict:** keeps yours and warns on every pull until resolved |

- A deploy updates the review copy only for what it applied, so an edit nobody reviewed is still flagged later.
- A key the repo stops managing is removed from the live file if its value still matches the repo copy; otherwise it is kept. A file removed from the repo is left in place and no longer tracked.
- A key that changes between an object and a plain value counts as a conflict on the whole subtree.
- Switching a file between replace and merge takes a snapshot and is treated as a fresh deploy.
- Invalid JSON fails only that file, which is left untouched and retried on the next pull.
- Records are written per item after the write, so an interrupted run recomputes safely.
- A host with records in the old layout (`<state dir>/deployed/*.tsv`) refuses `pull` and `add` until `dotfiles init` has run. Review pending edits with the old `add` before updating. `init` snapshots every managed file, drops the old records and starts fresh ones.
- `--force` takes the repo's version; the snapshot keeps yours.

`status` shows these lists, each under its own label: `updates available:`, `unreviewed changes:`, `conflicts:`, `dismissed:`, `saved, not committed:` and `uncommitted files:`. Before the first `pull` with these records, `unreviewed changes:` says `not tracked yet`.

`dotfiles add` shows each unreviewed edit and each conflict and asks for one of three answers:

- **Save** asks which layer to use (this host, any profile or the public default), copies the change there and stages it. It never commits or pushes. Merged files save only that key; other files save the whole file. A saved edit isn't asked about again while that layer holds the value, and discarding the staged change brings it back.
- **Dismiss** keeps the change local; `add` asks again only if the value changes. On a conflict it also accepts the repo's current version as the new starting point.
- **Skip** asks again next time. Quitting partway does the same for anything unanswered.

`add --all` also asks again about dismissed edits. When the review ends, `add` lists the staged files in each repo and tells you to commit and push them.

- It only offers files dotfiles manages, so `~/.ssh`, `~/.gitconfig.local` and your own drop-ins can't be swept in. A tool's drop-in is offered the public default only, and `90-dotfiles.sh` only dismiss and skip.
- Layers offered: the host layer only when the host directory in the hosts repo has a `host.yaml` in its working copy; each profile in the chain; the public default. A repo with no git, a detached hosts repo and a pinned public repo offer no layers, and `add` says why.
- Saving to the public default shows the value and needs typing `public`.
- A save to a layer file with uncommitted changes is allowed only if `add` made them; otherwise that target is skipped.
- Saving a replaced file to a layer that has no copy of it creates one, which masks lower layers from then on. Saving below a layer that already has the file or key is allowed, with a message that the higher layer still wins.
- A conflict in a replaced file shows your change and the repo's separately; saving the whole file would undo the repo's change, so `add` warns and asks you to confirm. A key you deleted can be dismissed but not saved. An array save hides later repo changes to the list.
- `add` needs a terminal and has no dry run: answer `n` to look without saving.
- To resolve a conflict without `add`, take the repo's version with `pull --force PATH`.

### `~/.bashrc`

`~/.bashrc` is an ordinary managed file: edit protection and `add` apply to it. A host-specific change can be saved as a host copy with `add`, which then shadows later changes to the public `.bashrc` on that host.

On first install, a custom `~/.bashrc` is replaced like any other file, and a warning says the old content is no longer loaded. The warning names the original in the app's `original/` backup when that is the file just replaced. If it isn't (on a reinstall after an uninstall, `original/` still holds the first one), it names the snapshot that holds it. A distro's unchanged `/etc/skel/.bashrc` and an empty file get no warning.

`~/.bashrc` still loads everything in `~/.bashrc.d/`, so an existing `00-local.sh` keeps working. Dotfiles leaves it alone and creates nothing there.

### Self-install

A real `pull` (not `--dry-run`) installs two things, so the checkout becomes the installed command:

- `~/.local/bin/dotfiles`, a symlink to the running checkout's `dotfiles` script. It is created only when missing or dangling. A valid link to another checkout, or a regular file, is left alone with a warning (`~/.local/bin/dotfiles points at <X>; leaving it (remove the link to switch to <REPO>)`), so running a pull from another checkout (a worktree, say) never re-points the installed command.
- `<shell scripts dir>/90-dotfiles.sh` (default `~/.bashrc.d/`), a copy of `lib/login.sh` taken from the repo the link resolves to. It goes through the normal deploy, so edit protection applies to it too. It is managed by dotfiles; do not edit it.

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
                  [--update-check on|off] [--interval <n>m|h|d] [--yes] [--no-sync]

Init asks for the hosts repo, hostname, profile, update check and interval, writes the config file and runs a `pull`. A flag answers its question without asking. Before the profile question it lists the profile names found in the hosts repo, then the dotfiles repo. It ends with a summary and a reminder to open a new terminal.

- `--hosts-dir`: a URL (contains `://`, or looks like `user@host:path`) is cloned to `~/.local/share/dotfiles/dotfiles-hosts`; a path must be an existing directory; `none` means no hosts repo. A failed clone exits 1 and writes nothing, except when an interactive run fails over ssh: init then shows a public key (your existing `~/.ssh/id_ed25519`, `id_ecdsa` or `id_rsa`, or a new `id_ed25519` with no passphrase, since the update check can't answer one) and where to add it, and retries when you press Enter (`q` stops). If the default hosts path already holds a pushed (non-checkout) copy, a URL is refused with an error naming the path; the copy is never deleted.
- `--hostname`: same rules as everywhere else (no `/`, not `.` or `..`); the prompt applies them too.
- `--profile`: a profile already set in the config stays active even if `hosts/<hostname>/host.yaml` exists.
- `--yes` accepts every default (or flag value) without prompting. `--no-sync` writes the config and skips the pull.
- Without a terminal and without `--yes`, init exits 1 with `init is interactive; pass --yes to accept defaults`.
- If `hosts/<hostname>/host.yaml` exists only in the working copy, init stops before writing the config: it isn't committed, so a pull wouldn't use it. Commit it, then run init again. Profiles are validated against the committed tree.

Init writes `${DOTFILES_CONFIG:-~/.config/dotfiles/config.yaml}` in the format described under Config file, with the header `# Written by dotfiles init on <date>`. It is written to `<config>.tmp` and then moved into place.

Re-running init is safe. The defaults offered are the values already in the config, so accepting every answer (or `--yes`) changes nothing. When the new content differs from an existing file, the old one is kept as `<config>.bak`; when nothing changed, no `.bak` is made.

**On a host that already has records, init can reset.** After saving the answers it asks whether to reset every managed file to the repo layers, defaulting to no. No runs a normal `pull`, so changing the hostname or profile wipes nothing. A reset:

- Updates the repos first (fast-forward only), then lists what would be lost: unreviewed, conflicting and dismissed changes, local-only keys in merged files, files no longer managed, and files dotfiles has no record of writing that differ from the repo's.
- Doesn't offer the question when it can't tell what would be lost (the profile or overlays don't load): it says why and runs a normal `pull`.
- Needs `reset` typed to confirm, takes a snapshot of every managed file and prints its path, then runs `pull --no-fetch` with every managed file replaced by what the repo layers produce, local-only keys removed, and fresh records.
- Never happens with `--yes` or with no terminal: init then runs the normal `pull`.
- Leaves files dotfiles doesn't manage alone, such as `00-local.sh` and `.gitconfig.local`.
- Is all or nothing; `pull --force PATH` handles single files but keeps local-only keys. `init --remote` behaves the same way on the host.

On a host with records from an older version there is no reset to offer: init snapshots every managed file, removes the old records and runs a `pull` that starts fresh ones.

### `init --remote`

    dotfiles init --remote [--dry-run] [--yes] [--hostname NAME] [--profile NAME] [--update-check on|off] [--interval <n>m|h|d] HOST...

For a host that cannot reach the repos. It ships the repos as `pull --remote` does, then runs `dotfiles init` there (with `ssh -t`, so it can prompt) instead of `pull --no-fetch`. The flags above are forwarded to the remote init and are valid only with `init --remote`; `--hostname` also needs exactly one HOST. A malformed value is refused before anything is shipped; whether a `--profile` exists is checked by the remote init, after shipping. When a hosts payload is shipped, the remote init gets `--hosts-dir <remote path>`; otherwise the remote keeps its own default. An existing remote config supplies the defaults, so `--yes` on a configured host does not wipe hand-set values such as `profile`.

---

## Update check

The drop-in `90-dotfiles.sh` runs in interactive shells only. It never deploys or installs anything. In each new terminal it:

1. Prints the report left by the previous check (if any), then deletes it.
2. While `pending` in the state directory is non-empty, prints at every terminal:

       dotfiles: lazygit, htop not installed (needs sudo) — run 'dotfiles pull'

   A pull that installs everything leaves `pending` empty, and the reminder stops.
3. Unless `DOTFILES_NO_UPDATE_CHECK` is set to a non-empty value, or `dotfiles` is not on `PATH`, starts `dotfiles check-updates` detached in the background (`setsid` when available, else a plain background subshell). Its output goes to `launch.log` in the state directory (overwritten each time), so a failure to start is visible.

`dotfiles check-updates` is the internal command behind this; it is not in `dotfiles help`. It:

- Exits at once, changing nothing, if `update_check: off`, if another run or a pull holds the lock, or if the last check is younger than `update_check_interval` (default `4h`). `update_check_interval: 0m` means always check. A `last-check` timestamp in the future (clock skew) does not throttle.
- Touches `last-check`, even when the fetch fails, so an offline machine does not retry at every terminal.
- Runs `git fetch` on the dotfiles repo and the hosts repo, with a bounded git: ssh `ConnectTimeout=10`, `ServerAliveInterval=15`, `ServerAliveCountMax=2` (plus `BatchMode=yes`) unless `GIT_SSH_COMMAND` is set, `http.lowSpeedLimit=1000`/`http.lowSpeedTime=30`, and `timeout 300` where available. A timeout counts as a failed fetch. A pinned repo, a pushed copy, a repo with no upstream and a repo that isn't a checkout of its own are skipped.
- Never changes `HEAD`, the working tree, the live files or any package.
- Writes the report only when a repo has new commits upstream.

### Report

`report` holds one line, in the file `report` in the state directory. The file is absent when there is nothing to say; an existing report is left alone when a check finds nothing new.

| Line | Meaning |
|---|---|
| `dotfiles: updates available (dotfiles, hosts) — run 'dotfiles pull'` | The named repos have new commits upstream. |

A manual `pull` removes a stale report. `status` shows `updates available:` itself. Pending packages are not in the report; the reminder above shows them at every terminal instead.

### State directory

`${XDG_STATE_HOME:-~/.local/state}/dotfiles/`:

| File | Content |
|---|---|
| `lock` | Lock held while a pull or an update check runs (a `lock.d/` directory where `flock` is unavailable). |
| `records/` | The saved copies behind local-edit detection. See Local edits. |
| `last-check` | Empty file; its modification time is the last update check and drives the throttle. |
| `last-sync` | Empty file; touched by each `pull`. |
| `last-complete` | The fingerprint of the last complete pull, for the early stop. |
| `launch.log` | Output of the login drop-in's launch of `dotfiles check-updates`; overwritten each time. |
| `report` | Message shown at the next terminal, removed once shown. |
| `pending` | Packages still to install, one per line. Shown by `dotfiles status` and by the reminder at every terminal. Refreshed by each real pull; empty when nothing is missing. |

### Turning it off

- Permanently: `update_check: off` in the config file, or `dotfiles init --update-check off`.
- For one shell: `DOTFILES_NO_UPDATE_CHECK=1` in the environment before the shell starts, for example `DOTFILES_NO_UPDATE_CHECK=1 bash`.

---

## Undoing a change

Pull follows the repo, so undo in the repo:

- Revert and publish: `git revert <commit>` in the dotfiles (or hosts) repo, push it, and let each host pick it up with `dotfiles pull`. For hosts that receive sends, run `dotfiles pull --remote HOST` again.
- Roll one host back without publishing: `dotfiles checkout <tag-or-commit>`. Return later with `dotfiles checkout main`. See Versions.

---

## Backups

The app's backup policy (`backup.dir`, default `~/.bak/<app>/`) applies before a deployed file is overwritten:

- `original/` keeps the file as it was before dotfiles first touched it.
- `<timestamp>/` holds snapshots of earlier versions, up to `backup.max_backups` (default `3`); older ones are pruned.
- `--no-backup` skips creating them.

No command restores them. To restore, copy the file back by hand, for example `cp ~/.bak/git/original/.gitconfig ~/.gitconfig`. `dotfiles uninstall` restores the originals for you.
