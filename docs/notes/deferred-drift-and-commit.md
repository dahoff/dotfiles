# Local edits: what was built, and what is still deferred

Status: edit protection and `dotfiles add` are built. The items under "Deferred" are ideas,
not scheduled.

## Built

- **Edit protection** (`lib/deployed.sh`, `lib/installer.sh`): each deploy records a hash of
  the file it wrote in `$STATE_DIR/deployed/<app>.tsv`. An upgrade leaves a file alone if its
  live copy differs from that record, and `--force` overwrites it (the snapshot keeps the
  edit). Merged files are expected to change, so only the keys the repo manages are compared.
- **`dotfiles add`** (`lib/add.sh`): reviews each edit, then copies accepted files into a layer
  and stages them. It never commits or pushes, so you review again in git or lazygit. It only
  copies files dotfiles already manages. Saving to the public default needs typing `public`.
- **Merged files are display-only in `add`.** Accepting needs per-key layer logic: the same
  key can be set in several layers, and a whole-file copy would pull in local keys.
- **`~/.bashrc` is an ordinary managed file** (`apps/bash/configure.sh`). It used to be
  appended to, which added a block on each `bash` app change and hid edits from detection. The
  first deploy cleans up: your own content moves to `~/.bashrc.d/00-local.sh`, which dotfiles
  doesn't manage, and a stock distro file stays only in the backup, because add-ons load last
  and it would override the managed prompt and aliases.

## Why `add` and not `commit`

The original idea here was a `dotfiles commit` that also committed and pushed, with `dotfiles
sync` becoming two-way. It was dropped: most of the risk and work came from the tool committing
to a public repo on your behalf. `sync` stays one-way, so `push` keeps its ssh meaning and no
`pull` verb was needed. A `commit` could still be added on top of `add`.

## Deferred

- **`gitleaks` secret scanning.** A standalone command-line scanner for secrets in git repos.
  - A one-time scan of both repos' full history, to check nothing has already leaked. Nobody
    has run this yet.
  - A pre-commit hook. It needs `gitleaks` and the hook on each machine plus handling for false
    positives, and `git commit --no-verify` bypasses it.
- **GitHub push protection** is already on for the public `dotfiles` repo, as of 2026-11-04. It
  only recognises known token formats. It isn't reported as enabled on the private hosts repo.
- **Accepting merged-file changes in `add`.**
- **New add-on files from the hosts repo.** An overlay can only replace a file the public
  `config.yaml` lists, so an add-on for one host has nowhere to go, and `add` can't pick up a
  new file like `~/.bashrc.d/60-mine.sh`.
- **`dotfiles commit` and a two-way `sync`**, if `add` plus a manual commit becomes tedious.
