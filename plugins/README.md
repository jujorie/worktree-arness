# Plugins Folder

Plugins installed on this machine, one git clone per plugin. Everything here is git-ignored except this README.

A plugin is a git repo that brings its own skills, agents and tools (for example a CLI with its own dependencies) without adding them to arness. Its skills and agents are linked into `skills/` and `agents/`, which are private by default, so they are never committed.

## How it is used

| Need | Skill | What it does |
|---|---|---|
| Install | `plugin-manage add <url>` | Clones into `plugins/<name>`, links skills and agents, renders its Claude Code rules into `.claude/settings.json`, runs its `install` command. Shows the plan and asks first |
| Update | `plugin-manage update <name>` | Fetches, shows what changes (new permission rules included), then moves the clone and refreshes links, rules and `install` |
| Remove | `plugin-manage remove <name>` | Runs `uninstall`, removes its links, the clone and its rules |
| List | `plugin-manage list` | Name, version, commit, state (`OK`, `BROKEN_LINK`, `DIRTY`, `INSTALL_FAILED`) |
| Restore links | `./setup.sh --provider <p>` | Relinks the plugins found here and renders their rules |

## Plugin format

A repo with this layout; only `arness-plugin.conf` is required.

```
my-plugin/
├── arness-plugin.conf
├── README.md
├── skills/<prefix>-<name>/SKILL.md    same rules as arness skills (CODESTYLE.md)
├── agents/<prefix>-<name>.md
└── ...                                 its own code, tests and CI
```

`arness-plugin.conf` is one `KEY=value` per line, like `.env`; `#` starts a comment. Unknown keys and repeated single keys are errors.

```
name=my-plugin
version=0.1.0
prefix=my-
arness=1
description=What the plugin does, one line
skills=my-init my-check
agents=my-reviewer
requires=uv git
install=uv tool install --force .
uninstall=uv tool uninstall my-plugin
allow.claude=Bash(my-tool *)
allow.opencode=my-tool *
```

| Key | Required | Value |
|---|---|---|
| `name` | yes | Lowercase slug; the folder in `plugins/` |
| `version` | yes | `MAJOR.MINOR.PATCH` |
| `prefix` | yes | Slug ending in `-`; every skill and agent name starts with it, so plugins do not collide |
| `arness` | yes | Plugin contract version, `1` |
| `description` | yes | One line, at most 200 characters |
| `skills` | no | Space-separated names; each has `skills/<n>/SKILL.md` with `name: <n>` |
| `agents` | no | Space-separated names; each has `agents/<n>.md` |
| `requires` | no | Commands that must be installed; checked, never installed |
| `install` / `uninstall` | no | Command run in the plugin folder after add or update / before remove |
| `allow.claude` | no, repeatable | Claude Code rule, `Tool(pattern)`, added to `.claude/settings.json` with `Skill(<n>)` for each skill |
| `allow.opencode` | no, repeatable | OpenCode bash rule; printed for the user to add to `opencode.json`, which setup never edits |

A rule that starts with `*` or a space, or a bare tool name such as `Bash`, is rejected as too broad.

## Providers

| Provider | Skills | Agents | Rules |
|---|---|---|---|
| Claude Code | yes, through `.claude/skills` | yes, through `.claude/agents` | rendered |
| Codex | yes, through `.agents/skills` | no | none |
| OpenCode | yes, through `.agents/skills` | no (it does not read `.claude/agents`) | manual, in `opencode.json` |

## Rules

- Install, update and remove plugins only with `plugin-manage`, never by hand: it validates the plugin, shows its permission rules and install command before running them, and keeps links and rules in sync.
- Do not edit the clones here; make changes in the plugin's own repo and update.
- A plugin's `install` command runs code from that repo on your machine. Install plugins you trust, pinned to a tag (`--ref`).
