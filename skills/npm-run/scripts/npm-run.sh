#!/usr/bin/env bash
# Run an npm script of a worktree in the background, and list, stop or clean up the ones it started.
#
# Usage: npm-run.sh run     [--worktree <repo>/<name>] [--install] <script> [-- <args>...]
#        npm-run.sh scripts [--worktree <repo>/<name>]
#        npm-run.sh ps
#        npm-run.sh stop    [--worktree <repo>/<name>] [<script>] | --all
#        npm-run.sh clean   [--worktree <repo>/<name>]
#
# The worktree is one of worktrees/<repo>/<name> made from a repo in source/. Without --worktree, the
# only one there is used; with several, nothing runs and they are listed (CHOOSE_WORKTREE).
# The script must be a key of "scripts" in the package.json at the root of the worktree (read with
# `npm pkg get scripts`). It runs as `npm run <script> [-- <args>]`, cwd = the worktree, in its own
# process group, so stop also ends its children (dev servers, watchers).
# Without node_modules it stops with CONFIRM_INSTALL; --install runs `npm ci` (with package-lock.json)
# or `npm install` first. Logs and pids: <arness>/tmp/npm-run/<repo>/<name>/<script>.{log,pid}.
# stop removes the pid and log of what it stops, and the install.log and folders left empty. A script
# that ended by itself (FINISHED, EXITED) keeps its log until clean removes everything that no longer runs.
#
# Stdout, first word is the status:
#   STARTED <repo>/<name> <script> <pid> <log>     running in the background
#   FINISHED <repo>/<name> <script> <code> <log>   ended within the first second (exit 0 only if code 0)
#   INSTALLED <repo>/<name> <log>                  dependencies installed (before STARTED)
#   SCRIPT <name>                                  one per available script (scripts, NO_COMMAND,
#                                                  UNKNOWN_SCRIPT)
#   RUNNING <repo>/<name> <script> <pid> <log>     ps: still running
#   EXITED <repo>/<name> <script> <pid> <log>      ps: no longer running (its pid file is removed)
#   STOPPED <repo>/<name> <script> <pid>           stop (its pid and log are removed)
#   CLEANED <repo>/<name> <file>                   clean: a log or stale pid file removed
#   NONE                                           ps / stop / clean: nothing to show, stop or remove
#   CHOOSE_WORKTREE <repo>/<name>...               several worktrees, none given (exit 10)
#   NO_WORKTREE                                    no worktree at all (exit 4)
#   NOT_FOUND <repo>/<name>                        not a worktree of a repo in source/ (exit 4)
#   NO_PACKAGE_JSON <path>                         no package.json at the worktree root (exit 6)
#   INVALID_PACKAGE_JSON <path>                    npm cannot read it (exit 6)
#   NO_COMMAND <repo>/<name>                       no script given (exit 5)
#   UNKNOWN_SCRIPT <repo>/<name> <script>          not in package.json "scripts" (exit 7)
#   CONFIRM_INSTALL <repo>/<name>                  no node_modules: ask, then rerun with --install (exit 11)
#   INSTALL_FAILED <code> <log>                    npm ci / install failed; last 20 lines on stderr (exit 12)
#   ALREADY_RUNNING <repo>/<name> <script> <pid>   that script already runs there (exit 9)
#   NO_NPM                                         npm not found (exit 3)
# Exit codes: 0 ok, 2 invalid usage, 3 no npm, 4 no worktree, 5 no command, 6 package.json,
# 7 unknown script, 8 script failed at start, 9 already running, 10 choose worktree,
# 11 confirm install, 12 install failed.
set -euo pipefail

EXIT_USAGE=2 EXIT_NO_NPM=3 EXIT_NO_WORKTREE=4 EXIT_NO_COMMAND=5 EXIT_PACKAGE=6 EXIT_UNKNOWN_SCRIPT=7
EXIT_FAILED=8 EXIT_RUNNING=9 EXIT_CHOOSE=10 EXIT_CONFIRM_INSTALL=11 EXIT_INSTALL=12

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

resolve_root() {
  if [ -n "${ARNESS_ROOT:-}" ]; then
    printf '%s\n' "$ARNESS_ROOT"
  else
    # <root>/skills/npm-run/scripts -> <root>. -P follows symlinks (.claude/skills, .agents/skills).
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

# npm script names: letters, digits and : . _ - (build:prod, test.unit). Also used as a file name.
validate_script() {
  case "$1" in
    ""|-*|.*|*[!A-Za-z0-9:._-]*) return 1 ;;
  esac
}

