#!/usr/bin/env bash
set -uo pipefail
cd "$HOME/projects/rust/jj-gwi" || exit 1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="GWI" GIT_AUTHOR_EMAIL="gwi@example.invalid"
export GIT_COMMITTER_NAME="GWI" GIT_COMMITTER_EMAIL="gwi@example.invalid"

git add docs/git-compatibility.md cli/tests/cli-reference@.md.snap
git commit -q -m "docs: document git-worktree interop for colocated workspaces; regen cli-reference

Updates the git-compatibility support matrix (git-worktree: Yes for colocated
workspaces) covering \`git.auto-register-worktrees\`, \`--colocate\`/\`--no-colocate\`,
and the lazy per-workspace HEAD/index sync. Regenerates the cli-reference snapshot
for the new \`jj workspace add --colocate\` flag."

echo "=== full branch (commits on top of mainline) ==="
git log --oneline mainline..HEAD
echo ""; echo "=== working tree clean? ==="; git status --short || true
echo "DONE"
