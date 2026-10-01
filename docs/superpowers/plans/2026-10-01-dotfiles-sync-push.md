# dotfiles sync/push (sub-project 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `setup.sh` with a `dotfiles` command that syncs a host from its config file (pulling both repos), runs a throttled config-only background sync from a `~/.bashrc.d` drop-in with a next-terminal report, pushes committed repo snapshots to hosts without git, and drops the workstation-side remote deploy and the rollback/backups commands.

**Architecture:** `setup.sh` is renamed `dotfiles` and slimmed. Profile resolution moves to `lib/profile.sh` and the new behavior lives in small libraries:
- `lib/config.sh`: parse the config file.
- `lib/sync.sh`: state dir, lock, throttle, pull, self-install, pending list, report.
- `lib/push.sh`: ssh/scp and payload.
- `lib/login.sh`: the drop-in source.

The installer core loses `--remote` and the rollback/backups commands. Tests stay in the existing bash harness; push is tested against the Docker SSH container.

**Tech Stack:** Bash 4+, git, flock (util-linux; with an mkdir fallback), ssh/scp, tar, jq (unchanged), Docker for the push tests.

**Spec:** `docs/superpowers/specs/2026-10-01-dotfiles-sync-push-design.md` (it builds on `docs/superpowers/specs/2026-09-30-dotfiles-hosts-design.md`).

## Global Constraints

- Command name `dotfiles` (an executable at the repo root). `setup.sh` is deleted, with no wrapper.
- Commands: `sync`, `push`, `status`, `uninstall`, `verify`, `help`. The orchestrator-level `deploy`/`install`/`upgrade` are removed; app installers keep theirs, and the orchestrator calls `<app>/install.sh deploy`.
- Config file: `${DOTFILES_CONFIG:-$HOME/.config/dotfiles/config}`. It is made of `key=value` lines and is parsed, never sourced. Keys: `dotfiles_repo`, `hosts_repo`, `hostname`, `profile`, `auto_sync` (`on`/`off`), `auto_sync_interval` (`<n>m|h|d`, default `4h`).
- Precedence: command-line flag > env `DOTFILES_HOSTS_REPO` (hosts repo only) > config file > default.
- State dir: `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/`. It holds `lock`, `last-sync`, `last-sync.log`, `report` and `pending`.
- Default repo paths: `~/.local/share/dotfiles/dotfiles` and `~/.local/share/dotfiles/dotfiles-hosts`.
- Self-install: `~/.local/bin/dotfiles` is a symlink to `<dotfiles_repo>/dotfiles`, and `<shell_scripts_dir>/90-dotfiles.sh` is a copy of `lib/login.sh`.
- Report lines are each prefixed `dotfiles: `. Exact forms:
  - `updated a, b`
  - `N package(s) pending (a, b) — run 'dotfiles sync'`
  - `<path>: pull failed (<reason>) — see <log>`
  - `sync failed (<items>) — see <log>`
- `--auto` never installs OS packages or runs custom install scripts, never prompts, and touches `last-sync` even when it fails.
- Pull is `git pull --ff-only` only. A failed pull leaves the repo untouched.
- Push sends `git archive HEAD` (committed state), or the plain directory when the source is not a git work tree. It refuses a remote target that is a git checkout, then runs `dotfiles sync --no-pull` with `ssh -t`.
- `DOTFILES_SSH_OPTS` (whitespace-split extra ssh/scp options) is kept for tests and lives in `lib/push.sh`.
- Tests must never touch the real `$HOME`, `~/.bashrc.d`, `~/.local/bin`, or the real repos. Every test sets `HOME`, `STATE_DIR`, `XDG_STATE_HOME` and `DOTFILES_CONFIG` to temp paths and unsets `DOTFILES_HOSTS_REPO`. Tests that need a git origin clone the worktree into `/tmp`.
- Commits: `git add <explicit paths>`. NEVER add a `Co-Authored-By` or any Claude attribution trailer.
- Suites run from `test/`: `./run-core-tests.sh` and `./run-app-tests.sh` (every `apps/test-*.sh` file). `./run-remote-tests.sh` needs Docker. `docker-compose` v1 is broken on this machine, so put a `docker-compose` → `docker compose` shim in a temp dir on PATH, never in `~/.local/bin`. `test/ssh-key` must be mode 600.

## Review Focus

