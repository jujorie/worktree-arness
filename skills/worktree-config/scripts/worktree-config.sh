#!/usr/bin/env bash
# Copy <arness>/config/<repo>/** into an existing worktree, then run config/<repo>/install.sh in it.
#
# Usage: worktree-config.sh [--worktree] <repo>/<name>
#
# Files keep their relative path: config/<repo>/src/a.js -> worktrees/<repo>/<name>/src/a.js.
# Existing files are overwritten; the file mode is kept.
# config/<repo>/install.sh (top level only) is never copied: it runs with `bash`, cwd = the worktree.
# Its output (stdout+stderr) goes to <arness>/tmp/worktree-config/<repo>/<name>-install.log, never to the
# console, so a build cannot flood the caller. On failure only the last 20 lines are shown (on stderr).
#
# Stdout, first word is the status:
#   COPIED <rel>             file copied
#   SKIPPED <rel> <reason>   reason: symlink | reserved-path | conflict
#   DONE <path> files=<n> install=<yes|no>
#   NO_WORKTREE              slug missing or without <name> (exit 5)
#   NOT_FOUND <path>         no such worktree of a repo in source/ (exit 4)
#   NO_CONFIG <repo>         nothing in config/<repo>/; nothing done (exit 0)
#   INSTALL_FAILED <code> <log>   install.sh failed; files were already copied (exit 7)
# Exit codes: 0 ok, 2 invalid usage/input, 4 not found, 5 no worktree, 7 install failed, 13 some file skipped.
set -euo pipefail

EXIT_USAGE=2 EXIT_NOT_FOUND=4 EXIT_NO_WORKTREE=5 EXIT_INSTALL=7 EXIT_SKIPPED=13

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

resolve_root() {
  if [ -n "${ARNESS_ROOT:-}" ]; then
    printf '%s\n' "$ARNESS_ROOT"
  else
    # <root>/skills/worktree-config/scripts -> <root>. -P follows symlinks (.claude/skills, .agents/skills).
    (cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
  fi
}

# Valid file name, or several joined by "/" (feat/PROJ-123). Same rule as worktree-create.
validate_name() {
  local rest="$1" part
  [ -n "$rest" ] || return 1
  while :; do
    part="${rest%%/*}"
    case "$part" in
      ""|.|..|-*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    [ "$part" = "$rest" ] && return 0
    rest="${rest#*/}"
  done
}

# Return 1 if writing <rel> inside the worktree is unsafe: reserved .git, or a symlink on the way.
# Parts that do not exist yet will be created as real directories, so the walk stops at the first one.
check_dest() {
  local rel="$1" cur="$WT" rest="$1" part
  while :; do
    part="${rest%%/*}"
    if [ "$part" = ".git" ]; then DEST_WHY="reserved-path"; return 1; fi
    cur="$cur/$part"
    if [ -L "$cur" ]; then DEST_WHY="symlink"; return 1; fi
    [ -e "$cur" ] || return 0
    case "$rest" in */*) rest="${rest#*/}" ;; *) return 0 ;; esac
  done
}

main() {
  local slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) [ $# -ge 2 ] || die "--worktree needs a value"; slug="$2"; shift 2 ;;
      -h|--help)  sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
      -*)         die "unknown option: $1" ;;
      *)          [ -z "$slug" ] || die "only one worktree allowed"; slug="$1"; shift ;;
    esac
  done

  # The worktree is required, as <repo>/<name>. Without it we stop.
  case "$slug" in
    ""|*/) echo "NO_WORKTREE"; exit "$EXIT_NO_WORKTREE" ;;
    /*)    die "invalid worktree: '$slug' (expected <repo>/<name>)" ;;
    */*)   ;;
    *)     echo "NO_WORKTREE"; exit "$EXIT_NO_WORKTREE" ;;
  esac
  local repo="${slug%%/*}" name="${slug#*/}"
  validate_name "$repo" || die "invalid repo in worktree: '$repo'"
  validate_name "$name" || die "invalid worktree name: '$name' (use letters, digits, . _ - and / between parts)"
  command -v git >/dev/null 2>&1 || die "git not found"

  local root
  root="$(resolve_root)"
  root="$(cd -P "$root" && pwd -P)"   # git reports physical paths
  WT="$root/worktrees/$repo/$name"

  # It must be a real worktree of source/<repo>, not just a folder.
  if [ -L "$WT" ] || [ ! -e "$root/source/$repo/.git" ] ||
     ! git -C "$root/source/$repo" worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $WT"; then
    echo "NOT_FOUND $WT"
    exit "$EXIT_NOT_FOUND"
  fi

  local cfg="$root/config/$repo"
  if [ ! -d "$cfg" ] || [ -L "$cfg" ]; then echo "NO_CONFIG $repo"; exit 0; fi

  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(find "$cfg" \( -type f -o -type l \) | LC_ALL=C sort)

  # 1. Copy.
  local rel dest copied=0 skipped=0
  for f in ${files[@]+"${files[@]}"}; do
    rel="${f#"$cfg/"}"
    [ "$rel" != "install.sh" ] || continue
    if [ -L "$f" ]; then echo "SKIPPED $rel symlink"; skipped=1; continue; fi
    if ! check_dest "$rel"; then echo "SKIPPED $rel $DEST_WHY"; skipped=1; continue; fi
    dest="$WT/$rel"
    if [ -d "$dest" ] || ! mkdir -p "$(dirname "$dest")" 2>/dev/null; then
      echo "SKIPPED $rel conflict"; skipped=1; continue
    fi
    cp -p "$f" "$dest"          # keeps the file mode
    echo "COPIED $rel"
    copied=$((copied + 1))
  done

  # 2. install.sh runs IN the worktree. Never copied.
  local installed=no rc=0 log
  if [ -f "$cfg/install.sh" ] && [ ! -L "$cfg/install.sh" ]; then
    log="$root/tmp/worktree-config/$repo/$name-install.log"
    mkdir -p "$(dirname "$log")"
    (cd "$WT" && bash "$cfg/install.sh") > "$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "INSTALL_FAILED $rc $log"
      { echo "--- last 20 lines of the install log ---"; tail -n 20 "$log"; } >&2
      exit "$EXIT_INSTALL"
    fi
    installed=yes
  fi

  echo "DONE $WT files=$copied install=$installed"
  if [ "$skipped" -eq 1 ]; then exit "$EXIT_SKIPPED"; fi
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
