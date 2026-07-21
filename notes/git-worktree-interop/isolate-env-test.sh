#!/usr/bin/env bash
set -euo pipefail
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ================= config isolation prelude =================
# Suppress ALL user/system git + jj config (identity, and esp. commit signing
# via x509/ac-sign which prompts for a dummy identity and fails).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="GWI Test"
export GIT_AUTHOR_EMAIL="gwi-test@example.invalid"
export GIT_COMMITTER_NAME="GWI Test"
export GIT_COMMITTER_EMAIL="gwi-test@example.invalid"
export JJ_CONFIG="$WORK/jjconfig.toml"
cat > "$JJ_CONFIG" <<'EOF'
[user]
name = "GWI Test"
email = "gwi-test@example.invalid"
[signing]
behavior = "drop"
EOF
# ============================================================

echo "WORK=$WORK"
echo "=== [1] plain git: init + add + commit must NOT prompt to sign ==="
mkdir "$WORK/g" && cd "$WORK/g"
git init -q .
echo hi > f && git add f
git commit -q -m "test commit"
echo "  GIT COMMIT OK (no signing prompt)"
git config --get commit.gpgsign >/dev/null 2>&1 && echo "  gpgsign SET (bad)" || echo "  gpgsign unset (good)"

echo "=== [2] git worktree add must work (needed by research) ==="
git worktree add -q "$WORK/g-wt" -b wtbranch
echo "  WORKTREE CREATED: $(ls -a "$WORK/g-wt" | tr '\n' ' ')"
echo "  .git file in worktree: $(cat "$WORK/g-wt/.git")"

echo "=== [3] jj colocated: describe + new must NOT prompt ==="
cd "$WORK" && jj git init --colocate repo >/dev/null 2>&1
cd "$WORK/repo"
echo hello > a.txt
jj describe -m first >/dev/null 2>&1 && echo "  JJ DESCRIBE OK"
jj new >/dev/null 2>&1 && echo "  JJ NEW OK"
echo "  jj signing.behavior = $(jj config list signing.behavior 2>/dev/null || echo unset)"
echo "=== ALL GOOD ==="