1. **A background sync while you're mid-edit on this machine.** `--auto` deploys the working tree as-is, so uncommitted edits in `~/git/dotfiles` go live. That is the intended behavior (spec). It must never stash, reset, or otherwise touch the repo. Task 4 tests a dirty conflicting tree.
2. **A config file with CRLF line endings, trailing spaces, or `key = value` with spaces.** These must parse to the trimmed value, not to a name containing `\r`. Tested in Task 3.
3. **Two terminals opened at once.** Only one sync may run; the second exits silently and leaves no stray lock file that blocks future runs. Tested in Task 4 by holding the lock with `flock` in a background subshell.
4. **Push to a host whose remote `$HOME` path or default dirs don't exist yet.** The payload unpack must `mkdir -p` the parents. Tested in Task 7's first push to a fresh container.
5. **The report shows only new information.** An auto sync where nothing changed writes no report, and an interactive sync deletes a stale report. Tested in Task 5.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `dotfiles` | create (from `setup.sh`) | CLI parsing, command dispatch, phases, summary |
| `setup.sh` | delete | — |
| `lib/profile.sh` | create (moved code) | `reset_pkg_arrays`, `load_manifest`, `resolve_profile_path`, `apply_profile_modifiers`, `load_profile`, `load_packages_for_profile`, `prepare_overlays` |
| `lib/config.sh` | create | `config_load FILE` → `CFG_*` globals; `config_interval_seconds STR` |
| `lib/sync.sh` | create | state paths, lock, throttle, `sync_pull_repo`, `sync_self_install`, report/pending writers |
| `lib/push.sh` | create | ssh/scp wrappers (`DOTFILES_SSH_OPTS`), payload build, remote unpack, `push_host` |
| `lib/login.sh` | create | drop-in source (spec text) |
| `lib/remote.sh` | delete | — |
| `lib/installer.sh` | modify | remove `--remote`/`execute_remote`/`app_pre_remote`/`APP_REMOTE_DROP_ARGS`/`.version` branch; remove `rollback`/`backups`/`--to`; `verify` keeps file checks only |
| `lib/backup.sh` | modify | remove checksums, `backup_verify`, `backup_get_latest` (and `backup_list_snapshots` if unused) |
| `lib/state.sh` | modify | nothing required; `state_add_snapshot`/`state_get_snapshots` stay |
| `bash/install.sh` | modify | drop `APP_REMOTE_DROP_ARGS`/`app_pre_remote` |
| `test/apps/test-setup.sh` | modify | use `./dotfiles`, `sync` |
| `test/apps/test-hosts.sh` | modify | use `./dotfiles sync` |
| `test/apps/test-config.sh` | create | config parsing + precedence |
| `test/apps/test-sync.sh` | create | lock, pull, self-install, `--auto`, report, drop-in |
| `test/apps/test-status.sh` | create | status output |
| `test/run-core-tests.sh` | modify | drop rollback/backups tests; keep snapshot + original + uninstall |
| `test/run-remote-tests.sh` | rewrite | push tests against the Docker container |
| `docs/schema.md` | modify | remove `hosts.yaml` section; add config file, commands, report |
| `README`-like usage | `dotfiles help` | updated usage text |

---

### Task 1: Rename to `dotfiles`, extract `lib/profile.sh`, remove remote mode

This task is a refactor plus removal. Local behavior is unchanged except that `deploy` is now spelled `sync`.

**Files:** create `dotfiles` (from `setup.sh` via `git mv`) and `lib/profile.sh`. Delete `lib/remote.sh`. Modify `lib/installer.sh`, `bash/install.sh`, `test/apps/test-setup.sh`, `test/apps/test-hosts.sh`, `test/run-remote-tests.sh` and `docs/schema.md` (hosts.yaml section only).

**Interfaces:**
- Produces: `./dotfiles sync|status|uninstall|verify|help`. `sync` does exactly what `setup.sh deploy` did locally: it passes `deploy` to each app installer. `status`, `uninstall` and `verify` behave as before.
- `lib/profile.sh` holds the moved functions with unchanged signatures. It uses globals that `dotfiles` declares: `PROFILES_DIR`, `HOSTS_REPO`, the `PKG_*` arrays, `RESOLVED_PROFILE`, `HOSTS_PROFILE_CHAIN`, `HOST_YAML`, `STAGE_ROOT`, `STRATEGIES_FILE`, `LAYER_ROOTS` and `WORK_DIR`.
- `run_all` takes no host argument any more. Its signature is `run_all PROFILE_ARG`. It still sets `OVERLAY_HOST` from `HOSTNAME_ARG`, or from `hosts_local_name` when that is empty.
- `hosts_normalize_name` stays in `lib/hosts.sh`, unused by `dotfiles` (Task 7 may use it to label output). Keep it and its tests.

- [ ] **Step 1:** In `test/apps/test-setup.sh` and `test/apps/test-hosts.sh`:
  - replace every `./setup.sh deploy` / `$ROOT_DIR/setup.sh` / `setup.sh` reference with `./dotfiles sync` / `$ROOT_DIR/dotfiles` / `dotfiles`
  - change the test-setup Test 1 title to "dotfiles exists and is executable"
  - delete the tests for `--host`/`--hosts-file` (test-setup Tests 7–8 and test-hosts Test 13). In their place, add one test asserting that `./dotfiles sync --host x` exits non-zero with "Unknown option".
  - change test-setup Test 6 (invalid command) to also assert that `./dotfiles deploy` is rejected.
- [ ] **Step 2:** Run `cd test && bash apps/test-setup.sh`. Expected: FAIL at Test 1 (`dotfiles` missing).
- [ ] **Step 3:** `git mv setup.sh dotfiles`. Then:
  1. Move the profile functions listed above into `lib/profile.sh`, source it from `dotfiles`, and keep the header comment style.
  2. Delete `load_hosts`, `run_on_target`'s remote branch (make it plain `eval`, or inline `eval` at call sites, and drop the `host` parameters of `detect_pkg_manager`, `is_pkg_installed`, `run_phase_os_packages`, `run_phase_custom_installs` and `run_phase_configs`), the `--host`/`--hosts-file`/`--continue-on-error` parsing, `REMOTE_HOST_ARG`/`HOSTS_FILE`/`CONTINUE_ON_ERROR`, and every remote-related line in `main`/`run_all`.
  3. The result target label is always `local`.
  4. `validate_command` accepts `sync status uninstall verify help -h --help`. Map `sync` to the installer command `deploy` (keep a variable `INSTALLER_CMD`). For `status`, `uninstall` and `verify`, the installer command is the same word.
  5. Update `usage` to the new CLI (no push yet). Its header is `Usage: dotfiles <command> [options]`, and the examples use `dotfiles sync`.
