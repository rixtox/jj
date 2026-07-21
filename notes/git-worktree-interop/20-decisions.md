# Design decisions (git-worktree interop for jj workspaces)
Status legend: **OPEN** = awaiting human steering · **DECIDED** = chosen

## DECISIONS MADE (2026-07-21, by Naiwei)

| ID | Decision | Chosen | Note |
|----|----------|--------|------|
| D1 | Registration mechanism | **Native file-writing + gix index** | as recommended |
| D2 | Per-workspace git HEAD in op-store | **Lazy derivation** (no op-store format change; read worktree HEAD file for import) | recommended; proceeds |
| D3 | Sync timing | **Lazy per-workspace** | as recommended |
| D4 | Opt-in vs automatic | **Automatic for all colocated repos** | ⚠️ OVERRIDE of recommended opt-in. Implication: forget/rename/`colocation disable` lifecycle must be handled in MVP (not deferred). Provide a config safety off-switch. |
| D5 | First increment scope | **MVP: colocated-only** | as recommended; D4 pulls lifecycle handling into MVP |
| D6 | Reuse `jj git colocation` vs new path | **New dedicated path** in `jj workspace`, factor out shared helpers | recommended; proceeds |

_Original synthesis recommendations and full option tradeoffs are preserved below._

_All decisions below are OPEN. Synthesis recommendation shown per decision._

## D1: Registration mechanism: native file-writing vs `git worktree add` vs hybrid
**Status:** OPEN

**Question:** How should jj create the linked-worktree registration files (the outer `.git` gitlink + `<common>/worktrees/<id>/{commondir,gitdir,HEAD}` + optional index)?

**Options:**
- **Native: jj writes the 4 text files itself and uses gix `index_from_tree`+`File::write` for the index** — Consistent with jj's architecture (gix for all local mutation, subprocess only for network+gc; git_subprocess.rs). No dependency on the user's git version for local layout. Proven viable (exp030 hand-assembly recognized by git; exp8a minimal 3-file worktree valid). Cost: jj owns realpath canonicalization, prune/repair edge cases, and cross-platform path encoding (git_backend.rs:298-308) itself.
- **Shell out to `git worktree add`** — git handles all admin-file details, locking, and future format changes. But sets a NEW precedent (jj never shells out for local repo mutation), depends on user git behavior/version for local layout, and `git worktree add` also checks out files / creates a branch which conflicts with jj owning the working tree and wc snapshotting. Heavier and harder to make atomic with the jj tx.
- **Hybrid: native text files + gix index, but reuse `git worktree repair`/`prune` subprocess for reconciliation only** — Gets native creation (fast, atomic) plus git's battle-tested repair for the rare drift case. Adds a subprocess dependency but only on an idempotent maintenance path, not the hot path.

**Recommendation:** Native (option 1)

**Rationale:** It is the only option consistent with jj's established policy (gix for all local object/ref/index work, subprocess only for network+gc). The format is tiny and fully specified (Area 3), gix already supplies index writing, and the hand-assembly experiment proves git accepts jj-written files. Keep the hybrid repair path (option 3) in reserve as a follow-up for drift reconciliation rather than a v1 requirement.

## D2: Per-workspace git HEAD representation in the op-store
**Status:** OPEN

**Question:** The View stores a single `git_head: RefTarget` (op_store.rs:256, explicit `// TODO: Support multiple Git worktrees?`). How do we track each workspace's git HEAD?

**Options:**
- **Derive lazily from `wc_commit.parent_ids()[0]`; do NOT persist per-workspace git HEAD** — No op-store format/version change, no migration. wc_commit_ids is already per-workspace (op_store.rs:261), and reset_head already computes HEAD from the parent. Downside: import of an out-of-band `git checkout` inside a worktree needs another place to record the imported HEAD per workspace; the single git_head can't hold N values. May need per-worktree HEAD read directly from `.git/worktrees/<id>/HEAD` on snapshot rather than a stored value.
- **Add a per-WorkspaceName git_head map to op_store::View** — Cleanly models the reality and supports importing per-worktree external checkouts. But it's a persisted-format change with content-hash/operation-log implications and a migration/backfill story (op_store.rs:248-259). Larger blast radius; every op-store reader/writer touched.
- **Keep git_head repo-wide; only ONE workspace is 'the' colocated one at a time** — Minimal change, preserves all existing invariants. But defeats the feature's purpose (other workspaces wouldn't have live git HEAD). Effectively today's behavior.

