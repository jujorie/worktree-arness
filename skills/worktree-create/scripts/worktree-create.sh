#!/usr/bin/env bash
# Create a git worktree from a repo cloned in <arness>/source/ into <arness>/worktrees/<repo>/<name>.
#
# Usage: worktree-create.sh [--source REPO] [--name NAME] [--branch REF] [--no-confirm] [--no-config] [--no-fetch]
#
# Stdout (machine readable), first word is the status:
#   CREATED <path> <base>        done; new branch NAME created from <base> (NAME may contain /, e.g. feat/X-1)
#   CHOOSE_SOURCE <repo>...      several repos and no --source; ask the user (exit 10)
#   CONFIRM_BRANCH <branch> [behind=<n>]
#                                current branch of the source; confirm it, rerun with --branch (exit 11).
#                                behind=<n>: commits origin/<branch> has that the local branch lacks (after a
#                                fetch of that branch); absent if unknown (no origin, local-only branch, offline)
#   EXISTS <path>                destination exists; nothing changed (exit 12)
#   NO_SOURCE                    no repo in source/ or --source is not one of them (exit 4)
#   NO_NAME                      --name missing or empty (exit 5)
# After CREATED, if config/<repo>/ exists, the worktree-config script runs on the new worktree (skip with
# --no-config). Its output follows as lines prefixed with "CONFIG " (COPIED/SKIPPED/DONE/INSTALL_FAILED...).
# If it fails, "CONFIG_FAILED <code>" is printed and the exit code is 14; the worktree stays created.
# Exit codes: 0 ok, 2 invalid usage/input, 3 git failed, 4 no source, 5 no name, 10-12 see above, 14 config failed.
set -euo pipefail

EXIT_USAGE=2 EXIT_GIT=3 EXIT_NO_SOURCE=4 EXIT_NO_NAME=5 EXIT_CHOOSE=10 EXIT_CONFIRM=11 EXIT_EXISTS=12 EXIT_CONFIG=14
NO_FETCH=0   # set by --no-fetch; read by resolve_base

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

resolve_root() {
  if [ -n "${ARNESS_ROOT:-}" ]; then
    printf '%s\n' "$ARNESS_ROOT"
  else
    # <root>/skills/worktree-create/scripts -> <root>. -P follows symlinks (.claude/skills, .agents/skills).
    (cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
  fi
}

# Valid file name, or several joined by "/" (feat/PROJ-123). Each part must be a safe
# path component, so the destination stays inside worktrees/<repo>/.
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

# Print the ref to branch from, or return 1. Order: local branch/ref, origin/<branch> already fetched,
# then fetch just that branch from origin (the user asked for it explicitly, e.g. epic/X that only exists remotely).
resolve_base() {
  local repo="$1" b="$2" rb
  case "$b" in
    origin/?*)  # asked for the remote side explicitly: refresh it so the worktree starts from the real tip
      rb="${b#origin/}"
      if [ "$NO_FETCH" -eq 0 ] && git check-ref-format "refs/heads/$rb" 2>/dev/null; then
        GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --quiet origin "+refs/heads/$rb:refs/remotes/origin/$rb" >&2 \
          || echo "warning: could not refresh $b; using the local copy" >&2
      fi ;;
  esac
  if git -C "$repo" rev-parse --verify --quiet "$b^{commit}" >/dev/null; then printf '%s\n' "$b"; return 0; fi
  git -C "$repo" remote | grep -Fxq origin || return 1
  git check-ref-format "refs/heads/$b" 2>/dev/null || return 1
  if ! git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$b^{commit}" >/dev/null; then
    GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --quiet origin "+refs/heads/$b:refs/remotes/origin/$b" >&2 || return 1
  fi
  printf 'origin/%s\n' "$b"
}

# Print how many commits origin/<branch> has that the local <branch> lacks, or nothing if unknown.
# Fetches just that branch first. A branch that does not exist in origin is silent; a failure warns on stderr.
behind_count() {
  local repo="$1" b="$2" rc=0
  [ "$b" != "HEAD" ] || return 0
  git -C "$repo" remote | grep -Fxq origin || return 0
  git check-ref-format "refs/heads/$b" 2>/dev/null || return 0
  GIT_TERMINAL_PROMPT=0 git -C "$repo" ls-remote --exit-code --heads origin "refs/heads/$b" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then return 0; fi
  if [ "$rc" -ne 0 ] || ! GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --quiet origin "+refs/heads/$b:refs/remotes/origin/$b" >&2; then
    echo "warning: could not refresh origin/$b; cannot tell if $b is behind" >&2
    return 0
  fi
  git -C "$repo" rev-list --count "$b..origin/$b" 2>/dev/null || true
}

