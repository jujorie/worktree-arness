---
name: worktree-clean
description: List the worktrees in this arness workspace's worktrees/ folder with their merge status and remove the ones the user picks. Use when the user asks to clean, list, prune or delete worktrees, or to remove the ones already merged.
allowed-tools: Bash(skills/worktree-clean/scripts/worktree-clean.sh *)
---

# worktree-clean

Lists `worktrees/<repo>/<name>` and removes the chosen ones (worktree + its branch) with git.
All logic is in `scripts/worktree-clean.sh` (in this skill's folder). Do not run `git worktree remove` or `git branch -d` yourself.

## Procedure

1. List, from the repo root (add `--source <repo>` if the user named one):
   ```bash
   skills/worktree-clean/scripts/worktree-clean.sh list
   ```
   - `NONE`: tell the user there is nothing to clean. Done.
   - `NO_SOURCE` (exit 4): no repo in `source/`. Done.
   - Otherwise one tab-separated row per worktree: `repo name branch base status ahead path`.
2. Show a numbered markdown table: `#`, repo, name, base, status, ahead. Status meaning:
   - `EMPTY`: the branch has no commits of its own yet (a worktree just created). Nothing was merged and nothing is lost, but it is **not** "merged": never describe it as merged.
   - `MERGED`: branch is in its base, or in `origin/<base>` (merged in the remote while the local base is behind). Safe to remove.
   - `NOT_MERGED`: has `ahead` commits not in base. Removing loses them.
   - `DIRTY`: uncommitted changes. Removing loses them.
   - `UNKNOWN_BASE`: base not recorded (worktree not made by `worktree-create`). Ask the user for the base branch and rerun `list --base <ref>`, or treat it like `NOT_MERGED`.
   - Note: squash or rebase merges are not detected; they show as `NOT_MERGED`.
   - The remote side of each base (`origin/<branch>`, or `origin/<base>` for a local base) is refreshed first (one `git fetch` per base). If the fetch fails a `warning:` appears on stderr and the status may be stale: tell the user. Offline: add `--no-fetch`.
3. Ask: which to delete? A comma-separated list (numbers or names), or `all` / `todos`.
   - `all` / `todos` means **every `MERGED` worktree only**. Never include `EMPTY` or any other status in it; those only by explicit name.
   - If nothing is `MERGED` and the user said `all`, say so and ask for explicit names.
4. For each chosen worktree that is not `MERGED`, ask a second confirmation naming what is lost (the `ahead` commits, or the uncommitted changes). Only if the user confirms, it goes with `--force`.
5. Run one `remove` per repo, grouping names (no `--force` for the merged ones; a separate call with `--force` for the confirmed ones):
   ```bash
   skills/worktree-clean/scripts/worktree-clean.sh remove --source <repo> [--base <ref>] [--force] <name>...
   ```
6. Report each `REMOVED <path>` and each `SKIPPED <path> <reason>` (exit 13 means at least one skipped).

## Rules

- **Never run `remove` without asking first.** Always show the table, then ask which to delete and get the user's answer before any `remove`. Do not run `list` and `remove` in the same step, even if the user said "clean" or "delete the merged ones", and even if only one worktree is listed: the user must see the table and confirm the exact list. Only skip the question if the user's own message already names the exact worktrees to delete.
- If a status looks wrong (e.g. `MERGED` for a worktree the user just created), do not delete; tell the user.
- Never pass `--force` without the user's explicit confirmation in this conversation for those specific worktrees.
- Never build paths by hand or delete folders in `worktrees/` or `source/` yourself.
- Names come from the `name` column of `list`; do not invent them.
