#!/usr/bin/env bash
set -euo pipefail
: "${ARNESS_ROOT:=$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=../../scripts/lib.sh
. "$ARNESS_ROOT/scripts/lib.sh"

# OpenCode reads AGENTS.md natively and skills from .agents/skills.
link ../skills .agents/skills

# Always load the memory index into context. Create it if missing so the path resolves.
mkdir -p "$ARNESS_ROOT/.memory"
[ -e "$ARNESS_ROOT/.memory/MEMORY.md" ] || : > "$ARNESS_ROOT/.memory/MEMORY.md"
# copy_once: opencode.json is user-editable (models, providers); never overwritten.
copy_once providers/opencode/opencode.json opencode.json
# TODO: agents -> .opencode/agents (frontmatter differs from Claude, translate first)