# list_worktrees: every worktrees/<repo>/<name> that is a git worktree of source/<repo>, as <repo>/<name>.
list_worktrees() {
  local repo_dir repo line path prefix
  for repo_dir in "$ROOT"/source/*/; do
    repo_dir="${repo_dir%/}"
    [ -e "$repo_dir/.git" ] || continue
    repo="$(basename "$repo_dir")"
    prefix="$ROOT/worktrees/$repo/"
    while IFS= read -r line; do
      case "$line" in
        "worktree $prefix"?*)
          path="${line#worktree }"
          if [ ! -d "$path" ] || [ -L "$path" ]; then continue; fi
          printf '%s/%s\n' "$repo" "${path#"$prefix"}" ;;
      esac
    done < <(git -C "$repo_dir" worktree list --porcelain 2>/dev/null)
  done | LC_ALL=C sort
}

# resolve_worktree <slug|"">: sets SLUG and WT, or stops with CHOOSE_WORKTREE / NO_WORKTREE / NOT_FOUND.
resolve_worktree() {
  local want="$1" all
  all="$(list_worktrees)"
  if [ -n "$want" ]; then
    case "$want" in
      */*) validate_name "$want" || die "invalid worktree: '$want' (expected <repo>/<name>)" ;;
      *)   die "invalid worktree: '$want' (expected <repo>/<name>)" ;;
    esac
    if ! printf '%s\n' "$all" | grep -Fxq -- "$want"; then
      echo "NOT_FOUND $want"
      exit "$EXIT_NO_WORKTREE"
    fi
    SLUG="$want"
  elif [ -z "$all" ]; then
    echo "NO_WORKTREE"
    exit "$EXIT_NO_WORKTREE"
  elif [ "$(printf '%s\n' "$all" | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "CHOOSE_WORKTREE $(printf '%s\n' "$all" | tr '\n' ' ' | sed 's/ *$//')"
    exit "$EXIT_CHOOSE"
  else
    SLUG="$all"
  fi
  WT="$ROOT/worktrees/$SLUG"
  STATE="$ROOT/tmp/npm-run/$SLUG"
}

