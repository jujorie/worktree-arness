#!/usr/bin/env bash
set -euo pipefail
: "${ARNESS_ROOT:=$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=../../scripts/lib.sh
. "$ARNESS_ROOT/scripts/lib.sh"

link ../skills .claude/skills
link ../agents .claude/agents
copy_once providers/claude/CLAUDE.md CLAUDE.md
render providers/claude/settings.json .claude/settings.json
