#!/usr/bin/env bash
# Start the rebase of workspace-cli onto mainline; STOP at the conflict (do not abort).
set -uo pipefail
cd "$HOME/projects/rust/jj-gwi" || exit 1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="GWI" GIT_AUTHOR_EMAIL="gwi@example.invalid"
export GIT_COMMITTER_NAME="GWI" GIT_COMMITTER_EMAIL="gwi@example.invalid"
export GIT_MERGE_AUTOEDIT=no

# Make sure we start clean on the branch tip.
git rebase --abort 2>/dev/null || true
git checkout --quiet --force workspace-cli
git reset --hard --quiet origin/workspace-cli 2>/dev/null || git reset --hard --quiet 930f386f4

echo "start: $(git log -1 --format='%h %s')"
if git rebase mainline > /tmp/gwi_rebase.out 2>&1; then
  echo "REBASE CLEAN (unexpected — no conflict). tip: $(git log -1 --format='%h %s')"
else
  echo "REBASE STOPPED (expected conflict)."
  echo "--- applying-commit ---"; grep -E "Could not apply|error: could not apply" /tmp/gwi_rebase.out | head -2
  echo "--- conflicted files ---"; git diff --name-only --diff-filter=U
  echo "--- conflict-marker counts ---"
  for f in $(git diff --name-only --diff-filter=U); do
    echo "  $f : <<< $(grep -c '^<<<<<<<' "$f") markers"
  done
fi
echo "REBASE-START DONE"
