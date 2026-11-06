# Updates and Local Edits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `sync` and the background deploy with `pull`, `add` and `sync` commands that apply updates safely, hold back conflicts, and save local edits to a chosen layer.

**Architecture:** Deploys read committed repo content only. Each managed file gets two saved copies, a repo copy and a review copy, under `$STATE_DIR/records/<app>/`. `pull` runs a three-way decision per file or per JSON key, and `add` reviews what changed since the review copy.

**Tech Stack:** bash 4+, jq, git. Tests are standalone scripts in `test/apps/`.

**Spec:** `docs/superpowers/specs/2026-11-06-updates-and-local-edits-design.md`

## Global Constraints

- Work in a worktree: `git worktree add .worktrees/updates-and-local-edits -b updates-and-local-edits`, as `~/.claude/CLAUDE.md` requires. The spec and this plan are untracked in the main checkout, so copy them in and commit them first.
- Never add a `Co-Authored-By` or Claude attribution line to commits.
- `add` stages only. Nothing in this work commits or pushes for the user.
- Only committed repo content deploys, except a repo with no git, which deploys as it stands.
- Saved copies are mode `0600`, in directories of mode `0700`.
- JSON paths are always path arrays, never dot-joined strings.
- Existing hosts don't migrate in place: `init` starts fresh records.
- The work hosts repo is out of scope: never access, set up or test it.
- Test thoroughly: the listed tests are a minimum. Each task also tests the edge cases of its own behaviour, including boundaries, empty and missing inputs, repeated runs and failures partway through, and each test asserts on the resulting files and records, not only on exit codes.

## Review Focus

- **JSON keys containing dots or `@`**, like `enabledPlugins.afk@dahoff`: treated as one key. Test in Task 4.
- **A live file that's a symlink**: written through, and the link stays. Test in Task 5.
- **Filenames containing spaces**: records and `add` handle them. Test in Task 5.
- **A repo with no commits, or a failed `git archive`**: `pull` stops and changes no live file, rather than deploying an empty tree. Test in Task 3.
- **The terminal closing during `add`**: EOF counts as skip, and no record changes. Test in Task 7.

---

### Task 1: New verbs

**Files:**
- Modify: `dotfiles`, `lib/push.sh`, `lib/init.sh`, `lib/versions.sh`, `lib/installer.sh:291`, `lib/login.sh:16`, `lib/add.sh`
- Test: `test/apps/test-sync.sh`, `test/apps/test-push.sh`, `test/apps/test-init.sh`, `test/apps/test-versions.sh`, plus the other suites that call `sync`

**Interfaces:**
- Produces: `dotfiles pull [--force] [--no-fetch] [--remote HOST...]`, `dotfiles init --remote HOST...`, `dotfiles sync`. `COMMAND` is `pull` wherever it was `sync`, and `INSTALLER_CMD` stays `deploy`.

- [ ] **Step 1: Write failing tests** in `test-sync.sh`:
  - `pull` deploys and `pull --no-fetch` skips the fetch.
  - `sync` with stdin not a terminal exits 1 and says it needs a terminal.
  - `sync` with `DOTFILES_ADD_ASSUME_TTY=1` runs `add`, then `pull`.
  - `sync --dry-run` runs `pull --dry-run` and prints that `add` was skipped.
  - `dotfiles push x` exits 1 and names `pull --remote` and `init --remote`.
  - `--no-pull` is rejected as an unknown option.

  In `test-push.sh`: `pull --remote HOST` and `init --remote HOST` replace the old forms, and `--force` reaches the remote command line.

- [ ] **Step 2: Run them and confirm they fail.** Run: `bash test/apps/test-sync.sh`. Expected: FAIL on `pull`.

- [ ] **Step 3: Rename `sync` to `pull` throughout `dotfiles`**, including `--no-pull` to `--no-fetch`, the usage text and user-facing messages. The messages at `lib/installer.sh:291`, `lib/login.sh:16`, `lib/push.sh:198` and `lib/versions.sh:179` say `dotfiles pull`. `lib/versions.sh:170` and `lib/init.sh:408` call `pull --no-fetch` and `pull`.

