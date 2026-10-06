---
name: learnings-save
description: Review the conversation for what was learned and save each item where it belongs (memory, CODESTYLE, a skill, a README), so nothing is lost when the context is cleared. Use when the user asks "algo que recordar antes del clear?", "guarda lo aprendido", "save what you learned" or "wrap up the session", or before /clear or /compact.
---

# learnings-save

Turns what was learned in this conversation into saved knowledge, using the table in `AGENTS.md`, section "What you learn". It complements saving as you go: it catches what slipped through.

## Procedure

1. Read `.memory/MEMORY.md` and open the memories that touch this conversation's topics.
2. List what this conversation taught that would cost effort to rediscover. Candidates:
   - Corrections the user made, and preferences they showed.
   - Decisions and their reason.
   - Facts about this machine or its tools (IPs, services, ports, MCP servers).
   - Traps that broke something, and how they were fixed.
   - How a skill really behaves.
   - Pending items left open.
   Drop what the code, the docs or git history already say, and what only mattered to this conversation.
3. Pick one destination for each item with the table in `AGENTS.md`:
   - **memory**: update the memory that already covers it, or create one (frontmatter and index line as in `AGENTS.md`, section "Memory"). Convert relative dates to absolute ones. Delete memories that turned out wrong, or that are now written in the repo.
   - **repo doc** (`CODESTYLE.md`, `CONTRIBUTING.md`, a shared skill, a folder `README.md`): draft the exact change. Do not commit or push: ask whether to open a branch and PR.
   - **private skill**: edit its `SKILL.md` directly. It is never committed.
4. Check links: every `[[name]]` in `.memory/` points to an existing memory, or is meant as a future one.
5. Report as a table: item, destination (file), and done / proposed. End with what is still pending.

## Rules

- Never store secrets or credentials, in memory or in docs.
- One fact, one place: never the same thing in memory and in a repo doc.
- Never commit, push or open a PR without the user's yes in this conversation.
- If nothing was learned, say so in one line; do not invent memories.
