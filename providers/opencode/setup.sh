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
# copy_once never updates an existing opencode.json, so say when it lacks the rule that makes OpenCode
# ask before `plugin-manage.sh apply` (its skills/*/scripts/*.sh rule would allow it otherwise).
apply_rule='"skills/plugin-manage/scripts/plugin-manage.sh apply *": "ask"'
if ! grep -qF "$apply_rule" "$ARNESS_ROOT/opencode.json"; then
  warn "opencode.json lets OpenCode run plugin-manage.sh apply without asking; add $apply_rule to permission.bash, after the skills/*/scripts/*.sh rules"
fi
# TODO: agents -> .opencode/agents (frontmatter differs from Claude, translate first)
