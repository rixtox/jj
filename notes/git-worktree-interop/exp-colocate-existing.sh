#!/usr/bin/env bash
# Experiment: how to register a git worktree at an ALREADY-POPULATED directory
# (as needed to colocate an existing jj workspace).
set -uo pipefail
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@e.invalid GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@e.invalid

cd "$WORK"
git init -q main && cd main
echo hello > a.txt && git add a.txt && git commit -q -m first
HEAD_OID=$(git rev-parse HEAD)
COMMON="$WORK/main/.git"

# Simulate an existing (non-colocated) jj secondary workspace: populated dir + .jj/
WS="$WORK/ws2"
mkdir -p "$WS/.jj"
echo hello > "$WS/a.txt"          # matches committed tree
echo "state" > "$WS/.jj/repo"     # jj control files

echo "=== (1) shell-out: git worktree add --orphan onto populated dir (expect FAIL) ==="
git -C "$COMMON" worktree add --orphan -B br1 "$WS" 2>&1 | head -3; echo "exit=${PIPESTATUS[0]}"

echo ""
echo "=== (2) shell-out with -f (expect FAIL too) ==="
git -C "$COMMON" worktree add -f --orphan -B br2 "$WS" 2>&1 | head -3; echo "exit=${PIPESTATUS[0]}"

echo ""
echo "=== (3) NATIVE: write the 4 admin files by hand, HEAD=commit ==="
ID=ws2
mkdir -p "$COMMON/worktrees/$ID"
printf '../..\n' > "$COMMON/worktrees/$ID/commondir"
printf '%s/.git\n' "$WS" > "$COMMON/worktrees/$ID/gitdir"
printf '%s\n' "$HEAD_OID" > "$COMMON/worktrees/$ID/HEAD"
printf 'gitdir: %s/worktrees/%s\n' "$COMMON" "$ID" > "$WS/.git"
printf '/*\n' > "$WS/.jj/.gitignore"
echo "wrote admin files"
echo "--- git -C ws2 status (before index) ---"
git -C "$WS" status 2>&1 | head -8
echo "--- populate the per-worktree index from HEAD tree ---"
git -C "$WS" read-tree HEAD 2>&1; echo "read-tree exit=$?"
echo "--- git -C ws2 status (after read-tree) ---"
git -C "$WS" status --porcelain 2>&1 | head; echo "(clean if empty above)"
echo "--- git -C ws2 worktree list --porcelain ---"
git -C "$WS" worktree list --porcelain 2>&1 | head
echo "--- git -C ws2 rev-parse --git-common-dir & HEAD ---"
git -C "$WS" rev-parse --git-common-dir HEAD 2>&1 | head
echo "DONE"
