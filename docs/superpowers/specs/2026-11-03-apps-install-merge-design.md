# Design: one folder per tool (merge `packages/` into `apps/`)

## Why

Everything about one tool should live in one place. Today `claude` is spread across three:

| What | Where |
|---|---|
| How to detect it, which script installs it | `profiles/complete.yaml` |
| The install script | `packages/custom/claude/install.sh` |
| Its config | `apps/claude/` |

The goal is that adding or understanding a tool means looking in one folder, and that a profile only says *which* tools a host gets, never *how* to install them.

## Goals

- `apps/<name>/` holds how to install the tool and how to configure it.
- Tools that need only an OS package name are one line in `apps/os-packages.yaml`, so simple tools don't add a folder each.
- Defining a tool and selecting it are separate. A tool reaches a host only when a profile or `host.yaml` lists it. Adding a tool to the repo installs it nowhere.
- `packages/` is gone.

## Non-goals

- No new `dotfiles` commands or flags.
- Hosts repos don't gain the ability to ship folder apps or scripts. They stay data only.
- No renaming of internals for its own sake (the `PKG_*` arrays and `packages:` key stay).
- No change to the layers (dotfiles, then profile, then host) or to the hosts repo's `apps/<app>/files/` overlays.
- No change to `bootstrap.sh` or `init`, beyond any path they happen to reference.

## Anti-goals (failure even if it technically works)

