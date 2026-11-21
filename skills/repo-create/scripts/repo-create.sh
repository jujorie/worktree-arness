#!/usr/bin/env bash
# Create a repository and put it in <arness>/source/<name>, in one of three modes:
#   default    create <owner>/<name> on GitHub with gh, then clone it (through repo-clone)
#   --local    only a local repo: git init source/<name>, branch main and an initial commit; no GitHub
#   --publish  create <owner>/<name> on GitHub, empty, from the local repo source/<name> (made with --local),
#              add it as origin and push its current branch
#
# Usage: repo-create.sh plan  [options] <owner>/<name>
#        repo-create.sh apply [options] <owner>/<name>
#        repo-create.sh plan  --local [--description TEXT] [--no-readme] <name>
#        repo-create.sh apply --local [--description TEXT] [--no-readme] <name>
#        repo-create.sh plan  --publish [visibility] [--description TEXT] [--protocol ssh|https] <owner>/<name>
#        repo-create.sh apply --publish [visibility] [--description TEXT] [--protocol ssh|https] <owner>/<name>
# Options: --private (default) | --public | --internal, --description TEXT, --no-readme,
#          --protocol ssh|https (default: gh's git_protocol for github.com, else https)
# --local takes a <name>, not <owner>/<name>, and no visibility or --protocol: nothing goes to GitHub. Its
# README holds the description; with --no-readme (and then no --description) the initial commit is empty,
# so main always exists.
# --publish takes no --no-readme: the GitHub repo is created empty and gets the local history.
#
# plan checks everything and writes nothing; apply does the work.
# Stdout (machine readable), first word is the status:
#   REPO <repo>, MODE local|publish, VISIBILITY <v>, DESCRIPTION <text>, README yes|no, PROTOCOL <p>,
#   BRANCH <branch>, DEST <path>   plan lines, printed before CONFIRM_*. MODE and BRANCH only in --local and
#                                  --publish; VISIBILITY and PROTOCOL not in --local; README not in --publish
#   CONFIRM_CREATE <repo>          plan done (default or --local), nothing written (exit 20)
#   CONFIRM_PUBLISH <owner>/<name> plan --publish done, nothing written (exit 20)
#   CREATED <owner>/<name> <path>  apply done: repo created on GitHub and cloned
#   CREATED_LOCAL <name> <path>    apply --local done: local repo with branch main and its initial commit
#   PUBLISHED <owner>/<name> <path> <branch>
#                                  apply --publish done: repo created, set as origin, <branch> pushed and tracked
#   EXISTS <path>                  source/<name> already exists; nothing done (exit 10)
#   REMOTE_EXISTS <owner>/<name> <url>  the repo already exists on GitHub; nothing done (exit 12)
#   NO_OWNER <owner>               no GitHub user or organization with that name (exit 13)
#   NOT_CLONED <owner>/<name> <url>     apply created the repo but did not clone it: the clone failed,
#                                  or the repo could not be looked up after creating it (exit 14)
#   CREATE_FAILED_EXISTS <owner>/<name> <url>  gh repo create failed, yet the repo exists: created
#                                  before the failure or by someone else; nothing cloned or linked (exit 15)
#   NOT_PUSHED <owner>/<name> <url>     apply --publish created the repo and set it as origin of the local
#                                  repo, but the push failed (exit 16)
#   NOT_LINKED <owner>/<name> <url>     apply --publish created the repo but did not set it as origin: it
#                                  could not be looked up after creating it, or git remote add failed (exit 17)
#   NO_LOCAL <path>                --publish: source/<name> is missing or is not the top of a git repo (exit 18)
#   HAS_REMOTE <path> <url>        --publish: the local repo already has an origin; nothing done (exit 19)
#   NO_IDENTITY                    apply --local: git has no user.name or user.email for the new repo;
#                                  the folder is removed again (exit 5)
#   NO_AUTH                        gh is missing or not logged in to github.com (exit 4)
# Exit codes: 0 ok, 2 invalid usage/input, 3 GitHub, network or git error, 4 no gh auth, 5 no git identity,
#             10 exists, 12 remote exists, 13 no owner, 14 created but not cloned, 15 create failed but exists,
#             16 created but not pushed, 17 created but not linked, 18 no local repo, 19 local has remote,
#             20 plan ready.
set -euo pipefail

