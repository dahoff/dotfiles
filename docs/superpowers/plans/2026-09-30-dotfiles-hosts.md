# dotfiles-hosts Overlays and Merging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a `dotfiles-hosts` repo supply profile defaults and per-host directories that pick a profile, adjust its package list, and override individual app files with a `replace` or `merge` (JSON) strategy, without changing behavior when no hosts repo is given.

**Architecture:** The seven near-identical app `install.sh` files collapse into `lib/installer.sh` with named hooks. Two new libraries hold the logic: `lib/hosts.sh` handles hosts-repo lookup and parsing, and `lib/overlay.sh` handles layer composition, validation, JSON merge, and content hashing. `setup.sh` resolves the profile chain and host, validates every overlay before making any change, then stages each app's composed files into a temp directory and passes it to the installer as `--stage DIR`. The installer copies or merges from the stage. Its version is the stage's content hash, not the git hash. When run on its own, the installer stages its own files (dotfiles layer only).

**Tech Stack:** Bash 4+, jq (only when a merge actually happens), the existing `test/` harness (plain bash scripts, Docker for remote tests).

**Spec:** `docs/superpowers/specs/2026-09-30-dotfiles-hosts-design.md`

## Global Constraints

- Without a hosts repo, profile resolution and package lists stay exactly as they are today. The only visible changes are the content-hash version and `strategy: merge` from `config.yaml`, both required by the spec.
- Hosts repo input: `--hosts-repo PATH` or env `DOTFILES_HOSTS_REPO`. Host name: `--hostname NAME`, default `hostname -s`. Profile: `--profile NAME`.
- The only strategies are `replace` and `merge`, and the default is `replace`. `merge` applies only to `.json` files.
- `files:` map keys have the form `<app>/<src>`, where `<app>` is the dotfiles app directory name and `<src>` is the `src` from that app's `config.yaml`.
- Merge result = live ⊕ dotfiles ⊕ hosts-repo profile layers (base-most first) ⊕ host layer, using jq `*`. A missing live file is left out. Key deletions are never propagated.
- Strategy precedence, last wins: app `config.yaml`, then hosts-repo profile `files:` maps along the chain (base-most first), then `host.yaml` `files:`.
- Layer precedence for replace, highest wins: `dotfiles/<app>/files/<src>`, then `dotfiles-hosts/profiles/<p>/apps/<app>/files/<src>` along the chain, then `dotfiles-hosts/hosts/<hostname>/apps/<app>/files/<src>`.
- The hosts repo cannot define new apps. Packages added through `extra` refer to dotfiles app directories and `packages/` scripts.
- `--host`/`--hosts-file` keep working. For remote targets the overlay host name is the host entry with `user@` and the domain removed.
- Commits: never add a `Co-Authored-By` or other Claude attribution trailer (user preference). Never stage `claude/files/settings.json`, which has uncommitted user work in progress. Use `git add <explicit paths>`.
- Run tests from `test/`: `./run-core-tests.sh`, `./run-app-tests.sh`, or one file with `bash apps/test-<name>.sh`. All of them must pass at the end of every task.

## Review Focus

1. **Live file that is empty (0 bytes) or holds a non-object JSON value (`[]`, `"x"`).** An empty file is treated as absent, so the staged file is copied. A non-object is treated as invalid: that file fails and the live file is left byte-identical. Tested in Task 4.
2. **A file fails during deploy, then the next run.** The state version must be recorded as `incomplete`, so the next deploy retries instead of printing "already up to date". Tested in Task 4.
3. **Remote host given as an IP address or `user@host.example.com`.** The overlay host name must be `host` for the second form, and the full IP for the first, not `10`. Tested in Task 3.
4. **Profiles that extend each other across repos (`a` → `b` → `a`).** This must abort with a clear message instead of recursing forever. Tested in Task 5.
5. **`hosts/<name>/` exists but has no `host.yaml`** (for example only `apps/`). The run must warn that the directory is ignored instead of silently applying it or silently skipping it. Tested in Task 5.

## Interpretations of the spec (decided here, flag in review if wrong)

- **The merge set travels inside the stage directory.** It is the `strategies` file, not separate `--merge` arguments. `--stage DIR` is the only new installer argument, and the directory ships as-is for `--remote`.
- **The version hash also covers the app's `config.yaml`,** so a dest or mode change triggers an upgrade. It does not cover installer code; `--force` handles that.
- **"That file fails, other files continue" applies to every per-file deploy failure,** not only JSON. A missing source still aborts the app.
- **A `profile:` on a `--hosts-file` entry works like `--profile` for that host:** it wins over `host.yaml` and logs a warning.
- **Per-file failure lines in the summary work for local deploys only.** A remote installer can't write to the local failures file, so a remote failure shows as an app-level FAIL.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `lib/installer.sh` | create | Shared installer core: arg parsing, load_config, install/upgrade/uninstall/rollback/status/verify/backups/diff, remote mode, staging, merge deploy, hook defaults |
| `lib/overlay.sh` | create | `config.yaml` file entries, strategy resolution/validation, overlay validation, JSON merge, staging, version hash |
| `lib/hosts.sh` | create | Hosts-repo helpers: profile path lookup, `host.yaml` scalar reads, `files:` map parsing, host-name normalization |
| `lib/utils.sh` | modify | add `list_contains` |
| `lib/remote.sh` | modify | `remote_package_installer` takes version + stage dir and builds in a temp tree; `remote_skip_if_current` takes the local version |
| `<app>/install.sh` ×7 | rewrite | ~10–120 lines each: set `APP_DIR`, source core, define hooks, `installer_main "$@"` |
| `setup.sh` | modify | `--hosts-repo`/`--hostname`, profile chain across repos, `host.yaml`, overlay validation, staging, failure reporting |
| `claude/config.yaml` | modify | `settings.json` gets `strategy: merge` |
| `docs/schema.md` | modify | document `strategy`, hosts repo, `host.yaml`, `files:` map, new flags |
| `test/apps/test-overlay.sh` | create | unit tests for `lib/overlay.sh` + `lib/hosts.sh` |
| `test/apps/test-claude.sh` | create | installer merge behavior (standalone) |
| `test/apps/test-hosts.sh` | create | `setup.sh` resolution and overlay integration tests |
| `test/apps/test-setup.sh` | modify | tests 9, 10, 20 for the new core/version |
| `test/fixtures/hosts-repo/**` | create | fixture hosts repo |
| `test/run-remote-tests.sh`, `test/docker/Dockerfile` | modify | new package signature; overlay remote test; jq in image |

---

### Task 1: Shared installer core; claude, vim, scripts, tmux on it

Pure refactor: behavior and output stay the same.

**Files:**
- Create: `lib/installer.sh`
- Rewrite: `claude/install.sh`, `vim/install.sh`, `scripts/install.sh`, `tmux/install.sh`
- Modify: `test/apps/test-setup.sh` (tests 9–10)

**Interfaces:**
- Produces (used by Tasks 2 and 4):
  - Apps do: `APP_DIR=...; source "$(dirname "$APP_DIR")/lib/installer.sh"; <hook overrides>; installer_main "$@"`
  - Hook functions with no-op defaults: `app_parse_arg "$@"` (return 0 + set `APP_ARG_SHIFT` if consumed), `app_usage`, `app_after_load_config`, `app_pre_install`, `app_pre_deploy install|upgrade`, `app_post_files install|upgrade`, `app_post_install install|upgrade`, `app_up_to_date`, `app_post_uninstall`, `app_pre_remote`
  - Overridable: `deploy_file src dest mode strategy verb` (default calls `deploy_file_default` with the same args)
  - Switches: `UPGRADE_ALWAYS=false`, `APP_REMOTE_DROP_ARGS=()`
  - Helpers: `deploy_all_files install|upgrade`, `installer_src NAME` (path of source for a config src), `installer_strategy NAME` (prints `replace` for now)

- [ ] **Step 1: Update the failing structure tests**

In `test/apps/test-setup.sh`, replace tests 9 and 10 (the `grep -q "cmd_deploy"` blocks) with:

```bash
# Test 9: app installers use the shared core
info "Test 9: app installers source lib/installer.sh"
for app in bash claude git packages scripts tmux vim; do
    if ! grep -q 'lib/installer.sh' "$ROOT_DIR/$app/install.sh"; then
        fail "$app/install.sh does not source lib/installer.sh"
    fi
done
pass "All app installers source lib/installer.sh"

# Test 10: shared core provides deploy
info "Test 10: deploy command in lib/installer.sh"
if grep -q "^cmd_deploy()" "$ROOT_DIR/lib/installer.sh"; then
    pass "cmd_deploy exists in lib/installer.sh"
else
    fail "cmd_deploy missing from lib/installer.sh"
fi
```

