# Making jj Workspaces Git-Worktree-Compatible: Research Synthesis

## Executive Summary

Today, a jj "workspace" and a git "worktree" are **completely independent mechanisms** that happen to solve the same problem (multiple working copies over one object store). A secondary jj workspace created by `jj workspace add` has **no `.git` at all**, is invisible to git (`git worktree list` shows only the main colocated worktree), and is never treated as colocated — so `git status` inside it fails with `fatal: not a git repository`. To make plain `git` commands work inside a secondary jj workspace, jj must **register a git linked-worktree** for that workspace and keep its per-worktree HEAD + index in sync with the jj working-copy commit.

The good news: the git linked-worktree on-disk format is small and fully specified (4 mandatory text files + an optional index), gix already understands the READ side of that layout, and jj already has all the tree->index->HEAD sync logic in `jj_lib::git::reset_head`/`reset_index`. The core work is (1) **writing the registration files** at `jj workspace add` time, (2) **generalizing the sync path from "one main worktree" to "the acting workspace's worktree"**, and (3) deciding how to model a **per-workspace git HEAD**, which the op-store currently cannot express.

---

## Area 1: jj Workspace Model & Lifecycle

### How it works today
- A workspace = (working-copy dir + `.jj/`); the *repo store* is shared. A secondary workspace's `.jj/repo` is a **FILE** containing a relative path to the primary's `.jj/repo` dir (`workspace.rs:576-587`), plus its own `.jj/working_copy/{checkout,tree_state,type}`. It has **NO `.git`** (exp010).
- Identity is a `WorkspaceName`/`WorkspaceNameBuf` (newtype over String), default `"default"`, else `--name` or destination basename (`ref_name.rs:318`, `add.rs:97-108`). Persisted in `.jj/working_copy/checkout` protobuf (exp011) and used as the key of `View.wc_commit_ids: BTreeMap<WorkspaceNameBuf, CommitId>` (`op_store.rs:261-263`).
- `jj workspace add` calls `Workspace::init_workspace_with_existing_repo` (`workspace.rs:370-409`): creates `.jj`, writes the `repo` pointer file, loads `SimpleWorkspaceStore`, checks out root commit for the new name, then a **second CLI transaction** builds the real initial wc commit via `tx.edit`/`tx.finish` (`add.rs:179-234`).
- Enumeration has **two registries** that must stay consistent: authoritative `View.wc_commit_ids()` (name->commit, `list.rs:77`) and `SimpleWorkspaceStore` at `.jj/repo/workspace_store/index` (name->relpath, `workspace_store.rs:161-251`). A worktree reconciler needs both: commit from the View, path from the store.
- `is_colocated_git_workspace` returns true **only** if the GitBackend's `git_workdir()` equals the workspace root (`git_util.rs:61-77`). Secondary workspaces' shared backend workdir is the PRIMARY root, so they are **never colocated** — no HEAD reset, no `refs/heads` export (`cli_util.rs:2313-2320`).
- `forget` untracks (removes `wc_commit` from View + workspace_store) but **leaves files on disk** (`forget.rs:79-96`); `rename` reindexes; `update-stale` recovers lagging workspaces.

### What's missing
jj **never** creates `.git/worktrees/<name>` (exp011). `View.git_head` is a single `RefTarget` with `// TODO: Support multiple Git worktrees?` (`op_store.rs:256-259`). Objects written from a secondary DO reach the shared store (protected by `refs/jj/keep/*`), but user-facing git refs/HEAD do not sync.

### Natural hook seams
- **Lib**: `Workspace::init_workspace_with_existing_repo` (`workspace.rs:370`) is the single lib entry that materializes a secondary workspace and has `repo` (hence GitBackend access). Reused by non-CLI callers; keeps registration atomic.
- **CLI**: `cmd_workspace_add` after init returns and after the final `tx.finish` (`add.rs:129-234`) — colocation-aware, mirrors how all other git side-effects are CLI-gated. **Critical**: create/update the worktree HEAD *after* the final `tx.finish`, else it would point at the throwaway root-commit checkout.

---

## Area 2: git HEAD/Index Sync (main colocated working copy)

