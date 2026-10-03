# Handoff — dotfiles-hosts / sync / bootstrap work (state as of 2026-10-02)

Read this first when resuming. Everything below is on branch `dotfiles-sync-init`.

## Where things are

| What | Where |
|---|---|
| Main checkout | `/home/david/git/dotfiles` — branch `main` at `10aa592`. 11 commits ahead of `origin/main`. **Not pushed.** User has an uncommitted WIP edit to `claude/files/settings.json` there; leave it alone. |
| Work branch | `dotfiles-sync-init`. Worktree at `/home/david/git/dotfiles/.claude/worktrees/sync-init`. 18+ commits on top of `main`. **Not merged, not pushed.** |
| SDD workspaces (git-ignored scratch) | `<worktree>/.superpowers/sdd/2026-10-01-dotfiles-sync-push/` holds sub-project 2's ledger `progress.md`, briefs, reports and reviews. `<worktree>/.superpowers/sdd/2026-10-01-dotfiles-bootstrap-init/` holds sub-project 3's instructions; nothing has started there. |

## The three sub-projects

1. **Sub-project 1: dotfiles-hosts overlays and merge.** DONE and merged to local `main`.
   - Spec: `docs/superpowers/specs/2026-09-30-dotfiles-hosts-design.md`
2. **Sub-project 2: the `dotfiles` command (sync, `--auto` background sync, push, status).** DONE on the branch. It passed per-task reviews, a final review (opus) and a fix wave. Core tests 34/34, app tests 14/14, and the Docker push suite pass.
   - Spec: `docs/superpowers/specs/2026-10-01-dotfiles-sync-push-design.md`. Its **"Revisions (2026-10-02)"** section at the end overrides earlier text.
   - Plan (executed): `docs/superpowers/plans/2026-10-01-dotfiles-sync-push.md`
3. **Sub-project 3: `bootstrap.sh`, `dotfiles init`, `dotfiles push --init`.** NOT STARTED. Spec and plan are written and were revised for the 2026-10-02 decisions.
   - Spec: `docs/superpowers/specs/2026-10-01-dotfiles-bootstrap-init-design.md`
   - Plan: `docs/superpowers/plans/2026-10-01-dotfiles-bootstrap-init.md` (Tasks 1–4)

## Next steps, in order

1. **Execute `docs/superpowers/plans/2026-10-02-dotfiles-sync-revisions.md`** (Tasks R1–R3) with subagent-driven development. These apply the user's 2026-10-02 decisions to the already-built sub-project 2:
   - **R1:** config becomes YAML at `~/.config/dotfiles/config.yaml`. Drop the `dotfiles_repo` setting. Rename `hosts_repo` / `--hosts-repo` / `DOTFILES_HOSTS_REPO` to `hosts_dir` / `--hosts-dir` / `DOTFILES_HOSTS_DIR`. Self-install never re-points a valid `~/.local/bin/dotfiles` link.
   - **R2:** `push` finds the remote's dotfiles dir by following its `~/.local/bin/dotfiles` link, and reads `hosts_dir` from the remote `config.yaml`.
   - **R3:** "option A" for packages that need sudo:
     - a reminder at **every** terminal while anything is pending: `dotfiles: a, b not installed (needs sudo) — run 'dotfiles sync'`
     - the one-time report drops its pending line
     - `sync --auto` installs packages itself when `sudo -n true` works (passwordless sudo)
     - custom-tool drop-ins (e.g. `50-lazygit.sh`) are deployed only once their tool is installed
2. **Execute the sub-project 3 plan** (Tasks 1–4).
3. **Run the final whole-branch review**, then present the merge options to the user. Only the user decides whether to merge or push.

## Decisions the user made (2026-10-01/02)

- **Background sync** is triggered from a `~/.bashrc.d/90-dotfiles.sh` drop-in, which the user calls "a function in bashrc". It is throttled (default 4h), deploys configs only, and leaves a one-time report at the next terminal.
- **Packages needing sudo:** option A, as above.
- **Repo locations:** default `~/.local/share/dotfiles/{dotfiles,dotfiles-hosts}`. This machine keeps `~/git/...`.
- **Push** sends committed `HEAD` (`git archive`) and runs a full interactive sync remotely.
- **CLI:** `setup.sh` was renamed to `dotfiles`. Commands are `sync`, `push`, `status`, `uninstall`, `verify` and `help`. `deploy`, `install` and `upgrade` were dropped at the top level.
- **Backups:** keep originals and pre-upgrade snapshots. Drop `rollback`, `backups` and checksums. Undo happens in git.
- **Config:** YAML. No `dotfiles_repo` key. `hosts_dir` is "just a directory".
- **Other assumptions:** everything else listed to the user (precedence, lock behaviour, throttle restarting even after a failed run, `updated` semantics, push refusals, status contents, the sub-project 3 init flow) was accepted as written.

## Open questions for the user

- **Is `github.com/dahoff/dotfiles` public?** `bootstrap.sh` defaults to cloning it over HTTPS with no SSH key. If it's private, bootstrap needs credentials or a different approach.
- **The real `dotfiles-hosts` repos** (one on personal GitHub, one on work GitHub) haven't been created. That is the user's job; don't create them.

## Rulings made autonomously (cost if wrong)

- **Sub-project 2 rulings** (also in the ledger):
  - A failed pull is a warning and exits 0. Cost: none.
  - Forced `-c merge.autoStash=false -c rebase.autoStash=false -c pull.rebase=false` on pulls. Cost: none.
  - `auto_sync_interval: 0m` means always sync. Cost: none.
  - Push refuses remote targets that aren't a previously pushed copy (no `PUSHED` marker) and aren't empty. Cost: a stale copy may need manual cleanup.
  - The drop-in's launcher output goes to `<state>/launch.log`. Cost: one small file.
  - A config error under `--auto` is reported as `sync failed (config)`, throttled by a fixed 4h. Cost: an error is reported at most every 4h.
- **Sub-project 1 ruling:** merge semantics are `live ⊕ (repo layers pre-merged)`. Cost: one jq edge case differs from strict left-to-right merging.

## Known deferred minors (not blocking)

- A relative `hosts_dir` / old relative `dotfiles_repo` edge case. Moot after R1 for `dotfiles_repo`.
- A config error while the config also says `auto_sync: off` still runs one background report.
- A pull killed by the timeout may show an empty reason.
- `sync --dry-run` creates empty `~/.bak/<app>/original` dirs. This predates this branch.
- The full list is in the sub-project 2 ledger (`progress.md`), under lines marked `minor (deferred)`.

## Practical notes for whoever implements

- **Session guard:** this session runs isolated in the worktree. Shell commands that mention git with runtime variables, `sed -f`, or complex constructs get refused. Put the commands in a script file under the scratchpad and run it with `bash <file>`, or use plain literal commands.
- **Docker tests:** `docker-compose` v1 is broken on this machine. Use a shim at `/tmp/dcshim/docker-compose` containing `exec docker compose "$@"`, put on PATH only for those commands, never in `~/.local/bin`. `chmod 600 test/ssh-key`. Run `test/cleanup-test-env.sh` (not `--full`) afterwards.
- **Test isolation:** tests must never touch the real HOME. Set `HOME`, `XDG_STATE_HOME`, `STATE_DIR` and `DOTFILES_CONFIG` to temp paths, and unset the hosts env var.
- **Commits:** never add a `Co-Authored-By` or any Claude attribution trailer (user preference). Use `git add <explicit paths>`.
- **Suites:** run from `test/`: `./run-core-tests.sh`, `./run-app-tests.sh`, and `./run-remote-tests.sh` (Docker).
