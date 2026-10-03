#!/usr/bin/env bash
# Clone a git repo into <arness>/source/<name>.
#
# Usage: repo-clone.sh [--name NAME] [--depth N] [--overwrite [--force]] <url>
#
# Stdout (machine readable), first word is the status:
#   CLONED <path>          done
#   EXISTS <path>          destination exists; nothing changed (exit 10)
#   DIRTY <path> <why>     overwrite refused: uncommitted/unpushed work or not a git repo (exit 11)
# Exit codes: 0 ok, 2 invalid usage/input, 3 clone failed, 10 exists, 11 unsafe overwrite.
set -euo pipefail

TMP_CLONE=""   # global: the EXIT trap runs after main() returns
cleanup() { if [ -n "$TMP_CLONE" ]; then rm -rf "$TMP_CLONE"; fi; }

EXIT_USAGE=2 EXIT_CLONE=3 EXIT_EXISTS=10 EXIT_UNSAFE=11

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

resolve_root() {
  if [ -n "${ARNESS_ROOT:-}" ]; then
    printf '%s\n' "$ARNESS_ROOT"
  else
    # <root>/skills/repo-clone/scripts -> <root>. -P follows symlinks (.claude/skills, .agents/skills).
    (cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
  fi
}

# Print a clean URL or return 1. Allowlist of schemes; no option-like or whitespace input.
validate_url() {
  local url="$1"
  [ -n "$url" ] || return 1
  case "$url" in
    -*|*[[:space:]]*|*[[:cntrl:]]*|*://-*|*@-*) return 1 ;;
    https://?*|http://?*|ssh://?*|file://?*|git@?*:?*) return 0 ;;
    *) return 1 ;;
  esac
}

# owner/repo.git, git@host:owner/repo, ssh://host:22/repo/ ... -> repo
derive_name() {
  local u="$1" name
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  u="${u%.git}"
  name="${u##*/}"
  name="${name##*:}"
  printf '%s\n' "$name"
}

# Safe single path component only; keeps the destination inside source/.
validate_name() {
  case "$1" in
    ""|.|..|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

is_positive_int() {
  case "$1" in
    ""|*[!0-9]*|0*) return 1 ;;
  esac
}

# Echo the reason when dest must not be deleted without --force; empty when safe.
unsafe_reason() {
  local dest="$1"
  # Require dest to be its own repo, otherwise git would report the enclosing repo.
  if [ ! -e "$dest/.git" ]; then echo "not-a-git-repo"; return; fi
  if [ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]; then echo "uncommitted-changes"; return; fi
  if [ -n "$(git -C "$dest" log --branches --not --remotes --oneline 2>/dev/null)" ]; then
    echo "unpushed-commits"
  fi
}

main() {
  local url="" name="" depth="" name_set=0 depth_set=0 overwrite=0 force=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --name)      [ $# -ge 2 ] || die "--name needs a value"; name="$2"; name_set=1; shift 2 ;;
      --depth)     [ $# -ge 2 ] || die "--depth needs a value"; depth="$2"; depth_set=1; shift 2 ;;
      --overwrite) overwrite=1; shift ;;
      --force)     force=1; shift ;;
      -h|--help)   sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
      -*)          die "unknown option: $1" ;;
      *)           [ -z "$url" ] || die "only one URL allowed"; url="$1"; shift ;;
    esac
  done

  [ -n "$url" ] || die "missing repository URL"
  validate_url "$url" || die "invalid URL (allowed: https://, http://, ssh://, git@host:path, file://): $url"
  if [ "$depth_set" -eq 1 ]; then is_positive_int "$depth" || die "--depth must be a positive integer"; fi
  command -v git >/dev/null 2>&1 || die "git not found"

  if [ "$name_set" -eq 0 ]; then name="$(derive_name "$url")"; fi
  validate_name "$name" || die "invalid destination name: '$name' (use letters, digits, . _ -; pass --name)"

  local root source_dir dest
  root="$(resolve_root)"
  source_dir="$root/source"
  dest="$source_dir/$name"
  mkdir -p "$source_dir"

  if [ -L "$dest" ]; then die "$dest is a symlink, refusing to touch it"; fi
  if [ -e "$dest" ]; then
    [ -d "$dest" ] || die "$dest exists and is not a directory"
    if [ "$overwrite" -eq 0 ]; then
      echo "EXISTS $dest"
      exit "$EXIT_EXISTS"
    fi
    local why
    why="$(unsafe_reason "$dest")"
    if [ -n "$why" ] && [ "$force" -eq 0 ]; then
      echo "DIRTY $dest $why"
      exit "$EXIT_UNSAFE"
    fi
  fi

  # Clone into a temp dir first: a failure leaves no partial dir and keeps the old copy.
  TMP_CLONE="$(mktemp -d "$source_dir/.repo-clone.XXXXXX")"
  trap cleanup EXIT
  export GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL="https:http:ssh:file"

  local ok=0
  if [ -n "$depth" ]; then
    git clone --quiet --depth "$depth" -- "$url" "$TMP_CLONE/repo" >&2 || ok=1
  else
    git clone --quiet -- "$url" "$TMP_CLONE/repo" >&2 || ok=1
  fi
  if [ "$ok" -ne 0 ]; then
    echo "error: git clone failed for $url" >&2
    exit "$EXIT_CLONE"
  fi

  if [ -e "$dest" ]; then rm -rf "$dest"; fi
  mv "$TMP_CLONE/repo" "$dest"
  echo "CLONED $dest"
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
