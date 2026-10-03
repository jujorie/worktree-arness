#!/usr/bin/env bash
# Usage: ./setup.sh --provider <name>[,<name>...]   (required)
set -euo pipefail

ARNESS_ROOT="$(cd "$(dirname "$0")" && pwd)"
export ARNESS_ROOT
PROVIDERS_ALL="claude codex opencode"
choice=""

usage() {
  cat <<EOT
Usage: ./setup.sh --provider <name>[,<name>...]

Providers:
  claude     Claude Code
  codex      Codex CLI
  opencode   OpenCode
  all        every provider above
  auto       only providers whose CLI is installed

Examples:
  ./setup.sh --provider claude
  ./setup.sh --provider claude,codex
EOT
}

while [ $# -gt 0 ]; do
  case "$1" in
    --provider|-p) choice="${2:?--provider needs a value}"; shift 2 ;;
    --provider=*)  choice="${1#*=}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$choice" ]; then
  echo "error: --provider is required" >&2
  usage >&2
  exit 2
fi

selected=""
add() { case " $selected " in *" $1 "*) ;; *) selected="$selected $1" ;; esac; }
for p in ${choice//,/ }; do
  case "$p" in
    all)  for c in $PROVIDERS_ALL; do add "$c"; done ;;
    auto) for c in $PROVIDERS_ALL; do
            if command -v "$c" >/dev/null 2>&1; then add "$c"; fi
          done ;;
    claude|codex|opencode) add "$p" ;;
    *) echo "unknown provider: $p" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "${selected// /}" ]; then
  echo "error: no installed provider CLI detected (auto)" >&2
  usage >&2
  exit 1
fi

for p in $selected; do
  echo "==> $p"
  bash "$ARNESS_ROOT/providers/$p/setup.sh"
done