- [ ] **Step 4: Add `cmd_sync` to `dotfiles`.** It refuses without a terminal, runs `"$SCRIPT_DIR/dotfiles" add` with the layer flags as a child process, stops if that fails, then runs `pull` with all flags. Each child takes its own lock. `cmd_add` currently ends with `exit 0`, which is fine for a child.

- [ ] **Step 5: Parse `--remote` in `parse_args` and `init_main`.** It takes the following non-flag words as hosts and routes to `cmd_push`, with `PUSH_INIT=true` for `init`. Keep `lib/push.sh` as the file name. The remote command becomes `pull --no-fetch`, plus `--force` when given. `pull --remote` warns when `git rev-list --count HEAD..@{u}` is above 0 in either repo. The help text says it sends from this machine to the host.

- [ ] **Step 6: Replace `push` in `validate_command`** with an error naming both replacements.

- [ ] **Step 7: Update the other suites to the new verbs.** Run: `bash test/run-app-tests.sh`. Expected: all pass, apart from any that need Docker.

- [ ] **Step 8: Commit** with `Add pull and sync verbs; replace push with --remote`.

### Task 2: Update check replaces background sync

**Files:**
- Modify: `lib/login.sh`, `lib/sync.sh`, `lib/config.sh`, `lib/init.sh`, `lib/push.sh`, `dotfiles`
- Test: `test/apps/test-sync.sh`, `test/apps/test-config.sh`, `test/apps/test-init.sh`

**Interfaces:**
- Produces: internal command `dotfiles check-updates`, config keys `update_check` and `update_check_interval`, and init flag `--update-check on|off`. The old `auto_sync` keys still load as aliases, so an existing config keeps working. `--interval` stays. The drop-in's opt-out becomes `DOTFILES_NO_UPDATE_CHECK`.

- [ ] **Step 1: Write failing tests:**
  - With an upstream one commit ahead, `check-updates` writes a report containing `updates available` and `dotfiles pull`, and `HEAD` doesn't move.
  - No live file changes and no package command runs.
  - A second run inside the interval does nothing.
  - `update_check: off` does nothing.
  - A pinned repo, or one with no git or upstream, writes no report.
  - A failed fetch writes no report.
  - `pull --auto` is rejected.

- [ ] **Step 2: Run them and confirm they fail.** Run: `bash test/apps/test-sync.sh`.

- [ ] **Step 3: Implement `sync_check_updates`** in `lib/sync.sh`, using `sync_git_bounded` with `BatchMode=yes` to fetch, then `git rev-list --count HEAD..@{u}`. Throttle on `last-check`, and write the existing `report` file.

- [ ] **Step 4: Remove the old mode from `dotfiles`:** `--auto`, `SYNC_AUTO`, `CHECK_ONLY`, `SYNC_CAN_SUDO`, `SYNC_SUDO_SHIM`, `sync_make_sudo_shim`, `sync_has_tty` and `sync_write_report`'s sync content. Point `lib/login.sh` at `check-updates`. The init question becomes `Update check (on/off)`.

- [ ] **Step 5: Run the tests.** Run: `bash test/run-app-tests.sh`. Expected: all pass, with the tests of the removed mode deleted.

- [ ] **Step 6: Commit** with `Background check only reports updates; nothing deploys unasked`.

### Task 3: Deploy committed content; stop when a pull is blocked

**Files:**
- Modify: `lib/sync.sh`, `lib/profile.sh:622-640`, `lib/add.sh`, `dotfiles`
- Test: `test/apps/test-sync.sh`, `test/apps/test-status.sh`, plus any suite that deploys uncommitted fixture edits

