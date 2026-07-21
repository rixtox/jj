#!/usr/bin/env bash
set -uo pipefail
cd "$HOME/projects/rust/jj-gwi" || exit 1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="GWI" GIT_AUTHOR_EMAIL="gwi@example.invalid"
export GIT_COMMITTER_NAME="GWI" GIT_COMMITTER_EMAIL="gwi@example.invalid"

git add cli/tests/test_git_colocated.rs
git commit -q -m "tests: cover secondary-workspace Git status/diff, worktree metadata, merge/conflict/undo

Adds regression tests for colocated secondary workspaces (GWI-001 ACs):
- clean \`git status\` after add + \`git diff\` == \`jj diff\` after an edit (AC1/AC1b);
- \`git worktree list --porcelain\` non-prunable + \`rev-parse --git-common-dir\`,
  which on macOS also guards realpath handling (\`/var\` vs \`/private/var\`) (AC2/AC11);
- merge working-copy commit -> Git HEAD is the first parent (AC5b);
- conflicted working-copy commit -> \`git status\` does not crash (AC4);
- \`jj undo\` after \`workspace add\` does not crash (AC14)."

echo "=== commits on top of mainline ==="
git log --oneline mainline..HEAD | head -6
echo ""; echo "=== working tree ==="; git status --short || true
echo "DONE"
