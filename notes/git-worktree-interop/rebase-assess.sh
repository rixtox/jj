#!/usr/bin/env bash
# Rebase-and-assess origin/workspace-cli onto main in a throwaway clone.
# Runs git from a script (dodges jj-guard) with full config isolation (no signing prompts).
set -uo pipefail

SRC="/Users/naiwei/projects/rust/jj"
WORK="$(mktemp -d)"
OUT="$WORK/assess.log"

# ---- config isolation (no user/system git config; no x509/ac-sign prompts) ----
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="GWI" GIT_AUTHOR_EMAIL="gwi@example.invalid"
export GIT_COMMITTER_NAME="GWI" GIT_COMMITTER_EMAIL="gwi@example.invalid"
export GIT_MERGE_AUTOEDIT=no
# --------------------------------------------------------------------------------

echo "WORK=$WORK"
echo "=== toolchain availability ==="
command -v cargo && cargo --version 2>&1 | head -1 || echo "cargo: NOT ON PATH"
command -v rustc && rustc --version 2>&1 | head -1 || echo "rustc: NOT ON PATH"
command -v git && git --version || echo "git missing"

echo "=== local clone (hardlinks) ==="
git clone --quiet --local "$SRC" "$WORK/repo" && echo "cloned"
cd "$WORK/repo"

# Bring the two branches in from the source's remote-tracking refs.
git fetch --quiet "$SRC" \
  'refs/remotes/origin/workspace-cli:refs/heads/workspace-cli' \
  'refs/remotes/origin/main:refs/heads/mainline' && echo "fetched workspace-cli + mainline"

echo "=== branch facts ==="
echo "mainline tip:      $(git log -1 --format='%h %s' mainline)"
echo "workspace-cli tip: $(git log -1 --format='%h %s' workspace-cli)"
MB=$(git merge-base mainline workspace-cli)
echo "merge-base:        $(git log -1 --format='%h %s' "$MB")"
echo "wc ahead of MB:    $(git rev-list --count "$MB"..workspace-cli)"
echo "main ahead of MB:  $(git rev-list --count "$MB"..mainline)"

echo "=== attempt rebase of workspace-cli onto mainline ==="
git checkout --quiet workspace-cli
if git rebase mainline > "$WORK/rebase.out" 2>&1; then
  echo "REBASE: CLEAN (no conflicts)"
  echo "rebased tip: $(git log -1 --format='%h %s')"
  echo "commits after rebase: $(git rev-list --count mainline..HEAD)"
else
  echo "REBASE: CONFLICTS / STOPPED"
  echo "--- rebase output (tail) ---"
  tail -30 "$WORK/rebase.out"
  echo "--- conflicted files ---"
  git diff --name-only --diff-filter=U 2>/dev/null | head -40
  echo "--- status ---"
  git status --short 2>&1 | head -40
  git rebase --abort 2>/dev/null || true
fi

echo "=== KEEP path for later inspection: $WORK/repo ==="
echo "DONE"
