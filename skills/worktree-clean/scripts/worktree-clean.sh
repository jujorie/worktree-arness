#!/usr/bin/env bash
# List and remove the worktrees in <arness>/worktrees/<repo>/ created from repos in <arness>/source/.
#
# Usage: worktree-clean.sh list   [--source REPO] [--base REF] [--no-fetch]
#        worktree-clean.sh remove --source REPO [--base REF] [--force] [--no-fetch] NAME...
#
# list stdout: one tab-separated row per worktree, or NONE (exit 0):
#   repo  name  branch  base  status  ahead  path
#   status: MERGED | PR_MERGED | PUSHED | EMPTY | NOT_MERGED | DIRTY | UNKNOWN_BASE
#           DIRTY = uncommitted changes, or a rebase/bisect/merge/cherry-pick/revert in progress
#           EMPTY = no commits of its own yet (still where it was created): nothing merged, nothing to lose
#           PR_MERGED = the branch was deleted in origin and a merged pull request had exactly its tip
#                       as head (squash and rebase merges included): nothing to lose
#           PUSHED = origin/<branch> holds every commit (pushed work, e.g. a pull request not merged yet, or
#                    a branch checked out from origin and updated from it): nothing to lose, but nothing
#                    says it was merged anywhere. Online, the tip in origin is checked with ls-remote.
#   ahead:  commits of the branch not in base ("-" if unknown); a PUSHED branch may have some
#   branch is "(detached)" for a worktree with no branch (worktree-create --detach, e.g. a release): base is
#   the ref it was checked out from (git config arness-worktree.<name>.base), else a branch or tag at its
#   HEAD, else "-". It is EMPTY, or NOT_MERGED with ahead = commits on its HEAD that no branch, remote
#   branch or tag holds (lost on removal). Removing it deletes no branch.
# remove stdout, per NAME (exit 13 if any SKIPPED):
#   STOPPED <repo>/<name> <script> <pid>   an npm script npm-run started there, stopped before removing it
#   REMOVED <path>
#   SKIPPED <path|name> <reason>   reason: invalid-name | not-a-worktree | git-failed | stop-failed |
#                                  NOT_MERGED | DIRTY | UNKNOWN_BASE (these three need --force)
# Before a worktree is removed, the npm scripts npm-run started in it (dev servers, watchers) are stopped
# with `npm-run.sh stop --worktree <repo>/<name>`: once its folder is gone they would keep running and
# holding their ports. If that stop fails the worktree is kept (stop-failed).
# The base of a worktree is read from git config branch.<name>.arness-base (set by worktree-create);
# --base is the fallback when it is missing.
# Merge status looks at the base and at its remote side: a worktree is MERGED if its branch is in <base> or
# in origin/<base> (e.g. merged in origin/develop while the local develop is behind). The remote side is
# refreshed first with `git fetch origin <branch>`, once per base. If the fetch fails a warning goes to
# stderr and the local copy is used; if the branch no longer exists in origin, a note says so instead.
# A branch that is not MERGED is checked for PR_MERGED: `git ls-remote` to see it is gone from origin, then
# `gh pr list --head <branch> --state merged` (skipped without gh, or when gh fails).
# --no-fetch skips all network calls (offline).
# Exit codes: 0 ok, 2 invalid usage/input, 4 no source, 13 some worktree skipped.
set -euo pipefail

EXIT_USAGE=2 EXIT_NO_SOURCE=4 EXIT_SKIPPED=13

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

