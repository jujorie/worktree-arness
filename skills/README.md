# Skills Folder

Each subfolder is a skill (`SKILL.md`, `scripts/`, `tests/`), shared by Claude Code, Codex and OpenCode. See `CODESTYLE.md` for how they are written.

## Shared skills

Committed to the repo. Their names carry no prefix (`repo-clone`, `worktree-create`...). Tests and CI check them: structure, permissions in `providers/`, shellcheck, bats.

## Local skills

Skills that are yours and do not belong in the repo: put them in `skills/local-<name>/`. The folder is git-ignored (`/skills/local-*/` in `.gitignore`), so it is never committed, and all three providers find it with no setup, because `.claude/skills` and `.agents/skills` point to this folder.

To add one, copy it or link it (a link lets the skill live in its own private repo), then restart the agent session:

```bash
cp -R ~/my-skills/foo skills/local-foo
# or
ln -s ~/src/my-skills/foo skills/local-foo
```

- The folder must start with `local-`, and `name` in its `SKILL.md` must be **exactly the folder name** (`name: local-foo`), in lowercase letters, digits and single hyphens. This is a requirement, not a style choice: OpenCode requires `name` to match the directory, while Claude Code would accept a different `name` (and then invoke the skill by it). Matching names work in all three providers.
- Repo checks skip `local-*` skills: they need no permission entries in `providers/`, and their scripts are not linted by the suite.
- To stop agents asking before running its script, declare `allowed-tools` in its `SKILL.md`, or add rules in your own settings, which `setup.sh` never touches:
  - Claude Code: `.claude/settings.local.json`, `permissions.allow`: `Skill(local-foo)` and `Bash(skills/local-foo/scripts/foo.sh *)`.
  - OpenCode: `opencode.json` at the repo root, `permission.skill`: `"local-foo": "allow"`. Its bash rule for `skills/*/scripts/*.sh` already covers the script.
- Do not mention local skills, or what is in them, in committed files.
