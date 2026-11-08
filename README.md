# dotfiles

One command to set up a machine's tools and config, and keep it up to date. It installs packages, deploys config files, tells you from new terminals when updates are available, and helps you save local edits back to a repo. Per-machine differences live in an optional private repo, so this public repo stays free of personal settings.

## Command reference

Find what you want to do, then follow the link for details. For flags, see [Flags](#flags).

### Update this machine

| Command | What it does |
|---|---|
| [`dotfiles pull`](#pull) | Updates the repos, installs missing tools, deploys changed config. Keeps your edits and reports conflicts. |
| [`dotfiles pull --no-fetch`](#pull) | Deploys what's already checked out, without fetching. |
| [`dotfiles sync`](#sync) | `add`, then `pull`: review your edits first, then update. Needs a terminal. |
| [`dotfiles status`](#status) | Shows updates available, your edits, conflicts and uncommitted repo files. Changes nothing. |
| [`dotfiles versions`](#versions-and-checkout) | Lists tagged versions. |
| [`dotfiles checkout REF`](#versions-and-checkout) | Pins this machine to a tag or commit. `checkout main` follows `main` again. |

### Save local edits

| Command | What it does |
|---|---|
| [`dotfiles add`](#add) | Walks through your edits: save one to a repo layer (staged, not committed), dismiss it or skip it. |
| [`dotfiles add --all`](#add) | Also asks again about edits you dismissed. |
| [`dotfiles sync`](#sync) | Runs `add`, then `pull`. |

### Resolve conflicts

| Command | What it does |
|---|---|
| [`dotfiles add`](#resolving-conflicts) | Save your version to a layer, or dismiss it to accept the repo's version as the new starting point. |
| [`dotfiles pull --force PATH`](#resolving-conflicts) | Takes the repo's version of that one file. |
| [`dotfiles pull --force`](#pull) | Takes the repo's version of every file. |

### Set up or update a remote host

For a host that can't reach the repos. This machine sends its committed repos over ssh.

| Command | What it does |
|---|---|
| [`dotfiles init --remote HOST...`](#remote-hosts) | First setup of each host. |
| [`dotfiles pull --remote HOST...`](#remote-hosts) | Updates each host. |

### Set up, reset or remove

| Command | What it does |
|---|---|
| [`dotfiles init`](#init) | First setup of this machine. Run again to change settings, or to reset every managed file to the repo layers. |
| [`dotfiles uninstall`](#uninstall) | Removes deployed config and restores your original files. |

### Check

| Command | What it does |
|---|---|
| [`dotfiles status`](#status) | Shows updates available, your edits, conflicts and uncommitted repo files. Changes nothing. |
| [`dotfiles verify`](#verify-and-help) | Checks that every deployed file exists. |
| [`dotfiles help`](#verify-and-help) | Lists every command and flag. |

More: [Set up a new machine](#set-up-a-new-machine) · [Command details](#command-details) · [Flags](#flags) · [Day-to-day](#day-to-day) · [Add an app](#add-an-app) · [Layered config](#layered-config) · [Troubleshooting](#troubleshooting)

## Set up a new machine

You need bash 4 or newer and one of `apt`, `dnf` or `brew`. macOS ships bash 3.2, so install a newer one from Homebrew first.

```bash
curl -fsSL https://raw.githubusercontent.com/dahoff/dotfiles/main/bootstrap.sh | bash
```

This installs git if it's missing, clones this repo to `~/.local/share/dotfiles/dotfiles`, and runs `dotfiles init`. If you have a [hosts repo](#the-hosts-repo), pass it in:

```bash
curl -fsSL https://raw.githubusercontent.com/dahoff/dotfiles/main/bootstrap.sh | bash -s -- --hosts-dir git@github.com:you/dotfiles-hosts.git
```

`init` asks for the following, then runs the first `pull`:

| Question | Default | Notes |
|---|---|---|
| Hosts repo | `none` | A git URL, a local path, or `none`. If an ssh clone fails, it shows you a public key to add, then retries. |
| Hostname | `hostname -s` | Selects `hosts/<hostname>/` in the hosts repo. |
| Profile | `complete` | Not asked if `hosts/<hostname>/host.yaml` already selects one. |
| Update check | `on` | Whether new terminals check for updates and tell you. They never deploy anything. |
| Check interval | `4h` | Format is `<n>m`, `<n>h` or `<n>d`. |

The first pull may ask for your sudo password to install packages, and for your git name and email if none are set. When it finishes, **open a new terminal** to load the new shell setup.

Your existing settings are kept:

- `~/.gitconfig` moves to `~/.gitconfig.local`, which the managed config includes.
- A custom `~/.bashrc` is replaced, and a warning says where the old copy is: its content is no longer loaded. Copy back what you want, and `dotfiles add` offers to save it to a layer.
- Every file that gets replaced is first copied to `~/.bak/<app>/original/`, and a snapshot of all managed files is always taken.
- Files dotfiles doesn't manage are never touched, including any `~/.bashrc.d/*.sh` of your own.

Answers are saved in `~/.config/dotfiles/config.yaml`. Run `dotfiles init` again at any time to change them.

**A machine that can't reach the repos:** see [Remote hosts](#remote-hosts).

**Moving a machine from an older version of dotfiles:** the new `add` refuses the old records, so review pending edits with the old `dotfiles add` **before** you update. Then update, and run `dotfiles init` again: it snapshots every managed file and starts fresh records.

**Choosing what gets installed:** there are two built-in profiles.

| Profile | Tools |
|---|---|
| `complete` | git, bash, tmux, vim, curl, fzf, jq, tree, lazygit, ssh, lazyssh, scripts, claude |
| `minimal` | `complete` without claude, lazygit and lazyssh |

## Command details

### pull

Fetches both repos (fast-forward only), installs missing tools, and deploys config. It stops early with `Already up to date` when nothing has changed, unless a conflict is open.

For each file it compares your live copy with the repo:

| You changed it | The repo changed it | Pull does |
|---|---|---|
| No | Yes | Applies the repo's version |
| Yes | No | Keeps yours |
| Yes | Yes, to your value | Updates its records only |
| Yes | Yes, to something else | **Conflict:** keeps yours, warns on every pull until [resolved](#resolving-conflicts) |

Only **committed** repo content is deployed. If a repo has uncommitted files, `pull` names them and doesn't deploy them. Merged JSON files such as Claude's `settings.json` are compared per key.

- `--no-fetch` skips the fetch and deploys what's checked out.
- `--force` takes the repo's version of every file. Local-only keys in merged files are kept, and a snapshot is always taken first.
- `--force PATH` does the same for one file; see [Resolving conflicts](#resolving-conflicts).
- If a repo has diverged, or upstream changed a file you saved, `pull` stops and prints the git commands to fix it.
- A machine pinned by `checkout` warns and doesn't fetch.
- `pull` works unattended, so cron and scripts can use it.

### sync

`dotfiles sync` is `add`, then `pull`, for when you want to review your edits before updating. It fast-forwards both repos first, so `add` sees conflicts from incoming changes. If that update fails, it warns and `add` still runs on what's here. It needs a terminal, and `--dry-run` previews only the `pull`.

### status

Read-only. It shows the repos, version, host, profile, last check, missing packages and each tool's state, then these lists, each under its own label:

| Label | Meaning |
|---|---|
| `updates available:` | Changes `pull` would bring in: apps whose files changed, and commits already fetched but not merged in either repo. |
| `unreviewed changes:` | Local edits `add` hasn't asked about yet. |
| `conflicts:` | You and the repo both changed them; yours is kept. |
| `dismissed:` | Edits you kept local on purpose. `add --all` asks again. |
| `saved, not committed:` | Edits a repo layer holds with uncommitted changes. Commit them, then run `pull`. |
| `held in a lower layer:` | Edits a committed layer holds, below a layer that wins, so they stay local on this host. `add` leaves them out; `add --all` offers them, and dismissing one moves it to `dismissed:`. |
| `uncommitted files:` | Repo files that aren't committed, so aren't deployed. |

### versions and checkout

`dotfiles versions` lists tagged versions. `dotfiles checkout REF` switches to a tag, commit or branch and deploys it with `pull --no-fetch`. A tag or commit pins the machine, so `pull` won't move it. `dotfiles checkout main` follows `main` again. It refuses if the repo has uncommitted changes, and refuses a version from before this design as too old.

### add

`dotfiles add` shows each local edit and asks what to do. It needs a terminal, and never commits or pushes. It only offers files dotfiles manages.

| Answer | Effect |
|---|---|
| **Save** | Asks which layer: this host, a profile or the public default. Copies the change there and stages it. Merged files save only that key, other files the whole file. |
| **Dismiss** | Keeps the change local, and `add` doesn't ask again unless the value changes. |
| **Skip** | Asks again next time. Quitting partway skips everything unanswered. |

When the review ends, `add` lists what it staged in each repo. Commit and push those yourself; other machines don't get them until you do. If you later discard a staged save, `add` asks again.

- `dotfiles add --all` also asks again about dismissed edits.
- The host layer is offered only when the host's directory in the hosts repo has a `host.yaml`. A detached hosts repo, or a public repo pinned by `checkout`, offers no layers, and `add` says why.
- Saving to the public repo shows the value and needs you to type `public`.
- Saving a replaced file to a layer that has no copy creates one, which then hides later changes to the public file on that host. `add` says so before it saves.
- Arrays are saved as one value, so a save hides later repo changes to that list.
- A host with no git (a [remote host](#remote-hosts)) can only dismiss, because the next `pull --remote` would wipe a save.
- Your own `~/.bashrc.d/*.sh` and `~/.gitconfig.local` are never offered.
- `add` has no dry run: answer `k` (or press Enter) to skip each edit and look without saving. The prompt's options are `s` save, `d` dismiss, `k` skip (the default) and `q` quit.

### Resolving conflicts

A conflict means you and the repo changed the same file, or the same key in a merged file, to different things. Your version is kept and `pull` warns each time. Resolve it one of these ways:

- **`dotfiles add`:** save your version to a layer, or dismiss it. Dismissing accepts the repo's current version as the new starting point and stops the warning. For a replaced file, `add` shows your change and the repo's separately and warns before saving, because saving the whole file undoes the repo's change.
- **`dotfiles pull --force PATH`:** takes the repo's version of that file only, and touches nothing else. `PATH` can be a deployed config file or a drop-in. It refuses a path dotfiles doesn't manage. It keeps local-only keys in merged files and takes a snapshot first.

### init

First setup is described in [Set up a new machine](#set-up-a-new-machine).

On a machine that's already set up, `init` saves your answers, then asks whether to reset. The default is no, which runs a normal `pull`, so changing the hostname or profile wipes nothing.

A reset makes every managed file exactly what the repo layers produce, removes local-only keys, and starts fresh records. It resets to the repo, not to the files from before dotfiles; that's what `uninstall` does.

- It updates the repos first, then lists everything that would be lost. If it can't tell what would be lost (the profile or overlays don't load), it doesn't offer a reset.
- You must type `reset` to confirm, and it prints the snapshot's path.
- `--yes`, or no terminal, never resets.
- Files dotfiles doesn't manage, such as `~/.gitconfig.local`, are left alone.
- To reset one file only, use `pull --force PATH`.
- `init` refuses a `host.yaml` that isn't committed yet: commit it, then run `init` again.

Settings flags: `--hosts-dir URL|PATH|none`, `--hostname NAME`, `--profile NAME`, `--update-check on|off`, `--interval <n>m|h|d`, `--yes` and `--no-sync` (write the config only).

### Remote hosts

For a host that can't reach the repos, such as a machine behind a firewall. These commands run on **this** machine and send its committed repos to the host over ssh. The host's copy isn't a git checkout, so it can't fetch.

```bash
dotfiles init --remote user@host      # first setup; accepts init's flags
dotfiles pull --remote user@host      # update; --force is passed through
```

`pull --remote` warns if the repos here are behind their remotes, since the host gets what's committed here. Only committed changes are sent, and conflicts show in your terminal. An edit made on such a host has to be copied back by hand. `init --remote` resets a host the way [`init`](#init) does.

### uninstall

Removes deployed config and restores your original files. It lists your local changes first and always takes a snapshot, even with `--no-backup`; if that fails, nothing is restored. Installed tools and the `dotfiles` command stay. So do `~/.bashrc.d/90-dotfiles.sh` and the drop-ins placed by `install.dropin`; drop-ins listed under an app's `files:` (such as `50-tmux.sh`) are removed or restored like any other file.

`uninstall` removes `~/.gitconfig` and leaves `~/.gitconfig.local`, which holds the settings the first install moved out of your old `~/.gitconfig`; rename it back if you want them.

### verify and help

`dotfiles verify` checks that every deployed file exists. `dotfiles help` lists every command and flag.

## Flags

| Flag | Works with | Effect |
|---|---|---|
| `--dry-run` | `pull`, `sync`, `checkout`, `uninstall`, `pull --remote`, `init --remote` | Shows what would happen without changing anything. |
| `--no-fetch` | `pull`, `sync` | Doesn't fetch. Uses what's checked out. |
| `--force [PATH]` | `pull` | Takes the repo's version of every file, or of `PATH` only. **This overwrites local edits**, though the snapshot it takes keeps them. |
| `--force` | `pull --remote` | The same on the host, for every file. It takes no `PATH`, and a word with a `/` or starting with `~` is refused as a host. For one file, run `dotfiles pull --force PATH` there over ssh. |
| `--no-backup` | `pull`, `uninstall` | Skips creating backups. `uninstall` and `pull --force` still take their snapshot. |
| `--profile NAME` | `pull`, `sync`, `status`, `add`, `uninstall`, `verify` | Uses this profile for this run only. |
| `--hosts-dir PATH` | `pull`, `sync`, `status`, `add`, `uninstall`, `verify` | Uses this hosts repo for this run only. |
| `--hostname NAME` | `pull`, `sync`, `status`, `add`, `uninstall`, `verify` | Uses this host directory for this run only. |
| `--yes` | `init`, `init --remote` | Accepts the defaults without prompting. Never resets. |

`dotfiles help` lists the flags this table leaves out (`--verbose`, `--quiet`, `--log`, `--shell-scripts-dir` and others).

To change a profile, hosts repo or hostname permanently, use `dotfiles init`. The update check reads the saved config and doesn't know about flags from an earlier run.

## Day-to-day

### Staying up to date

A new terminal runs a throttled `git fetch`, at most once per interval, and tells you in the next terminal when there are updates. It **never deploys or installs anything**, and never prompts. When you see the message, run `dotfiles pull`, or `dotfiles sync` to review your edits first.

If packages are still missing because they need sudo, every terminal reminds you to run `dotfiles pull`.

To turn the check off, run `dotfiles init --update-check off`, or start a single shell with `DOTFILES_NO_UPDATE_CHECK=1 bash`.

### Changing a config file

There are two ways, and both end with you committing and pushing. Other machines pick up the change on their next `pull`.

**Edit the repo** by changing the file under `apps/<app>/files/`. Only committed content deploys, so commit before you deploy:

```bash
git add -p && git commit
dotfiles pull --no-fetch   # deploy it here
git push
```

To **try a change first**, commit it on a branch, deploy that, and go back when you're done:

```bash
git switch -c try-tmux
git commit -am "Try a new prefix"
dotfiles pull --no-fetch      # deploys the branch
dotfiles checkout main        # back to main
```

`dotfiles status` names uncommitted repo files and says they aren't deployed.

**Or edit the live file** (`~/.tmux.conf`, say) and save it back afterwards:

```bash
dotfiles add
```

`add` shows each edit and asks whether to save it, and to which layer: this host, a profile, or the public default. It stages the change; then review, commit and push from the repo it names.

Until you save them, edits are safe: `pull` leaves an edited file alone, even when the repo changes the same file, and warns you. See [Resolving conflicts](#resolving-conflicts).

Your own `~/.bashrc.d/*.sh` drop-ins and `~/.gitconfig.local` are never copied into a repo, which makes them the right place for secrets and one-off settings.

### SSH hosts

The `ssh` app deploys `~/.ssh/config` (mode 0600). The public copy is a stub with no hosts, because host names and addresses don't belong in a public repo. Keep the shared host list in the hosts repo at `profiles/<name>/apps/ssh/files/config`, or `hosts/<hostname>/...` for one machine. That copy replaces the stub whole, so keep its first line, `Include config.local`.

To add a host, use lazyssh (or edit `~/.ssh/config`), then save it back and publish it:

```bash
dotfiles add                       # offers the profile layer; stages it
git -C <hosts repo> commit -m "ssh: add newhost" && git -C <hosts repo> push
```

Other machines get the host on their next `pull`, as an alias for `ssh newhost`, `scp file newhost:` and lazyssh.

- **Settings for one machine** go in `~/.ssh/config.local`, which is never copied into a repo. It's read first, so it wins.
- **An existing `~/.ssh/config`** is merged in on the first install: its entries are appended to the managed file, except `Host` blocks whose aliases are all in the repo already. Options above its first `Host` line go under `Host *`, so they still apply to every host. The original is kept in `~/.bak/ssh/original/`. The merged entries then show as a local edit, so run `dotfiles add` to save them to a repo, after moving any that are for this machine only into `~/.ssh/config.local`. Until you do, pulls hold back changes to `~/.ssh/config` on that machine.
- Keys and `known_hosts` are never managed.

### Undoing a change

Pull follows the repo, so undo in the repo:

- **Everywhere:** `git revert <commit>`, then push.
- **On this machine only:** `dotfiles checkout <tag-or-commit>`, and `dotfiles checkout main` to return. While pinned, this machine doesn't fetch.
- **One file:** copy it back from `~/.bak/<app>/`. `original/` holds the file from before dotfiles first touched it, and timestamped folders hold the last few versions.

To cut a version for `dotfiles versions` to list: `git tag v1.0 && git push origin v1.0`.

### Machines updated with `pull --remote`

A host set up with `init --remote` isn't a git checkout, so it can't fetch updates. Run `dotfiles pull --remote user@host` again from a machine that can. See [Remote hosts](#remote-hosts).

## Add an app

Bootstrap clones over HTTPS, so before you can push from a bootstrapped machine, run `git remote set-url origin git@github.com:dahoff/dotfiles.git`.

Defining a tool doesn't install it anywhere. It only reaches a machine once a profile or `host.yaml` lists it, so every recipe below ends with adding the name to a list.

### A package with no config

Add it to `apps/os-packages.yaml`:

```yaml
packages:
  - htop                 # same package name on apt, dnf and brew
  - name: fd             # names differ
    apt: fd-find
    dnf: fd-find
    brew: fd
```

Then list it in `profiles/complete.yaml`, or in a [profile or `host.yaml`](#choosing-tools-per-machine) if only some machines need it:

```yaml
packages:
  # ...
  - htop
```

### An app with config files

Create a folder named after the app:

```
apps/ripgrep/
  config.yaml
  configure.sh
  files/
    ripgreprc
    50-ripgrep.sh
```

`config.yaml` says how to install the tool and where each file goes:

```yaml
app:
  name: ripgrep
  description: ripgrep configuration

files:
  - src: ripgreprc
    dest: ~/.config/ripgrep/ripgreprc
    mode: '0644'
  # A shell drop-in, sourced by ~/.bashrc
  - src: 50-ripgrep.sh
    dest: ${SHELL_SCRIPTS_DIR}/50-ripgrep.sh
    mode: '0644'

install:
  apt: ripgrep
  dnf: ripgrep
  brew: ripgrep
```

Keep comments on their own line in the `files:` list. A comment at the end of a `src:` or `dest:` line becomes part of the file name.

`configure.sh` is the same boilerplate for almost every app. It's what makes dotfiles deploy the `files:` list, so don't leave it out:

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/../../lib/installer.sh"

installer_main "$@"
```

Add the app's name to a profile and commit it. Only committed content deploys; to try it first, use a branch as in [Changing a config file](#changing-a-config-file). Then:

```bash
chmod +x apps/ripgrep/configure.sh
dotfiles pull --dry-run
dotfiles pull --no-fetch
dotfiles status
```

Other `config.yaml` options:

| Field | Effect |
|---|---|
| `strategy: merge` on a file | Merges a JSON file into the live one instead of replacing it. See [Replace or merge](#replace-or-merge). |
| `requirements:` | Commands that must exist, or the deploy fails. |
| `post_install:` | Shell commands to run after deploying. |
| `backup.max_backups` | How many snapshots to keep. The default is 3. |

Every field is described in [docs/schema.md](docs/schema.md). `app_*` hooks in `configure.sh` handle special cases, and `apps/git/configure.sh` is a good example.

### A tool that isn't in a package manager

Add an `install.sh`. Its `install.check` command is required, and tells dotfiles whether the tool is already there. For a working example, see `apps/lazygit/`:

```yaml
app:
  name: lazygit

install:
  check: command -v lazygit
  dropin: files/50-lazygit.sh   # optional: copied once the check passes
```

```bash
chmod +x apps/lazygit/install.sh   # required, or the pull fails
```

Only committed files deploy, so `chmod` the script and commit it.

`install.dropin` only works with an `install.sh`. For a tool installed by package manager, put its drop-in under `files:` as in the ripgrep example.

### Removing an app

Removing a name from a profile, or excluding it, **doesn't clean anything up**. It only stops future updates. To remove what was deployed:

```bash
apps/<app>/configure.sh uninstall    # removes its files, restores originals
```

Then delete it from the profile. `dotfiles uninstall` can't do this, because it only covers apps still on the list. dotfiles also doesn't uninstall the tool itself or any file placed by `install.dropin`, so remove those by hand.

## Layered config

Most machines can share one setup. When one needs to differ, put the difference in a **hosts repo**: a separate, private git repo holding only data.

| What you want | Where it goes |
|---|---|
| A change for every machine | This repo: `apps/<app>/files/` |
| A change for a group of machines (work, personal) | Hosts repo: `profiles/<name>/apps/<app>/files/` |
| A change for one machine | Hosts repo: `hosts/<hostname>/apps/<app>/files/` |
| Different tools on some machines | Hosts repo: a profile, or `host.yaml` |
| Secrets, or anything that shouldn't be in git | An unmanaged file such as `~/.bashrc.d/90-secrets.sh` |

### The hosts repo

```
dotfiles-hosts/
  profiles/
    personal.yaml                          # which tools this group gets
    personal/apps/claude/files/settings.json
  hosts/
    my-laptop/
      host.yaml                            # required, or the folder is ignored
      apps/tmux/files/.tmux.conf
```

To start using one, create the repo, push it, and point this machine at it:

```bash
dotfiles init --hosts-dir git@github.com:you/dotfiles-hosts.git
```

A URL is cloned to `~/.local/share/dotfiles/dotfiles-hosts`. `pull` fetches this repo too. Like the dotfiles repo, only its committed content is deployed, so commit a change (on a branch, to try it) before you deploy it.

### Choosing tools per machine

`host.yaml` picks a profile, and can adjust the tool list for that one machine:

```yaml
profile: personal
exclude:
  - lazyssh
extra:
  - htop                 # defined in apps/
  - name: docker         # defined right here
    apt: docker.io
```

A profile in the hosts repo works the same way, starting from another profile:

```yaml
# profiles/personal.yaml
extends: complete
exclude:
  - lazygit
extra:
  - htop
```

- `include` keeps only the tools you name, and can't be combined with `exclude`.
- A profile is either a full `packages:` list or `extends:` plus changes. If it has `packages:`, then `extends`, `exclude` and `extra` are ignored.
- A hosts-repo profile takes priority over a built-in one with the same name. A hosts-repo `complete.yaml` can use `extends: complete` to build on the built-in one.
- A hosts repo can only ship packages as new tools. An app with its own config or `install.sh` must have a folder in this repo's `apps/`.

Profile selection, most specific first: `--profile`, then `profile:` in the saved config, then `profile:` in `host.yaml`, then `complete`. In the first two cases dotfiles warns if they override `host.yaml`. The `exclude`, `include` and `extra` in `host.yaml` always apply last.

### Overriding a file

To override a file, put your version at the same `<src>` name, under the app's folder in a layer:

```
hosts/my-laptop/apps/tmux/files/.tmux.conf
```

The file has to be one the app already lists in its `config.yaml`. An overlay with any other name stops the pull before it changes anything. To add a new file, first add it to the app's `files:` list in this repo.

Layers apply in this order, with the last one winning:

1. `apps/<app>/files/<src>` in this repo
2. Each hosts-repo profile, starting from the base of the `extends` chain
3. `hosts/<hostname>/apps/<app>/files/<src>`

For a replaced file, the most specific layer's copy wins whole: it replaces every lower layer's copy entirely, so later changes to the public file stop reaching that machine until you remove or update the copy. `dotfiles add` says so when you save a file to a layer that has no copy of it yet.

### Replace or merge

Files are replaced by default. JSON files can be merged instead, so that each layer only needs the keys it changes, and keys that only exist in the live file (like settings an app writes for itself) are kept. Set it in the app's `config.yaml`, or per machine or profile with a `files:` map:

```yaml
# host.yaml or a hosts-repo profile
profile: personal
files:
  claude/settings.json: merge    # or replace
```

The overlay then only needs what differs, as in this `hosts/my-laptop/apps/claude/files/settings.json`:

```json
{ "env": { "CLAUDE_STATUS_RATE_LIMITS": "1" } }
```

Merging needs `jq`. Objects merge recursively, while arrays and single values are replaced.

When the repo removes a key, a pull deletes it from the live file if you haven't changed its value, along with any parents that leaves empty. If you have changed it, it stays. To force a setting off on a machine where it might already be on, set it explicitly in that machine's layer.

### Checking the result

```bash
dotfiles status            # shows the host and profile in use, and each app's state
dotfiles pull --dry-run    # shows what would change
```

## Troubleshooting

| Symptom | What to do |
|---|---|
| `dotfiles: command not found` | Open a new terminal. If it's still missing, make sure `~/.local/bin` is on `PATH`; the `bash` app adds it. After `init --no-sync` the command isn't linked yet, so run `~/.local/share/dotfiles/dotfiles/dotfiles pull` once. |
| A pull says `Already up to date`, but a deployed file is missing | That early stop doesn't check deployed files. Run `dotfiles pull --force`, or `dotfiles pull --force PATH` for one file. It takes the repo's version, after a snapshot. |
| `X not installed (needs sudo)` at every terminal | Run `dotfiles pull` so it can ask for your password. |
| A file isn't updating | It probably has a local edit or a conflict, which `dotfiles status` lists; `pull` keeps your version. Save it with `dotfiles add`, or take the repo's with `dotfiles pull --force PATH`. Or the change isn't committed yet: `status` lists uncommitted repo files. |
| `pull failed` | The remote can't be reached. Pull carries on with what's checked out. |
| `pull blocked` | The repo has diverged, or local changes are in the way. Nothing was deployed. Run the git commands it prints, then `dotfiles pull`. |
| `This host still has records from an older version` | Run `dotfiles init`: it snapshots every managed file and starts fresh records. |
| `Custom install script not found or not executable` | Run `chmod +x apps/<app>/install.sh` and commit it. The check reads the committed file, so an uncommitted `chmod` changes nothing. |
| A pull warns that this machine is pinned | You ran `dotfiles checkout` on a tag or commit. `dotfiles checkout main` follows `main` again. |
| An `updates available` message at a new terminal | The background check found new commits and deployed nothing. Run `dotfiles pull`. |

For every field, flag and edge case, see [docs/schema.md](docs/schema.md).
