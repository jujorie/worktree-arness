# arness

Shared agent configuration (skills, agents, instructions) for Claude Code, Codex and OpenCode.

## Setup

Works on macOS and Linux/WSL. On WSL, keep the repo in the Linux filesystem (`~/src/...`), not under `/mnt/c`.

```bash
./setup.sh --provider claude          # required; or codex, opencode
./setup.sh --provider claude,codex    # comma list
./setup.sh --provider all             # every provider
./setup.sh --provider auto            # only providers whose CLI is installed
./setup.sh --help
```

Setup is idempotent: run it again after pulling or moving the repo. It never overwrites real files; it warns and skips.

Generated files (git-ignored, do not edit): `.claude/settings.json`, `.claude/skills`, `.claude/agents`, `.agents/skills`, `CLAUDE.md`.
Edit the sources instead: `skills/`, `agents/`, `AGENTS.md`, `providers/*/`.
Personal Claude settings go in `.claude/settings.local.json`.

## Memory

Agent memory is personal, so `.memory/` is git-ignored: it lives inside the repo folder but is never committed or shared.
Claude Code writes there automatically (`autoMemoryDirectory` in `providers/claude/settings.json`). Codex and OpenCode have no equivalent that can be redirected here.
To share or migrate memory, copy the folder by hand (`cp -R .memory /path/to/other/clone/`).

## Layout

| Path | Purpose |
|---|---|
| `skills/`, `agents/`, `AGENTS.md` | Shared content, single source of truth |
| `providers/` | One folder per provider (`claude`, `codex`, `opencode`) with its settings and `setup.sh`; see `providers/README.md` |
| `skills/<name>/` | A skill: `SKILL.md`, its `scripts/` (all scripts the skill needs) and `tests/` (bats) |
| `source/` | Repo clones, origin of the worktrees (git-ignored; see `source/README.md`) |
| `worktrees/` | One worktree per task, `worktrees/<repo>/<name>` (git-ignored; see `worktrees/README.md`) |
| `config/` | Local files copied into each new worktree, plus an optional `install.sh` (git-ignored; see `config/README.md`) |
| `scripts/lib.sh` | Helpers (`link`, `copy_once`, `render`) sourced by setup scripts |
| `tmp/` | Not in the repo (git-ignored), created by the scripts when needed: logs such as the `install.sh` output of `worktree-config` |
| `.env` | Local settings shared by skills, `KEY=value` per line (git-ignored). Scripts read it without sourcing it; a variable set in the terminal wins |

Settings templates use `{{$ARNESS_ROOT}}`, replaced with the absolute repo path at setup time.

## Skills

| Skill | Purpose |
|---|---|
| `repo-clone` | Clone a repo URL into `source/`; asks before overwriting or offers a copy under another name |
| `worktree-create` | Create a worktree in `worktrees/<repo>/<name>` from a repo in `source/`; confirms the base branch; fails with `NO_SOURCE` / `NO_NAME` |
| `worktree-config` | Copy `config/<repo>/` into an existing worktree and run its `install.sh` there; `worktree-create` runs it automatically |
| `worktree-clean` | List worktrees with merged status and remove the ones you pick (`all` = merged only) |
| `npm-run` | Run a `package.json` script of a worktree in the background (asks which worktree if there are several, and before installing dependencies); list, stop and clean up after them |

Rules for new skills: scripts go in `skills/<name>/scripts/`, tests in `skills/<name>/tests/`, and `name` in `SKILL.md` must equal the folder name.

## Tests (only needed if you change the scripts)

Not required to use the repo. If you modify `setup.sh`, `scripts/`, any `providers/*/setup.sh` or a skill's scripts, install the tools and run the suite:

```bash
brew install bats-core shellcheck            # macOS
sudo apt install bats shellcheck             # Ubuntu / WSL
./scripts/test.sh
```

CI runs the same suite on Ubuntu and macOS (`.github/workflows/test.yml`).
Scripts must stay portable: bash 3.2 (macOS default) compatible, no GNU-only flags (`sed -i`, `readlink -f`, `mapfile`...). The tests check this.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, branch and commit names, and [CODESTYLE.md](CODESTYLE.md) for the code conventions. `main` is protected: changes go through a pull request.

## License

[MIT](LICENSE)
