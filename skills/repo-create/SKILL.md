---
name: repo-create
description: >-
  Create a new repository in this workspace's source/ folder, ready for worktree-create: on GitHub with
  gh and cloned, or local only (git init, no GitHub), and later publish a local one to GitHub. Use
  whenever the user asks to create, make or start a new repo, local or on GitHub, or to publish or push
  a local repo to GitHub, e.g. "crea un repo nuevo", "new repo my-org/my-service", "crea un repo local
  sin GitHub", "sube el repo local a GitHub". Always use this skill, never `gh repo create`, `git init`
  or its script directly.
allowed-tools: Bash(skills/repo-create/scripts/repo-create.sh plan *)
---

# repo-create

> Use this skill; do not run `gh repo create`, `git init`, `git clone` or the script on your own. The procedure below decides what to ask and when to stop.

Puts a new repository in `source/<name>`, so the other skills (`worktree-create`, `worktree-config`, `worktree-clean`...) work on it right away. Three modes:

| Mode | Option | What it does |
|---|---|---|
| GitHub | (none) | Creates `<owner>/<name>` on GitHub and clones it into `source/<name>` (through the `repo-clone` script). |
| Local | `--local <name>` | Only a local repo: `git init` in `source/<name>`, branch `main` and an initial commit (with a README unless `--no-readme`), no remote. Nothing goes to GitHub and `gh` is not needed. |
| Publish | `--publish <owner>/<name>` | For a local repo made with `--local`: creates `<owner>/<name>` on GitHub, empty, sets it as `origin` of `source/<name>` and pushes the branch checked out there, with tracking. |

