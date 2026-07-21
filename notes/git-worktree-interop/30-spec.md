# Spec: Git-worktree interoperability for jj workspaces (MVP) — v2

Status: **REVISED after adversarial review** (pending human approval; then plan)
Decisions baked in: D1 native · D2 lazy-derive HEAD *(see §10 — flagged for re-confirm)* · D3 lazy sync · D4 **automatic** · D5 colocated-only MVP · D6 new code path

> v2 folds in all blockers/majors from the spec-review workflow (5 reviewers, verified against tree HEAD `74ed79525`). Change log at §11.
> Line numbers below are corrected to the reviewed tree; treat as guideposts (they drift).

---

## 1. Goal & success criteria

**Goal:** plain `git` commands work inside a secondary jj workspace of a colocated repo, showing
the same picture the main colocated workspace shows today.

**Primary success criterion:** In a colocated repo, after `jj workspace add ../ws2`:
- `git -C ../ws2 status/diff/log/show` succeed; **`git status` is clean** for an unmodified workspace;
  HEAD = ws2's wc parent (detached); index == wc-parent tree; **after an edit, `git -C ../ws2 diff` == `jj -R ../ws2 diff`**.
- `git -C <main> worktree list` lists ws2 as a valid, **non-prunable** linked worktree.
- No regression to existing main-colocation or non-colocated-workspace behavior.

---

## 2. User-facing behavior (D4 = automatic)

- **Colocated** repo: `jj workspace add` **automatically** registers a git linked worktree. No flag.
- **Non-colocated** repo: unchanged — no `.git` written; the config key below is a no-op.
- **Safety off-switch (config):** `git.auto-register-worktrees` (bool, default `true`). *(Renamed from
  `git.colocate-workspaces` to avoid confusion with the existing `git.colocate` init/clone key,
  `misc.toml:28`. Naming to finalize in planning — see §5.)* When `false`, `jj workspace add` behaves
  as today (no registration).
- **`jj workspace forget <name>`** performs git-side teardown (**NEW code** — forget touches only the
  op-store + workspace_store today): remove `COMMON/worktrees/ID` and `DEST/.git` (both ignore-if-absent),
  never touch other files in `DEST`. Loop over the multi-workspace forget transaction. If `DEST` was
  already deleted by the user, git would mark the worktree prunable — teardown still removes the admin dir.
- **`jj workspace rename`**: the git worktree **id is immutable across rename**. Because rename does not
  move `DEST`, the git worktree stays valid trivially and no git-side change is required. (Runtime
  name→id lookup is via the persisted id in the workspace_store — see §6, not via the WorkspaceName.)
- **`jj git colocation disable`** with live secondary worktrees: currently has **zero** worktree
  awareness and would **strand** them — the breaker is that disable does `std::fs::rename(.git →
  .jj/repo/store/git)` (`colocation.rs`), moving the common dir out from under every linked worktree
  (`fatal: not a git repository`). *(Not `core.bare=true`; that alone did not break a live worktree in
  git 2.54 experiments.)* **MVP:** disable must enumerate `COMMON/worktrees/*` and **refuse** with a
  clear message if any jj-registered worktree exists. Auto-teardown is a follow-up (§7).

---

## 3. On-disk mechanism (D1 = native)

On `jj workspace add <dest>` in a colocated repo, the worktree files are written **explicitly in
`cmd_workspace_add` AFTER `tx.finish()`** using the just-created `new_wc_commit` (`add.rs:~227-235`) —
**NOT** in the `init_workspace_with_existing_repo` lib seam (`workspace.rs:370-409`), which checks out
the **root** commit (HEAD/index would wrongly point at root). This explicit write is **mandatory**: the
`finish_transaction`/`snapshot` auto-trigger **cannot** fire for the new workspace, because
`working_copy_shared_with_git` is computed once from `is_colocated_git_workspace` at helper construction
(`cli_util.rs:1171`) **before** `.git` exists, and is cached.

