#!/usr/bin/env bats
# Unit tests for skills/npm-run/scripts/npm-run.sh.
# Each test builds a throwaway ARNESS_ROOT with local repos and worktrees. npm runs for real, offline,
# on scripts that only echo, sleep or exit: no network and no dependencies.

load ../../../tests/helpers

SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/npm-run.sh"

git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

mk_repo() {
  mkdir -p "$ARNESS_ROOT/source/$1"
  git_q init -q "$ARNESS_ROOT/source/$1"
  echo 1 > "$ARNESS_ROOT/source/$1/f.txt"
  git_q -C "$ARNESS_ROOT/source/$1" add f.txt
  git_q -C "$ARNESS_ROOT/source/$1" commit -q -m c1
}

# mk_wt <repo> <name>: a worktree with a package.json and node_modules, laid out like worktree-create.
mk_wt() {
  git_q -C "$ARNESS_ROOT/source/$1" worktree add -q -b "$2" "$ARNESS_ROOT/worktrees/$1/$2" main
  cat > "$ARNESS_ROOT/worktrees/$1/$2/package.json" <<'EOF'
{
  "name": "fixture",
  "version": "1.0.0",
  "scripts": {
    "ok": "echo ran-ok",
    "fail": "echo boom && exit 3",
    "echo": "echo",
    "serve": "sleep 30",
    "build:prod": "echo prod"
  }
}
EOF
  mkdir -p "$ARNESS_ROOT/worktrees/$1/$2/node_modules"
}

WT() { echo "$ARNESS_ROOT/worktrees/$1"; }
state() { echo "$ARNESS_ROOT/tmp/npm-run/$1"; }

# dead_pid: the pid of a process that has already ended and been reaped, so nothing runs with it.
dead_pid() {
  local p
  sh -c 'exit 0' &
  p=$!
  wait "$p" || true
  echo "$p"
}

# group_pids <pgid>: the processes in that process group. Git Bash has no pgrep, but its ps prints the
# PGID as the third column, after a status letter (S, I, O) in front of stopped or waiting processes.
group_pids() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -g "$1" || true
  else
    ps | awk -v g="$1" 'NR > 1 { sub(/^[^ 0-9]/, " ") } NR > 1 && $3 == g { print $1 }'
  fi
}

setup() {
  command -v npm >/dev/null 2>&1 || skip "npm not installed"
  TMP="$(mktemp -d)"
  TMP="$(cd -P "$TMP" && pwd -P)"
  export ARNESS_ROOT="$TMP/root"
  export npm_config_offline=true npm_config_update_notifier=false
  # `run` calls a script FINISHED only if it ends within the first second; a slow CI runner takes longer
  # to start npm. Give it 3 s (a long-running script like `serve` just costs the full wait).
  export NPM_RUN_QUICK_TENTHS=30
  mkdir -p "$ARNESS_ROOT/source" "$ARNESS_ROOT/worktrees"
  mk_repo a
  mk_wt a feat/x
}

teardown() {
  [ -n "${TMP:-}" ] || return 0
  ARNESS_ROOT="$TMP/root" "$SCRIPT" stop --all >/dev/null 2>&1 || true
  # A node left alive by a failed native node test (Git Bash) would hold the whole run open.
  if [ -n "${NODE_PID:-}" ]; then MSYS2_ARG_CONV_EXCL='*' taskkill /T /F /PID "$NODE_PID" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
}

# --- worktree ----------------------------------------------------------------------

@test "the only worktree is used when none is given" {
  run "$SCRIPT" run ok
  [ "$status" -eq 0 ]
  [ "$output" = "FINISHED a/feat/x ok 0 $(state a/feat/x)/ok.log" ]
  grep -q ran-ok "$(state a/feat/x)/ok.log"
}

@test "CHOOSE_WORKTREE lists every worktree when there are several" {
  mk_repo b
  mk_wt b PROJ-1
  mk_wt a feat/y
  run "$SCRIPT" run ok
  [ "$status" -eq 10 ]
  [ "$output" = "CHOOSE_WORKTREE a/feat/x a/feat/y b/PROJ-1" ]
  run "$SCRIPT" run --worktree b/PROJ-1 ok
  [ "$status" -eq 0 ]
  [[ "$output" == "FINISHED b/PROJ-1 ok 0 "* ]]
}

@test "NO_WORKTREE without worktrees" {
  rm -rf "$ARNESS_ROOT/source/a" "$ARNESS_ROOT/worktrees/a"
  run "$SCRIPT" run ok
  [ "$status" -eq 4 ]
  [ "$output" = "NO_WORKTREE" ]
}

@test "NOT_FOUND for an unknown worktree or a plain folder" {
  run "$SCRIPT" run --worktree a/nope ok
  [ "$status" -eq 4 ]
  [ "$output" = "NOT_FOUND a/nope" ]
  mkdir -p "$ARNESS_ROOT/worktrees/a/plain"
  run "$SCRIPT" run --worktree a/plain ok
  [ "$status" -eq 4 ]
}

@test "unsafe worktree slugs are rejected" {
  for s in a a/../x ../a/x /a/x 'a b/x' a/-x; do
    run "$SCRIPT" run --worktree "$s" ok
    [ "$status" -eq 2 ]
  done
}

# --- package.json and scripts ------------------------------------------------------

@test "NO_PACKAGE_JSON without a package.json at the worktree root" {
  rm "$(WT a/feat/x)/package.json"
  mkdir -p "$(WT a/feat/x)/sub" && echo '{"scripts":{"ok":"echo"}}' > "$(WT a/feat/x)/sub/package.json"
  run "$SCRIPT" run ok
  [ "$status" -eq 6 ]
  [ "$output" = "NO_PACKAGE_JSON $(WT a/feat/x)/package.json" ]
}

@test "INVALID_PACKAGE_JSON when npm cannot read it" {
  echo 'not json' > "$(WT a/feat/x)/package.json"
  run "$SCRIPT" run ok
  [ "$status" -eq 6 ]
  [ "$output" = "INVALID_PACKAGE_JSON $(WT a/feat/x)/package.json" ]
}

@test "NO_COMMAND lists the available scripts" {
  run "$SCRIPT" run
  [ "$status" -eq 5 ]
  [ "${lines[0]}" = "NO_COMMAND a/feat/x" ]
  [ "${lines[1]}" = "SCRIPT build:prod" ]
  [ "${#lines[@]}" -eq 6 ]
}

