#!/usr/bin/env bash
set -uo pipefail
cd /Users/naiwei/projects/rust/jj
# Regenerate cli-reference snapshot (adds `jj workspace colocate`)
INSTA_UPDATE=always ~/.cargo/bin/cargo test -p jj-cli --test runner -- test_generate_md_cli_help 2>&1 | tail -4
rm -f cli/tests/cli-reference@.md.snap.new
echo "=== snapshot diff (expect only 'workspace colocate' additions) ==="
git diff --stat -- cli/tests/cli-reference@.md.snap
git diff -- cli/tests/cli-reference@.md.snap | grep -E '^\+' | grep -iE 'colocate' | head
echo ""
echo "=== full worktree/colocation/workspaces suite + cli-reference ==="
~/.cargo/bin/cargo test -p jj-cli --test runner -- git_colocat workspaces test_generate_md_cli_help 2>&1 | grep -E "test result:|FAILED" | tail -5
