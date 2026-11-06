# Handoff — dotfiles-hosts / sync / bootstrap work (state as of 2026-11-03)

Read this first when resuming. Sub-projects 1–3 are merged and on `origin/main`.

## Where things are

| What | Where |
|---|---|
| Dotfiles | `/home/david/git/dotfiles`, branch `main`. Check `git status -sb` for commits not yet pushed. The feature branch and worktree are gone. |
| Personal hosts repo | `git@github.com:dahoff/dotfiles-hosts.git` (private), checked out at `/home/david/git/dotfiles-hosts`. Holds `profiles/personal.yaml` (`extends: complete`, turns on the Claude rate limit bars) and `hosts/koi/host.yaml` (`profile: personal`). |
| Work hosts repo | The user creates and manages it. Claude has no access to it. It needs its own profile setting `CLAUDE_STATUS_RATE_LIMITS` to `"0"`: `merge` never deletes live keys, so leaving it out does not guarantee off. |
| This machine (koi) | `~/.config/dotfiles/config.yaml` didn't exist when last checked, so `dotfiles sync` doesn't use the hosts repo here until `dotfiles init` has run. |

## The three sub-projects

1. **Sub-project 1: dotfiles-hosts overlays and merge.** DONE and merged to local `main`.
   - Spec: `docs/superpowers/specs/2026-09-30-dotfiles-hosts-design.md`
2. **Sub-project 2: the `dotfiles` command (sync, `--auto` background sync, push, status).** DONE and pushed. It passed per-task reviews, a final review (opus) and a fix wave. Core tests 34/34, app tests 14/14, and the Docker push suite pass.
   - Spec: `docs/superpowers/specs/2026-10-01-dotfiles-sync-push-design.md`. Its **"Revisions (2026-10-02)"** section at the end overrides earlier text.
   - Plan (executed): `docs/superpowers/plans/2026-10-01-dotfiles-sync-push.md`
3. **Sub-project 3: `bootstrap.sh`, `dotfiles init`, `dotfiles push --init`.** DONE and pushed (Tasks 1–4), after the revisions plan R1–R3 (`docs/superpowers/plans/2026-10-02-dotfiles-sync-revisions.md`, also DONE). Final review of `763c17e..aab5003` (opus) plus one fix wave (`e990448`). Core 34/34, apps 16/16, Docker P1–P7 and PI1–PI4 pass.
   - Spec: `docs/superpowers/specs/2026-10-01-dotfiles-bootstrap-init-design.md`
   - Plan: `docs/superpowers/plans/2026-10-01-dotfiles-bootstrap-init.md` (Tasks 1–4)

## Next steps

1. Try bootstrap on a fresh machine with a real terminal. The `/dev/tty` path has no automated test.
2. Open design decisions are listed under "Open questions for the user".

## Decisions the user made (2026-10-01/02)

- **Background sync** is triggered from a `~/.bashrc.d/90-dotfiles.sh` drop-in, which the user calls "a function in bashrc". It is throttled (default 4h), deploys configs only, and leaves a one-time report at the next terminal.
- **Packages needing sudo:** option A, as above.
- **Repo locations:** default `~/.local/share/dotfiles/{dotfiles,dotfiles-hosts}`. This machine keeps `~/git/...`.
- **Push** sends committed `HEAD` (`git archive`) and runs a full interactive sync remotely.
- **CLI:** `setup.sh` was renamed to `dotfiles`. Commands are `sync`, `push`, `status`, `uninstall`, `verify` and `help`. `deploy`, `install` and `upgrade` were dropped at the top level.
- **Backups:** keep originals and pre-upgrade snapshots. Drop `rollback`, `backups` and checksums. Undo happens in git.
- **Config:** YAML. No `dotfiles_repo` key. `hosts_dir` is "just a directory".
- **Other assumptions:** everything else listed to the user (precedence, lock behaviour, throttle restarting even after a failed run, `updated` semantics, push refusals, status contents, the sub-project 3 init flow) was accepted as written.

## Layout since 2026-11-03

One folder per tool, per `docs/superpowers/specs/2026-11-03-apps-install-merge-design.md`: `apps/<name>/` holds `config.yaml` (with `install:`), `install.sh` (the tool) and `configure.sh` (its config). `apps/os-packages.yaml` defines package-only tools. Profiles list names. `packages/` is gone. Older specs and plans still describe the previous layout.

