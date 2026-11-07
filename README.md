# dotfiles

One command to set up a machine's tools and config, and keep it up to date. It installs packages, deploys config files, and syncs in the background from new terminals. Per-machine differences live in an optional private repo, so this public repo stays free of personal settings.

- [Set up a new machine](#set-up-a-new-machine)
- [Commands](#commands)
- [Day-to-day](#day-to-day)
- [Add an app](#add-an-app)
- [Layered config](#layered-config)
- [Troubleshooting](#troubleshooting)

## Set up a new machine

You need bash 4 or newer and one of `apt`, `dnf` or `brew`. macOS ships bash 3.2, so install a newer one from Homebrew first.

```bash
curl -fsSL https://raw.githubusercontent.com/dahoff/dotfiles/main/bootstrap.sh | bash
```

This installs git if it's missing, clones this repo to `~/.local/share/dotfiles/dotfiles`, and runs `dotfiles init`. If you have a [hosts repo](#the-hosts-repo), pass it in:

```bash
curl -fsSL https://raw.githubusercontent.com/dahoff/dotfiles/main/bootstrap.sh | bash -s -- --hosts-dir git@github.com:you/dotfiles-hosts.git
```

`init` asks for the following, then runs the first sync:

| Question | Default | Notes |
|---|---|---|
| Hosts repo | `none` | A git URL, a local path, or `none`. If an ssh clone fails, it shows you a public key to add, then retries. |
| Hostname | `hostname -s` | Selects `hosts/<hostname>/` in the hosts repo. |
| Profile | `complete` | Not asked if `hosts/<hostname>/host.yaml` already selects one. |
| Background sync | `on` | |
| Sync interval | `4h` | Format is `<n>m`, `<n>h` or `<n>d`. |

The first sync may ask for your sudo password to install packages, and for your git name and email if none are set. When it finishes, **open a new terminal** to load the new shell setup.

Your existing settings are kept:

- `~/.gitconfig` moves to `~/.gitconfig.local`, which the managed config includes.
- A custom `~/.bashrc` is replaced, and a warning says where the original is: its content is no longer loaded. An existing `~/.bashrc.d/00-local.sh` still loads and is left alone.
- Every file that gets replaced is first copied to `~/.bak/<app>/original/`.

Answers are saved in `~/.config/dotfiles/config.yaml`. Run `dotfiles init` again at any time to change them.

**A machine that can't reach the repos:** from a machine that can, run this. It copies the committed repos over ssh and runs `init` on the target.

```bash
dotfiles push --init user@host
```

**Choosing what gets installed:** there are two built-in profiles.

| Profile | Tools |
|---|---|
| `complete` | git, bash, tmux, vim, curl, fzf, jq, tree, lazygit, lazyssh, scripts, claude |
| `minimal` | `complete` without claude, lazygit and lazyssh |

## Commands

| Command | What it does |
|---|---|
| `dotfiles init` | Asks the setup questions, saves the answers, and runs a sync. |
| `dotfiles sync` | Pulls the repos, installs missing tools, and deploys changed config. Stops early if nothing changed. |
| `dotfiles status` | Shows the repos, version, host, profile, last sync, missing packages, each app's state, and local edits. Changes nothing. |
| `dotfiles add` | Walks through your local edits and stages the ones you accept into a repo. Never commits or pushes. |
| `dotfiles push HOST...` | Copies the committed repos to each host over ssh and syncs there. Add `--init` for a first-time setup. |
| `dotfiles versions` | Lists tagged versions. |
| `dotfiles checkout REF` | Switches to a tag or commit, deploys it, and stays there. `dotfiles checkout main` follows `main` again. |
| `dotfiles verify` | Checks that every deployed file exists. |
| `dotfiles uninstall` | Removes deployed config and restores your original files. Installed tools and the `dotfiles` command stay. |
| `dotfiles help` | Lists every command and flag. |

Most useful flags:

| Flag | Works with | Effect |
|---|---|---|
| `--dry-run` | `sync`, `push`, `checkout`, `uninstall` | Shows what would happen without changing anything. `add` has no dry run: answer `n` to look without saving. |
| `--force` | `sync` | Redeploys everything. **This overwrites local edits**, though the backup snapshot keeps them unless you also pass `--no-backup`. |
| `--no-pull` | `sync` | Uses what's already checked out. |
| `--profile NAME` | `sync`, `status`, `add`, `uninstall`, `verify` | Uses this profile for this run only. |
| `--hosts-dir PATH` | `sync`, `status`, `add`, `uninstall`, `verify` | Uses this hosts repo for this run only. |
| `--hostname NAME` | `sync`, `status`, `add`, `uninstall`, `verify` | Uses this host directory for this run only. |
| `--yes` | `init`, `push --init` | Accepts the defaults without prompting. |

To change a profile, hosts repo or hostname permanently, use `dotfiles init`. The background sync reads the saved config and doesn't know about flags from an earlier run.

## Day-to-day

### Staying up to date

A new terminal starts a sync in the background, at most once per interval. It never prompts:

- **Config updates** are applied, and the next terminal tells you what changed.
- **Missing packages** are only installed if sudo works without a password. Otherwise every terminal reminds you to run `dotfiles sync` yourself.

To turn it off, run `dotfiles init --auto-sync off`, or start a single shell with `DOTFILES_NO_AUTO_SYNC=1 bash`.

### Changing a config file

There are two ways, and both end with you committing and pushing. Other machines pick up the change on their next sync.

**Edit the repo** by changing the file under `apps/<app>/files/`, then deploy it:

```bash
dotfiles sync --dry-run   # optional preview
dotfiles sync             # uncommitted changes are deployed too, so you can try them first
git add -p && git commit && git push
```

**Or edit the live file** (`~/.tmux.conf`, say) and save it back afterwards:

```bash
dotfiles add
```

`add` shows a diff of each edited file and asks which layer to save it to: this host, a profile, or the public default. Then review, commit and push from the repo it names.

Until you save them, edits are safe: `sync` leaves an edited file alone, even when the repo changes the same file, and warns you. `add` can't accept changes to merged files like Claude's `settings.json`. It shows the differences, and you edit the repo copy by hand.

`add` only handles files dotfiles manages. Your own `~/.bashrc.d/*.sh` drop-ins and `~/.gitconfig.local` are never touched or copied into a repo, which makes them the right place for secrets and one-off settings.

### Undoing a change

Sync follows the repo, so undo in the repo:

- **Everywhere:** `git revert <commit>`, then push.
- **On this machine only:** `dotfiles checkout <tag-or-commit>`, and `dotfiles checkout main` to return. While pinned, this machine doesn't pull.
- **One file:** copy it back from `~/.bak/<app>/`. `original/` holds the file from before dotfiles first touched it, and timestamped folders hold the last few versions.

To cut a version for `dotfiles versions` to list: `git tag v1.0 && git push origin v1.0`.

### Machines updated with `push`

A pushed copy isn't a git checkout, so it can't pull updates. Run `dotfiles push user@host` again to update it. Only committed changes are sent.

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

Add the app's name to a profile, then try it, and commit it when it works:

```bash
chmod +x apps/ripgrep/configure.sh
dotfiles sync --dry-run
dotfiles sync
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
chmod +x apps/lazygit/install.sh   # required, or the sync fails
```

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

A URL is cloned to `~/.local/share/dotfiles/dotfiles-hosts`. `sync` pulls this repo too, and uses its working tree as it is, so you can try changes before committing them.

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

The file has to be one the app already lists in its `config.yaml`. An overlay with any other name stops the sync before it changes anything. To add a new file, first add it to the app's `files:` list in this repo.

Layers apply in this order, with the last one winning:

1. `apps/<app>/files/<src>` in this repo
2. Each hosts-repo profile, starting from the base of the `extends` chain
3. `hosts/<hostname>/apps/<app>/files/<src>`

A layer's copy replaces lower layers entirely, so later changes to the public file stop reaching that machine until you remove or update the copy.

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

A merge never deletes a key. To remove one, delete it from the repo layer **and** from the live file. To force a setting off on a machine where it might already be on, set it explicitly in that machine's layer.

### Checking the result

```bash
dotfiles status            # shows the host and profile in use, and each app's state
dotfiles sync --dry-run    # shows what would change
```

## Troubleshooting

| Symptom | What to do |
|---|---|
| `dotfiles: command not found` | Open a new terminal. If it's still missing, make sure `~/.local/bin` is on `PATH`; the `bash` app adds it. After `init --no-sync` the command isn't linked yet, so run `~/.local/share/dotfiles/dotfiles/dotfiles sync` once. |
| A sync says `Already up to date`, but a deployed file is missing | That early stop doesn't check deployed files. Run `dotfiles sync --force`, which also overwrites local edits. |
| `X not installed (needs sudo)` at every terminal | Run `dotfiles sync` so it can ask for your password. |
| A file isn't updating | It probably has a local edit, which `dotfiles status` will list. Save it with `dotfiles add`, or take the repo's version with `dotfiles sync --force`. |
| `pull failed` | Your local history has diverged, or the remote can't be reached. Sync carries on with what's checked out. Fix it with git in the repo it names. |
| `Custom install script not found or not executable` | `chmod +x apps/<app>/install.sh` |
| A sync warns that this machine is pinned | You ran `dotfiles checkout` on a tag or commit. `dotfiles checkout main` follows `main` again. |
| Checking what the background sync did | See `~/.local/state/dotfiles/last-sync.log`. |

For every field, flag and edge case, see [docs/schema.md](docs/schema.md).
