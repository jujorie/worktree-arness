#!/usr/bin/env bash
# List and remove what skills left in <arness>/tmp/ that nothing needs any more.
#
# Usage: tmp-clean.sh list   [--days N]
#        tmp-clean.sh remove [--days N] PATH...
#        tmp-clean.sh purge  KEY...
#
# Skills keep their files in tmp/<skill>/<key>, where <key> is one of:
#   <repo>/<name>   a worktree (worktrees/<repo>/<name>, <repo> a repo in source/)
#   anything else   a ticket (PROJ-123), a pull request (PR-12, 12) or other, as a folder or as files
#                   <key>.<ext>
# list stdout: one line per entry nothing needs, or NONE (exit 0):
#   ORPHAN <path> <kb>   under tmp/<skill>/<repo>/: its worktree no longer exists
#   STALE <path> <kb>    any other entry with nothing modified in the last N days (--days, default 30)
#   <path> is relative to the repo root (tmp/...). An entry holding a *.pid of a live process is never
#   listed (a note goes to stderr).
# remove stdout, per PATH (exit 13 if any SKIPPED); only paths that list reports now are removed:
#   REMOVED <path>
#   SKIPPED <path> not-listed
# purge stdout: removes tmp/<skill>/<key> and tmp/<skill>/<key>.* of every skill, whatever their age
# (a ticket or pull request just closed). NONE if there was nothing (exit 13 if any SKIPPED):
#   PURGED <path>
#   SKIPPED <path|key> <reason>   reason: invalid-key | running
# remove and purge also drop the folders left empty, up to tmp/<skill> (kept).
# Exit codes: 0 ok, 2 invalid usage/input, 13 some path skipped.
set -euo pipefail

EXIT_USAGE=2 EXIT_SKIPPED=13

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