- [ ] **Step 4:** Delete `lib/remote.sh`. In `lib/installer.sh`:
  - remove the `remote.sh` source, `REMOTE_MODE`, `--remote` parsing, `execute_remote`, the `app_pre_remote` hook, `APP_REMOTE_DROP_ARGS`, and the `.version` file branch of `installer_version` (it becomes: stage version, else the git hash)
  - remove the `--remote` lines from usage
  - in `installer_main`, drop the remote dispatch.

  In `bash/install.sh`, drop `APP_REMOTE_DROP_ARGS` and `app_pre_remote`.
- [ ] **Step 5:** Reduce `test/run-remote-tests.sh` to Test 0 (environment check) plus a placeholder banner. Every other test there used the removed remote mode, and Task 7 rewrites the file for push. Keep the `test_ssh` helper and the SSH variables. In `docs/schema.md`, delete the "Hosts Schema (`hosts.yaml`)" section and every `--host`/`--hosts-file` mention.
- [ ] **Step 6:** Run `cd test && ./run-core-tests.sh && ./run-app-tests.sh`. Expected: all pass. Also run `grep -rn "remote_\|setup.sh\|--hosts-file" --include=*.sh . | grep -v docs/superpowers`. Expected: only `hosts_normalize_name`/test-overlay hits remain. Also expected: no hits for `remote_` outside comments, and no `setup.sh` hits.
- [ ] **Step 7:** Commit: `git add -A dotfiles setup.sh lib/ bash/install.sh test/ docs/schema.md`, with message "Rename setup.sh to dotfiles; move profile resolution to lib/profile.sh; remove remote deploy mode".

---

### Task 2: Backup simplification (drop rollback/backups)

**Files:** modify `lib/installer.sh`, `lib/backup.sh` and `test/run-core-tests.sh`.

**Interfaces:**
- Installer commands remaining: `deploy install upgrade uninstall status verify diff help`.
- `rollback`, `backups` and `--to` become "Unknown command/option".
- `verify` checks that state files exist and nothing else.
- Upgrade still snapshots live files (`backup_create_snapshot`) and prunes (`backup_prune`).
- Install still creates `original` backups, and uninstall restores them (`backup_restore` with `original`).

- [ ] **Step 1:** In `test/run-core-tests.sh`:
  - Remove Tests 9–11, 15/15b–15e, 21, 28, 34 and 36. Those are the backups/rollback ones; renumber only the banner count.
  - Add **Test R1**: after `install` and then `upgrade --force`, a snapshot dir `~/.bak/tmux/<YYYYmmdd_HHMMSS>` exists containing `.tmux.conf`.
  - Add **Test R2**: `./install.sh rollback` exits non-zero with "Unknown command".
  - Add **Test R3**: `./install.sh backups` exits non-zero.
  - Add **Test R4**: after a fresh install over an existing original `~/.tmux.conf` ("original"), `uninstall` restores the content "original".
  - Add **Test R5**: no `.checksums` file is created anywhere under `~/.bak/tmux` after install and upgrade (`find ~/.bak/tmux -name .checksums` prints nothing).
  - Make the final banner read `All <N> core library tests passed!` with the new count.
- [ ] **Step 2:** Run `cd test && ./run-core-tests.sh`. Expected: FAIL at R2 (rollback still exists).
- [ ] **Step 3:** In `lib/installer.sh`:
  - Delete `cmd_rollback`, `cmd_backups`, the `--to` parsing and `ROLLBACK_TARGET`, and the `rollback`/`backups` entries in `validate_command`, `usage` and the `installer_main` dispatch.
  - In `cmd_verify`, remove the "Verify backups" block.

  In `lib/backup.sh`:
  - remove the checksum writing in `backup_create_original` and `backup_create_snapshot`
  - remove `backup_verify` and `backup_get_latest`
  - remove `backup_list_snapshots` only if nothing else uses it (`grep -rn`)
  - update the export list.

  Keep `backup_restore`, `backup_prune`, `backup_init`, `backup_has_original`, `backup_create_original` and `backup_create_snapshot`.
- [ ] **Step 4:** Run `cd test && ./run-core-tests.sh && ./run-app-tests.sh`. Expected: all pass. If an app test used `rollback`/`backups`, delete that assertion and note it in the report.
- [ ] **Step 5:** Commit "Drop rollback/backups commands and backup checksums; keep originals and snapshots".

---

### Task 3: Config file (`lib/config.sh`) and precedence

**Files:** create `lib/config.sh` and `test/apps/test-config.sh`. Modify `dotfiles` and `docs/schema.md`.

**Interfaces:**
- `config_load FILE` sets these globals:
  - `CFG_DOTFILES_REPO`, `CFG_HOSTS_REPO`, `CFG_HOSTNAME`, `CFG_PROFILE`: raw strings, `~` expanded at the start, empty if unset
  - `CFG_AUTO_SYNC`: default `on`
  - `CFG_AUTO_SYNC_INTERVAL`: default `4h`
  - `CFG_FILE`: the path

  It returns 0 when the file is missing, with all defaults. For each malformed or unknown line it logs `log_warn "<file>:<n>: ignoring <reason>: <line>"`. It returns 1 for `auto_sync` not in `on`/`off`, and for an invalid interval.