**Recommendation:** Lazy derivation (option 1) for the outbound HEAD, plus reading each worktree's own HEAD file for inbound import

**Rationale:** Outbound HEAD is already a pure function of the workspace's wc parent (reset_head), so no persisted per-workspace git_head is needed to WRITE worktree HEADs. For inbound (external `git checkout` in a worktree), read `.git/worktrees/<id>/HEAD` directly at that workspace's snapshot rather than storing N values. This avoids a risky op-store format migration in v1. If bidirectional import proves to need durable state, escalate to option 2 as a follow-up.

## D3: Sync timing for per-workspace HEAD/index
**Status:** OPEN

**Question:** When should a workspace's git worktree HEAD+index be updated relative to jj operations, especially when another workspace rewrites this one's @?

**Options:**
- **Lazy per-workspace (match today's stale-wc model): each workspace reconciles its own worktree HEAD/index only on its next mutating command** — Matches existing behavior exactly (verified gwi_exp009/010: cross-workspace @ rewrite leaves HEAD stale until that workspace acts). No need to write another worktree's index from a foreign cwd. Downside: a git command run in a stale worktree between jj ops sees an out-of-date index/HEAD until the next jj command there.
- **Eager: any operation that changes ANY workspace's wc_commit_id immediately updates that workspace's worktree HEAD+index** — Always-correct git view in every worktree. But requires writing a DIFFERENT worktree's index from an arbitrary cwd (crosses the current single-worktree assumption), holds the repo-global git_import_export.lock while touching N files, and adds per-op cost proportional to affected worktrees. Higher complexity and race surface.
- **On-demand command (e.g. `jj workspace sync-git` / `jj git worktree sync`) plus lazy on-mutation** — Gives users an explicit escape hatch to force-refresh a worktree without a no-op jj command, while keeping the cheap lazy default. Small extra surface; good for reconciling out-of-band drift.

**Recommendation:** Lazy (option 1) as the default, with an on-demand sync command (option 3) as a follow-up

**Rationale:** Lazy is consistent with jj's existing stale-working-copy semantics that users already understand, avoids the hardest technical problem (writing a foreign worktree's index from another cwd), and keeps per-op cost bounded. Eager sync is a correctness-nice-to-have with disproportionate complexity/lock-contention cost; defer it. Ship an explicit sync command if users hit staleness in practice.

## D4: Opt-in vs automatic for colocated workspaces
**Status:** OPEN

**Question:** Should git-worktree registration happen automatically for every `jj workspace add` in a colocated repo, or be opt-in via flag/config?

**Options:**
- **Opt-in via flag (e.g. `jj workspace add --colocate`) and/or config (e.g. `git.colocate-workspaces`)** — Safe default, no behavior change for existing users, no surprise `.git/worktrees` entries or new prune/repair interactions. Users who don't need git-in-workspace pay nothing. Downside: discoverability; the feature is off unless found.
- **Automatic for all colocated repos** — Best UX (git just works everywhere), matches the feature intent. But changes behavior for every existing colocated user, creates git worktree bookkeeping they didn't ask for, risks interacting with their own manual `git worktree`/prune/gc.worktreePruneExpire, and complicates forget/disable. Riskier rollout.
- **Config default on, per-command override off** — Middle ground; still a behavior change but escapable. Adds two knobs to reason about.

**Recommendation:** Opt-in via flag + config (option 1), defaulting off in v1

**Rationale:** This is a new interop surface touching git's own bookkeeping and the tested colocation invariants; defaulting off limits blast radius and lets the feature bake. A config key allows users who want it everywhere to flip the default. Revisit auto-on once prune/repair/forget lifecycle and cross-platform paths are proven.

## D5: Scope of the first increment
**Status:** OPEN

**Question:** What subset ships first: which repo types, which lifecycle operations, and how much sync?

