#!/usr/bin/env bash
# Run an npm script of a worktree in the background, and list, stop or clean up the ones it started.
#
# Usage: npm-run.sh run     [--worktree <repo>/<name>] [--install] <script> [-- <args>...]
#        npm-run.sh wait    [--worktree <repo>/<name>] <script> [--timeout <seconds>]
#        npm-run.sh scripts [--worktree <repo>/<name>]
#        npm-run.sh ps
#        npm-run.sh stop    [--worktree <repo>/<name>] [<script>] | --all
#        npm-run.sh clean   [--worktree <repo>/<name>]
#
# The worktree is one of worktrees/<repo>/<name> made from a repo in source/. Without --worktree, the
# only one there is used; with several, nothing runs and they are listed (CHOOSE_WORKTREE).
# The script must be a key of "scripts" in the package.json at the root of the worktree (read with
# `npm pkg get scripts`). It runs as `npm run <script> [-- <args>]`, cwd = the worktree, in its own
# process group, so stop also ends its children (dev servers, watchers); in Git Bash, with taskkill /T.
# Without node_modules it stops with CONFIRM_INSTALL; --install runs `npm ci` (with package-lock.json)
# or `npm install` first. Logs and pids: <arness>/tmp/npm-run/<repo>/<name>/<script>.{log,pid}.
# A bash wrapper leads the process group (its pid is the one saved): it runs npm, then writes npm's exit
# code to <script>.code, also after npm-run itself returned. A new run removes the old .code first. stop
# kills the wrapper with the group, so a stopped script leaves no .code (stop also removes any it finds).
# A script counts as running while anything of its group runs, also what it left behind (`cmd &`) after npm
# ended, so ps lists it and stop ends it; stop waits for the whole group and sends KILL after 5 s.
# wait polls every second until <script>.code appears; default --timeout 540 s (under the 10 min an agent's
# shell tool allows; 0 waits forever). On TIMEOUT the script keeps running: call wait again.
# With an .nvmrc at the worktree root, install and run use that node version from nvm (NVM_DIR, else ~/.nvm or
# ${XDG_CONFIG_HOME:-~/.config}/nvm) or nvm-windows (NVM_HOME), first in PATH for them only; 22 and 22.x pick
# the highest 22.x installed. With nvm and the version missing: NO_NODE_VERSION; no nvm: a warning.
# stop removes the pid and log of what it stops, and the install.log and folders left empty. A script
# that ended by itself (FINISHED, EXITED) keeps its log until clean removes everything that no longer runs.
#
# Stdout, first word is the status:
#   STARTED <repo>/<name> <script> <pid> <log>     running in the background
#   FINISHED <repo>/<name> <script> <code> <log>   run: ended within the first second (NPM_RUN_QUICK_TENTHS changes it);
#                                                  wait: it ended. Exit 0 only if code 0, else 8 and the last 20 log lines on stderr
#   TIMEOUT <repo>/<name> <script> <pid> <log>     wait: still running after --timeout; it keeps running (exit 15)
#   NOT_STARTED <repo>/<name> <script>             wait: not started there, or stopped or cleaned since (exit 16)
#   NO_CODE <repo>/<name> <script> <log>           wait: ended without saving its code (killed outside stop) (exit 17)
#   NODE <repo>/<name> <version>                   the .nvmrc node runs, from nvm or the current one (before CONFIRM_INSTALL / INSTALLED / STARTED / FINISHED)
#   NODE_UNRESOLVED <repo>/<name> <alias>          .nvmrc alias not resolved (lts/*, node): the current node runs (same place)
#   INSTALLED <repo>/<name> <log>                  dependencies installed (before STARTED)
#   SCRIPT <name>                                  one per available script (scripts, NO_COMMAND,
#                                                  UNKNOWN_SCRIPT)
#   RUNNING <repo>/<name> <script> <pid> <log>     ps: still running
#   EXITED <repo>/<name> <script> <pid> <log> [<code>]  ps: no longer running (its pid file is removed); <code>
#                                                  last, when it saved one
#   STOPPED <repo>/<name> <script> <pid>           stop (its pid, log and code are removed)
#   STOP_FAILED <repo>/<name> <script> <pid>       stop could not end its process tree; pid kept (exit 14)
#   CLEANED <repo>/<name> <file>                   clean: a log, code or stale pid file removed
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
#   NO_NODE_VERSION <repo>/<name> <version>        .nvmrc version neither in nvm nor current (exit 13); no nvm: a warning
#   ALREADY_RUNNING <repo>/<name> <script> <pid>   that script already runs there (exit 9)
#   NO_NPM                                         npm not found (exit 3)
# Exit codes: 0 ok, 2 invalid usage, 3 no npm, 4 no worktree, 5 no command, 6 package.json,
# 7 unknown script, 8 script failed at start, 9 already running, 10 choose worktree,
# 11 confirm install, 12 install failed, 13 node version of .nvmrc not installed, 14 stop failed,
# 15 wait timed out, 16 wait: not started, 17 wait: no exit code saved.
set -euo pipefail

