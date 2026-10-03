# Source Folder

Main clones of the repos you work on. Everything here is git-ignored except this README.

## What goes here

One folder per repo: `source/<repo>/`, a full git clone. These are the **origin** of the worktrees; you do not work in them directly. Keep each on the branch you want new worktrees to start from.

## How it is used

| Need | Skill | Result |
|---|---|---|
| Clone a repo | `repo-clone <url>` | `source/<repo>/` (name derived from the URL, or `--name`) |
| Work on a branch | `worktree-create` | `worktrees/<repo>/<name>/`, created from `source/<repo>` |

## Rules

- Do not clone by hand or rename folders here; use `repo-clone`, which validates the URL and never overwrites work without asking.
- Do not commit or edit inside `source/<repo>/` for day-to-day work: make a worktree instead.
- `worktree-create` only sees direct subfolders with their own `.git`. With several repos it asks which one to use.
- `worktree-create` also records each worktree's base branch in the repo's git config (`branch.<name>.arness-base`), which `worktree-clean` uses.