Definitions: `COMMON` = shared git dir via `canonicalize_git_repo_path` (`git_backend.rs:561-568`) then
`git_repo_path()` (= `<main>/.git`); `DEST` = `dunce::canonicalize(dest)`; `ID` = persisted opaque
worktree id (§6).

Steps (all realpath-canonical; `/private/var` not `/var` on macOS):
1. `<DEST>/.jj/.gitignore` ← `"/*\n"` (reuse `maybe_add_gitignore`, `cli/src/commands/git/mod.rs`) so
   git ignores the `.jj` control dir. *(Without this, `git status` in ws2 is dirty out of the box.)*
2. `mkdir -p COMMON/worktrees/ID`
3. `COMMON/worktrees/ID/commondir` ← `"../..\n"`
4. `COMMON/worktrees/ID/gitdir` ← `"DEST/.git\n"`
5. `COMMON/worktrees/ID/HEAD` ← raw hex OID of `new_wc_commit.parent_ids()[0]` + `"\n"` (detached).
   Merge @ → use `parent_ids()[0]`. Parent is the jj root commit → unborn placeholder `ref: refs/jj/root\n`.
6. `DEST/.git` (FILE) ← `"gitdir: COMMON/worktrees/ID\n"`
7. `COMMON/worktrees/ID/index` ← written from the wc-parent tree via a **new pub** `reset_worktree_index`
   (see §4), reusing conflicted-@ stage logic (`git.rs:1982-2040`) and merge first-parent handling.

Atomicity: on any partial failure, clean up the partial `worktrees/ID` dir + `DEST/.git`. Note these
writes happen **outside** the jj transaction, so `jj undo`/op-restore will not reverse them (§8 AC, §7).

**Anti-prune (normative, not optional):** realpath resolvability does **not** stop expiry-based pruning.
`jj util gc` shells out to real `git gc` (`git_backend.rs:921`), which auto-runs `git worktree prune`
honoring `gc.worktreePruneExpire` (default 3 months) → a long-idle registered worktree is silently pruned.
**MVP mitigation:** pass `-c gc.worktreePruneExpire=never` to the gc subprocess (`git_backend.rs:924-928`).
*(Alternative considered: a per-worktree `locked` file — more targeted but adds cleanup obligation on
forget; deferred.)*

---

## 4. Sync model (D3 = lazy)

### 4.1 Write sites to parameterize (exhaustive — this is the core work)
Every `get_git_repo(store)`-derived HEAD/index write reached from `snapshot_working_copy`
(`cli_util.rs:2121/2124`) **and** `finish_transaction` (`cli_util.rs:2314/2316`, via
`try_reset_git_head` `cli_util.rs:2638-2651`) must target **the acting workspace's own** worktree:

- **Immutable-@ branch** (`cli_util.rs:2122-2124`) → `reset_head`/`reset_index` (`git.rs:1797/1877`).
- **Mutable-@ hot path** (`cli_util.rs:2133-2139`, the common case for an ordinary edit) →
  `export_working_copy_changes_to_git` (`cli_util.rs:2615`) → **`update_intent_to_add` /
  `update_intent_to_add_impl`** (`git.rs:2051-2068`), which today hardcodes `get_git_repo(repo.store())`
  (the MAIN handle) and writes the MAIN index (`git.rs:2056`). **This MUST be parameterized too** — else
  `echo x >> f` in ws2 writes the main index and `git -C ws2 diff` ≠ `jj -R ws2 diff` (AC1 fails).
- ⚠️ **Exhaustive audit required:** any missed `get_git_repo(store)` write site silently writes the main
  worktree's index/HEAD with no error. The plan includes a grep-audit of all such sites reached from
  snapshot/finish (residual risk).