**At upgrade, one failed sync per machine is expected (the user accepted this).** `sync` pulls and then keeps running the old code in memory, so the first sync after this ships stops with `No packages found` and changes nothing. A second sync works. Each machine then redeploys its apps once, because the version hash covers `configure.sh` and `config.yaml`.

## Rulings made autonomously (cost if wrong)

- **Sub-project 2 rulings:**
  - A failed pull is a warning and exits 0. Cost: none.
  - Forced `-c merge.autoStash=false -c rebase.autoStash=false -c pull.rebase=false` on pulls. Cost: none.
  - `auto_sync_interval: 0m` means always sync. Cost: none.
  - Push refuses remote targets that aren't a previously pushed copy (no `PUSHED` marker) and aren't empty. Cost: a stale copy may need manual cleanup.
  - The drop-in's launcher output goes to `<state>/launch.log`. Cost: one small file.
  - A config error under `--auto` is reported as `sync failed (config)`, throttled by a fixed 4h. Cost: an error is reported at most every 4h.
- **Sub-project 1 ruling:** merge semantics are `live ⊕ (repo layers pre-merged)`. Cost: one jq edge case differs from strict left-to-right merging.

## Known minor issues (not blocking)

- A relative `hosts_dir` / old relative `dotfiles_repo` edge case. Moot after R1 for `dotfiles_repo`.
- A config error while the config also says `auto_sync: off` still runs one background report.
- A pull killed by the timeout may show an empty reason.
- `init` doesn't re-prompt for a hostname with no `hosts/<name>/`; it lists the available ones instead.
- The push snippet parses `#a #b` differently from `config_load`; the difference only affects a warning.
- A dangling link target is accepted when its directory has `lib/`; the refusal guard still protects it.
- test-sync Case 25 is skipped on hosts without `setsid` when run from a terminal.
- A sudoers rule granting NOPASSWD for apt-get without SETENV refuses background apt. It fails closed: packages stay pending.

## Practical notes for whoever implements

- **Docker tests:** `docker-compose` v1 is broken on this machine. Use a shim at `/tmp/dcshim/docker-compose` containing `exec docker compose "$@"`, put on PATH only for those commands, never in `~/.local/bin`. `test/setup-test-env.sh` generates the test SSH key. Run `test/cleanup-test-env.sh` (not `--full`) afterwards.
- **Test isolation:** tests must never touch the real HOME. Set `HOME`, `XDG_STATE_HOME`, `STATE_DIR` and `DOTFILES_CONFIG` to temp paths, and unset the hosts env var.
- **Commits:** never add a `Co-Authored-By` or any Claude attribution trailer (user preference). Use `git add <explicit paths>`.
- **Suites:** run from `test/`: `./run-core-tests.sh`, `./run-app-tests.sh`, and `./run-remote-tests.sh` (Docker).

## Rulings made 2026-10-02 (evening: revisions R1–R3 and sub-project 3)

- **`push --init` and `--hosts-dir`:** it omits `--hosts-dir` when no hosts payload is shipped; the spec said to forward `none`. This keeps a remote's configured `hosts_dir`. Cost: clearing a remote hosts_dir needs an interactive init.
- **`init` and the profile line:** `init` keeps an uncommented configured profile, or `--profile`, even when host.yaml exists, because an explicit profile overrides host.yaml at sync time (`lib/profile.sh`). The line is commented only otherwise.
- **`sync --auto` and sudo:**
  - It installs only when `sudo -n true` works **and** `/dev/tty` can't be opened.
  - apt and dnf use `sudo -n`, and custom installers get a `sudo -n` shim.
  - `DOTFILES_TEST_HAS_TTY=1` is a test hook. It can only force check-only mode.
  - Consequence: without `setsid` (e.g. macOS) background sync never installs; it only reminds.
- **Background apt:** it runs `sudo -n DEBIAN_FRONTEND=noninteractive apt-get`. A sudoers rule that grants NOPASSWD for apt-get without SETENV refuses it. That fails closed: the packages stay pending.
- **Test-only package:** `packages/custom/testtool` and `files/50-testtool.sh` live in the real package tree. Only the `pendingtest` fixture profile references them.
- **Remote snippet:** its internal output key stays `dotfiles_repo=`.
- **Final review scope:** it covered `763c17e..aab5003` only, since SP2 was reviewed earlier.
- **Running tests:** the suites share `/tmp/home-test-localtest`. Never run two suites at the same time.
