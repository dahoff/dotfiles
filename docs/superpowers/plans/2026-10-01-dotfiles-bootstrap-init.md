# dotfiles bootstrap/init (sub-project 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three ways to set up a host:
- `dotfiles init`: guided per-host setup that writes `~/.config/dotfiles/config` and runs the first sync.
- `bootstrap.sh`: a one-command setup for a fresh machine. It installs git, clones dotfiles and runs `init`.
- `dotfiles push --init HOST`: first-time setup of a host without git.

**Architecture:** Init logic lives in `lib/init.sh`, dispatched from `dotfiles init` before settings are resolved, because there may be no config file or only a broken one. Prompts go through one `init_ask` helper. It reads `/dev/tty` normally, reads stdin when `DOTFILES_INIT_ASSUME_TTY=1` (tests only), and never prompts with `--yes`. `bootstrap.sh` is self-contained and uses no `lib/`. `push --init` reuses `push_host` and runs the remote `dotfiles init` with forwarded flags.

**Tech Stack:** Bash 4+, git, the existing test harness, and Docker for `push --init`.

**Spec:** `docs/superpowers/specs/2026-10-01-dotfiles-bootstrap-init-design.md`. It builds on `docs/superpowers/specs/2026-10-01-dotfiles-sync-push-design.md`.

## Global Constraints

- **Config file**: written to `${DOTFILES_CONFIG:-$HOME/.config/dotfiles/config}`, using the same keys and format as `lib/config.sh` reads: `dotfiles_repo`, `hosts_repo`, `hostname`, `profile`, `auto_sync`, `auto_sync_interval`.
  - Header comment: `# Written by dotfiles init on <date -u +%Y-%m-%d>`.
  - If an existing file differs from the new content, it is kept as `<config>.bak`.
  - The new file is written to `<config>.tmp` and then moved into place.
- **Default paths**:
  - Hosts repo clone target: `~/.local/share/dotfiles/dotfiles-hosts`.
  - Bootstrap clone target: `~/.local/share/dotfiles/dotfiles`.
- **Default bootstrap repo URL**: `https://github.com/dahoff/dotfiles.git`.
- **`init` flags**: `--hosts-repo URL|PATH|none`, `--hostname NAME`, `--profile NAME`, `--auto-sync on|off`, `--interval <n>m|h|d`, `--yes`, `--no-sync`.
- **Non-interactive runs**: if init isn't interactive and `--yes` isn't given, it exits 1 with `init is interactive; pass --yes to accept defaults`. "Interactive" means `[ -t 0 ]` or `DOTFILES_INIT_ASSUME_TTY=1`; prompts read `/dev/tty`.
- **Hosts repo values**: an argument is a URL if it contains `://` or matches `^[^/[:space:]]+@[^:/[:space:]]+:`. `none` means no hosts repo. Anything else is a path, which must be an existing directory.
- **Clone failure**: exit 1 and write nothing.
- **Tests never touch the real HOME or config.** They set HOME, `DOTFILES_CONFIG`, `XDG_STATE_HOME` and `STATE_DIR` to temp paths, and unset `DOTFILES_HOSTS_REPO`. Git origins are local bare repos under `/tmp`. Never use the network.
- **Commits**: `git add <explicit paths>`. NEVER add a Co-Authored-By or any Claude attribution trailer.
- **Test runs**: `cd test && ./run-core-tests.sh && ./run-app-tests.sh` must pass at the end of every task. For Docker (Task 3), put a shim at `/tmp/dcshim/docker-compose` that runs `docker compose`, never in `~/.local/bin`. `test/ssh-key` must be mode 600. Clean up with `test/cleanup-test-env.sh`.
- **Worktree**: work only in `/home/david/git/dotfiles/.claude/worktrees/sync-init`.

## Review Focus

1. **Re-running `init` on a configured host.** Each prompt's default must be the current config value, and nothing else changes when every answer is accepted. The `.bak` file is created only when the content differs. Tested in Task 1.
2. **`init --hosts-repo <URL>` when the default hosts path already holds a pushed (non-git) copy.** That is an error that names the path. It must never delete the copy. Tested in Task 1.
3. **`bootstrap.sh` piped from curl (`curl … | bash`).** Stdin is the script, so init must read answers from `/dev/tty`. When there is no tty, it must fall back to `--yes` instead of hanging. Tested in Task 2 via `DOTFILES_BOOTSTRAP_NO_TTY=1` and `</dev/null`.
4. **The hostname prompt receiving a value containing `/` or `..`.** It must be rejected exactly as `--hostname` is. Tested in Task 1.
5. **`push --init` to a host that already has a config.** Remote init must keep the existing values as defaults, so `--yes` doesn't wipe a hand-set `profile`. Tested in Task 3.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `lib/init.sh` | create | `init_main ARGS...`: parse flags, prompts, hosts repo clone/pull, config writing, first sync |
| `dotfiles` | modify | `init` command dispatched before `resolve_settings`; `push --init` plus init flag forwarding |
| `lib/push.sh` | modify | `push_host` INIT=true runs the remote `dotfiles init <flags>` |
| `bootstrap.sh` | create | standalone installer (git, clone or pull, exec init) |
| `test/apps/test-init.sh` | create | init tests |
| `test/apps/test-bootstrap.sh` | create | bootstrap tests |
| `test/run-remote-tests.sh` | modify | `push --init` Docker tests |
| `docs/schema.md` | modify | "Setting up a new machine" section |