- `config_interval_seconds STR` prints the seconds for `<n>m|h|d` and returns 1 for anything else.
- In `dotfiles`, after `parse_args`, a function `resolve_settings` fills in:
  - `DOTFILES_REPO`: config, else `SCRIPT_DIR`. Abort if the directory is missing. `SCRIPT_DIR`, which `PROFILES_DIR`/app dirs/`packages` use, becomes `DOTFILES_REPO`. If the config points somewhere else, log `log_warn "Running $SCRIPT_DIR/dotfiles but config dotfiles_repo is $X; using $X"` and re-exec `"$X/dotfiles" "$@"` **only if** `$X/dotfiles` exists and `DOTFILES_REEXEC` is unset (set `DOTFILES_REEXEC=1` for the exec).
  - `HOSTS_REPO`: flag > env > config > the default path if that directory exists > empty. A configured or flagged path that doesn't exist aborts (existing message).
  - `HOSTNAME_ARG`: flag > config `hostname` > empty, which keeps the `hosts_local_name` fallback.
  - `PROFILE_ARG`: flag > config `profile` > empty.
  - `AUTO_SYNC` and `AUTO_SYNC_SECONDS`, from the config (used in Task 5).
- Parsing rules:
  - strip `\r`
  - skip blank lines and lines whose first non-space character is `#`
  - split on the first `=`
  - trim spaces around the key and the value
  - strip one pair of surrounding quotes (`"` or `'`) from the value
  - a key not matching `^[a-z_]+$` is malformed.

- [ ] **Step 1:** Write `test/apps/test-config.sh` as a unit test that sources `lib/logging.sh`, `lib/utils.sh` and `lib/config.sh`, in the style of test-overlay. Cases:
  1. A missing file gives defaults (`on`, `4h`, and empty values).
  2. All keys set, including `~/x` → `$HOME/x`.
  3. A CRLF file, `key = value ` with spaces, and a quoted value all parse to the clean value.
  4. Comments and blank lines are ignored.
  5. An unknown key warns with the file:line and is ignored.
  6. A line without `=` warns.
  7. `auto_sync=maybe` makes `config_load` return 1.
  8. `auto_sync_interval=10x` returns 1.
  9. `config_interval_seconds` gives `30m`=1800, `4h`=14400, `2d`=172800, and returns 1 for `h`, `0x` and the empty string.

  Integration cases, against `./dotfiles sync --dry-run` with a sandboxed HOME, `DOTFILES_CONFIG` and the fixture hosts repo copied to `/tmp`:
  1. The config's `hosts_repo` + `hostname=testhost` gives `Using profile 'base'`.
  2. The `--hostname excludehost` flag beats the config hostname.
  3. Env `DOTFILES_HOSTS_REPO` beats the config `hosts_repo`.
  4. With no `hosts_repo` configured but `$HOME/.local/share/dotfiles/dotfiles-hosts` present (a copy of the fixture), that repo is used.
  5. Config `profile=minimal` with no host.yaml gives `Using profile 'minimal'`.
  6. Config `hosts_repo=/nonexistent` gives a non-zero exit with "Hosts repo not found".
  7. Config `dotfiles_repo=/nonexistent` gives a non-zero exit.
- [ ] **Step 2:** Run it. Expected: FAIL (`lib/config.sh` missing).
- [ ] **Step 3:** Implement `lib/config.sh`, plus `resolve_settings` and its call in `dotfiles`. Add a "Config file" section to `docs/schema.md` with the key table from the spec.
- [ ] **Step 4:** Run `bash apps/test-config.sh`, then the full suites. Expected: all pass.
- [ ] **Step 5:** Commit "Add per-host config file with flag/env/config/default precedence".

---

### Task 4: Sync pipeline: lock, pull, self-install, record

**Files:** create `lib/sync.sh` and `lib/login.sh`. Modify `dotfiles`. Create `test/apps/test-sync.sh`.