### 4.2 Obtaining a per-workspace gix handle (OQ2 resolved)
jj has **no** per-worktree handle today: `GitBackend.base_repo` is opened once at `<main>/.git`;
`git_repo()`/`get_git_repo()` always return the MAIN handle (`git_backend.rs:356-358`). Acquire a
worktree-scoped handle via `git_repo.worktrees()` → `worktree::Proxy` →
`into_repo_with_possibly_inaccessible_worktree()` (`git.rs:1353`; jj already iterates `worktrees()` at
`git.rs:1349-1356`). For a linked-worktree handle, gix `git_dir() = COMMON/worktrees/ID`, so
`index_path()`, `index_from_tree`, and the `HEAD` PseudoRef all route into `worktrees/ID/` **(OQ1
CONFIRMED — no spike needed)**. Pass this handle into the generalized reset/intent-to-add functions.

### 4.3 HEAD write for a secondary worktree (blocker #2 fix)
`reset_head` (`git.rs:1797`) is coupled to the single global op-store `git_head`: it builds its
optimistic-lock `PreviousValue` guard from `mut_repo.git_head()` (`git.rs:1811`) and calls
`mut_repo.set_git_head_target()` (`git.rs:1832`). Routed naively to a secondary this uses a wrong guard
and clobbers the **main** workspace's HEAD tracking. For a secondary worktree:
- (a) build the `PreviousValue` guard from the worktree's **own on-disk HEAD** (via the worktree-scoped
  gix handle / `COMMON/worktrees/ID/HEAD`), **not** `mut_repo.git_head()`;
- (b) **do NOT** call `set_git_head_target()` (leave the shared `git_head` untouched — consistent with
  D2 lazy-derive).
`reset_index` (`git.rs:1877-1881`) already takes the passed-in `git_repo`, so **no signature change** —
but it is private; add a **pub `reset_worktree_index(repo, worktree_gix, wc_commit)`** wrapper for §3.7
that writes only the index to an arbitrary handle.

### 4.4 Trigger (lazy) & inbound import
- Lazy: on tx-committing commands, reset **only the acting workspace's** worktree HEAD+index. A
  cross-workspace @ rewrite leaves the other workspace's git view stale until that workspace next runs a
  mutating jj command — **matching today's stale-working-copy UX** (documented).
- **Inbound import (blocker #4 fix):** the lib `import_head` (`git.rs:1165`; `import_git_head` at
  `cli_util.rs:1319` is only the CLI wrapper) reads the shared `head_id()` and writes the single
  `set_git_head_target` (`git.rs:1168/1197`). Running it unchanged for a secondary would import the
  **main** HEAD as ws2's wc parent — an active bug. **MVP decision: DISABLE inbound HEAD import for
  secondary worktrees** (documented: an external `git checkout` inside ws2 is *not* re-imported into jj;
  use jj commands to move @). Redirecting import to the worktree's own HEAD is a follow-up (§7).

