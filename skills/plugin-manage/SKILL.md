---
name: plugin-manage
description: Add, update, remove, list or check arness plugins, git repos that bring their own skills, agents and tools into plugins/. Use whenever the user asks to install, add, update, upgrade, remove, uninstall or list a plugin, e.g. "instala el plugin X", "actualiza los plugins", "qué plugins hay". Always use this skill, never `git clone` into plugins/ or its script directly.
allowed-tools: Bash(skills/plugin-manage/scripts/plugin-manage.sh *)
---

# plugin-manage

> Use this skill; do not clone into `plugins/`, link plugin skills by hand or run the script on your own. The procedure below decides what to ask and when to stop.

A plugin is a git repo with an `arness-plugin.conf` at its root. Installing it clones it into `plugins/<name>`, links its skills into `skills/` and its agents into `agents/`, renders its Claude Code permission rules into `.claude/settings.json` and runs its `install` command. See `plugins/README.md` for the format.

All the work is done by `scripts/plugin-manage.sh` (in this skill's folder), run from the repo root. It never prompts: add, update and remove first answer with a plan and a `CONFIRM_*` line, and write nothing until they are run again with `--yes`.

## Procedure

1. Pick the command from the request:
   - Install: `skills/plugin-manage/scripts/plugin-manage.sh add [--ref <tag|branch>] <url>`. Ask for the URL if missing. Suggest a tag for `--ref` when the user has one.
   - Update: `... update [--ref <tag|branch>] <name>`. For "update all", run `list` and update each plugin in turn.
   - Remove: `... remove <name>`.
   - List: `... list`.
   - Validate a plugin folder without installing (a plugin's own CI): `... check <dir>`.
2. Read the first word of each stdout line:

| Output | Exit | What to do |
|---|---|---|
| `PLUGIN`, `SKILL`, `AGENT`, `ALLOW`, `NEW_ALLOW`, `INSTALL`, `UNINSTALL` lines, then `CONFIRM_ADD <name> <commit>` / `CONFIRM_UPDATE <name> <from> <to>` / `CONFIRM_REMOVE <name>` | 20 | Nothing was written. Show the user the plan: URL and commit, skills, agents, every `ALLOW` rule word for word (`NEW_ALLOW` = rules the installed version did not ask for), and the `INSTALL`/`UNINSTALL` command, which runs code from the plugin on this machine. Ask for confirmation. Only on an explicit yes, rerun the same command with `--yes`, plus `--commit <commit>` (add) or `--commit <to>` (update), so what runs is what was shown. |
| `ADDED <name> <path>` / `UPDATED <name> <from> <to>` | 0 | Report it. Relay any `MANUAL opencode <rule>` lines: the user adds them to `opencode.json` if they use OpenCode. Tell the user to restart the agent session to load new skills and agents. |
| `UP_TO_DATE <name> <commit>` | 0 | Report it. |
| `REMOVED <name>` | 0 | Report it; restart the session to unload its skills. |
| `INSTALLED ...` lines / `NONE` | 0 | Show them as a table: name, version, commit, state, skills and agents linked/declared. For `BROKEN_LINK`, offer `./setup.sh --provider <p>` (it restores plugin links); for `INSTALL_FAILED`, offer to run `update` or `remove`. |
| `VALID <name> <version>` | 0 | Report it. |
| `BAD_MANIFEST`, `INVALID`, `ARNESS_VERSION`, `BROAD_PERMISSION` | 4 | The plugin is invalid; nothing was written. Show the line. The fix belongs in the plugin repo. |
| `MISSING_REQUIREMENT <command>` | 5 | Tell the user to install `<command>`; never install it yourself. |
| `NAME_CONFLICT <path>` | 6 | A skill or agent with that name already exists. Show it; never delete or rename it to make room. |
| `ALREADY_INSTALLED <name>` | 10 | Offer `update <name>` instead. |
| `DIRTY <path> <why>` | 11 | The clone has local changes or commits. Show them. For `remove`, only on an explicit answer, rerun with `--force` (the changes are lost). |
| `NOT_INSTALLED <name>` | 12 | Run `list` and show what is installed. |
| `INSTALL_FAILED <name>` | 13 | The install command failed (its output is on stderr); clone and links are kept. Show the error, then offer `update` after a fix, or `remove`. |
| `MISMATCH <expected> <actual>` | 14 | The ref moved between the plan and the confirmation. Run the command again without `--yes` and show the new plan. |
| error on stderr | 2 | Invalid usage, URL, ref or name. Fix the input or ask the user. |
| error on stderr | 3 | Clone or fetch failed (network, auth, wrong URL). Show the git error. |

## Rules

- Never pass `--yes` without showing the plan and getting the user's explicit confirmation in this conversation, and always pass back the `--commit` from that plan. `--force` only on an explicit answer too.
- Never edit `opencode.json`, `.claude/settings.json` or files inside `plugins/` yourself, and never link plugin skills or agents by hand.
- Plugin skills and agents are local to this machine: never commit them, copy their content into committed files or mention them in commits and pull requests.
- `plugins/` is git-ignored, so installed plugins are never committed.
