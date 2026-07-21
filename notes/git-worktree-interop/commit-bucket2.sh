#!/usr/bin/env bash
set -uo pipefail
cd "$HOME/projects/rust/jj-gwi" || exit 1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="GWI" GIT_AUTHOR_EMAIL="gwi@example.invalid"
export GIT_COMMITTER_NAME="GWI" GIT_COMMITTER_EMAIL="gwi@example.invalid"

git add cli/src/config-schema.json cli/src/config/misc.toml \
        cli/src/commands/workspace/add.rs cli/tests/test_git_colocated.rs Cargo.lock
git commit -q -m "workspace add: gate auto worktree registration on git.auto-register-worktrees; add --colocate

Adds the \`git.auto-register-worktrees\` config (bool, default true), distinct
from \`git.colocate\` (which governs \`jj git init\`/\`jj git clone\`). In a colocated
repo, \`jj workspace add\` now registers a Git worktree iff the parent is colocated
AND the config is enabled; \`--colocate\` forces it, \`--no-colocate\` disables it.
This reconciles the automatic-default intent with an explicit opt-out and satisfies
the AC that \`git.auto-register-worktrees=false\` reproduces today's behavior. +test."

echo "=== new commits on top of mainline ==="
git log --oneline mainline..HEAD
echo ""; echo "=== working tree ==="; git status --short || true
echo "DONE"
