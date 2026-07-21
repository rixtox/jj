#!/usr/bin/env bash
# Commit the current working-tree changes in the finish clone as two commits.
set -uo pipefail
cd "$HOME/projects/rust/jj-gwi" || exit 1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="GWI" GIT_AUTHOR_EMAIL="gwi@example.invalid"
export GIT_COMMITTER_NAME="GWI" GIT_COMMITTER_EMAIL="gwi@example.invalid"

echo "=== pre-commit status ==="
git status --short

# Commit 1: rebase fixup (cli_util.rs) — per-workspace HEAD reset wiring.
git add cli/src/cli_util.rs
git commit -q -m "fixup: route Git HEAD reset through per-workspace reset_head_at_workspace

Rebase fixup. On main, try_reset_git_head wraps the 2-arg reset_head; the
workspace-cli stack made reset_head take a workspace name and added
reset_head_at_workspace(.., workspace_path). Thread the acting workspace name
and root through try_reset_git_head and call it from both snapshot_working_copy
and finish_transaction, so secondary colocated workspaces reset their OWN Git
HEAD/index. (Squash into the op_store per-workspace git_head commit in cleanup.)"

# Commit 2: T3 gc worktree-prune protection + T7 regression test.
git add lib/src/git_backend.rs cli/tests/test_git_colocated.rs
git commit -q -m "git: never prune registered worktrees during \`jj util gc\`

\`git gc\` auto-runs \`git worktree prune\` honoring gc.worktreePruneExpire
(default 3 months), which can delete a live colocated workspace's worktree admin
dir and let its detached-HEAD commit be garbage-collected. Pass
\`-c gc.worktreePruneExpire=never\` to the gc subprocess. Adds a regression test
that a working-dir-removed (prunable) worktree survives \`jj util gc --expire=now\`."

echo ""
echo "=== new commits on top of mainline ==="
git log --oneline mainline..HEAD | head -4
echo ""
echo "=== working tree now clean? ==="
git status --short || true
echo "COMMIT DONE"