**Interfaces:**
- Produces: `repo_committed_tree PATH` prints an export of `HEAD`, or `PATH` itself for a repo with no git. It returns 1 if a git repo can't be exported. `repo_warn_dirty PATH` warns and names uncommitted files. `sync_pull_repo` returns 2 when the pull is blocked (diverged, or local changes would be overwritten) and 1 for other failures.
- Consumes: `prepare_overlays` sets `LAYER_ROOTS`, `APPS_DIR` and the strategy sources from the export. `HOSTS_DIR` and `DOTFILES_REPO` stay real paths, because `add` writes to those.

- [ ] **Step 1: Write failing tests:**
  - An uncommitted change to a layer file doesn't deploy, and `pull` and `status` name that file and say it isn't deployed.
  - A staged save followed by `git reset --hard` leaves the live file unchanged on the next `pull`.
  - A repo with no commits makes `pull` exit 1 and changes no live file.
  - Upstream changing a file that's staged locally makes `pull` exit 1, deploy nothing and print `git pull --rebase`.
  - Diverged repos do the same.
  - A network failure still warns and deploys `HEAD`.
  - A dirty repo can still stop early.

- [ ] **Step 2: Run them and confirm they fail.** Run: `bash test/apps/test-sync.sh`.

- [ ] **Step 3: Implement `repo_committed_tree`** with `git archive HEAD | tar -x` into `$WORK_DIR`, applying the rooted-repo check from `sync_pull_repo`.

- [ ] **Step 4: Classify pull failures.** Run git with `LC_ALL=C` and treat `would be overwritten`, `Not possible to fast-forward` and `diverg` as blocked. In `main`, a blocked pull prints commit, `git pull --rebase`, push and `dotfiles pull` with the repo path, then exits 1.

- [ ] **Step 5: Change `sync_fingerprint` to use `HEAD` regardless of dirty state**, and call `repo_warn_dirty` before the early stop so the warning always shows.

- [ ] **Step 6: Commit changes in test fixtures** wherever a test edits a repo and expects a deploy, then run the suites. Run: `bash test/run-app-tests.sh`. Expected: all pass.

- [ ] **Step 7: Commit** with `Deploy committed content only; stop when a pull is blocked`.

### Task 4: Records and the three-way decision

**Files:**
- Create: `lib/records.sh`, `lib/merge3.jq`, `test/apps/test-records.sh`
- Modify: `lib/versions.sh:13`

**Interfaces:**
- Produces, with layout `$STATE_DIR/records/<app>/{manifest.tsv,repo/<src>,review/<src>}`, where manifest lines are `SRC<TAB>DEST<TAB>STRATEGY`:
  - `records_repo_path APP SRC`, `records_review_path APP SRC`: print paths.
  - `records_put APP SRC DEST STRATEGY REPO_FILE LIVE_FILE`: writes both copies and the manifest line.
  - `records_set_repo APP SRC FILE`, `records_set_review APP SRC FILE`: replace one copy.
  - `records_list APP`: prints manifest lines.
  - `records_prune APP DEST...`, `records_remove APP`, `records_any`: housekeeping; `records_any` succeeds if any app has records.
  - `records_decide_file LIVE REPO_COPY NEW`: prints `apply`, `none`, `keep`, `same` or `conflict`.
  - `records_merge3 BASE NEW LIVE REVIEW`: prints JSON `{live, repo, review, conflicts, applied}`, where `conflicts` and `applied` are arrays of path arrays.
  - `records_items APP SRC DEST STAGE_FILE ALL`: prints `KIND<TAB>PATH_JSON` lines. `KIND` is `edited`, `conflict` or `dismissed`, and `PATH_JSON` is `[]` for replaced files. `dismissed` appears only when `ALL` is `true`.

- [ ] **Step 1: Write failing tests** in `test-records.sh`:
  - Every row of the spec's `pull` table, for `records_decide_file` and `records_merge3`.
  - Copies are `0600` and directories `0700`.
  - Conflicts keep their old value in `repo`, so a second run reports the same conflict.
  - `applied` paths update `review`; other paths leave it alone, so an unreviewed edit stays visible.
  - A key the repo drops is removed from `live` when unchanged and kept when edited.
  - Object-to-scalar changes in either direction report one conflict at the topmost path and leave the subtree untouched.
  - A key `a.b@c` and a nested `a` → `b@c` stay distinct (Review Focus).
  - `null` differs from absent.
  - An array reordered inside counts as changed, while objects with reordered keys don't.
  - Repo `{}` doesn't flag or remove live children.
  - `records_items` returns nothing when live equals the repo copy, even if the review copy differs.