**Options:**
- **MVP: main-colocated repos only; `jj workspace add` registers a linked worktree with detached HEAD + index at the wc parent; lazy sync on mutation; `forget` prunes the worktree; conflicted @ reuses existing index logic** — Smallest genuinely-useful slice — `git status`/`git diff`/`git log` work in a secondary workspace. Reuses reset_head/reset_index/build_index_from_merged_tree. Defers: `--git-repo` external mode, eager cross-workspace sync, per-worktree external-checkout import, rename gitlink stability, Windows edge cases.
- **Full: also cover `--git-repo` external mode, bidirectional import (external git checkout in a worktree), rename/repair, and colocation enable/disable interactions** — Complete but large; touches op-store (per-worktree HEAD import), path portability, and the #8052 guard. High risk of scope creep and regressions in tested invariants.
- **Minimal probe: just relax the #8052 guard and document the manual `git worktree add` + `jj git init --git-repo=<worktree gitdir>` recipe (already works, EXP7)** — Almost no code; ships as docs + a guard change. But the result is non-colocated and doesn't auto-sync (manual jj git import/export), so it's not the seamless experience the feature intends.

**Recommendation:** MVP (option 1)

**Rationale:** It delivers the core value (plain git commands work inside a secondary colocated workspace) while reusing jj's existing, well-tested tree->index->HEAD machinery and avoiding the op-store format change and cross-workspace eager-sync complexity. Everything deferred (external mode, bidirectional import, rename/repair) is additive and can follow once the primitive is solid.

## D6: Reuse/extend `jj git colocation` machinery vs new code paths
**Status:** OPEN

**Question:** Should per-workspace worktree colocation reuse the existing `jj git colocation enable/disable` code, or be a distinct path?

**Options:**
- **New dedicated path in the `jj workspace` family; leave `git colocation` as-is (main-workspace whole-repo toggle)** — Clean separation of concerns. `git colocation` is a whole-repo main-workspace concept (moves .git <-> store/git, toggles core.bare, main-only guard at colocation.rs:76-90); worktree registration is per-workspace and does NOT move .git or touch core.bare. Conflating them would overload confusing semantics. Downside: some shared helpers (reset_head wiring, git_target/path canonicalization) should still be factored out and reused.
- **Extend `jj git colocation enable` to operate per-workspace** — Fewer commands, but the enable/disable semantics (relocate .git, flip core.bare, main-only) are wrong for a per-workspace linked worktree, which must NOT set core.bare and must keep the shared store. Forces relaxing the main-only guard and overloading the command. High confusion risk.

**Recommendation:** New dedicated path in `jj workspace` (option 1), factoring out shared reset/path helpers

**Rationale:** The two features are architecturally different: colocation enable/disable relocates the whole repo's `.git` and toggles bareness for the main workspace, whereas worktree registration adds a per-workspace gitlink over the unchanged shared store. Keep them separate to avoid overloading tested semantics; share only the low-level reset_head/reset_index/path-canonicalization helpers.

---

