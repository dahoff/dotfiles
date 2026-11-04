# One Folder Per Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `packages/` into `apps/`, so a tool's install and config live in one folder and a profile only lists names.

**Architecture:** First rename the config scripts and move the tool scripts, keeping the long-form profile working. Then teach `load_manifest` to resolve plain names into the existing `PKG_*` arrays, so the phases in `dotfiles` barely change. Finally migrate `complete.yaml` and the app configs.

**Tech Stack:** Bash, jq, the repo's shell test suites.

**Spec:** `docs/superpowers/specs/2026-11-03-apps-install-merge-design.md`

## Global Constraints

- `complete` resolves to exactly: `git bash tmux vim curl fzf jq tree lazygit lazyssh scripts claude`.
- A dry run writes nothing.
- Suites pass at each commit: from `test/`, `./run-core-tests.sh` and `./run-app-tests.sh`, one at a time. Run `./run-remote-tests.sh` (Docker, with the `/tmp/dcshim` shim on `PATH`) at the end.
- Tests never touch the real `HOME`. Commits have no attribution trailers. `git add` explicit paths.

## Review Focus

Each line has its test in Task 3.

- `extra:` before `exclude:` in one `host.yaml`: the `- name` list after `exclude:` isn't read as tools, even when the last extra was a long-form entry with `custom:`.
- `- curl  # comment` in a list: the comment isn't part of the name.
- A plain name containing `/`: unknown tool, no path lookup outside `apps/`.
- `install:` above `files:` in a `config.yaml`: the app still deploys all its files and keeps its `app.name`.
- No `apps/os-packages.yaml` at all: folder tools still resolve, and an unknown name gives the normal error.

---

### Task 1: Rename `apps/*/install.sh` to `configure.sh`

**Files:** `apps/*/install.sh`, `dotfiles:360`, `lib/overlay.sh:179`, `lib/installer.sh:4`, `docs/schema.md`, and tests using `./install.sh`, `$APP/install.sh` or `apps/<app>/install.sh`.

**Interfaces:** Produces: `apps/<name>/configure.sh`, which is what the config phase and the version hash read. `apps/<name>/install.sh` is free for Task 2.

- [ ] `git mv` each script; update headers, usage lines, `$installer`, the "Installer not found" message and the version hash.
- [ ] Update tests (`test-overlay` Cases 8-9 hash `configure.sh`; `test-setup` Test 9 greps `configure.sh`, keeping `packages` until Task 2; `test-tmux` Test 27; the `sleeptest` app in `test-sync`).
- [ ] Run core and app suites. Expected: all pass.
- [ ] Commit: `Rename app config scripts to configure.sh`.

### Task 2: Move tool scripts into `apps/`, delete `packages/`

**Files:** `packages/custom/{claude,lazygit,lazyssh}` move to `apps/<tool>/`; `packages/custom/testtool` moves to `test/fixtures/testtool`; delete `packages/install.sh`; `dotfiles:296,300,328`; `profiles/complete.yaml`; `test/fixtures/hosts-dir/profiles/pendingtest.yaml`; `test/apps/test-sync.sh:724`; `test/apps/test-packages.sh`; `test/apps/test-setup.sh`.

**Interfaces:** Produces: `custom.script` and `custom.dropin` are relative to `$APPS_DIR`.

- [ ] Change the three `$SCRIPT_DIR/packages/` paths in `dotfiles` to `$APPS_DIR/`.
- [ ] Move the files. `complete.yaml` becomes `script: lazygit/install.sh`, `dropin: lazygit/files/50-lazygit.sh`, and likewise for the others. Fixtures use `../test/fixtures/testtool/install.sh`.
- [ ] Update `test-packages.sh` paths. Remove Tests 11 and 15, which exist only for the deleted module.
- [ ] Run core and app suites. Expected: all pass.
- [ ] Commit: `Move tool install scripts into apps/ and remove packages/`.

### Task 3: Resolve plain names

**Files:** `lib/profile.sh`; new `test/apps/test-resolve.sh`.

**Interfaces:**
- `load_manifest file [source_label] [definitions:true|false]`: `source_label` names the file in errors (the `extra:` temp file passes the real path). In definitions mode, `- curl` means apt, dnf and brew all equal `curl`.
- `load_os_packages`: loads `$APPS_DIR/os-packages.yaml` once into associative arrays `OSPKG_APT`, `OSPKG_DNF`, `OSPKG_BREW`. A missing file is fine.
- `resolve_tool name source_label`: appends one entry to the `PKG_*` arrays or logs an error and returns 1.
- `dedupe_packages`: keeps each name once at its first position, using the last entry's definition. Called at the end of `load_packages_for_profile`, on both paths.

Folder tool mapping: `apt/dnf/brew` from `install:`; `check` from `install:`; script `<name>/install.sh` when that file exists; dropin `<name>/<dropin>`; config dir `<name>` and flags `configure_flags` when `configure.sh` exists.

- [ ] Write `test-resolve.sh`, running against a copy of the tree in a temp dir with `sync --dry-run --no-pull --hosts-dir ... --hostname ...`, asserting on the `Packages:` line, exit code and logged package names:
  - name from a folder, a one-line `os-packages.yaml` entry and a long-form one, each giving the right package name (including `apt` differing from `brew`)
  - unknown name aborts naming the tool and file; also from `extra:` in `host.yaml`; nothing written under `HOME`
  - name in both a folder and `os-packages.yaml` aborts
  - `- name: x` alone aborts
  - inline entry replaces a folder definition with no merging
  - `extra: [tool]` already listed: once, at first position
  - `include:` of a name not inherited aborts; `exclude:` of an absent name doesn't
  - a defined tool no profile lists is not in `Packages:`
  - tool-only app: no config phase; config-only app: `configure_flags` reaches `configure.sh` (real sync of a fixture app under the temp `HOME`)
  - each Review Focus line above
- [ ] Run it. Expected: fails on plain names.
- [ ] Implement in `lib/profile.sh`. In `load_manifest`, test for a top-level key before the subsection branches, so a section after a `custom:` entry ends the list.
- [ ] Run the new test, then core and app suites. Expected: all pass.
- [ ] Commit: `Profiles: resolve plain tool names from apps/ and os-packages.yaml`.

### Task 4: Migrate `complete` and document

**Files:** `apps/os-packages.yaml` (new), `apps/{git,bash,tmux,vim,scripts,claude}/config.yaml`, `apps/{lazygit,lazyssh}/config.yaml` (new), `profiles/complete.yaml`, `test/apps/test-packages.sh`, `test/apps/test-resolve.sh`, `docs/schema.md`, `docs/superpowers/HANDOFF.md`.

- [ ] Add a test: `complete` resolves to the exact list in Global Constraints with the same `apt`/`dnf`/`brew` values as today (git has no `brew`), and `minimal` excludes `claude lazygit lazyssh`. Run it against the old profile first: it should pass, which pins today's behaviour before migrating.
- [ ] Move each entry's fields into `install:` and `os-packages.yaml`, and make `complete.yaml` a list of names. curl, fzf, jq and tree use the one-line form. `bash` gets `configure_flags: --append`.
- [ ] Update `test-packages.sh` Tests 2, 3 and 10, which grep the profile text, to assert the resolved result instead.
- [ ] Rewrite the profile section of `docs/schema.md`; update `HANDOFF.md`, including the one failed sync per machine.
- [ ] Run core, app and Docker suites, one at a time, plus a koi dry run in a temp `HOME` with the real hosts repo. Expected: all pass, and the koi package list is unchanged.
- [ ] Commit: `Migrate complete profile to tool names; document apps/ layout`.
