---
name: worktree-config
description: Apply config/<repo>/ to an existing worktree: copy its files and run install.sh there. Use whenever the user asks to configure, set up, prepare or re-apply the config of a worktree <repo>/<name>, e.g. "configura el worktree", "prepara el worktree", "instala dependencias". Always use this skill, never its script directly. worktree-create already runs it.
allowed-tools: Bash(skills/worktree-config/scripts/worktree-config.sh *)
---

# worktree-config

> Use this skill; do not run the script on your own. The procedure below decides what to ask and when to stop.

Applies `config/<repo>/` to `worktrees/<repo>/<name>`.
All validation, copying and execution is done by `scripts/worktree-config.sh` (in this skill's folder). Do not copy files or run `install.sh` yourself.

What it does:
- Every file under `config/<repo>/` is copied to the same relative path in the worktree (`config/a/src/test.js` → `worktrees/a/<name>/src/test.js`). Existing files are overwritten.
- Files matched by `config/.configignore` or `config/<repo>/.configignore` are not copied (see *Ignore file*). Without them nothing is ignored: dotfiles like `.env` or `.claude/` are copied, and so is `.DS_Store`.
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

## Ignore file

`.configignore` lists what not to copy. Two places, and their rules are added together: `config/.configignore` (all repos) and `config/<repo>/.configignore` (that repo). Neither is copied. Ignored files are skipped without a line in the output. It follows the `.gitignore` idea, in a simpler form. If asked to create or edit one, use exactly this syntax:

- One rule per line. Blank lines and lines starting with `#` are ignored.
- A rule without `/` is a glob on any name of the path: `.DS_Store` matches it in any folder, `.vscode` matches that folder at any depth and everything in it.
- A rule with `/` in the middle is a glob on the whole path relative to `config/<repo>/`: `.vscode/*` is only the top-level `.vscode`, `pkg/.vscode/*` only that one. `*` also crosses `/`.
- A leading `/` is dropped (paths are always from the root); a trailing `/` means everything under it (`build/` = `build/*`).
- Globs are `*`, `?` and `[abc]`. Not supported: `!` negation, `**`, escapes.

```
# config/mplus-bob/.configignore
.DS_Store
._*
.vscode/*
```

## Rules

- "Finish with X" means: stop, report the literal failure code `X` and why. No workaround.
- `config/` is git-ignored and local to each user; its `install.sh` is user code and runs as is.
- Never build paths by hand or write inside `worktrees/` yourself.
