# providers/claude

Setup for [Claude Code](https://claude.com/claude-code). Run via `./setup.sh --provider claude` (or `providers/claude/setup.sh` directly).

## What `setup.sh` does

| Result (git-ignored) | Source | How |
|---|---|---|
| `.claude/skills` | `skills/` | relative symlink `../skills` |
| `.claude/agents` | `agents/` | relative symlink `../agents` |
| `.claude/settings.json` | `providers/claude/settings.json` | rendered copy, `{{$ARNESS_ROOT}}` -> absolute repo path |
| `CLAUDE.md` | `providers/claude/CLAUDE.md` | copied once, kept if it already has content |

`CLAUDE.md` only contains `@AGENTS.md`, so instructions live in one place: the root `AGENTS.md`.

## Files here

- `settings.json`: shared project settings **template**. Never put machine-specific paths in it; use `{{$ARNESS_ROOT}}`.
- `CLAUDE.md`: stub that imports `AGENTS.md`.
- `setup.sh`: the installer. Idempotent.

## Notes for agents and contributors

- Do not edit `.claude/settings.json`; it is regenerated on each setup. Edit `settings.json` here and re-run setup. A differing existing file is saved as `settings.json.bak`.
- Personal overrides go in `.claude/settings.local.json` (never touched by setup).
- Skills and agents are authored in `skills/` and `agents/` at the repo root, not under `.claude/`.
- Claude Code reads skills only from `.claude/skills` (project), `~/.claude/skills` and plugins. There is no setting for a custom path, hence the symlink.
- Restart the Claude session after adding skills or agents.

## Permissions

`settings.json` pre-approves, in `permissions.allow`, the `Skill(<name>)` of each repo skill and the `Bash(...)` call of its script (relative and absolute path). `allowed-tools` in a `SKILL.md` was not enough to avoid prompts with every model, so the rule lives here too. When you add a skill with a script, add its three entries.