resolve_root() {
  if [ -n "${ARNESS_ROOT:-}" ]; then
    printf '%s\n' "$ARNESS_ROOT"
  else
    # <root>/skills/worktree-clean/scripts -> <root>. -P follows symlinks (.claude/skills, .agents/skills).
    (cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
  fi
}

# Valid file name, or several joined by "/" (feat/PROJ-123). Each part must be a safe path component.
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

# True if <branch> is gone from origin and a merged pull request had its current tip as head.
# Any doubt (origin unreachable, no gh, gh fails, tip moved after the merge) is false. Args: repo_dir branch
pr_merged() {
  local repo_dir="$1" branch="$2" tip rc=0 heads
  git -C "$repo_dir" remote | grep -Fxq origin || return 1
  command -v gh >/dev/null 2>&1 || return 1
  # Exit 2 = reachable and the ref is not there; 0 = still there; anything else = unknown.
  GIT_TERMINAL_PROMPT=0 git -C "$repo_dir" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || return 1
  tip="$(git -C "$repo_dir" rev-parse "$branch^{commit}")" || return 1
  heads="$(cd "$repo_dir" && GH_PROMPT_DISABLED=1 gh pr list --head "$branch" --state merged \
    --json headRefOid --jq '.[].headRefOid' 2>/dev/null)" || return 1
  printf '%s\n' "$heads" | grep -Fxq "$tip"
}

# True if origin holds every commit of <branch>: origin/<branch> contains its tip. Online the tip in origin is
# asked with ls-remote, so a stale origin/<branch> (deleted or rewritten in origin) proves nothing; a tip
# this clone does not have is a doubt, so false. --no-fetch trusts the local origin/<branch>.
# Args: repo_dir branch
pushed() {
  local repo_dir="$1" branch="$2" local_tip remote_tip
  local_tip="$(git -C "$repo_dir" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}")" || return 1
  git -C "$repo_dir" merge-base --is-ancestor "$branch" "$local_tip" 2>/dev/null || return 1
  if [ "${NO_FETCH:-0}" -eq 1 ]; then return 0; fi
  remote_tip="$(GIT_TERMINAL_PROMPT=0 git -C "$repo_dir" ls-remote origin "refs/heads/$branch" 2>/dev/null \
    | awk 'NR == 1 { print $1 }')"
  [ -n "$remote_tip" ] || return 1
  [ "$remote_tip" = "$local_tip" ] || git -C "$repo_dir" merge-base --is-ancestor "$branch" "$remote_tip" 2>/dev/null
}

# Stop what npm-run started in worktree <repo>/<name> and pass its STOPPED lines on. Nothing to do when
# npm-run has no state for it. Args: slug
stop_npm_scripts() {
  local slug="$1" npm_run="$ROOT/skills/npm-run/scripts/npm-run.sh" out
  [ -d "$ROOT/tmp/npm-run/$slug" ] || return 0
  if [ ! -x "$npm_run" ]; then
    echo "warning: npm-run not found; cannot stop the npm scripts of $slug" >&2
    return 1
  fi
  if ! out="$(ARNESS_ROOT="$ROOT" "$npm_run" stop --worktree "$slug")"; then
    echo "warning: npm-run stop failed for $slug: $out" >&2
    return 1
  fi
  printf '%s\n' "$out" | grep '^STOPPED ' || true
}

# Print the ref a detached worktree shows: the one worktree-create recorded, else a branch or tag at its HEAD
# (remote first: a release is usually origin/<branch>), else "-". Args: repo_dir wt_path name
detached_base() {
  local repo_dir="$1" path="$2" name="$3" base pattern
  base="$(git -C "$repo_dir" config --get "arness-worktree.$name.base" 2>/dev/null || true)"
  # One pattern at a time: for-each-ref sorts all its matches by refname, whatever the order of the patterns.
  # Several refs of one kind on HEAD (origin/main and origin/release/1.2) give the first by name: only the
  # recorded ref is exact.
  for pattern in refs/remotes refs/heads refs/tags; do
    if [ -n "$base" ]; then break; fi
    base="$(git -C "$path" for-each-ref --points-at HEAD --format='%(refname:short)' "$pattern" 2>/dev/null \
      | grep -v '/HEAD$' | awk 'NR == 1' || true)"
  done
  printf '%s\n' "${base:--}"
}

# True if a rebase, bisect, merge, cherry-pick or revert is in progress in the worktree: removing it loses
# that state even when no file is changed (a rebase starts on a commit a branch holds). Args: wt_path
op_in_progress() {
  local gitdir f
  gitdir="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  for f in rebase-merge rebase-apply BISECT_LOG MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    if [ -e "$gitdir/$f" ]; then return 0; fi
  done
  return 1
}

