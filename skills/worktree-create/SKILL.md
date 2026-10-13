---
name: worktree-create
description: Create a git worktree and its branch for a task from a repo in source/, or check out an existing branch as it is (detached, e.g. a release), then apply config/<repo>/ to it. Use whenever the user asks to create, open or start a worktree or working branch, e.g. "crea un worktree", "nuevo worktree para X", "monta la rama release/1.2". Always use this skill, never `git worktree add` or its script directly. Fails with NO_SOURCE or NO_NAME.
allowed-tools: Bash(skills/worktree-create/scripts/worktree-create.sh *)
---

# worktree-create

> Use this skill; do not run `git worktree add` or the script on your own. The procedure below decides what to ask and when to stop.

Creates `worktrees/<repo>/<name>` with a new branch `<name>`. `<name>` may contain `/` (e.g. `feat/PROJ-123` → `worktrees/<repo>/feat/PROJ-123`); each part must be a valid file name, taken from a repo in `source/`.
All validation and creation is done by `scripts/worktree-create.sh` (in this skill's folder). Do not run `git worktree` yourself.

**Detached mode** (`--detach`): to look at an existing branch as it is, with no branch of its own (e.g. "monta la rama release/1.2", "quiero ver si el bug ya estaba en release/1.2"). The worktree is checked out in detached HEAD at that branch: nothing is created in git, nothing is tracked. Its name defaults to the branch without `origin/` (`origin/release/1.2` → `worktrees/<repo>/release/1.2`).

## Procedure

1. From the user's message, extract:
   - **source**: repo folder name in `source/` (optional if only one repo is cloned).
   - **name**: worktree name. Never invent it.
   - **detach**: the user wants to open an existing branch itself (a release, someone's branch to look at), not a new branch for a task. Then add `--detach` and `--branch origin/<branch>` (the up-to-date tip; the script fetches it), or `--branch <branch>` if the user asks for the local one. **name** is optional here: without it the script names the worktree after the branch.
   - **no-confirm**: the user explicitly says not to confirm anything (e.g. "sin confirmar", "no confirmes"). Then add `--no-confirm`.
   If only a base branch is given ("de la rama X") with no name and it is not clear whether the user wants a new branch or X itself, ask: a detached worktree of X, or a new branch (which name)?
2. Run from the repo root, passing only what you have:
   ```bash
   skills/worktree-create/scripts/worktree-create.sh [--source <repo>] [--name <name>] [--detach --branch <ref>] [--no-confirm]
   ```
3. Read the first word of stdout:

| Output | Exit | What to do |
|---|---|---|
| `CREATED <path> <base>` | 0 | Report path and base branch. If `CONFIG ...` lines follow, `config/<repo>/` was applied (see worktree-config): summarize them. Done. |
| `CREATED <path> <base> detached` | 0 | Same, and say it is in detached HEAD at `<base>`: to work on a fix there, create a branch (`git switch -c <name>`) or a normal worktree; `worktree-clean` removes it without `--force` while it has no commits of its own. |
| `CONFIG_FAILED <code>` | 14 | The worktree **was created**, but applying `config/<repo>/` failed (the `CONFIG ...` lines say why, e.g. `INSTALL_FAILED`). Report it; once fixed, run the `worktree-config` skill on `<repo>/<name>`. |
| `CHOOSE_SOURCE <repo>...` | 10 | Ask the user which repo. Valid answer: rerun with `--source <repo>`. Invalid or no answer: **finish with NO_SOURCE**. |
| `CONFIRM_BRANCH <branch> [behind=<n>]` | 11 | Ask: create the worktree from `<branch>`? If `behind=<n>` with n > 0, say the local `<branch>` is `<n>` commits behind `origin/<branch>` and offer `origin/<branch>` as the base (rerun with `--branch origin/<branch>`). A `warning:` on stderr means the remote could not be checked: say so. Offline: `--no-fetch`. Yes: rerun with `--branch <branch>`. User gives another branch: rerun with that one; it may exist only in `origin` and the script fetches it by itself. |
| `EXISTS <path>` | 12 | Tell the user; ask for another name. Never delete it. |
| `NO_SOURCE` | 4 | **Finish with NO_SOURCE** (no repo in `source/`, or the given one is not there). Suggest the `repo-clone` skill. |
| `NO_NAME` | 5 | **Finish with NO_NAME**. Do not ask or guess a name. (Never with `--detach --branch`: that one names itself.) |
| error on stderr | 2 / 3 | Show the message and ask the user. **Never fall back to another branch** (e.g. the current one) to get past it. |

Always keep the same `--source`/`--name`/`--detach` when rerunning after a question.

After creating, the script applies `config/<repo>/` to the new worktree by itself (copy + `install.sh`), using the `worktree-config` script. Pass `--no-config` only if the user asks not to.

The new branch is set to track `origin/<name>` (config only, **nothing is pushed**): the first `git push` in the worktree creates it in origin. Do not push for the user unless asked. A `--detach` worktree has no branch, so nothing is tracked or recorded.

## Rules

- "Finish with X" means: stop, report the literal failure code `X` and why. No workaround.
- If the branch the user chose fails (`branch not found`), report that and stop or ask. Never create the worktree from a different branch than the one the user chose.
- Never skip the branch confirmation unless the user explicitly said not to confirm.
- Never build paths by hand or delete folders in `worktrees/`.
- `worktrees/` is for worktrees only; `source/` repos are never modified except for the added worktree metadata.
