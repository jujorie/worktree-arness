#!/usr/bin/env bash
# Run shellcheck + bats. Requires: bats-core, shellcheck (see README).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for tool in bats shellcheck; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool (see README, 'Tests')" >&2; exit 1; }
done

exec bats -r "$ROOT/tests" "$ROOT/skills"
