#!/usr/bin/env bash
# Create a GitHub repository with gh and clone it into <arness>/source/<name> (through repo-clone).
#
# Usage: repo-create.sh plan  [options] <owner>/<name>
#        repo-create.sh apply [options] <owner>/<name>
# Options: --public | --internal (default: private), --description TEXT, --no-readme,
#          --protocol ssh|https (default: gh's git_protocol for github.com, else https)
#
# plan checks everything and writes nothing; apply creates the repo on GitHub, then clones it.
# Stdout (machine readable), first word is the status:
#   REPO <owner>/<name>, VISIBILITY <v>, DESCRIPTION <text>, README yes|no, PROTOCOL <p>, DEST <path>
#                                  plan lines, printed before CONFIRM_CREATE
#   CONFIRM_CREATE <owner>/<name>  plan done, nothing written (exit 20)
#   CREATED <owner>/<name> <path>  apply done: repo created and cloned
#   EXISTS <path>                  source/<name> already exists; nothing done (exit 10)
#   REMOTE_EXISTS <owner>/<name> <url>  the repo already exists on GitHub; nothing done (exit 12)
#   NO_OWNER <owner>               no GitHub user or organization with that name (exit 13)
#   NOT_CLONED <owner>/<name> <url>     apply created the repo but the clone failed (exit 14)
#   NO_AUTH                        gh is missing or not logged in to github.com (exit 4)
# Exit codes: 0 ok, 2 invalid usage/input, 3 GitHub or network error, 4 no gh auth, 10 exists,
#             12 remote exists, 13 no owner, 14 created but not cloned, 20 plan ready.
set -euo pipefail

EXIT_USAGE=2 EXIT_GITHUB=3 EXIT_NO_AUTH=4 EXIT_EXISTS=10 EXIT_REMOTE_EXISTS=12 EXIT_NO_OWNER=13
EXIT_NOT_CLONED=14 EXIT_PLAN=20
GH_HOST_NAME="github.com"

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

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

# Checks shared by plan and apply. Prints a status and exits when the repo cannot be created.
check_all() {
  local repo="$1" dest="$2" owner="${1%%/*}" rc=0 urls

  if [ -L "$dest" ]; then die "$dest is a symlink, refusing to touch it"; fi
  if [ -e "$dest" ]; then
    echo "EXISTS $dest"
    exit "$EXIT_EXISTS"
  fi
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

PROTOCOL=""

main() {
  local cmd="" repo="" visibility="private" description="" readme=1
  local -a create_args

  case "${1:-}" in
    plan|apply) cmd="$1"; shift ;;
    -h|--help)  sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    "")         die "missing command: plan or apply" ;;
    *)          die "unknown command: $1 (use plan or apply)" ;;
  esac

  while [ $# -gt 0 ]; do
    case "$1" in
      --public)      visibility="public"; shift ;;
      --internal)    visibility="internal"; shift ;;
      --private)     visibility="private"; shift ;;
      --description) [ $# -ge 2 ] || die "--description needs a value"; description="$2"; shift 2 ;;
      --no-readme)   readme=0; shift ;;
      --protocol)    [ $# -ge 2 ] || die "--protocol needs a value"; PROTOCOL="$2"; shift 2 ;;
      -h|--help)     sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
      -*)            die "unknown option: $1" ;;
      *)             [ -z "$repo" ] || die "only one repository allowed"; repo="$1"; shift ;;
    esac
  done

  [ -n "$repo" ] || die "missing repository: <owner>/<name>"
  case "$repo" in
    */*/*|*/) die "invalid repository: '$repo' (use <owner>/<name>)" ;;
    */*) ;;
    *) die "invalid repository: '$repo' (use <owner>/<name>)" ;;
  esac
  local owner="${repo%%/*}" name="${repo#*/}"
  validate_owner "$owner" || die "invalid owner: '$owner' (letters, digits and single hyphens)"
  validate_name "$name" || die "invalid repository name: '$name' (letters, digits, . _ -; no .git)"
  validate_description "$description" || die "invalid description: no control characters, 350 characters at most"
  case "$PROTOCOL" in ""|ssh|https) ;; *) die "--protocol must be ssh or https" ;; esac

  local root dest
  root="$(resolve_root)"
  dest="$root/source/$name"
  # GH_HOST: gh api and gh repo create go to github.com, the host checked by NO_AUTH, not gh's default.
  export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1 GH_HOST="$GH_HOST_NAME"

  check_all "$repo" "$dest"

  if [ "$cmd" = "plan" ]; then
    local readme_word="yes"
    if [ "$readme" -eq 0 ]; then readme_word="no"; fi
    echo "REPO $repo"
    echo "VISIBILITY $visibility"
    echo "DESCRIPTION $description"
    echo "README $readme_word"
    echo "PROTOCOL $PROTOCOL"
    echo "DEST $dest"
    echo "CONFIRM_CREATE $repo"
    exit "$EXIT_PLAN"
  fi

  create_args=(repo create "$repo" "--$visibility")
  if [ -n "$description" ]; then create_args+=(--description "$description"); fi
  if [ "$readme" -eq 1 ]; then create_args+=(--add-readme); fi
  local urls url rc=0 created=1
  if ! gh "${create_args[@]}" >&2; then created=0; fi

  # Look the repo up even after a failed create: the API may have created it before failing.
  urls="$(remote_urls "$repo")" || rc=$?
  if [ "$created" -eq 0 ] && [ "$rc" -eq 1 ]; then
    echo "error: gh repo create failed for $repo; nothing was created" >&2
    exit "$EXIT_GITHUB"
  fi
  if [ "$created" -eq 0 ] && [ "$rc" -ne 0 ]; then
    echo "error: gh repo create failed for $repo and it could not be looked up; run plan to check whether it exists" >&2
    exit "$EXIT_GITHUB"
  fi
  if [ "$rc" -ne 0 ]; then
    echo "error: could not look up $repo after creating it" >&2
    echo "NOT_CLONED $repo $(fallback_url "$repo" "$PROTOCOL")"
    exit "$EXIT_NOT_CLONED"
  fi
  if [ "$created" -eq 0 ]; then echo "warning: gh repo create failed, but $repo exists on GitHub" >&2; fi
  url="$(pick_url "$urls" "$PROTOCOL")"

  local out
  rc=0
  out="$(ARNESS_ROOT="$root" "$(script_dir)/../../repo-clone/scripts/repo-clone.sh" --name "$name" "$url")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || echo "$out" >&2
    echo "NOT_CLONED $repo $url"
    exit "$EXIT_NOT_CLONED"
  fi
  echo "CREATED $repo $dest"
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
