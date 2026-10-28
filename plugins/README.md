# Plugins Folder

Plugins installed on this machine, one git clone per plugin, plus one `.<name>.state` file each. Everything here is git-ignored except this README.

A plugin is a git repo that brings its own skills, agents and tools (for example a CLI with its own dependencies) without adding them to arness. Its skills and agents are linked into `skills/` and `agents/`, which are private by default, so they are never committed.

## How it is used

Always through the `plugin-manage` skill. Each change is two steps: a plan that writes nothing, then `apply` with the commit the plan showed. `apply` is kept out of the permission allowlists on purpose, so the agent's own prompt asks you before anything runs.

| Need | Plan | Then |
|---|---|---|
| Install | `plugin-manage add [--ref <tag>] <url>`: source and commit, description, requirements, skills, agents, permission rules, install and uninstall commands | `apply add --commit <sha> <url>`: clones into `plugins/<name>`, links skills and agents, records the state, renders the Claude Code rules, runs `install` |
| Update | `plugin-manage update <name>`: the same, plus the rules that are new | `apply update --commit <sha> --ref <ref> <name>` |
| Remove | `plugin-manage remove <name>` | `apply remove <name>`: runs `uninstall`, removes the links, the clone, the state and its rules |
| List | `plugin-manage list` | State `OK`, `BROKEN_LINK`, `MODIFIED`, `INSTALL_FAILED` or `UNMANAGED` |
| Restore links | `./setup.sh --provider <p>` | Relinks the installed plugins and renders their rules |

A plugin installed at a tag (`--ref v1.2.0`) updates to the newest tag; one installed at a branch follows that branch.

## What is trusted

`apply` writes `plugins/.<name>.state` from the manifest it has just validated: commit, ref, version, skills, agents, uninstall command and permission rules. Rendering the settings, `sync`, `list` and `remove` read only that file, never the clone as it is now. So editing the clone or running `git pull` in it grants nothing: `list` reports it as `MODIFIED`, and `update` refuses it until it is removed or the change is undone.

## Plugin format

A repo with this layout; only `arness-plugin.conf` is required.

```
my-plugin/
├── arness-plugin.conf
├── README.md
├── skills/<prefix>-<name>/SKILL.md    same rules as arness skills (CODESTYLE.md)
├── agents/<prefix>-<name>.md          frontmatter name: <prefix>-<name>
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
requires=uv my-tool
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
| `agents` | no | Space-separated names; each has `agents/<n>.md` with `name: <n>` |
| `requires` | no | Commands that must be installed; checked, never installed |
| `install` / `uninstall` | no | Command run in the plugin folder after add or update / before remove. No time limit |
| `allow.claude` | no, repeatable | Claude Code rule, rendered into `.claude/settings.json` together with `Skill(<n>)` for each skill |
| `allow.opencode` | no, repeatable | OpenCode bash rule; printed for you to add to `opencode.json`, which setup never edits |

### Permission rules

An allowlist, not a denylist. A rule is accepted only when it is:

- `Bash(<command>)`, `Bash(<command> <args> ...)` or either with a trailing ` *` (OpenCode: the same without `Bash(...)`);
- for a `<command>` listed in `requires`, which is not a command runner (`bash`, `sh`, `env`, `xargs`, `python`, `node`, `git`, `find`, `awk`... see `RUNNERS` in the script);
- with literal arguments only: no wildcard other than the final ` *`, no quotes, `$`, `;`, `&` or `|`.

Anything else (`Read(...)`, `Write(...)`, `WebFetch(...)`, `Bash(*)`, `Bash(bash *)`) is `BAD_RULE`.

## Providers

| Provider | Skills | Agents | Rules |
|---|---|---|---|
| Claude Code | yes, through `.claude/skills` | yes, through `.claude/agents` | rendered from the state |
| Codex | yes, through `.agents/skills` | no | none |
| OpenCode | yes, through `.agents/skills` | no (it does not read `.claude/agents`) | manual in `opencode.json`: `MANUAL opencode bash <rule>` and `MANUAL opencode skill <name>` lines |

OpenCode's `skills/*/scripts/*.sh` rule runs every script of a plugin skill without asking; the plan lists them as `OPENCODE_AUTO_ALLOW`.

## Rules

- Install, update and remove plugins only with `plugin-manage`, never by hand: it validates the plugin, shows everything it will grant and run, and keeps links, state and rules in sync.
- Do not edit the clones or the state files here; make changes in the plugin's own repo and update.
- A plugin's `install` command runs code from that repo on your machine. Install plugins you trust, from `https://`, `ssh://` or `git@` URLs (plain `http://` is refused), pinned to a tag.