# read_scripts: SCRIPTS = the keys of "scripts" in the worktree's package.json, one per line.
# `npm pkg get scripts` prints them as JSON, one "key": value per line, two spaces of indent.
read_scripts() {
  local pkg="$WT/package.json" out
  if [ ! -f "$pkg" ] || [ -L "$pkg" ]; then
    echo "NO_PACKAGE_JSON $pkg"
    exit "$EXIT_PACKAGE"
  fi
  if ! out="$(cd "$WT" && npm pkg get scripts 2>/dev/null)"; then
    echo "INVALID_PACKAGE_JSON $pkg"
    exit "$EXIT_PACKAGE"
  fi
  SCRIPTS="$(printf '%s\n' "$out" | sed -n 's/^  "\([^"]*\)": .*/\1/p' | LC_ALL=C sort)"
}

print_scripts() {
  if [ -n "$SCRIPTS" ]; then printf '%s\n' "$SCRIPTS" | sed 's/^/SCRIPT /'; fi
}

# pid_alive <pid>: 0 if that process runs and is an npm we started (its process group leader).
pid_alive() {
  case "$1" in ""|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -p "$1" -o args= 2>/dev/null)" in *npm*) return 0 ;; esac
  return 1
}

install_deps() {
  local log="$STATE/install.log" rc=0 cmd=install
  [ ! -f "$WT/package-lock.json" ] || cmd=ci
  mkdir -p "$STATE"
  (cd "$WT" && npm "$cmd" --no-audit --no-fund) > "$log" 2>&1 < /dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "INSTALL_FAILED $rc $log"
    { echo "--- last 20 lines of $log ---"; tail -n 20 "$log"; } >&2
    exit "$EXIT_INSTALL"
  fi
  echo "INSTALLED $SLUG $log"
}

cmd_run() {
  local want="" install=0 script="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) [ $# -ge 2 ] || die "--worktree needs a value"; want="$2"; shift 2 ;;
      --install)  install=1; shift ;;
      --)         shift; args=("$@"); break ;;
      -*)         die "unknown option: $1" ;;
      *)          [ -z "$script" ] || die "only one script allowed (pass its arguments after --)"; script="$1"; shift ;;
    esac
  done

  resolve_worktree "$want"
  read_scripts
  if [ -z "$script" ]; then
    echo "NO_COMMAND $SLUG"
    print_scripts
    exit "$EXIT_NO_COMMAND"
  fi
  if ! validate_script "$script" || ! printf '%s\n' "$SCRIPTS" | grep -Fxq -- "$script"; then
    echo "UNKNOWN_SCRIPT $SLUG $script"
    print_scripts
    exit "$EXIT_UNKNOWN_SCRIPT"
  fi

  local pid_file="$STATE/$script.pid" log="$STATE/$script.log" pid
  if [ -f "$pid_file" ] && pid="$(cat "$pid_file")" && pid_alive "$pid"; then
    echo "ALREADY_RUNNING $SLUG $script $pid"
    exit "$EXIT_RUNNING"
  fi

  if [ ! -d "$WT/node_modules" ]; then
    if [ "$install" -eq 0 ]; then
      echo "CONFIRM_INSTALL $SLUG"
      exit "$EXIT_CONFIRM_INSTALL"
    fi
    install_deps
  fi

  mkdir -p "$STATE"
  # Job control gives the job its own process group (pgid = pid), so stop can end the whole tree.
  set -m
  if [ "${#args[@]}" -gt 0 ]; then
    (cd "$WT" && exec nohup npm run "$script" -- "${args[@]}") > "$log" 2>&1 < /dev/null &
  else
    (cd "$WT" && exec nohup npm run "$script") > "$log" 2>&1 < /dev/null &
  fi
  pid=$!
  set +m
  echo "$pid" > "$pid_file"

  # A script that fails at once (missing binary, syntax error) is reported here, not as STARTED.
  local rc=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" || rc=$?
    rm -f "$pid_file"
    echo "FINISHED $SLUG $script $rc $log"
    if [ "$rc" -ne 0 ]; then
      { echo "--- last 20 lines of $log ---"; tail -n 20 "$log"; } >&2
      exit "$EXIT_FAILED"
    fi
    return 0
  fi
  disown "$pid" 2>/dev/null || true
  echo "STARTED $SLUG $script $pid $log"
}

cmd_scripts() {
  local want=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) [ $# -ge 2 ] || die "--worktree needs a value"; want="$2"; shift 2 ;;
      *)          die "unknown argument: $1" ;;
    esac
  done
  resolve_worktree "$want"
  read_scripts
  print_scripts
}

# each_pid_file: every <tmp>/npm-run/<repo>/<name>/<script>.pid, as "<slug>\t<script>\t<file>".
each_pid_file() {
  local base="$ROOT/tmp/npm-run" f rel
  [ -d "$base" ] || return 0
  find "$base" -type f -name '*.pid' | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#"$base/"}"
    printf '%s\t%s\t%s\n' "${rel%/*}" "$(basename "$rel" .pid)" "$f"
  done
}