**Interfaces (`lib/sync.sh`):**
- `sync_state_dir`: prints `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles` and runs `mkdir -p` on it.
- `sync_lock`: takes an exclusive non-blocking lock on `<state>/lock` and holds it until the process exits. With `flock` available it opens fd 9 on the lock file and runs `flock -n 9`. Without `flock` it runs `mkdir <state>/lock.d`, and an EXIT trap appended through a helper removes it, without clobbering existing traps: keep a global `SYNC_CLEANUP` list that the single EXIT trap in `dotfiles` runs. Returns 1 if the lock is held.
- `sync_pull_repo PATH`:
  - Returns 0 and logs `log_info "Pulled <path>"` / `Already up to date: <path>` on success.
  - Returns 0 silently when PATH is not a git work tree, or has no upstream (`git -C PATH rev-parse --abbrev-ref @{u}` fails).
  - Returns 1 on pull failure, printing a reason on stdout: the first non-empty line of git's stderr, trimmed to 120 characters.
  - It runs `git -C PATH pull --ff-only --quiet`, with `GIT_TERMINAL_PROMPT=0` always. When `SYNC_AUTO=true`, it also sets `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, unless `GIT_SSH_COMMAND` is already set.
- `sync_self_install DOTFILES_REPO SHELL_SCRIPTS_DIR`:
  - `mkdir -p ~/.local/bin`
  - `ln -sfn DOTFILES_REPO/dotfiles ~/.local/bin/dotfiles`
  - `mkdir -p SHELL_SCRIPTS_DIR`
  - `cmp -s` `lib/login.sh` against `SHELL_SCRIPTS_DIR/90-dotfiles.sh`, copying and chmod 0644 when they differ.
  - Logs `log_debug` lines only.
- `sync_touch_last`: touches `<state>/last-sync`.
- `sync_write_pending NAME...`: writes one name per line to `<state>/pending`, or an empty file.
- `sync_clear_report`: `rm -f <state>/report`.

**`dotfiles sync` flow:** add the `--auto` and `--no-pull` flags. `--auto` is parsed here, but its behavior lands in Task 5. In this task it only sets `SYNC_AUTO=true`.
1. `resolve_settings` (Task 3).
2. `sync_lock`, unless `--dry-run`. If the lock is held: when `SYNC_AUTO` is set, `exit 0`; otherwise print `dotfiles: sync already running` to stderr and `exit 1`.
3. Pull each of `DOTFILES_REPO` and `HOSTS_REPO` (if set), unless `--no-pull` or `--dry-run`. A failure adds `RESULTS+=("local|pull <path>|FAIL")` and a warning line `"<path>: pull failed (<reason>)"` to the global `SYNC_WARNINGS` array, then logs `log_warn`. It does not set `EXIT_CODE` (a failed pull is a warning, not a sync failure).
4. `sync_self_install`, unless `--dry-run`.
5. `run_all`, as today.
6. Outside `--dry-run`, `sync_touch_last` runs whether or not step 5 failed, and so does `sync_clear_report` when not `--auto`.

`lib/login.sh` is the exact text from the spec's "Login drop-in" section.

- [ ] **Step 1:** Write `test/apps/test-sync.sh`.
  - **Setup:**
    - Sandbox `HOME`/`STATE_DIR`/`XDG_STATE_HOME`/`DOTFILES_CONFIG` and unset `DOTFILES_HOSTS_REPO`.
    - Build a bare origin with `git clone --bare "$ROOT_DIR" /tmp/sync-origin.git`, then clone `/tmp/sync-origin.git` to `$WORK/dotfiles` (the repo under test) and to `$WORK/author` (used to push new commits).
    - Set the clones' `user.name`/`user.email` locally.
    - Note: `$ROOT_DIR` must have its working changes committed for the clone to include them. The test runs after the commit step of each task, so use `git -C "$ROOT_DIR" stash`-free means: if `$ROOT_DIR` is dirty, the test prints a skip notice for pull tests (still pass) rather than cloning stale code. Simplest: clone, then `rsync -a --exclude .git "$ROOT_DIR"/ $WORK/dotfiles/` and commit there as "wip". Use that.
    - Write a config with `dotfiles_repo=$WORK/dotfiles` and the fixture profile `base` via the copied fixture hosts repo (`hostname=testhost`).
  - **Cases:**
    1. **Self-install:** `$WORK/dotfiles/dotfiles sync --no-backup` creates the symlink `~/.local/bin/dotfiles` → `$WORK/dotfiles/dotfiles` and `~/.bashrc.d/90-dotfiles.sh`, identical to `lib/login.sh`. A second run keeps them and exits 0.
    2. **Pull fast-forward:** commit a new file `PULLTEST` in `$WORK/author` and push it to origin. After sync, `$WORK/dotfiles/PULLTEST` exists.
    3. **`--no-pull`:** push another commit. `sync --no-pull` doesn't bring it in.
    4. **Diverged:** make a local commit in `$WORK/dotfiles` and push a different commit from author. Sync exits 0, the output contains `pull failed`, and `git -C $WORK/dotfiles log -1` is still the local commit.
    5. **Dirty conflicting tree:** modify a tracked file that the incoming commit also changes. Sync leaves the modification intact (`git diff` non-empty with the local change) and warns `pull failed`.
    6. **Non-git dotfiles repo:** run sync from a copy without `.git`. It exits 0 with no pull warnings.
    7. **Lock held:** run `( flock 9; sleep 5 ) 9>"$XDG_STATE_HOME/dotfiles/lock" &`, wait until the lock is taken, then run `sync`. It exits 1 with "already running", and `sync --auto` exits 0 quickly with no deploy output. Kill the holder, and a later `sync` succeeds (no stale lock).
    8. **last-sync:** it exists after a successful sync, and it is also touched (mtime updated) after a sync that fails validation. Use `--hostname typo` with the fixture to force the abort.
    9. **Interactive sync clears report:** create `<state>/report` with "x". After `sync`, it's gone.
- [ ] **Step 2:** Run it. Expected: FAIL at case 1.
- [ ] **Step 3:** Implement `lib/sync.sh`, `lib/login.sh` and the `dotfiles` flow changes. Add `--auto`/`--no-pull` to `usage`.
- [ ] **Step 4:** Run `bash apps/test-sync.sh`, then the full suites. Expected: all pass.
- [ ] **Step 5:** Commit "Add sync pipeline: lock, ff-only pull, self-install, last-sync".

---

### Task 5: `--auto`: throttle, config-only with pending, report, login drop-in

**Files:** modify `dotfiles` and `lib/sync.sh`. Extend `test/apps/test-sync.sh`.

**Interfaces/behavior:**
- **Throttle**, first thing after the lock with `--auto`: if `AUTO_SYNC` is `off`, `exit 0`. If `<state>/last-sync` exists and `now - mtime < AUTO_SYNC_SECONDS`, `exit 0`. Use `stat -c %Y`, falling back to `stat -f %m`.
- **Logging:** with `--auto`, `exec >"<state>/last-sync.log" 2>&1` right after the throttle passes. That truncates the file each run, and its first line is `dotfiles sync --auto <ISO date>`.
- **Settings:** with `--auto`, `export GIT_SETUP_SKIP=true`.
- **Phases:**
  - Phase 1 in check mode (`CHECK_ONLY=true`): compute the missing packages as today, without the dry-run/install branches, and record each missing package's name in `PENDING`. Use the package entry's `name`, not the apt package name.
  - Phase 2 in check mode: for each custom entry whose `check` fails, add the name to `PENDING`, skip the script, and still install its drop-in.
  - Phase 3 runs normally.
  - An interactive sync also fills `PENDING`, with what's still missing after installs, which is usually nothing.
  - Always run `sync_write_pending "${PENDING[@]}"`, except in `--dry-run`.
- **Updated apps:** in `run_phase_configs`, read `state_get_version <app-name>` before and after each installer run, with the state file path from `lib/state.sh`. Note that the state name is the app's `app.name`; read it with `yaml` from `<dir>/config.yaml`, falling back to the dir name. If the value changed, or the file didn't exist before and does now, add the app to `UPDATED_APPS`.
- **Report** (`--auto` only, written at the end): the lines from the Global Constraints, in this order:
  1. `updated …` when `UPDATED_APPS` is non-empty
  2. pending, when `PENDING` is non-empty
  3. each `SYNC_WARNINGS` entry, plus ` — see <log>`
  4. `sync failed (<items>) — see <log>` when any RESULTS item is FAIL, excluding the `pull …` items already reported

  Write to `<state>/report.tmp`, then `mv` it into place. Write nothing (and remove any old report) if there are no lines.
- **Summary:** with `--auto`, still print it into the log.

- [ ] **Step 1:** Extend `test/apps/test-sync.sh`.
  - **Fixture:** add `test/fixtures/hosts-repo/profiles/pendingtest.yaml` with:
    - `claude` and `scripts` (config only)
    - an OS-package entry `name: nonexistent-pkg` with `apt: dotfiles-nonexistent-pkg`, `dnf: dotfiles-nonexistent-pkg` and `brew: dotfiles-nonexistent-pkg`
    - a custom entry `name: faketool` with `custom: check: false`, `script: custom/lazygit/install.sh` (never run in `--auto`) and `dropin: custom/lazygit/files/50-lazygit.sh`
  - **Cases:**
    1. **Throttle:** `touch` last-sync now. `sync --auto` exits 0, writes no log lines beyond nothing, and changes no state. With last-sync 5 hours old (`touch -d '5 hours ago'`), `--auto` runs: the log exists and starts with `dotfiles sync --auto`.
    2. **`auto_sync=off`:** with an old last-sync, `--auto` exits 0 and leaves the log unchanged.
    3. **Config-only + pending:** with config `profile=pendingtest` and no host.yaml (`hostname=nohost`):
       - `--auto` installs nothing; there is no sudo and apt is not invoked, which the test checks by putting a fake `sudo` first on PATH that writes `/tmp/.../sudo-called` and exits 1.
       - `<state>/pending` contains `nonexistent-pkg` and `faketool`.
       - The report contains `dotfiles: 2 packages pending (nonexistent-pkg, faketool) — run 'dotfiles sync'`.
       - `~/.bashrc.d/50-lazygit.sh` was deployed.
       - The claude configs were deployed.
    4. **Updated:** with a fresh HOME, the first `--auto` (base profile) gives a report line starting `dotfiles: updated claude, scripts`. Back-date last-sync and run `--auto` again with no changes: no report file. Then change a fixture layer in the `/tmp` copy, back-date, and run `--auto`: the report says `dotfiles: updated claude`.
    5. **Pull failure in report:** with the diverged setup from Task 4, `--auto` writes a report line matching `dotfiles: <path>: pull failed (` and `— see`.
    6. **Validation failure:** with `--hostname typo` in the config (`hostname=typo`), `--auto` gives a report containing `dotfiles: sync failed (`, and last-sync is touched.
    7. **Drop-in:**
       - Write a fake `dotfiles` script into `$WORK/bin` that appends its args to `$WORK/calls`, and put `$WORK/bin` first on PATH.
       - Create `<state>/report` containing `dotfiles: hello`.
       - Run `bash --norc --noprofile -i -c 'source ~/.bashrc.d/90-dotfiles.sh' 2>/dev/null`. The output contains `dotfiles: hello`, the report is deleted, and within 2 s `$WORK/calls` contains `sync --auto`.
       - Run the same command again with `DOTFILES_NO_AUTO_SYNC=1`: no new call.
       - Run non-interactively (`bash --norc -c 'source …'`): no output and no call.
- [ ] **Step 2:** Run it. Expected: the new cases fail.
- [ ] **Step 3:** Implement. Keep the throttle, report and pending functions in `lib/sync.sh` (`sync_should_run_auto`, `sync_write_report LOG UPDATED_CSV PENDING_CSV`; pass warnings and failures through globals or arguments, as the implementer chooses, but document the choice in the function header).
- [ ] **Step 4:** Run `bash apps/test-sync.sh`, then the full suites. Expected: all pass.
- [ ] **Step 5:** Commit "Add background sync mode: throttle, config-only with pending packages, next-terminal report".

---

### Task 6: `dotfiles status`

**Files:** modify `dotfiles` (it replaces today's `status`, which ran each installer's `status`) and create `test/apps/test-status.sh`.

**Behavior:** this is read-only: no lock, no pull, no self-install, no changes to state. It prints the spec's layout. The exact labels and the left-column width of 17 characters (`printf '%-17s%s\n'`) are:
- `dotfiles repo:` shows `<path>  (git <branch> @ <short sha>[, dirty])`, or `(pushed: <PUSHED file content>)` for a copy with a `PUSHED` file, or `(not a git checkout)`.
- `hosts repo:` uses the same forms, or `none`.
- `config:` shows `<path>`, or `<path> (not found, using defaults)`.
- `host:` shows `<name>  (hosts/<name>/host.yaml)` or `<name>  (no host directory)`, followed by `   profile: <resolved>`.
- `auto sync:` shows `on, every <interval> — last run <age> ago` or `on, every 4h — never run`, or `off`. Age formatting: `<n>m`, `<n>h` or `<n>d`, rounded down, and `just now` under 1 minute.
- `pending:` shows the comma list from `<state>/pending`, or `none`.
- `apps:` is followed by one line per config app in the resolved package list, as `  <app padded to 9>` plus one of:
  - `up to date`: state version = fresh stage version
  - `update available`: they differ, or the version is `incomplete`
  - `not installed`: no state file

  For the stage version, stage into `$WORK_DIR` with `overlay_stage_app` and read `version`.
- If the resolution or validation fails, print the error and still print the sections above it. Exit 0.

- [ ] **Step 1:** Write `test/apps/test-status.sh`. Use the sandbox, the fixture hosts repo copied to `/tmp`, and a config with `hostname=testhost`. Cases:
  1. Before any sync:
     - the `apps:` lines show `claude    not installed`
     - `auto sync:` shows `never run`
     - `pending:` shows `none`
     - `host:` shows `testhost  (hosts/testhost/host.yaml)   profile: base`
  2. After `sync --no-backup`, `claude    up to date`.
  3. After editing the host layer in the `/tmp` copy, `claude    update available` and `scripts   up to date`.
  4. `dotfiles repo:` contains `(git ` when run from the worktree.
  5. A non-git copy with a `PUSHED` file shows `(pushed: source=...`.
  6. Status creates no state files: `find "$STATE_DIR" -newer <marker>` and `<state>` have no new files.
  7. A missing config shows `(not found, using defaults)`.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement `cmd_status` in `dotfiles`. Remove the old per-installer status path, which only exists in `run_phase_configs` via the installer command.
- [ ] **Step 4:** Run the full suites. Expected: pass.
- [ ] **Step 5:** Commit "Add dotfiles status".

---

### Task 7: `dotfiles push`

**Files:** create `lib/push.sh`. Modify `dotfiles`. Rewrite `test/run-remote-tests.sh`.

**Interfaces (`lib/push.sh`):**
- `push_ssh [-t] HOST CMD`: `ssh -o ConnectTimeout=10 $DOTFILES_SSH_OPTS [-t] HOST CMD`. `push_scp SRC HOST:DEST`: the same options for scp.
- `push_build_payload REPO OUT_TAR`:
  - If REPO is a git work tree, run `git -C REPO archive --format=tar HEAD -o OUT_TAR`.
  - Otherwise, `tar -C REPO -cf OUT_TAR --exclude=./PUSHED .`.
  - Either way, append a `PUSHED` file (`tar -rf`) containing `source=<hosts_local_name> commit=<sha or none> date=<date -u +%Y-%m-%dT%H:%M:%SZ>`.
- `push_remote_paths HOST`: one ssh call running a POSIX `sh` snippet. The snippet reads `${DOTFILES_CONFIG:-$HOME/.config/dotfiles/config}` on the remote for the `dotfiles_repo`/`hosts_repo` lines and prints two lines, `dotfiles_repo=<abs path>` and `hosts_repo=<abs path>`, defaulting to `$HOME/.local/share/dotfiles/{dotfiles,dotfiles-hosts}` and expanding a leading `~`. Parse those lines locally.
- `push_host HOST INIT(true|false)`:
  1. Build the payloads in `$WORK_DIR/push`: `dotfiles.tar` always, and `hosts.tar` when `HOSTS_REPO` is set.
  2. Get the remote paths.
  3. In one ssh call, check `[ -e <path>/.git ]` for each target; if it is a git checkout, log the spec's message and return 1.
  4. `mkdir -p` a remote temp dir (`mktemp -d` on the remote).
  5. scp the tars there.
  6. In one ssh call, for each tar: `mkdir -p "$(dirname P)" && rm -rf P.new && mkdir P.new && tar -xf T -C P.new && rm -rf P.old && { [ -e P ] && mv P P.old || true; } && mv P.new P && rm -rf P.old`, then remove the temp dir.
  7. `push_ssh -t HOST "<remote dotfiles_repo>/dotfiles sync --no-pull"`. Sub-project 3 adds `init`; for now, INIT=true is an error.
  8. Return the remote exit code.
- `dotfiles push [--dry-run] HOST...`: needs at least one HOST (usage error otherwise). It runs `resolve_settings` to find `DOTFILES_REPO`/`HOSTS_REPO`, runs no local sync and takes no lock. For each host it calls `push_host` and adds `RESULTS+=("<host>|push|ok/FAIL")`. Then it prints the summary and exits 1 if any host failed.
  - `--dry-run`: builds the payload, prints `Would push <tar> (<size>) to HOST:<path>` (this still calls `push_remote_paths`), and runs `ssh -t HOST "<repo>/dotfiles sync --no-pull --dry-run"` only if the remote repo already exists. Otherwise it prints `Would run dotfiles sync on HOST`.

**Tests (`test/run-remote-tests.sh`, Docker):**
- Keep Test 0.
- Export `DOTFILES_SSH_OPTS="-o Port=2222 -o IdentityFile=$SCRIPT_DIR/ssh-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"`.
- Run every push with a sandboxed local config: `DOTFILES_CONFIG=/tmp/push-cfg` containing `hosts_repo=<fixture copy>`. Run them from the worktree, with `HOME` sandboxed locally so the local side never self-installs into the real HOME. `push` doesn't self-install locally anyway, but sandbox it all the same.

| # | Test |
|---|---|
| P1 | Fresh container: `rm -rf ~/.local/share/dotfiles ~/.config/dotfiles ~/.claude`. Write a remote config `~/.config/dotfiles/config` with `hostname=testhost`, and seed `~/.claude/settings.json` with `{"liveOnly":1}`. Then `./dotfiles push testuser@localhost` exits 0. On the remote: `~/.local/share/dotfiles/dotfiles/dotfiles` exists, `~/.local/share/dotfiles/dotfiles-hosts/hosts/testhost/host.yaml` exists, the `PUSHED` file has `commit=`, `jq .liveOnly` is 1, `jq .hostKey` is `testhost`, `~/.claude/statusline-command.sh` is `# host statusline`, and the remote has `~/.local/bin/dotfiles` and `~/.bashrc.d/90-dotfiles.sh` (self-install ran on the remote). |
| P2 | Second push after a file is removed: create a local throwaway commit-free scenario by pushing from a temp non-git copy of the worktree with an extra file `EXTRA`, then pushing again from the worktree. `EXTRA` is gone on the remote, and the remote `PUSHED` shows the worktree commit. |
| P3 | Refusal: `mkdir -p ~/.local/share/dotfiles/dotfiles/.git` on the remote. Push exits 1 with output containing `is a git checkout`, and the remote dir is unchanged. Clean up afterwards. |
| P4 | `--dry-run` prints `Would push` and changes nothing on the remote (the `PUSHED` mtime is unchanged). |
| P5 | Push with no HOST gives a usage error (exit 1); this is a local test, so put it in test-sync or a new `test/apps/test-push.sh`. Push to an unreachable host (`testuser@localhost` with `-o Port=1`) gives exit 1 and `localhost|push FAILED`-style summary output. |

Delete the old Tests 14–15 content (the `--stage` and `setup.sh --host` versions); P1 supersedes them. Update the banner count.

- [ ] **Step 1:** Write the tests (`test/run-remote-tests.sh` and `test/apps/test-push.sh` for the local cases).
- [ ] **Step 2:** Run `bash apps/test-push.sh`. Expected: FAIL (no `push` command).
- [ ] **Step 3:** Implement `lib/push.sh` and the `push` command, and update `usage`.
- [ ] **Step 4:** Rebuild and start the Docker env using the shim note in Global Constraints, run `./run-remote-tests.sh` in full, then run `test/cleanup-test-env.sh`. Then run the local suites. Expected: all pass.
- [ ] **Step 5:** Commit "Add dotfiles push: ship committed repo snapshots over ssh and sync remotely".

---

### Task 8: Docs and usage

**Files:** modify `docs/schema.md` and the `usage` text in `dotfiles`.

- [ ] **Step 1:** Update `docs/schema.md`:
  - Add a "Commands" section: `sync`, including `--auto`/`--no-pull`; `push`; `status`; `uninstall`; `verify`. Note the self-install.
  - Add a "Background sync" section: the drop-in, the throttle, config-only behavior, the report lines, the state dir files, and how to turn it off (`auto_sync=off`, or `DOTFILES_NO_AUTO_SYNC=1` for one shell).
  - Add an "Undoing a change" section: `git revert` and push, or `git checkout <old> && dotfiles sync --no-pull`.
  - Add a "Backups" section: originals plus snapshots in `~/.bak/<app>/<timestamp>/`, copied back by hand; no rollback command.
  - Make sure no reference to `setup.sh`, `--host`, `--hosts-file`, `rollback` or `backups` remains (`grep`).
- [ ] **Step 2:** Make `dotfiles help` list every command and flag from the spec. Add a test-setup assertion that `dotfiles help` mentions `sync`, `push`, `status`, `--auto` and `--no-pull`.
- [ ] **Step 3:** Run the full local suites. Expected: pass.
- [ ] **Step 4:** Commit "Document dotfiles commands, background sync, backups and undo".