@test "UNKNOWN_SCRIPT fails for anything not in scripts, also npm built-ins" {
  for s in nope install test 'ok;rm' '../ok' 'build'; do
    run "$SCRIPT" run "$s"
    [ "$status" -eq 7 ]
    [ "${lines[0]}" = "UNKNOWN_SCRIPT a/feat/x $s" ]
  done
  [ ! -d "$(state a/feat/x)" ]
  run "$SCRIPT" run -ok
  [ "$status" -eq 2 ]
}

@test "scripts with : in the name work" {
  run "$SCRIPT" run build:prod
  [ "$status" -eq 0 ]
  grep -q prod "$(state a/feat/x)/build:prod.log"
}

@test "scripts lists the scripts of the worktree" {
  run "$SCRIPT" scripts --worktree a/feat/x
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "SCRIPT build:prod" ]
  [ "${lines[4]}" = "SCRIPT serve" ]
}

# --- dependencies --------------------------------------------------------------------

@test "CONFIRM_INSTALL without node_modules; nothing runs" {
  rmdir "$(WT a/feat/x)/node_modules"
  run "$SCRIPT" run ok
  [ "$status" -eq 11 ]
  [ "$output" = "CONFIRM_INSTALL a/feat/x" ]
  [ ! -e "$(state a/feat/x)/ok.log" ]
}

@test "--install installs the dependencies, then runs" {
  rmdir "$(WT a/feat/x)/node_modules"
  run "$SCRIPT" run --install ok
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "INSTALLED a/feat/x $(state a/feat/x)/install.log" ]
  [[ "${lines[1]}" == "FINISHED a/feat/x ok 0 "* ]]
}

# --- running -------------------------------------------------------------------------

@test "arguments after -- reach the script" {
  run "$SCRIPT" run echo -- --flag "two words"
  [ "$status" -eq 0 ]
  grep -q -- '--flag two words' "$(state a/feat/x)/echo.log"
}

@test "a script that fails at once reports FINISHED with its code and exits 8" {
  run "$SCRIPT" run fail
  [ "$status" -eq 8 ]
  [ "${lines[0]}" = "FINISHED a/feat/x fail 3 $(state a/feat/x)/fail.log" ]
  [[ "$output" == *boom* ]]
  [ ! -e "$(state a/feat/x)/fail.pid" ]
}

@test "a long script runs in the background with its pid saved" {
  run "$SCRIPT" run serve
  [ "$status" -eq 0 ]
  [[ "$output" == "STARTED a/feat/x serve "* ]]
  pid="$(cat "$(state a/feat/x)/serve.pid")"
  kill -0 "$pid"

  run "$SCRIPT" run serve
  [ "$status" -eq 9 ]
  [ "$output" = "ALREADY_RUNNING a/feat/x serve $pid" ]

  run "$SCRIPT" ps
  [ "$output" = "RUNNING a/feat/x serve $pid $(state a/feat/x)/serve.log" ]
}

@test "stop ends the script and its children" {
  "$SCRIPT" run serve >/dev/null
  pid="$(cat "$(state a/feat/x)/serve.pid")"
  sleep 0.5
  [ -n "$(group_pids "$pid")" ]

  run "$SCRIPT" stop --worktree a/feat/x serve
  [ "$status" -eq 0 ]
  [ "$output" = "STOPPED a/feat/x serve $pid" ]
  sleep 0.3
  [ -z "$(group_pids "$pid")" ]
  [ ! -e "$(state a/feat/x)/serve.pid" ]

  run "$SCRIPT" ps
  [ "$output" = "NONE" ]
}

@test "stop ends the Windows process tree with taskkill in Git Bash, also with MSYS_NO_PATHCONV=1" {
  [ -r "/proc/$$/winpid" ] || skip "only Git Bash (Windows) has /proc/<pid>/winpid"
  local real
  real="$(command -v taskkill)"
  mkdir -p "$TMP/tkbin"
  # taskkill that logs its arguments, then runs the real one
  cat > "$TMP/tkbin/taskkill" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/taskkill.log"
exec "$real" "\$@"
EOF
  chmod +x "$TMP/tkbin/taskkill"
  export PATH="$TMP/tkbin:$PATH"
  "$SCRIPT" run serve >/dev/null
  pid="$(cat "$(state a/feat/x)/serve.pid")"
  winpid="$(cat "/proc/$pid/winpid")"

  run env MSYS_NO_PATHCONV=1 "$SCRIPT" stop --worktree a/feat/x serve
  [ "$status" -eq 0 ]
  [ "$output" = "STOPPED a/feat/x serve $pid" ]
  grep -qx "/T /F /PID $winpid" "$TMP/taskkill.log"
}

@test "stop ends a native node an MSYS shell keeps as its parent, also with MSYS_NO_PATHCONV=1" {
  [ -r "/proc/$$/winpid" ] || skip "only Git Bash (Windows) has /proc/<pid>/winpid"
  local wt
  wt="$(WT a/feat/x)"
  # sh stays as the parent of node: the `exit 0` after it keeps sh from replacing itself with node.
  # A TERM to the group ends sh but not node; only taskkill /T ends both.
  printf '%s\n' "require('fs').writeFileSync('node.pid', String(process.pid)); setInterval(function () {}, 1000);" > "$wt/server.js"
  printf '%s\n' 'node server.js' 'exit 0' > "$wt/tree.sh"
  cat > "$wt/package.json" <<'EOF'
{ "name": "fixture", "version": "1.0.0", "scripts": { "tree": "sh tree.sh" } }
EOF
  "$SCRIPT" run tree >/dev/null
  for _ in $(seq 100); do
    if [ -s "$wt/node.pid" ]; then break; fi
    sleep 0.1
  done
  NODE_PID="$(cat "$wt/node.pid")"

  run env MSYS_NO_PATHCONV=1 "$SCRIPT" stop --worktree a/feat/x tree
  [ "$status" -eq 0 ]
  [[ "$output" == "STOPPED a/feat/x tree "* ]]
  # 128: no such process. 0 would mean node was still alive (it is ended here, then).
  run env MSYS2_ARG_CONV_EXCL='*' taskkill /F /PID "$NODE_PID"
  [ "$status" -eq 128 ]
}