All the work is done by `scripts/repo-create.sh` (in this skill's folder), run from the repo root. It never prompts. `plan` checks everything and writes nothing. Only `apply` writes, and it is deliberately **not** pre-allowed in any mode: creating a repository on GitHub is visible to others, so the agent's own permission prompt shows the command to the user before it runs.

## Procedure

1. Pick the mode from what the user asked: a repo "local", "sin GitHub", "sin remoto" → `--local`; publish, upload or push a local repo to GitHub → `--publish`; otherwise GitHub. If it is not clear whether the repo should exist on GitHub, ask.
2. Get from the user:
   - **name**: `<owner>/<name>` for GitHub and `--publish`; only `<name>` for `--local`. If the owner is missing in a mode that needs it, ask; do not guess it. For `--publish`, `<name>` is the folder in `source/` and the repo name on GitHub.
   - **visibility** (GitHub and `--publish`): private (default), `--public` or `--internal` (organizations only). Never make it public unless the user says so.
   - optional **description** (`--description "<text>"`). With `--local` it goes into the README, so it cannot go with `--no-readme`.
   - A README is added by default (GitHub and `--local`), so the repo has a `main` branch to base worktrees on. `--no-readme` only if the user wants no README: with `--local` the initial commit is then empty (`main` still exists); on GitHub the repo is empty and `worktree-create` has no base branch until something is pushed. `--publish` takes no `--no-readme`.
   - `--protocol ssh|https` (GitHub and `--publish`) only if the user asks; the default is gh's `git_protocol` for github.com.
3. Run the plan:
   ```bash
   skills/repo-create/scripts/repo-create.sh plan [mode] [options] <owner>/<name>|<name>
   ```
4. Read the first word of each stdout line:

| Output | Exit | What to do |
|---|---|---|
| plan lines (`REPO`, `MODE`, `VISIBILITY`, `DESCRIPTION`, `README`, `PROTOCOL`, `BRANCH`, `DEST`, whichever the mode prints), then `CONFIRM_CREATE <repo>` or `CONFIRM_PUBLISH <owner>/<name>` | 20 | Nothing was written. Show the plan (repo, mode, visibility, description, README, clone protocol, branch, folder) and ask for confirmation. For `--publish` say which branch will be pushed and that it becomes the default branch on GitHub. On an explicit yes, go to step 5 with the **same** options. |
| `EXISTS <path>` | 10 | GitHub or `--local` (also from `apply --local` if the folder appeared after the check): `source/<name>` already exists; nothing was created. Tell the user. The repo cannot be put there under another name by this skill: ask whether to pick another repo name, or free that folder first. If it is a local repo the user wants on GitHub, that is `--publish`. |
| `REMOTE_EXISTS <owner>/<name> <url>` | 12 | The repo already exists on GitHub; nothing was created. GitHub mode: offer to clone it with the `repo-clone` skill (URL from the output). `--publish`: tell the user and ask for another name; never link or push to an existing repo. |
| `NO_OWNER <owner>` | 13 | No such user or organization. Show it and ask for the right owner. |
| `NO_LOCAL <path>` | 18 | `--publish`: `source/<name>` does not exist or is not the top of a git repo (reason on stderr). Nothing was done. Offer `--local` to create it, or ask for the right name. |
| `HAS_REMOTE <path> <url>` | 19 | `--publish`: the local repo already has an `origin`; nothing was done. Tell the user; this skill never replaces a remote. |
| `NO_AUTH` | 4 | `gh` is missing or not logged in to github.com. Tell the user to run `! gh auth login`; never log in for them. `--local` never needs it. |
| error on stderr | 2 | Invalid repo, name or option, or (`--publish`) a local repo with a detached HEAD or no commit. Show the message, fix the input or ask the user. |
| error on stderr | 3 | GitHub, network or git error. Show it. |

5. Create:
   ```bash
   skills/repo-create/scripts/repo-create.sh apply [same mode and options] <owner>/<name>|<name>
   ```
   `apply` runs every check of `plan` again, so it can also answer any status of the table above (same actions).

| Output | Exit | What to do |
|---|---|---|
| `CREATED <owner>/<name> <path>` | 0 | GitHub mode. Report the repo and the path. Offer `worktree-create` to start working on it. Done. |
| `CREATED_LOCAL <name> <path>` | 0 | `--local`. Report the path and that it has branch `main` and no remote. Offer `worktree-create`, and say it can be put on GitHub later with `--publish`. Done. |
| `PUBLISHED <owner>/<name> <path> <branch>` | 0 | `--publish`. Report the repo, that `<branch>` was pushed and is tracked from `origin`. Done. |
| `NO_IDENTITY` | 5 | `--local`: git has no `user.name` or `user.email` for the new repo; the folder was removed again. Tell the user to set them; never set git config for them. |
| `NOT_CLONED <owner>/<name> <url>` | 14 | The repo **was created** on GitHub but it was not cloned; the reason is on stderr. Say so, and offer to clone it with the `repo-clone` skill. Never run `apply` again: the repo already exists. |
| `NOT_LINKED <owner>/<name> <url>` | 17 | `--publish`: the repo **was created** on GitHub, empty, but it is not set as `origin` of the local repo (reason on stderr). Say so, and only on the user's yes add it and push: `git -C <path> remote add origin <url>` and `git -C <path> push -u origin <branch>`. Never run `apply` again. |
| `NOT_PUSHED <owner>/<name> <url>` | 16 | `--publish`: the repo **was created** and is `origin` of the local repo, but the push failed (reason on stderr). Show the error and, once its cause is fixed and only on the user's yes, push: `git -C <path> push -u origin <branch>`. Never run `apply` again. |
| `CREATE_FAILED_EXISTS <owner>/<name> <url>` | 15 | `gh repo create` failed (its error is on stderr), yet the repo exists on GitHub, and nothing was cloned or linked. It may have been created by this call just before the error, or by someone else after the checks: there is no way to tell. Tell the user both possibilities. GitHub mode: ask whether to clone it with the `repo-clone` skill (URL from the output). `--publish`: never link or push to it without the user's explicit yes after they checked it is theirs and empty. Never run `apply` again. |
| error on stderr | 3 | `gh repo create`, `git init` or the initial commit failed (permissions in the organization, name taken, network). Show the error. If it says the repo `was not found on GitHub right after the failure`, it was most likely not created; if it says to run plan, it may exist. Either way, before retrying run `plan` again and follow its status. `--local` removes the folder it made when it fails before the initial commit. |
| no status line, any other exit (e.g. 130 after Ctrl-C) | other | `apply` was interrupted and the repo may exist. Run `plan` again and follow its status. |

## Rules

- Never run `apply` without showing the plan and getting the user's explicit confirmation in this conversation, and always with the mode and options of that plan.
- Never pick the owner or a public visibility on your own.
- Never delete a repository on GitHub, and never delete or overwrite folders in `source/`; the script refuses an existing destination (and, with `--publish`, a local repo that already has an `origin`).
- To clone a repo that already exists, use `repo-clone`, not this skill, and only after the user says yes: `REMOTE_EXISTS` and `CREATE_FAILED_EXISTS` never clone or link on their own.
- A `--local` repo is a normal git repo in `source/`: work on it through `worktree-create`, as with any clone. `worktree-clean` judges merges against the local base branch while it has no `origin`.
- `source/` is git-ignored, so neither the clone nor the local repo is ever committed to arness.
