#!/usr/bin/env bash
# install.sh - TEST FIXTURE, not a real tool. Used only by test/apps/test-sync.sh
# through test/fixtures/hosts-dir/profiles/pendingtest.yaml; keep it out of every
# real profile. "Installs" by touching $DOTFILES_TEST_MARKER; fails without it.
set -euo pipefail
[[ -n "${DOTFILES_TEST_MARKER:-}" ]] || exit 1
touch "$DOTFILES_TEST_MARKER"
# DOTFILES_TEST_SUDO=1: call sudo like a real installer does, so the test can see its args
if [[ "${DOTFILES_TEST_SUDO:-}" == 1 ]]; then sudo testtool-install; fi