@test "stop reports STOP_FAILED and keeps the pid when taskkill cannot end the tree" {
  [ -r "/proc/$$/winpid" ] || skip "only Git Bash (Windows) has /proc/<pid>/winpid"
  mkdir -p "$TMP/tkbin"
  printf '#!/usr/bin/env bash\necho "access denied" >&2\nexit 1\n' > "$TMP/tkbin/taskkill"
  chmod +x "$TMP/tkbin/taskkill"
  "$SCRIPT" run serve >/dev/null
  pid="$(cat "$(state a/feat/x)/serve.pid")"

  PATH="$TMP/tkbin:$PATH" run "$SCRIPT" stop --worktree a/feat/x serve
  [ "$status" -eq 14 ]
  [[ "$output" == *"STOP_FAILED a/feat/x serve $pid"* ]]
  [[ "$output" == *"warning: taskkill could not end the process tree of $pid: access denied"* ]]
  [[ "$output" != *"STOPPED"* ]]
  [ -e "$(state a/feat/x)/serve.pid" ]
  # The real taskkill ends it, and the pid kept lets stop do it.
  run "$SCRIPT" stop --worktree a/feat/x serve
  [ "$status" -eq 0 ]
  [ "$output" = "STOPPED a/feat/x serve $pid" ]
}

@test "stop still finds its npm through /proc when ps cannot print it" {
  [ -d /proc/self ] || skip "no /proc here"
  mkdir -p "$TMP/psbin"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/psbin/ps"
  chmod +x "$TMP/psbin/ps"
  "$SCRIPT" run serve >/dev/null
  pid="$(cat "$(state a/feat/x)/serve.pid")"

  PATH="$TMP/psbin:$PATH" run "$SCRIPT" stop --worktree a/feat/x serve
  [ "$status" -eq 0 ]
  [ "$output" = "STOPPED a/feat/x serve $pid" ]
}

@test "worktrees are matched through cygpath when it exists" {
  fake_cygpath ok
  run "$SCRIPT" run ok
  [ "$status" -eq 0 ]
  [[ "$output" == "FINISHED a/feat/x ok 0 "* ]]
  grep -q -- '^-m .*/worktrees/a/$' "$CYGPATH_LOG"
}

@test "a repo whose worktrees dir cygpath cannot convert is left out with a warning" {
  fake_cygpath fail
  run "$SCRIPT" run ok
  [ "$status" -eq 4 ]
  [[ "$output" == *"warning: cygpath cannot convert "*"/worktrees/a/; a not listed"* ]]
  [[ "$output" == *NO_WORKTREE ]]
}

@test "ps reports EXITED for a dead pid and forgets it" {
  mkdir -p "$(state a/feat/x)"
  dead="$(dead_pid)"
  echo "$dead" > "$(state a/feat/x)/serve.pid"
  run "$SCRIPT" ps
  [ "$output" = "EXITED a/feat/x serve $dead $(state a/feat/x)/serve.log" ]
  run "$SCRIPT" ps
  [ "$output" = "NONE" ]
}

@test "stop never kills a pid that is not an npm it started" {
  sleep 30 &
  other=$!
  mkdir -p "$(state a/feat/x)"
  echo "$other" > "$(state a/feat/x)/serve.pid"
  run "$SCRIPT" stop --all
  [ "$output" = "NONE" ]
  kill -0 "$other"
  kill "$other"
  wait "$other" 2>/dev/null || true
}

@test "stop removes its pid, log, install.log and the folders left empty" {
  rm -rf "$(WT a/feat/x)/node_modules"
  "$SCRIPT" run --install serve >/dev/null
  [ -f "$(state a/feat/x)/install.log" ]
  run "$SCRIPT" stop --worktree a/feat/x serve
  [ "$status" -eq 0 ]
  [ ! -e "$ARNESS_ROOT/tmp/npm-run" ]
  [ -d "$ARNESS_ROOT/tmp" ]
}

@test "stop keeps the files of another script still running in the worktree" {
  (cd "$(WT a/feat/x)" && npm pkg set scripts.watch="sleep 30" >/dev/null)
  "$SCRIPT" run serve >/dev/null
  "$SCRIPT" run watch >/dev/null
  echo log > "$(state a/feat/x)/install.log"
  run "$SCRIPT" stop --worktree a/feat/x serve
  [ "$status" -eq 0 ]
  [ ! -e "$(state a/feat/x)/serve.pid" ]
  [ ! -e "$(state a/feat/x)/serve.log" ]
  [ -f "$(state a/feat/x)/watch.pid" ]
  [ -f "$(state a/feat/x)/install.log" ]
}

@test "a FINISHED script keeps its log until clean" {
  run "$SCRIPT" run ok
  [ "$status" -eq 0 ]
  [ -f "$(state a/feat/x)/ok.log" ]
  [ "$(cat "$(state a/feat/x)/ok.code")" = 0 ]
  run "$SCRIPT" clean
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "CLEANED a/feat/x ok.code" ]
  [ "${lines[1]}" = "CLEANED a/feat/x ok.log" ]
  [ "${#lines[@]}" -eq 2 ]
  [ ! -e "$ARNESS_ROOT/tmp/npm-run" ]
}

@test "an EXITED script keeps its log until clean" {
  mkdir -p "$(state a/feat/x)"
  echo "$(dead_pid)" > "$(state a/feat/x)/serve.pid"
  echo "it died" > "$(state a/feat/x)/serve.log"
  run "$SCRIPT" ps
  [[ "$output" == "EXITED "* ]] || false
  [ -f "$(state a/feat/x)/serve.log" ]
  run "$SCRIPT" clean
  [ "$output" = "CLEANED a/feat/x serve.log" ]
}

@test "clean never touches what still runs" {
  "$SCRIPT" run serve >/dev/null
  pid="$(cat "$(state a/feat/x)/serve.pid")"
  echo log > "$(state a/feat/x)/install.log"
  echo old > "$(state a/feat/x)/ok.log"
  echo "$(dead_pid)" > "$(state a/feat/x)/gone.pid"
  run "$SCRIPT" clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEANED a/feat/x gone.pid"* ]] || false
  [[ "$output" == *"CLEANED a/feat/x ok.log"* ]] || false
  [ -f "$(state a/feat/x)/serve.pid" ]
  [ -f "$(state a/feat/x)/serve.log" ]
  [ -f "$(state a/feat/x)/install.log" ]
  kill -0 "$pid"
}

