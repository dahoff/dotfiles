# dotfiles sync revisions (sub-project 2 follow-up) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the decisions the user made after reviewing sub-project 2:
- The config file becomes YAML.
- The `dotfiles_repo` setting is dropped.
- `hosts_repo` is renamed `hosts_dir` everywhere.
- Packages that need sudo get a reminder at every terminal until they're installed.
- A background sync installs packages itself when sudo needs no password.
- A custom tool's shell drop-in is deployed only once the tool is installed.

**Architecture:** These are changes to existing code on branch `dotfiles-sync-init`:
- `lib/config.sh` changes parser.
- `dotfiles`, `lib/sync.sh`, `lib/login.sh` and `lib/push.sh` change behavior.
- Tests, `docs/schema.md` and the sub-project 2 spec follow.

There are no new modules.

**Tech Stack:** Bash 4+, POSIX sh (the remote snippet runs under dash), the existing test harness, and Docker for push.

**Spec:** `docs/superpowers/specs/2026-10-01-dotfiles-sync-push-design.md`. Its "Revisions (2026-10-02)" section is binding and overrides earlier text.

## Global Constraints

- **Config file location:** `${DOTFILES_CONFIG:-$HOME/.config/dotfiles/config.yaml}`.
- **Config file format:** a flat YAML mapping of `key: value` lines.
  - Comments: a full-line `#`, or a trailing ` #…` when the value is unquoted.
  - Blank lines are ignored, CRLF is tolerated, and one pair of matching quotes is stripped.
  - A leading `~` is expanded.
  - Indented lines or list items (`- x`) produce a warning and are ignored.
  - Keys: `hosts_dir`, `hostname`, `profile`, `auto_sync`, `auto_sync_interval`. Any other key produces a warning naming `file:line`.
  - `auto_sync` accepts `on`/`off`, and also `true`/`false`/`yes`/`no`, normalized to `on`/`off`.
  - `auto_sync_interval` is `<n>m|h|d`. `hostname` follows the `--hostname` rules.
- **Hosts directory naming:** user-facing names are `hosts_dir`, `--hosts-dir`, env `DOTFILES_HOSTS_DIR`, status label `hosts dir:`, and errors such as `Hosts dir not found or not a directory: <path>`. Internal variables are renamed to match (`HOSTS_DIR`, `CFG_HOSTS_DIR`).
  - No `hosts_repo`, `--hosts-repo` or `DOTFILES_HOSTS_REPO` may remain anywhere except under `docs/superpowers/`, which is history.
  - The default directory is `~/.local/share/dotfiles/dotfiles-hosts`.
- **No `dotfiles_repo` setting.** The dotfiles repo is always the checkout the running `dotfiles` script lives in.
- **Self-install link:** `~/.local/bin/dotfiles` is created only if it is missing or dangling. A valid link to another checkout is left alone with a warning, and so is a non-symlink file. The `90-dotfiles.sh` drop-in is copied from the repo the link resolves to.
- **Pending reminder:** the drop-in prints exactly `dotfiles: <a, b> not installed (needs sudo) — run 'dotfiles sync'` at every interactive terminal while `<state>/pending` is non-empty. The one-time report no longer contains a pending line.
- **Background installs:** `sync --auto` runs phases 1 and 2 for real only when `sudo -n true` succeeds (stdin `</dev/null`, fd 9 closed). Otherwise they run in check-only mode, as today.
- **Custom tool drop-ins:** a custom entry's drop-in is deployed only when its `check` passes after the install step, or when the entry has no `check`. It applies to both interactive and `--auto` runs. Existing copies are never removed.
- **Tests:** never touch the real HOME. Set HOME, XDG_STATE_HOME, STATE_DIR and DOTFILES_CONFIG to temp paths, and unset DOTFILES_HOSTS_DIR.
- **Docker:** use a shim at `/tmp/dcshim/docker-compose` (`exec docker compose "$@"`), never one in `~/.local/bin`. Run `chmod 600 test/ssh-key`. Clean up with `test/cleanup-test-env.sh`, not `--full`.
- **Commits:** `git add <explicit paths>`. NEVER add a Co-Authored-By or any Claude attribution trailer.
- **Done means:** `cd test && ./run-core-tests.sh && ./run-app-tests.sh` passes at the end of every task, and `./run-remote-tests.sh` passes in R2 and R3.
- **Where to work:** only in `/home/david/git/dotfiles/.claude/worktrees/sync-init`.

## Review Focus

1. **A YAML config with a value containing `: `**, such as `profile: a: b`, or a `#` inside quotes (`hostname: "a#b"`, which is invalid for other reasons). Only the first `: ` splits key from value, and `#` inside quotes is not a comment. Tested in R1.
2. **A user who ran `./dotfiles sync` from a worktree.** `~/.local/bin/dotfiles` keeps pointing at the original checkout, and a warning is printed. Tested in R1.
3. **`sudo -n true` prompting or hanging** on systems with odd sudo configs. It must run with `</dev/null` and must not hang. Tested in R3 with a fake `sudo` that would block on stdin.
4. **Two parsers drifting apart.** The remote snippet must parse `hosts_dir` exactly like `config_load`, including CRLF, comments, quotes and `~`. Tested in R2 with a local dash unit test plus Docker.