(bash, git and packages move in Task 2. Until then Test 9 fails, which is expected.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd test && bash apps/test-setup.sh`
Expected: FAIL at Test 9 (`bash/install.sh does not source lib/installer.sh`). The test checks claude first in the loop order bash, claude…, so the message names bash.

- [ ] **Step 3: Create `lib/installer.sh`**

Build it from `claude/install.sh`. Copy that file's functions `load_config`, `check_requirements`, `cmd_deploy`, `cmd_uninstall` (body), `cmd_rollback`, `cmd_status`, `cmd_verify`, `cmd_backups`, `cmd_diff`, `run_post_install`, `usage`, `validate_command`, `parse_args`, `execute_remote` and `main`, then apply the changes shown below. The full file has this layout:

```bash
#!/usr/bin/env bash
# installer.sh - Shared app installer core
#
# An app's install.sh sets APP_DIR, sources this file, redefines any app_*
# hooks (or core functions) it needs, then calls: installer_main "$@"

ROOT_DIR="$(dirname "$APP_DIR")"

source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/yaml.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backup.sh"
source "$ROOT_DIR/lib/state.sh"
source "$ROOT_DIR/lib/remote.sh"

# Configuration
CONFIG_FILE="$APP_DIR/config.yaml"
FILES_DIR="$APP_DIR/files"

# Global variables (set from config)
APP_NAME=""
APP_VERSION=""
BACKUP_DIR=""
MAX_BACKUPS=3
declare -a CONFIG_FILES=()
declare -a CONFIG_DESTS=()
declare -a CONFIG_MODES=()

# Flags
DRY_RUN=false
NO_BACKUP=false
TEST_MODE=false
FORCE=false
REMOTE_MODE=false

# Cross-module: shell scripts drop-in directory
SHELL_SCRIPTS_DIR="$HOME/.bashrc.d"

# App switches (apps override after sourcing)
UPGRADE_ALWAYS=false               # true: upgrade never skips on matching version
declare -a APP_REMOTE_DROP_ARGS=() # "--flag value" options not forwarded with --remote

# Set by app_parse_arg: number of arguments it consumed
APP_ARG_SHIFT=0

# --- Hooks: apps redefine these after sourcing -----------------------------

# Consume an app-specific option; return 0 and set APP_ARG_SHIFT if handled
app_parse_arg() { return 1; }
# Print app-specific usage lines
app_usage() { :; }
# After config.yaml is loaded
app_after_load_config() { :; }
# install only: after the requirements check, before backups
app_pre_install() { :; }
# install|upgrade ($1): after backups, before files are deployed
app_pre_deploy() { :; }
# install|upgrade ($1): after files are deployed and state is written
app_post_files() { :; }
# install|upgrade ($1): after post_install commands ran
app_post_install() { :; }
# upgrade found nothing to do
app_up_to_date() { :; }
# uninstall: after files were restored/removed, before state is removed
app_post_uninstall() { :; }
# --remote: before packaging
app_pre_remote() { :; }

# Deploy one file; apps may override and call deploy_file_default for the rest
# Usage: deploy_file src dest mode strategy install|upgrade
deploy_file() { deploy_file_default "$@"; }

# ---------------------------------------------------------------------------
```

Changes against the copied `claude/install.sh` code:

1. **`load_config`:** Add `log_debug "Shell scripts dir: $SHELL_SCRIPTS_DIR"` after the `Max backups` debug line. In the `dest:` branch, put the placeholder substitution between the `sed` and the `abs_path` call:

```bash
                dest=$(echo "$line" | sed 's/^[[:space:]]*dest:[[:space:]]*//')
                # Resolve ${SHELL_SCRIPTS_DIR} placeholder
                dest="${dest//\$\{SHELL_SCRIPTS_DIR\}/$SHELL_SCRIPTS_DIR}"
                dest=$(abs_path "$dest")
```

After the `while` loop, before `log_debug "Loaded ..."`:

```bash
    # Ensure shell scripts directory exists if any files target it
    local d
    for d in "${CONFIG_DESTS[@]}"; do
        if [[ "$d" == "$SHELL_SCRIPTS_DIR"/* ]] && ! is_dry_run; then
            ensure_dir "$SHELL_SCRIPTS_DIR" || return 1
            break
        fi
    done
```

2. **Add the file-deploy helpers** after `check_requirements`:

```bash
# Path of the file to deploy for a config src
installer_src() { echo "$FILES_DIR/$1"; }

# Strategy for a config src
installer_strategy() { echo replace; }

# Copy one file into place
# Usage: deploy_file_default src dest mode strategy install|upgrade
deploy_file_default() {
    local src="$1" dest="$2" mode="$3" verb="${5:-install}"

    if [[ "$verb" == upgrade ]]; then
        if is_dry_run; then
            log_info "[DRY-RUN] Would update: $src -> $dest"
            return 0
        fi
        log_info "Updating: $(basename "$dest")"
    else
        if is_dry_run; then
            log_info "[DRY-RUN] Would install: $src -> $dest (mode: $mode)"
            return 0
        fi
        log_info "Installing: $(basename "$dest")"
    fi
    copy_file "$src" "$dest" || return 1
    set_permissions "$dest" "$mode"
}

# Deploy every config file
# Usage: deploy_all_files install|upgrade
deploy_all_files() {
    local verb="$1" i
    for i in "${!CONFIG_FILES[@]}"; do
        local name="${CONFIG_FILES[$i]}"
        local dest="${CONFIG_DESTS[$i]}"
        local mode="${CONFIG_MODES[$i]:-0644}"
        local src
        src=$(installer_src "$name")

        if [[ ! -f "$src" ]]; then
            log_error "Source file not found: $src"
            return 1
        fi
        deploy_file "$src" "$dest" "$mode" "$(installer_strategy "$name")" "$verb" || return 1
    done
}
```

3. **`cmd_install`** body after the "already installed" check:

```bash
    # Check requirements
    check_requirements || return 1

    app_pre_install || return 1

    # Initialize backup
    if [[ "$NO_BACKUP" != true ]]; then
        backup_init "$APP_NAME" "$BACKUP_DIR" || return 1
    fi

    # Backup original files
    if [[ "$NO_BACKUP" != true ]]; then
        log_info "Creating original backups..."
        for dest in "${CONFIG_DESTS[@]}"; do
            if [[ -f "$dest" ]]; then
                backup_create_original "$dest" "$BACKUP_DIR" || return 1
            fi
        done
    fi

    app_pre_deploy install || return 1

    log_info "Installing configuration files..."
    deploy_all_files install || return 1

    # Create state file
    if ! is_dry_run; then
        state_init || return 1
        state_create "$APP_NAME" "$APP_VERSION" "$BACKUP_DIR" "${CONFIG_DESTS[@]}" || return 1
    fi

    app_post_files install || return 1

    # Run post-install commands
    run_post_install

    app_post_install install

    log_success "$APP_NAME installed successfully!"
    return 0
```

4. **`cmd_upgrade`:** Wrap the version-skip block in `if [[ "$UPGRADE_ALWAYS" != true ]]; then ... fi`, and call `app_up_to_date` right before its `return 0`. In the snapshot block, use `${ts:-}` instead of `$ts` (`local ts` with no value is unbound under `set -u`). Replace everything from `# Install files (same as install)` to the end of the function with:

```bash
    app_pre_deploy upgrade || return 1

    log_info "Updating configuration files..."
    deploy_all_files upgrade || return 1

    # Update state file (version + file list)
    if ! is_dry_run; then
        state_set_version "$APP_NAME" "$APP_VERSION"
        state_update_files "$APP_NAME" "${CONFIG_DESTS[@]}"
    fi

    app_post_files upgrade || return 1

    # Run post-install commands
    run_post_install

    app_post_install upgrade

    log_success "$APP_NAME upgraded successfully!"
    return 0
```

5. **`cmd_uninstall`:** Call `app_post_uninstall` right after the restore `for` loop, before `# Remove state file`. After `log_info "Backups preserved at: $backup_dir"`, add `log_info "Shell scripts directory left intact: $SHELL_SCRIPTS_DIR"`.

6. **`usage`:** After the `--force` option line, add `  --shell-scripts-dir PATH   Set drop-in directory (default: ~/.bashrc.d)`. End the heredoc after the `Examples` block, then call `app_usage` after the heredoc.

7. **`parse_args`:** Add this before the `*)` case, and replace the `*)` case:

```bash
            --shell-scripts-dir)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --shell-scripts-dir requires a path argument" >&2
                    exit 1
                fi
                SHELL_SCRIPTS_DIR=$(abs_path "$2")
                shift 2
                ;;
            *)
                if app_parse_arg "$@"; then
                    shift "$APP_ARG_SHIFT"
                else
                    echo "Error: Unknown option: $1" >&2
                    usage
                    exit 1
                fi
                ;;
```

8. **`execute_remote`:** After `remote_check_connection || exit 1`, add `app_pre_remote`. Replace the argument filter loop's condition `if [[ "$arg" == "--remote" ]]; then` with `if [[ "$arg" == "--remote" ]] || list_contains "$arg" "${APP_REMOTE_DROP_ARGS[@]}"; then`.

9. **Rename `main` to `installer_main`.** After `load_config || exit 1`, add `app_after_load_config || exit 1`. Do not end the file with a call; apps call `installer_main "$@"`.

Add to `lib/utils.sh` (before the export block) and export it:

```bash
# Check whether a value is among the remaining arguments
# Usage: list_contains needle item...
list_contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}
```

```bash
export -f list_contains
```

- [ ] **Step 4: Rewrite `claude/install.sh`, `vim/install.sh`, `scripts/install.sh`**

`claude/install.sh` (vim and scripts are the same apart from the header comment: `# vim/install.sh - Vim configuration installer`, `# scripts/install.sh - Utility scripts installer`):

```bash
#!/usr/bin/env bash
# claude/install.sh - Claude Code configuration installer
# Usage: ./install.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$APP_DIR")/lib/installer.sh"

installer_main "$@"
```

- [ ] **Step 5: Rewrite `tmux/install.sh`**

```bash
#!/usr/bin/env bash
# tmux/install.sh - Tmux configuration installer
# Usage: ./install.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$APP_DIR")/lib/installer.sh"

# TPM (Tmux Plugin Manager) bootstrap
TPM_DIR="$HOME/.tmux/plugins/tpm"
TPM_REPO="https://github.com/tmux-plugins/tpm"

bootstrap_tpm() {
    if [[ -d "$TPM_DIR/.git" ]]; then
        log_debug "TPM already present at $TPM_DIR"
        return 0
    fi
    log_info "Cloning TPM into $TPM_DIR"
    if is_dry_run; then
        log_info "[DRY-RUN] git clone --depth 1 $TPM_REPO $TPM_DIR"
        return 0
    fi
    git clone --depth 1 "$TPM_REPO" "$TPM_DIR" || {
        log_error "Failed to clone TPM. Check internet connectivity."
        return 1
    }
}

cleanup_tpm() {
    [[ -d "$HOME/.tmux/plugins" ]] || return 0
    log_info "Removing tmux plugins directory"
    is_dry_run && return 0
    rm -rf "$HOME/.tmux/plugins"
}

# Bootstrap TPM before post-install runs install_plugins.
# Non-fatal: failure (e.g. offline) leaves tmux usable without plugins.
app_post_files() {
    bootstrap_tpm || log_warn "TPM bootstrap failed; plugins will not be installed"
}

# Remove TPM and any plugin clones
app_post_uninstall() {
    cleanup_tpm
}

installer_main "$@"
```

- [ ] **Step 6: Run the tests**

Run: `cd test && ./run-core-tests.sh && bash apps/test-tmux.sh && bash apps/test-vim.sh && bash apps/test-scripts.sh`
Expected: all pass (core: "All 37 core library tests passed!").
Run: `bash apps/test-setup.sh`
Expected: still FAIL at Test 9 on `bash` (moves in Task 2).

- [ ] **Step 7: Commit**

```bash
git add lib/installer.sh lib/utils.sh claude/install.sh vim/install.sh scripts/install.sh tmux/install.sh test/apps/test-setup.sh
git commit -m "Extract shared installer core; move claude, vim, scripts, tmux onto it"
```

---

### Task 2: bash, git and packages on the shared core

**Files:**
- Rewrite: `bash/install.sh`, `git/install.sh`, `packages/install.sh`

**Interfaces:**
- Consumes: Task 1 hooks and switches.

- [ ] **Step 1: Rewrite `bash/install.sh`**

```bash
#!/usr/bin/env bash
# bash/install.sh - Bash configuration installer
# Usage: ./install.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$APP_DIR")/lib/installer.sh"

# Bash-specific flags
APPEND_MODE=false
SUPPLEMENT_FILES=()
APP_REMOTE_DROP_ARGS=(--supplement)

app_parse_arg() {
    case $1 in
        --append)
            APPEND_MODE=true
            APP_ARG_SHIFT=1
            ;;
        --supplement)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "Error: --supplement requires a file argument" >&2
                exit 1
            fi
            local supplement_path
            supplement_path=$(abs_path "$2")
            if [[ ! -f "$supplement_path" ]]; then
                echo "Error: Supplement file not found: $2" >&2
                exit 1
            fi
            SUPPLEMENT_FILES+=("$supplement_path")
            APP_ARG_SHIFT=2
            ;;
        *)
            return 1
            ;;
    esac
}

app_usage() {
    cat << EOF
Bash-specific options:
  --append                   Append to existing .bashrc instead of replacing
  --supplement FILE          Install additional file to drop-in directory
                             (repeatable, e.g. --supplement secrets.sh)

Bash examples:
  $0 install --append
  $0 install --supplement ~/secrets.sh
  $0 install --supplement ~/10-path.sh --supplement ~/90-secrets.sh
  $0 install --shell-scripts-dir ~/.config/bash.d

EOF
}

# Ensure shell scripts directory exists
app_after_load_config() {
    if ! is_dry_run; then
        ensure_dir "$SHELL_SCRIPTS_DIR" || return 1
    fi
}

app_pre_remote() {
    if [[ ${#SUPPLEMENT_FILES[@]} -gt 0 ]]; then
        log_warn "--supplement is not supported in --remote mode"
        log_warn "Supplement files must be copied to the remote host manually"
    fi
}
```

Then copy `install_bashrc_file` and `install_supplements` unchanged from the current `bash/install.sh` (lines 150–217), and finish with:

```bash
# Route .bashrc through the append-aware installer
deploy_file() {
    if [[ "$(basename "$1")" == ".bashrc" ]]; then
        install_bashrc_file "$1" "$2" "$3"
    else
        deploy_file_default "$@"
    fi
}

app_post_files() {
    install_supplements
}

installer_main "$@"
```

- [ ] **Step 2: Rewrite `git/install.sh`**

```bash
#!/usr/bin/env bash
# git/install.sh - Git configuration installer
# Usage: ./install.sh <command> [options]

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$APP_DIR")/lib/installer.sh"

SKIP_GIT_SETUP=false
```

Then copy `_preserve_existing_gitconfig` and `_maybe_run_git_setup` unchanged from the current `git/install.sh` (lines 46–118), and finish with:

```bash
app_parse_arg() {
    if [[ "$1" == "--skip-git-setup" ]]; then
        SKIP_GIT_SETUP=true
        APP_ARG_SHIFT=1
        return 0
    fi
    return 1
}

app_usage() {
    cat << EOF
Git-specific options:
  --skip-git-setup     Skip interactive git identity setup (for unattended deploys)

EOF
}

# Preserve existing .gitconfig before overwriting
app_pre_install() {
    _preserve_existing_gitconfig
}

# Prompt for git identity on fresh systems
app_post_install() {
    _maybe_run_git_setup
}

app_up_to_date() {
    _maybe_run_git_setup
}

installer_main "$@"
```

- [ ] **Step 3: Rewrite `packages/install.sh`**

```bash
#!/usr/bin/env bash
# packages/install.sh - Custom tool installer and drop-in manager
# OS package installation is handled by setup.sh.
# This installer manages custom tool scripts and their shell drop-ins.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$APP_DIR")/lib/installer.sh"

APP_NAME="packages"
FILES_DIR="$APP_DIR"   # drop-in paths are relative to packages/
UPGRADE_ALWAYS=true    # custom installs are re-run on every upgrade

# Custom installs (loaded from active profile)
declare -a CUSTOM_NAMES=()
declare -a CUSTOM_CHECKS=()
declare -a CUSTOM_SCRIPTS=()
declare -a CUSTOM_DROPINS=()

# Profiles directory
PROFILES_DIR="$ROOT_DIR/profiles"
```

Then copy these from the current `packages/install.sh`, unchanged: `load_custom_from_profile`, `load_config`, `run_custom_installs`. Copy `cmd_status` and `cmd_verify` unchanged as well; redefining them overrides the core versions. Finish with:

```bash
# No config.yaml: no requirements and no post_install commands
check_requirements() { return 0; }
run_post_install() { return 0; }

app_pre_deploy() {
    if [[ "$1" == install ]]; then
        run_custom_installs
        return
    fi

    # Re-run custom installs unconditionally on upgrade
    local i
    for i in "${!CUSTOM_NAMES[@]}"; do
        local name="${CUSTOM_NAMES[$i]}"
        local script="${CUSTOM_SCRIPTS[$i]}"

        log_info "Re-running custom install: $name"
        if is_dry_run; then
            log_info "[DRY-RUN] Would run: $APP_DIR/$script"
            continue
        fi
        bash "$APP_DIR/$script" || {
            log_warn "Custom install script returned non-zero: $name"
        }
    done
}

app_post_uninstall() {
    log_warn "Custom tools (lazygit, etc.) are not uninstalled automatically"
}

app_usage() {
    cat << EOF
Note: OS package installation is handled by setup.sh, not this installer.

EOF
}

installer_main "$@"
```

- [ ] **Step 4: Run all tests**

Run: `cd test && ./run-core-tests.sh && ./run-app-tests.sh`
Expected: all pass, including test-setup Tests 9–10. If an app test greps output text that the core changed (for example a usage line), restore that text in the app's `app_usage` instead of editing the test.

Run: `wc -l */install.sh lib/installer.sh`
Expected: each app `install.sh` under ~130 lines.

- [ ] **Step 5: Commit**

```bash
git add bash/install.sh git/install.sh packages/install.sh
git commit -m "Move bash, git, packages installers onto the shared core"
```

---

### Task 3: `lib/overlay.sh` and `lib/hosts.sh`

**Files:**
- Create: `lib/overlay.sh`, `lib/hosts.sh`, `test/apps/test-overlay.sh`

**Interfaces:**
- Produces:
  - `overlay_config_entries CONFIG_YAML` → stdout lines `src<TAB>strategy` (strategy defaults to `replace`)
  - `overlay_check_strategy KEY STRATEGY` → 0/1; logs an error for an unknown strategy or merge on a non-`.json` file
  - `overlay_resolve_strategies APP_DIR STRATEGIES_FILE` → stdout lines `src strategy`, in config order, last declaration wins
  - `overlay_validate_app APP_DIR STRATEGIES_FILE [LAYER_ROOT...]` → 0/1 (logs each error)
  - `overlay_json_merge OUT FILE...` → 0/1; on failure OUT is untouched; OUT may also be one of the inputs
  - `overlay_stage_app APP_DIR STAGE_DIR STRATEGIES_FILE [LAYER_ROOT...]` → 0/1; writes `STAGE_DIR/{files/<src>,strategies,skip,version}`
  - `overlay_hash` (stdin → 12 hex chars)
  - STRATEGIES_FILE format: lines `<app>/<src> <strategy>`, lowest precedence first. A LAYER_ROOT is a directory whose `apps/<app>/files/<src>` overlays the dotfiles file, lowest precedence first.
  - `hosts_normalize_name SPEC` → host name (removes `user@` and the domain; keeps IPv4 addresses whole)
  - `hosts_resolve_profile_path PROFILES_DIR HOSTS_REPO NAME SKIP_HOSTS` → path (hosts repo first unless SKIP_HOSTS=true or HOSTS_REPO empty)
  - `hosts_read_scalar FILE KEY` → value of top-level `KEY:` (empty if absent)
  - `hosts_parse_files_map FILE` → stdout `<app>/<src> <strategy>` lines; returns 1 on a malformed entry

- [ ] **Step 1: Write the failing unit tests** in `test/apps/test-overlay.sh`

```bash
#!/usr/bin/env bash
# test-overlay.sh - Unit tests for lib/overlay.sh and lib/hosts.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$TEST_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

echo "======================================"
echo "Overlay / Hosts Library Tests"
echo "======================================"
echo

source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/overlay.sh"
source "$ROOT_DIR/lib/hosts.sh"

T="/tmp/dotfiles-test-overlay"
rm -rf "$T"
mkdir -p "$T"

APP="$T/repo/demo"
P1="$T/p1"
H1="$T/h1"
NONE="$T/no-strategies"
: > "$NONE"

mkdir -p "$APP/files" "$P1/apps/demo/files" "$H1/apps/demo/files"
cat > "$APP/config.yaml" << 'EOF'
app:
  name: demo
files:
  - src: a.json
    dest: ~/a.json
    mode: '0644'
    strategy: merge
  - src: b.txt
    dest: ~/b.txt
    mode: '0644'
  - src: c.json
    dest: ~/c.json
    mode: '0644'
EOF
echo '{"base":1,"shared":"base","arr":[1,2],"obj":{"x":1}}' > "$APP/files/a.json"
echo 'base b' > "$APP/files/b.txt"
echo '{"c":"base","baseonly":1}' > "$APP/files/c.json"
echo '{"shared":"profile","obj":{"y":2}}' > "$P1/apps/demo/files/a.json"
echo 'profile b' > "$P1/apps/demo/files/b.txt"
echo '{"arr":[9],"host":true}' > "$H1/apps/demo/files/a.json"
echo 'host b' > "$H1/apps/demo/files/b.txt"
echo '{"c":"host"}' > "$H1/apps/demo/files/c.json"

jqc() { jq -c -S "$@"; }

# Test 1
info "Test 1: overlay_config_entries reads src and strategy"
expected=$'a.json\tmerge\nb.txt\treplace\nc.json\treplace'
[[ "$(overlay_config_entries "$APP/config.yaml")" == "$expected" ]] \
    && pass "config entries parsed" || fail "config entries wrong: $(overlay_config_entries "$APP/config.yaml")"

# Test 2
info "Test 2: overlay_json_merge merges objects, replaces arrays, later wins"
overlay_json_merge "$T/m.json" "$APP/files/a.json" "$P1/apps/demo/files/a.json" "$H1/apps/demo/files/a.json"
[[ "$(jqc . "$T/m.json")" == '{"arr":[9],"base":1,"host":true,"obj":{"x":1,"y":2},"shared":"profile"}' ]] \
    && pass "merge result correct" || fail "merge result: $(jqc . "$T/m.json")"

# Test 3
info "Test 3: overlay_json_merge into one of its inputs (live file)"
echo '{"live":1,"shared":"live"}' > "$T/live.json"
overlay_json_merge "$T/live.json" "$T/live.json" "$P1/apps/demo/files/a.json"
[[ "$(jqc . "$T/live.json")" == '{"live":1,"obj":{"y":2},"shared":"profile"}' ]] \
    && pass "in-place merge keeps live keys" || fail "in-place merge: $(jqc . "$T/live.json")"

# Test 4
info "Test 4: invalid JSON fails and leaves output untouched"
echo '{oops' > "$T/bad.json"
echo '{"keep":1}' > "$T/out.json"
if overlay_json_merge "$T/out.json" "$T/out.json" "$T/bad.json" 2>/dev/null; then
    fail "merge with invalid JSON should fail"
fi
[[ "$(cat "$T/out.json")" == '{"keep":1}' ]] && pass "invalid JSON rejected, output untouched" || fail "output modified"

# Test 5
info "Test 5: non-object JSON is rejected"
echo '[]' > "$T/arr.json"
if overlay_json_merge "$T/out.json" "$T/out.json" "$T/arr.json" 2>/dev/null; then
    fail "merge with a JSON array should fail"
fi
pass "non-object JSON rejected"

# Test 6
info "Test 6: missing jq fails with a clear message"
out=$( (PATH=/nonexistent; overlay_json_merge "$T/out.json" "$T/out.json" "$APP/files/a.json") 2>&1 ) && fail "should fail without jq"
[[ "$out" == *"jq is required"* ]] && pass "missing jq reported" || fail "message was: $out"

# Test 7
info "Test 7: stage with no layers copies dotfiles files"
overlay_stage_app "$APP" "$T/s0" "$NONE"
cmp -s "$T/s0/files/b.txt" "$APP/files/b.txt" || fail "b.txt not staged"
[[ "$(cat "$T/s0/strategies")" == $'a.json merge\nb.txt replace\nc.json replace' ]] || fail "strategies: $(cat "$T/s0/strategies")"
[[ "$(cat "$T/s0/version")" =~ ^[0-9a-f]{12}$ ]] || fail "version: $(cat "$T/s0/version")"
[[ ! -s "$T/s0/skip" ]] || fail "skip should be empty"
pass "no-layer stage correct"

# Test 8
info "Test 8: stage with profile and host layers"
overlay_stage_app "$APP" "$T/s1" "$NONE" "$P1" "$H1"
[[ "$(cat "$T/s1/files/b.txt")" == "host b" ]] || fail "replace should pick host layer"
[[ "$(jqc . "$T/s1/files/a.json")" == '{"arr":[9],"base":1,"host":true,"obj":{"x":1,"y":2},"shared":"profile"}' ]] \
    || fail "a.json: $(jqc . "$T/s1/files/a.json")"
[[ "$(jqc . "$T/s1/files/c.json")" == '{"c":"host"}' ]] || fail "c.json should be replaced by host layer"
pass "layered stage correct"

# Test 9
info "Test 9: strategy overrides, last declaration wins"
printf 'demo/c.json merge\n' > "$T/strat1"
overlay_stage_app "$APP" "$T/s2" "$T/strat1" "$P1" "$H1"
[[ "$(jqc . "$T/s2/files/c.json")" == '{"baseonly":1,"c":"host"}' ]] || fail "c.json merge: $(jqc . "$T/s2/files/c.json")"
printf 'demo/c.json merge\ndemo/c.json replace\n' > "$T/strat2"
overlay_stage_app "$APP" "$T/s3" "$T/strat2" "$P1" "$H1"
[[ "$(jqc . "$T/s3/files/c.json")" == '{"c":"host"}' ]] || fail "later replace should win"
pass "strategy precedence correct"

# Test 10
info "Test 10: version is stable, changes with a layer, ignores other apps"
overlay_stage_app "$APP" "$T/s4" "$NONE" "$P1" "$H1"
[[ "$(cat "$T/s1/version")" == "$(cat "$T/s4/version")" ]] || fail "version not stable"
mkdir -p "$T/repo/other/files" && echo x > "$T/repo/other/files/x"
overlay_stage_app "$APP" "$T/s5" "$NONE" "$P1" "$H1"
[[ "$(cat "$T/s1/version")" == "$(cat "$T/s5/version")" ]] || fail "unrelated app changed version"
echo 'host b2' > "$H1/apps/demo/files/b.txt"
overlay_stage_app "$APP" "$T/s6" "$NONE" "$P1" "$H1"
[[ "$(cat "$T/s1/version")" != "$(cat "$T/s6/version")" ]] || fail "layer change did not change version"
echo 'host b' > "$H1/apps/demo/files/b.txt"
pass "version behaves"

# Test 11
info "Test 11: missing source in every layer fails the stage"
mv "$APP/files/b.txt" "$T/b.txt.bak"
if overlay_stage_app "$APP" "$T/s7" "$NONE" 2>/dev/null; then
    mv "$T/b.txt.bak" "$APP/files/b.txt"
    fail "stage should fail when no layer has b.txt"
fi
mv "$T/b.txt.bak" "$APP/files/b.txt"
pass "missing source detected"

# Test 12
info "Test 12: invalid JSON in a layer skips only that file"
mkdir -p "$T/hbad/apps/demo/files"
echo '{bad' > "$T/hbad/apps/demo/files/a.json"
overlay_stage_app "$APP" "$T/s8" "$NONE" "$T/hbad" 2>/dev/null || fail "stage should continue"
[[ "$(cat "$T/s8/skip")" == "a.json" ]] || fail "skip: $(cat "$T/s8/skip")"
[[ -f "$T/s8/files/b.txt" ]] || fail "other files should still be staged"
pass "bad layer skipped"

# Test 13
info "Test 13: overlay_validate_app"
overlay_validate_app "$APP" "$NONE" "$P1" "$H1" || fail "valid overlays rejected"
mkdir -p "$T/htypo/apps/demo/files" && echo x > "$T/htypo/apps/demo/files/a.jsno"
out=$(overlay_validate_app "$APP" "$NONE" "$T/htypo" 2>&1) && fail "unknown overlay src accepted"
[[ "$out" == *"a.jsno"* ]] || fail "message should name the file: $out"
printf 'demo/zzz.json merge\n' > "$T/strat3"
overlay_validate_app "$APP" "$T/strat3" 2>/dev/null && fail "unknown files: key accepted"
printf 'demo/b.txt merge\n' > "$T/strat4"
overlay_validate_app "$APP" "$T/strat4" 2>/dev/null && fail "merge on non-json accepted"
printf 'demo/b.txt copy\n' > "$T/strat5"
overlay_validate_app "$APP" "$T/strat5" 2>/dev/null && fail "unknown strategy accepted"
printf 'other/x merge\n' > "$T/strat6"
overlay_validate_app "$APP" "$T/strat6" || fail "keys for other apps must be ignored here"
pass "validation correct"

# Test 14
info "Test 14: hosts_normalize_name"
[[ "$(hosts_normalize_name user@web1.example.com)" == web1 ]] || fail "user@fqdn"
[[ "$(hosts_normalize_name web1)" == web1 ]] || fail "bare"
[[ "$(hosts_normalize_name web1.lan)" == web1 ]] || fail "domain"
[[ "$(hosts_normalize_name user@10.0.0.5)" == 10.0.0.5 ]] || fail "IPv4 must stay whole"
pass "host names normalized"

# Test 15
info "Test 15: hosts_resolve_profile_path"
mkdir -p "$T/hr/profiles" "$T/df/profiles"
touch "$T/hr/profiles/minimal.yaml" "$T/df/profiles/minimal.yaml" "$T/df/profiles/complete.yaml"
[[ "$(hosts_resolve_profile_path "$T/df/profiles" "$T/hr" minimal false)" == "$T/hr/profiles/minimal.yaml" ]] || fail "hosts first"
[[ "$(hosts_resolve_profile_path "$T/df/profiles" "$T/hr" minimal true)" == "$T/df/profiles/minimal.yaml" ]] || fail "skip hosts"
[[ "$(hosts_resolve_profile_path "$T/df/profiles" "$T/hr" complete false)" == "$T/df/profiles/complete.yaml" ]] || fail "fallback"
[[ "$(hosts_resolve_profile_path "$T/df/profiles" "" minimal false)" == "$T/df/profiles/minimal.yaml" ]] || fail "no hosts repo"
pass "profile lookup order"

# Test 16
info "Test 16: hosts_read_scalar and hosts_parse_files_map"
cat > "$T/host.yaml" << 'EOF'
# comment
profile: complete   # trailing comment
exclude:
  - lazyssh
files:
  claude/settings.json: merge
  tmux/.tmux.conf: replace
EOF
[[ "$(hosts_read_scalar "$T/host.yaml" profile)" == complete ]] || fail "profile scalar"
[[ -z "$(hosts_read_scalar "$T/host.yaml" missing)" ]] || fail "missing scalar"
[[ "$(hosts_parse_files_map "$T/host.yaml")" == $'claude/settings.json merge\ntmux/.tmux.conf replace' ]] \
    || fail "files map: $(hosts_parse_files_map "$T/host.yaml")"
printf 'files:\n  settings.json: merge\n' > "$T/badmap.yaml"
hosts_parse_files_map "$T/badmap.yaml" >/dev/null 2>&1 && fail "key without app/ accepted"
pass "host.yaml parsing"

rm -rf "$T"
echo
echo "======================================"
echo -e "${GREEN}All 16 overlay/hosts library tests passed!${NC}"
echo "======================================"
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd test && bash apps/test-overlay.sh`
Expected: FAIL at the `source "$ROOT_DIR/lib/overlay.sh"` line with "No such file or directory".

- [ ] **Step 3: Create `lib/overlay.sh`**

```bash
#!/usr/bin/env bash
# overlay.sh - Compose app files from dotfiles and dotfiles-hosts layers
#
# A staging directory for one app holds:
#   files/<src>   the composed file to deploy (replace: winning layer;
#                 merge: repo layers pre-merged)
#   strategies    "<src> <strategy>" per config.yaml file entry
#   skip          srcs whose repo layers could not be merged
#   version       content hash used as the app version

# Print "src<TAB>strategy" for each files[] entry of an app config.yaml
# Usage: overlay_config_entries config.yaml
overlay_config_entries() {
    local config="$1" line in_files=false src="" strategy=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^files: ]]; then
            in_files=true
            continue
        fi
        [[ "$in_files" == true ]] || continue
        [[ "$line" =~ ^[[:alpha:]] ]] && break

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*src:[[:space:]]*([^[:space:]]+) ]]; then
            if [[ -n "$src" ]]; then
                printf '%s\t%s\n' "$src" "${strategy:-replace}"
            fi
            src="${BASH_REMATCH[1]}"
            strategy=""
        elif [[ "$line" =~ ^[[:space:]]+strategy:[[:space:]]*([^[:space:]#]+) ]]; then
            strategy="${BASH_REMATCH[1]}"
        fi
    done < "$config"

    if [[ -n "$src" ]]; then
        printf '%s\t%s\n' "$src" "${strategy:-replace}"
    fi
    return 0
}

# Check a strategy value for a file
# Usage: overlay_check_strategy <app>/<src> strategy
overlay_check_strategy() {
    local key="$1" strategy="$2"
    case "$strategy" in
        replace)
            return 0
            ;;
        merge)
            if [[ "$key" != *.json ]]; then
                log_error "merge strategy requires a .json file: $key"
                return 1
            fi
            return 0
            ;;
        *)
            log_error "Unknown strategy '$strategy' for $key (use replace or merge)"
            return 1
            ;;
    esac
}

