---
name: repo-create
description: Create a new GitHub repository with gh and clone it into this workspace's source/ folder, ready for worktree-create. Use whenever the user asks to create, make or start a new repo, e.g. "crea un repo nuevo", "new repo my-org/my-service". Always use this skill, never `gh repo create` or its script directly.
allowed-tools: Bash(skills/repo-create/scripts/repo-create.sh plan *)
---

# repo-create

> Use this skill; do not run `gh repo create`, `git clone` or the script on your own. The procedure below decides what to ask and when to stop.

Creates `<owner>/<name>` on GitHub and clones it into `source/<name>` (through the `repo-clone` script), so the other skills (`worktree-create`, `npm-run`...) work on it right away.
All the work is done by `scripts/repo-create.sh` (in this skill's folder), run from the repo root. It never prompts. `plan` checks everything and writes nothing. Only `apply` creates the repo, and it is deliberately **not** pre-allowed: creating a repository on GitHub is visible to others, so the agent's own permission prompt shows the command to the user before it runs.

## Procedure

1. Get from the user:
   - **owner** (organization or user) and **name**: `<owner>/<name>`. If the owner is missing, ask; do not guess it.
   - **visibility**: private (default), `--public` or `--internal` (organizations only). Never make it public unless the user says so.
   - optional **description** (`--description "<text>"`).
   - A README is added by default, so the repo has a `main` branch to base worktrees on. `--no-readme` only if the user wants an empty repo (then `worktree-create` has no base branch until something is pushed).
   - `--protocol ssh|https` only if the user asks; the default is gh's `git_protocol` for github.com.
2. Run the plan:
   ```bash
   skills/repo-create/scripts/repo-create.sh plan [options] <owner>/<name>
   ```
3. Read the first word of each stdout line:

| Output | Exit | What to do |
|---|---|---|
| `REPO`, `VISIBILITY`, `DESCRIPTION`, `README`, `PROTOCOL`, `DEST` lines, then `CONFIRM_CREATE <owner>/<name>` | 20 | Nothing was written. Show the plan (repo, visibility, description, README, clone protocol, destination folder) and ask for confirmation. On an explicit yes, go to step 4 with the **same** options. |
| `EXISTS <path>` | 10 | `source/<name>` already exists; nothing was created. Tell the user. The repo cannot be cloned there under another name by this skill: ask whether to pick another repo name, or free that folder first. |
| `REMOTE_EXISTS <owner>/<name> <url>` | 12 | The repo already exists on GitHub; nothing was created. Offer to clone it with the `repo-clone` skill (URL from the output). |
| `NO_OWNER <owner>` | 13 | No such user or organization. Show it and ask for the right owner. |
| `NO_AUTH` | 4 | `gh` is missing or not logged in to github.com. Tell the user to run `! gh auth login`; never log in for them. |
| error on stderr | 2 | Invalid repo, name or option. Show the message, fix the input or ask the user. |
| error on stderr | 3 | GitHub or network error. Show it. |

4. Create and clone:
   ```bash
   skills/repo-create/scripts/repo-create.sh apply [same options] <owner>/<name>
   ```
   `apply` runs every check of `plan` again, so it can also answer `EXISTS`, `REMOTE_EXISTS`, `NO_OWNER` or `NO_AUTH` (same actions as above).

| Output | Exit | What to do |
|---|---|---|
| `CREATED <owner>/<name> <path>` | 0 | Report the repo and the path. Offer `worktree-create` to start working on it. Done. |
| `NOT_CLONED <owner>/<name> <url>` | 14 | The repo **was created** on GitHub but the clone failed (the git error is on stderr). Say so, and offer to clone it with the `repo-clone` skill. Never run `apply` again: the repo already exists. |
| error on stderr | 3 | `gh repo create` failed (permissions in the organization, name taken, network). Nothing was created. Show the gh error. |

## Rules

- Never run `apply` without showing the plan and getting the user's explicit confirmation in this conversation, and always with the options of that plan.
- Never pick the owner or a public visibility on your own.
- Never delete a repository on GitHub, and never delete or overwrite folders in `source/`; the script refuses an existing destination.
- To clone a repo that already exists, use `repo-clone`, not this skill.
- `source/` is git-ignored, so the clone is never committed.
