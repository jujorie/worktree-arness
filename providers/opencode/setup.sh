#!/usr/bin/env bash
set -euo pipefail
: "${ARNESS_ROOT:=$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=SCRIPTDIR/../../scripts/lib.sh
. "$ARNESS_ROOT/scripts/lib.sh"

# OpenCode reads AGENTS.md natively and skills from .agents/skills.
link ../skills .agents/skills

# Always load the memory index into context. Create it if missing so the path resolves.
mkdir -p "$ARNESS_ROOT/.memory"
[ -e "$ARNESS_ROOT/.memory/MEMORY.md" ] || : > "$ARNESS_ROOT/.memory/MEMORY.md"
# copy_once: opencode.json is user-editable (models, providers); never overwritten.
copy_once providers/opencode/opencode.json opencode.json
# copy_once never updates an existing opencode.json, so say when it lacks an "ask" rule of the shipped
# one: each makes OpenCode ask before a script subcommand that writes (`plugin-manage.sh apply`,
# `repo-create.sh apply`), which its skills/*/scripts/*.sh rule would allow otherwise. The rules are read
# from the shipped file, so a new one is checked without touching this script.
{ grep -o '"[^"]*": "ask"' "$ARNESS_ROOT/providers/opencode/opencode.json" || true; } | while IFS= read -r rule; do
  grep -qF "$rule" "$ARNESS_ROOT/opencode.json" && continue
  cmd="$(printf '%s\n' "$rule" | sed 's/^"\(.*\)": "ask"$/\1/; s/ \*$//; s|.*/||')"
  warn "opencode.json lets OpenCode run $cmd without asking; add $rule to permission.bash, after the skills/*/scripts/*.sh rules"
done
# TODO: agents -> .opencode/agents (frontmatter differs from Claude, translate first)