- [ ] **Step 2: Run them and confirm they fail.** Run: `bash test/apps/test-records.sh`.

- [ ] **Step 3: Implement `lib/merge3.jq`** with this algorithm, where a leaf is any non-object value, and empty objects manage nothing:

```
P = leaves(BASE) ∪ leaves(NEW)
for each p in P: b, n, l = value at p (or absent)
  blocked = a proper prefix of p is a non-object in LIVE, or NEW has a
            non-object at a proper prefix of p and BASE doesn't, or the reverse
conflicts = topmost path for each blocked p,
            plus every p with n != b, l != b, l != n
skip any p at or under a conflict path
n == b           -> nothing
l == b           -> set or delete p in live and review; repo[p] = n; applied += p
l == n           -> repo[p] = n; review[p] = n
result repo = NEW, except conflict paths keep BASE's value
```

- [ ] **Step 4: Implement `lib/records.sh`** and set `VERSIONS_MARKER="lib/records.sh"`, so `checkout` refuses versions from before this design. Update `test-versions.sh`.

- [ ] **Step 5: Run the tests.** Run: `bash test/apps/test-records.sh && bash test/apps/test-versions.sh`. Expected: PASS.

- [ ] **Step 6: Commit** with `Add records and the three-way decision`.

### Task 5: Deploys use the records

**Files:**
- Modify: `lib/installer.sh`, `lib/sync.sh`, `lib/overlay.sh`, `dotfiles`, `apps/git/configure.sh`
- Create: `test/apps/test-pull-records.sh`
- Test: `test/apps/test-claude.sh`, `test/apps/test-sync.sh`

**Interfaces:**
- Consumes: `records_*` from Task 4.
- Produces: installer env `DOTFILES_FORCE_PATH` and `DOTFILES_RESET=1`. A held conflict records state version `conflict` and writes the dest to `DOTFILES_KEPT_FILE`. `HELD_CONFLICTS` in `dotfiles` blocks `sync_record_complete`.

- [ ] **Step 1: Write failing tests** that run through `dotfiles pull`, for both replaced and merged files:
  - Each table row produces the expected live file.
  - After a conflict, the warning repeats on every `pull` and `last-complete` isn't written.
  - After a conflict, reverting the edit by hand makes the next `pull` apply the repo's version.
  - An unrelated repo change doesn't overwrite a hand edit in `settings.json`, and the edit stays flagged.
  - `--force` overwrites repo-managed values and keeps local-only keys.
  - `--force PATH` changes only that file, an unmanaged `PATH` exits 1, and both take a snapshot under `--no-backup`.
  - First install over an existing `settings.json` gives `live * repo` with both copies recorded.
  - A live symlink stays a symlink, and a `src` with a space deploys (Review Focus).
  - Switching a file's strategy snapshots it, then deploys it fresh.
  - A file removed from the repo stays in place, with a warning if it has unreviewed edits.
  - A deleted live file comes back.
  - Invalid JSON in a live or layer file fails only that file, leaves it untouched, and is retried on the next `pull`.
  - Changing profile or host counts as repo changes: an untouched file follows, and an edited one conflicts.
  - A run killed partway through recovers on the next `pull`, with records written only after each file's write.

- [ ] **Step 2: Run them and confirm they fail.** Run: `bash test/apps/test-pull-records.sh`.

- [ ] **Step 3: Rewrite `deploy_all_files` around the records.** With no record, deploy fresh and call `records_put`. Otherwise use `records_decide_file` or `records_merge3`, and write live with `cat tmp > dest` so symlinks survive. Remove `installer_keep_edit`, `installer_baseline` and `app_matches_repo`, including its git override.

