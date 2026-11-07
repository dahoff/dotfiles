# Design: updates, local edits and drift

Status: approved 2026-11-06. Built on the `updates-and-local-edits` branch.

## Goals

1. Easy way to install updated dotfiles.
2. Easy way to take local edits and add them back to one of the dotfiles repos.
3. Warn on conflicts and keep the user from losing work.

## Commands

| Command | What it does |
|---|---|
| `dotfiles pull` | Updates the repos, installs packages and deploys. It applies what it safely can, holds back conflicts and reports them. |
| `dotfiles pull --force [PATH]` | Takes the repo's version for one file, or for everything if no path is given. It always takes a snapshot first and keeps local-only keys in merged files. |
| `dotfiles pull --no-fetch` | Deploys what's already here. `pull --remote` and `checkout` use this. |
| `dotfiles init` | First setup of this host, which keeps what's already on the machine. On a host already set up, it resets instead: every managed file becomes exactly what the repo layers produce, removing local-only keys, and records start fresh. Before a reset, it lists what would be lost, asks you to confirm and takes a snapshot. |
| `dotfiles add` | Shows your new local changes and any conflicts, and asks you to save, dismiss or skip each one. |
| `dotfiles add --all` | Also asks again about anything you dismissed. |
| `dotfiles sync` | Runs `add`, then `pull`. Needs a terminal. |
| `dotfiles status` | Shows available updates, unreviewed changes, conflicts, and saved changes waiting for a commit. |
| `dotfiles checkout REF` | Switches to a tag, commit or branch, then deploys it with `pull --no-fetch`. A tag or commit pins the machine, so `pull` won't move it; `checkout main` follows `main` again. Refuses if the repo has uncommitted changes. |
| `dotfiles init --remote HOST...` | First setup of a host that can't reach the repos, sent from this machine over ssh. Replaces `push --init`. |
| `dotfiles pull --remote HOST...` | Updates such a host: sends this machine's committed repos to it over ssh, then runs `pull --no-fetch` there. It warns if the repos here are behind their remotes. `--force` passes through, and conflicts show in your terminal. Replaces `push`. |

New terminals only run a throttled `git fetch`, then tell you when updates are available. They never deploy or install anything. The reminder about packages still pending stays, and says to run `dotfiles pull`.

`init` and `checkout` move from `sync` to `pull`, since neither should prompt for reviews. `dotfiles push` goes away.

## `add` answers

- **Save:** asks which layer to use (this host, any profile or the public default), copies the change there and stages it, without committing. Merged files save only that key; other files save the whole file. It isn't asked about again while that layer holds the value, and if you discard the staged change, `add` asks again.
- **Dismiss:** keeps the change local, and `add` won't ask again unless the value changes. On a conflict, this also accepts the repo's current version as the new starting point, which stops the warning.
- **Skip:** asks again next time. Quitting partway does the same for anything unanswered.

When the review ends, including when you quit partway, if anything was saved, `add` lists the staged files in each repo and tells you to commit and push them yourself. Other hosts won't get those changes until you do.

## Drift detection

Each managed file has two saved copies, stored privately (`0600`) in the state dir:

| Copy | Holds | Used by |
|---|---|---|
| **Repo copy** | The last repo version you accepted | `pull`, to see what the repo changed |
| **Review copy** | The live file as of your last review | `add`, to see what's new |

Merged JSON is compared per key, and everything else per file.

`pull` asks two questions about each file or key. "Did you change it?" compares the live file on disk with the repo copy. "Did the repo change it?" compares the repo now with the repo copy.

| Did you change it? | Did the repo change it? | `pull` does |
|---|---|---|
| No | Yes | Applies it |
| No | No | Nothing |
| Yes | No | Keeps yours |
| Yes | Yes, to your value | Updates its records only |
| Yes | Yes, to something else | **Conflict:** keeps yours and warns on every pull until resolved |

A key the repo stops managing is removed from the live file if its value still matches the repo copy. Otherwise it's kept.

Three rules hold this together:

