---
name: plugin-manage
description: Add, update, remove, list or check arness plugins, git repos that bring their own skills, agents and tools into plugins/. Use whenever the user asks to install, add, update, upgrade, remove, uninstall or list a plugin, e.g. "instala el plugin X", "actualiza los plugins", "qué plugins hay". Always use this skill, never `git clone` into plugins/ or its script directly.
allowed-tools: Bash(skills/plugin-manage/scripts/plugin-manage.sh add *), Bash(skills/plugin-manage/scripts/plugin-manage.sh update *), Bash(skills/plugin-manage/scripts/plugin-manage.sh remove *), Bash(skills/plugin-manage/scripts/plugin-manage.sh list), Bash(skills/plugin-manage/scripts/plugin-manage.sh check *)
---

# plugin-manage

> Use this skill; do not clone into `plugins/`, link plugin skills by hand or run the script on your own. The procedure below decides what to ask and when to stop.

A plugin is a git repo with an `arness-plugin.conf` at its root. Installing it clones it into `plugins/<name>`, links its skills into `skills/` and its agents into `agents/`, renders its Claude Code permission rules into `.claude/settings.json` and runs its `install` command, which runs the plugin's own code on this machine. See `plugins/README.md` for the format.

All the work is done by `scripts/plugin-manage.sh` (in this skill's folder), run from the repo root. It never prompts. `add`, `update` and `remove` only print a plan and write nothing. Only `apply add|update|remove` changes anything, and it is deliberately **not** pre-allowed: the agent's own permission prompt shows the command to the user before it runs.

## Procedure

1. Pick the command from the request and run the **plan**:
   - Install: `skills/plugin-manage/scripts/plugin-manage.sh add [--ref <tag|branch>] <url>`. Ask for the URL if missing. Suggest a tag for `--ref`: a plugin installed at a tag updates to the newest tag.
   - Update: `... update [--ref <tag|branch>] <name>`. For "update all", run `list` and plan each plugin in turn.
   - Remove: `... remove <name>`.
   - List: `... list`. Validate a plugin folder without installing it (a plugin's own CI): `... check <dir>`.
2. Read the first word of each stdout line:

| Output | Exit | What to do |
|---|---|---|
| Plan lines (`PLUGIN`, `SOURCE`, `DESCRIPTION`, `REQUIRES`, `PROVIDES`, `SKILL`, `AGENT`, `ALLOW`, `NEW_ALLOW`, `OPENCODE_AUTO_ALLOW`, `INSTALL`, `UNINSTALL`), then `CONFIRM_ADD <name> <commit>` / `CONFIRM_UPDATE <name> <from> <to> <ref>` / `CONFIRM_REMOVE <name>` | 20 | Nothing was written. Show the whole plan: source and commit, description, requirements, the commands the plugin installs (`PROVIDES`), skills, agents, every `ALLOW` rule word for word (`NEW_ALLOW` = rules the installed version did not have), the scripts OpenCode would run without asking (`OPENCODE_AUTO_ALLOW`), and the `INSTALL`/`UNINSTALL` commands, which run code from the plugin. With `OPENCODE_UNGATED`, also tell the user that their `opencode.json` lets OpenCode run `apply` without asking, and that the `"ask"` rule from `providers/opencode/opencode.json` should be added to it (`plugins/README.md`). Ask for confirmation. On an explicit yes, go to step 3. |
| `UP_TO_DATE <name> <commit> <ref>` | 0 | Report it. |
| `INSTALLED ...` lines / `NONE` | 0 | Show them as a table: name, version, commit, ref, state, skills and agents linked/declared. `BROKEN_LINK`: offer `./setup.sh --provider <p>` (it restores plugin links). `MODIFIED`: the clone was changed outside this skill (edits, a `git pull`); nothing from it is trusted until it is updated or removed. `INSTALL_FAILED`: offer update or remove. `UNMANAGED`: a folder this skill did not install; offer to remove it. |
| `VALID <name> <version>` | 0 | Report it. |
| `BAD_MANIFEST`, `INVALID`, `ARNESS_VERSION`, `BAD_RULE` | 4 | The plugin is invalid; nothing was written. Show the line. The fix belongs in the plugin repo. |
| `MISSING_REQUIREMENT <command>` | 5 | Tell the user to install `<command>`; never install it yourself. |
| `NAME_CONFLICT <path>` | 6 | A skill or agent with that name already exists. Show it; never delete or rename it to make room. |
| `ALREADY_INSTALLED <name>` | 10 | Offer `update <name>` instead. |
| `DIRTY <path> <why>` | 11 | The clone has local changes (`uncommitted-changes`) or was moved outside this skill (`moved`). Show it. For remove only, and only on an explicit answer, `apply remove --force` (the changes are lost). |
| `NOT_INSTALLED <name>` | 12 | Run `list` and show what is installed. |
| error on stderr | 2 | Invalid usage, URL, ref or name. Fix the input or ask the user. |
| error on stderr | 3 | Clone or fetch failed (network, auth, wrong URL). Show the git error. |

3. Run the confirmed change, with the full 40-character commit from the plan, so what runs is what was shown:
   - `... apply add --commit <commit> [--ref <same ref>] <url>`
   - `... apply update --commit <to> --ref <ref> <name>` (the `<ref>` of `CONFIRM_UPDATE`)
   - `... apply remove <name>`

| Output | Exit | What to do |
|---|---|---|
| `ADDED <name> <path>` / `UPDATED <name> <from> <to>` | 0 | Report it. Relay the `MANUAL opencode bash <rule>` and `MANUAL opencode skill <name>` lines: the user adds them to `opencode.json` if they use OpenCode. Tell the user to restart the agent session to load new skills and agents. |
| `REMOVED <name>` | 0 | Report it; restart the session to unload its skills. |
| `MISMATCH <expected> <actual>` | 14 | The source changed after the plan. Run the plan again and show it. |
| `INSTALL_FAILED <name>` | 13 | The install command failed (its output is on stderr); clone and links are kept. Show the error, then offer update after a fix, or remove. |
| any status of the table above | | As above. |

## Rules

- Never run `apply` without showing the plan and getting the user's explicit confirmation in this conversation, and always pass the `--commit` from that plan. `--force` only on an explicit answer too.
- `install` has no time limit. If it hangs, tell the user; do not retry it in a loop.
- Never edit `opencode.json`, `.claude/settings.json`, `plugins/.<name>.state` or files inside `plugins/` yourself, and never link plugin skills or agents by hand.
- Plugin skills and agents are local to this machine: never commit them, copy their content into committed files or mention them in commits and pull requests.
- `plugins/` is git-ignored, so installed plugins are never committed.
