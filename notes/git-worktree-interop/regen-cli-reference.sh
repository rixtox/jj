#!/usr/bin/env bash
# Regenerate the cli-reference insta snapshot canonically (adds the new --colocate flag).
set -uo pipefail
cd "$HOME/projects/rust/jj-gwi" || exit 1
export INSTA_UPDATE=always
~/.cargo/bin/cargo test -p jj-cli --test runner -- test_generate_md_cli_help 2>&1 | tail -8
# Remove any leftover pending snapshot.
rm -f cli/tests/cli-reference@.md.snap.new
echo "=== git diff --stat of the snapshot ==="
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git diff --stat -- cli/tests/cli-reference@.md.snap
echo "REGEN DONE"