@test "clean --worktree only cleans that worktree; nothing to clean is NONE" {
  mk_wt a feat/y
  mkdir -p "$(state a/feat/x)" "$(state a/feat/y)"
  echo x > "$(state a/feat/x)/ok.log"
  echo y > "$(state a/feat/y)/ok.log"
  run "$SCRIPT" clean --worktree a/feat/y
  [ "$output" = "CLEANED a/feat/y ok.log" ]
  [ -f "$(state a/feat/x)/ok.log" ]
  [ ! -e "$(state a/feat/y)" ]
  run "$SCRIPT" clean --worktree a/feat/y
  [ "$output" = "NONE" ]
  run "$SCRIPT" clean --worktree ../x
  [ "$status" -eq 2 ]
}

@test "stop needs a target" {
  run "$SCRIPT" stop
  [ "$status" -eq 2 ]
  run "$SCRIPT" stop --all serve
  [ "$status" -eq 2 ]
  run "$SCRIPT" stop --worktree ../x
  [ "$status" -eq 2 ]
}

# --- wait and exit codes -------------------------------------------------------------

# add_script <name> <command>: add a script to the worktree's package.json.
add_script() {
  (cd "$(WT a/feat/x)" && npm pkg set "scripts.$1=$2" >/dev/null)
}

@test "wait blocks until a slow script ends with 0: FINISHED 0, exit 0" {
  add_script slow "sleep 2 && echo slow-done"
  NPM_RUN_QUICK_TENTHS=1 run "$SCRIPT" run slow
  [ "$status" -eq 0 ]
  [[ "$output" == "STARTED a/feat/x slow "* ]] || false
  run "$SCRIPT" wait --worktree a/feat/x slow
  [ "$status" -eq 0 ]
  [ "$output" = "FINISHED a/feat/x slow 0 $(state a/feat/x)/slow.log" ]
  grep -q slow-done "$(state a/feat/x)/slow.log"
}

@test "wait on a slow script that fails gives FINISHED with its code, exit 8 and the log tail" {
  add_script slowfail "sleep 2 && echo slow-boom && exit 3"
  NPM_RUN_QUICK_TENTHS=1 run "$SCRIPT" run slowfail
  [[ "$output" == "STARTED a/feat/x slowfail "* ]] || false
  run "$SCRIPT" wait --worktree a/feat/x slowfail
  [ "$status" -eq 8 ]
  [ "${lines[0]}" = "FINISHED a/feat/x slowfail 3 $(state a/feat/x)/slowfail.log" ]
  [[ "$output" == *"--- last 20 lines of $(state a/feat/x)/slowfail.log ---"* ]] || false
  [[ "$output" == *slow-boom* ]] || false
}

@test "wait on a script that already ended answers at once with its code" {
  run "$SCRIPT" run fail
  [ "$status" -eq 8 ]
  start="$(date +%s)"
  run "$SCRIPT" wait fail
  [ "$status" -eq 8 ]
  [ "${lines[0]}" = "FINISHED a/feat/x fail 3 $(state a/feat/x)/fail.log" ]
  [ "$(( $(date +%s) - start ))" -le 1 ]
}

@test "wait --timeout gives TIMEOUT and leaves the script running" {
  "$SCRIPT" run serve >/dev/null
  pid="$(cat "$(state a/feat/x)/serve.pid")"
  run "$SCRIPT" wait --worktree a/feat/x serve --timeout 1
  [ "$status" -eq 15 ]
  [ "$output" = "TIMEOUT a/feat/x serve $pid $(state a/feat/x)/serve.log" ]
  kill -0 "$pid"
  [ ! -e "$(state a/feat/x)/serve.code" ]
}

@test "wait on a script never started there is NOT_STARTED; bad input exits 2" {
  run "$SCRIPT" wait --worktree a/feat/x serve
  [ "$status" -eq 16 ]
  [ "$output" = "NOT_STARTED a/feat/x serve" ]
  run "$SCRIPT" wait --worktree a/nope serve
  [ "$status" -eq 4 ]
  [ "$output" = "NOT_FOUND a/nope" ]
  run "$SCRIPT" wait
  [ "$status" -eq 2 ]
  run "$SCRIPT" wait serve --timeout x
  [ "$status" -eq 2 ]
  run "$SCRIPT" wait ../serve
  [ "$status" -eq 2 ]
}

@test "wait on a script that died without a code is NO_CODE" {
  mkdir -p "$(state a/feat/x)"
  echo "$(dead_pid)" > "$(state a/feat/x)/serve.pid"
  echo "it died" > "$(state a/feat/x)/serve.log"
  run "$SCRIPT" wait serve
  [ "$status" -eq 17 ]
  [ "$output" = "NO_CODE a/feat/x serve $(state a/feat/x)/serve.log" ]
}

@test "the exit code is saved after npm-run returned, and ps shows it in EXITED" {
  add_script slowfail "sleep 2 && exit 3"
  NPM_RUN_QUICK_TENTHS=1 run "$SCRIPT" run slowfail
  [[ "$output" == "STARTED a/feat/x slowfail "* ]] || false
  pid="$(cat "$(state a/feat/x)/slowfail.pid")"
  for _ in $(seq 100); do
    if [ -f "$(state a/feat/x)/slowfail.code" ]; then break; fi
    sleep 0.1
  done
  [ "$(cat "$(state a/feat/x)/slowfail.code")" = 3 ]
  sleep 0.5
  run "$SCRIPT" ps
  [ "$output" = "EXITED a/feat/x slowfail $pid $(state a/feat/x)/slowfail.log 3" ]
}

@test "a new run of a script forgets the code of the previous one" {
  run "$SCRIPT" run fail
  [ -f "$(state a/feat/x)/fail.code" ]
  add_script fail "sleep 30"
  run "$SCRIPT" run fail
  [[ "$output" == "STARTED a/feat/x fail "* ]] || false
  [ ! -e "$(state a/feat/x)/fail.code" ]
}

@test "clean removes the exit code files of what no longer runs" {
  run "$SCRIPT" run fail
  [ -f "$(state a/feat/x)/fail.code" ]
  run "$SCRIPT" clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEANED a/feat/x fail.code"* ]] || false
  [ ! -e "$ARNESS_ROOT/tmp/npm-run" ]
}

@test "stop leaves no exit code behind, and wait then says NOT_STARTED" {
  "$SCRIPT" run serve >/dev/null
  pid="$(cat "$(state a/feat/x)/serve.pid")"
  run "$SCRIPT" stop --worktree a/feat/x serve
  [ "$status" -eq 0 ]
  [ "$output" = "STOPPED a/feat/x serve $pid" ]
  sleep 0.5
  [ ! -e "$(state a/feat/x)/serve.code" ]
  [ ! -e "$(state a/feat/x)/serve.code.tmp" ]
  run "$SCRIPT" wait serve
  [ "$status" -eq 16 ]
  [ "$output" = "NOT_STARTED a/feat/x serve" ]
}

