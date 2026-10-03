---
name: worktree-config
description: Copy the local files in this arness workspace's config/<repo>/ into an existing worktree and run config/<repo>/install.sh in it. Use when the user asks to configure, set up or re-apply the config of a worktree given as <repo>/<name>. worktree-create already runs it on new worktrees.
allowed-tools: Bash(skills/worktree-config/scripts/worktree-config.sh *)
---

# worktree-config

Applies `config/<repo>/` to `worktrees/<repo>/<name>`.
All validation, copying and execution is done by `scripts/worktree-config.sh` (in this skill's folder). Do not copy files or run `install.sh` yourself.

What it does:
- Every file under `config/<repo>/` is copied to the same relative path in the worktree (`config/a/src/test.js` → `worktrees/a/<name>/src/test.js`). Existing files are overwritten.
- `config/<repo>/install.sh` is not copied: it runs with cwd = the worktree, after the copy (build, install deps...). Its output goes to `tmp/worktree-config/<repo>/<name>-install.log`, not to the console.

## Procedure

1. Get the worktree slug `<repo>/<name>` from the user (e.g. `my-repo/feat/PROJ-123`; the name may contain `/`). It is the same repo and name given to `worktree-create`. **If you do not have it, stop**: report `NO_WORKTREE` and ask for it. Do not guess.
2. Run from the repo root:
   ```bash
   skills/worktree-config/scripts/worktree-config.sh <repo>/<name>
   ```
3. Read the stdout:

| Output | Exit | What to do |
|---|---|---|
| `DONE <path> files=<n> install=<yes\|no>` | 0 | Report it, with the `COPIED` lines if useful. |
| `NO_CONFIG <repo>` | 0 | Nothing in `config/<repo>/`; tell the user. |
| `NO_WORKTREE` | 5 | **Finish with NO_WORKTREE**. Ask for `<repo>/<name>`. |
| `NOT_FOUND <path>` | 4 | The worktree does not exist. Suggest `worktree-create`, or check the slug. |
| `INSTALL_FAILED <code> <log>` | 7 | Files are copied but `install.sh` failed. The last 20 lines of its output are on stderr; the full log is at `<log>` (read it only if needed). |
| `SKIPPED <file> <reason>` | 13 | Some files were not copied (symlink, reserved `.git`, conflict). Report each. |
| error on stderr | 2 | Invalid slug. Show the message. |

## Rules

- "Finish with X" means: stop, report the literal failure code `X` and why. No workaround.
- `config/` is git-ignored and local to each user; its `install.sh` is user code and runs as is.
- Never build paths by hand or write inside `worktrees/` yourself.