- [ ] **Step 4: Change `installed_version`** to return `conflict` when any file or key was held, and show that in `status`.

- [ ] **Step 5: Parse `--force [PATH]`** in `parse_args`, resolving `PATH` to an absolute dest. Take a snapshot for `--force` and for a first install even with `--no-backup`. A first install also saves the original even with `--no-backup`. `pull` refuses to run with old-format `$STATE_DIR/deployed/*.tsv` and tells you to run `dotfiles init`.

- [ ] **Step 6: Run the tests.** Run: `bash test/run-app-tests.sh`. Expected: all pass, except the review parts of `test-add.sh` and `test-status.sh`, because `add` and `status` still read the old records until Tasks 7 and 8. Keep `lib/deployed.sh` until Task 8, and list those failures in the task report.

- [ ] **Step 7: Commit** with `Deploys hold back conflicts, per file and per key`.

### Task 6: Remove `.bashrc` special handling and `--append`

**Files:**
- Modify: `apps/bash/configure.sh`, `test/apps/test-bash.sh`, `test/apps/test-add.sh:405-407`, `test/apps/test-resolve.sh`
- Delete: `test/apps/test-upgrade-from-append.sh`
- Modify, if the check below allows: `lib/profile.sh`, `dotfiles`

- [ ] **Step 1: Write failing tests** in `test-bash.sh`:
  - A first install over a custom `.bashrc` replaces it, creates no `00-local.sh`, keeps the original, and warns with the original's path and `no longer loaded`.
  - A stock `/etc/skel/.bashrc` gets no warning.
  - An existing `00-local.sh` is still sourced and left unchanged.
  - `--append` is rejected.
  - `--supplement` still works.

- [ ] **Step 2: Run them and confirm they fail.** Run: `bash test/apps/test-bash.sh`.

- [ ] **Step 3: Remove from `apps/bash/configure.sh`:** `--append`, `BASHRC_*`, `bashrc_has_blocks`, `app_matches_repo`, `bashrc_preserve`, `deploy_bashrc` and the `deploy_file` override. Add the warning in `app_post_deploy` for installs, using `installer_report_warning`. Delete the tests of the old behaviour.

- [ ] **Step 4: Leave the `configure_flags` plumbing in `lib/profile.sh` and `dotfiles` as it is**, with its generic test in `test-resolve.sh`. It's harmless, and removing it could break a repo we can't check.

- [ ] **Step 5: Run the tests.** Run: `bash test/run-app-tests.sh`. Expected: all pass, except the same `test-add.sh` and `test-status.sh` review parts as in Task 5.

- [ ] **Step 6: Commit** with `Treat .bashrc like any other file; remove --append`.

### Task 7: Rewrite `add`

**Files:**
- Modify: `lib/add.sh`, `dotfiles`
- Test: `test/apps/test-add.sh`

**Interfaces:**
- Consumes: `records_items`, `records_set_review`, `records_set_repo`, `records_review_path`.
- Produces: `add_build_layers` keeps its globals and leaves out a repo with no git. `add_saved_elsewhere APP_DIR SRC PATH_JSON DEST` succeeds if any layer's working copy already holds the live value. Status reuses it in Task 8.

- [ ] **Step 1: Write failing tests**, answering prompts with `DOTFILES_ADD_ASSUME_TTY=1`:
  - The prompt offers save, dismiss and skip, and `q` quits.
  - Dismissing stops further prompts until the value changes again.
  - `--all` asks about dismissed items again.
  - Dismissing a conflict stops the warning on the next `pull`.
  - EOF leaves records unchanged and the item pending (Review Focus).
  - Saving asks for a layer, offers every available layer, and stages only that layer.
  - Saving a replaced file to a layer without a copy prints that the file will be created and masks lower copies.
  - Saving below a layer with the same file or key prints that the higher layer still wins.
  - A second save to a layer file changed only by `add` works; a file with other uncommitted edits is skipped.
  - A saved item isn't asked again, and asks again after `git reset --hard`.
  - After commit and `pull`, the item is clean.
  - Saving a merged key writes only that key, and creates the layer's JSON if needed.
  - An invalid layer JSON refuses the save.
  - A deleted key offers only dismiss and skip, and says why.
  - An array save warns about hiding later repo changes.
  - A replaced-file conflict shows both changes and needs confirmation to save.
  - The public layer shows the value and needs `public` typed.
  - A repo with no git offers only dismiss.
  - The closing message lists staged files per repo and says to commit and push, including after `q`.