# Print "src strategy" for every config.yaml file entry, in config order,
# applying overrides from a strategies file (last declaration wins)
# Usage: overlay_resolve_strategies app_dir strategies_file
overlay_resolve_strategies() {
    local app_dir="$1" strategies_file="$2"
    local app src strategy key
    app=$(basename "$app_dir")
    local -a order=()
    local -A final=()

    while IFS=$'\t' read -r src strategy; do
        order+=("$src")
        final["$src"]="$strategy"
    done < <(overlay_config_entries "$app_dir/config.yaml")

    while read -r key strategy; do
        [[ "${key%%/*}" == "$app" ]] || continue
        src="${key#*/}"
        if [[ -n "${final[$src]:-}" ]]; then
            final["$src"]="$strategy"
        fi
    done < "$strategies_file"

    for src in "${order[@]}"; do
        echo "$src ${final[$src]}"
    done
}

# Validate overlays and strategies for one app; logs every problem
# Usage: overlay_validate_app app_dir strategies_file [layer_root...]
overlay_validate_app() {
    local app_dir="$1" strategies_file="$2"
    shift 2
    local app src strategy key root f rel ok=0
    app=$(basename "$app_dir")
    local -A known=()

    while IFS=$'\t' read -r src strategy; do
        known["$src"]=1
    done < <(overlay_config_entries "$app_dir/config.yaml")

    for root in "$@"; do
        [[ -d "$root/apps/$app/files" ]] || continue
        while IFS= read -r f; do
            rel="${f#"$root/apps/$app/files/"}"
            if [[ -z "${known[$rel]:-}" ]]; then
                log_error "Overlay file $f: '$rel' is not a src in $app/config.yaml"
                ok=1
            fi
        done < <(find "$root/apps/$app/files" -type f)
    done

    while read -r key strategy; do
        [[ "${key%%/*}" == "$app" ]] || continue
        if [[ -z "${known[${key#*/}]:-}" ]]; then
            log_error "files: entry '$key' is not a src in $app/config.yaml"
            ok=1
        fi
    done < "$strategies_file"

    while read -r src strategy; do
        overlay_check_strategy "$app/$src" "$strategy" || ok=1
    done < <(overlay_resolve_strategies "$app_dir" "$strategies_file")

    return $ok
}