- A host's resolved package list, or the order of it, changes because of this refactor. `complete` must still resolve to exactly: `git bash tmux vim curl fzf jq tree lazygit lazyssh scripts claude`.
- A dry run writes anything (fixed in `d6c7c42`; don't regress it).
- A typo in a tool name silently installs nothing.

## Layout

```
apps/
  os-packages.yaml        # simple tools
  claude/                 # tool install and config
    config.yaml
    install.sh            # installs the tool
    configure.sh          # sets up its config
    files/
  bash/                   # config only: no install.sh
  lazygit/                # tool only: no configure.sh
    config.yaml
    install.sh
    files/50-lazygit.sh
```

### The two scripts (user's decision)

- `install.sh` installs the tool. It's the former `packages/custom/<tool>/install.sh`.
- `configure.sh` sets up the config. It's the former `apps/<app>/install.sh`, renamed. It keeps every subcommand it has now (`deploy`, `upgrade`, `uninstall`, `status`, ...).

### `apps/<name>/config.yaml`

The existing file gains an optional top-level `install:` section. All its fields are optional.

```yaml
install:
  apt: tmux
  dnf: tmux
  brew: tmux
  check: command -v claude          # required when install.sh exists
  dropin: files/50-lazygit.sh       # relative to the app folder
  configure_flags: --append         # passed to configure.sh; bash uses this today
```

- A tool's script is not named in the config: `install.sh` in the folder means there is a custom install.
- Whether the config phase runs is decided the same way: `configure.sh` in the folder means it does.
- The name of a tool is its folder name. All current entries already have `name` equal to `dir`.
- `install:` must not disturb the existing readers of `config.yaml` (`yaml_load`, `overlay_config_entries`). Both stop or skip at top-level keys they don't use, but the builder must verify this, particularly that `files:` parsing ends at `install:` in either order.

### `apps/os-packages.yaml` (user's decision on name)

```yaml
packages:
  - curl                 # same package name on apt, dnf and brew
  - fzf
  - jq
  - tree
  - name: fd             # the long form, when package names differ
    apt: fd-find
    dnf: fd-find
    brew: fd
```

It's a list of definitions. Being listed here selects nothing. The `fd` entry above is an example of the format and isn't added.

## Selecting tools

### Profiles

A profile lists names. Order is kept, and it's the order the tools are processed in.

```yaml
packages:
  - git
  - bash
  - tmux
  - vim
  - curl
  - fzf
  - jq
  - tree
  - lazygit
  - lazyssh
  - scripts
  - claude
```

`extends`, `exclude` and `include` work as they do now, by name. `complete` is a plain explicit list and stops meaning "everything": adding a tool takes two edits, define then list. That's deliberate; the user wants to control which hosts get each tool.

### `extra` in profiles and `host.yaml`

Takes names, the same as `packages:`, so a single host can add a tool:

```yaml
profile: personal
extra:
  - htop
```

### Inline definitions still work

A `packages:` or `extra:` list may mix names with the existing long form, so a hosts repo can add a tool `dotfiles` doesn't define. This is how the work repo, which Claude can't see, can add its own tools.

```yaml
extra:
  - name: docker
    apt: docker.io
```

### Resolution

For a plain name, in order:

1. `apps/<name>/config.yaml` exists: use that folder.
2. `apps/os-packages.yaml` defines it: use that entry.
3. Otherwise it's an error, and the run aborts before any change, like the other errors listed under "Errors" in `docs/schema.md`. The message names the tool and the profile or `host.yaml` it came from.

A name defined both as a folder and in `os-packages.yaml` is also an error, because which definition wins would be a guess.

A folder's `apps/<name>/` may exist with no `config.yaml` only if it holds nothing the tool needs; treat a folder without `config.yaml` as not defining a tool.

## Calls Claude made (the user has seen these and can overrule them)

- `lazygit` and `lazyssh` get folders, and their shell drop-ins move into them.
- `packages/install.sh` is deleted. `dotfiles` and `lib/` never call it; only `test/apps/test-packages.sh` does, and the tests for it go too.
- The test-only `testtool` moves to `test/fixtures/testtool/`, so it doesn't appear as a real app.
- In the inline long form, `custom.script` and `custom.dropin` become relative to `apps/` (they were relative to `packages/`, which is gone). `config.dir` keeps meaning a folder under `apps/`. The `pendingtest` fixture points at its tool with `../test/fixtures/testtool/...`. Inline entries using `custom/...` paths stop working; the user's personal hosts repo has none, and the work repo doesn't exist yet.
- Phases are unchanged: all OS packages in one batch, then custom installs, then configs.
- `exclude` naming something absent stays silently ignored, as today: it can't cause a tool to go missing.
- `include` naming something not in the inherited list becomes an error, aborting before any change. Today it's silently dropped, which is the typo failure listed under Anti-goals. Neither repo Claude can see uses `include` on real hosts.
- An inline long-form entry whose name a folder or `os-packages.yaml` also defines replaces that definition entirely, with no merging of fields. It's an explicit choice made in a profile or `host.yaml`, so nothing is guessed, and it's how today's entries behave (test fixtures use `name: claude` with only `config.dir` to get a config-only app). The folder-versus-`os-packages.yaml` error above doesn't apply to it.
- A long-form entry with a name and nothing else (`- name: tmux`) is an error, since it would silently do nothing. To refer to a defined tool, write `- tmux`.
- If a tool arrives twice in one resolved list (`extra: [tmux]` when the profile lists it), it's processed once, at its first position. If either entry is inline, the later entry's definition is the one used.

## Consequences to keep

- The app version hash in `lib/overlay.sh` hashes `config.yaml` and the config script. It must follow the rename to `configure.sh`. Each machine therefore redeploys its apps once after this ships, with one backup snapshot per app. That's accepted.
- `install.sh` (the tool installer) stays out of that hash: a change to how a tool installs shouldn't redeploy its config. Editing `install:` in `config.yaml` does redeploy once, which is accepted to keep the hash simple.
- A drop-in deploys only when its tool passes `check`, as it does now.
- `lib/profile.sh`'s `prepare_overlays` and the `status` command iterate tools with a config. Tools without `configure.sh` must not reach them, the same as entries with no `config.dir` today.
- **One failed sync per machine at upgrade (user's decision: accepted).** `sync` pulls and then keeps running the old code already in memory, which doesn't understand plain names, so the first sync after this ships stops with `No packages found` and changes nothing. Under `--auto` it reports `sync failed (profile)` once and the next run, after the throttle, uses the new code. A manual second `dotfiles sync` clears it at once. No re-exec or parser fallback is built. Note this in the handoff, and say it in the docs if there's a natural place.
- `~/.local/state` may hold a stale `packages` app state from the deleted module on old machines. It must do no harm; the builder should check what reads it.

## Docs

- `docs/schema.md`: rewrite the profile section around names, and document `install:`, `os-packages.yaml`, and resolution errors.
- `docs/superpowers/HANDOFF.md`: update on completion. Older specs and plans in `docs/superpowers/` stay as written.

## Testing

Existing suites (`test/run-core-tests.sh`, `test/run-app-tests.sh`, and the Docker `test/run-remote-tests.sh`) must pass, one at a time. Most changes are mechanical (`./install.sh` becomes `./configure.sh` in about 90 places), and `test/apps/test-packages.sh` needs rewriting around the new paths.

New behaviour needing tests:

- `complete` resolves to the exact list and order above, and `minimal` still excludes `claude`, `lazygit` and `lazyssh`.
- A name resolves from a folder, from a one-line `os-packages.yaml` entry, and from a long-form one, and each installs the right package name.
- An unknown name, and a name defined in both places, each abort before any change, including when it comes from `extra:` in `host.yaml`.
- Inline long-form entries mixed with names work in `packages:` and `extra:`.
- A tool-only app (`lazygit`) gets its install and drop-in and no config phase; a config-only app (`bash`) gets a config phase with `configure_flags` applied and no install.
- A definition in `os-packages.yaml` that no profile lists installs nothing.

## Left to the builder

- How the parser is restructured. `lib/profile.sh`'s `load_manifest` is line-based with parallel arrays; extend or reshape it as needed, keeping the arrays' meaning for `dotfiles`.
- The order of commits, provided the suites pass at each commit.