- [ ] **Step 2: Run them and confirm they fail.** Run: `bash test/apps/test-add.sh`.

- [ ] **Step 3: Rewrite the review loop** in `lib/add.sh` over `records_items`. Show your change as repo copy vs live, and for a conflict also the repo's change as repo copy vs stage. Remove `add_show_merged`.

- [ ] **Step 4: Implement save.** Keep `add_save` for replaced files. Add `add_save_key LAYER_JSON PATH_JSON VALUE_FILE`, written with `setpath`. Record the file's hash under `$STATE_DIR/records/.add-saved/` after each save, and allow a further save only while the working copy still matches that hash. A save doesn't touch the records.

- [ ] **Step 5: Implement dismiss.** It updates only that item in the review copy, and for a conflict also in the repo copy from the stage. For replaced files, the item is the whole file.

- [ ] **Step 6: Run the tests.** Run: `bash test/apps/test-add.sh`. Expected: PASS. The `add` tests moved or removed here must not lower the coverage of the spec's corner cases.

- [ ] **Step 7: Commit** with `add reviews per key, with save, dismiss and skip`.

### Task 8: Status, drop-ins and uninstall

**Files:**
- Modify: `dotfiles:1005-1045`, `dotfiles:330-345`, `lib/sync.sh:118-126`, `lib/installer.sh:577-620`, `lib/add.sh`
- Delete: `lib/deployed.sh`
- Test: `test/apps/test-status.sh`, `test/apps/test-sync.sh`, `test/apps/test-add.sh`, `test/apps/test-setup.sh`

**Interfaces:**
- Consumes: `records_*`, `add_saved_elsewhere`, and the deploy logic from Task 5 exposed as `installer_deploy_recorded APP SRC SRC_PATH DEST MODE STRATEGY`.

- [ ] **Step 1: Write failing tests:**
  - `status` lists updates available, unreviewed changes, conflicts, dismissed local differences, saved changes waiting for a commit, and uncommitted repo files, each under its own label.
  - An edit to `50-lazygit.sh` survives a repo change to it and is flagged, and `add` offers it with the public default as the only save target.
  - An edit to `90-dotfiles.sh` survives and is flagged, and `add` offers only dismiss and skip.
  - `uninstall` lists local changes and takes a snapshot, even with `--no-backup`, before restoring.

- [ ] **Step 2: Run them and confirm they fail.** Run: `bash test/apps/test-status.sh`.

- [ ] **Step 3: Route both drop-in copies through `installer_deploy_recorded`**, with app names `<tool>` and `dotfiles`. The check before deploying a tool's drop-in stays as it is.

- [ ] **Step 4: Update `cmd_status` and `cmd_uninstall`, then delete `lib/deployed.sh`.**

- [ ] **Step 5: Run the tests.** Run: `bash test/run-app-tests.sh`. Expected: all pass.

- [ ] **Step 6: Commit** with `Status shows every review state; drop-ins and uninstall are protected`.

### Task 9: Re-running `init`

**Files:**
- Modify: `lib/init.sh`, `lib/installer.sh`, `lib/push.sh`
- Test: `test/apps/test-init.sh`, `test/apps/test-push.sh`

**Interfaces:**
- Consumes: `records_any`, `DOTFILES_RESET=1`, snapshot code from Task 5.
- Produces: `init_reset_summary` prints what a reset would lose.

