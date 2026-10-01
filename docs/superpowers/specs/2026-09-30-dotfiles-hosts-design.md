# Design: dotfiles-hosts repo, host overlays, and file merging

Date: 2026-09-30
Status: draft for review
Scope: sub-project 1 of 3

## Context

Today `dotfiles` holds the framework, app modules, and profiles. Each app's `install.sh`
copies whole files over the live config, so host-specific settings are overwritten on every
deploy (example: `~/.claude/settings.json` has plugins, marketplaces, `effortLevel`, `tui` that
should exist only on one machine, and Claude Code itself writes keys into that file at runtime).

## Overall direction (all three sub-projects)

Recorded here so later specs have a reference; only sub-project 1 is specified in detail.

**Repos**

| Repo | Contents |
|---|---|
| `dotfiles` | Framework, app modules, default profiles, `bootstrap.sh`, login hook |
| `dotfiles-hosts` | Profile defaults (`profiles/`) and per-host directories (`hosts/<hostname>/`). One instance on personal GitHub, one on work GitHub, same name. A host uses exactly one. Data only, no framework code. |

**Delivery model:** pull, not push. Each host clones both repos and applies changes itself.
Hosts that can't reach git get the repos copied over SSH (tar) and apply them the same way.
The apply code path is identical for both.

**Commands (end state)**

```
dotfiles init              guided per-host setup, writes local config, installs login hook, first sync
dotfiles sync              apply locally (run by the login hook)
dotfiles push HOST...      tar repos over SSH, run `dotfiles sync` there
dotfiles push --init HOST  same, but runs `dotfiles init` (first setup without git)
dotfiles status            installed state, last applied commits
bootstrap.sh               install git, clone dotfiles + dotfiles-hosts, exec `dotfiles init`
```

`dotfiles` is `setup.sh` reworked and linked into `~/.local/bin`. Deployment stays copy-based
(not symlinks): merged files can't be symlinks, and apps writing to symlinked configs would
dirty the git checkouts and break unattended `git pull --ff-only`.

**Sub-projects**

1. **dotfiles-hosts, host overlays, merging** (this spec)
2. **Sync agent and push**: `dotfiles sync`/`push`/`status`, login hook (background, `flock`,
   throttled, `--ff-only`, config-only unattended, report at next login), local config file,
   removal of `lib/remote.sh` and `--host`/`--hosts-file`.
3. **Bootstrap and init**: `bootstrap.sh`, `dotfiles init`, `dotfiles push --init`.

Deferred: drift detection and `dotfiles commit` (see `docs/notes/deferred-drift-and-commit.md`).

## Sub-project 1 goals

- A `dotfiles-hosts` repo can supply profile defaults and per-host directories.
- A host directory chooses a profile, adjusts its package list, and overrides individual app
  files.
- Each overridden file uses one of two strategies, `replace` or `merge`.
- `merge` preserves keys in the live file that no repo manages (fixes the Claude settings case).
- Without a hosts repo, behavior is unchanged.

## `dotfiles-hosts` layout

```
dotfiles-hosts/
  profiles/
    minimal.yaml                          # profile, same schema as dotfiles profiles + `files:`
    minimal/apps/<app>/files/<src>        # optional file overlays for this profile
  hosts/
    <hostname>/
      host.yaml
      apps/<app>/files/<src>              # optional file overlays for this host
```

`<app>` is the dotfiles app directory name (e.g. `claude`); `<src>` is the `src` name from that
app's `config.yaml`.

### `host.yaml`

```yaml
profile: complete            # required; base profile, resolved as described below
exclude:                     # optional; same semantics as in profiles
  - lazyssh
extra:                       # optional; same format as profile packages[]
  - name: htop
    apt: htop
files:                       # optional; per-file strategy, keyed <app>/<src>
  claude/settings.json: merge
```

`include` is also accepted (mutually exclusive with `exclude`, as in profiles).

### Profile files in `dotfiles-hosts`

Same schema as dotfiles profiles (`packages` or `extends` + `exclude`/`include`/`extra`), plus
an optional `files:` map identical to the one in `host.yaml`.

### App `config.yaml` addition

Each `files[]` entry may declare a default strategy:

```yaml
files:
  - src: settings.json
    dest: ~/.claude/settings.json
    mode: '0644'
    strategy: merge          # optional; default replace
```

## Resolution

Inputs: `--hosts-repo PATH` (or env `DOTFILES_HOSTS_REPO`), `--hostname NAME` (default
`hostname -s`), `--profile NAME`.

1. **No hosts repo:** exactly today's behavior.
2. **Host directory:** if `hosts/<hostname>/host.yaml` exists, it is the top layer and its
   `profile:` is the base profile. If `--profile` is also given, `--profile` wins and a warning
   is logged.
