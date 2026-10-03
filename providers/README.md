# Providers Folder

Everything specific to each agent tool (Claude Code, Codex, OpenCode) lives here, one folder per provider. The shared content (`skills/`, `agents/`, `AGENTS.md`) stays at the repo root and is wired to each tool by that provider's `setup.sh`.

Not to be confused with `config/` at the repo root, which holds local files copied into worktrees (see `config/README.md`).

## Layout

```
providers/<provider>/
├── setup.sh      installer for this provider, idempotent
├── README.md     what it generates and provider-specific notes
└── ...           templates it renders or copies (settings.json, CLAUDE.md, opencode.json)
```

| Provider | Folder | Setup generates (git-ignored) |
|---|---|---|
| Claude Code | `providers/claude/` | `.claude/skills`, `.claude/agents` (symlinks), `.claude/settings.json` (rendered), `CLAUDE.md` |
| Codex | `providers/codex/` | `.agents/skills` (symlink) |
| OpenCode | `providers/opencode/` | `.agents/skills` (symlink), `opencode.json` (copied once), `.memory/MEMORY.md` |

## How it is used

- Run `./setup.sh --provider <name>` from the repo root (`claude`, `codex`, `opencode`, a comma list, `all` or `auto`). It runs `providers/<name>/setup.sh` for each one. See the root `README.md`.
- Edit the sources here and re-run setup. Never edit the generated files: `.claude/`, `.agents/`, `CLAUDE.md`, `opencode.json`.
- Templates use `{{$ARNESS_ROOT}}`, replaced with the absolute repo path at setup time (`render` in `scripts/lib.sh`). Never put machine-specific paths in them.
- Permissions that let agents run the skills' scripts without asking live here too: `permissions.allow` in `providers/claude/settings.json` and `permission` in `providers/opencode/opencode.json`. A new skill with a script needs its entries added.

## Adding a provider

1. Create `providers/<name>/setup.sh` (source `scripts/lib.sh`, resolve `ARNESS_ROOT` as the others do) and a `README.md`.
2. Add `<name>` to `PROVIDERS_ALL` and to the `case` in the root `setup.sh`.
3. Run `./scripts/test.sh`.
