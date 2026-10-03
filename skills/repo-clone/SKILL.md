---
name: repo-clone
description: Clone a git repository into this workspace's source/ folder. Use whenever the user asks to clone, download, fetch or get a repo from a URL (https, ssh, git@), e.g. "clona el repo", "baja el repositorio". Always use this skill, never `git clone` or its script directly.
allowed-tools: Bash(skills/repo-clone/scripts/repo-clone.sh *)
---

# repo-clone

> Use this skill; do not run `git clone` or the script on your own. The procedure below decides what to ask and when to stop.

Clones a repository into `source/<name>` at the root of this repo. Always `source/`; never clone elsewhere.
All validation and cloning is done by `scripts/repo-clone.sh` (in this skill's folder). Do not run `git clone` yourself.

## Procedure

1. Get the repository URL from the user. If missing, ask for it.
2. Run the script from the repo root:
   ```bash
   skills/repo-clone/scripts/repo-clone.sh <url>
   ```
   Optional flags: `--name <dir>` (destination folder name; default is derived from the URL), `--depth <n>` (shallow clone; default is a full clone, add it only if the user asks or the repo is huge).
3. Read the first word of stdout:

| Output | Exit | What to do |
|---|---|---|
| `CLONED <path>` | 0 | Report the path. Done. |
| `EXISTS <path>` | 10 | Ask the user: **overwrite** the existing folder, or **clone under another name**? Then go to step 4. |
| `DIRTY <path> <reason>` | 11 | Overwrite was refused because the existing folder has `uncommitted-changes`, `unpushed-commits` or is `not-a-git-repo`. Tell the user what would be lost. Only if they explicitly confirm, repeat with `--overwrite --force`. |
| error on stderr | 2 | Invalid URL, name or option. Show the message, fix the input or ask the user. |
| error on stderr | 3 | Clone failed (network, auth, wrong URL). Show the git error. |

4. Resolve `EXISTS`:
   - Overwrite: rerun with `--overwrite` (same URL). If it answers `DIRTY`, follow the table above.
   - Another name: ask for the name, rerun with `--name <new-name>`. If that also answers `EXISTS`, ask again.

## Rules

- Never pass `--overwrite` or `--force` without the user's explicit answer in this conversation. Overwrite deletes the existing folder.
- Never build the destination path yourself or delete folders in `source/` by hand; the script guards against paths outside `source/`.
- The script never prompts. Private repos need credentials already configured (ssh agent or git credential helper); if the clone fails for auth, say so.
- `source/` is git-ignored, so cloned repos are never committed.