cmd_ps() {
  [ $# -eq 0 ] || die "ps takes no arguments"
  local slug script file pid any=0
  while IFS='	' read -r slug script file; do
    [ -n "$file" ] || continue
    any=1
    pid="$(cat "$file")"
    if pid_alive "$pid"; then
      echo "RUNNING $slug $script $pid ${file%.pid}.log"
    else
      rm -f "$file"
      echo "EXITED $slug $script $pid ${file%.pid}.log"
    fi
  done < <(each_pid_file)
  [ "$any" -eq 1 ] || echo "NONE"
}

# prune_dirs <dir>: remove <dir> and its parents while empty, up to <arness>/tmp (kept).
prune_dirs() {
  local d="$1" top="$ROOT/tmp"
  while [ "$d" != "$top" ]; do
    case "$d" in "$top"/*) ;; *) return 0 ;; esac
    rmdir "$d" 2>/dev/null || return 0
    d="$(dirname "$d")"
  done
}

# forget <pid file>: remove it and its log; when nothing else runs in that worktree, also its install.log
# and the folders left empty.
forget() {
  local file="$1" dir
  dir="$(dirname "$file")"
  rm -f "$file" "${file%.pid}.log"
  if ! ls "$dir"/*.pid >/dev/null 2>&1; then rm -f "$dir/install.log"; fi
  prune_dirs "$dir"
}

# stop_pid <pid>: TERM to its process group, then KILL after 5 s.
stop_pid() {
  local pid="$1"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 50); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

cmd_stop() {
  local want="" only="" all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) [ $# -ge 2 ] || die "--worktree needs a value"; want="$2"; shift 2 ;;
      --all)      all=1; shift ;;
      -*)         die "unknown option: $1" ;;
      *)          [ -z "$only" ] || die "only one script allowed"; only="$1"; shift ;;
    esac
  done
  if [ "$all" -eq 1 ]; then
    if [ -n "$want" ] || [ -n "$only" ]; then die "--all takes no worktree or script"; fi
  else
    [ -n "$want" ] || [ -n "$only" ] || die "stop needs --worktree, a script, or --all"
    [ -z "$want" ] || validate_name "$want" || die "invalid worktree: '$want'"
    [ -z "$only" ] || validate_script "$only" || die "invalid script: '$only'"
  fi

  local slug script file pid any=0
  while IFS='	' read -r slug script file; do
    [ -n "$file" ] || continue
    [ -z "$want" ] || [ "$slug" = "$want" ] || continue
    [ -z "$only" ] || [ "$script" = "$only" ] || continue
    pid="$(cat "$file")"
    if pid_alive "$pid"; then
      stop_pid "$pid"
      echo "STOPPED $slug $script $pid"
      any=1
    fi
    forget "$file"
  done < <(each_pid_file)
  [ "$any" -eq 1 ] || echo "NONE"
}

# cmd_clean [--worktree <slug>]: remove the logs and pid files of what no longer runs, and empty folders.
cmd_clean() {
  local want=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) [ $# -ge 2 ] || die "--worktree needs a value"; want="$2"; shift 2 ;;
      *)          die "unknown argument: $1" ;;
    esac
  done
  [ -z "$want" ] || validate_name "$want" || die "invalid worktree: '$want'"

  local base="$ROOT/tmp/npm-run" f rel slug dir pid any=0 live p
  [ -d "$base" ] || { echo "NONE"; return 0; }
  while IFS= read -r f; do
    rel="${f#"$base/"}"
    slug="${rel%/*}"
    [ -z "$want" ] || [ "$slug" = "$want" ] || continue
    dir="$(dirname "$f")"
    case "$f" in
      *.pid) pid="$(cat "$f")"; if pid_alive "$pid"; then continue; fi ;;
      *.log)
        if [ "$(basename "$f")" = install.log ]; then
          live=0
          for p in "$dir"/*.pid; do
            if [ -f "$p" ] && pid_alive "$(cat "$p")"; then live=1; fi
          done
          [ "$live" -eq 0 ] || continue
        elif [ -f "${f%.log}.pid" ] && pid_alive "$(cat "${f%.log}.pid")"; then
          continue
        fi ;;
      *) continue ;;
    esac
    rm -f "$f"
    echo "CLEANED $slug $(basename "$f")"
    any=1
    prune_dirs "$dir"
  done < <(find "$base" -type f \( -name '*.pid' -o -name '*.log' \) | LC_ALL=C sort)
  [ -n "$want" ] || prune_dirs "$base"
  [ "$any" -eq 1 ] || echo "NONE"
}

main() {
  [ $# -gt 0 ] || die "missing command: run, scripts, ps, stop or clean (-h for help)"
  local cmd="$1"
  shift
  case "$cmd" in
    -h|--help) sed -n '2,44p' "${BASH_SOURCE[0]}"; exit 0 ;;
    run|scripts|ps|stop|clean) ;;
    *) die "unknown command: $cmd" ;;
  esac
  if ! command -v npm >/dev/null 2>&1; then echo "NO_NPM"; exit "$EXIT_NO_NPM"; fi
  command -v git >/dev/null 2>&1 || die "git not found"
  ROOT="$(resolve_root)"
  ROOT="$(cd -P "$ROOT" && pwd -P)"   # git reports physical paths
  case "$cmd" in
    run)     cmd_run "$@" ;;
    scripts) cmd_scripts "$@" ;;
    ps)      cmd_ps "$@" ;;
    stop)    cmd_stop "$@" ;;
    clean)   cmd_clean "$@" ;;
  esac
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
