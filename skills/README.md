# Skills Folder

Each subfolder is a skill (`SKILL.md`, `scripts/`, `tests/`), shared by Claude Code, Codex and OpenCode. See `CODESTYLE.md` for how they are written.

## Shared skills

Committed to the repo, and listed one by one in the allowlist in `skills/.gitignore` (see below). Tests and CI check them: structure, permissions in `providers/`, shellcheck, bats.

**Adding a shared skill:** create `skills/<name>/` and add `!/<name>/` to the allowlist in `skills/.gitignore` (no globs: a pattern like `worktree-*` would also publish a private skill with that prefix). Add its permission entries in `providers/` too. If you forget the line in `skills/.gitignore`, the skill is not committed and CI fails because its permission rules point to a skill that is not there.

## Local skills

`skills/` is **private by default**: `skills/.gitignore` ignores everything in it except `README.md` and the shared skills above. So any other folder is a local skill of your machine, with any name, and it is never committed. All three providers find it with no setup, because `.claude/skills` and `.agents/skills` point to this folder.

To add one, copy it or link it (a link lets the skill live in its own private repo), then restart the agent session:

```bash
cp -R ~/my-skills/foo skills/foo
# or
ln -s ~/src/my-skills/foo skills/foo
```

- Keep the skill as published. The one naming rule is that `name` in its `SKILL.md` equals the folder name, in lowercase letters, digits and single hyphens: OpenCode requires it, while Claude Code would accept a different `name` (and then invoke the skill by it).
- Do not give a local skill the name of a shared one.
- Repo checks only see shared skills: a local skill needs no permission entries in `providers/`, and its scripts are not linted by the suite.
- To stop agents asking before running its script, declare `allowed-tools` in its `SKILL.md`, or add rules in your own settings, which `setup.sh` never touches:
  - Claude Code: `.claude/settings.local.json`, `permissions.allow`: `Skill(foo)` and `Bash(skills/foo/scripts/foo.sh *)`.
  - OpenCode: `opencode.json` at the repo root, `permission.skill`: `"foo": "allow"`. Its bash rule for `skills/*/scripts/*.sh` already covers the script.
- Do not mention local skills, or what is in them, in committed files.
- To see what is local: `git status --ignored skills/`.