EXIT_USAGE=2 EXIT_GITHUB=3 EXIT_NO_AUTH=4 EXIT_NO_IDENTITY=5 EXIT_EXISTS=10 EXIT_REMOTE_EXISTS=12
EXIT_NO_OWNER=13 EXIT_NOT_CLONED=14 EXIT_CREATE_FAILED_EXISTS=15 EXIT_NOT_PUSHED=16 EXIT_NOT_LINKED=17
EXIT_NO_LOCAL=18 EXIT_HAS_REMOTE=19 EXIT_PLAN=20
GH_HOST_NAME="github.com"
LOCAL_BRANCH="main"   # branch of a repo made with --local

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

# Print the header comment (from line 2 to the first line that is not a comment) as the usage.
usage() { awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

script_dir() { (cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); }

resolve_root() {
  if [ -n "${ARNESS_ROOT:-}" ]; then
    printf '%s\n' "$ARNESS_ROOT"
  else
    # <root>/skills/repo-create/scripts -> <root>. -P follows symlinks (.claude/skills, .agents/skills).
    (cd "$(script_dir)/../../.." && pwd -P)
  fi
}

# GitHub user or organization: letters, digits and single hyphens, 39 characters at most.
validate_owner() {
  case "$1" in
    ""|-*|*-|*--*|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  [ "${#1}" -le 39 ]
}

# Repository name, also the folder in source/: letters, digits, . _ -, 100 characters at most.
validate_name() {
  case "$1" in
    ""|.|..|-*|*.git|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 100 ]
}

validate_description() {
  case "$1" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  [ "${#1}" -le 350 ]
}

default_protocol() {
  local p
  p="$(gh config get git_protocol -h "$GH_HOST_NAME" 2>/dev/null || true)"
  if [ "$p" = "ssh" ]; then echo ssh; else echo https; fi
}

# Print "<ssh_url> <clone_url>" of the repo. Exit 1 when it does not exist, 2 on any other error.
remote_urls() {
  local repo="$1" out err
  err="$(mktemp)"
  if out="$(gh api "repos/$repo" --jq '.ssh_url + " " + .clone_url' 2>"$err")"; then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  if grep -q 'HTTP 404' "$err"; then rm -f "$err"; return 1; fi
  cat "$err" >&2
  rm -f "$err"
  return 2
}

# Exit 0 when the user or organization exists, 1 when not, 2 on any other error.
owner_exists() {
  local owner="$1" err
  err="$(mktemp)"
  if gh api "users/$owner" --jq .login >/dev/null 2>"$err"; then rm -f "$err"; return 0; fi
  if grep -q 'HTTP 404' "$err"; then rm -f "$err"; return 1; fi
  cat "$err" >&2
  rm -f "$err"
  return 2
}

pick_url() {
  local urls="$1" protocol="$2"
  if [ "$protocol" = "ssh" ]; then echo "${urls%% *}"; else echo "${urls#* }"; fi
}

# Clone URL of the chosen protocol when GitHub cannot be asked for it.
fallback_url() {
  local repo="$1" protocol="$2"
  if [ "$protocol" = "ssh" ]; then echo "git@$GH_HOST_NAME:$repo.git"; else echo "https://$GH_HOST_NAME/$repo.git"; fi
}

# The destination must not exist yet (default and --local). Prints a status and exits otherwise.
check_dest_free() {
  local dest="$1"
  if [ -L "$dest" ]; then die "$dest is a symlink, refusing to touch it"; fi
  if [ -e "$dest" ]; then
    echo "EXISTS $dest"
    exit "$EXIT_EXISTS"
  fi
}

