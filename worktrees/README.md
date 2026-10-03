# Worktrees Folder

Git worktrees of the repos in `source/`, one per task. Everything here is git-ignored except this README.

## Layout

```
worktrees/<repo>/<name>/
```

`<name>` is also the branch name, and may contain `/`: `feat/PROJ-123` gives `worktrees/<repo>/feat/PROJ-123` on branch `feat/PROJ-123`. Each part must be a valid file name (letters, digits, `.` `_` `-`).

## How it is used

| Need | Skill | What it does |
|---|---|---|
| New worktree | `worktree-create` | Creates the worktree and branch from `source/<repo>`, confirming the base branch. Then applies `config/<repo>/` (see below) |
| Re-apply local config | `worktree-config <repo>/<name>` | Copies `config/<repo>/**` into the worktree and runs `config/<repo>/install.sh` there |
| Clean up | `worktree-clean` | Lists worktrees with their merge status (`MERGED`, `EMPTY` = no commits yet, `NOT_MERGED`, `DIRTY`, `UNKNOWN_BASE`) and removes the ones you choose, with their branch |

## Rules

- Create and delete worktrees only with these skills (or their scripts in `skills/*/scripts/`), never by hand: they keep `source/<repo>` consistent.
- Do not put anything else here; `worktree-clean` assumes every folder is a worktree.
- Work inside `worktrees/<repo>/<name>/`; leave `source/<repo>` untouched.