EXIT_USAGE=2 EXIT_NO_NPM=3 EXIT_NO_WORKTREE=4 EXIT_NO_COMMAND=5 EXIT_PACKAGE=6 EXIT_UNKNOWN_SCRIPT=7
EXIT_FAILED=8 EXIT_RUNNING=9 EXIT_CHOOSE=10 EXIT_CONFIRM_INSTALL=11 EXIT_INSTALL=12
EXIT_NODE_VERSION=13 EXIT_STOP_FAILED=14 EXIT_TIMEOUT=15 EXIT_NOT_STARTED=16 EXIT_NO_CODE=17
WAIT_TIMEOUT=540

# Leader of the script's process group: runs npm run, saves its exit code (via a .tmp, so a reader never
# sees half a file; removed when the save fails) and exits with it. $1 is the code file; the rest are npm
# run's arguments. Its command line has "npm run", so pid_alive knows it; a TERM to the group kills it
# before it writes anything.
# shellcheck disable=SC2016 # expanded by the wrapper bash, not here
WRAPPER='c="$1"; shift; npm run "$@"; rc=$?; { echo "$rc" > "$c.tmp" && mv -f "$c.tmp" "$c"; } || rm -f "$c.tmp"; exit "$rc"'

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

need_npm() {
  if ! command -v npm >/dev/null 2>&1; then echo "NO_NPM"; exit "$EXIT_NO_NPM"; fi
}

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
    # Git for Windows lists worktrees as C:/Users/..., while the shell gives /c/Users/...
    if command -v cygpath >/dev/null 2>&1; then
      prefix="$(cygpath -m "$prefix")" || { echo "warning: cygpath cannot convert $ROOT/worktrees/$repo/; $repo not listed" >&2; continue; }
    fi
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

# pid_alive <pid>: 0 if something we started still runs in that process group. <pid> is its leader, the
# wrapper that runs npm. While the leader exists it must be ours: its command line has npm (the wrapper's
# "npm run"), or it is a zombie ("<defunct>", ps prints no arguments then). Once it is gone, its group lives
# on while any process it left runs (a `cmd &` in the script), and no new process gets that pid while the
# group exists, so the group is still ours.
pid_alive() {
  case "$1" in ""|*[!0-9]*) return 1 ;; esac
  if kill -0 "$1" 2>/dev/null; then
    case "$(proc_args "$1")" in *npm*|*defunct*) return 0 ;; esac
    return 1
  fi
  kill -0 -- "-$1" 2>/dev/null
}

# group_alive <pid>: 0 while any process of the group led by <pid> runs (zombies included); the leader
# alone where a group cannot be signalled.
group_alive() {
  kill -0 -- "-$1" 2>/dev/null || kill -0 "$1" 2>/dev/null
}

# read_pid <file>: its content, or nothing when it cannot be read (removed meanwhile by another npm-run).
read_pid() {
  cat "$1" 2>/dev/null || true
}

