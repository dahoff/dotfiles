# Deferred: drift detection and `dotfiles commit`

Status: idea, not scheduled. Revisit after the dotfiles-hosts / sync / bootstrap work lands.

## Problem

Configs are deployed by copying. Once hosts sync automatically at login, any hand edit to a
live managed file (e.g. `~/.tmux.conf`) is silently overwritten on the next sync that touches
that app. Backups exist, but nothing tells you it happened.

## Drift detection

- On deploy, record a hash of each file written (in `~/.local/state/dotfiles/`).
- Before overwriting, compare the live file to the recorded hash. If it differs, the file has
  drifted: keep the backup and report at next login, e.g.
  `dotfiles: ~/.tmux.conf had local edits, overwritten (backup: ...)`.
- `dotfiles status` lists drifted files on demand.
- Files deployed with the `merge` strategy are expected to change locally; skip them (or only
  report drift in repo-managed keys).

## `dotfiles commit`

Turn a local edit into a deliberate change instead of a lost one:

1. Detect drifted files (as above) and show a diff of live vs deployed.
2. For each change, ask where it belongs:
   - **host-specific**: `dotfiles-hosts/hosts/<hostname>/apps/<app>/files/...`
   - **hosts-dir profile default**: `dotfiles-hosts/profiles/<profile>/apps/<app>/files/...`
   - **dotfiles default**: `dotfiles/<app>/files/...`
3. Write the change into the chosen layer (for `merge` files, only the changed keys), then
   commit and optionally push that repo.
4. Re-run sync so the recorded hashes match.