## Risks
- Correctness invariants: the per-worktree HEAD/index reset must exactly replicate the tested colocation behavior (detached HEAD at wc PARENT, index == wc-parent tree, `git diff` matches `jj diff`) independently per worktree without cross-contaminating the shared object store or sibling worktree HEADs (test_git_colocated.rs:26-125). Any divergence silently corrupts a user's git view.
- Path canonicalization: git reports a worktree as 'prunable' if gitdir/.git paths are not realpath-consistent (verified /var vs /private/var on macOS, EXP4a/5a). jj must canonicalize exactly as git's strbuf_realpath does; std::fs::canonicalize behavior on symlinks/last-component must match, and it interacts with jj's existing last-component-preserving canonicalize_git_repo_path (git_backend.rs:555-568).
- Op-store single git_head (op_store.rs:256): if the lazy-derivation approach (D2 opt 1) proves insufficient for importing external `git checkout` performed inside a worktree, a format/migration change is forced late. import_git_head today reads only the single shared HEAD (cli_util.rs:1319, git.rs:1165-1199).
- gix per-worktree index write not empirically verified for jj's version: index_from_tree + File::write are documented to work with an explicit path, but whether they behave identically when the gix::Repository is a linked-worktree handle (vs the main handle) was NOT tested (Area 4/6 open question). Also gix-index tree-cache staleness caveat: must call State::remove_tree() before write when entries changed (gix-index issue #2421).
- Cross-workspace staleness (chosen lazy model): a git command run in a workspace whose @ was rewritten by another workspace sees a stale index/HEAD until that workspace's next jj mutation (gwi_exp009/010). Users may be surprised; needs clear docs and possibly the on-demand sync command.
- git's own auto-prune: `git worktree prune` / gc.worktreePruneExpire may remove jj-registered worktrees if their gitdir path becomes unresolvable, orphaning the jj workspace's git side. jj must keep paths resolvable or write a `locked` file to opt out of pruning.
- core.bare / worktree config: if a colocated repo ever has core.bare=true or core.worktree in shared .git/config, all linked worktrees break (Area 3). jj colocated repos are non-bare today, but colocation disable sets core.bare=true (colocation.rs) — disabling colocation while secondary worktrees exist would break them.
- #8052 guard removal regression: `jj git init --colocate` refuses inside a linked worktree to prevent broken-state bugs (init.rs:209-217). Any relaxation to support this feature risks reintroducing those failures.
- Windows/WSL portability: worktree gitdir paths are typically ABSOLUTE, so jj's relative-path forward-slash portability trick (git_backend.rs:298-308) does not apply; a repo moved between Windows and WSL, or across machines, will have stale absolute paths requiring a repair step. Also git_target raw-byte file must have no trailing newline on Windows.
- Locking / concurrency: writing multiple worktree indexes under the single repo-global git_import_export.lock (cli_util.rs:1216) serializes correctly but an out-of-band `git checkout`/`git commit` in a worktree races with jj and is only reconciled on that worktree's next snapshot via its own working_copy.lock; each worktree needs its own HEAD import path.
- git worktree add checks out files and jj owns the working tree via .jj/working_copy snapshotting — if the index/checkout written for git disagrees with jj's tree state, `git status` may show spurious deleted/untracked entries (noted in Area 3 open questions when index absent).
- Two enumeration registries (View.wc_commit_ids and SimpleWorkspaceStore) must stay consistent with the git worktrees/<id> set; out-of-band `git worktree add/remove` or `jj workspace forget` can desync all three, requiring reconciliation logic that does not exist today.

## Recommended scope (MVP)
MVP (matches decision D5 option 1, D4 opt-in, D1 native, D2 lazy-derivation, D3 lazy sync, D6 new path):

Ship a per-workspace git linked-worktree for MAIN-COLOCATED repos only, opt-in via `jj workspace add --colocate` (and/or a `git.colocate-workspaces` config), off by default.

On `jj workspace add --colocate <dest>`, after the final tx.finish, natively write the 4 admin files under `<common>/.git/worktrees/<id>/` (commondir=`../..`, gitdir=realpath, HEAD=detached raw OID of wc parent) plus the `<dest>/.git` gitlink, all using canonical realpaths. Write the per-worktree index from the wc parent tree via gix index_from_tree (reusing reset_index/build_index_from_merged_tree, including the existing conflicted-@ stages/dummy-marker handling).

Generalize is_colocated_git_workspace and reset_head/reset_index to target the acting workspace's own worktree gix repo/HEAD-path/index-path (modeled on the existing git_repo.worktrees() iteration in export_some_refs). Sync LAZILY: only the acting workspace reconciles its own worktree HEAD/index on tx-committing commands — matching jj's existing stale-working-copy UX. `jj workspace forget` prunes/detaches the git worktree (git-prune-style, no file deletion, matching forget's documented semantics).

Success criterion: `git status`, `git diff`, and `git log` work inside a secondary colocated jj workspace, showing the same picture as the main colocated workspace does today.

DEFER to follow-ups: (1) `--git-repo` external-mode worktrees; (2) eager cross-workspace HEAD/index sync + an on-demand `jj workspace sync-git` command; (3) bidirectional import of an external `git checkout` performed inside a worktree (and any op-store per-workspace git_head map it requires); (4) rename gitlink-stability and a `git worktree repair`-equivalent; (5) colocation enable/disable interactions when worktrees exist; (6) automatic (default-on) behavior; (7) Windows/WSL absolute-path portability hardening; (8) relaxing the #8052 `jj git init --colocate`-inside-a-worktree guard.
