#!/usr/bin/env bats
# Unit tests for skills/npm-run/scripts/npm-run.sh.
# Each test builds a throwaway ARNESS_ROOT with local repos and worktrees. npm runs for real, offline,
# on scripts that only echo, sleep or exit: no network and no dependencies.

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

setup() {
  command -v npm >/dev/null 2>&1 || skip "npm not installed"
  TMP="$(mktemp -d)"
  TMP="$(cd -P "$TMP" && pwd -P)"
  export ARNESS_ROOT="$TMP/root"
  export npm_config_offline=true npm_config_update_notifier=false
  mkdir -p "$ARNESS_ROOT/source" "$ARNESS_ROOT/worktrees"
  mk_repo a
  mk_wt a feat/x
}

teardown() {
  [ -n "${TMP:-}" ] || return 0
  ARNESS_ROOT="$TMP/root" "$SCRIPT" stop --all >/dev/null 2>&1 || true
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
  [ -n "$(pgrep -g "$pid" || true)" ]

  run "$SCRIPT" stop --worktree a/feat/x serve
  [ "$status" -eq 0 ]
  [ "$output" = "STOPPED a/feat/x serve $pid" ]
  sleep 0.3
  [ -z "$(pgrep -g "$pid" || true)" ]
  [ ! -e "$(state a/feat/x)/serve.pid" ]

  run "$SCRIPT" ps
  [ "$output" = "NONE" ]
}

@test "ps reports EXITED for a dead pid and forgets it" {
  mkdir -p "$(state a/feat/x)"
  echo 999999 > "$(state a/feat/x)/serve.pid"
  run "$SCRIPT" ps
  [ "$output" = "EXITED a/feat/x serve 999999 $(state a/feat/x)/serve.log" ]
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

@test "stop needs a target" {
  run "$SCRIPT" stop
  [ "$status" -eq 2 ]
  run "$SCRIPT" stop --all serve
  [ "$status" -eq 2 ]
  run "$SCRIPT" stop --worktree ../x
  [ "$status" -eq 2 ]
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
  [[ "$output" == *"Exit codes:"* ]]
}