### 4.5 Locking & tree-cache (OQ4)
- **Locking clause (normative):** any write to a worktree HEAD/index — **including the existing
  `export_some_refs` per-worktree `check_and_detach_head` loop** (`git.rs:1349-1356`), which already
  reaches into *every* sibling worktree's HEAD on any ref export — MUST hold the repo-global
  `git_import_export.lock` (`cli_util.rs:1216`). Define ordering so A's export does not silently discard
  an un-imported external `git checkout` in sibling B (guard/defer a cross-worktree HEAD touch when that
  worktree's on-disk HEAD diverges from its lazily-derived value).
- **Tree-cache staleness:** when the per-worktree index entries change (not just the add-time build),
  invalidate the gix index tree extension (`State::remove_tree`, gix-index #2421) before write.

---

## 5. Config & docs

- New config key **`git.auto-register-worktrees`** (bool, default `true`) in `config-schema.json` +
  `misc.toml`, with a description distinguishing it from `git.colocate` (`misc.toml:28`,
  `config-schema.json:542`); explicitly a no-op in a non-colocated repo. *(Final key name to confirm.)*
- Update `docs/git-compatibility.md`: change "git-worktree: No" → describe automatic registration, the
  off-switch, the lazy-sync/staleness semantics, the disabled inbound import, and lifecycle.
- Update `jj workspace add` help text.

---

## 6. Worktree ID derivation (OQ3 resolved)

Persist an **opaque, stable worktree id** in the `SimpleWorkspaceStore` entry (which already stores
name→relpath). *(The prior "recompute from `gitdir`" idea is FALSE — `gitdir` stores `DEST/.git` (a path),
not the WorkspaceName; free-form `--name`/basename + rename break path-derivation.)* Persisting makes
rename a git-side no-op and sanitization deterministic. Rules:
- Sanitize from the WorkspaceName to a filesystem-safe charset; define collision suffixing; handle
  case-insensitive filesystems; reject reserved names.
- **Dedup scans the on-disk `COMMON/worktrees/*` set** (which includes user-created worktrees), not the
  jj workspace list.
- Out-of-band `git worktree remove`: lazy reconciliation — re-create admin files on the workspace's next
  mutation, or error clearly (define which in planning).

---

## 7. Out of scope (deferred follow-ups)

1. `--git-repo` external-mode worktrees.
2. Eager cross-workspace HEAD/index sync + explicit `jj workspace sync-git` command.
3. Bidirectional inbound import (external `git checkout`/`commit` inside a worktree) — and the op-store
   per-workspace `git_head` map it may require (D2 option 2 — see §10).
4. `git worktree repair`-equivalent for moved repos; **Windows/WSL absolute-path portability** (MVP is
   macOS/Linux-focused per AC11).
5. Relaxing the `#8052` `jj git init --colocate`-inside-a-worktree guard — and confirming the widened
   `is_colocated_git_workspace` does **not** newly bypass it.
6. `jj git colocation disable` **auto-teardown** of secondary worktrees (MVP refuses instead).
7. `locked`-file based hard anti-prune.
8. Retro-registration of pre-existing git-less workspaces (mixed state is a documented supported steady
   state; existing workspaces stay git-less until re-added).
9. git submodules.

---

## 8. Acceptance criteria (testable) + test-plan mapping

| AC | Criterion | Test file |
|----|-----------|-----------|
| AC1 | colocated `jj workspace add ../ws2`: `git -C ../ws2 status/diff/log/show` succeed; `git status` **clean** (no `.jj` untracked) for unmodified ws2; HEAD = ws2 wc parent (detached); index == wc-parent tree | test_git_colocated.rs |
| AC1b | **after an edit** in ws2, `git -C ../ws2 diff` == `jj -R ../ws2 diff` (exercises the mutable-@ hot path) | test_git_colocated.rs |
| AC2 | `git -C <main> worktree list --porcelain` shows ws2, **no `prunable` line**; `git -C ../ws2 rev-parse --git-common-dir` → `<main>/.git` | test_git_colocated.rs |
| AC3 | HEAD == initial wc **parent (not root)** immediately after add; editing a file doesn't move ws2's HEAD; `jj new` in ws2 moves HEAD | test_git_colocated.rs |
| AC4 | conflicted @ in ws2: index carries correct stages; `git status` consistent with main-workspace conflict handling | test_git_colocated.rs |
| AC5 | root-commit @ (unborn) in ws2 → unborn HEAD, no crash; whole-repo unborn (main has no commits) → registers with `refs/jj/root` placeholder | test_git_colocated.rs |
| AC5b | merge @ in ws2 → HEAD = `parent[0]`; index from merged first-parent tree | test_git_colocated.rs |
| AC6 | `jj workspace forget ws2` removes `COMMON/worktrees/ID` + gitlink, leaves ws2 files; `git worktree list` no longer lists it | test_workspaces.rs |
| AC6b | forget when `DEST` already deleted → admin dir removed cleanly (no dangling/prunable entry) | test_workspaces.rs |
| AC7 | `git.auto-register-worktrees=false` → no `.git` created; identical to today | test_workspaces.rs |
| AC8 | non-colocated repo → `jj workspace add` unchanged | test_workspaces.rs |
| AC9 | `jj git colocation disable` with a live secondary worktree → **refuses** with clear message (does not relocate `.git` and strand it) | test_git_colocation.rs |
| AC10 | reset in ws2 does **not** alter the main workspace's `git_head`/HEAD | test_git_colocated.rs |
| AC11 | realpath: on symlinked `/tmp`→`/private/var`, ws2 not reported prunable | test_git_colocated.rs |
| AC12 | `jj util gc` (or `git gc`) with a live secondary worktree leaves `worktrees/ID` intact | test_git_colocated.rs |
| AC13 | `jj bookmark set` + `jj git export` from ws2 interacts safely with sibling worktree HEADs (locking) | test_git_colocated.rs |
| AC14 | `jj undo` after add: define expected worktree-file state (admin files written outside tx are NOT reversed → likely orphaned admin dir; document + reconcile on next mutation) | test_workspaces.rs |
| AC15 | all existing `test_workspaces.rs` / `test_git_colocated.rs` / `test_git_colocation.rs` pass (no regression) | (existing) |

---

## 9. Resolved questions (none carried into planning)

- **OQ1 (gix per-worktree index/HEAD write):** CONFIRMED-WORKS via source (gix 0.85.0) + git-format
  experiment. Caveat folded into §4.5 (tree-cache).
- **OQ2 (handle acquisition):** RESOLVED → §4.2 (`into_repo_with_possibly_inaccessible_worktree`).
- **OQ3 (name→id):** RESOLVED → §6 (persist opaque id).
- **OQ4 (locking/ordering):** RESOLVED → §4.5 locking clause.
- **OQ5 (existing-user asymmetry):** RESOLVED → §7.8 (documented mixed state).
- **OQ6 (gc/prune):** RESOLVED → §3 anti-prune (normative).
- **NEW-OQ7 (mutable-@ hot path):** RESOLVED into §4.1 (blocker).
- **NEW-OQ8 (reset_head git_head coupling):** RESOLVED into §4.3 (blocker).

---

## 10. ⚠️ Decision to re-confirm: D2 — how to model per-workspace git HEAD

The review made this fork concrete. A **prior-session decision on record** said to *extend the op-store
`View` with a `BTreeMap<WorkspaceNameBuf, RefTarget>`* — the opposite of this session's D2 (lazy-derive).

- **D2-A Lazy-derive (current baseline):** no op-store format change; derive outbound HEAD from
  `wc_commit.parent[0]`; build the HEAD-write lock guard from the worktree's own on-disk HEAD; skip
  `set_git_head_target` for secondaries; **disable inbound import** for secondaries (§4.4). Smaller MVP.
- **D2-B Op-store per-workspace `git_head` map:** models reality, cleanly enables inbound import and
  correct lock baselines, resolves the `git_head` coupling structurally — but is a **persisted-format
  change** (content-hash/op-log/migration blast radius) touching every op-store reader/writer.

**Recommendation:** proceed with **D2-A** for the MVP (matches D3-lazy, avoids a format migration), and
adopt D2-B only if/when inbound import lands. **Needs your confirmation given the conflicting prior
decision.**

---

## 11. v2 change log (from review)
- §3: added `.jj/.gitignore`; explicit post-`tx.finish` write point; concrete canonicalization rule;
  normative anti-prune (`gc.worktreePruneExpire=never`).
- §4: added exhaustive write-site parameterization incl. `update_intent_to_add` (mutable-@ hot path);
  secondary-worktree HEAD reset without touching global `git_head`; handle acquisition; locking clause;
  tree-cache invalidation; inbound import DISABLED for secondaries; citation fixes.
- §2/§6: normative forget/rename/disable lifecycle; persisted opaque worktree id; on-disk dedup.
- §5: config key renamed to avoid `git.colocate` collision.
- §8: +AC1b/5b/6b/10/12/13/14 and a test-plan mapping.
- §10: surfaced the D2 lazy-derive vs op-store-map fork for re-confirmation.