# --publish: the destination must be the top of a git repo with no origin and a commit on its current
# branch. Sets PUBLISH_BRANCH. Prints a status and exits otherwise.
check_local_repo() {
  local dest="$1" top real url
  if [ -L "$dest" ]; then die "$dest is a symlink, refusing to touch it"; fi
  if [ ! -d "$dest" ]; then
    if [ -e "$dest" ]; then
      echo "error: $dest is not a folder" >&2
    else
      echo "error: $dest does not exist; create it first with --local" >&2
    fi
    echo "NO_LOCAL $dest"
    exit "$EXIT_NO_LOCAL"
  fi
  real="$(cd -P "$dest" && pwd -P)"
  top="$(git -C "$dest" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$top" ] || [ "$(cd -P "$top" && pwd -P)" != "$real" ]; then
    echo "error: $dest is not the top folder of a git repository" >&2
    echo "NO_LOCAL $dest"
    exit "$EXIT_NO_LOCAL"
  fi
  if url="$(git -C "$dest" remote get-url origin 2>/dev/null)"; then
    echo "HAS_REMOTE $dest $url"
    exit "$EXIT_HAS_REMOTE"
  fi
  if ! PUBLISH_BRANCH="$(git -C "$dest" symbolic-ref --quiet --short HEAD)"; then
    die "$dest has a detached HEAD; check out the branch to publish first"
  fi
  if ! git -C "$dest" rev-parse --verify --quiet "HEAD^{commit}" >/dev/null; then
    die "$dest has no commit on $PUBLISH_BRANCH; commit something first"
  fi
}

# GitHub checks shared by plan and apply of the default mode and --publish. Prints a status and exits
# when the repo cannot be created.
check_github() {
  local repo="$1" owner="${1%%/*}" rc=0 urls

  if ! command -v gh >/dev/null 2>&1 || ! gh auth status -h "$GH_HOST_NAME" >/dev/null 2>&1; then
    echo "NO_AUTH"
    exit "$EXIT_NO_AUTH"
  fi
  if [ -z "$PROTOCOL" ]; then PROTOCOL="$(default_protocol)"; fi
  owner_exists "$owner" || rc=$?
  if [ "$rc" -eq 1 ]; then echo "NO_OWNER $owner"; exit "$EXIT_NO_OWNER"; fi
  if [ "$rc" -ne 0 ]; then echo "error: could not look up owner $owner" >&2; exit "$EXIT_GITHUB"; fi
  rc=0
  urls="$(remote_urls "$repo")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "REMOTE_EXISTS $repo $(pick_url "$urls" "$PROTOCOL")"
    exit "$EXIT_REMOTE_EXISTS"
  fi
  if [ "$rc" -ne 1 ]; then echo "error: could not look up $repo" >&2; exit "$EXIT_GITHUB"; fi
}

# Create the repo on GitHub and set REPO_URL to its URL of the chosen protocol. Exits with a status when
# it cannot tell that this call created it, or when it was created but cannot be looked up (status word
# <not_done>, e.g. NOT_CLONED, with exit <not_done_exit>). Args: repo visibility description readme
# not_done not_done_exit
create_on_github() {
  local repo="$1" visibility="$2" description="$3" readme="$4" not_done="$5" not_done_exit="$6"
  local -a create_args
  local urls rc=0 created=1

  create_args=(repo create "$repo" "--$visibility")
  if [ -n "$description" ]; then create_args+=(--description "$description"); fi
  if [ "$readme" -eq 1 ]; then create_args+=(--add-readme); fi
  if ! gh "${create_args[@]}" >&2; then created=0; fi

  # Look the repo up even after a failed create: the API may have created it before failing.
  urls="$(remote_urls "$repo")" || rc=$?
  if [ "$created" -eq 0 ] && [ "$rc" -eq 1 ]; then
    echo "error: gh repo create failed for $repo; it was not found on GitHub right after the failure" >&2
    exit "$EXIT_GITHUB"
  fi
  if [ "$created" -eq 0 ] && [ "$rc" -ne 0 ]; then
    echo "error: gh repo create failed for $repo and it could not be looked up; run plan to check whether it exists" >&2
    exit "$EXIT_GITHUB"
  fi
  if [ "$rc" -ne 0 ]; then
    echo "error: could not look up $repo after creating it" >&2
    echo "$not_done $repo $(fallback_url "$repo" "$PROTOCOL")"
    exit "$not_done_exit"
  fi
  REPO_URL="$(pick_url "$urls" "$PROTOCOL")"
  # Created by this call before the API failed, or by someone else after the checks: no way to tell,
  # so clone or link nothing and let the user decide.
  if [ "$created" -eq 0 ]; then
    echo "CREATE_FAILED_EXISTS $repo $REPO_URL"
    exit "$EXIT_CREATE_FAILED_EXISTS"
  fi
}