- [ ] **Step 1: Write failing tests:**
  - On a host with records, `init` saves its answers, then asks whether to reset, defaulting to no. Answering no runs a normal `pull` and keeps local edits.
  - Confirming lists what would be lost, including local-only keys, then needs `reset` typed. Every managed file then equals the repo layers exactly, records are fresh and a snapshot exists.
  - `00-local.sh` and `.gitconfig.local` are untouched.
  - `--yes` never resets. With no terminal it doesn't reset and runs a normal `pull`.
  - A host with only old `deployed/*.tsv` records doesn't get the reset prompt: `init` snapshots all managed files, removes old records and state, and deploys fresh, keeping local-only keys in merged files.
  - `init --remote` reaches the same prompt over `ssh -t`.

- [ ] **Step 2: Run them and confirm they fail.** Run: `bash test/apps/test-init.sh`.

- [ ] **Step 3: Implement the prompt** after `init_write_config`, then run `pull` with `DOTFILES_RESET=1` on confirmation. `deploy_all_files` under reset writes the stage file exactly and calls `records_put`.

- [ ] **Step 4: Implement the move from old records** in `init_main`, before the first `pull`.

- [ ] **Step 5: Run the tests.** Run: `bash test/apps/test-init.sh && bash test/apps/test-push.sh`. Expected: PASS.

- [ ] **Step 6: Commit** with `Re-running init can reset a host to the repo layers`.

### Task 10: Documentation

**Files:**
- Modify: `README.md`, `docs/schema.md`, `docs/roadmap.md`, `bootstrap.sh` (messages only)

- [ ] **Step 1: Reorganise the README.** Near the top, add a command reference grouped by task, with each command linking to its details:
  - Update this machine: `pull`, `pull --no-fetch`, `sync`, `status`, `versions`, `checkout`.
  - Save local edits: `add`, `add --all`, `sync`.
  - Resolve conflicts: `add`, `pull --force [PATH]`.
  - Set up or update a remote host: `init --remote`, `pull --remote`.
  - Reset or remove: `init` again, `uninstall`.
  - Check: `verify`, `help`.

  Then rewrite these to match:
  - The opening paragraph and `init` question table.
  - "Your existing settings are kept", dropping the `00-local.sh` line.
  - The flags table, "Staying up to date" and "Changing a config file", which must explain committing before deploying and trying a change on a branch.
  - "Machines updated with `push`" and the layered config section, including that the most specific layer's copy of a replaced file wins whole.

- [ ] **Step 2: Update `docs/schema.md`:** commands, config keys, Background sync (now the update check), Local edits, `~/.bashrc`, `push` and `push --init`.

- [ ] **Step 3: Update `docs/roadmap.md`:** remove "Accept merged-file changes in `dotfiles add`" and "Tell an older repo version from a hand edit", which this work settles.

- [ ] **Step 4: Check for leftovers.** Run: `grep -rnE 'dotfiles sync --|--no-pull|auto_sync|--auto\b|dotfiles push|push --init|00-local|--append' README.md docs/schema.md dotfiles lib apps bootstrap.sh`. Expected: only the config aliases from Task 2 and the existing `00-local.sh` note.

- [ ] **Step 5: Run the full suite.** Run: `bash test/run-core-tests.sh && bash test/run-app-tests.sh`, then `make -C test test` if Docker is available. Expected: all pass. Report it if the remote tests couldn't run.

- [ ] **Step 6: Commit** with `Docs: reorganise the README by task; describe the new commands`.

---

## Choices this plan makes beyond the spec

- `auto_sync` becomes `update_check`, because the old name would be wrong. Old keys still load.
- The reset needs `reset` typed, after listing what would be lost.
- `sync` doesn't fetch before `add`. Conflicts from incoming commits appear at its `pull` step, and running `add` again resolves them. Comparing against unfetched commits would add a second comparison path for little gain.
- Originals stay stored by filename. No app has two files with the same name today.
- `add` offers only the public default for `lazygit` and `lazyssh` drop-ins, because overlays don't apply to them, and only dismiss and skip for `90-dotfiles.sh`, which comes from `lib/`.
