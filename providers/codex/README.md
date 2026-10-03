# providers/codex

Setup for Codex CLI. Run via `./setup.sh --provider codex`.

## What `setup.sh` does

| Result (git-ignored) | Source | How |
|---|---|---|
| `.agents/skills` | `skills/` | relative symlink `../skills` |

Codex reads `AGENTS.md` natively, so the root `AGENTS.md` is used as is. Codex scans skills in `.agents/skills` (repo, walking up to the repo root), `$HOME/.agents/skills`, `/etc/codex/skills` and built-ins. `.agents/skills` is shared with OpenCode; the link is idempotent so both providers can be set up together.

## Memory

Codex follows the memory contract in the root `AGENTS.md` (read/write `.memory/`). That is guidance only. Codex hooks (`SessionStart`, `Stop`) could force it but need the `codex_hooks` flag and some versions had bugs with repo-local config; not adopted yet.

## Not done yet (TODO)

- Subagents: location and format not verified. Check the Codex docs before adding.
- `~/.codex/config.toml` is user-level (global). Do not generate it from the repo without a clear need; if needed, add a template here and render it with `render` from `scripts/lib.sh`.

## Notes for agents and contributors

- Skills use `SKILL.md` with `name` and `description` frontmatter. Two skills with the same `name` are not merged.
- Author skills in `skills/` at the repo root, not under `.agents/`.
- Keep `setup.sh` portable (bash 3.2, no GNU-only flags). Tests: `./scripts/test.sh`.