# Remove the folder apply --local made when it stops before the initial commit. Only set after mkdir
# created it, so it never removes anything that was already there.
LOCAL_DEST=""
remove_partial_local() {
  if [ -n "$LOCAL_DEST" ] && [ -d "$LOCAL_DEST" ] && [ ! -L "$LOCAL_DEST" ]; then rm -rf "$LOCAL_DEST"; fi
}

# First non-empty value of git config <key> in <dir>, or nothing. Args: dir key
config_value() { git -C "$1" config "$2" 2>/dev/null || true; }

# git identity for commits in <dir>: true when the author and the committer each have a name and an email
# from an explicit source, in git's order (git-commit-tree): GIT_<SIDE>_NAME/EMAIL, <side>.name/email,
# user.name/email, and EMAIL for the email. Never what git would guess from the host name. Checked per side:
# git's user.useConfigOnly does not, so author.email alone would let the committer go out with no email.
has_identity() {
  local dir="$1" side name email config_only
  config_only="$(git -C "$dir" config --bool user.useConfigOnly 2>/dev/null || true)"
  for side in author committer; do
    # A variable that is set but empty is not a fallback to the config: git refuses an empty ident.
    if [ "$side" = "author" ]; then
      if [ -n "${GIT_AUTHOR_NAME+x}" ] && [ -z "$GIT_AUTHOR_NAME" ]; then return 1; fi
      if [ -n "${GIT_AUTHOR_EMAIL+x}" ] && [ -z "$GIT_AUTHOR_EMAIL" ]; then return 1; fi
      name="${GIT_AUTHOR_NAME:-}" email="${GIT_AUTHOR_EMAIL:-}"
    else
      if [ -n "${GIT_COMMITTER_NAME+x}" ] && [ -z "$GIT_COMMITTER_NAME" ]; then return 1; fi
      if [ -n "${GIT_COMMITTER_EMAIL+x}" ] && [ -z "$GIT_COMMITTER_EMAIL" ]; then return 1; fi
      name="${GIT_COMMITTER_NAME:-}" email="${GIT_COMMITTER_EMAIL:-}"
    fi
    if [ -z "$name" ]; then name="$(config_value "$dir" "$side.name")"; fi
    if [ -z "$name" ]; then name="$(config_value "$dir" user.name)"; fi
    if [ -z "$email" ]; then email="$(config_value "$dir" "$side.email")"; fi
    if [ -z "$email" ]; then email="$(config_value "$dir" user.email)"; fi
    # With user.useConfigOnly git takes the email only from the config, not from EMAIL.
    if [ -z "$email" ] && [ "$config_only" != "true" ]; then email="${EMAIL:-}"; fi
    if [ -z "$name" ] || [ -z "$email" ]; then return 1; fi
  done
}