---

### Task R1: YAML config, drop `dotfiles_repo`, rename to `hosts_dir`, self-install link rule

**Files:**
- `lib/config.sh`
- `dotfiles` (`resolve_settings`, flags, usage, status labels, errors, self-install call)
- `lib/sync.sh` (`sync_self_install`)
- `lib/profile.sh` and any other user of `HOSTS_REPO`
- every test that writes a config or uses `--hosts-repo` / `DOTFILES_HOSTS_REPO`: `test-config.sh`, `test-sync.sh`, `test-status.sh`, `test-hosts.sh`, `test-setup.sh`, `test-claude.sh`, `test-push.sh`, `run-app-tests.sh` and `run-core-tests.sh`
- `docs/schema.md`

**Interfaces:**
- `config_load FILE` sets `CFG_HOSTS_DIR`, `CFG_HOSTNAME`, `CFG_PROFILE`, `CFG_AUTO_SYNC` and `CFG_AUTO_SYNC_INTERVAL`, with the same return codes as today. `CFG_DOTFILES_REPO` and `CFG_HOSTS_REPO` are removed.
- `sync_self_install REPO SHELL_SCRIPTS_DIR` implements the link rule from the Global Constraints. When it skips re-linking it warns:

  ```
  ~/.local/bin/dotfiles points at <X>; leaving it (remove the link to switch to <REPO>)
  ```

- `resolve_settings`:
  - `HOSTS_DIR` is resolved as flag > env `DOTFILES_HOSTS_DIR` > config > default dir if it exists > empty.
  - The `dotfiles_repo` mismatch warning is removed.

- [ ] **Step 1: Update the tests first.**
  - **YAML unit cases** in `test-config.sh`:
    - basic keys
    - CRLF
    - quoted values
    - a trailing comment
    - `#` inside quotes kept
    - a value containing `: ` kept whole
    - `auto_sync: yes` normalized to `on`
    - an indented line and a list item each warn
    - unknown keys `dotfiles_repo` and `hosts_repo` each warn (they are no longer valid keys)
    - `~` expansion
  - **Integration cases** move to `config.yaml`, `hosts_dir` and `--hosts-dir`.
  - **Self-install cases** in `test-sync.sh`:
    - (a) no link: it is created
    - (b) a valid link to checkout A while running from B: the link is unchanged and the output contains `leaving it`
    - (c) a dangling link: it is re-created to the running checkout
    - (d) a regular file at the path: left untouched, with a warning
- [ ] **Step 2:** Run `bash test/apps/test-config.sh`. It should fail.
- [ ] **Step 3: Implement.**
  - Rename the config keys and `HOSTS_REPO` throughout. Use `grep -rn 'hosts_repo\|hosts-repo\|HOSTS_REPO\|dotfiles_repo\|DOTFILES_REPO_CFG\|CFG_DOTFILES_REPO'`.
  - Leave `DOTFILES_REPO`, the internal running-repo variable, as it is.
  - Update `docs/schema.md`: the config section shows a YAML example and lists `hosts_dir`, and every flag and env var mention is updated.
- [ ] **Step 4:** Run the full local suites. They should pass. Then run `grep -rn 'hosts_repo\|hosts-repo\|HOSTS_REPO\|dotfiles_repo' --include=*.sh --include=*.md . dotfiles | grep -v docs/superpowers`. It should print nothing, apart from `lib/push.sh`, which R2 handles.
- [ ] **Step 5:** Commit: "Config becomes YAML (config.yaml); drop dotfiles_repo; rename hosts_repo to hosts_dir; never re-point a valid ~/.local/bin/dotfiles".

### Task R2: push remote paths (link target + YAML `hosts_dir`)

**Files:** `lib/push.sh`, `test/apps/test-push.sh`, `test/run-remote-tests.sh`.

**Behavior:**
- **The remote snippet** (POSIX sh, `push_remote_snippet`) prints `dotfiles_repo=<abs>` and `hosts_dir=<abs>`. These are internal output names, and the local parser reads them.
  - **dotfiles path:** if `$HOME/.local/bin/dotfiles` is a symlink, follow it with a portable `readlink` loop. If the final target's basename is `dotfiles` and its directory contains `lib/`, use that directory. Otherwise use `$HOME/.local/share/dotfiles/dotfiles`.
  - **hosts dir:** read the remote config (`${DOTFILES_CONFIG:-$HOME/.config/dotfiles/config.yaml}`) for `hosts_dir`, using the same YAML rules as `config_load`, last occurrence wins. If the value is absent or not absolute after `~` expansion, warn and use the default.
- **The local side** consumes the renamed output lines.