main() {
  local source="" name="" branch="" no_confirm=0 no_config=0 no_fetch=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --source)     [ $# -ge 2 ] || die "--source needs a value"; source="$2"; shift 2 ;;
      --name)       [ $# -ge 2 ] || die "--name needs a value"; name="$2"; shift 2 ;;
      --branch)     [ $# -ge 2 ] || die "--branch needs a value"; branch="$2"; shift 2 ;;
      --no-confirm) no_confirm=1; shift ;;
      --no-config)  no_config=1; shift ;;
      --no-fetch)   no_fetch=1; NO_FETCH=1; shift ;;
      -h|--help)    sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
      *)            die "unknown argument: $1" ;;
    esac
  done
  command -v git >/dev/null 2>&1 || die "git not found"

  local root source_dir
  root="$(resolve_root)"
  source_dir="$root/source"

  # 1. Source repo. A repo is a direct child of source/ that has its own .git.
  local repos=() d
  for d in "$source_dir"/*/; do
    [ -e "${d}.git" ] && [ ! -L "${d%/}" ] && repos+=("$(basename "$d")")
  done
  if [ "${#repos[@]}" -eq 0 ]; then echo "NO_SOURCE"; exit "$EXIT_NO_SOURCE"; fi

  if [ -z "$source" ]; then
    if [ "${#repos[@]}" -gt 1 ]; then
      echo "CHOOSE_SOURCE ${repos[*]}"
      exit "$EXIT_CHOOSE"
    fi
    source="${repos[0]}"
  else
    local found=0 r
    for r in "${repos[@]}"; do [ "$r" = "$source" ] && found=1; done
    if [ "$found" -eq 0 ]; then echo "NO_SOURCE"; exit "$EXIT_NO_SOURCE"; fi
  fi
  local repo="$source_dir/$source"

  # 2. Worktree name.
  if [ -z "$name" ]; then echo "NO_NAME"; exit "$EXIT_NO_NAME"; fi
  validate_name "$name" || die "invalid name: '$name' (use letters, digits, . _ - and / between parts)"
  git check-ref-format --branch "$name" >/dev/null 2>&1 || die "invalid branch name: '$name'"

  # 3. Base branch: confirm the source's current branch unless told not to.
  if [ -z "$branch" ]; then
    local current
    current="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)" || { echo "error: cannot read branch of $repo" >&2; exit "$EXIT_GIT"; }
    if [ "$no_confirm" -eq 0 ]; then
      local behind=""
      if [ "$no_fetch" -eq 0 ]; then behind="$(behind_count "$repo" "$current")"; fi
      echo "CONFIRM_BRANCH $current${behind:+ behind=$behind}"
      exit "$EXIT_CONFIRM"
    fi
    branch="$current"
  fi
  case "$branch" in -*|*[[:space:]]*) die "invalid branch: '$branch'" ;; esac
  branch="$(resolve_base "$repo" "$branch")" || die "branch not found in $source, locally or in origin: $branch"

  # 4. Create.
  local dest="$root/worktrees/$source/$name"
  if [ -e "$dest" ] || [ -L "$dest" ]; then echo "EXISTS $dest"; exit "$EXIT_EXISTS"; fi
  # Hard guarantee: nothing between worktrees/ and the destination may be a symlink.
  # Checked before mkdir so a refused run creates nothing.
  local walk="$root/worktrees/$source" rest="$name" part
  while :; do
    [ ! -L "$walk" ] || die "refusing symlink in destination: $walk"
    [ -e "$walk" ] || break
    case "$rest" in */*) ;; *) break ;; esac
    part="${rest%%/*}"; rest="${rest#*/}"
    walk="$walk/$part"
  done
  mkdir -p "$(dirname "$dest")"
  if ! git -C "$repo" worktree add --quiet -b "$name" "$dest" "$branch" >&2; then
    echo "error: git worktree add failed" >&2
    exit "$EXIT_GIT"
  fi
  # Track origin/<name>, not the base: when the base is origin/<x> git sets that as upstream, so pull/push would
  # target the base branch. This only writes config (nothing is pushed); the first `git push` creates the branch.
  if git -C "$repo" remote | grep -Fxq origin; then
    git -C "$repo" config "branch.$name.remote" origin
    git -C "$repo" config "branch.$name.merge" "refs/heads/$name"
  fi
  # Remember the base: git does not, and worktree-clean needs it to tell if the branch was merged.
  if [ "$branch" != "HEAD" ]; then git -C "$repo" config "branch.$name.arness-base" "$branch"; fi
  echo "CREATED $dest $branch"

  # Copy config/<repo>/** into the new worktree and run its install.sh (worktree-config skill).
  if [ "$no_config" -eq 0 ] && [ -d "$root/config/$source" ]; then
    local config_script out rc=0
    config_script="$(dirname "${BASH_SOURCE[0]}")/../../worktree-config/scripts/worktree-config.sh"
    out="$(ARNESS_ROOT="$root" "$config_script" "$source/$name")" || rc=$?
    if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/CONFIG /'; fi
    if [ "$rc" -ne 0 ]; then
      echo "CONFIG_FAILED $rc"
      exit "$EXIT_CONFIG"
    fi
  fi
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