# proc_args <pid>: its command line. ps first (Linux, macOS: a leader that is a zombie shows as
# [bash] <defunct>, so pid_alive still takes it as ours and stop ends its group); /proc when ps cannot (the
# ps of Git Bash has no -o, slim images have no ps).
proc_args() {
  if ps -p "$1" -o args= 2>/dev/null; then return 0; fi
  if [ -r "/proc/$1/cmdline" ]; then tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline"; fi
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

# nvm_dirs: the nvm folders, one per line: NVM_DIR when set; else ~/.nvm and the XDG one, since the agent's
# shell may not load the profile that exports NVM_DIR.
nvm_dirs() {
  if [ -n "${NVM_DIR:-}" ]; then
    printf '%s\n' "$NVM_DIR"
  else
    printf '%s\n' "$HOME/.nvm" "${XDG_CONFIG_HOME:-$HOME/.config}/nvm"
  fi
}

# nvm_installed: 0 with nvm-windows (NVM_HOME set) or nvm (nvm.sh or versions/node in one of nvm_dirs).
nvm_installed() {
  local d
  [ -z "${NVM_HOME:-}" ] || return 0
  while IFS= read -r d; do
    if [ -e "$d/nvm.sh" ] || [ -d "$d/versions/node" ]; then return 0; fi
  done < <(nvm_dirs)
  return 1
}

# node_dir <version>: "<version><TAB><folder>" of the highest installed node that is <version> or starts with
# <version> (22 matches 22.17.1, not 2). Looks in nvm (nvm_dirs: <dir>/versions/node/v<x>/bin)
# and nvm-windows (NVM_HOME: <dir>/v<x>; a different `root:` in its settings.txt is not read). Fails when
# no installed version matches.
node_dir() {
  local want="$1" base d v
  {
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      if command -v cygpath >/dev/null 2>&1; then base="$(cygpath -u "$base")" || continue; fi
      for d in "$base"/v*; do
        v="${d##*/v}"
        case "$v" in "$want"|"$want".*) ;; *) continue ;; esac
        if [ -d "$d/bin" ]; then d="$d/bin"; fi
        if [ -x "$d/node" ] || [ -x "$d/node.exe" ]; then printf '%s\t%s\n' "$v" "$d"; fi
      done
    done < <(nvm_dirs | sed 's#$#/versions/node#'; printf '%s\n' "${NVM_HOME:-}")
  } | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | grep .
}

# use_nvmrc: when the worktree has an .nvmrc, put that node version first in PATH for install and the
# script (the global node is left alone). Sets NODE_LINE to "NODE <slug> <version>" when that version runs
# (from nvm, or the current node when it matches), or to "NODE_UNRESOLVED <slug> <alias>" for an alias
# (lts/*, node), which is not resolved; and NODE_MISSING to the version when nvm is installed but neither it
# nor the current node has it (cmd_run stops with NO_NODE_VERSION after the script checks). Without nvm,
# a version the current node does not match: a warning on stderr, and the current node runs.
use_nvmrc() {
  local file="$WT/.nvmrc" raw want found have home bom=$'\xef\xbb\xbf' tab=$'\t'
  NODE_LINE="" NODE_MISSING=""
  [ -f "$file" ] || return 0
  # First field of the first non-empty line, without a UTF-8 BOM, a # comment or CR (Windows editors write
  # them). awk reads all its input: an `exit` would kill tr with SIGPIPE on a big file (CODESTYLE, Pitfalls).
  raw="$(LC_ALL=C sed -e "s/^$bom//" -e 's/#.*//' "$file" | tr -d '\r' | awk 'NF && !d { print $1; d=1 }')"
  if [ -z "$raw" ]; then
    echo "note: .nvmrc has no version; using the current node" >&2
    return 0
  fi
  want="${raw#v}"
  # 22.x is 22, 22.17.x is 22.17.
  while :; do
    case "$want" in *.x|*.X) want="${want%.?}" ;; *) break ;; esac
  done
  # Nothing left (v, .x): not a version, report it like an alias.
  if [ -z "$want" ]; then want="$raw"; fi
  case "$want" in
    .*|*.|*..*|*[!0-9.]*)
      echo "note: .nvmrc asks for '$want', an alias npm-run does not resolve; using the current node" >&2
      NODE_LINE="NODE_UNRESOLVED $SLUG $want"
      return 0 ;;
  esac
  if found="$(node_dir "$want")"; then
    PATH="${found#*"$tab"}:$PATH"
    NODE_LINE="NODE $SLUG ${found%%"$tab"*}"
    return 0
  fi
  if [ -n "${NVM_HOME:-}" ]; then
    home="$NVM_HOME"
    if command -v cygpath >/dev/null 2>&1; then home="$(cygpath -u "$home")" || home="$NVM_HOME"; fi
    if ! ls -d "$home"/v* >/dev/null 2>&1; then
      echo "note: NVM_HOME ($NVM_HOME) has no node versions; nvm-windows may keep them under the root: of its settings.txt" >&2
    fi
  fi
  have="$(node --version 2>/dev/null)" || have=""
  have="${have#v}"
  case "$have" in "$want"|"$want".*) NODE_LINE="NODE $SLUG $have"; return 0 ;; esac
  # Without nvm (node from a package manager, fnm, volta...) there is nothing to switch to or install with.
  if ! nvm_installed; then
    echo "warning: .nvmrc asks for node $want and there is no nvm; using the current node ${have:-(none)}" >&2
    return 0
  fi
  NODE_MISSING="$want"
}