# wait_code <script>: wait up to 10 s for the wrapper to save that script's code, then for it to be gone.
wait_code() {
  for _ in $(seq 100); do
    if [ -f "$(state a/feat/x)/$1.code" ]; then break; fi
    sleep 0.1
  done
  sleep 0.5
}

@test "a child that ignores TERM keeps the script RUNNING, and stop ends it with KILL after 5 s" {
  add_script stubborn "trap '' TERM; sleep 30"
  "$SCRIPT" run stubborn >/dev/null
  pid="$(cat "$(state a/feat/x)/stubborn.pid")"
  sleep 0.5
  kill -TERM -- "-$pid"
  sleep 1
  # The wrapper passed the TERM on and waits for npm, which waits for the child that ignores it.
  run "$SCRIPT" ps
  [ "$output" = "RUNNING a/feat/x stubborn $pid $(state a/feat/x)/stubborn.log" ]
  [ ! -e "$(state a/feat/x)/stubborn.code" ]
  start="$(date +%s)"
  run "$SCRIPT" stop --worktree a/feat/x stubborn
  [ "$status" -eq 0 ]
  [ "$output" = "STOPPED a/feat/x stubborn $pid" ]
  [ "$(( $(date +%s) - start ))" -ge 4 ]
  sleep 0.3
  [ -z "$(group_pids "$pid")" ]
  [ ! -e "$(state a/feat/x)/stubborn.code" ]
}

@test "a running script with defunct in its worktree, name or args is RUNNING, waited and stopped" {
  mk_wt a fix-defunct
  (cd "$(WT a/fix-defunct)" && npm pkg set "scripts.defunct=sleep 30; true" >/dev/null)
  run "$SCRIPT" run --worktree a/fix-defunct defunct -- --grep defunct
  [[ "$output" == "STARTED a/fix-defunct defunct "* ]] || false
  pid="$(cat "$(state a/fix-defunct)/defunct.pid")"
  run "$SCRIPT" ps
  [ "$output" = "RUNNING a/fix-defunct defunct $pid $(state a/fix-defunct)/defunct.log" ]
  run "$SCRIPT" run --worktree a/fix-defunct defunct
  [ "$status" -eq 9 ]
  run "$SCRIPT" wait --worktree a/fix-defunct defunct --timeout 1
  [ "$status" -eq 15 ]
  [ "$output" = "TIMEOUT a/fix-defunct defunct $pid $(state a/fix-defunct)/defunct.log" ]
  run "$SCRIPT" stop --worktree a/fix-defunct defunct
  [ "$output" = "STOPPED a/fix-defunct defunct $pid" ]
  sleep 0.3
  [ -z "$(group_pids "$pid")" ]
}

# signal_wrapper_only <signal>: start serve, send <signal> to the saved pid only (the wrapper, not its
# group), and check that the wrapper passed it on to npm, saved the code and reported it to wait.
signal_wrapper_only() {
  "$SCRIPT" run serve >/dev/null
  pid="$(cat "$(state a/feat/x)/serve.pid")"
  sleep 0.5
  kill "-$1" "$pid"
  run "$SCRIPT" wait serve --timeout 10
  # The wrapper ended by itself (it exits right after saving the code); checked before the cleanup KILL.
  wrapper_alive=1
  for _ in $(seq 20); do
    if ! kill -0 "$pid" 2>/dev/null; then wrapper_alive=0; break; fi
    sleep 0.1
  done
  # Whatever the script left in the group must not outlive the test.
  kill -KILL -- "-$pid" 2>/dev/null || true
  [ "$wrapper_alive" -eq 0 ]
  [ "$status" -eq 8 ]
  [[ "${lines[0]}" == "FINISHED a/feat/x serve "* ]] || false
  code="$(cat "$(state a/feat/x)/serve.code")"
  [ "$code" -ne 0 ]
  [ "${lines[0]}" = "FINISHED a/feat/x serve $code $(state a/feat/x)/serve.log" ]
}

@test "a TERM to the wrapper alone reaches npm, and its code is saved" {
  signal_wrapper_only TERM
}

@test "an INT to the wrapper alone reaches npm, and its code is saved" {
  signal_wrapper_only INT
}

@test "stop also removes a .code.tmp left behind" {
  # Its wrapper is gone (a dead pid): nothing rewrites or renames the .code.tmp, only forget can remove it.
  mkdir -p "$(state a/feat/x)"
  dead_pid > "$(state a/feat/x)/serve.pid"
  echo 0 > "$(state a/feat/x)/serve.code.tmp"
  run "$SCRIPT" stop --worktree a/feat/x serve
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
  [ ! -e "$(state a/feat/x)/serve.code.tmp" ]
}

@test "a run that stops early without npm also removes the old code" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v20.19.0/bin" 20.19.0
  no_node_path
  echo 99.1 > "$(WT a/feat/x)/.nvmrc"
  mkdir -p "$(state a/feat/x)"
  echo 3 > "$(state a/feat/x)/ver.code"
  echo 3 > "$(state a/feat/x)/../x-other.code"
  PATH="$NO_NODE_PATH" run "$SCRIPT" run ver
  [ "$status" -eq 13 ]
  [ "$output" = "NO_NODE_VERSION a/feat/x 99.1" ]
  [ ! -e "$(state a/feat/x)/ver.code" ]
  # An invalid script name never reaches rm.
  PATH="$NO_NODE_PATH" run "$SCRIPT" run ../x-other
  [ "$status" -eq 13 ]
  [ -f "$(state a/feat/x)/../x-other.code" ]
}

@test "a run that fails with INVALID_PACKAGE_JSON (and UNKNOWN_SCRIPT) also removes the old code" {
  mkdir -p "$(state a/feat/x)"
  echo 0 > "$(state a/feat/x)/ok.code"
  echo 0 > "$(state a/feat/x)/gone.code"
  run "$SCRIPT" run gone
  [ "$status" -eq 7 ]
  [ ! -e "$(state a/feat/x)/gone.code" ]
  cp "$(WT a/feat/x)/package.json" "$TMP/package.json"
  echo 'not json' > "$(WT a/feat/x)/package.json"
  run "$SCRIPT" run ok
  [ "$status" -eq 6 ]
  [ ! -e "$(state a/feat/x)/ok.code" ]
  # wait no longer answers with the result of the run before.
  cp "$TMP/package.json" "$(WT a/feat/x)/package.json"
  run "$SCRIPT" wait ok
  [ "$status" -ne 0 ]
  [[ "$output" != FINISHED* ]] || false
}