---

### Task 1: `dotfiles init` (flags, `--yes`, config writing, hosts repo)

**Files:** create `lib/init.sh` and `test/apps/test-init.sh`. Modify `dotfiles` to add the `init` command, its usage, and dispatch right after `log_init`/`WORK_DIR` and before `resolve_settings`.

**Interfaces:**
- `init_main "$@"`. It exits the process with init's exit code.
- `init_ask VAR PROMPT DEFAULT`:
  - Under `--yes`, it sets VAR to DEFAULT.
  - Otherwise it prints `PROMPT [DEFAULT]: ` to stderr and reads one line, from stdin if `DOTFILES_INIT_ASSUME_TTY=1`, else from `/dev/tty`. An empty answer means DEFAULT. EOF means exit 1 with `init: no answer for '<PROMPT>'`.
- `init_validate_hostname NAME`: the same rules as `--hostname` in `dotfiles` `parse_args`: non-empty, no `/`, not `.` or `..`.
- `init_write_config FILE`: uses the globals `INIT_HOSTS_REPO`, `INIT_HOSTNAME`, `INIT_PROFILE`, `INIT_PROFILE_COMMENTED`, `INIT_AUTO_SYNC`, `INIT_INTERVAL` and `DOTFILES_REPO`. It writes this layout, with the dotfiles repo always set:

```
# Written by dotfiles init on 2026-10-01
dotfiles_repo=/abs/path
hosts_repo=/abs/path            # or: # hosts_repo=   (when none)
hostname=koi
profile=complete                # or: # profile=complete  (host.yaml selects the profile)
auto_sync=on
auto_sync_interval=4h
```

**Flow:**
1. Parse the flags. An unknown flag is a usage error (exit 1).
2. Check that init is interactive: `[ -t 0 ]`, or `DOTFILES_INIT_ASSUME_TTY=1`, or `--yes`. If none applies, exit 1 with the exact message from the Global Constraints.
3. Load defaults with `config_load` on the existing config if there is one; a load error means warn and use defaults. Then fill:
   - hosts repo: the configured value, else the default path if it exists, else `none`
   - hostname: the configured value, else `hosts_local_name`
   - profile: the configured value, else `complete`
   - auto sync: `on`
   - interval: `4h`
4. Flags override defaults. Interactive runs prompt for every value not given as a flag, in this order: hosts repo, hostname, profile (only if no host.yaml), auto sync, interval.
5. **Hosts repo:**
   - `none` leaves it empty.
   - A URL clones to the default path. If the target already exists:
     - a git checkout whose `remote.origin.url` matches the URL is pulled with `--ff-only`; a failure is only a warning
     - any other existing target is an error naming the path, telling the user to pass `--hosts-repo <path>` or `none`. Nothing is deleted.

     Clone with `GIT_TERMINAL_PROMPT=0` when `--yes`. A clone failure exits 1.
   - A path must be a directory. Store it as an absolute path.

   Interactive runs re-prompt on an invalid value; `--yes` exits 1.
6. **Hostname:** validate it, re-prompting or exiting on failure. If a hosts repo is set:
   - if `hosts/<name>/host.yaml` exists, print `hosts/<name>/host.yaml found (profile: <hosts_read_scalar profile>)`
   - otherwise print `no hosts/<name>/ in <repo>; available: a, b` (or `none`)
7. **Profile:** only asked when there is no host.yaml. It must resolve via `hosts_resolve_profile_path` with the dotfiles `profiles/` and the hosts repo; it is an error if the file is missing. When a host.yaml exists, the profile line is written commented.
8. **Auto sync:** `on` or `off`. **Interval:** validated with `config_interval_seconds`.
9. Write the config following the Global Constraints. Print `Wrote <config>` and, when a backup was made, `previous config saved as <config>.bak`.
10. Unless `--no-sync`, run `"$DOTFILES_REPO/dotfiles" sync` as a child process with stdin inherited. Init's exit code is the sync's exit code.
11. Closing lines: `dotfiles: <host> configured (profile <p> | host.yaml)`. Add `background sync every <interval>` or `background sync off`.