# no_node_version: stop with NO_NODE_VERSION when use_nvmrc found that nvm lacks the .nvmrc version.
no_node_version() {
  [ -n "$NODE_MISSING" ] || return 0
  echo "NO_NODE_VERSION $SLUG $NODE_MISSING"
  exit "$EXIT_NODE_VERSION"
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
  # The .nvmrc node first in PATH, since npm may only be reachable through nvm. A version nvm lacks is
  # reported after the script checks (listing the scripts needs no node version) and before the install
  # question; first only when there is no npm to read the scripts with.
  use_nvmrc
  if ! command -v npm >/dev/null 2>&1; then no_node_version; fi
  need_npm
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

  local pid_file="$STATE/$script.pid" log="$STATE/$script.log" code_file="$STATE/$script.code" pid
  if [ -f "$pid_file" ] && pid="$(read_pid "$pid_file")" && pid_alive "$pid"; then
    echo "ALREADY_RUNNING $SLUG $script $pid"
    exit "$EXIT_RUNNING"
  fi
  no_node_version

  if [ ! -d "$WT/node_modules" ]; then
    if [ "$install" -eq 0 ]; then
      # The .nvmrc line first: the install question must say which node it would use, or that it is not checked.
      if [ -n "$NODE_LINE" ]; then echo "$NODE_LINE"; fi
      echo "CONFIRM_INSTALL $SLUG"
      exit "$EXIT_CONFIRM_INSTALL"
    fi
    [ -z "$NODE_LINE" ] || echo "$NODE_LINE"
    install_deps
  elif [ -n "$NODE_LINE" ]; then
    echo "$NODE_LINE"
  fi

  mkdir -p "$STATE"
  # The code of an earlier run would make wait answer at once with an old result.
  rm -f "$code_file" "$code_file.tmp"
  # Job control gives the job its own process group (pgid = pid), so stop can end the whole tree.
  set -m
  if [ "${#args[@]}" -gt 0 ]; then
    (cd "$WT" && exec nohup "$BASH" -c "$WRAPPER" npm-run "$code_file" "$script" -- "${args[@]}") > "$log" 2>&1 < /dev/null &
  else
    (cd "$WT" && exec nohup "$BASH" -c "$WRAPPER" npm-run "$code_file" "$script") > "$log" 2>&1 < /dev/null &
  fi
  pid=$!
  set +m
  echo "$pid" > "$pid_file"

  # A script that fails at once (missing binary, syntax error) is reported here, not as STARTED.
  local rc=0 tenths="${NPM_RUN_QUICK_TENTHS:-10}"
  case "$tenths" in ""|*[!0-9]*) tenths=10 ;; esac
  for _ in $(seq "$tenths"); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" || rc=$?
    # Keep the pid while something the script left (a `cmd &`) still runs in its group, so ps lists it
    # and stop can end it.
    if ! kill -0 -- "-$pid" 2>/dev/null; then rm -f "$pid_file"; fi
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