1. **Only committed repo content gets deployed.** If a repo has uncommitted changes, `pull` and `status` name those files and say they aren't deployed. So a staged save can't become the repo copy, and discarding one can't delete your edit. To try a change first, commit it on a branch and run `dotfiles pull --no-fetch`, then `dotfiles checkout main` to go back.
2. **A deploy only updates the review copy for what it applied.** An edit you haven't reviewed still gets flagged later.
3. **An open conflict keeps being checked.** It turns off the "already up to date" early stop, so later pulls re-evaluate it.

To resolve a conflict, either save or dismiss it in `add`, or take the repo's version with `pull --force PATH`.

## Corner cases

| Case | What happens |
|---|---|
| Upstream changed the layer file you saved to, or the repos diverged | `pull` stops without deploying and gives the exact commands: commit, `git pull --rebase`, push, then `dotfiles pull`. |
| Saved but never committed | The value stays local, and the change shows in `git status` and `dotfiles status`. |
| Second save to a layer file with uncommitted changes | Allowed if only `add` changed that file. Today it's skipped. |
| Remote host with no git | `add` only offers dismiss, because the next `pull --remote` would wipe a save. An edit made there has to be copied back by hand. |
| Conflict in a replaced file | `add` shows your change and the repo's separately. Saving the whole file would undo the repo's change, so it warns and asks you to confirm. |
| A key changes between object and plain value | The whole subtree counts as a conflict. |
| You deleted a repo-managed key | Dismiss keeps it deleted. Saving isn't possible, and `add` says so. |
| Arrays | Compared and saved as one value. `add` warns that a save hides later repo changes to that list. |
| Saving a replaced file to a layer with no copy of it | Allowed. A message says the file will be created there, which masks any copy in lower layers from then on. |
| Saving below a layer that has the same file or key | Allowed. A message says the higher layer still wins, so on this host the change stays local. |
| Saving to the public repo | Shows the value and requires typing `public`. Not offered when pinned or without git. |
| Claude Code rewrites `settings.json` | Each changed value is asked about once and never blocks `pull`. |
| You set a value back to the repo's | Counts as reviewed, with no prompt. |
| Regretted a dismiss | `status` lists local differences, and `add --all` asks again. |
| First install over an existing file | The original is kept for `uninstall`, and a snapshot is always taken. Existing keys aren't offered by `add`. `.bashrc` gets no special handling: it's replaced like any other file, and a hard-to-miss message gives the original's path and says your old content is no longer loaded. Copy back what you want, and `add` offers to save it to a layer. |
| A host that already has `00-local.sh` | It keeps working, because `.bashrc` still loads everything in `~/.bashrc.d/`, and dotfiles leaves it alone. Nothing creates this file any more. |
| Lazygit, lazyssh and `90-dotfiles.sh` drop-ins | Go through the normal deploy, so they're protected too. They bypass it today. |
| Live file deleted | Restored by the next deploy that isn't an early stop. `--force` always restores it. |
| File removed from the repo | Left in place and no longer tracked, with a warning if it has unreviewed edits. |
| Profile or host change | Handled as repo changes against the repo copy. |
| Switching a file between replace and merge | Takes a snapshot, then treated as a fresh deploy. |
| Invalid JSON | Only that file fails and is left untouched. It's retried on the next pull. |
| Pinned with `checkout` | `pull` warns and doesn't fetch new commits. `checkout main` follows again. |
| Interrupted run | Records are written per item after the write, so a re-run recomputes safely. A lock prevents concurrent runs. |
| `sync` or `add` with no terminal | Refuses. `pull` still works unattended. |
| `uninstall` | Lists your local changes and always takes a snapshot first. Today it can destroy edits. |
| Re-running `init` only to change settings | It asks its questions and saves the answers, then asks whether to reset, defaulting to no. Answering no runs a normal `pull`, so changing the hostname or profile doesn't wipe anything. |
| Re-running `init` as a reset | Resets to the repo layers, not to the files from before dotfiles; that's what `uninstall` does. Files dotfiles doesn't manage, like `00-local.sh` and `.gitconfig.local`, stay untouched. `--yes` doesn't skip the confirmation, and with no terminal it refuses. It's all or nothing; `pull --force PATH` handles single files but keeps local-only keys. `init --remote` behaves the same way. |
| Moving a host to this design | `init` snapshots all managed files and starts fresh records. Review pending edits with today's `add` before updating, because the new `add` refuses old records and replaced files get overwritten. |
| `checkout` to a version from before this design | Refused as too old. |

