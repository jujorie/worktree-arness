#!/usr/bin/env bash
set -euo pipefail
: "${ARNESS_ROOT:=$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=SCRIPTDIR/../../scripts/lib.sh
. "$ARNESS_ROOT/scripts/lib.sh"

# Codex reads AGENTS.md natively and skills from .agents/skills.
link ../skills .agents/skills
# TODO: subagents + ~/.codex/config.toml (verify paths in Codex docs).