3. **No host directory:** base profile is `--profile`, default `complete`.
4. **Profile lookup:** a name resolves to `dotfiles-hosts/profiles/<name>.yaml` first, then
   `dotfiles/profiles/<name>.yaml`. When a hosts-repo profile `extends:` its own name, the
   lookup continues in dotfiles (so `dotfiles-hosts/profiles/minimal.yaml` can say
   `extends: minimal` to build on the dotfiles one).
5. **Package list:** built by the existing `extends`/`exclude`/`include`/`extra` logic, applied
   along the chain, with `host.yaml` as the final link. Packages added via `extra` reference
   dotfiles app directories and `packages/` scripts; a hosts repo cannot define new apps.

## File overlays

For each app file `<app>/<src>`, the layers from lowest to highest are:

1. `dotfiles/<app>/files/<src>`
2. `dotfiles-hosts/profiles/<p>/apps/<app>/files/<src>` for each hosts-repo profile in the
   chain, base-most first
3. `dotfiles-hosts/hosts/<hostname>/apps/<app>/files/<src>`

The strategy is the last declaration found, in order: app `config.yaml`, hosts-repo profile
`files:` maps along the chain, `host.yaml` `files:`. Default `replace`.

- **replace:** the highest layer that has the file wins; it is copied over the live file.
- **merge:** JSON only. Result = live ⊕ layer1 ⊕ layer2 ⊕ layer3, using jq's `*` (objects
  merge recursively; arrays and scalars are replaced by the later value). If the live file
  doesn't exist it is omitted. Consequence: removing a key from a repo does not remove it from
  the live file; that is done by hand.

## Mechanics

- The orchestrator (`setup.sh`) resolves the profile chain and host, then for each app with a
  config builds a staging directory containing the composed files (replace: winning layer;
  merge: repo layers pre-merged) and the set of files to merge.
- The app installer receives the staging directory and merge set as arguments, and in its copy
  step either copies (replace) or merges the staged JSON into the live file (merge).
- Each app's version (used by `upgrade` to skip unchanged apps) becomes a hash of its composed
  files and strategies instead of the dotfiles git hash, so a hosts-repo change triggers an
  upgrade and an unrelated dotfiles commit doesn't.
- **Shared installer core:** the seven app `install.sh` files (~850 lines each, mostly
  identical) are consolidated into `lib/installer.sh`. Each app keeps a small `install.sh` that
  sources the core and defines only its specific hooks (bash append mode and supplements, git
  identity setup, etc.). This avoids making the same overlay change in seven copies.
- **Remote compatibility:** `--host`/`--hosts-file` keep working in this sub-project. Overlays
  are resolved on the workstation using the host entry's name (user@ and domain stripped) as
  the hostname, and the staged files are shipped with the app. Removed in sub-project 2.

## Errors

| Condition | Behavior |
|---|---|
| `--hosts-repo` path missing or not a directory | Abort before any changes |
| `host.yaml` has no `profile:` | Abort |
| Profile name not found in either repo | Abort (existing behavior) |
| Overlay file whose `<src>` isn't in the app's `config.yaml` | Abort (catches typos) |
| Overlays for an app not in the resolved package list | Warning, ignored |
| `merge` declared for a non-`.json` file | Abort |
| Live or layer file is invalid JSON during merge | That file fails, live file left untouched, other files continue; reported in summary |
| `jq` missing when a merge is needed | That app fails with a clear message (jq is installed in phase 1 by the default profiles) |

## Initial migration

- `claude/config.yaml`: `settings.json` gets `strategy: merge`.
- `claude/files/settings.json` keeps only settings shared by every host.
- Machine-specific settings move to the relevant `dotfiles-hosts/hosts/<hostname>/` directory,
  or stay unmanaged in the live file (preserved by merge).

## Testing

Using the existing `test/` harness, with a fixture hosts repo under `test/fixtures/`:

- No hosts repo: output identical to current behavior.
- Profile lookup order, and a hosts-repo profile extending its own name.
- Host directory selects profile; `--profile` override warns and wins.
- `exclude`/`extra` in `host.yaml`.
- Replace across all three layers picks the highest.
- Merge across layers plus live file: repo keys updated, unmanaged live keys preserved, arrays
  replaced.
- Each error row above.
- Existing app tests pass against the shared installer core.
- Remote deploy with overlays still works (existing remote test setup).

## Out of scope

Sync agent, push, init, bootstrap, local config file (sub-projects 2-3); drift detection and
`dotfiles commit` (deferred); hosts repo defining new apps; merge for non-JSON formats;
propagating key deletions.
