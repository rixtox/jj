#!/usr/bin/env bash
# Continue the in-progress rebase; auto-stage resolved files; report if a NEW conflict appears.
set -uo pipefail
cd "$HOME/projects/rust/jj-gwi" || exit 1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="GWI" GIT_AUTHOR_EMAIL="gwi@example.invalid"
export GIT_COMMITTER_NAME="GWI" GIT_COMMITTER_EMAIL="gwi@example.invalid"
export GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true EDITOR=true GIT_MERGE_AUTOEDIT=no

# Safety: refuse to continue if unresolved conflict markers remain anywhere.
if git diff --name-only --diff-filter=U | grep -q . ; then
  for f in $(git diff --name-only --diff-filter=U); do
    if grep -qE '^(<<<<<<<|>>>>>>>)' "$f"; then
      echo "ABORT: unresolved markers still in $f"; exit 2
    fi
  done
fi

git add -u
for i in 1 2 3 4 5 6 7 8 9 10; do
  if git rebase --continue > /tmp/gwi_cont.out 2>&1; then
    echo "REBASE COMPLETE."
    echo "tip: $(git log -1 --format='%h %s')"
    echo "commits on top of mainline: $(git rev-list --count mainline..HEAD)"
    echo "--- rebased commit list ---"
    git log --oneline mainline..HEAD
    exit 0
  fi
  # stopped again
  CF=$(git diff --name-only --diff-filter=U)
  if [ -n "$CF" ]; then
    echo "NEW CONFLICT at: $(grep -E 'could not apply' /tmp/gwi_cont.out | head -1)"
    echo "--- conflicted files ---"; echo "$CF"
    for f in $CF; do echo "  $f : $(grep -c '^<<<<<<<' "$f") markers"; done
    exit 3
  fi
  # no conflict but continue failed for another reason (e.g. empty commit)
  if grep -qiE 'no changes|empty|patch is empty' /tmp/gwi_cont.out; then
    git rebase --skip >/dev/null 2>&1 && continue
  fi
  echo "REBASE continue failed unexpectedly:"; tail -15 /tmp/gwi_cont.out; exit 4
done
echo "loop-exhausted"; exit 5