@test "a code saved by the run before while this run starts is not taken as this run's result" {
  add_script slow "sleep 2"
  # An npm that, while run reads the scripts (after its first clear), plays the run before ending and
  # saving code 7.
  local real_npm
  real_npm="$(command -v npm)"
  mkdir -p "$TMP/npmbin" "$(state a/feat/x)"
  printf '#!/usr/bin/env bash\nif [ "$1" = pkg ]; then echo 7 > "%s"; fi\nexec "%s" "$@"\n' \
    "$(state a/feat/x)/slow.code" "$real_npm" > "$TMP/npmbin/npm"
  chmod +x "$TMP/npmbin/npm"
  PATH="$TMP/npmbin:$PATH" NPM_RUN_QUICK_TENTHS=1 run "$SCRIPT" run slow
  [[ "$output" == "STARTED a/feat/x slow "* ]] || false
  run "$SCRIPT" wait slow --timeout 10
  [ "$status" -eq 0 ]
  [ "$output" = "FINISHED a/feat/x slow 0 $(state a/feat/x)/slow.log" ]
}

@test "the wrapper ends its wait loop on wait's result and switches the trap off before saving" {
  run bash -c 'source "$1"; printf "%s\n" "$WRAPPER"' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *'kill -0'* ]] || false
  # The forwarding trap is switched off between the wait loop and the save.
  [[ "$output" == *'done; trap "" TERM INT; { echo'* ]] || false
}

@test "a run that stops early without npm keeps the code of a script that still runs" {
  "$SCRIPT" run serve >/dev/null
  echo 0 > "$(state a/feat/x)/serve.code"
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v20.19.0/bin" 20.19.0
  no_node_path
  echo 99.1 > "$(WT a/feat/x)/.nvmrc"
  PATH="$NO_NODE_PATH" run "$SCRIPT" run serve
  [ "$status" -eq 13 ]
  [ -f "$(state a/feat/x)/serve.code" ]
}

@test "a new run removes the old code also when it stops before running" {
  run "$SCRIPT" run fail
  [ -f "$(state a/feat/x)/fail.code" ]
  rmdir "$(WT a/feat/x)/node_modules"
  run "$SCRIPT" run fail
  [ "$status" -eq 11 ]
  [ ! -e "$(state a/feat/x)/fail.code" ]
}

@test "a TERM from outside npm-run still saves the exit code" {
  "$SCRIPT" run serve >/dev/null
  pid="$(cat "$(state a/feat/x)/serve.pid")"
  sleep 0.5
  kill -TERM -- "-$pid"
  run "$SCRIPT" wait serve --timeout 10
  [ "$status" -eq 8 ]
  [[ "${lines[0]}" == "FINISHED a/feat/x serve "* ]] || false
  [ "$(cat "$(state a/feat/x)/serve.code")" -ne 0 ]
}

@test "a pid file with 1, 0 or a leading zero is never signalled: stop says NONE" {
  for p in 1 0 01; do
    mkdir -p "$(state a/feat/x)"
    echo "$p" > "$(state a/feat/x)/serve.pid"
    run "$SCRIPT" stop --all
    [ "$status" -eq 0 ]
    [ "$output" = "NONE" ]
    [ ! -e "$(state a/feat/x)/serve.pid" ]
  done
  mkdir -p "$(state a/feat/x)"
  echo 1 > "$(state a/feat/x)/serve.pid"
  run "$SCRIPT" ps
  [ "$output" = "EXITED a/feat/x serve - $(state a/feat/x)/serve.log" ]
}

@test "a pid reused by another process is taken as dead: ps says EXITED and stop leaves it alone" {
  sleep 30 &
  other=$!
  mkdir -p "$(state a/feat/x)"
  echo "$other" > "$(state a/feat/x)/serve.pid"
  run "$SCRIPT" ps
  [ "$output" = "EXITED a/feat/x serve $other $(state a/feat/x)/serve.log" ]
  echo "$other" > "$(state a/feat/x)/serve.pid"
  run "$SCRIPT" stop --all
  [ "$output" = "NONE" ]
  kill -0 "$other"
  kill "$other"
  wait "$other" 2>/dev/null || true
}

@test "the wrapper leaves no .code.tmp when it cannot save the code, and keeps npm's exit" {
  mkdir -p "$TMP/fakebin"
  printf '#!/bin/sh\nexit 3\n' > "$TMP/fakebin/npm"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/fakebin/mv"
  chmod +x "$TMP/fakebin/npm" "$TMP/fakebin/mv"
  run bash -c 'source "$1"; PATH="$2:$PATH" "$BASH" -c "$WRAPPER" npm-run "$3" x' _ "$SCRIPT" "$TMP/fakebin" "$TMP/x.code"
  [ "$status" -eq 3 ]
  [ ! -e "$TMP/x.code.tmp" ]
  [ ! -e "$TMP/x.code" ]
}

@test "clean removes an orphan .code.tmp" {
  mkdir -p "$(state a/feat/x)"
  echo 0 > "$(state a/feat/x)/ok.code.tmp"
  run "$SCRIPT" clean
  [ "$status" -eq 0 ]
  [ "$output" = "CLEANED a/feat/x ok.code.tmp" ]
  [ ! -e "$ARNESS_ROOT/tmp/npm-run" ]
}

@test "wait, ps and stop do not crash on a pid file they cannot read" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  mkdir -p "$(state a/feat/x)"
  echo "$(dead_pid)" > "$(state a/feat/x)/serve.pid"
  echo "it died" > "$(state a/feat/x)/serve.log"
  chmod 000 "$(state a/feat/x)/serve.pid"
  run "$SCRIPT" wait serve
  [ "$status" -eq 17 ]
  [ "$output" = "NO_CODE a/feat/x serve $(state a/feat/x)/serve.log" ]
  run "$SCRIPT" ps
  [ "$status" -eq 0 ]
  [[ "$output" == "EXITED a/feat/x serve "* ]] || false
  echo "$(dead_pid)" > "$(state a/feat/x)/other.pid"
  chmod 000 "$(state a/feat/x)/other.pid"
  run "$SCRIPT" stop --all
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
}