# Merge JSON objects left to right with jq's `*` and write the result to out.
# Fails, leaving out untouched, if jq is missing or an input is not a JSON object.
# out may also be one of the inputs.
# Usage: overlay_json_merge out file...
overlay_json_merge() {
    local out="$1"
    shift

    if ! command_exists jq; then
        log_error "jq is required to merge JSON files (strategy: merge); install jq"
        return 1
    fi

    local f
    for f in "$@"; do
        if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
            log_error "Not a valid JSON object: $f"
            return 1
        fi
    done

    local tmp
    tmp=$(mktemp "$(dirname "$out")/.$(basename "$out").merge.XXXXXX") || return 1
    if ! jq -s 'reduce .[] as $x ({}; . * $x)' "$@" > "$tmp"; then
        rm -f "$tmp"
        log_error "jq merge failed for $out"
        return 1
    fi
    mv "$tmp" "$out"
}

# Hash stdin to a short version string
overlay_hash() {
    if command_exists sha256sum; then
        sha256sum
    else
        shasum -a 256
    fi | cut -c1-12
}

# Write stage_dir/version from config.yaml, strategies, skip and staged files
# Usage: overlay_write_version app_dir stage_dir
overlay_write_version() {
    local app_dir="$1" stage_dir="$2" src strategy
    {
        cat "$app_dir/config.yaml"
        cat "$stage_dir/strategies" "$stage_dir/skip"
        while read -r src strategy; do
            printf '== %s\n' "$src"
            cat "$stage_dir/files/$src" 2>/dev/null || true
        done < "$stage_dir/strategies"
    } | overlay_hash > "$stage_dir/version"
}