### How it works today
- `jj_lib::git::reset_head(mut_repo, wc_commit)` (`git.rs:1797-1842`): computes `new_head = wc_commit.parent_ids()[0]` (or absent -> unborn placeholder), edits HEAD only if changed via `update_git_head` (`git.rs:1738-1775`, detached to parent OID using gix `edit_references` with expected-value guards), clears in-progress git state, then **always** calls `reset_index`.
- Unborn/root: when parent is the jj root commit, HEAD becomes symbolic ref `refs/jj/root` (which intentionally doesn't exist), so git sees an unborn HEAD (`git.rs:1744-1760`, const at `git.rs:92-93`).
- `reset_index` (`git.rs:1877-1929`) rebuilds the index from the wc commit's **PARENT** tree (so `git diff` == `jj diff`): resolved -> `git_repo.index_from_tree`; empty -> empty state; conflicted -> `build_index_from_merged_tree` (stages 1/2/3 for 2-sided). Then `update_intent_to_add` marks new files, stat info copied from old index, written with gix `index.write()`. **All gix, no subprocess.** Writes to the single `git_repo.index_path()`.
- **Triggers** (CLI): `finish_transaction` (`cli_util.rs:2313-2320`) and `snapshot_working_copy` (`cli_util.rs:2120-2140`), both gated on `self.working_copy_shared_with_git && should_commit_transaction()`. `working_copy_shared_with_git` is a single boolean cached once per `WorkspaceCommandHelper` (`cli_util.rs:1171-1172`).
- Import direction: `import_git_head` reads the single `git_repo.head_id()` and checks it out as the wc parent, under `git_import_export.lock` (`cli_util.rs:1271-1291`, `git.rs:1165-1199`).
- `.git` location: `GitBackend::load` reads `.jj/repo/store/git_target` (colocated = `../../../.git`, internal = `git`), canonicalized by `canonicalize_git_repo_path` which **preserves a trailing `.git`** to avoid bare-repo misdetection (`git_backend.rs:321-349, 555-568`).
- **Already worktree-aware (one place)**: `export_some_refs` iterates `git_repo.worktrees()` and calls `check_and_detach_head` on each linked worktree so moving a bookmark doesn't break a worktree HEAD (`git.rs:1304-1356`). This is the **template** to generalize wc HEAD/index reset.

### What's missing
Every write target is hard-coded to the single main gix repo: `index_path()`, the single `HEAD` ref, and the single `working_copy_shared_with_git` boolean. Experimentally confirmed: cross-workspace `jj describe` that rewrites another workspace's @-parent leaves that workspace's git HEAD/index **stale** until it next runs a mutating command (`gwi_exp009/010`); read-only commands don't resync.

---

## Area 3: git Linked-Worktree On-Disk Format (target to replicate)

Fully specified from git source + experiments (git 2.54). To register a linked worktree, write exactly **4 files**:

1. `<worktree>/.git` — a regular **FILE** (not dir): `gitdir: <ABS realpath>/worktrees/<id>\n` (EXP1, `setup.c:1007-1013`, `worktree.c:1119`).
2. `<common>/worktrees/<id>/gitdir` — `<ABS realpath of worktree>/.git\n` (used for reverse lookup / prune; `worktree.c:1118`, doc `gitrepository-layout.adoc:285-290`).
3. `<common>/worktrees/<id>/commondir` — `../..\n` (REQUIRED; without it shared refs/objects aren't found — EXP2b; `setup.c:321-348`).
4. `<common>/worktrees/<id>/HEAD` — either `ref: refs/heads/<branch>\n` OR a raw 40-hex OID + `\n` (detached; both valid — EXP3a, `setup.c:350-400`).

**Everything else is optional**: `index`, `logs/HEAD`, `ORIG_HEAD`, `refs/`, `config.worktree` can all be deleted and the worktree stays valid and non-prunable (EXP5b, EXP8a).

Key constraints:
- **Paths MUST be canonical realpaths** (resolve symlinks). A `/var` vs `/private/var` mismatch makes git report the worktree "prunable" even though it exists (EXP4a/5a vs EXP8a).
- A **jj-style detached HEAD (raw OID) maps cleanly** onto a linked-worktree admin HEAD — fully valid (EXP9b). jj colocated repos already detach HEAD after the first commit (EXP9a).
- HEAD-referenced branches must live in **SHARED refs** (`refs/heads` in common dir), not the admin dir (EXP8b). Per-worktree namespace: HEAD, ORIG_HEAD, `logs/HEAD`, `refs/bisect|worktree|rewritten`; everything else under `refs/` is shared.
- Do **NOT** set `core.bare=true` or `core.worktree` in shared `.git/config` (breaks all worktrees). jj colocated repos are non-bare, so naturally satisfied.
- Prefer **absolute-path** linking (git default) over `--relative-paths` (sets `extensions.relativeWorktrees`, rejected by older git).
- `locked` file (any reason string) makes a worktree never-prunable and blocks remove/move without `-f -f` (EXP4d).
- Discovery self-check jj can run: from the worktree, `git rev-parse --git-dir` -> `<common>/worktrees/<id>`, `--git-common-dir` -> `<common>`, and `git worktree list --porcelain` shows it with no `prunable` line.

---

## Area 4: gix (0.85.0) Capabilities

jj pins **gix 0.85.0** with features `attributes, blob-diff, index, max-performance-safe, sha1, sha256, zlib-rs` (`Cargo.toml:56-64`); matching sub-crates gix-worktree 0.54, gix-index 0.53, gix-ref 0.65, gix-discover 0.53 (`Cargo.lock`).

- **READ side fully supported**: `gix::open` on `.git/worktrees/<id>` resolves `commondir`/`gitdir`, opens objects at `common_dir/objects`, and routes refs via `RefStore::for_linked_worktree` (`open/repository.rs:187-234`); `Repository::worktrees()`/`worktree_proxy_by_id()` enumerate.
- **NO CREATE/REGISTER API**: the entire gix worktree module is read-only (Proxy: `base/is_locked/lock_reason/open_index/...`); grep for `add/create/register worktree` across all gix crates returns nothing. `gix-worktree-state` is checkout-only and jj doesn't even enable it.
- **gix CAN write a per-worktree index at an arbitrary path**: `gix_index::File::from_state(state, path)` + `File::write()` (locks `self.path`), and `Repository::index_from_tree(tree)` builds the state — all under the already-enabled `index` feature (`gix-index/src/file/init.rs:109`, `write.rs:22/67`, `gix/src/repository/index.rs:210`).
- **gix CAN write a per-worktree HEAD via ref transactions** — but only once opened AS a linked worktree (HEAD is `Category::PseudoRef`, routed to `git_dir`; `gix-ref/src/store/file/find.rs:253`). That requires the admin files to already exist, which gix can't create.
- **jj today opens the store bare** with `open_path_as_is(true)` on `git_target` (`git_backend.rs:277-281, 570-586`); `common_dir=None`. It has **no per-worktree gix handle**.
- **Precedent**: jj shells out to git **only** for network (fetch/push/remote) and gc (`git_subprocess.rs:183/239/271`, `git_backend.rs:921`); MINIMUM_GIT_VERSION 2.41. No local `git worktree`/`checkout`/`read-tree` subprocess calls.
- **Manual-assembly experiment (exp030)**: hand-writing the 4 admin files + building the index via `read-tree` produced a worktree git fully recognized (`worktree list`, `status`, `checkout-index` all worked). This proves option (b) — write text files ourselves + use gix — is viable and matches existing architecture.

---

## Area 5: Prior Art & Constraints

- **No design doc or roadmap item** for this feature. Official stance: `docs/git-compatibility.md:65-66` says "git-worktree: No" and steers users to `jj workspace`.
- **Closest existing primitive**: `--git-repo=<path>` external mode, which the docs say "will work similar to a Git worktree" (`git-compatibility.md:82-88`). **VERIFIED (EXP7)**: `jj git init --git-repo=<main>/.git/worktrees/<name>` already works — jj imports that worktree's HEAD, `git_target` = the worktree gitdir. But the resulting jj workspace is **non-colocated** (no `.git` in root), so jj+git in the same dir do NOT auto-sync — manual `jj git import/export`.
- **`jj git init --colocate` deliberately REFUSES** inside a linked git worktree (`init.rs:209-217`, detection at `init.rs:406-414` via `git_dir != common_dir`, issue #8052). This guard would need to be relaxed/superseded — and its removal must not reintroduce the bugs it fixed.
- **`jj git colocation enable/disable` is main-workspace-only** — rejects non-main workspaces (`colocation.rs:76-90`, test `test_git_colocation.rs:347-382`). It moves `.jj/repo/store/git` <-> `.git`, toggles `core.bare`, rewrites `git_target`, and runs `reset_head` once.
- **Colocation invariants (heavily tested, must not break)**: HEAD always detached at wc PARENT; editing files doesn't move HEAD; `jj new` moves HEAD to new parent; index == wc-parent tree; external `git switch` re-imports as an op (`test_git_colocated.rs:26-125, 882-959`).
- **Windows/WSL path fragility**: `git_target` is a raw byte file (no trailing newline on Windows); relative paths forced to forward slashes for WSL portability; absolute paths can't be made portable (`git_backend.rs:298-308`). Worktree gitdirs are typically absolute, so this portability trick doesn't apply.

---

## Area 6: Multi-Workspace Sync & Conflicted Commits

- **Refresh trigger is per-acting-workspace and lazy across workspaces**: only the acting colocated workspace's HEAD/index is updated, only on tx-committing commands (`cli_util.rs:2121, 2314`). This matches jj's existing "stale working copy" UX model.
- **git_head is a single global value** (`op_store.rs:256-263`) while `wc_commit_ids` is already per-workspace. So the working-copy side of the model is ready; only the git-HEAD side needs per-workspace representation (new map, or derive lazily from `wc_commit.parent[0]`).
- **Conflicted @ is already solved and worktree-agnostic**: HEAD = parent[0]; index carries 2-sided stages (1/2/3) or, for many-sided, first side at stage 0 + a dummy `.jj-do-not-resolve-this-conflict` blob at stage 2 (`git.rs:1982-2040`, consts `git.rs:94-96`); the @ commit's git tree carries `.jjconflict-base/side` subtrees (`git_backend.rs:1538-1580`). `build_index_from_merged_tree` can be reused per-worktree unchanged (exp013/014).
- **Locking is two-tier**: per-workspace `working_copy.lock` (`local_working_copy.rs:2630-2633`) + repo-global `git_import_export.lock` at the shared `.jj/repo` (`cli_util.rs:1216-1225`). The global lock already serializes git HEAD/index/ref writes across workspaces — a multi-worktree updater can hold it while touching multiple worktree indexes. But out-of-band `git checkout` inside a worktree is only reconciled on that worktree's next jj snapshot, and `import_git_head` reads only the shared HEAD — each worktree needs its own HEAD import keyed to its own HEAD file.

---

## Proposed Mechanism (grounded sketch)

### On `jj workspace add <dest> [--name N]` (colocated repos only)
After the final `tx.finish` produces the initial wc commit for the new `WorkspaceName`:
1. Resolve `<common>` = GitBackend's `.git` dir (`git_repo_path()`), and `<id>` = the WorkspaceName (or a sanitized/deduped derivative — see decision D5).
2. Create `<common>/worktrees/<id>/` and write, using **canonical realpaths**:
   - `commondir` = `../..\n`
   - `gitdir` = `<realpath dest>/.git\n`
   - `HEAD` = raw OID of `wc_commit.parent_ids()[0]` + `\n` (detached; unborn placeholder if parent is root)
   - `<dest>/.git` FILE = `gitdir: <realpath common>/worktrees/<id>\n`
3. Optionally write `<common>/worktrees/<id>/index` from the wc parent tree via gix `index_from_tree` + `File::write` (or leave it for git to lazily create).

### Sync points (generalize existing code)
- **`reset_head`/`reset_index` become worktree-parameterized**: accept the target gix repo/HEAD-path/index-path instead of always `base_repo`. Content logic is unchanged; only routing changes. Model on the existing `git_repo.worktrees()` iteration in `export_some_refs` (`git.rs:1351-1356`).
- **`is_colocated_git_workspace`** generalized to also return true for a workspace dir that is a registered linked worktree of the shared repo (git_workdir of that worktree == workspace root), so `working_copy_shared_with_git` becomes per-workspace.
- **On every tx that commits**: reset the acting workspace's own worktree HEAD+index (lazy cross-workspace, matching today's stale-wc model — see decision D3).
- **On import**: each workspace's `import_git_head` reads its own `<common>/worktrees/<id>/HEAD`, not the shared HEAD.

### Lifecycle
- **`forget`**: mirror jj's "don't touch files" semantics — `git worktree prune`-style detach or write a `locked` file; do NOT force-delete the checkout.
- **`rename`**: keep the gitlink stable, or rewrite gitdir/.git (git-worktree-repair-equivalent).
- **`colocation disable`**: decide whether to tear down secondary worktrees or refuse when they exist.

---

## Key uncertainties carried into decisions/risks
- Per-workspace git HEAD is not modeled in the op-store today (explicit TODO). Must decide: persist a map vs derive lazily.
- gix worktree-index write when the handle is a linked-worktree handle (vs main) was not empirically verified for jj's exact version (open question in Area 4/6).
- `extensions.worktreeConfig` / `core.bare` relocation behavior differed slightly from source reading on git 2.54 — needs verification on jj's target git.