@test "stop of a script that ended by itself also removes its code" {
  add_script slow "sleep 2"
  NPM_RUN_QUICK_TENTHS=1 run "$SCRIPT" run slow
  [[ "$output" == "STARTED a/feat/x slow "* ]] || false
  wait_code slow
  run "$SCRIPT" stop --worktree a/feat/x slow
  [ "$status" -eq 0 ]
  [ ! -e "$(state a/feat/x)/slow.code" ]
}

@test "clean keeps the .code of a script still running" {
  "$SCRIPT" run serve >/dev/null
  echo 0 > "$(state a/feat/x)/serve.code"
  run "$SCRIPT" clean
  [ -f "$(state a/feat/x)/serve.code" ]
}

@test "wait --timeout 0 waits with no limit" {
  add_script slow "sleep 2"
  NPM_RUN_QUICK_TENTHS=1 run "$SCRIPT" run slow
  [[ "$output" == "STARTED a/feat/x slow "* ]] || false
  run "$SCRIPT" wait slow --timeout 0
  [ "$status" -eq 0 ]
  [ "$output" = "FINISHED a/feat/x slow 0 $(state a/feat/x)/slow.log" ]
}

# --- usage ---------------------------------------------------------------------------

@test "invalid usage exits 2; -h prints the header" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  run "$SCRIPT" bogus
  [ "$status" -eq 2 ]
  run "$SCRIPT" run ok fail
  [ "$status" -eq 2 ]
  run "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exit codes:"* ]] || false
  [[ "$output" == *"14 stop failed"* ]] || false
  [[ "$output" == *"15 wait timed out"* ]] || false
  [[ "$output" == *"npm-run.sh wait "* ]] || false
  [[ "$output" != *"set -euo"* ]] || false
  [[ "$output" == *"13 node version of .nvmrc not installed"* ]] || false
}

# --- .nvmrc ------------------------------------------------------------------------

# fake_node <dir> <version>: a node in <dir> that answers --version with v<version> and runs the real
# node for anything else, so npm keeps working through it.
fake_node() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = --version ]; then echo v%s; exit 0; fi\nexec "%s" "$@"\n' \
    "$2" "$REAL_NODE" > "$1/node"
  chmod +x "$1/node"
  # Windows: npm runs scripts with cmd.exe, which only finds node.exe / node.cmd.
  if command -v cygpath >/dev/null 2>&1; then
    printf '@echo off\r\nif "%%~1"=="--version" (echo v%s& exit /b 0)\r\n"%s" %%*\r\n' \
      "$2" "$(cygpath -w "$REAL_NODE")" > "$1/node.cmd"
  fi
}

nvmrc_setup() {
  REAL_NODE="$(command -v node)"
  # No nvm of this machine: NVM_DIR set to an empty folder (unset, it would look in ~/.nvm and the XDG one) and no NVM_HOME.
  export NVM_DIR="$TMP/no-nvm"
  unset NVM_HOME
  # A script that reports the node it sees.
  cat > "$(WT a/feat/x)/package.json" <<'JSON'
{ "name": "fixture", "version": "1.0.0", "scripts": { "ver": "node --version" } }
JSON
}

@test ".nvmrc: the exact version from nvm runs install and the script" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v22.17.1/bin" 22.17.1
  fake_node "$NVM_DIR/versions/node/v20.19.0/bin" 20.19.0
  echo v22.17.1 > "$(WT a/feat/x)/.nvmrc"
  rm -rf "$(WT a/feat/x)/node_modules"
  run "$SCRIPT" run --install ver
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NODE a/feat/x 22.17.1" ]
  [[ "${lines[1]}" == "INSTALLED a/feat/x "* ]]
  [[ "${lines[2]}" == "FINISHED a/feat/x ver 0 "* ]]
  grep -qx v22.17.1 "$(state a/feat/x)/ver.log"
}

@test ".nvmrc: a major version picks the highest installed one, nvm-windows layout too" {
  nvmrc_setup
  export NVM_HOME="$TMP/nvm-windows"
  fake_node "$NVM_HOME/v22.9.0" 22.9.0
  fake_node "$NVM_HOME/v22.17.1" 22.17.1
  fake_node "$NVM_HOME/v24.10.0" 24.10.0
  printf '22\r\n' > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NODE a/feat/x 22.17.1" ]
  grep -qx v22.17.1 "$(state a/feat/x)/ver.log"
}

@test ".nvmrc: a version nvm does not have stops with NO_NODE_VERSION; nothing runs" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v20.19.0/bin" 20.19.0
  echo 99.1 > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 13 ]
  [ "$output" = "NO_NODE_VERSION a/feat/x 99.1" ]
  [ ! -e "$(state a/feat/x)/ver.log" ]
  # Without node_modules it is found before the install question, not after it.
  rm -rf "$(WT a/feat/x)/node_modules"
  run "$SCRIPT" run ver
  [ "$status" -eq 13 ]
  [ "$output" = "NO_NODE_VERSION a/feat/x 99.1" ]
}

@test ".nvmrc: a BOM, comments and blank lines are skipped; 2 does not match 22" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v22.17.1/bin" 22.17.1
  printf '\357\273\277\n# pinned for the project\nv22 # LTS\n' > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NODE a/feat/x 22.17.1" ]
  echo 2 > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 13 ]
  [ "$output" = "NO_NODE_VERSION a/feat/x 2" ]
}

@test ".nvmrc: without nvm, a current node that matches runs and is reported with NODE" {
  nvmrc_setup
  local cur
  cur="$(node --version)"
  echo "${cur%%.*}" > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NODE a/feat/x ${cur#v}" ]
  [[ "${lines[1]}" == "FINISHED a/feat/x ver 0 "* ]]
}

@test ".nvmrc: NO_COMMAND and UNKNOWN_SCRIPT come before NO_NODE_VERSION" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v20.19.0/bin" 20.19.0
  echo 99.1 > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run
  [ "$status" -eq 5 ]
  [ "${lines[0]}" = "NO_COMMAND a/feat/x" ]
  [ "${lines[1]}" = "SCRIPT ver" ]
  run "$SCRIPT" run vre
  [ "$status" -eq 7 ]
  [ "${lines[0]}" = "UNKNOWN_SCRIPT a/feat/x vre" ]
}

@test ".nvmrc: 22.x picks the highest 22.x, like 22" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v22.9.0/bin" 22.9.0
  fake_node "$NVM_DIR/versions/node/v22.17.1/bin" 22.17.1
  echo 22.x > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NODE a/feat/x 22.17.1" ]
}

