# Finish plan — adopt & complete origin/workspace-cli for GWI-001
Status: **PLAN READY** (awaiting go-ahead to implement). Working clone: `~/projects/rust/jj-gwi`.

## State summary

origin/workspace-cli (10 commits, e50ac0bd7..930f386f4) is a substantially complete, load-time-colocation implementation of GWI-001, but it diverges from our decisions in one structural way and leaves two hard blockers plus a large test-coverage debt. Verified on branch. Core machinery is present and sound: (a) MaybeColocatedGitRepo resolves ONE gix handle per backend at load time by canonicalized common_dir() comparison, and backend factories thread workspace_root so each workspace's backend is loaded pointed at its own worktree (2743b9ca9/6d5e43ccc/ce4151e95); (b) per-workspace git_head is a new op-store map (workspace_git_heads, proto tag 13) that is additive and forward/backward compatible (e2e0c705a) — D2-B is adopted correctly and migration-safe; (c) reset_head_at_workspace and import_head are workspace-scoped and no longer clobber main HEAD (Blockers #3/#4 handled); (d) import_worktree_heads enumerates all worktrees on import (bf9855864, Blocker #4); (e) workspace add shells out to `git worktree add --orphan` and writes .jj/.gitignore (Blocker #2 handled), forget shells out to `git worktree remove`, and colocation disable refuses with live worktrees (Blocker #6 handled). Remaining work has three buckets. BUCKET 1 (behavioral gaps / blockers): AC12 `jj util gc` is a CONFIRMED blocker — run_git_gc has no gc.worktreePruneExpire=never so gc can prune a live worktree's HEAD; and update_intent_to_add (Blocker #1, AC1b) has NO workspace parameter — index routing works only because the backend was loaded at the acting workspace, with no explicit guard. BUCKET 2 (D4 reconcile): the branch has NO `--colocate` flag and NO config gate — it auto-colocates unconditionally when the parent is colocated with only `--no-colocate` opt-out; we must add `git.auto-register-worktrees` (default true) to gate auto behavior and satisfy AC7, and optionally add an explicit `--colocate` flag for symmetry. BUCKET 3 (tests): many ACs are partial/missing — clean `git status` in ws2 (AC1), index==tree + git-diff==jj-diff (AC1/AC1b), --porcelain/prunable/--git-common-dir (AC2), conflicted/merge/unborn @ in ws2 (AC4/AC5/AC5b), forget admin-dir deletion assertions (AC6/AC6b), realpath/prunable (AC11), gc (AC12), export locking (AC13), undo-after-add (AC14). Overall: ~70% done; finish work is 1 blocker fix + 1 defense-in-depth fix + D4 config + a substantial test pass, then rebase/regen snapshots.

## Acceptance-criteria status (branch as-is)

| AC | Status | Note |
|----|--------|------|
| AC1 | **partial** | add.rs creates worktree + .jj/.gitignore and jj status works (test_git_colocated.rs:633,678); but no test asserts `git status` CLEAN in ws2 (forget tests imply jj-checked-out files show untracked), and index==wc-parent tree in ws2 is unasserted. |
| AC1b | **partial** | update_intent_to_add (git.rs:2167) has NO workspace param; routing relies on GitBackend being loaded at ws2's root. Plausibly correct for the acting workspace but has no ws2-specific test and no defense if backend loaded elsewhere. |
| AC2 | **partial** | forget test uses plain `git worktree list` (test_git_colocated.rs:1056); no --porcelain/prunable/--git-common-dir assertions. Impl uses --porcelain in colocation.rs:254 but untested at this granularity. |
| AC3 | **partial** | test at test_git_colocated.rs:745-759 asserts HEAD==requested rev after add; independent_heads shows commit advances only ws2 HEAD. Not directly asserted: edit-without-new leaves HEAD, and `jj new` moves it, for ws2. |
| AC4 | **missing** | Conflict index-stage tests exist only for DEFAULT workspace at lib level (test_git.rs:3877); no secondary-worktree conflicted-@ index test. |
| AC5 | **partial** | test_workspace_add_colocate_empty_repo (test_git_colocated.rs:800) covers whole-repo unborn add via --orphan, no crash; refs/jj/root only tested for DEFAULT (test_git.rs:3574); unborn-@ index inspection in ws2 uncovered. |
| AC5b | **missing** | No test creates a merge working-copy commit in a secondary colocated workspace; merge-index behavior tested only for DEFAULT (test_git.rs:3877). |
| AC6 | **partial** | forget --cleanup --force via `git worktree remove` (forget.rs:153); tests assert absence from `git worktree list` (test_git_colocated.rs:1056,1115). Not asserted: admin dir/gitlink actually deleted; plain `forget` (no --cleanup) leaving files is only covered on non-colocated/dirty paths. |
| AC6b | **partial** | test_workspace_forget_handles_missing_worktree (test_git_colocated.rs:1183) asserts command succeeds (stderr 'is not a working tree' -> continue, forget.rs:169); does not assert COMMON/worktrees/ID pruned. |
| AC7 | **missing** | Config key does not exist anywhere on branch (grep=0). Behavior is auto-detect-from-parent with only --no-colocate opt-out. This is the core D4 reconcile gap. |
| AC8 | **done** | test_workspace_forget_non_colocated_no_git_cleanup (test_git_colocated.rs:1219) + not_moving_head (:75); test_workspaces.rs:1357 uses --no-colocate. Covered with test. |
| AC9 | **done** | colocation.rs:243-276 refuses unless --force; tests test_git_colocation.rs:120 (exact error snapshot) + :151 (--force preserves both workspaces' data). |
| AC10 | **partial** | reset_head_at_workspace is per-workspace (git.rs:1887); test_colocated_workspace_independent_heads asserts primary HEAD unchanged when committing in ws2. But covers commit-in-ws2, not an explicit `jj git reset`-style command in ws2; AC's 'reset' wording only indirectly covered. |
| AC11 | **missing** | dunce::canonicalize used in git_util.rs / git_backend.rs common_dir compare, and .git-symlink edge tests exist, but no /tmp->/private/var realpath test and no 'prunable' assertion. |
| AC12 | **missing** | CONFIRMED blocker: run_git_gc (git_backend.rs:928-935) runs `git gc --prune=@<ts> +0000` with no `-c gc.worktreePruneExpire=never`; git gc auto-prunes worktrees, can delete a live worktree's HEAD GC-root. No test. |
| AC13 | **missing** | No CLI test exports a bookmark from ws2 with sibling worktrees; pre-existing lib export tests only pass WorkspaceName::DEFAULT. Sibling-worktree locking safety untested. |
| AC14 | **missing** | No test runs `jj undo` right after `jj workspace add`; forget.rs documents post-tx cleanup but undo-after-add semantics are neither tested nor documented in add.rs. |
| AC15 | **done-needs-test** | Snapshots updated (op-hash churn in test_workspaces.rs; git_head() template markers in test_git_init.rs) consistent with green, but must run `cargo test` after rebase to confirm. |

## Ordered tasks

### T1: Add git.auto-register-worktrees config (default true) to config schema + docs
D4 reconcile: the automatic default needs a real config knob to gate it and to satisfy AC7. Add the key alongside the pre-existing git.colocate.

Files: `cli/src/config/misc.toml`, `cli/src/config-schema.json`, `cli/src/config/mod.rs (if a typed accessor/struct exists)`

### T2: Wire auto-register-worktrees into workspace add colocate decision + add explicit --colocate flag (after T1)
Reconcile D4: change colocate_requested so that if --no-colocate=>false; if --colocate=>true; else parent_is_colocated && settings.get_bool(git.auto-register-worktrees). Keeps the flag mechanism AND the automatic default. This directly implements AC7's escape hatch.

Files: `cli/src/commands/workspace/add.rs`

### T3: Fix jj util gc to not prune live worktree registrations
CONFIRMED blocker (AC12): run_git_gc (git_backend.rs:928-935) runs `git gc --prune=@<ts>` with no worktree protection; git gc auto-runs `git worktree prune` and can delete a live worktree HEAD's GC-root. Add `-c gc.worktreePruneExpire=never` to the git invocation.

Files: `lib/src/git_backend.rs`

### T4: Harden update_intent_to_add index routing for secondary worktrees (Blocker #1 / AC1b defense-in-depth)
update_intent_to_add (git.rs:2167) takes no workspace param and writes whatever index the load-time backend resolved. Add an optional workspace_path (mirroring reset_head_at_workspace) OR a debug_assert that the resolved git_repo.workdir/common_dir matches the acting workspace, and thread the acting workspace through export_working_copy_changes_to_git (cli_util.rs:2604).

Files: `lib/src/git.rs`, `cli/src/cli_util.rs`

### T5: Test AC1/AC1b: git status CLEAN + index==wc-parent tree + git diff==jj diff in ws2 (after T2, T4)
Highest-priority missing coverage. Assert `git -C ws2 status --porcelain` empty after add (fix .gitignore/index sync if not), index equals wc-parent tree, and after an edit `git -C ws2 diff`==`jj -R ws2 diff` (exercises T4).

Files: `cli/tests/test_git_colocated.rs`

### T6: Test AC7: git.auto-register-worktrees=false -> non-colocated ws2, no .git (after T2)
Verifies the new config gate produces today's behavior. Also add a --colocate-forces-colocation test for symmetry.

Files: `cli/tests/test_git_colocated.rs`

### T7: Test AC12: util gc with live secondary worktree keeps worktrees/ID + HEAD resolvable (after T3)
Regression test for T3: colocated add ws2, commit in ws2, run `jj util gc`, assert COMMON/.git/worktrees/<ID> still exists, ws2 HEAD commit still resolves, ws2 jj+git status still work.

Files: `cli/tests/test_git_colocated.rs`

### T8: Test AC4/AC5/AC5b: conflicted / unborn / merge @ in secondary worktree index stages (after T2)
Add ws2 variants of the DEFAULT-workspace lib tests: conflicted @ -> correct index stages; root/unborn @ -> no crash; merge @ -> HEAD=parent[0] and index from first-parent tree; verify via get_index_state on ws2 + `git -C ws2 status`.

Files: `cli/tests/test_git_colocated.rs`, `lib/tests/test_git.rs`

### T9: Test AC6/AC6b: forget deletes admin dir + gitlink; already-deleted DEST prunes cleanly (after T2)
Strengthen forget coverage: assert COMMON/worktrees/<ID> admin dir and ws2 gitlink are gone after `forget --cleanup`, ws2 files remain; and that after DEST deleted the registration is actually pruned (not just command success).

Files: `cli/tests/test_git_colocated.rs`

### T10: Test AC2/AC11: --porcelain/no-prunable/--git-common-dir + symlinked-tmpdir realpath (after T2)
Assert `git -C main worktree list --porcelain` lists ws2 with no 'prunable' line and `git -C ws2 rev-parse --git-common-dir` -> main/.git; add a /tmp->/private/var symlinked-parent test asserting ws2 not reported prunable.

Files: `cli/tests/test_git_colocated.rs`

### T11: Test AC13/AC14: bookmark set + git export from ws2 (sibling locking) and jj undo after add (after T2)
AC13: export a bookmark from ws2 with a sibling worktree, assert sibling HEADs unaffected and no lock error. AC14: `jj undo` immediately after `jj workspace add`, assert worktree admin files survive; document the intended semantics in add.rs.

Files: `cli/tests/test_git_colocated.rs`, `cli/src/commands/workspace/add.rs`

### T12: Migrate stopgap git-CLI colocate tests to real `jj workspace add` (after T2)
independent_heads/in_bare_repo/moved_original/wrong_gitdir/invalid_gitdir use a stopgap helper with manual `git worktree add`; the TODOs flag migrating to the real command so production paths are exercised and tests don't silently skip when git is absent.

Files: `cli/tests/test_git_colocated.rs`

### T13: Add concurrent-op merge test for workspace_git_heads
merge_view (repo.rs:2012-2021) merges the per-workspace map via merge_ref_targets but is untested; add a test with two divergent concurrent ops setting the same and different workspace heads, then merge and assert results.

Files: `lib/tests/test_git.rs`, `lib/tests/test_operations.rs`

### T14: Retitle/split misleading commits + reconcile docs during history cleanup (after T2)
5da8385a3 title claims worktree logic in MaybeColocatedGitRepo but adds none; 4db2bc4ac title says '--colocate' but implements --no-colocate. During review-prep, retitle so messages match diffs; update user docs for the new --colocate flag + git.auto-register-worktrees.

Files: `docs/ (git colocation docs)`, `(commit messages during history edit)`

### T15: Regenerate cli-reference snapshot + run full suite (after T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13)
Adding --colocate/git.auto-register-worktrees changes the CLI reference snapshot; run cargo insta and the full test suite (AC15) to confirm all existing test_workspaces/test_git_colocated/test_git_colocation tests pass after rebase.

Files: `cli/tests/cli-reference@.md.snap`, `cli/tests/*.snap`

## Divergences from our decisions
- D4 (primary): The branch has NO opt-in `--colocate` flag on `jj workspace add` and NO config gate. It auto-colocates unconditionally whenever the parent workspace is colocated (add.rs:147-153, is_colocated_git_workspace), with only a `--no-colocate` opt-out. Our decision: KEEP a flag mechanism AND add `git.auto-register-worktrees` (bool, default true) as the automatic-default switch. Change: add the config (T1), change colocate_requested to `if no_colocate {false} else if colocate {true} else {parent_is_colocated && settings.get_bool("git.auto-register-worktrees")?}` (T2), and add an explicit `--colocate` flag for symmetry with git init/clone. AC7 depends entirely on this.
- git.colocate is NOT new: it exists on main (misc.toml:28, schema:542) and only governs `jj git init`/`jj git clone`, not `workspace add`. Do not conflate it with the new auto-register-worktrees key; add the new key next to it.
- Blocker #5 (gc) is NOT handled by the branch: run_git_gc (git_backend.rs:928-935) emits `git gc --prune=@<ts> +0000` with no `-c gc.worktreePruneExpire=never`. Must add worktree-prune protection (T3). This contradicts any assumption the branch is gc-safe for colocated worktrees.
- Blocker #1 (mutable-@ index routing) is only IMPLICITLY handled: update_intent_to_add (git.rs:2167) has no workspace parameter, unlike reset_head_at_workspace which re-opens `<workspace_path>/.git`. Routing is correct only because the backend was load-time-resolved for the acting workspace. Add defense-in-depth (explicit path or debug_assert) per T4; do not treat it as robustly guaranteed.
- Commit-message drift: 4db2bc4ac ('workspace add --colocate') implements --no-colocate; 5da8385a3 ('Add worktree support to MaybeColocatedGitRepo') adds no worktree-opening logic to that type (it refactors load/load_at_workspace + docs). Retitle during history cleanup (T14).
- reset_head_at_workspace and import_worktree_heads use their own raw `<ws>/.git` open + common_dir check rather than routing through MaybeColocatedGitRepo::open_automatic, duplicating the canonicalized colocation detection. Not a correctness blocker but a divergence worth a shared helper if time permits.

## Risks
- AC12/gc is a data-loss risk: without gc.worktreePruneExpire=never, `jj util gc` (or an auto-gc) can prune a live secondary worktree registration and let its HEAD commit be garbage-collected, corrupting ws2. Must land T3 before shipping.
- Blocker #1 latent misroute: because update_intent_to_add relies on the load-time backend handle with no explicit workspace, any future caller that builds a mut_repo whose backend was not loaded at the acting workspace will silently write intent-to-add into the wrong worktree's index. T4 mitigates but the abstraction remains fragile.
- AC1 clean-status uncertainty: forget tests reveal jj-checked-out files appear untracked from git's view (needs --force), which may mean `git status` is NOT clean in ws2 after add. If T5 fails, the add path (index sync to wc-parent tree and/or .gitignore scope) needs fixing, which could be more than a test — schedule T5 early to surface this.
- Hard runtime dependency on the `git` binary: add/forget/colocation-disable shell out to `git worktree` via bare Command::new("git") with no git.executable-path resolution and no Windows .exe/UNC handling. Colocated flows will fail on git-less environments and are untested on Windows.
- Snapshot churn / merge conflicts on rebase: op-hash snapshots (test_workspaces.rs) and the ViewId hash (simple_op_store.rs:1085) changed due to workspace_git_heads; rebasing onto a moved main plus adding --colocate/config will require regenerating cli-reference and insta snapshots (T15) and may conflict.
- Scope risk on AC7: if the design owner decides auto-register-worktrees is out of scope, AC7 must be explicitly marked deferred; do not silently leave the unconditional auto-colocate behavior, which has no user-facing off switch other than per-invocation --no-colocate.
- proto backward-compat depends on empty-map filtering: workspace_git_heads is filtered on serialize so unchanged views keep their hash; if a future edit stops filtering absent/empty entries, existing op hashes break and old jj compatibility assumptions change.
