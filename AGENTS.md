# arness

Shared agent configuration (skills, agents, instructions) used with Claude Code, Codex and OpenCode. See `README.md` for setup.

## Repo rules

- Shared content is authored at the repo root: `skills/`, `agents/`, `AGENTS.md`. Never edit generated files (`.claude/`, `.agents/`, `CLAUDE.md`, `opencode.json` copies); edit the sources in `providers/*/` and re-run `./setup.sh --provider <name>`.
- Shell scripts must run on macOS (bash 3.2) and Linux/WSL: no GNU-only flags (`sed -i`, `readlink -f`, `mapfile`). Run `./scripts/test.sh` after changing them.
- Skills: each lives in `skills/<name>/` with `SKILL.md`, its scripts in `skills/<name>/scripts/` and bats tests in `skills/<name>/tests/`. To clone a repo, use the `repo-clone` skill.
- Workspace folders (git-ignored, each has a README with its usage): `source/` repo clones (`repo-clone`), `worktrees/<repo>/<name>` one per task (`worktree-create`, `worktree-config`, `worktree-clean`), `config/<repo>/` local files copied into each new worktree. Work in a worktree, not in `source/`. Read the folder's README before using it.

## Memory

Persistent project memory lives in `.memory/` (git-ignored, personal to each user).

- At the start of a task, read `.memory/MEMORY.md`. It is an index: one line per memory, `- [Title](file.md) — hook`. Open only the files relevant to the task.
- When you learn something durable that is not obvious from the code or git history (user preferences, corrections to your approach, project decisions and their reason, pointers to external resources), save it:
  1. Write `.memory/<short-kebab-name>.md` with this frontmatter, then the fact:
     ```markdown
     ---
     name: <short-kebab-name>
     description: <one-line summary used to decide relevance>
     metadata:
       type: user | feedback | project | reference
     ---
     ```
  2. Add one line to `.memory/MEMORY.md`. No frontmatter and no memory content in the index.
- Before saving, check for an existing memory on the same topic and update it instead of duplicating. Delete memories that turn out to be wrong.
- Do not save what the repo already records (code structure, past fixes, git history) or anything only relevant to the current conversation.
- Never store secrets or credentials.