# Build the staging directory for one app
# Usage: overlay_stage_app app_dir stage_dir strategies_file [layer_root...]
# Returns 1 on a fatal error for this app (bad strategy, missing source).
# A merge file whose repo layers can't be merged is listed in stage_dir/skip.
overlay_stage_app() {
    local app_dir="$1" stage_dir="$2" strategies_file="$3"
    shift 3
    local app src strategy root
    app=$(basename "$app_dir")

    mkdir -p "$stage_dir/files" || return 1
    : > "$stage_dir/strategies"
    : > "$stage_dir/skip"

    while read -r src strategy; do
        overlay_check_strategy "$app/$src" "$strategy" || return 1

        local -a layers=()
        if [[ -f "$app_dir/files/$src" ]]; then
            layers+=("$app_dir/files/$src")
        fi
        for root in "$@"; do
            if [[ -f "$root/apps/$app/files/$src" ]]; then
                layers+=("$root/apps/$app/files/$src")
            fi
        done

        if [[ ${#layers[@]} -eq 0 ]]; then
            log_error "Source file not found: $app_dir/files/$src (and no overlay provides it)"
            return 1
        fi

        local out="$stage_dir/files/$src"
        mkdir -p "$(dirname "$out")" || return 1
        echo "$src $strategy" >> "$stage_dir/strategies"

        if [[ "$strategy" == merge ]] && { [[ ${#layers[@]} -gt 1 ]] || command_exists jq; }; then
            if ! overlay_json_merge "$out" "${layers[@]}"; then
                log_error "Cannot merge repo layers for $app/$src; skipping it"
                echo "$src" >> "$stage_dir/skip"
            fi
        else
            cp "${layers[-1]}" "$out" || return 1
        fi
    done < <(overlay_resolve_strategies "$app_dir" "$strategies_file")

    overlay_write_version "$app_dir" "$stage_dir"
}

export -f overlay_config_entries
export -f overlay_check_strategy
export -f overlay_resolve_strategies
export -f overlay_validate_app
export -f overlay_json_merge
export -f overlay_hash
export -f overlay_write_version
export -f overlay_stage_app
```

- [ ] **Step 4: Create `lib/hosts.sh`**

```bash
#!/usr/bin/env bash
# hosts.sh - dotfiles-hosts repo helpers (profile lookup, host.yaml parsing)

# Host name used for hosts/<name>/: strips user@ and the domain.
# IPv4 addresses are kept whole.
# Usage: hosts_normalize_name [user@]host[.domain]
hosts_normalize_name() {
    local h="${1#*@}"
    if [[ "$h" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        echo "$h"
    else
        echo "${h%%.*}"
    fi
}

# Resolve a profile name: hosts repo first (unless skip_hosts), then dotfiles
# Usage: hosts_resolve_profile_path profiles_dir hosts_repo name skip_hosts
hosts_resolve_profile_path() {
    local profiles_dir="$1" hosts_repo="$2" name="$3" skip_hosts="${4:-false}"
    if [[ -n "$hosts_repo" && "$skip_hosts" != true && -f "$hosts_repo/profiles/$name.yaml" ]]; then
        echo "$hosts_repo/profiles/$name.yaml"
    else
        echo "$profiles_dir/$name.yaml"
    fi
}

# Print the value of a top-level "key: value" line (empty if absent)
# Usage: hosts_read_scalar file key
hosts_read_scalar() {
    local file="$1" key="$2" line v
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^${key}:[[:space:]]*([^#]*) ]]; then
            v="${BASH_REMATCH[1]}"
            v="${v%"${v##*[![:space:]]}"}"
            v="${v#[\"\']}"
            v="${v%[\"\']}"
            echo "$v"
            return 0
        fi
    done < "$file"
    return 0
}

# Print "<app>/<src> <strategy>" for each entry of a top-level files: map
# Usage: hosts_parse_files_map file
hosts_parse_files_map() {
    local file="$1" line in_files=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ "$line" =~ ^files:[[:space:]]*$ ]]; then
            in_files=true
            continue
        fi
        [[ "$in_files" == true ]] || continue
        [[ "$line" =~ ^[[:alpha:]] ]] && break

        if [[ "$line" =~ ^[[:space:]]+([^[:space:]:/]+/[^[:space:]:]+):[[:space:]]*([[:alnum:]_-]+)[[:space:]]*(#.*)?$ ]]; then
            echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        else
            log_error "$file: invalid files: entry (expected '<app>/<src>: <strategy>'): $line"
            return 1
        fi
    done < "$file"
    return 0
}

export -f hosts_normalize_name
export -f hosts_resolve_profile_path
export -f hosts_read_scalar
export -f hosts_parse_files_map
```

- [ ] **Step 5: Run the tests**

Run: `cd test && bash apps/test-overlay.sh`
Expected: "All 16 overlay/hosts library tests passed!"

- [ ] **Step 6: Commit**

```bash
git add lib/overlay.sh lib/hosts.sh test/apps/test-overlay.sh
git commit -m "Add overlay staging/merge and hosts-repo helper libraries"
```

---

### Task 4: Installer stages, merges, and versions by content; claude settings.json merges

**Files:**
- Modify: `lib/installer.sh`, `lib/remote.sh`, `packages/install.sh`, `claude/config.yaml`, `test/apps/test-setup.sh` (Test 20), `test/run-remote-tests.sh` (Test 2 call)
- Create: `test/apps/test-claude.sh`

**Interfaces:**
- Consumes: `overlay_stage_app`, `overlay_json_merge`, `list_contains`.
- Produces (used by Task 6):
  - Installer option `--stage DIR`. DIR must contain a `version` file.
  - Env `DOTFILES_FAILURES_FILE`: when set, the installer appends one `<app>/<src>` line per failed file.
  - Installer exit status is non-zero if any file failed. The state version is then `incomplete`.
  - `remote_package_installer APP_DIR VERSION [STAGE_DIR]` → package path. The stage ships as `<app>/.stage`.
  - `remote_skip_if_current APP_NAME COMMAND FORCE LOCAL_VERSION`

- [ ] **Step 1: Write the failing test** `test/apps/test-claude.sh`

```bash
#!/usr/bin/env bash
# test-claude.sh - Claude module tests (settings.json merge strategy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$TEST_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

echo "======================================"
echo "Claude Module Tests"
echo "======================================"
echo

TEST_STATE="/tmp/dotfiles-test-claudetest"
TEST_HOME="/tmp/home-test-claudetest"
rm -rf "$TEST_STATE" "$TEST_HOME"
mkdir -p "$TEST_STATE/apps" "$TEST_HOME/.claude"
export STATE_DIR="$TEST_STATE"
export HOME="$TEST_HOME"

REPO_SETTINGS="$ROOT_DIR/claude/files/settings.json"
LIVE="$HOME/.claude/settings.json"
cd "$ROOT_DIR/claude"

state_version() { grep "^  version:" "$STATE_DIR/apps/claude.yaml" | awk '{print $2}'; }

# Test 1
info "Test 1: config declares merge for settings.json"
[[ "$(sed -n '/src: settings.json/,/src:/p' config.yaml)" == *"strategy: merge"* ]] \
    && pass "settings.json uses merge" || fail "settings.json strategy is not merge"

# Test 2
info "Test 2: deploy merges into an existing live file"
echo '{"model":"live-model","liveOnly":1,"enabledPlugins":{"x@y":true}}' > "$LIVE"
./install.sh deploy --no-backup &>/dev/null || fail "deploy failed"
[[ "$(jq -r .liveOnly "$LIVE")" == 1 ]] || fail "unmanaged live key lost"
[[ "$(jq -c .enabledPlugins "$LIVE")" == '{"x@y":true}' ]] || fail "unmanaged live object lost"
[[ "$(jq -c .model "$LIVE")" == "$(jq -c .model "$REPO_SETTINGS")" ]] || fail "repo key not applied"
cmp -s "$HOME/.claude/statusline-command.sh" files/statusline-command.sh || fail "replace file not deployed"
pass "merge keeps live keys, applies repo keys"

# Test 3
info "Test 3: version is a content hash; redeploy is a no-op"
[[ "$(state_version)" =~ ^[0-9a-f]{12}$ ]] || fail "version: $(state_version)"
./install.sh deploy --no-backup 2>&1 | grep -q "already up to date" || fail "redeploy should skip"
pass "content-hash version"

# Test 4
info "Test 4: diff of a merged file compares against the merge result"
./install.sh diff 2>&1 | grep -q "No differences found" || fail "diff should be clean after deploy"
pass "merge-aware diff"

# Test 5
info "Test 5: invalid live JSON fails that file only, live untouched, retried next run"
echo '{oops' > "$LIVE"
cp "$LIVE" "$HOME/live.bak"
echo "# stale" > "$HOME/.claude/statusline-command.sh"
rc=0
./install.sh upgrade --force --no-backup &>/dev/null || rc=$?
[[ $rc -ne 0 ]] || fail "upgrade should fail"
cmp -s "$LIVE" "$HOME/live.bak" || fail "live file was modified"
cmp -s "$HOME/.claude/statusline-command.sh" files/statusline-command.sh || fail "other files should still deploy"
[[ "$(state_version)" == incomplete ]] || fail "version should be 'incomplete', got $(state_version)"
echo '{"liveOnly":2}' > "$LIVE"
out=$(./install.sh deploy --no-backup 2>&1) || fail "retry failed: $out"
[[ "$out" != *"already up to date"* ]] || fail "incomplete install was skipped"
[[ "$(jq -r .liveOnly "$LIVE")" == 2 ]] || fail "retry did not merge"
pass "per-file failure handled and retried"

# Test 6
info "Test 6: non-object live JSON fails and is left untouched"
echo '[]' > "$LIVE"
./install.sh upgrade --force --no-backup &>/dev/null && fail "upgrade should fail on []"
[[ "$(cat "$LIVE")" == "[]" ]] || fail "live [] was modified"
pass "non-object rejected"

# Test 7
info "Test 7: empty live file is treated as absent"
: > "$LIVE"
./install.sh upgrade --force --no-backup &>/dev/null || fail "upgrade failed on empty live file"
[[ "$(jq -c -S . "$LIVE")" == "$(jq -c -S . "$REPO_SETTINGS")" ]] || fail "empty live should become repo settings"
pass "empty live file handled"

# Test 8
info "Test 8: dry-run reports merge and changes nothing"
echo '{"liveOnly":3}' > "$LIVE"
./install.sh upgrade --force --dry-run 2>&1 | grep -q "Would merge" || fail "dry-run should say 'Would merge'"
[[ "$(cat "$LIVE")" == '{"liveOnly":3}' ]] || fail "dry-run modified live file"
pass "dry-run merge"

# Test 9
info "Test 9: missing jq fails the app with a clear message"
NOJQ="$HOME/nojq-bin"
mkdir -p "$NOJQ"
for f in /usr/bin/* /bin/*; do
    [[ "$(basename "$f")" == jq ]] && continue
    ln -sf "$f" "$NOJQ/" 2>/dev/null || true
done
out=$(PATH="$NOJQ" ./install.sh upgrade --force --no-backup 2>&1) && fail "should fail without jq"
[[ "$out" == *"jq is required"* ]] || fail "message was: $out"
[[ "$(cat "$LIVE")" == '{"liveOnly":3}' ]] || fail "live file changed without jq"
pass "missing jq reported"

./install.sh uninstall &>/dev/null || true
rm -rf "$TEST_STATE" "$TEST_HOME"

echo
echo "======================================"
echo -e "${GREEN}All 9 claude module tests passed!${NC}"
echo "======================================"
```

In `test/apps/test-setup.sh`, replace Test 20 with:

```bash
# Test 20: Version stored on install is a content hash
info "Test 20: Version stored on install"
STATE_FILE="$STATE_DIR/apps/bash.yaml"
VERSION=$(grep "^  version:" "$STATE_FILE" | awk '{print $2}')
if [[ "$VERSION" =~ ^[0-9a-f]{12}$ ]]; then
    pass "State file contains content hash ($VERSION)"
else
    fail "State file should contain a 12-char content hash, got '$VERSION'"
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd test && bash apps/test-claude.sh`
Expected: FAIL at Test 1 ("settings.json strategy is not merge").

- [ ] **Step 3: Migrate `claude/config.yaml`**

```yaml
files:
  - src: settings.json
    dest: ~/.claude/settings.json
    mode: '0644'
    strategy: merge
```

`claude/files/settings.json` already holds only shared settings. The machine-specific keys (plugins, marketplaces, `effortLevel`, `tui`) exist only in live files, and merge preserves them. Do not touch that file; it has uncommitted user changes.

- [ ] **Step 4: Add staging, merge deploy and failure tracking to `lib/installer.sh`**

Source the new lib after `remote.sh`: `source "$ROOT_DIR/lib/overlay.sh"`.

Add to the globals:

```bash
# Staging directory (--stage, or built by prepare_stage)
STAGE_DIR=""
STAGING_ENABLED=true   # false for apps without config.yaml (packages)

# Per-run count of files that failed to deploy
FILE_FAILURES=0
```

Replace `installer_src`, `installer_strategy`, `deploy_file_default` and `deploy_all_files` with:

```bash
# Path of the file to deploy for a config src
installer_src() {
    if [[ -n "$STAGE_DIR" ]]; then
        echo "$STAGE_DIR/files/$1"
    else
        echo "$FILES_DIR/$1"
    fi
}

# Strategy for a config src (replace unless the stage says otherwise)
installer_strategy() {
    local src strategy
    if [[ -n "$STAGE_DIR" ]]; then
        while read -r src strategy; do
            if [[ "$src" == "$1" ]]; then
                echo "$strategy"
                return 0
            fi
        done < "$STAGE_DIR/strategies"
    fi
    echo replace
}

# True if staging could not compose this src
installer_is_skipped() {
    [[ -n "$STAGE_DIR" ]] && grep -qxF "$1" "$STAGE_DIR/skip"
}

# Count a failed file and report it to setup.sh
record_file_failure() {
    FILE_FAILURES=$((FILE_FAILURES + 1))
    if [[ -n "${DOTFILES_FAILURES_FILE:-}" ]]; then
        echo "$(basename "$APP_DIR")/$1" >> "$DOTFILES_FAILURES_FILE"
    fi
}

# Copy (replace) or merge (JSON) one file into place
# Usage: deploy_file_default src dest mode strategy install|upgrade
deploy_file_default() {
    local src="$1" dest="$2" mode="$3" strategy="${4:-replace}" verb="${5:-install}"

    if [[ "$strategy" == merge ]]; then
        if is_dry_run; then
            log_info "[DRY-RUN] Would merge: $src -> $dest (mode: $mode)"
            return 0
        fi
        log_info "Merging: $(basename "$dest")"
        ensure_dir "$(dirname "$dest")" || return 1
        if [[ -s "$dest" ]]; then
            overlay_json_merge "$dest" "$dest" "$src" || return 1
        else
            copy_file "$src" "$dest" || return 1
        fi
        set_permissions "$dest" "$mode"
        return
    fi

    if [[ "$verb" == upgrade ]]; then
        if is_dry_run; then
            log_info "[DRY-RUN] Would update: $src -> $dest"
            return 0
        fi
        log_info "Updating: $(basename "$dest")"
    else
        if is_dry_run; then
            log_info "[DRY-RUN] Would install: $src -> $dest (mode: $mode)"
            return 0
        fi
        log_info "Installing: $(basename "$dest")"
    fi
    copy_file "$src" "$dest" || return 1
    set_permissions "$dest" "$mode"
}

# Deploy every config file. A failed file is counted and skipped; the
# others continue. A missing source aborts.
# Usage: deploy_all_files install|upgrade
deploy_all_files() {
    local verb="$1" i
    FILE_FAILURES=0
    for i in "${!CONFIG_FILES[@]}"; do
        local name="${CONFIG_FILES[$i]}"
        local dest="${CONFIG_DESTS[$i]}"
        local mode="${CONFIG_MODES[$i]:-0644}"
        local src
        src=$(installer_src "$name")

        if installer_is_skipped "$name"; then
            log_error "Skipping $name: its repo layers could not be merged"
            record_file_failure "$name"
            continue
        fi
        if [[ ! -f "$src" ]]; then
            log_error "Source file not found: $src"
            return 1
        fi
        if ! deploy_file "$src" "$dest" "$mode" "$(installer_strategy "$name")" "$verb"; then
            log_error "Failed to deploy $name; left $dest as it was"
            record_file_failure "$name"
        fi
    done
}

# Version recorded in state: incomplete when any file failed
installed_version() {
    if [[ $FILE_FAILURES -gt 0 ]]; then
        echo incomplete
    else
        echo "$APP_VERSION"
    fi
}

# Version of what would be deployed
installer_version() {
    if [[ -n "$STAGE_DIR" ]]; then
        cat "$STAGE_DIR/version"
    elif [[ -f "$APP_DIR/.version" ]]; then
        cat "$APP_DIR/.version"
    else
        (cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    fi
}

# Commands that deploy files need a stage
command_needs_stage() {
    list_contains "$COMMAND" deploy install upgrade diff
}

# Stage this app's own files (dotfiles layer only) when no --stage was given
prepare_stage() {
    [[ "$STAGING_ENABLED" == true && -z "$STAGE_DIR" ]] || return 0
    local tmp
    tmp=$(mktemp -d) || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    STAGE_DIR="$tmp/stage"
    overlay_stage_app "$APP_DIR" "$STAGE_DIR" /dev/null
}
```

In `cmd_install`: change `state_create "$APP_NAME" "$APP_VERSION" ...` to `state_create "$APP_NAME" "$(installed_version)" ...`. Replace the final `log_success ... return 0` with:

```bash
    if [[ $FILE_FAILURES -gt 0 ]]; then
        log_error "$APP_NAME installed with $FILE_FAILURES failed file(s)"
        return 1
    fi
    log_success "$APP_NAME installed successfully!"
    return 0
```

Make the same two changes in `cmd_upgrade`: use `state_set_version "$APP_NAME" "$(installed_version)"`, and finish with the same failure block using `upgraded` and `upgraded successfully!`.

Replace `cmd_diff`'s loop body with:

```bash
    for i in "${!CONFIG_FILES[@]}"; do
        local name="${CONFIG_FILES[$i]}"
        local src dest="${CONFIG_DESTS[$i]}"
        src=$(installer_src "$name")

        if [[ ! -f "$dest" ]]; then
            echo "File not installed: $dest"
            has_diff=true
            continue
        fi

        local want="$src" tmp=""
        if [[ "$(installer_strategy "$name")" == merge && -s "$dest" ]]; then
            tmp=$(mktemp)
            if overlay_json_merge "$tmp" "$dest" "$src"; then
                want="$tmp"
            fi
        fi

        echo "=== $(basename "$dest") ==="
        if diff -u "$dest" "$want" 2>/dev/null; then
            echo "No differences"
        else
            has_diff=true
        fi
        [[ -n "$tmp" ]] && rm -f "$tmp"
        echo
    done
```

In `parse_args`, add before `*)`:

```bash
            --stage)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --stage requires a directory argument" >&2
                    exit 1
                fi
                if [[ ! -f "$2/version" ]]; then
                    echo "Error: Not a staging directory: $2" >&2
                    exit 1
                fi
                STAGE_DIR=$(abs_path "$2")
                shift 2
                ;;
```

Add `  --stage DIR          Deploy files composed by setup.sh (internal)` to `usage` under `--force`.

In `execute_remote`, replace the code from `# Skip if remote is already at current version` to the start of `# Execute installer on remote` with:

```bash
    local app_name version
    app_name=$(basename "$APP_DIR")
    version=$(installer_version)

    # Skip if remote is already at current version
    remote_skip_if_current "$app_name" "$COMMAND" "$FORCE" "$version" && exit 0

    # Package installer (with the stage, if any)
    local package_file
    package_file=$(remote_package_installer "$APP_DIR" "$version" "$STAGE_DIR") || exit 1

    # Deploy to remote
    remote_deploy_installer "$package_file" || {
        rm -f "$package_file"
        exit 1
    }

    # Build remote arguments (drop --remote, --stage and app-specific local-only flags)
    local remote_args=()
    local skip_next=false

    for arg in "$@"; do
        if [[ "$skip_next" == true ]]; then
            skip_next=false
            continue
        fi

        if list_contains "$arg" --remote --stage "${APP_REMOTE_DROP_ARGS[@]}"; then
            skip_next=true
            continue
        fi

        remote_args+=("$arg")
    done

    if [[ -n "$STAGE_DIR" ]]; then
        remote_args+=(--stage "$REMOTE_TMP_DIR/$app_name/.stage")
    fi
```

Delete the now-duplicated `local app_name` / `app_name=$(basename "$APP_DIR")` lines further down in the same function.

In `installer_main`, after `log_init "$@"` and before the remote check:

```bash
    # Compose files to deploy (before --remote, so the stage ships with it)
    if command_needs_stage; then
        prepare_stage || exit 1
    fi
```

Replace the `# Set version from git hash` block (the `.version`/git `if`) with `APP_VERSION=$(installer_version)`.

In `packages/install.sh`, add `STAGING_ENABLED=false   # no config.yaml; drop-ins come from the profile` after `UPGRADE_ALWAYS=true`.

- [ ] **Step 5: Update `lib/remote.sh`**

Replace `remote_package_installer`:

```bash
# Package installer for remote deployment
# Usage: remote_package_installer app_dir version [stage_dir]
# The stage directory, if given, ships as <app>/.stage
remote_package_installer() {
    local app_dir="$1"
    local version="$2"
    local stage_dir="${3:-}"
    local app_name root_dir build package_file

    app_name=$(basename "$app_dir")
    root_dir=$(dirname "$app_dir")
    package_file="/tmp/${app_name}-installer-$(timestamp).tar.gz"

    log_info "Packaging installer: $app_name"

    build=$(mktemp -d) || return 1
    if ! cp -R "$app_dir" "$build/$app_name" || ! cp -R "$root_dir/lib" "$build/lib"; then
        rm -rf "$build"
        log_error "Failed to create package"
        return 1
    fi

    # Remote has no .git directory, so ship the version
    echo "$version" > "$build/$app_name/.version"

    if [[ -n "$stage_dir" ]] && ! cp -R "$stage_dir" "$build/$app_name/.stage"; then
        rm -rf "$build"
        log_error "Failed to add staged files to package"
        return 1
    fi

    if ! tar -czf "$package_file" -C "$build" "$app_name" lib 2>/dev/null; then
        rm -rf "$build"
        log_error "Failed to create package"
        return 1
    fi
    rm -rf "$build"

    log_debug "Package created: $package_file"
    echo "$package_file"
}
```

Replace `remote_skip_if_current`:

```bash
# Check if remote is already up to date, skip packaging if so
# Usage: remote_skip_if_current app_name command force local_version
# Returns 0 if remote is current and should be skipped, 1 otherwise
remote_skip_if_current() {
    local app_name="$1"
    local command="$2"
    local force="$3"
    local local_version="$4"

    if [[ "$command" != "deploy" && "$command" != "upgrade" ]] || [[ "$force" == true ]]; then
        return 1
    fi

    local remote_version
    remote_version=$(remote_get_version "$app_name")

    if [[ -n "$remote_version" && "$remote_version" == "$local_version" ]]; then
        log_info "$app_name is already up to date on remote ($local_version)"
        return 0
    fi

    return 1
}
```

In `test/run-remote-tests.sh` Test 2, change the packaging call to:

```bash
PACKAGE=$(source ../lib/logging.sh; source ../lib/utils.sh; source ../lib/remote.sh; remote_package_installer "$PWD" "$(git rev-parse --short HEAD)" 2>/dev/null)
```

- [ ] **Step 6: Run the tests**

Run: `cd test && bash apps/test-claude.sh`
Expected: "All 9 claude module tests passed!"
Run: `./run-core-tests.sh && ./run-app-tests.sh`
Expected: all pass. That includes core Test 29 (missing `files/.tmux.conf` → install fails, now during staging) and test-setup Test 20.

- [ ] **Step 7: Commit**

```bash
git add lib/installer.sh lib/remote.sh packages/install.sh claude/config.yaml test/apps/test-claude.sh test/apps/test-setup.sh test/run-remote-tests.sh
git commit -m "Stage files per app, merge JSON with strategy: merge, version by content"
```

---

### Task 5: setup.sh profile resolution across repos and host.yaml

**Files:**
- Modify: `setup.sh`
- Create: `test/fixtures/hosts-repo/...` (resolution part), `test/apps/test-hosts.sh`

**Interfaces:**
- Consumes: `hosts_resolve_profile_path`, `hosts_read_scalar`, `hosts_normalize_name`, `list_contains`.
- Produces (used by Task 6), as globals set by `load_packages_for_profile PROFILE_ARG HOSTNAME`:
  - `RESOLVED_PROFILE`: the profile name in use
  - `HOSTS_PROFILE_CHAIN`: hosts-repo profile names in the chain, base-most first
  - `HOST_YAML`: path to `host.yaml`, or empty
  - `HOSTS_REPO`: absolute path, or empty
  - `OVERLAY_HOST`: host name used for `hosts/<name>/`
- Log lines that tests rely on: `Using profile '<name>'`, `Packages: <space-separated names>`, `Host directory: hosts/<name>`

- [ ] **Step 1: Create the fixture hosts repo (resolution files)**

`test/fixtures/hosts-repo/profiles/minimal.yaml`:
```yaml
# Builds on dotfiles' minimal (extending its own name continues in dotfiles)
extends: minimal
exclude:
  - tree
```

`test/fixtures/hosts-repo/profiles/base.yaml`:
```yaml
# Config-only package list for overlay tests (no OS packages, no custom installs)
packages:
  - name: claude
    config:
      dir: claude
  - name: scripts
    config:
      dir: scripts

files:
  claude/settings.local.json: merge
```

`test/fixtures/hosts-repo/profiles/cycle-a.yaml`:
```yaml
extends: cycle-b
exclude:
  - tree
```

`test/fixtures/hosts-repo/profiles/cycle-b.yaml`:
```yaml
extends: cycle-a
exclude:
  - curl
```

`test/fixtures/hosts-repo/hosts/testhost/host.yaml`:
```yaml
profile: base
files:
  claude/settings.local.json: replace
```

`test/fixtures/hosts-repo/hosts/excludehost/host.yaml`:
```yaml
profile: base
exclude:
  - scripts
extra:
  - name: vim
    config:
      dir: vim
```

`test/fixtures/hosts-repo/hosts/noprofile/host.yaml`:
```yaml
# Missing profile: on purpose
exclude:
  - scripts
```

`test/fixtures/hosts-repo/hosts/nohostyaml/apps/claude/files/statusline-command.sh`:
```sh
# never applied: this host directory has no host.yaml
```

- [ ] **Step 2: Write the failing tests** `test/apps/test-hosts.sh`

```bash
#!/usr/bin/env bash
# test-hosts.sh - setup.sh with a dotfiles-hosts repo (resolution and overlays)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$TEST_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

echo "======================================"
echo "Hosts Repo Tests"
echo "======================================"
echo

unset DOTFILES_HOSTS_REPO
TEST_STATE="/tmp/dotfiles-test-hoststest"
TEST_HOME="/tmp/home-test-hoststest"
HR="/tmp/hosts-repo-hoststest"
rm -rf "$TEST_STATE" "$TEST_HOME" "$HR"
mkdir -p "$TEST_STATE/apps" "$TEST_HOME"
cp -R "$TEST_DIR/fixtures/hosts-repo" "$HR"
export STATE_DIR="$TEST_STATE"
export HOME="$TEST_HOME"
cd "$ROOT_DIR"

# Run setup.sh, capture output and exit code in OUT / RC
run() {
    RC=0
    OUT=$(./setup.sh "$@" 2>&1) || RC=$?
}
packages_line() { echo "$OUT" | grep -o 'Packages: .*' | head -1; }

# Test 1
info "Test 1: no hosts repo keeps today's resolution"
run deploy --dry-run --hostname testhost
[[ $RC -eq 0 ]] || fail "dry-run failed: $OUT"
[[ "$(packages_line)" == "Packages: git bash tmux vim curl fzf jq tree lazygit lazyssh scripts claude" ]] \
    || fail "package list changed: $(packages_line)"
[[ "$OUT" != *"Host directory"* ]] || fail "no host directory without hosts repo"
pass "unchanged without hosts repo"

# Test 2
info "Test 2: hosts-repo profile extending its own name continues in dotfiles"
run deploy --dry-run --hosts-repo "$HR" --hostname nohost --profile minimal
[[ $RC -eq 0 ]] || fail "dry-run failed: $OUT"
[[ "$(packages_line)" == "Packages: git bash tmux vim curl fzf jq scripts" ]] \
    || fail "expected dotfiles minimal minus tree: $(packages_line)"
pass "lookup order and self-extend"

# Test 3
info "Test 3: profile only in dotfiles is found"
run deploy --dry-run --hosts-repo "$HR" --hostname nohost --profile complete
[[ "$(packages_line)" == "Packages: git bash tmux vim curl fzf jq tree lazygit lazyssh scripts claude" ]] \
    || fail "fallback: $(packages_line)"
pass "dotfiles fallback"

# Test 4
info "Test 4: host directory selects profile"
run deploy --dry-run --hosts-repo "$HR" --hostname testhost
[[ "$OUT" == *"Using profile 'base'"* ]] || fail "host.yaml profile not used"
[[ "$OUT" == *"Host directory: hosts/testhost"* ]] || fail "host directory not reported"
[[ "$(packages_line)" == "Packages: claude scripts" ]] || fail "packages: $(packages_line)"
pass "host.yaml profile"

# Test 5
info "Test 5: --profile overrides host.yaml with a warning"
run deploy --dry-run --hosts-repo "$HR" --hostname testhost --profile minimal
[[ "$OUT" == *"overrides profile 'base'"* ]] || fail "no override warning"
[[ "$OUT" == *"Using profile 'minimal'"* ]] || fail "--profile did not win"
pass "--profile wins"

# Test 6
info "Test 6: host.yaml exclude and extra"
run deploy --dry-run --hosts-repo "$HR" --hostname excludehost
[[ "$(packages_line)" == "Packages: claude vim" ]] || fail "exclude/extra: $(packages_line)"
pass "host.yaml exclude/extra"

# Test 7
info "Test 7: env DOTFILES_HOSTS_REPO works like --hosts-repo"
OUT=$(DOTFILES_HOSTS_REPO="$HR" ./setup.sh deploy --dry-run --hostname testhost 2>&1) || fail "env run failed"
[[ "$(packages_line)" == "Packages: claude scripts" ]] || fail "env not honored"
pass "env hosts repo"

# Test 8
info "Test 8: missing hosts repo aborts before changes"
run deploy --hosts-repo /tmp/does-not-exist-hosts --hostname testhost
[[ $RC -ne 0 ]] || fail "should abort"
[[ ! -d "$HOME/.claude" ]] || fail "changes were made"
pass "missing hosts repo aborts"

# Test 9
info "Test 9: host.yaml without profile: aborts"
run deploy --dry-run --hosts-repo "$HR" --hostname noprofile
[[ $RC -ne 0 && "$OUT" == *"has no 'profile:'"* ]] || fail "should abort on missing profile:"
pass "missing profile: aborts"

# Test 10
info "Test 10: unknown profile aborts"
run deploy --dry-run --hosts-repo "$HR" --hostname nohost --profile nope
[[ $RC -ne 0 && "$OUT" == *"Profile not found"* ]] || fail "should abort on unknown profile"
pass "unknown profile aborts"

# Test 11
info "Test 11: extends cycle aborts"
run deploy --dry-run --hosts-repo "$HR" --hostname nohost --profile cycle-a
[[ $RC -ne 0 && "$OUT" == *"extends cycle"* ]] || fail "cycle not detected: $(echo "$OUT" | tail -3)"
pass "cycle detected"

# Test 12
info "Test 12: host directory without host.yaml is ignored with a warning"
run deploy --dry-run --hosts-repo "$HR" --hostname nohostyaml --profile base
[[ $RC -eq 0 && "$OUT" == *"no host.yaml"* ]] || fail "no warning for hosts/nohostyaml"
[[ "$OUT" != *"Host directory"* ]] || fail "directory without host.yaml was used"
pass "host dir without host.yaml ignored"

# Test 13
info "Test 13: --hostname with --hosts-file is rejected"
run deploy --hosts-file /tmp/x.yaml --hostname a
[[ $RC -ne 0 ]] || fail "should reject --hostname with --hosts-file"
pass "--hostname/--hosts-file exclusive"

# (Task 6 adds overlay tests here)

rm -rf "$TEST_STATE" "$TEST_HOME" "$HR"
echo
echo "======================================"
echo -e "${GREEN}All hosts repo tests passed!${NC}"
echo "======================================"
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd test && bash apps/test-hosts.sh`
Expected: FAIL at Test 1 (`--hostname` is an unknown option).

- [ ] **Step 4: Implement resolution in `setup.sh`**

Source the new libs after `remote.sh`:

```bash
source "$SCRIPT_DIR/lib/hosts.sh"
source "$SCRIPT_DIR/lib/overlay.sh"
```

Add globals after `PROFILE_ARG=""`:

```bash
HOSTS_REPO="${DOTFILES_HOSTS_REPO:-}"
HOSTNAME_ARG=""

# Resolution results (set by load_packages_for_profile)
RESOLVED_PROFILE=""
declare -a HOSTS_PROFILE_CHAIN=()   # hosts-repo profiles in the chain, base-most first
HOST_YAML=""
OVERLAY_HOST=""
```

Replace `resolve_profile_path`:

```bash
# Resolve profile name to file path (hosts repo first unless skip_hosts)
# Usage: resolve_profile_path name [skip_hosts]
resolve_profile_path() {
    hosts_resolve_profile_path "$PROFILES_DIR" "$HOSTS_REPO" "$1" "${2:-false}"
}
```

Split `load_profile`. Its exclude/include/extra part becomes `apply_profile_modifiers FILE LABEL`, which can be applied to a profile or to `host.yaml`. Take the current lines 235–381 verbatim: from `# Parse exclude/include lists` through the final `No packages remaining` check. Wrap them in the function below and rename `$profile_path` → `$file` and `$name` → `$label`. Delete the `load_profile "$extends_name" || return 1` line from that block. Move the `extra:` detection in:

```bash
# Apply exclude/include/extra from a profile or host.yaml to PKG_* arrays
# Usage: apply_profile_modifiers file label
apply_profile_modifiers() {
    local file="$1" label="$2"
    local -a exclude_list=()
    local -a include_list=()
    local has_extra=false
    grep -q '^extra:' "$file" && has_extra=true

    # ... lines 235-264 (parse exclude/include), with $profile_path -> $file
    # ... lines 269-381 (apply exclude, include, extra, empty check), with
    #     $profile_path -> $file and $name -> $label
}
```

Then `load_profile` becomes:

```bash
# Load packages from a profile file into PKG_* arrays
# Handles 'extends', 'exclude'/'include', and 'extra' directives.
# A hosts-repo profile that extends its own name continues the lookup in dotfiles.
# Usage: load_profile name [skip_hosts] [depth]
load_profile() {
    local name="$1" skip_hosts="${2:-false}" depth="${3:-0}"

    if [[ $depth -gt 10 ]]; then
        log_error "Profile chain too deep at '$name' (extends cycle?)"
        return 1
    fi

    local profile_path
    profile_path=$(resolve_profile_path "$name" "$skip_hosts")

    if [[ ! -f "$profile_path" ]]; then
        log_error "Profile not found: $profile_path"
        return 1
    fi

    local from_hosts=false
    if [[ -n "$HOSTS_REPO" && "$profile_path" == "$HOSTS_REPO/profiles/"* ]]; then
        from_hosts=true
    fi

    local extends_name=""
    local has_packages=false
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^extends:[[:space:]]*(.*) ]]; then
            extends_name="${BASH_REMATCH[1]}"
            extends_name=$(echo "$extends_name" | sed 's/[[:space:]]*$//')
        elif [[ "$line" =~ ^packages: ]]; then
            has_packages=true
        fi
    done < "$profile_path"

    if [[ "$has_packages" == true ]]; then
        # Form 1: full package list
        load_manifest "$profile_path" || return 1
    else
        if [[ -z "$extends_name" ]]; then
            log_error "Profile '$name' has no 'packages:' list and no 'extends:' directive"
            return 1
        fi
        local parent_skip=false
        if [[ "$from_hosts" == true && "$extends_name" == "$name" ]]; then
            parent_skip=true
        fi
        load_profile "$extends_name" "$parent_skip" $((depth + 1)) || return 1
        apply_profile_modifiers "$profile_path" "$name" || return 1
    fi

    if [[ "$from_hosts" == true ]]; then
        HOSTS_PROFILE_CHAIN+=("$name")
    fi
    log_debug "Profile '$name': ${#PKG_NAMES[@]} package(s) after filtering"
    return 0
}
```

Replace `load_packages_for_profile`:

```bash
# Resolve host and profile, load packages into PKG_* arrays
# Usage: load_packages_for_profile profile_arg hostname
#   profile_arg: explicit profile ("" = not given)
# Sets RESOLVED_PROFILE, HOSTS_PROFILE_CHAIN, HOST_YAML
load_packages_for_profile() {
    local profile_arg="$1" hostname="$2"

    reset_pkg_arrays
    HOSTS_PROFILE_CHAIN=()
    HOST_YAML=""

    if [[ ! -d "$PROFILES_DIR" ]]; then
        log_error "No profiles directory found: $PROFILES_DIR"
        return 1
    fi

    if [[ -n "$HOSTS_REPO" ]]; then
        local host_dir="$HOSTS_REPO/hosts/$hostname"
        if [[ -f "$host_dir/host.yaml" ]]; then
            HOST_YAML="$host_dir/host.yaml"
        elif [[ -d "$host_dir" ]]; then
            log_warn "Ignoring hosts/$hostname/: no host.yaml"
        fi
    fi

    if [[ -z "$HOST_YAML" ]]; then
        RESOLVED_PROFILE="${profile_arg:-complete}"
        load_profile "$RESOLVED_PROFILE"
        return
    fi

    local host_profile
    host_profile=$(hosts_read_scalar "$HOST_YAML" profile)
    if [[ -z "$host_profile" ]]; then
        log_error "$HOST_YAML has no 'profile:'"
        return 1
    fi

    RESOLVED_PROFILE="$host_profile"
    if [[ -n "$profile_arg" ]]; then
        log_warn "Explicit profile '$profile_arg' overrides profile '$host_profile' from hosts/$hostname/host.yaml"
        RESOLVED_PROFILE="$profile_arg"
    fi

    load_profile "$RESOLVED_PROFILE" || return 1
    apply_profile_modifiers "$HOST_YAML" "host $hostname"
}
```

In `load_hosts`, make the default profile empty so an explicit `profile:` can be told apart. Change both `current_profile="complete"` assignments and the initial `local current_profile="complete"` to `""`, and update the comment to `# Outputs lines of "host|profile" (profile empty when not given)`.

Replace the start of `run_all`, up to and including the `log_info "[$target] Using profile ..."` line:

```bash
run_all() {
    local host="${1:-}"
    local profile="${2:-}"
    local target="${host:-local}"

    if [[ -n "$HOSTNAME_ARG" ]]; then
        OVERLAY_HOST="$HOSTNAME_ARG"
    elif [[ -n "$host" ]]; then
        OVERLAY_HOST=$(hosts_normalize_name "$host")
    else
        OVERLAY_HOST=$(hostname -s)
    fi

    # Load profile-specific package list
    load_packages_for_profile "$profile" "$OVERLAY_HOST" || return 1
    log_info "[$target] Using profile '$RESOLVED_PROFILE' (${#PKG_NAMES[@]} package(s))"
    if [[ -n "$HOST_YAML" ]]; then
        log_info "[$target] Host directory: hosts/$OVERLAY_HOST"
    fi
    log_info "[$target] Packages: ${PKG_NAMES[*]}"
```

In `main`, change `local profile="${PROFILE_ARG:-complete}"` (both places) to `local profile="$PROFILE_ARG"`. Insert before `# Determine execution mode`:

```bash
    # Validate hosts repo before any changes
    if [[ -n "$HOSTS_REPO" ]]; then
        if [[ ! -d "$HOSTS_REPO" ]]; then
            log_error "Hosts repo not found or not a directory: $HOSTS_REPO"
            exit 1
        fi
        HOSTS_REPO="$(cd "$HOSTS_REPO" && pwd)"
    fi
```

In `parse_args`, add:

```bash
            --hosts-repo)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --hosts-repo requires a path argument" >&2
                    exit 1
                fi
                HOSTS_REPO="$2"
                shift 2
                ;;
            --hostname)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --hostname requires a name argument" >&2
                    exit 1
                fi
                HOSTNAME_ARG="$2"
                shift 2
                ;;
```

After the `while` loop in `parse_args`:

```bash
    if [[ -n "$HOSTNAME_ARG" && -n "$HOSTS_FILE" ]]; then
        echo "Error: --hostname and --hosts-file are mutually exclusive" >&2
        exit 1
    fi
```

In `usage`, add after the Profile options block:

```
Hosts repo options:
  --hosts-repo PATH    dotfiles-hosts checkout (default: env DOTFILES_HOSTS_REPO)
                       Profiles are looked up there first, then in profiles/
  --hostname NAME      Host directory hosts/NAME/ to apply (default: hostname -s;
                       with --host, the host without user@ and domain)
```

In the Profile options block, change `Ignored when using --hosts-file` to `With --hosts-file, a host entry's profile: acts like --profile`.

- [ ] **Step 5: Run the tests**

Run: `cd test && bash apps/test-hosts.sh`
Expected: "All hosts repo tests passed!"
Run: `./run-app-tests.sh`
Expected: all pass (test-setup unchanged).

- [ ] **Step 6: Commit**

```bash
git add setup.sh test/apps/test-hosts.sh test/fixtures/hosts-repo
git commit -m "Resolve profiles across dotfiles-hosts and dotfiles; add host.yaml"
```

---

### Task 6: setup.sh validates and stages overlays; per-file failures in the summary

**Files:**
- Modify: `setup.sh`, `test/apps/test-hosts.sh`
- Create: fixture overlay files

**Interfaces:**
- Consumes: Task 5 globals; `overlay_validate_app`, `overlay_stage_app`, `hosts_parse_files_map`; installer `--stage` and `DOTFILES_FAILURES_FILE` (Task 4).
- Produces: globals `WORK_DIR` (per run, removed on exit), `STAGE_ROOT`, `STRATEGIES_FILE`, `LAYER_ROOTS[]`, and the summary items `<app>/<src>` for failed files.

- [ ] **Step 1: Add the fixture overlay files**

`test/fixtures/hosts-repo/profiles/base/apps/claude/files/settings.json`:
```json
{
  "model": "profile-model",
  "profileKey": true,
  "permissions": { "defaultMode": "plan" },
  "list": [1, 2]
}
```
`test/fixtures/hosts-repo/profiles/base/apps/claude/files/statusline-command.sh`:
```sh
# profile statusline
```
`test/fixtures/hosts-repo/profiles/base/apps/claude/files/tmux-notify.sh`:
```sh
# profile notify
```
`test/fixtures/hosts-repo/hosts/testhost/apps/claude/files/settings.json`:
```json
{ "hostKey": "testhost", "permissions": { "allow": ["Bash(ls)"] }, "list": [9] }
```
`test/fixtures/hosts-repo/hosts/testhost/apps/claude/files/statusline-command.sh`:
```sh
# host statusline
```
`test/fixtures/hosts-repo/hosts/mergelocal/host.yaml`:
```yaml
profile: base
```
`test/fixtures/hosts-repo/hosts/excludehost/apps/scripts/files/extract`:
```sh
# overlay for an app this host excludes
```
`test/fixtures/hosts-repo/hosts/typo/host.yaml`:
```yaml
profile: base
```
`test/fixtures/hosts-repo/hosts/typo/apps/claude/files/setings.json`:
```json
{}
```
`test/fixtures/hosts-repo/hosts/mergetxt/host.yaml`:
```yaml
profile: base
files:
  claude/statusline-command.sh: merge
```
`test/fixtures/hosts-repo/hosts/badjson/host.yaml`:
```yaml
profile: base
```
`test/fixtures/hosts-repo/hosts/badjson/apps/claude/files/settings.json`:
```
{ "broken":
```

- [ ] **Step 2: Add the failing overlay tests** to `test/apps/test-hosts.sh`, replacing the `# (Task 6 adds overlay tests here)` line:

```bash
CL="$HOME/.claude"
seed_settings() {
    mkdir -p "$CL"
    echo '{"model":"live-model","liveOnly":1,"list":[0],"permissions":{"deny":["Bash(rm)"]}}' > "$CL/settings.json"
    echo '{"permissions":{"allow":["Live"]},"liveLocal":1}' > "$CL/settings.local.json"
}

# Test 14
info "Test 14: unknown overlay src aborts before changes"
run deploy --no-backup --hosts-repo "$HR" --hostname typo
[[ $RC -ne 0 && "$OUT" == *"setings.json"* ]] || fail "typo overlay not rejected"
[[ ! -d "$CL" ]] || fail "changes were made"
pass "typo overlay aborts"

# Test 15
info "Test 15: merge on a non-JSON file aborts before changes"
run deploy --no-backup --hosts-repo "$HR" --hostname mergetxt
[[ $RC -ne 0 && "$OUT" == *"requires a .json file"* ]] || fail "merge on .sh not rejected"
[[ ! -d "$CL" ]] || fail "changes were made"
pass "merge on non-JSON aborts"

# Test 16
info "Test 16: overlays for an excluded app warn and are ignored"
run deploy --dry-run --hosts-repo "$HR" --hostname excludehost
[[ $RC -eq 0 && "$OUT" == *"Ignoring overlays for 'scripts'"* ]] || fail "no warning for excluded app overlay"
pass "excluded-app overlay warned"

# Test 17
info "Test 17: three-layer replace and merge with live file"
seed_settings
run deploy --no-backup --hosts-repo "$HR" --hostname testhost
[[ $RC -eq 0 ]] || fail "deploy failed: $(echo "$OUT" | tail -20)"
[[ "$(cat "$CL/statusline-command.sh")" == "# host statusline" ]] || fail "host layer should win"
[[ "$(cat "$CL/tmux-notify.sh")" == "# profile notify" ]] || fail "profile layer should win over dotfiles"
S="$CL/settings.json"
[[ "$(jq -r .model "$S")" == profile-model ]] || fail "repo key should override live"
[[ "$(jq -r .liveOnly "$S")" == 1 ]] || fail "unmanaged live key lost"
[[ "$(jq -r .profileKey "$S")" == true ]] || fail "profile key missing"
[[ "$(jq -r .hostKey "$S")" == testhost ]] || fail "host key missing"
[[ "$(jq -c .list "$S")" == "[9]" ]] || fail "arrays should be replaced: $(jq -c .list "$S")"
[[ "$(jq -c -S .permissions "$S")" == '{"allow":["Bash(ls)"],"defaultMode":"plan","deny":["Bash(rm)"]}' ]] \
    || fail "objects should merge recursively: $(jq -c -S .permissions "$S")"
[[ "$(jq -r .statusLine.type "$S")" == command ]] || fail "dotfiles key missing"
cmp -s "$CL/settings.local.json" "$ROOT_DIR/claude/files/settings.local.json" \
    || fail "host.yaml replace should override the profile's merge for settings.local.json"
pass "layers and merge correct"

# Test 18
info "Test 18: unchanged inputs skip; a hosts-repo change upgrades only that app"
run deploy --no-backup --hosts-repo "$HR" --hostname testhost
[[ "$OUT" == *"claude is already up to date"* ]] || fail "claude should be up to date"
echo "# host statusline v2" > "$HR/hosts/testhost/apps/claude/files/statusline-command.sh"
run deploy --no-backup --hosts-repo "$HR" --hostname testhost
[[ "$OUT" == *"claude upgraded successfully"* ]] || fail "hosts-repo change should upgrade claude"
[[ "$OUT" == *"scripts is already up to date"* ]] || fail "scripts should be untouched"
[[ "$(cat "$CL/statusline-command.sh")" == "# host statusline v2" ]] || fail "new overlay not deployed"
pass "content-hash upgrades"

# Test 19
info "Test 19: profile files: strategy applies when the host doesn't override it"
echo '{"liveLocal":1}' > "$CL/settings.local.json"
run deploy --no-backup --hosts-repo "$HR" --hostname mergelocal
[[ $RC -eq 0 ]] || fail "deploy failed"
[[ "$(jq -r .liveLocal "$CL/settings.local.json")" == 1 ]] || fail "profile merge strategy not applied"
pass "profile strategy"

# Test 20
info "Test 20: invalid JSON in a layer fails that file only, reported in summary"
seed_settings
cp "$CL/settings.json" "$HOME/settings.before"
run deploy --no-backup --hosts-repo "$HR" --hostname badjson
[[ $RC -ne 0 ]] || fail "deploy should report failure"
[[ "$OUT" == *"claude/settings.json: deploy FAILED"* ]] || fail "summary should name the file"
cmp -s "$CL/settings.json" "$HOME/settings.before" || fail "live settings.json modified"
[[ "$(cat "$CL/statusline-command.sh")" == "# profile statusline" ]] || fail "other claude files should deploy"
[[ "$(grep '^  version:' "$STATE_DIR/apps/claude.yaml" | awk '{print $2}')" == incomplete ]] \
    || fail "claude version should be incomplete"
pass "bad layer isolated"
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd test && bash apps/test-hosts.sh`
Expected: Tests 1–13 pass, then FAIL at Test 14 (typo overlay not rejected).

- [ ] **Step 4: Implement overlays in `setup.sh`**

Add globals after `OVERLAY_HOST=""`:

```bash
# Overlay staging (per run_all)
WORK_DIR=""
STAGE_ROOT=""
STRATEGIES_FILE=""
declare -a LAYER_ROOTS=()
```

Add after `load_packages_for_profile`:

```bash
# Collect layer roots and the strategies file, then validate every app's
# overlays. Runs before any change; returns 1 to abort.
# Usage: prepare_overlays target
prepare_overlays() {
    local target="$1"
    STAGE_ROOT="$WORK_DIR/$target"
    STRATEGIES_FILE="$STAGE_ROOT/strategies"
    LAYER_ROOTS=()
    mkdir -p "$STAGE_ROOT" || return 1
    : > "$STRATEGIES_FILE"

    local p
    for p in "${HOSTS_PROFILE_CHAIN[@]}"; do
        LAYER_ROOTS+=("$HOSTS_REPO/profiles/$p")
        hosts_parse_files_map "$HOSTS_REPO/profiles/$p.yaml" >> "$STRATEGIES_FILE" || return 1
    done
    if [[ -n "$HOST_YAML" ]]; then
        LAYER_ROOTS+=("$(dirname "$HOST_YAML")")
        hosts_parse_files_map "$HOST_YAML" >> "$STRATEGIES_FILE" || return 1
    fi

    local -a dirs=()
    local idx
    for idx in "${!PKG_NAMES[@]}"; do
        [[ -n "${PKG_CONFIG_DIR[$idx]}" ]] && dirs+=("${PKG_CONFIG_DIR[$idx]}")
    done

    local root app_path app
    for root in "${LAYER_ROOTS[@]}"; do
        [[ -d "$root/apps" ]] || continue
        for app_path in "$root"/apps/*/; do
            [[ -d "$app_path" ]] || continue
            app=$(basename "$app_path")
            if ! list_contains "$app" "${dirs[@]}"; then
                log_warn "[$target] Ignoring overlays for '$app' in ${root#"$HOSTS_REPO"/}: not in the package list"
            fi
        done
    done

    local key strategy
    while read -r key strategy; do
        app="${key%%/*}"
        if ! list_contains "$app" "${dirs[@]}"; then
            log_warn "[$target] Ignoring files: entry '$key': '$app' not in the package list"
        fi
    done < "$STRATEGIES_FILE"

    local dir ok=0
    for dir in "${dirs[@]}"; do
        [[ -f "$SCRIPT_DIR/$dir/config.yaml" ]] || continue
        overlay_validate_app "$SCRIPT_DIR/$dir" "$STRATEGIES_FILE" "${LAYER_ROOTS[@]}" || ok=1
    done
    return $ok
}
```

In `run_all`, right after the `Packages:` log line:

```bash
    # Validate overlays before any change
    if ! prepare_overlays "$target"; then
        log_error "[$target] Invalid overlay configuration; no changes made"
        return 1
    fi
```

In `run_phase_configs`, after the `if [[ ! -f "$installer" ]]` block:

```bash
        # Compose this app's files from all layers
        local -a stage_args=()
        if [[ -f "$SCRIPT_DIR/$dir/config.yaml" ]]; then
            local stage="$STAGE_ROOT/apps/$dir"
            if ! overlay_stage_app "$SCRIPT_DIR/$dir" "$stage" "$STRATEGIES_FILE" "${LAYER_ROOTS[@]}"; then
                log_error "[$target] $name: could not stage files"
                RESULTS+=("$target|$name|FAIL")
                EXIT_CODE=1
                continue
            fi
            stage_args=(--stage "$stage")
        fi
```

Add `cmd_args+=("${stage_args[@]}")` right after the `--remote` block. Replace the `if bash "$installer" ...; then ... fi` block with:

```bash
        export DOTFILES_FAILURES_FILE="$STAGE_ROOT/failures"
        : > "$DOTFILES_FAILURES_FILE"

        if bash "$installer" "${cmd_args[@]}"; then
            RESULTS+=("$target|$name|ok")
        else
            log_error "[$target] $name: $COMMAND failed"
            RESULTS+=("$target|$name|FAIL")
            EXIT_CODE=1
        fi

        # Per-file failures reported by the installer
        local failed
        while IFS= read -r failed; do
            [[ -n "$failed" ]] && RESULTS+=("$target|$failed|FAIL")
        done < "$DOTFILES_FAILURES_FILE"
```

In `main`, right after `log_init "$@"`:

```bash
    WORK_DIR=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$WORK_DIR'" EXIT
```

- [ ] **Step 5: Run the tests**

Run: `cd test && bash apps/test-hosts.sh`
Expected: "All hosts repo tests passed!"
Run: `./run-core-tests.sh && ./run-app-tests.sh`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add setup.sh test/apps/test-hosts.sh test/fixtures/hosts-repo
git commit -m "Validate and stage host/profile overlays in setup.sh; report failed files"
```

---

### Task 7: Remote overlay deploy test and docs

**Files:**
- Modify: `test/docker/Dockerfile`, `test/run-remote-tests.sh`, `docs/schema.md`

**Interfaces:**
- Consumes: `overlay_stage_app`, `remote_package_installer APP_DIR VERSION STAGE_DIR`, installer `--stage`.

- [ ] **Step 1: Add jq to the test image**

In `test/docker/Dockerfile`, add `jq \` to the `apt-get install -y` list after `tmux \`.

- [ ] **Step 2: Add the remote overlay test** to `test/run-remote-tests.sh`, before `# Cleanup`:

```bash
# Test 14: Overlays staged on the workstation ship with the app and merge remotely
info "Test 14: Remote deploy with staged overlays"
cd "$ROOT_DIR"
STAGE_TMP=$(mktemp -d)
PKG14=$(
    source lib/logging.sh; source lib/utils.sh; source lib/remote.sh; source lib/overlay.sh
    : > "$STAGE_TMP/strategies"
    overlay_stage_app "$ROOT_DIR/claude" "$STAGE_TMP/stage" "$STAGE_TMP/strategies" \
        "$SCRIPT_DIR/fixtures/hosts-repo/profiles/base" \
        "$SCRIPT_DIR/fixtures/hosts-repo/hosts/testhost" >/dev/null 2>&1
    remote_package_installer "$ROOT_DIR/claude" "$(cat "$STAGE_TMP/stage/version")" "$STAGE_TMP/stage" 2>/dev/null
)
scp $SSH_OPTS -i "$SSH_KEY" -P "$SSH_PORT" "$PKG14" "$SSH_USER@$SSH_HOST:/tmp/" &>/dev/null || { fail "copy failed"; exit 1; }
test_ssh "rm -rf /tmp/claude ~/.claude ~/.config/dotfiles/apps/claude.yaml; mkdir -p ~/.claude && echo '{\"liveOnly\":1}' > ~/.claude/settings.json && cd /tmp && tar -xzf $(basename "$PKG14")" &>/dev/null
if test_ssh "cd /tmp/claude && bash install.sh deploy --no-backup --stage /tmp/claude/.stage" &>/dev/null \
   && [[ "$(test_ssh "jq -r .liveOnly ~/.claude/settings.json")" == 1 ]] \
   && [[ "$(test_ssh "jq -r .hostKey ~/.claude/settings.json")" == testhost ]] \
   && [[ "$(test_ssh "cat ~/.claude/statusline-command.sh")" == "# host statusline" ]]; then
    pass "Remote overlay deploy merged and replaced correctly"
else
    fail "Remote overlay deploy failed"
    exit 1
fi
rm -rf "$STAGE_TMP" "$PKG14"
test_ssh "rm -rf /tmp/claude /tmp/claude-installer-* ~/.claude" &>/dev/null || true
cd "$SCRIPT_DIR"
```

Change the final banner to `All 14 remote tests passed!`.

- [ ] **Step 3: Run the remote tests**

Run: `cd test && make rebuild && make setup && ./run-remote-tests.sh`
Expected: "All 14 remote tests passed!"

- [ ] **Step 4: Update `docs/schema.md`**

In the App Config **Files** table, add a row:

```markdown
| `files[].strategy` | string | No | `replace` | `replace` copies the file over the live one. `merge` (JSON only) deep-merges into the live file with jq `*`: objects merge recursively, arrays and scalars are replaced, keys only in the live file are kept. Can be overridden per host (see Hosts Repo). |
```

Append a new section at the end:

```markdown
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
Strategy: last declaration among the app `config.yaml`, the hosts-repo profile `files:` maps (base-most first), and `host.yaml` `files:`.

### Errors

The run aborts before any change if the hosts repo is missing, `host.yaml` lacks `profile:`, a profile isn't found, the `extends` chain cycles, an overlay file or `files:` key names an unknown `src`, or `merge` is set on a non-`.json` file. Overlays for apps not in the package list are ignored with a warning. Invalid JSON during a merge fails only that file, leaves the live file untouched, and is reported in the summary. The app's version is then recorded as `incomplete`, so the next run retries.

### Removing managed keys

`merge` never deletes keys from the live file. To remove a key, delete it from the repo layer and from the live file by hand.
```

In the Hosts Schema (`hosts.yaml`) table, change the `hosts[].profile` description to `Profile for this host. Overrides hosts/<name>/host.yaml's profile (with a warning) when a hosts repo is used.`

- [ ] **Step 5: Final full verification**

Run: `cd test && ./run-core-tests.sh && ./run-app-tests.sh && ./run-remote-tests.sh`
Expected: all three report all tests passed.
Run: `git status --short`
Expected: only `claude/files/settings.json` (user WIP) and the untracked `docs/` items remain unstaged.

- [ ] **Step 6: Commit**

```bash
git add test/docker/Dockerfile test/run-remote-tests.sh docs/schema.md
git commit -m "Test remote deploys with overlays; document hosts repo and merge strategy"
```
