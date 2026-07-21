# Existing implementation found (2026-07-21)

While recon'ing for the plan, discovered that git-worktree interop for jj workspaces **already has an
extensive unmerged implementation** on origin branches. This overrides the earlier "no prior art" finding
(that only checked `main`). Two eras:

## Recent revival (2026-07-13) — the one to use
- **`origin/workspace-cli`** — ahead=10, behind main=37, last 2026-07-13. **Near-complete implementation.**
  Superset of `colocated-workspaces`. Commit stack (bottom→top):
  1. `2743b9ca9` workspace: Make backend factories aware of the workspace root
  2. `ce4151e95` workspace: Reload the repo from disk in `workspace add`
  3. `cf428ee6a` git: box all gix::open::Error
  4. `f126d23e8` git: Add **MaybeColocatedGitRepo** helper
  5. `6d5e43ccc` git: make **GitBackend colocation-aware**
  6. `5da8385a3` workspace: Add worktree support to MaybeColocatedGitRepo
  7. `4db2bc4ac` **workspace add --colocate: create Git worktree** for colocated workspace
  8. `bf9855864` git import: **check all worktrees' HEAD** for external changes
  9. `e2e0c705a` op_store: **add per-workspace git_head tracking**  ← chose D2-B (op-store map)
  10. `930f386f4` workspace forget: **clean up Git worktree** when forgetting colocated workspace
  Touches lib/src/{git.rs +184, git_backend.rs +159, op_store.rs, view.rs, repo.rs, simple_op_store.proto},
  cli forget/tests. (~3491 ins incl. large snapshot churn from the op_store proto change.)
- **`origin/colocated-workspaces`** — ahead=6 = just the clean lib foundation (commits 1–6 above), ~1180 lines.

## Older era (2024-11) — superseded reference
- `origin/workspace-colocate-2` (13), `workspace-colocate-minimal` (8), `git-colocate` (2), `workspace-heads`.
  Contain `git_worktree_add`/`git_worktree_remove` lib helpers (a direct-fs approach). Useful as reference
  but older; the 2026-07 branches are the live line of work.

## Design divergences vs our spec (must reconcile)
| Fork | Our spec decided | `workspace-cli` actually does |
|------|------------------|-------------------------------|
| D2 per-workspace HEAD | **D2-A lazy-derive** (no op-store change) | **D2-B op-store per-workspace git_head map** (`e2e0c705a`) |
| D4 rollout | **Automatic** | **`--colocate` flag (opt-in)** (`4db2bc4ac`) |
| Architecture | parameterize reset_head/update_intent_to_add piecemeal | **`MaybeColocatedGitRepo`** abstraction + colocation-aware backend |

The impl's D2-B matches the prior-session memory I had (wrongly) superseded → strong signal D2-B is the
correct call. Both branches need a **rebase onto main (37 commits behind)**.

## Implication
Pivot from "build from scratch" to leveraging `workspace-cli`. Our research/spec/review/ACs become the
**verification lens** to finish + harden the branch, not throwaway. Strategy decision pending (see 00-initiative.md).

## Rebase-and-assess result (2026-07-21)
- Rebasing `workspace-cli` (10 commits) onto `main` (74ed79525): **5/10 apply clean; ONE conflict** in
  `lib/src/git_backend.rs` on commit `6d5e43ccc` (colocation-aware GitBackend) — expected, main churned that
  file. `workspace.rs` + `test_git.rs` auto-merged. **Tractable rebase, not a rewrite.**
- ⚠️ **NO RUST TOOLCHAIN on this machine** (no cargo/rustc/rustup/~/.cargo). Cannot `cargo build`/`cargo test`
  here. Code + rebase can be produced, but **compile/test verification must run in the user's dev env or CI.**
  This shapes the finish approach: either (a) user installs rustup so I can verify locally, or (b) I produce a
  resolved-rebase + code branch and hand off build/test to the user/CI (TDD red/green loop happens there).

  **RESOLVED 2026-07-21:** user installed Rust via **mise** → `cargo 1.97.1` / `rustc 1.97.1` now on PATH
  (`~/.cargo/bin/cargo`, mise shims). `.config/mise.toml` provides `mise run build` and `mise run test`
  (nextest + cargo-insta, Rust 1.89). **Local verification unblocked → we finish + build + test here (option a).**

  **PARTIALLY BLOCKED AGAIN 2026-07-21:** toolchain is present but the sandbox **blocks crates.io**
  (`cargo` → "CONNECT tunnel failed, response 403" updating the index). `~/.cargo/registry` is EMPTY and jj was
  never built here (no `target/`), so `--offline` fails (`no matching package named ansi-to-tui`). To build/test
  locally we must **allowlist crates.io** (`index.crates.io` + `static.crates.io`; `naiwei:network-allowlist`
  skill) — otherwise verification must happen in the user's normal env / CI (I write code + rebase, hand off
  `mise run test`). Decision pending.
