// Copyright 2024 The Jujutsu Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#[cfg(feature = "git")]
use std::fs;
#[cfg(feature = "git")]
use std::path::Path;

#[cfg(feature = "git")]
use jj_lib::file_util::IoResultExt as _;
#[cfg(feature = "git")]
use jj_lib::git;
#[cfg(feature = "git")]
use jj_lib::repo::Repo as _;
use tracing::instrument;

use crate::cli_util::CommandHelper;
use crate::command_error::CommandError;
#[cfg(feature = "git")]
use crate::command_error::user_error;
use crate::ui::Ui;

/// Register a Git worktree for the current workspace (make it colocated)
///
/// Adds the Git-worktree machinery — a `.git` file in the workspace plus the
/// shared repo's worktree registration — to the current workspace so that plain
/// `git` commands work inside it. This is the in-place equivalent of
/// `jj workspace add --colocate` for a workspace that already exists.
///
/// The repository must already be colocated (see `jj git colocation enable`).
/// The `.jj` directory is hidden from Git via a generated `.jj/.gitignore`.
#[derive(clap::Args, Clone, Debug)]
pub struct WorkspaceColocateArgs {}

#[instrument(skip_all)]
pub async fn cmd_workspace_colocate(
    ui: &mut Ui,
    command: &CommandHelper,
    _args: &WorkspaceColocateArgs,
) -> Result<(), CommandError> {
    #[cfg(not(feature = "git"))]
    {
        let _ = (ui, command);
        return Err(crate::command_error::user_error(
            "This command requires a Git-backed repository (the `git` feature).",
        ));
    }
    #[cfg(feature = "git")]
    {
        let mut workspace_command = command.workspace_helper(ui).await?;
        let workspace_root = workspace_command.workspace_root().to_path_buf();
        let workspace_name = workspace_command.workspace_name().to_owned();

        // Already colocated? Nothing to do. Use the real colocation predicate
        // (the cached `is_colocated_git_workspace`) rather than a bare `.git`
        // existence check, so a stray `.git` file is not mistaken for a registered
        // worktree and a partially-configured worktree can still be completed.
        if workspace_command.working_copy_shared_with_git() {
            writeln!(
                ui.status(),
                "Workspace {} is already colocated with Git.",
                workspace_name.as_symbol()
            )?;
            return Ok(());
        }

        let repo = workspace_command.repo().clone();
        // The shared repo must be Git-backed and non-bare (i.e. colocated), so a
        // linked worktree can attach to it.
        let git_backend = git::get_git_backend(repo.store()).map_err(|_| {
            user_error("This is not a Git-backed repository, so it cannot be colocated.")
        })?;
        if git_backend.git_workdir().is_none() {
            return Err(user_error(
                "The repository is not colocated. Run `jj git colocation enable` on the main \
                 workspace first.",
            )
            .hinted("Only workspaces of a colocated repository can be colocated."));
        }
        // The common Git directory (`<main>/.git`), canonicalized so Git does not
        // treat the registered worktree as prunable (e.g. `/var` vs `/private/var`).
        let common_dir = canonicalize_git_dir(git_backend.git_repo().common_dir())?;
        let dest = dunce::canonicalize(&workspace_root).context(&workspace_root)?;

        // Determine the Git HEAD to bootstrap with: the working-copy commit's first
        // parent (detached), or the unborn placeholder when it is the root commit.
        let wc_commit_id = repo
            .view()
            .get_wc_commit_id(&workspace_name)
            .ok_or_else(|| user_error("The current workspace has no working-copy commit."))?
            .clone();
        let wc_commit = repo.store().get_commit(&wc_commit_id)?;
        let first_parent = &wc_commit.parent_ids()[0];
        let head_content = if first_parent == repo.store().root_commit_id() {
            "ref: refs/jj/root\n".to_string()
        } else {
            format!("{first_parent}\n")
        };

        // Natively register the worktree. `git worktree add` cannot be used here
        // because the workspace directory already exists and is populated; it
        // refuses to attach to a non-empty directory. Writing the small admin
        // files directly is the supported way to adopt an existing directory.
        let id = choose_worktree_id(&common_dir, &dest);
        let admin_dir = common_dir.join("worktrees").join(&id);
        // Roll back the natively-written registration if anything below fails
        // before the transaction commits, so a partial failure never leaves an
        // orphan worktree that Git treats as live but jj no longer tracks.
        // (Mirrors the GitWorktreeGuard used by `jj workspace add --colocate`.)
        let guard = ColocateGuard::new(admin_dir.clone(), dest.clone());
        fs::create_dir_all(&admin_dir).context(&admin_dir)?;
        write_file(&admin_dir.join("commondir"), "../..\n")?;
        write_file(
            &admin_dir.join("gitdir"),
            &format!("{}\n", dest.join(".git").display()),
        )?;
        write_file(&admin_dir.join("HEAD"), &head_content)?;
        write_file(
            &dest.join(".git"),
            &format!("gitdir: {}\n", admin_dir.display()),
        )?;
        // Hide the `.jj` control directory from Git.
        write_file(&dest.join(".jj").join(".gitignore"), "*\n")?;

        // Set the worktree's HEAD and index from the working-copy commit, reusing
        // the same per-workspace sync path as `jj workspace add --colocate`. This
        // also records the workspace's Git HEAD in the operation log (except when
        // the working-copy commit's parent is the root commit, i.e. an unborn HEAD).
        let mut tx = workspace_command.start_transaction();
        jj_lib::git::reset_head_at_workspace(
            tx.repo_mut(),
            &wc_commit,
            &workspace_name,
            Some(&dest),
        )
        .await?;
        tx.finish(
            ui,
            format!("colocate workspace {}", workspace_name.as_symbol()),
        )
        .await?;
        // Success: keep the registration.
        guard.defuse();

        writeln!(
            ui.status(),
            "Registered a Git worktree for workspace {}; `git` commands now work here.",
            workspace_name.as_symbol()
        )?;
        Ok(())
    }
}

