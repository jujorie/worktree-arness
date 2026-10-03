# providers/opencode

Setup for [OpenCode](https://opencode.ai). Run via `./setup.sh --provider opencode`.

## What `setup.sh` does

| Result (git-ignored) | Source | How |
|---|---|---|
| `.agents/skills` | `skills/` | relative symlink `../skills` |
| `opencode.json` | `providers/opencode/opencode.json` | copied once; kept if it already has content |
| `.memory/MEMORY.md` | n/a | created empty if missing |

`opencode.json` sets `instructions: [".memory/MEMORY.md"]`, so the memory index is always in context (see the Memory section of the root `AGENTS.md`). Because it is copied once, later template changes are not propagated; edit your local `opencode.json` or delete it and re-run setup.

OpenCode reads `AGENTS.md` natively. For skills it searches `.opencode/skills`, `.claude/skills` and `.agents/skills` (project, walking up to the git root) plus the global equivalents. We use `.agents/skills`, shared with Codex. If Claude is also set up, OpenCode would see the same skills via `.claude/skills` too; same `name` and same files, so no conflict.

## Not done yet (TODO)

- Agents: OpenCode reads `.opencode/agents/<name>.md` and does **not** read `.claude/agents`. Frontmatter differs from Claude (`mode`, `permission`, `model`, `temperature`...). Do not link `agents/` blindly; translate or keep per-provider agents first.
- Memory writes: OpenCode has no native memory. Writing relies on the contract in `AGENTS.md`; a plugin or MCP server could enforce it later.

## Notes for agents and contributors

- Skill `name` must match `^[a-z0-9]+(-[a-z0-9]+)*$` and equal its directory name; `description` is 1-1024 chars.
- Author skills in `skills/` at the repo root, not under `.agents/`.
- Keep `setup.sh` portable (bash 3.2, no GNU-only flags). Tests: `./scripts/test.sh`.
