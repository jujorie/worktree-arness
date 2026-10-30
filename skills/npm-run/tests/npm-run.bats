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
  run "$SCRIPT" clean
  [ "$status" -eq 0 ]
  [ "$output" = "CLEANED a/feat/x ok.log" ]
  [ ! -e "$ARNESS_ROOT/tmp/npm-run" ]
}

@test "an EXITED script keeps its log until clean" {
  mkdir -p "$(state a/feat/x)"
  echo 999999 > "$(state a/feat/x)/serve.pid"
  echo "it died" > "$(state a/feat/x)/serve.log"
  run "$SCRIPT" ps
  [[ "$output" == "EXITED "* ]]
  [ -f "$(state a/feat/x)/serve.log" ]
  run "$SCRIPT" clean
  [ "$output" = "CLEANED a/feat/x serve.log" ]
}

@test "clean never touches what still runs" {
  "$SCRIPT" run serve >/dev/null
  pid="$(cat "$(state a/feat/x)/serve.pid")"
  echo log > "$(state a/feat/x)/install.log"
  echo old > "$(state a/feat/x)/ok.log"
  echo 999999 > "$(state a/feat/x)/gone.pid"
  run "$SCRIPT" clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEANED a/feat/x gone.pid"* ]]
  [[ "$output" == *"CLEANED a/feat/x ok.log"* ]]
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
  [[ "$output" == *"13 node version of .nvmrc not installed"* ]]
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