# read_code <file>: the exit code saved in <file>, or fails when there is none (missing or not a number).
read_code() {
  local code
  [ -f "$1" ] || return 1
  code="$(cat "$1" 2>/dev/null)" || return 1
  case "$code" in ""|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$code"
}

# cmd_wait [--worktree <slug>] <script> [--timeout <seconds>]: block until that script ends and report its code.
cmd_wait() {
  local want="" script="" limit="$WAIT_TIMEOUT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) [ $# -ge 2 ] || die "--worktree needs a value"; want="$2"; shift 2 ;;
      --timeout)  [ $# -ge 2 ] || die "--timeout needs a value"; limit="$2"; shift 2 ;;
      -*)         die "unknown option: $1" ;;
      *)          [ -z "$script" ] || die "only one script allowed"; script="$1"; shift ;;
    esac
  done
  [ -n "$script" ] || die "wait needs a script"
  validate_script "$script" || die "invalid script: '$script'"
  case "$limit" in ""|*[!0-9]*) die "invalid --timeout: '$limit' (seconds, 0 for none)" ;; esac
  resolve_worktree "$want"

  local pid_file="$STATE/$script.pid" log="$STATE/$script.log" code_file="$STATE/$script.code"
  local pid code start="$SECONDS"
  while :; do
    if code="$(read_code "$code_file")"; then
      echo "FINISHED $SLUG $script $code $log"
      if [ "$code" -ne 0 ]; then
        { echo "--- last 20 lines of $log ---"; tail -n 20 "$log" 2>/dev/null || true; } >&2
        exit "$EXIT_FAILED"
      fi
      return 0
    fi
    pid=""
    if [ -f "$pid_file" ]; then pid="$(read_pid "$pid_file")"; fi
    if ! pid_alive "$pid"; then
      # The wrapper writes the code before it exits: look once more, in case it ended just now.
      if read_code "$code_file" >/dev/null; then continue; fi
      if [ -n "$pid" ] || [ -f "$log" ]; then
        echo "NO_CODE $SLUG $script $log"
        exit "$EXIT_NO_CODE"
      fi
      echo "NOT_STARTED $SLUG $script"
      exit "$EXIT_NOT_STARTED"
    fi
    if [ "$limit" -gt 0 ] && [ $((SECONDS - start)) -ge "$limit" ]; then
      echo "TIMEOUT $SLUG $script $pid $log"
      exit "$EXIT_TIMEOUT"
    fi
    sleep 1
  done
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
  local slug script file pid code any=0
  while IFS='	' read -r slug script file; do
    [ -n "$file" ] || continue
    any=1
    pid="$(read_pid "$file")"
    if pid_alive "$pid"; then
      echo "RUNNING $slug $script $pid ${file%.pid}.log"
    else
      rm -f "$file"
      # The code goes last, so the fields before it keep their place for whoever parses them.
      if code="$(read_code "${file%.pid}.code")"; then
        echo "EXITED $slug $script $pid ${file%.pid}.log $code"
      else
        echo "EXITED $slug $script $pid ${file%.pid}.log"
      fi
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

