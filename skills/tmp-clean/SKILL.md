---
name: tmp-clean
description: List what skills left in tmp/ that nothing needs any more (state of removed worktrees, old analyses and reviews) and remove what the user picks; purge everything kept for a ticket or pull request once it is closed. Use whenever the user asks to clean, purge or tidy tmp, e.g. "limpia tmp", "qué sobra en tmp", "borra lo de tmp de PROJ-123", or when a skill closes a ticket or pull request.
allowed-tools: Bash(skills/tmp-clean/scripts/tmp-clean.sh *)
---

# tmp-clean

> Use this skill; do not delete folders in `tmp/` yourself. The procedure below decides what to ask and when to stop.

Skills keep their files in `tmp/<skill>/<key>` (see `CODESTYLE.md` → *Files in tmp/*). `worktree-clean` already removes `tmp/<skill>/<repo>/<name>` with its worktree; this skill catches what is left: state of worktrees removed by other means, and folders of tickets and pull requests nobody closed.
All logic is in `scripts/tmp-clean.sh` (in this skill's folder).

## Procedure

### Clean up (the user asks what to clean)

1. List, from the repo root (`--days N` if the user gave an age; default 30):
   ```bash
   skills/tmp-clean/scripts/tmp-clean.sh list [--days N]
   ```
2. Status → action:

   | Status | Meaning | Action |
   |---|---|---|
   | `NONE` | nothing to clean | Say so. Done. |
   | `ORPHAN <path> <kb>` | state of a worktree that no longer exists | Safe to remove. |
   | `STALE <path> <kb>` | a ticket, PR or other key with nothing changed in N days | May still matter (a ticket waiting for weeks): the user decides one by one. |
   | `note: <path> still runs` (stderr) | holds the pid of a live process | Not listed; mention it. |

3. Show a numbered table: `#`, status, path, KB, grouped by `tmp/<skill>`. Ask which to remove: numbers, paths, or `all` / `todos`. **`all` means every `ORPHAN` only**; `STALE` entries go only when named, or when the user says so explicitly (`y los antiguos también`).
4. Remove the chosen ones in one call, with the same `--days` as the list:
   ```bash
   skills/tmp-clean/scripts/tmp-clean.sh remove [--days N] <path>...
   ```
   Report each `REMOVED <path>` and each `SKIPPED <path> not-listed` (it changed since the list: list again).

### Purge a closed ticket or pull request

When a ticket or pull request is closed (merged, discarded, review finished), or the user asks for it:
```bash
skills/tmp-clean/scripts/tmp-clean.sh purge <KEY>...
```
`<KEY>` is the folder name the skills used: the ticket id (`PROJ-123`), the pull request number or `PR-<n>`. It removes `tmp/<skill>/<KEY>` and `tmp/<skill>/<KEY>.*` of every skill, whatever their age. One `PURGED <path>` each, or `NONE`. `SKIPPED <key> invalid-key`: not a single safe name. `SKIPPED <path> running`: holds a live pid; stop that first.

Before purging, if a file there holds a conclusion worth keeping (an analysis, a review report), make sure it already lives where the task is tracked (the ticket, the pull request); if not, ask the user.

## Rules

- **Never `remove` without asking first**: show the table and get the user's answer. Skip the question only if the user's own message names the exact paths.
- `purge` needs no table, but only for a key that is closed or that the user named.
- Paths come from `list`; do not build them by hand. Never `rm` anything in `tmp/` yourself.
- A subagent cannot ask: it returns the table, it does not remove.
