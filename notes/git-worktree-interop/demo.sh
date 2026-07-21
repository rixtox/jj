#!/usr/bin/env bash
# End-to-end demo: git commands work inside a secondary jj workspace (the original goal).
set -uo pipefail
JJ="$HOME/projects/rust/jj-gwi/target/debug/jj"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="Demo" GIT_AUTHOR_EMAIL="demo@example.invalid"
export GIT_COMMITTER_NAME="Demo" GIT_COMMITTER_EMAIL="demo@example.invalid"
export JJ_CONFIG="$WORK/jjconfig.toml"
printf '[user]\nname="Demo"\nemail="demo@example.invalid"\n[signing]\nbehavior="drop"\n' > "$JJ_CONFIG"

cd "$WORK"
"$JJ" git init --colocate repo >/dev/null 2>&1
cd repo
echo "hello" > a.txt
"$JJ" describe -m "first commit" >/dev/null 2>&1
"$JJ" new >/dev/null 2>&1

echo "### Create a SECOND jj workspace (this is what used to have no .git):"
"$JJ" workspace add ../ws2 2>&1 | sed 's/^/    /'

echo ""
echo "### BEFORE this work, ../ws2 had only .jj/ and git failed. Now:"
echo ""
echo "\$ ls -a ../ws2"
ls -a ../ws2 | tr '\n' ' '; echo
echo ""
echo "\$ git -C ../ws2 status        # <-- THE ORIGINAL FAILURE, now works"
git -C ../ws2 status 2>&1 | sed 's/^/    /'
echo ""
echo "\$ git -C ../ws2 log --oneline -1"
git -C ../ws2 log --oneline -1 2>&1 | sed 's/^/    /'
echo ""
echo "\$ git -C ../ws2 rev-parse --git-common-dir   # shared with main repo"
git -C ../ws2 rev-parse --git-common-dir 2>&1 | sed 's/^/    /'
echo ""
echo "\$ git -C repo worktree list --porcelain"
git -C "$WORK/repo" worktree list --porcelain 2>&1 | sed 's/^/    /'
echo ""
echo "### Edit a file in ws2, then git diff reflects it (per-workspace index):"
echo "world" >> ../ws2/a.txt
"$JJ" -R ../ws2 status >/dev/null 2>&1   # snapshot
echo "\$ git -C ../ws2 status --porcelain"
git -C ../ws2 status --porcelain 2>&1 | sed 's/^/    /'
echo "DEMO OK"
