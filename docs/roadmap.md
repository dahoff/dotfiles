# Roadmap

Ideas and loose ends. Nothing here is scheduled.

## Secret scanning

- **One-time `gitleaks` scan** of both repos' full history, to check nothing has already leaked. Nobody has run this yet.
- **`gitleaks` pre-commit hook.** It needs `gitleaks` and the hook on each machine plus handling for false positives, and `git commit --no-verify` bypasses it.
- **GitHub push protection on the hosts repo.** It's on for the public `dotfiles` repo, as of 2026-11-04, where it only recognises known token formats. It isn't reported as enabled on the private hosts repo.

## Local edits

- **`dotfiles commit` and a two-way `sync`**, if `add` plus a manual commit becomes tedious. They were dropped for now because most of the risk and work came from the tool committing to a public repo on your behalf. A `commit` could be built on top of `add`.
- **A tool with both `configure.sh` and a drop-in shares one records app.** Pruning the configure.sh files' records drops the drop-in's record. No tool does both today.
- **Drop-in snapshots ignore `backup.dir` and aren't pruned.** They always go to `~/.bak/<app>`.
- **`--supplement` files bypass the records.** They get no edit protection and no snapshot. No profile uses them today.
- **Saving a key re-pretty-prints the layer file.** The value is right, but the file's formatting changes.
- **A subtree saved over a lower layer's object doesn't round-trip.** It comes back from `add` as "you deleted" items.

## Bootstrap

- **`dotfiles` on `PATH` from bootstrap.** `init --no-sync` creates no link, and `PATH` depends on the `bash` app. Waiting on trying bootstrap on a fresh machine.
- **`dotfiles --sync`.** It was the form first asked for, and it errors; the command is `dotfiles sync`. Decide whether to accept it.

## App config

- **Trailing comments in `files:`.** `load_config` in `lib/installer.sh` doesn't strip them, so `dest: ~/x   # note` deploys to a file with the comment in its name. The README warns about it; remove that warning once this is fixed.

## Releases

- **Tag the first release.** `dotfiles versions` lists nothing until a tag exists.