/// Canonicalizes a `.git` directory path while preserving the trailing `.git`
/// component (fully canonicalizing it could make a non-bare repo look bare).
#[cfg(feature = "git")]
fn canonicalize_git_dir(path: &Path) -> Result<std::path::PathBuf, CommandError> {
    if path.ends_with(".git") {
        let parent = path.parent().unwrap_or(path);
        Ok(dunce::canonicalize(parent).context(parent)?.join(".git"))
    } else {
        Ok(dunce::canonicalize(path).context(path)?)
    }
}

/// Picks a filesystem-safe, unique worktree id under `<common>/worktrees/`.
#[cfg(feature = "git")]
fn choose_worktree_id(common_dir: &Path, workspace_root: &Path) -> String {
    let base = workspace_root
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("workspace");
    let sanitized: String = base
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let worktrees = common_dir.join("worktrees");
    let mut id = sanitized.clone();
    let mut n = 1;
    while worktrees.join(&id).exists() {
        id = format!("{sanitized}-{n}");
        n += 1;
    }
    id
}

#[cfg(feature = "git")]
fn write_file(path: &Path, contents: &str) -> Result<(), CommandError> {
    fs::write(path, contents).context(path)?;
    Ok(())
}

/// Best-effort rollback of a natively-registered Git worktree when the colocate
/// transaction does not commit (partial failure). Defused on success.
#[cfg(feature = "git")]
struct ColocateGuard {
    admin_dir: std::path::PathBuf,
    workspace_root: std::path::PathBuf,
    defused: bool,
}

#[cfg(feature = "git")]
impl ColocateGuard {
    fn new(admin_dir: std::path::PathBuf, workspace_root: std::path::PathBuf) -> Self {
        Self {
            admin_dir,
            workspace_root,
            defused: false,
        }
    }

    fn defuse(mut self) {
        self.defused = true;
    }
}

#[cfg(feature = "git")]
impl Drop for ColocateGuard {
    fn drop(&mut self) {
        if self.defused {
            return;
        }
        // Remove the Git-registration artifacts we wrote: the worktree admin dir
        // and the `.git` gitlink. The generated `.jj/.gitignore` is left as-is
        // (harmless, and it may have pre-existed). Best-effort; errors ignored.
        let _ = fs::remove_dir_all(&self.admin_dir);
        let _ = fs::remove_file(self.workspace_root.join(".git"));
    }
}