# forget <pid file>: remove it, its log and code; when nothing else runs in that worktree, also its
# install.log and the folders left empty.
forget() {
  local file="$1" dir
  dir="$(dirname "$file")"
  rm -f "$file" "${file%.pid}.log" "${file%.pid}.code" "${file%.pid}.code.tmp"
  if ! ls "$dir"/*.pid >/dev/null 2>&1; then rm -f "$dir/install.log"; fi
  prune_dirs "$dir"
}

# stop_pid <pid>: TERM to its process group, then KILL after 5 s. Returns 1 when it cannot end the tree.
stop_pid() {
  local pid="$1" out rc=0
  # Git Bash (Windows): end the Windows process tree first. When an MSYS shell stays as the parent of a
  # native node (a script like `sh -c "node server.js; exit 0"`), TERM to the group does not reach node,
  # and TERM first would leave taskkill without the root of the tree. Console processes have no clean
  # shutdown here: taskkill refuses without /F. MSYS2_ARG_CONV_EXCL keeps /T /F as they are, also when
  # the user exported MSYS_NO_PATHCONV. Exit 128: that process no longer exists.
  if [ -r "/proc/$pid/winpid" ] && command -v taskkill >/dev/null 2>&1; then
    out="$(MSYS2_ARG_CONV_EXCL='*' taskkill /T /F /PID "$(cat "/proc/$pid/winpid")" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 128 ]; then
      echo "warning: taskkill could not end the process tree of $pid: $out" >&2
      return 1
    fi
  fi
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  # Wait for the whole group, not the leader: the wrapper dies at once with TERM, while a child that traps
  # or ignores it would keep running.
  for _ in $(seq 50); do
    group_alive "$pid" || return 0
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

  local slug script file pid any=0 failed=0
  while IFS='	' read -r slug script file; do
    [ -n "$file" ] || continue
    [ -z "$want" ] || [ "$slug" = "$want" ] || continue
    [ -z "$only" ] || [ "$script" = "$only" ] || continue
    pid="$(read_pid "$file")"
    if pid_alive "$pid"; then
      any=1
      if ! stop_pid "$pid"; then
        # Part of it may still run: keep its pid file, so stop can be retried.
        echo "STOP_FAILED $slug $script $pid"
        failed=1
        continue
      fi
      echo "STOPPED $slug $script $pid"
    fi
    forget "$file"
  done < <(each_pid_file)
  [ "$any" -eq 1 ] || echo "NONE"
  if [ "$failed" -eq 1 ]; then exit "$EXIT_STOP_FAILED"; fi
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
      *.pid) pid="$(read_pid "$f")"; if pid_alive "$pid"; then continue; fi ;;
      *.log)
        if [ "$(basename "$f")" = install.log ]; then
          live=0
          for p in "$dir"/*.pid; do
            if [ -f "$p" ] && pid_alive "$(read_pid "$p")"; then live=1; fi
          done
          [ "$live" -eq 0 ] || continue
        elif [ -f "${f%.log}.pid" ] && pid_alive "$(read_pid "${f%.log}.pid")"; then
          continue
        fi ;;
      *.code|*.code.tmp)
        p="${f%.tmp}"
        if [ -f "${p%.code}.pid" ] && pid_alive "$(read_pid "${p%.code}.pid")"; then continue; fi ;;
      *) continue ;;
    esac
    rm -f "$f"
    echo "CLEANED $slug $(basename "$f")"
    any=1
    prune_dirs "$dir"
  done < <(find "$base" -type f \( -name '*.pid' -o -name '*.log' -o -name '*.code' -o -name '*.code.tmp' \) \
    | LC_ALL=C sort)
  [ -n "$want" ] || prune_dirs "$base"
  [ "$any" -eq 1 ] || echo "NONE"
}

main() {
  [ $# -gt 0 ] || die "missing command: run, wait, scripts, ps, stop or clean (-h for help)"
  local cmd="$1"
  shift
  case "$cmd" in
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    run|wait|scripts|ps|stop|clean) ;;
    *) die "unknown command: $cmd" ;;
  esac
  # Only run and scripts call npm; run checks it itself, after putting the .nvmrc node first in PATH.
  [ "$cmd" != scripts ] || need_npm
  command -v git >/dev/null 2>&1 || die "git not found"
  ROOT="$(resolve_root)"
  ROOT="$(cd -P "$ROOT" && pwd -P)"   # git reports physical paths
  case "$cmd" in
    run)     cmd_run "$@" ;;
    wait)    cmd_wait "$@" ;;
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
