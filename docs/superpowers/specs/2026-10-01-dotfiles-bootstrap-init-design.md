# Design: `bootstrap.sh`, `dotfiles init`, `dotfiles push --init`

Date: 2026-10-01
Status: user delegated the design; revised 2026-10-02 for the YAML config (`config.yaml`), `hosts_dir`
naming and no `dotfiles_repo` key (see sub-project 2 spec, "Revisions"). Every other decision
here is an assumption for review.
Scope: sub-project 3 of 3. Builds on sub-project 2 (`2026-10-01-dotfiles-sync-push-design.md`):
the `dotfiles` command, config file, default repo paths, `push`.

## Goals

- A fresh machine with network access goes from nothing to a fully synced host with one command.
- A fresh machine without git/GitHub access gets the same result from the workstation via
  `dotfiles push --init HOST`.
- `dotfiles init` is the one place per-host settings are chosen; it writes the config file and
  runs the first sync. Re-running it is safe and shows current values as defaults.

## `bootstrap.sh` (repo root)

Usage on a new machine:

```
curl -fsSL https://raw.githubusercontent.com/dahoff/dotfiles/main/bootstrap.sh | bash
# or, with options:
curl -fsSL .../bootstrap.sh | bash -s -- --hosts-dir git@github.com:me/dotfiles-hosts.git
```

Steps:

1. `set -euo pipefail`; self-contained (does not source `lib/`, since the repo isn't there yet).
2. If `git` is missing: detect apt-get / dnf / brew and install git (`sudo` for apt/dnf; reads
   the password from the terminal: when piped from curl, stdin is the script, so sudo uses
   `/dev/tty`). No package manager → error with manual instructions.
3. Clone `DOTFILES_REPO_URL` (env or `--repo URL`; default
   `https://github.com/dahoff/dotfiles.git`) into `DOTFILES_DIR` (env or `--dir`; default
   `~/.local/share/dotfiles/dotfiles`). If the directory already is a git checkout: `git pull
   --ff-only` instead (failure → warning, continue). If it exists and is not a checkout → error.
4. `exec "$DOTFILES_DIR/dotfiles" init "<remaining args>" </dev/tty` (so init's prompts work even
   when bootstrap was piped from curl; if `/dev/tty` is unavailable, pass `--yes`).

Bootstrap options it consumes: `--repo URL`, `--dir PATH`. Everything else is passed to `init`.

## `dotfiles init`

```
dotfiles init [--hosts-dir URL|PATH|none] [--hostname NAME] [--profile NAME]
              [--auto-sync on|off] [--interval 4h] [--yes] [--no-sync]
```

Interactive by default; each prompt shows a default in brackets; Enter accepts it. `--yes`
accepts defaults/flags with no prompts (required when stdin isn't a terminal). Defaults come
from the existing config file when present, else the sub-project 2 defaults.

Prompts, in order:

1. **Hosts repo** — `none`, a git URL, or a local path.
   - URL: clone into `~/.local/share/dotfiles/dotfiles-hosts` (if that's already a checkout of the
     same URL: `git pull --ff-only`; a checkout of a different URL → error asking for a path or
     `--hosts-dir none`). Clone failure (e.g. no SSH key for the work GitHub) → error that tells
     the user to fix access or use `dotfiles push --init` from a machine that has it.
   - Path: must exist (checkout or pushed copy).
   - Default: the configured value; else the default path if it exists (e.g. a pushed copy);
     else `none`.
2. **Hostname** — default `hosts_local_name`. After answering, init prints whether
   `hosts/<name>/host.yaml` exists in the hosts repo and which profile it selects, and lists the
   host directories that do exist (to catch typos).
3. **Profile** — asked only when there is no `host.yaml` for the chosen host; choices are the
   profile names found in both repos (hosts repo first); default `complete`. When a `host.yaml`
   exists, the profile line is written commented out.
4. **Background sync** — `on`/`off` (default `on`), then the interval (default `4h`), validated
   (`<n>m|h|d`).

Then:

- Write `~/.config/dotfiles/config.yaml` (or `$DOTFILES_CONFIG`). If one exists and differs, the old
  file is kept as `config.bak`. Values that equal the built-in default are still written
  explicitly, as flat YAML (`key: value`), with a header comment `# Written by dotfiles init on
  <date>`. There is no `dotfiles_repo` key: the dotfiles repo is the checkout `init` runs from,
  and `~/.local/bin/dotfiles` (created by the first sync) records it.
- Unless `--no-sync`: run `dotfiles sync` (interactive full sync: packages + configs, sudo
  prompts). With `--yes` and no terminal, run `dotfiles sync` anyway (sudo may fail → reported;
  configs still deploy).
- Print a closing summary: config path, host/profile, what to do next ("open a new terminal;
  background sync runs every 4h").

Init does not delete anything and never touches the repos beyond clone/pull of the hosts repo.

## `dotfiles push --init HOST...`

Same as `dotfiles push` (sub-project 2) through the copy step, then runs
`ssh -t HOST '<remote dotfiles dir>/dotfiles init --hosts-dir <remote hosts path or none>'` instead of
`sync --no-pull`. Because the hosts repo was just unpacked at the remote's default path, init's
hosts-repo default is that pushed copy; the user answers the remaining prompts on the remote
terminal. Init's sync runs with `--no-pull` when the dotfiles repo is not a git checkout (always
the case for a pushed copy; pull would be skipped anyway).

## Errors

| Condition | Behavior |
|---|---|
| bootstrap: no git and no supported package manager | Exit 1 with manual instructions |
| bootstrap: clone fails | Exit 1, show git's error; suggest `--repo` or `push --init` |
| init: not a terminal and no `--yes` | Exit 1: "init is interactive; pass --yes to accept defaults" |
| init: invalid interval / unknown `--auto-sync` value | Re-prompt (interactive) or exit 1 (`--yes`) |
| init: hosts repo URL clone fails | Exit 1, nothing written |
| init: chosen profile not found | Re-prompt / exit 1 |
| push --init: remote init fails | That host fails; next host continues |

## Testing

- bootstrap (local, sandboxed HOME): with git present, clones from a local bare repo given via
  `--repo file:///…` into `--dir`, then runs `init --yes --no-sync` (assert config written);
  re-run pulls instead of cloning; existing non-checkout dir → error. Missing-git path is tested
  only by a dry check that the package-manager branch is selected (`DOTFILES_BOOTSTRAP_DRY=1`
  prints the install command instead of running it).
- init `--yes`: writes config with flag values; `none` hosts repo; URL hosts repo cloned from a
  local bare repo; existing config → `config.bak`; invalid interval → exit 1; not-a-tty without
  `--yes` → exit 1; `--no-sync` doesn't sync; with sync, configs deploy into the sandbox HOME.
- init interactive: drive prompts by feeding stdin through `script`-free means: init reads
  answers from stdin when `DOTFILES_INIT_ASSUME_TTY=1` (test-only switch) — assert defaults
  shown and accepted.
- push --init (Docker): fresh container, `push --init` with answers piped via
  `DOTFILES_INIT_ASSUME_TTY=1` + `--yes` → config exists remotely, configs deployed.

## Out of scope

Creating the dotfiles-hosts GitHub repos, SSH key provisioning, non-bash shells, uninstall of
the whole system ("dotfiles uninstall" from sub-project 2 covers configs).
