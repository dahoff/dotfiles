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

setup.sh processes the unified list in three phases:
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

## Hosts Schema (`hosts.yaml`)

Optional file for multi-host deployment. Maps remote hosts to profiles.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `hosts` | array of objects | Yes | — | List of remote host definitions. |
| `hosts[].host` | string | Yes | — | SSH target (e.g., `user@server.example.com`). |
| `hosts[].profile` | string | No | `"complete"` | Profile for this host. Overrides hosts/<name>/host.yaml's profile (with a warning) when a hosts repo is used. |

Legacy format also supported: plain strings in the `hosts` array are treated as hostnames with the default profile.

**Example:**
```yaml
hosts:
  - host: user@server1.example.com
    profile: complete
  - host: user@server2.example.com
    profile: minimal
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

- The host name is `--hostname`, else `hostname -s`. For `--host`/`--hosts-file` targets it is the host entry without `user@` and domain (IPv4 addresses are kept whole).
- If `hosts/<hostname>/host.yaml` exists, its `profile:` is the base profile. An explicit `--profile` (or a `--hosts-file` entry's `profile:`) wins, with a warning.
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

Running an app's `install.sh` directly deploys the dotfiles layer only (no hosts repo overlays); use `setup.sh` with the hosts repo to keep host overlays.
Strategy: last declaration among the app `config.yaml`, the hosts-repo profile `files:` maps (base-most first), and `host.yaml` `files:`.

### Errors

The run aborts before any change if the hosts repo is missing, `host.yaml` lacks `profile:`, a profile isn't found, the `extends` chain cycles, an overlay file or `files:` key names an unknown `src`, `merge` is set on a non-`.json` file, or a strategy other than `replace`/`merge` is used. Overlays for apps not in the package list are ignored with a warning. Invalid JSON during a merge fails only that file, leaves the live file untouched, and is reported in the summary. The app's version is then recorded as `incomplete`, so the next run retries.

### Removing managed keys

`merge` never deletes keys from the live file. To remove a key, delete it from the repo layer and from the live file by hand.
