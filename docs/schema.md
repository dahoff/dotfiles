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
| `hosts[].profile` | string | No | `"complete"` | Profile name to deploy to this host. |

Legacy format also supported: plain strings in the `hosts` array are treated as hostnames with the default profile.

**Example:**
```yaml
hosts:
  - host: user@server1.example.com
    profile: complete
  - host: user@server2.example.com
    profile: minimal
```
