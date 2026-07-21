#!/usr/bin/env bash
# Smoke test: colocate an EXISTING non-colocated secondary workspace.
set -uo pipefail
JJ="/Users/naiwei/projects/rust/jj/target/debug/jj"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=D GIT_AUTHOR_EMAIL=d@e.invalid GIT_COMMITTER_NAME=D GIT_COMMITTER_EMAIL=d@e.invalid
export JJ_CONFIG="$WORK/jjconfig.toml"
printf '[user]\nname="D"\nemail="d@e.invalid"\n[signing]\nbehavior="drop"\n' > "$JJ_CONFIG"

cd "$WORK"
"$JJ" git init --colocate repo >/dev/null 2>&1
cd repo
echo hello > a.txt
"$JJ" describe -m first >/dev/null 2>&1
"$JJ" new >/dev/null 2>&1

echo "### add a NON-colocated secondary workspace:"
"$JJ" workspace add --no-colocate ../ws2 2>&1 | sed 's/^/    /'
echo "\$ ls -a ../ws2 :  $(ls -a ../ws2 | tr '\n' ' ')"
echo ""
echo "### git status in ws2 BEFORE colocate (expect failure):"
git -C ../ws2 status 2>&1 | head -2 | sed 's/^/    /'
echo ""
echo "### run 'jj workspace colocate' inside ws2:"
( cd ../ws2 && "$JJ" workspace colocate 2>&1 ) | sed 's/^/    /'
echo ""
echo "### git status in ws2 AFTER colocate (expect success + clean):"
git -C ../ws2 status 2>&1 | sed 's/^/    /'
echo "\$ git -C ../ws2 worktree list --porcelain:"
git -C ../ws2 worktree list --porcelain 2>&1 | sed 's/^/    /'
echo "\$ git -C ../ws2 log --oneline -1:"
git -C ../ws2 log --oneline -1 2>&1 | sed 's/^/    /'
echo ""
echo "### running colocate again (expect idempotent 'already colocated'):"
( cd ../ws2 && "$JJ" workspace colocate 2>&1 ) | sed 's/^/    /'
echo "SMOKE DONE"
