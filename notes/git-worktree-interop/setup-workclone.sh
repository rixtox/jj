#!/usr/bin/env bash
# Set up a durable working clone for the adopt-and-finish work, OUTSIDE the jj-guarded tree.
set -uo pipefail
SRC="/Users/naiwei/projects/rust/jj"
DEST="$HOME/projects/rust/jj-gwi"

# config isolation (no signing prompts on any commit/rebase)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="GWI" GIT_AUTHOR_EMAIL="gwi@example.invalid"
export GIT_COMMITTER_NAME="GWI" GIT_COMMITTER_EMAIL="gwi@example.invalid"

if [ -d "$DEST/.git" ]; then
  echo "clone already exists at $DEST"
else
  echo "cloning $SRC -> $DEST (local hardlinks)"
  git clone --quiet --local "$SRC" "$DEST"
fi
cd "$DEST"
git fetch --quiet "$SRC" \
  'refs/remotes/origin/workspace-cli:refs/heads/workspace-cli' \
  'refs/remotes/origin/main:refs/heads/mainline' 2>&1 | tail -2
echo "checkout workspace-cli tip (un-rebased) for a warm/toolchain-sanity build"
git checkout --quiet workspace-cli
echo "HEAD: $(git log -1 --format='%h %s')"
echo "DEST=$DEST"
echo "SETUP DONE"