# Sets S_BASE, S_AHEAD, S_STATUS for a worktree. Args: repo_dir wt_path branch fallback_base name
compute_status() {
  local repo_dir="$1" path="$2" branch="$3" fallback="$4" name="$5" base=""
  S_BASE="-" S_AHEAD="-" S_STATUS="UNKNOWN_BASE"
  if [ "$branch" != "-" ]; then
    base="$(git -C "$repo_dir" config --get "branch.$branch.arness-base" 2>/dev/null || true)"
  fi
  if [ -z "$base" ]; then base="$fallback"; fi
  if [ -n "$base" ]; then S_BASE="$base"; fi
  if [ "$branch" = "-" ] && git -C "$path" rev-parse --verify --quiet "HEAD^{commit}" >/dev/null; then
    # Detached HEAD (worktree-create --detach): no branch to merge. It only loses commits made on it that no
    # branch, remote branch or tag holds.
    S_BASE="$(detached_base "$repo_dir" "$path" "$name")"
    S_AHEAD="$(git -C "$path" rev-list --count HEAD --not --branches --remotes --tags)"
    if [ "$S_AHEAD" -eq 0 ]; then S_STATUS="EMPTY"; else S_STATUS="NOT_MERGED"; fi
  elif [ "$branch" != "-" ] && [ -n "$base" ] && git -C "$repo_dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    # A local base (develop) may be behind its remote: a merge done in origin/develop counts too.
    local refs=("$base")
    case "$base" in
      origin/*) ;;
      *) if git -C "$repo_dir" rev-parse --verify --quiet "refs/remotes/origin/$base^{commit}" >/dev/null; then refs+=("origin/$base"); fi ;;
    esac
    S_AHEAD="$(git -C "$repo_dir" rev-list --count "$branch" --not "${refs[@]}")"
    if [ "$S_AHEAD" -ne 0 ]; then
      # Work not in the base is still safe if it was pushed to the branch's own remote (a PR not merged yet).
      if pushed "$repo_dir" "$branch"; then S_STATUS="PUSHED"; else S_STATUS="NOT_MERGED"; fi
    else
      # Nothing outside the base. That is "merged" only if the branch ever had work: a branch still on the
      # commit it was created from (oldest reflog entry) has merged nothing yet.
      local created
      created="$(git -C "$repo_dir" reflog show --format=%H "refs/heads/$branch" 2>/dev/null | tail -n 1)"
      if [ -n "$created" ] && [ "$created" = "$(git -C "$repo_dir" rev-parse "$branch^{commit}")" ]; then
        S_STATUS="EMPTY"
      elif [ "$base" = "origin/$branch" ]; then
        # The base is the branch's own remote: being in it only means the work was pushed, not merged.
        # If origin no longer holds it (deleted, rewritten), the local copy of the base proves nothing.
        if pushed "$repo_dir" "$branch"; then S_STATUS="PUSHED"; else S_STATUS="NOT_MERGED" S_AHEAD="-"; fi
      else
        S_STATUS="MERGED"
      fi
    fi
  fi
  # A squash or rebase merge leaves the commits out of the base: ask the forge.
  case "$S_STATUS" in
    EMPTY|PUSHED|NOT_MERGED|UNKNOWN_BASE)
      if [ "$branch" != "-" ] && [ "${NO_FETCH:-0}" -eq 0 ] && pr_merged "$repo_dir" "$branch"; then
        S_STATUS="PR_MERGED"
      fi ;;
  esac
  # Uncommitted work, or a git operation in progress, wins over any other status.
  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ] || op_in_progress "$path"; then S_STATUS="DIRTY"; fi
}

# Print one TSV row per worktree of <repo> that lives in worktrees/<repo>/.
repo_rows() {
  local repo="$1" fallback="$2" repo_dir="$SOURCE_DIR/$1" prefix="$WT_DIR/$1/" line path="" branch="-" name shown
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }"; branch="-" ;;
      "branch "*)   branch="${line#branch refs/heads/}" ;;
      "")
        case "$path" in
          "$prefix"?*)
            name="${path#"$prefix"}"
            compute_status "$repo_dir" "$path" "$branch" "$fallback" "$name"
            shown="$branch"
            if [ "$branch" = "-" ]; then shown="(detached)"; fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$name" "$shown" "$S_BASE" "$S_STATUS" "$S_AHEAD" "$path"
            ;;
        esac
        path="" ;;
    esac
  done < <(git -C "$repo_dir" worktree list --porcelain; echo)
}

# Refresh the remote side of every base, once each, so merges done in the remote are visible:
# origin/<branch> bases, and origin/<base> of local bases that origin is known to have.
prefetch_bases() {
  local r b br err
  for r in "${SEL_REPOS[@]}"; do
    git -C "$SOURCE_DIR/$r" remote | grep -Fxq origin || continue
    # A repo with no recorded base makes git config exit 1; under pipefail that would abort the script.
    { { git -C "$SOURCE_DIR/$r" config --get-regexp '^branch\..*\.arness-base$' 2>/dev/null || true; } | awk '{print $2}'
      if [ -n "$FALLBACK" ]; then printf '%s\n' "$FALLBACK"; fi
    } | LC_ALL=C sort -u | while IFS= read -r b; do
      case "$b" in
        origin/?*) br="${b#origin/}" ;;
        -*|"")     continue ;;
        # local base: refresh its remote counterpart, only if origin is known to have it
        *)         git -C "$SOURCE_DIR/$r" rev-parse --verify --quiet "refs/remotes/origin/$b^{commit}" >/dev/null || continue
                   br="$b" ;;
      esac
      git check-ref-format "refs/heads/$br" 2>/dev/null || continue
      if ! err="$(GIT_TERMINAL_PROMPT=0 git -C "$SOURCE_DIR/$r" fetch --quiet origin "+refs/heads/$br:refs/remotes/origin/$br" 2>&1)"; then
        case "$err" in
          *"couldn't find remote ref"*) echo "note: origin/$br no longer exists in $r (deleted in origin)" >&2 ;;
          *) echo "warning: could not refresh origin/$br in $r; its merge status may be stale" >&2 ;;
        esac
      fi
    done
  done
}

cmd_list() {
  local r out="" rows
  for r in "${SEL_REPOS[@]}"; do
    rows="$(repo_rows "$r" "$FALLBACK")"
    if [ -n "$rows" ]; then out="$out$rows"$'\n'; fi
  done
  if [ -z "$out" ]; then echo "NONE"; else printf '%s' "$out"; fi
}

cmd_remove() {
  local repo="${SEL_REPOS[0]}" repo_dir name path row skipped=0 stop d
  local branch status f_path
  [ "${#NAMES[@]}" -gt 0 ] || die "remove needs at least one NAME"
  stop="$WT_DIR/$repo"
  repo_dir="$SOURCE_DIR/$repo"

  for name in "${NAMES[@]}"; do
    if ! validate_name "$name"; then echo "SKIPPED $name invalid-name"; skipped=1; continue; fi
    path="$stop/$name"
    row="$(repo_rows "$repo" "$FALLBACK" | awk -F'\t' -v n="$name" '$2 == n')"
    if [ -z "$row" ]; then echo "SKIPPED $path not-a-worktree"; skipped=1; continue; fi
    IFS=$'\t' read -r _ _ branch _ status _ f_path <<EOF_ROW
$row
EOF_ROW
    case "$status" in
      MERGED|PR_MERGED|PUSHED|EMPTY) ;;
      *) if [ "$FORCE" -eq 0 ]; then echo "SKIPPED $f_path $status"; skipped=1; continue; fi ;;
    esac
    stop_npm_scripts "$repo/$name" || { echo "SKIPPED $f_path stop-failed"; skipped=1; continue; }

    if [ "$FORCE" -eq 1 ]; then
      git -C "$repo_dir" worktree remove --force "$f_path" >&2 || { echo "SKIPPED $f_path git-failed"; skipped=1; continue; }
    else
      git -C "$repo_dir" worktree remove "$f_path" >&2 || { echo "SKIPPED $f_path git-failed"; skipped=1; continue; }
    fi
    if [ "$branch" = "(detached)" ]; then
      # No branch to delete; drop the base worktree-create --detach recorded for it.
      git -C "$repo_dir" config --remove-section "arness-worktree.$name" >/dev/null 2>&1 || true
    elif [ "$branch" != "-" ]; then
      # -d is the safe delete; it can refuse a branch merged into the base but not into HEAD.
      # Merge into the base was verified above, so -D is safe then; with --force the user asked for it.
      # PR_MERGED: the tip is the head of a merged pull request, so -D loses nothing either.
      # PUSHED: origin/<branch> holds every commit, so -D loses nothing either.
      if [ "$status" = "MERGED" ] || [ "$status" = "PUSHED" ] || [ "$status" = "EMPTY" ]; then
        git -C "$repo_dir" branch -q -d "$branch" >&2 || git -C "$repo_dir" branch -q -D "$branch" >&2
      else
        git -C "$repo_dir" branch -q -D "$branch" >&2
      fi
      # Gone from origin: drop its stale remote-tracking ref too.
      if [ "$status" = "PR_MERGED" ]; then
        git -C "$repo_dir" update-ref -d "refs/remotes/origin/$branch" >/dev/null 2>&1 || true
      fi
    fi
    git -C "$repo_dir" worktree prune >&2
    # Drop now-empty parent dirs (feat/), never worktrees/<repo> itself.
    d="$(dirname "$f_path")"
    while [ "$d" != "$stop" ] && rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
    echo "REMOVED $f_path"
  done
  if [ "$skipped" -eq 1 ]; then exit "$EXIT_SKIPPED"; fi
}

main() {
  [ $# -ge 1 ] || die "missing command (list | remove)"
  local cmd="$1" source="" FORCE=0 NO_FETCH=0 r
  FALLBACK="" NAMES=()
  shift
  case "$cmd" in
    list|remove) ;;
    -h|--help) awk 'NR > 1 && /^set -euo/ { exit } NR > 1' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown command: $cmd" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) [ $# -ge 2 ] || die "--source needs a value"; source="$2"; shift 2 ;;
      --base)   [ $# -ge 2 ] || die "--base needs a value"; FALLBACK="$2"; shift 2 ;;
      --force)  FORCE=1; shift ;;
      --no-fetch) NO_FETCH=1; shift ;;
      -*)       die "unknown option: $1" ;;
      *)        NAMES+=("$1"); shift ;;
    esac
  done
  case "$FALLBACK" in -*|*[[:space:]]*) die "invalid --base: '$FALLBACK'" ;; esac
  if [ "$cmd" = "list" ] && [ "${#NAMES[@]}" -gt 0 ]; then die "list takes no NAME"; fi
  command -v git >/dev/null 2>&1 || die "git not found"

  local root
  root="$(resolve_root)"
  # Physical paths: git reports them, so prefixes must match.
  root="$(cd -P "$root" && pwd -P)"
  ROOT="$root" SOURCE_DIR="$root/source" WT_DIR="$root/worktrees"

  local repos=() d
  for d in "$SOURCE_DIR"/*/; do
    if [ -e "${d}.git" ] && [ ! -L "${d%/}" ]; then repos+=("$(basename "$d")"); fi
  done
  if [ "${#repos[@]}" -eq 0 ]; then echo "NO_SOURCE"; exit "$EXIT_NO_SOURCE"; fi

  SEL_REPOS=()
  if [ -n "$source" ]; then
    for r in "${repos[@]}"; do if [ "$r" = "$source" ]; then SEL_REPOS=("$r"); fi; done
    if [ "${#SEL_REPOS[@]}" -eq 0 ]; then echo "NO_SOURCE"; exit "$EXIT_NO_SOURCE"; fi
  else
    if [ "$cmd" = "remove" ]; then die "remove needs --source"; fi
    SEL_REPOS=("${repos[@]}")
  fi

  if [ "$NO_FETCH" -eq 0 ]; then prefetch_bases; fi
  if [ "$cmd" = "list" ]; then cmd_list; else cmd_remove; fi
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