- [ ] **Step 1:** Write `test/apps/test-init.sh` with a sandbox and a /tmp copy of the fixture hosts repo. Also create a bare git repo of the fixture (`git init`, commit, `git clone --bare`) for URL tests. Cases:
  1. Without a tty, run `dotfiles init </dev/null`. Expect exit 1 and the message from the Global Constraints.
  2. `init --yes --no-sync --hosts-repo <fixture path> --hostname testhost`. Expect:
     - exit 0
     - the config contains `hosts_repo=<abs>`, `hostname=testhost`, `auto_sync=on` and `auto_sync_interval=4h`
     - a commented `# profile=` line
     - `dotfiles_repo=<worktree>`
     - the output mentions `host.yaml found (profile: base)`
  3. `--hosts-repo none --profile minimal --auto-sync off --interval 2h`. Expect `# hosts_repo=`, `profile=minimal`, `auto_sync=off` and `auto_sync_interval=2h`.
  4. Re-run case 2's command. Expect no `.bak` (the content is the same apart from the header date, which is the same day). Then re-run with `--interval 1h`. Expect a `.bak` holding the old content.
  5. With an existing config containing `profile=minimal` and `hostname=nohost`, run `init --yes --no-sync --hosts-repo none`. Expect the new config keeps `profile=minimal` and `hostname=nohost`.
  6. Run with `--hosts-repo file:///<bare>.git` against an empty default path. Expect the clone at `$HOME/.local/share/dotfiles/dotfiles-hosts` with `hosts/testhost/host.yaml` present, and `hosts_repo` set to that path. Re-run it and expect a pull, exit 0.
  7. Put a non-git dir with a `PUSHED` file at the default path, then run `--hosts-repo file:///<bare>.git`. Expect exit 1, the path named in the error, the dir untouched, and no config written.
  8. Expect exit 1 for each of `--hostname ../x`, `--interval 10x`, `--profile nope` (with no host.yaml) and `--hosts-repo /nonexistent`.
  9. Without `--no-sync`: `init --yes --hosts-repo <fixture> --hostname testhost`. Expect exit 0 and `~/.claude/settings.json` deployed in the sandbox HOME (the base profile is config-only).
  10. Interactive via stdin: run `DOTFILES_INIT_ASSUME_TTY=1 dotfiles init --no-sync` and feed answers with `printf '%s\n' "<fixture>" "testhost" "" ""`, accepting the defaults for auto sync and interval. Expect exit 0, `hostname=testhost`, and the prompts (on stderr) to contain `[4h]`. Feed `"../bad"` and then `"testhost"` for the hostname and expect a re-prompt that succeeds. Short input (EOF) gives exit 1.
- [ ] **Step 2:** Run it. Expect a FAIL (`init` is an unknown command).
- [ ] **Step 3:** Implement `lib/init.sh` and the dispatch.
- [ ] **Step 4:** Run `bash test/apps/test-init.sh`, then the full suites. Everything should pass.
- [ ] **Step 5:** Commit with the message "Add dotfiles init: guided per-host config and first sync".

---

### Task 2: `bootstrap.sh`

**Files:** create `bootstrap.sh` (executable, repo root) and `test/apps/test-bootstrap.sh`.

**Behavior:** follows the spec's `bootstrap.sh` section, with these specifics:
- Arguments:
  - `--repo URL` and `--dir PATH` are consumed.
  - Env `DOTFILES_REPO_URL` and `DOTFILES_DIR` set defaults.
  - Everything else, with or without a leading `--`, is passed to init.
- **No git:** detect `apt-get`, `dnf` or `brew`. The install command is:
  - apt-get: `sudo apt-get update -qq && sudo apt-get install -y -qq git`
  - dnf: `sudo dnf install -y -q git`
  - brew: `brew install git`

  With `DOTFILES_BOOTSTRAP_DRY=1`, print `bootstrap: would run: <cmd>` and exit 0 without cloning. If no package manager is found, exit 1 with `bootstrap: git is required; install it and re-run`.
- **Clone or pull:**
  - Dir absent: `git clone "$URL" "$DIR"`, creating parent dirs first.
  - Dir is a git checkout: `git -C "$DIR" pull --ff-only`. A failure prints a warning and continues.
  - Dir exists but is not a checkout: exit 1 naming the dir.
- **Exec init:**
  - If `DOTFILES_BOOTSTRAP_NO_TTY` is unset and `/dev/tty` can be opened (`{ : </dev/tty; } 2>/dev/null`), run `exec "$DIR/dotfiles" init "${args[@]}" </dev/tty`.
  - Otherwise run `exec "$DIR/dotfiles" init --yes "${args[@]}"`. Don't add `--yes` twice.