## Not included

Automatic commits or pushes, saving individual hunks of a replaced file, line-level merging of replaced files, merging inside arrays, and two-way sync between hosts.

## Documentation

The README must be updated with every command change above, and organised so someone can quickly find the command they want: a short command reference near the top, grouped by task (update this machine, save local edits, resolve conflicts, set up or update a remote host, reset or remove), linking to details. `docs/schema.md` is updated to match, and anything saying `sync` deploys in the background, or describing `push` or `00-local.sh`, is corrected.

## Cleanup

Removed as part of this work: the ignored `--append` handling in `apps/bash/configure.sh`, the code that moves `.bashrc` content to `00-local.sh`, and the code that cleans up old appended blocks. `configure_flags` stays: no repo config here uses it, but the work hosts repo is out of scope and can't be checked, and the generic plumbing is harmless.

## Decisions

1. **Only committed changes deploy: decided, yes.** `pull` and `status` warn about uncommitted changes, and a branch can be used for testing.
2. **`add` stays stage-only: decided, yes.** It tells you to commit and push when the review ends.
3. **`--force` keeps local-only keys: decided, yes.** Re-running `init` is the way to wipe everything back to the repo layers.
4. **`dotfiles push` is renamed: decided.** `push --init` becomes `init --remote` and `push` becomes `pull --remote`. The help text must say `pull --remote` sends from this machine to the host.

## Review findings

An agent reviewed the first draft against the code, running experiments in a throwaway `$HOME`. "Reproduced" means it saw the problem on today's code; "traced" means it found it by reading the code. Each fix is included in the design above.

| Severity | Problem | How found | Fix |
|---|---|---|---|
| Blocker | Discarding a saved edit deletes it: the deploy reads uncommitted layer files, so the next pull overwrites your live file with no warning. | Reproduced | Deploy committed content only |
| Blocker | Saves on pushed copies vanish, because the next `push` replaces the directory. | Traced | Dismiss only without git |
| Blocker | Held-back conflicts are never re-checked, because later pulls stop early and the file stays behind permanently. | Reproduced | Open conflicts turn off the early stop; add `--force PATH` |
| Blocker | Records after a conflict were undefined: the warning either vanishes after one pull or never stops. | Traced | Repo copy means "last accepted"; `add` always offers conflicts |
| Should fix | "Commit and push, then pull" dead-ends when upstream touched the same file, and diverged repos weren't covered. | Reproduced | Stop with rebase commands |
| Should fix | Re-bootstrapping doesn't reset anything, and with state wiped an edited file was lost entirely. | Reproduced | `init` starts fresh records; always snapshot before install |
| Should fix | Hashes alone can't show a correct diff for a replaced file, so a conflict shows the repo's change reversed and a save silently reverts it. | Traced | Store contents for all files |
| Should fix | Changes between object and plain value were undefined and could fail or wipe keys. | Reproduced | Treat as a conflict on the subtree |
| Should fix | Not every managed file has records: some drop-ins are copied over unprotected. | Traced | Route them through the normal deploy |
| Should fix | `uninstall` destroys edits without warning. | Reproduced | List changes and always snapshot |
| Minor | A discarded save became a silent dismiss. | Traced | Don't record a save as reviewed until it reaches the repo |
| Minor | Setting a value back to the repo's by hand prompted again. | Traced | Treat it as reviewed |
| Minor | Files dropped from config, and replace/merge switches, were undefined. | Traced | See corner cases |
| Minor | `checkout` to an older commit would call a `pull --no-fetch` it doesn't have. | Traced | Refuse those versions as too old |

Two smaller notes from the review still need handling during the build:

- Compare array values with `==` rather than as JSON text, which flags reordered objects as changes.
- `sync` runs `add` before fetching, so `add` can't know about incoming conflicts unless `sync` fetches first.

The review found these parts sound: the non-conflict rows of the `pull` table, a saved key returning through the repo, layer and profile changes, deleted keys, null versus absent values, local-only keys under `--force`, and re-running after an interruption.