@test ".nvmrc: with NVM_DIR unset, nvm is also found in the XDG config folder" {
  nvmrc_setup
  unset NVM_DIR XDG_CONFIG_HOME
  fake_node "$TMP/home/.config/nvm/versions/node/v22.17.1/bin" 22.17.1
  echo 22 > "$(WT a/feat/x)/.nvmrc"
  HOME="$TMP/home" run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NODE a/feat/x 22.17.1" ]
  # A version it lacks stops there too: that nvm counts as installed.
  echo 99.1 > "$(WT a/feat/x)/.nvmrc"
  HOME="$TMP/home" run "$SCRIPT" run ver
  [ "$status" -eq 13 ]
  [ "$output" = "NO_NODE_VERSION a/feat/x 99.1" ]
  # XDG_CONFIG_HOME, when set, is where it looks.
  mkdir -p "$TMP/xdg"
  mv "$TMP/home/.config/nvm" "$TMP/xdg/nvm"
  echo 22 > "$(WT a/feat/x)/.nvmrc"
  HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NODE a/feat/x 22.17.1" ]
}

@test ".nvmrc: a big file is read without SIGPIPE" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v22.17.1/bin" 22.17.1
  awk 'BEGIN { print 22; for (i = 0; i < 200000; i++) print "22.17.1" }' > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NODE a/feat/x 22.17.1" ]
}

@test ".nvmrc: without nvm, a current node that does not match runs with a warning" {
  nvmrc_setup
  echo 99.1 > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: .nvmrc asks for node 99.1 and there is no nvm; using the current node "[0-9]* ]]
  [[ "$output" == *"FINISHED a/feat/x ver 0 "* ]]
  [[ "$output" != *NODE\ a/feat/x* ]]
  rm -f "$(state a/feat/x)/ver.log"
  # An nvm-windows install counts as nvm, even when its folder has no versions.
  export NVM_HOME="$TMP/nvm-windows-empty"
  mkdir -p "$NVM_HOME"
  run "$SCRIPT" run ver
  [ "$status" -eq 13 ]
  [[ "$output" == *"NO_NODE_VERSION a/feat/x 99.1" ]]
  [ ! -e "$(state a/feat/x)/ver.log" ]
  # So does a fresh nvm with no version installed yet.
  unset NVM_HOME
  export NVM_DIR="$TMP/nvm-fresh"
  mkdir -p "$NVM_DIR"
  touch "$NVM_DIR/nvm.sh"
  run "$SCRIPT" run ver
  [ "$status" -eq 13 ]
  [ "$output" = "NO_NODE_VERSION a/feat/x 99.1" ]
}

@test ".nvmrc: an alias is not resolved; NODE_UNRESOLVED, and the current node runs" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v22.17.1/bin" 22.17.1
  echo 'lts/*' > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: .nvmrc asks for 'lts/*', an alias npm-run does not resolve"* ]]
  [[ "$output" == *"NODE_UNRESOLVED a/feat/x lts/*"* ]]
  [[ "$output" == *"FINISHED a/feat/x ver 0 "* ]]
  [[ "$output" != *"NODE a/feat/x"* ]]
}

@test ".nvmrc: the NODE or NODE_UNRESOLVED line comes before the install question" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v22.17.1/bin" 22.17.1
  rm -rf "$(WT a/feat/x)/node_modules"
  echo 22 > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 11 ]
  [ "$output" = "NODE a/feat/x 22.17.1"$'\n'"CONFIRM_INSTALL a/feat/x" ]
  echo 'lts/*' > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 11 ]
  [[ "$output" == *"NODE_UNRESOLVED a/feat/x lts/*"*"CONFIRM_INSTALL a/feat/x" ]]
}

@test ".nvmrc: only the first field counts, and v or .x alone is not a version" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v22.17.1/bin" 22.17.1
  printf '  22 20\n' > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NODE a/feat/x 22.17.1" ]
  echo v > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [[ "$output" == *"NODE_UNRESOLVED a/feat/x v"$'\n'* ]]
  echo .x > "$(WT a/feat/x)/.nvmrc"
  run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [[ "$output" == *"NODE_UNRESOLVED a/feat/x .x"$'\n'* ]]
}

@test ".nvmrc: without npm in PATH, a version nvm lacks is reported first" {
  nvmrc_setup
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v20.19.0/bin" 20.19.0
  no_node_path
  echo 99.1 > "$(WT a/feat/x)/.nvmrc"
  PATH="$NO_NODE_PATH" run "$SCRIPT" run
  [ "$status" -eq 13 ]
  [ "$output" = "NO_NODE_VERSION a/feat/x 99.1" ]
}

# no_node_path: NO_NODE_PATH = PATH without the folders of the global node and npm. Skips the test when
# node shares a folder with git or bash, which the scripts need.
no_node_path() {
  local d IFS=:
  NO_NODE_PATH=""
  for d in $PATH; do
    if [ -x "$d/npm" ] || [ -x "$d/node" ] || [ -x "$d/node.exe" ]; then
      if [ -x "$d/git" ] || [ -x "$d/bash" ]; then skip "node shares a folder with git or bash here"; fi
      continue
    fi
    NO_NODE_PATH="${NO_NODE_PATH:+$NO_NODE_PATH:}$d"
  done
}

@test ".nvmrc: npm reachable only through nvm still runs" {
  nvmrc_setup
  local real_npm
  real_npm="$(command -v npm)"
  export NVM_DIR="$TMP/nvm"
  fake_node "$NVM_DIR/versions/node/v22.17.1/bin" 22.17.1
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$real_npm" > "$NVM_DIR/versions/node/v22.17.1/bin/npm"
  chmod +x "$NVM_DIR/versions/node/v22.17.1/bin/npm"
  no_node_path
  echo 22 > "$(WT a/feat/x)/.nvmrc"
  PATH="$NO_NODE_PATH" run "$SCRIPT" run ver
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NODE a/feat/x 22.17.1" ]
  grep -qx v22.17.1 "$(state a/feat/x)/ver.log"
}

@test "ps, stop and clean work without npm in PATH; scripts still needs it" {
  no_node_path
  PATH="$NO_NODE_PATH" run "$SCRIPT" ps
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
  PATH="$NO_NODE_PATH" run "$SCRIPT" stop --all
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
  PATH="$NO_NODE_PATH" run "$SCRIPT" clean
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
  PATH="$NO_NODE_PATH" run "$SCRIPT" scripts
  [ "$status" -eq 3 ]
  [ "$output" = "NO_NPM" ]
}