resolve_root() {
  if [ -n "${ARNESS_ROOT:-}" ]; then
    printf '%s\n' "$ARNESS_ROOT"
  else
    # <root>/skills/tmp-clean/scripts -> <root>. -P follows symlinks (.claude/skills, .agents/skills).
    (cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
  fi
}

# True if <path> holds a *.pid file whose process is still alive. Args: path
runs() {
  local f pid
  while IFS= read -r f; do
    pid="$(awk 'NR == 1' "$f" | tr -cd '0-9')"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  done < <(find "$1" -type f -name '*.pid' 2>/dev/null)
  return 1
}

# Print "<status> <rel path> <kb>" for <path>, unless it still runs. Args: status path
row() {
  local rel="${2#"$ROOT/"}"
  if runs "$2"; then echo "note: $rel still runs, skipped" >&2; return 0; fi
  printf '%s %s %s\n' "$1" "$rel" "$(du -sk "$2" | awk '{ print $1 }')"
}

# Entries under tmp/<skill>/<repo>/ whose worktree is gone. A path is live while worktrees/<repo>/<rel> is a
# worktree; a plain folder there (feat/) is walked into. Args: dir repo rel
walk_repo() {
  local dir="$1" repo="$2" rel="$3" c r wt
  for c in "$dir"/*; do
    if [ ! -e "$c" ] && [ ! -L "$c" ]; then continue; fi
    r="${rel:+$rel/}$(basename "$c")"
    wt="$ROOT/worktrees/$repo/$r"
    if [ -e "$wt/.git" ]; then
      continue
    elif [ -d "$wt" ] && [ -d "$c" ] && [ ! -L "$c" ]; then
      walk_repo "$c" "$repo" "$r"
    else
      row ORPHAN "$c"
    fi
  done
}

# True if nothing in <path> was modified in the last DAYS days. Args: path
stale() {
  [ -z "$(find "$1" -mtime "-$DAYS" -print 2>/dev/null | awk 'NR == 1')" ]
}

list_rows() {
  local skill e
  for skill in "$ROOT"/tmp/*; do
    if [ ! -d "$skill" ] || [ -L "$skill" ]; then
      if [ -e "$skill" ] && stale "$skill"; then row STALE "$skill"; fi
      continue
    fi
    for e in "$skill"/*; do
      if [ ! -e "$e" ] && [ ! -L "$e" ]; then continue; fi
      if [ -d "$e" ] && [ ! -L "$e" ] && [ -e "$ROOT/source/$(basename "$e")/.git" ]; then
        walk_repo "$e" "$(basename "$e")" ""
      elif stale "$e"; then
        row STALE "$e"
      fi
    done
  done
}

# Remove <path> (absolute, under tmp/) and the folders left empty up to tmp/<skill>. Args: path
drop() {
  local p="$1" top d
  top="$ROOT/tmp/$(printf '%s' "${p#"$ROOT/tmp/"}" | cut -d/ -f1)"
  rm -rf "$p"
  d="$(dirname "$p")"
  while [ "$d" != "$top" ] && [ "$d" != "$ROOT/tmp" ] && rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
}

cmd_list() {
  local rows
  rows="$(list_rows)"
  if [ -z "$rows" ]; then echo "NONE"; else printf '%s\n' "$rows"; fi
}

cmd_remove() {
  local rows p skipped=0
  [ "${#ARGS[@]}" -gt 0 ] || die "remove needs at least one PATH"
  rows="$(list_rows)"
  for p in "${ARGS[@]}"; do
    p="${p%/}"
    if printf '%s\n' "$rows" | awk -v p="$p" '$2 == p { found = 1 } END { exit !found }'; then
      drop "$ROOT/$p"
      echo "REMOVED $p"
    else
      echo "SKIPPED $p not-listed"; skipped=1
    fi
  done
  if [ "$skipped" -eq 1 ]; then exit "$EXIT_SKIPPED"; fi
}

cmd_purge() {
  local key p any=0 skipped=0
  [ "${#ARGS[@]}" -gt 0 ] || die "purge needs at least one KEY"
  for key in "${ARGS[@]}"; do
    case "$key" in
      ""|.*|-*|*[!A-Za-z0-9._-]*) echo "SKIPPED $key invalid-key"; skipped=1; continue ;;
    esac
    for p in "$ROOT"/tmp/*/"$key" "$ROOT"/tmp/*/"$key".*; do
      if [ ! -e "$p" ] && [ ! -L "$p" ]; then continue; fi
      any=1
      if runs "$p"; then echo "SKIPPED ${p#"$ROOT/"} running"; skipped=1; continue; fi
      drop "$p"
      echo "PURGED ${p#"$ROOT/"}"
    done
  done
  if [ "$any" -eq 0 ] && [ "$skipped" -eq 0 ]; then echo "NONE"; fi
  if [ "$skipped" -eq 1 ]; then exit "$EXIT_SKIPPED"; fi
}

main() {
  [ $# -ge 1 ] || die "missing command (list | remove | purge)"
  local cmd="$1"
  DAYS=30 ARGS=()
  shift
  case "$cmd" in
    list|remove|purge) ;;
    -h|--help) awk 'NR > 1 && /^set -euo/ { exit } NR > 1' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown command: $cmd" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) [ $# -ge 2 ] || die "--days needs a value"; DAYS="$2"; shift 2 ;;
      -*)     die "unknown option: $1" ;;
      *)      ARGS+=("$1"); shift ;;
    esac
  done
  case "$DAYS" in ""|0|*[!0-9]*) die "invalid --days: '$DAYS' (a whole number of days, 1 or more)" ;; esac
  if [ "$cmd" = "list" ] && [ "${#ARGS[@]}" -gt 0 ]; then die "list takes no PATH"; fi
  if [ "$cmd" = "purge" ] && [ "$DAYS" != 30 ]; then die "purge takes no --days"; fi

  ROOT="$(cd -P "$(resolve_root)" && pwd -P)"
  case "$cmd" in
    list)   cmd_list ;;
    remove) cmd_remove ;;
    purge)  cmd_purge ;;
  esac
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