- [ ] **Step 1: Write the tests.**
  - **dash unit tests** of the snippet against temp HOME and config:
    - YAML parsing: CRLF, comments, quotes, a trailing comment, `~`
    - link resolution: absolute and relative links, a link to a non-dotfiles file falling back to the default, and no link
  - **Docker:**
    - P1's remote config becomes `config.yaml` with `hosts_dir: "~/dh-custom"  # comment` and CRLF.
    - New **P7**: on the remote, create `~/alt/dotfiles` containing a `PUSHED` file plus `lib/`, then `ln -s ~/alt/dotfiles/dotfiles ~/.local/bin/dotfiles` after creating that target file. Push should unpack the dotfiles into `~/alt/dotfiles`.
- [ ] **Step 2:** Run `bash test/apps/test-push.sh`. It should fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the full Docker suite once, then the local suites, then clean up.
- [ ] **Step 5:** Commit: "Push: find the remote dotfiles via its installed link; read hosts_dir from remote config.yaml".

### Task R3: Pending reminder, background installs with passwordless sudo, drop-ins only when the tool exists

**Files:** `dotfiles` (phases 1–2, `--auto` flow), `lib/sync.sh` (report), `lib/login.sh`, `test/apps/test-sync.sh`, `docs/schema.md`.

**Behavior:**
- **The report** (`sync_write_report`) drops its pending line. The remaining lines are, in order: updated, pull warnings, sync failed.
- **The drop-in** (`lib/login.sh`):
  - It prints the one-time report and deletes it, as today.
  - Then, every time, if `<state>/pending` is non-empty it prints the reminder line from the Global Constraints. Names are joined with `, `, using bash only, no `paste` or `sed`, since this runs at every shell start. Read the file with a `while read` loop.
  - It then launches the background sync as today.
- **`sync --auto`:**
  - After throttling and logging, compute `SYNC_CAN_SUDO`: `sudo -n true </dev/null >/dev/null 2>&1 9>&-` exits 0, guarded by `command -v sudo`.
  - If it is true, phases 1 and 2 run for real, with stdin `</dev/null` for every install command. The log notes `passwordless sudo: installing packages`.
  - If it is false, the phases run in check-only mode, as today.
- **Phase 2 drop-ins (both modes):** after the install step for an entry, deploy its drop-in only if `check` is empty or `check` now passes. Otherwise log `<name>: drop-in held until the tool is installed`.
- **Pending (both modes):** whatever is still missing afterwards. An interactive sync that installs everything writes an empty `pending` file, so the reminder stops.

- [ ] **Step 1: Write the tests** (`test-sync.sh`).
  1. **Reminder at every shell, report once.** With `pending` containing `lazygit` and `htop` and a report present, two consecutive interactive drop-in runs both print `dotfiles: lazygit, htop not installed (needs sudo) — run 'dotfiles sync'`. Only the first prints the report.
  2. **No reminder when nothing is pending.** An empty `pending` file prints no reminder.
  3. **No pending line in the report.** `--auto` with a missing package writes a report without the word `pending`, and `pending` lists the package.
  4. **Sudo that would prompt.** A fake `sudo` on PATH exits 1 for `-n true` and otherwise records its args. Use one whose `-n` branch would block on stdin if stdin weren't `/dev/null`: `read -r _` before exiting 1. The sync must not hang (use `timeout 20`), and no install is recorded.
  5. **Passwordless sudo.** A fake `sudo` exits 0 for `-n true` and records every other invocation, exiting 0. `--auto` with the pendingtest profile records an install invocation for the OS package, for example args containing `install`. The custom script runs: point the custom entry at a fixture script that touches a marker file, since the real lazygit script must not run.
  6. **Drop-in held.** A custom entry whose `check` is `false` does not get its drop-in deployed in `--auto` or interactive. Use `--no-pull` and a fake `sudo` that fails, so interactive installs fail. Once `check` passes (`true`), the drop-in is deployed.
  - Use a /tmp copy of the fixture with a custom fixture script, e.g. `packages/custom/<x>/install.sh`? No: the hosts repo can't add scripts. Use the existing `pendingtest` profile in the fixture, and add a new fixture profile entry referencing an existing script. If no harmless script exists, add `test/fixtures/packages/fake-tool/install.sh` together with a mechanism that lets tests point at it. **Simplest:** add `packages/custom/testtool/install.sh`, which only touches `$DOTFILES_TEST_MARKER` when that is set and otherwise exits 1, plus `files/50-testtool.sh`. Mark both as test fixtures in a comment, and keep them out of every real profile.
- [ ] **Step 2:** Run it. It should fail.
- [ ] **Step 3: Implement.** Update `docs/schema.md`: the background sync section, the report lines and the reminder.
- [ ] **Step 4:** Run the full local suites and the Docker suite once, then clean up.
- [ ] **Step 5:** Commit: "Remind about packages needing sudo at every terminal; install in background with passwordless sudo; hold drop-ins until their tool is installed".