- The script starts with `set -euo pipefail` and prints `bootstrap: ...` progress lines to stderr.

- [ ] **Step 1:** Write `test/apps/test-bootstrap.sh`. Use a sandbox, a bare origin made from the worktree with the code currently on disk (rsync into a clone, then commit "wip" and push, as in `test-sync.sh`), and `DOTFILES_BOOTSTRAP_NO_TTY=1`. Cases:
  1. `bash bootstrap.sh --repo file://<bare> --dir $HOME/df -- --no-sync --hosts-repo none`. Expect exit 0, `$HOME/df/dotfiles` executable, and a config with `dotfiles_repo=$HOME/df`.
  2. Re-run the same command. Expect exit 0 and output containing `pull` (no re-clone).
  3. A `--dir` that exists but isn't a checkout. Expect exit 1 naming the dir.
  4. Arguments without `--` are passed through. `bash bootstrap.sh --repo … --dir … --no-sync --hosts-repo none --hostname bt` should produce `hostname=bt`.
  5. No git: build a PATH dir with symlinks to everything in `/usr/bin` and `/bin` except `git`, then run `DOTFILES_BOOTSTRAP_DRY=1 PATH=<dir> bash bootstrap.sh`. Expect exit 0 and output containing `would run:` plus `install` and `git`.
  6. Piped stdin: `cat bootstrap.sh | DOTFILES_BOOTSTRAP_NO_TTY=1 bash -s -- --repo … --dir $HOME/df2 --no-sync --hosts-repo none` should exit 0 and write a config (the `--yes` fallback).
- [ ] **Step 2:** Run it and expect a FAIL. **Step 3:** Implement. **Step 4:** Run the test and the full suites. **Step 5:** Commit with the message "Add bootstrap.sh: install git, clone dotfiles, run init".

---

### Task 3: `dotfiles push --init`

**Files:** modify `dotfiles` (flag parsing for push and forwarding of init flags), `lib/push.sh` (`push_host` with INIT=true) and `test/run-remote-tests.sh`. Add a local case to `test/apps/test-push.sh`.

**Behavior:**
- `dotfiles push --init [--yes] [--hostname N] [--profile P] [--auto-sync on|off] [--interval I] HOST...`. The init flags are accepted only together with `--init`; otherwise they are a usage error.
- `push_host HOST true` runs the normal payload, refusal and unpack steps. It then runs `push_ssh -t HOST "<rdot>/dotfiles init --hosts-repo <rhosts|none> <forwarded flags>"`. Every value is quoted with `push_quote`. `<rhosts>` is used only when a hosts payload was shipped; otherwise pass `none`.
- `--dry-run --init` prints `Would run dotfiles init on HOST`.

**Docker tests:**
- **PI1:** Fresh container (`rm -rf ~/.local/share/dotfiles ~/.config/dotfiles ~/.claude ~/.bashrc.d/90-dotfiles.sh ~/.local/bin/dotfiles`). Run `./dotfiles push --init --yes --hostname testhost testuser@localhost` and expect exit 0. On the remote:
  - the config has `hostname=testhost`, `hosts_repo=/home/testuser/.local/share/dotfiles/dotfiles-hosts`, `dotfiles_repo=/home/testuser/.local/share/dotfiles/dotfiles` and `auto_sync=on`
  - `~/.claude/statusline-command.sh` is `# host statusline`, which shows the sync ran
  - `~/.bashrc.d/90-dotfiles.sh` exists
- **PI2:** Re-run with only `--init --yes` and no `--hostname`. The remote config still has `hostname=testhost` (existing values are kept as defaults), and `config.bak` is absent or identical to the config apart from the header.
- **PI3:** `--init` with `--yes` but an invalid `--interval 10x` exits 1, and the remote config is unchanged.
- **Local (test-push.sh):** `dotfiles push --hostname x HOST`, without `--init`, gives a usage error.

- [ ] **Step 1:** Write the tests. **Step 2:** Run the local test and expect a FAIL. **Step 3:** Implement. **Step 4:** Run the full Docker suite once, clean up, then run the local suites. **Step 5:** Commit with the message "Add dotfiles push --init for first-time setup of hosts without git".

---

### Task 4: Docs

**Files:** modify `docs/schema.md` and `dotfiles` usage. The test-setup help assertion should also check `init`.

- [ ] **Step 1:** Add a "Setting up a new machine" section to `docs/schema.md`. Cover:
  - the bootstrap one-liner, with `--hosts-repo` passed through
  - running `dotfiles init` again later
  - `push --init` for hosts without git
  - what init writes
  - re-running init safely
- [ ] **Step 2:** The usage text lists `init` and its flags, and `push --init`.
- [ ] **Step 3:** Run the full suites. **Step 4:** Commit with the message "Document bootstrap, init and push --init".