create_local() {
  local name="$1" dest="$2" description="$3" readme="$4"
  local -a commit_args

  mkdir -p "$(dirname "$dest")"
  if ! mkdir "$dest"; then
    # Made by someone else since the check: leave it alone.
    if [ -e "$dest" ] || [ -L "$dest" ]; then echo "EXISTS $dest"; exit "$EXIT_EXISTS"; fi
    echo "error: could not create $dest" >&2
    exit "$EXIT_GITHUB"
  fi
  LOCAL_DEST="$dest"
  trap remove_partial_local EXIT

  # symbolic-ref instead of `git init -b`, which needs git 2.28 or later.
  if ! git init -q "$dest" >&2 || ! git -C "$dest" symbolic-ref HEAD "refs/heads/$LOCAL_BRANCH"; then
    echo "error: git init failed in $dest" >&2
    exit "$EXIT_GITHUB"
  fi
  # The identity can come from a conditional include that only applies inside the new repo: ask there.
  if ! has_identity "$dest"; then
    echo "error: git user.name or user.email is not set for $dest; set them and run apply again" >&2
    echo "NO_IDENTITY"
    exit "$EXIT_NO_IDENTITY"
  fi
  commit_args=(commit -q --no-verify -m "chore: initial commit")
  if [ "$readme" -eq 1 ]; then
    if [ -n "$description" ]; then
      printf '# %s\n\n%s\n' "$name" "$description" > "$dest/README.md"
    else
      printf '# %s\n' "$name" > "$dest/README.md"
    fi
    git -C "$dest" add README.md
  else
    commit_args+=(--allow-empty)
  fi
  if ! git -C "$dest" "${commit_args[@]}" >&2; then
    echo "error: the initial commit failed in $dest" >&2
    exit "$EXIT_GITHUB"
  fi
  LOCAL_DEST=""
  trap - EXIT
  echo "CREATED_LOCAL $name $dest"
}

publish_local() {
  local repo="$1" dest="$2" visibility="$3" description="$4"

  create_on_github "$repo" "$visibility" "$description" 0 NOT_LINKED "$EXIT_NOT_LINKED"
  if ! git -C "$dest" remote add origin "$REPO_URL" >&2; then
    echo "error: could not add origin $REPO_URL to $dest" >&2
    echo "NOT_LINKED $repo $REPO_URL"
    exit "$EXIT_NOT_LINKED"
  fi
  if ! git -C "$dest" push -u origin "refs/heads/$PUBLISH_BRANCH:refs/heads/$PUBLISH_BRANCH" >&2; then
    echo "error: git push of $PUBLISH_BRANCH to $REPO_URL failed; origin is set" >&2
    echo "NOT_PUSHED $repo $REPO_URL"
    exit "$EXIT_NOT_PUSHED"
  fi
  echo "PUBLISHED $repo $dest $PUBLISH_BRANCH"
}

PROTOCOL=""
REPO_URL=""         # set by create_on_github
PUBLISH_BRANCH=""   # set by check_local_repo

