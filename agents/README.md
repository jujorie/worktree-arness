# Agents Folder

Subagents shared through `.claude/agents`, one Markdown file each (`<name>.md` with frontmatter). Only Claude Code reads them: Codex has no equivalent, and OpenCode reads `.opencode/agents` with a different frontmatter (see `providers/opencode/README.md`).

## Shared agents

Committed to the repo, and listed one by one in the allowlist in `agents/.gitignore`, like shared skills in `skills/.gitignore`. There are none yet.

**Adding a shared agent:** create `agents/<name>.md` and add `!/<name>.md` to the allowlist in `agents/.gitignore` (no globs: a pattern would also publish a local agent that matches it).

## Local agents

`agents/` is **private by default**: `agents/.gitignore` ignores everything in it except `README.md` and the shared agents above. Any other file is a local agent of your machine and is never committed. Claude Code finds it with no setup, because `.claude/agents` points to this folder.

To add one, copy it or link it, then restart the agent session:

```bash
cp ~/my-agents/foo.md agents/foo.md
# or
ln -s ~/src/my-agents/foo.md agents/foo.md
```

- Do not give a local agent the name of a shared one.
- Do not mention local agents, or what is in them, in committed files.
- To see what is local: `git status --ignored agents/`.

## Plugin agents

Links named `<prefix>-<name>.md` that point into `plugins/` are agents of an installed plugin. They are local like the agents above, and managed with the `plugin-manage` skill: do not create or remove them by hand. See `plugins/README.md`.