main() {
  local cmd="" repo="" visibility="private" visibility_set=0 description="" readme=1 readme_set=0 mode="github"

  case "${1:-}" in
    plan|apply) cmd="$1"; shift ;;
    -h|--help)  usage; exit 0 ;;
    "")         die "missing command: plan or apply" ;;
    *)          die "unknown command: $1 (use plan or apply)" ;;
  esac

  while [ $# -gt 0 ]; do
    case "$1" in
      --public)      visibility="public"; visibility_set=1; shift ;;
      --internal)    visibility="internal"; visibility_set=1; shift ;;
      --private)     visibility="private"; visibility_set=1; shift ;;
      --description) [ $# -ge 2 ] || die "--description needs a value"; description="$2"; shift 2 ;;
      --no-readme)   readme=0; readme_set=1; shift ;;
      --protocol)    [ $# -ge 2 ] || die "--protocol needs a value"; PROTOCOL="$2"; shift 2 ;;
      --local)       [ "$mode" != "publish" ] || die "--local and --publish cannot go together"; mode="local"; shift ;;
      --publish)     [ "$mode" != "local" ] || die "--local and --publish cannot go together"; mode="publish"; shift ;;
      -h|--help)     usage; exit 0 ;;
      -*)            die "unknown option: $1" ;;
      *)             [ -z "$repo" ] || die "only one repository allowed"; repo="$1"; shift ;;
    esac
  done

  local owner="" name=""
  if [ "$mode" = "local" ]; then
    [ -n "$repo" ] || die "missing repository name: <name>"
    case "$repo" in */*) die "--local takes a <name>, not <owner>/<name>: nothing goes to GitHub" ;; esac
    [ "$visibility_set" -eq 0 ] || die "--local takes no visibility: nothing goes to GitHub"
    [ -z "$PROTOCOL" ] || die "--local takes no --protocol: nothing goes to GitHub"
    if [ "$readme" -eq 0 ] && [ -n "$description" ]; then
      die "--local --no-readme takes no --description: it only goes into the README"
    fi
    name="$repo"
  else
    [ -n "$repo" ] || die "missing repository: <owner>/<name>"
    case "$repo" in
      */*/*|*/) die "invalid repository: '$repo' (use <owner>/<name>)" ;;
      */*) ;;
      *) die "invalid repository: '$repo' (use <owner>/<name>)" ;;
    esac
    owner="${repo%%/*}" name="${repo#*/}"
    validate_owner "$owner" || die "invalid owner: '$owner' (letters, digits and single hyphens)"
    if [ "$mode" = "publish" ] && [ "$readme_set" -eq 1 ]; then
      die "--publish takes no --no-readme: the GitHub repo is created empty from the local one"
    fi
  fi
  validate_name "$name" || die "invalid repository name: '$name' (letters, digits, . _ -; no .git)"
  validate_description "$description" || die "invalid description: no control characters, 350 characters at most"
  case "$PROTOCOL" in ""|ssh|https) ;; *) die "--protocol must be ssh or https" ;; esac

  local root dest readme_word="yes"
  root="$(resolve_root)"
  dest="$root/source/$name"
  if [ "$readme" -eq 0 ]; then readme_word="no"; fi
  # GH_HOST: gh api and gh repo create go to github.com, the host checked by NO_AUTH, not gh's default.
  export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1 GH_HOST="$GH_HOST_NAME"

  case "$mode" in
    local)
      check_dest_free "$dest"
      if [ "$cmd" = "plan" ]; then
        echo "REPO $name"
        echo "MODE local"
        echo "DESCRIPTION $description"
        echo "README $readme_word"
        echo "BRANCH $LOCAL_BRANCH"
        echo "DEST $dest"
        echo "CONFIRM_CREATE $name"
        exit "$EXIT_PLAN"
      fi
      create_local "$name" "$dest" "$description" "$readme" ;;
    publish)
      check_local_repo "$dest"
      check_github "$repo"
      if [ "$cmd" = "plan" ]; then
        echo "REPO $repo"
        echo "MODE publish"
        echo "VISIBILITY $visibility"
        echo "DESCRIPTION $description"
        echo "PROTOCOL $PROTOCOL"
        echo "BRANCH $PUBLISH_BRANCH"
        echo "DEST $dest"
        echo "CONFIRM_PUBLISH $repo"
        exit "$EXIT_PLAN"
      fi
      publish_local "$repo" "$dest" "$visibility" "$description" ;;
    *)
      check_dest_free "$dest"
      check_github "$repo"
      if [ "$cmd" = "plan" ]; then
        echo "REPO $repo"
        echo "VISIBILITY $visibility"
        echo "DESCRIPTION $description"
        echo "README $readme_word"
        echo "PROTOCOL $PROTOCOL"
        echo "DEST $dest"
        echo "CONFIRM_CREATE $repo"
        exit "$EXIT_PLAN"
      fi
      create_on_github "$repo" "$visibility" "$description" "$readme" NOT_CLONED "$EXIT_NOT_CLONED"
      local out rc=0
      out="$(ARNESS_ROOT="$root" "$(script_dir)/../../repo-clone/scripts/repo-clone.sh" --name "$name" "$REPO_URL")" || rc=$?
      if [ "$rc" -ne 0 ]; then
        [ -z "$out" ] || echo "$out" >&2
        echo "NOT_CLONED $repo $REPO_URL"
        exit "$EXIT_NOT_CLONED"
      fi
      echo "CREATED $repo $dest" ;;
  esac
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
