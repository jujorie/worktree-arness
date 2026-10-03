#!/usr/bin/env bats
# Unit tests for skills/worktree-create/scripts/worktree-create.sh.
# Each test runs against a throwaway ARNESS_ROOT with local repos in source/.

SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/worktree-create.sh"

git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

mk_repo() {
  mkdir -p "$SRC/$1"
  git_q init -q "$SRC/$1"
  echo 1 > "$SRC/$1/f.txt"
  git_q -C "$SRC/$1" add f.txt
  git_q -C "$SRC/$1" commit -q -m c1
}

setup() {
  TMP="$(mktemp -d)"
  export ARNESS_ROOT="$TMP/root"
  SRC="$ARNESS_ROOT/source"
  mkdir -p "$SRC"
}

teardown() { rm -rf "$TMP"; }

@test "NO_SOURCE when source/ has no repos" {
  run "$SCRIPT" --name w
  [ "$status" -eq 4 ]
  [ "$output" = "NO_SOURCE" ]
}

@test "NO_SOURCE when source/ is missing" {
  rm -rf "$SRC"
  run "$SCRIPT" --name w
  [ "$status" -eq 4 ]
  [ "$output" = "NO_SOURCE" ]
}

@test "single repo is used without --source" {
  mk_repo a
  run "$SCRIPT" --name w --no-confirm
  [ "$status" -eq 0 ]
  [ "$output" = "CREATED $ARNESS_ROOT/worktrees/a/w main" ]
  [ -f "$ARNESS_ROOT/worktrees/a/w/f.txt" ]
  [ "$(git -C "$ARNESS_ROOT/worktrees/a/w" rev-parse --abbrev-ref HEAD)" = "w" ]
}

@test "several repos without --source asks to choose" {
  mk_repo a; mk_repo b
  run "$SCRIPT" --name w
  [ "$status" -eq 10 ]
  [ "$output" = "CHOOSE_SOURCE a b" ]
}

@test "--source picks one of several repos" {
  mk_repo a; mk_repo b
  run "$SCRIPT" --source b --name w --no-confirm
  [ "$status" -eq 0 ]
  [ -d "$ARNESS_ROOT/worktrees/b/w" ]
}

@test "invalid --source gives NO_SOURCE" {
  mk_repo a; mk_repo b
  run "$SCRIPT" --source nope --name w
  [ "$status" -eq 4 ]
  [ "$output" = "NO_SOURCE" ]
}

@test "path-like --source gives NO_SOURCE" {
  mk_repo a
  run "$SCRIPT" --source ../a --name w
  [ "$status" -eq 4 ]
  [ "$output" = "NO_SOURCE" ]
}

@test "NO_NAME when name missing" {
  mk_repo a
  run "$SCRIPT"
  [ "$status" -eq 5 ]
  [ "$output" = "NO_NAME" ]
}

@test "NO_NAME when name empty" {
  mk_repo a
  run "$SCRIPT" --name ""
  [ "$status" -eq 5 ]
  [ "$output" = "NO_NAME" ]
}

@test "unsafe name is rejected" {
  mk_repo a
  run "$SCRIPT" --name ../x --no-confirm
  [ "$status" -eq 2 ]
}

@test "asks to confirm the source branch" {
  mk_repo a
  git_q -C "$SRC/a" checkout -q -b develop
  run "$SCRIPT" --name w
  [ "$status" -eq 11 ]
  [ "$output" = "CONFIRM_BRANCH develop" ]
  [ ! -e "$ARNESS_ROOT/worktrees/a/w" ]
}

@test "--branch creates from that branch" {
  mk_repo a
  git_q -C "$SRC/a" checkout -q -b develop
  echo 2 > "$SRC/a/g.txt"; git_q -C "$SRC/a" add g.txt; git_q -C "$SRC/a" commit -q -m c2
  git_q -C "$SRC/a" checkout -q main
  run "$SCRIPT" --name w --branch develop
  [ "$status" -eq 0 ]
  [ "$output" = "CREATED $ARNESS_ROOT/worktrees/a/w develop" ]
  [ -f "$ARNESS_ROOT/worktrees/a/w/g.txt" ]
}

@test "--no-confirm uses the current branch" {
  mk_repo a
  git_q -C "$SRC/a" checkout -q -b develop
  run "$SCRIPT" --name w --no-confirm
  [ "$status" -eq 0 ]
  [ "$output" = "CREATED $ARNESS_ROOT/worktrees/a/w develop" ]
}

@test "unknown --branch is an error" {
  mk_repo a
  run "$SCRIPT" --name w --branch nope
  [ "$status" -eq 2 ]
}

@test "EXISTS when destination exists" {
  mk_repo a
  mkdir -p "$ARNESS_ROOT/worktrees/a/w"
  run "$SCRIPT" --name w --no-confirm
  [ "$status" -eq 12 ]
  [ "$output" = "EXISTS $ARNESS_ROOT/worktrees/a/w" ]
}

@test "existing branch name fails with git error" {
  mk_repo a
  git_q -C "$SRC/a" branch w
  run "$SCRIPT" --name w --no-confirm
  [ "$status" -eq 3 ]
}

@test "name with slash creates nested path" {
  mk_repo a
  run "$SCRIPT" --name feat/PROJ-123 --no-confirm
  [ "$status" -eq 0 ]
  [ "$output" = "CREATED $ARNESS_ROOT/worktrees/a/feat/PROJ-123 main" ]
  [ -f "$ARNESS_ROOT/worktrees/a/feat/PROJ-123/f.txt" ]
  [ "$(git -C "$ARNESS_ROOT/worktrees/a/feat/PROJ-123" rev-parse --abbrev-ref HEAD)" = "feat/PROJ-123" ]
}

@test "invalid file names are rejected" {
  mk_repo a
  for n in /x x/ a//b feat/../x ./x feat/-x "a b" 'a:b' 'a*b' 'a\b' .. a/.; do
    run "$SCRIPT" --name "$n" --no-confirm
    [ "$status" -eq 2 ]
  done
  [ ! -e "$ARNESS_ROOT/worktrees" ]
}

@test "refuses when worktrees/<repo> is a symlink outside" {
  mk_repo a
  mkdir -p "$ARNESS_ROOT/worktrees" "$TMP/outside"
  ln -s "$TMP/outside" "$ARNESS_ROOT/worktrees/a"
  run "$SCRIPT" --name w --no-confirm
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$TMP/outside")" ]
}

@test "refuses when an intermediate dir is a symlink outside" {
  mk_repo a
  mkdir -p "$ARNESS_ROOT/worktrees/a" "$TMP/outside"
  ln -s "$TMP/outside" "$ARNESS_ROOT/worktrees/a/feat"
  run "$SCRIPT" --name feat/x --no-confirm
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$TMP/outside")" ]
}

@test "refused symlink run creates no directories outside" {
  mk_repo a
  mkdir -p "$ARNESS_ROOT/worktrees/a" "$TMP/outside"
  ln -s "$TMP/outside" "$ARNESS_ROOT/worktrees/a/feat"
  run "$SCRIPT" --name feat/deep/x --no-confirm
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$TMP/outside")" ]
}

@test "records the base branch in the source repo config" {
  mk_repo a
  run "$SCRIPT" --name feat/x --no-confirm
  [ "$status" -eq 0 ]
  [ "$(git -C "$SRC/a" config --get branch.feat/x.arness-base)" = "main" ]
}

# --- config (worktree-config skill) ----------------------------------------

cfg() { mkdir -p "$(dirname "$ARNESS_ROOT/config/$1/$2")"; printf '%s' "$3" > "$ARNESS_ROOT/config/$1/$2"; }

@test "no config dir: output is only CREATED" {
  mk_repo a
  run "$SCRIPT" --name w --no-confirm
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "applies config/<repo> to the new worktree" {
  mk_repo a
  cfg a src/test.js 'v=1'
  cfg a install.sh 'echo done > installed.txt'
  run "$SCRIPT" --name feat/x --no-confirm
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "CREATED $ARNESS_ROOT/worktrees/a/feat/x main" ]
  [[ "$output" == *"CONFIG COPIED src/test.js"* ]]
  [[ "$output" == *"CONFIG DONE "*"files=1 install=yes" ]]
  [ "$(cat "$ARNESS_ROOT/worktrees/a/feat/x/src/test.js")" = "v=1" ]
  [ -f "$ARNESS_ROOT/worktrees/a/feat/x/installed.txt" ]
}

@test "--no-config skips the config" {
  mk_repo a
  cfg a src/test.js 'x'
  run "$SCRIPT" --name w --no-confirm --no-config
  [ "$status" -eq 0 ]
  [ ! -e "$ARNESS_ROOT/worktrees/a/w/src/test.js" ]
}

@test "only the config of the chosen repo is used" {
  mk_repo a; mk_repo b
  cfg a only-a 1
  cfg b only-b 1
  run "$SCRIPT" --source a --name w --no-confirm
  [ -f "$ARNESS_ROOT/worktrees/a/w/only-a" ]
  [ ! -e "$ARNESS_ROOT/worktrees/a/w/only-b" ]
}

@test "config failure keeps the worktree and exits 14" {
  mk_repo a
  cfg a keep.txt 1
  cfg a install.sh 'exit 3'
  run "$SCRIPT" --name w --no-confirm
  [ "$status" -eq 14 ]
  [[ "$output" == *"CONFIG INSTALL_FAILED 3"* ]]
  [[ "$output" == *"CONFIG_FAILED 7" ]]
  [ -d "$ARNESS_ROOT/worktrees/a/w" ]
  [ -f "$ARNESS_ROOT/worktrees/a/w/keep.txt" ]
}

# --- base branch that only exists in the remote -----------------------------

# mk_clone <name> : source/<name> is a clone of a fresh origin that has a branch epic/X-1 with an extra file.
mk_clone() {
  ORIGIN="$TMP/origin-$1"
  git_q init -q "$ORIGIN"
  echo 1 > "$ORIGIN/f.txt"; git_q -C "$ORIGIN" add f.txt; git_q -C "$ORIGIN" commit -q -m c1
  git_q -C "$ORIGIN" checkout -q -b epic/X-1
  echo 2 > "$ORIGIN/g.txt"; git_q -C "$ORIGIN" add g.txt; git_q -C "$ORIGIN" commit -q -m c2
  git_q -C "$ORIGIN" checkout -q main
  git clone -q "$ORIGIN" "$SRC/$1" 2>/dev/null
}

@test "--branch uses origin/<branch> when it is only remote-tracking" {
  mk_clone a
  [ -z "$(git -C "$SRC/a" branch --list epic/X-1)" ]
  run "$SCRIPT" --name w --branch epic/X-1
  [ "$status" -eq 0 ]
  [ "$output" = "CREATED $ARNESS_ROOT/worktrees/a/w origin/epic/X-1" ]
  [ -f "$ARNESS_ROOT/worktrees/a/w/g.txt" ]
  [ "$(git -C "$SRC/a" config --get branch.w.arness-base)" = "origin/epic/X-1" ]
}

@test "--branch fetches a remote branch created after the clone" {
  mk_clone a
  git_q -C "$ORIGIN" checkout -q -b epic/LATE
  echo 3 > "$ORIGIN/h.txt"; git_q -C "$ORIGIN" add h.txt; git_q -C "$ORIGIN" commit -q -m c3
  git_q -C "$ORIGIN" checkout -q main
  run "$SCRIPT" --name w --branch epic/LATE
  [ "$status" -eq 0 ]
  [ "$output" = "CREATED $ARNESS_ROOT/worktrees/a/w origin/epic/LATE" ]
  [ -f "$ARNESS_ROOT/worktrees/a/w/h.txt" ]
}

@test "--branch prefers the local branch over origin" {
  mk_clone a
  git_q -C "$SRC/a" branch epic/X-1 origin/main
  run "$SCRIPT" --name w --branch epic/X-1
  [ "$status" -eq 0 ]
  [ "$output" = "CREATED $ARNESS_ROOT/worktrees/a/w epic/X-1" ]
  [ ! -e "$ARNESS_ROOT/worktrees/a/w/g.txt" ]
}

@test "--branch missing locally and in origin is an error and creates nothing" {
  mk_clone a
  run "$SCRIPT" --name w --branch epic/NOPE
  [ "$status" -eq 2 ]
  [[ "$output" == *"branch not found"* ]]
  [ ! -e "$ARNESS_ROOT/worktrees/a/w" ]
}

@test "--branch with an invalid ref name never reaches fetch" {
  mk_clone a
  run "$SCRIPT" --name w --branch 'a..b'
  [ "$status" -eq 2 ]
}

# --- behind=<n> in the branch confirmation ------------------------------------

# origin_commit <file>: new commit on origin's main, after the clone.
origin_commit() {
  git_q -C "$ORIGIN" checkout -q main
  echo "$1" > "$ORIGIN/$1"; git_q -C "$ORIGIN" add "$1"; git_q -C "$ORIGIN" commit -q -m "$1"
}

@test "CONFIRM_BRANCH tells how many commits the local branch is behind origin" {
  mk_clone a
  origin_commit n1; origin_commit n2
  run "$SCRIPT" --name w
  [ "$status" -eq 11 ]
  [ "$output" = "CONFIRM_BRANCH main behind=2" ]
}

@test "CONFIRM_BRANCH says behind=0 when up to date" {
  mk_clone a
  run "$SCRIPT" --name w
  [ "$output" = "CONFIRM_BRANCH main behind=0" ]
}

@test "--no-fetch omits behind" {
  mk_clone a
  origin_commit n1
  run "$SCRIPT" --name w --no-fetch
  [ "$output" = "CONFIRM_BRANCH main" ]
}

@test "a local-only branch has no behind and no warning" {
  mk_clone a
  git_q -C "$SRC/a" checkout -q -b only-here
  run "$SCRIPT" --name w
  [ "$output" = "CONFIRM_BRANCH only-here" ]
}

@test "an unreachable origin warns and omits behind" {
  mk_clone a
  git -C "$SRC/a" remote set-url origin "$TMP/does-not-exist"
  run "$SCRIPT" --name w
  [ "$status" -eq 11 ]
  [[ "$output" == *"warning: could not refresh origin/main"* ]]
  [[ "$output" == *"CONFIRM_BRANCH main" ]]
}

@test "the user can pick origin/<branch> after seeing behind" {
  mk_clone a
  origin_commit n1
  run "$SCRIPT" --name w --branch origin/main
  [ "$status" -eq 0 ]
  [ -f "$ARNESS_ROOT/worktrees/a/w/n1" ]
}

@test "--no-confirm does not fetch or warn" {
  mk_clone a
  git -C "$SRC/a" remote set-url origin "$TMP/does-not-exist"
  run "$SCRIPT" --name w --no-confirm
  [ "$status" -eq 0 ]
  [[ "$output" != *warning* ]]
}

@test "--branch origin/<b> refreshes it first; --no-fetch uses the local copy" {
  mk_clone a
  origin_commit n1
  run "$SCRIPT" --name w --branch origin/main --no-fetch
  [ "$status" -eq 0 ]
  [ ! -e "$ARNESS_ROOT/worktrees/a/w/n1" ]
  run "$SCRIPT" --name w2 --branch origin/main
  [ -f "$ARNESS_ROOT/worktrees/a/w2/n1" ]
}

# --- upstream tracking ---------------------------------------------------------

@test "new branch tracks origin/<name>, also when the base is remote" {
  mk_clone a
  run "$SCRIPT" --name feat/one --no-confirm
  [ "$status" -eq 0 ]
  run "$SCRIPT" --name feat/two --branch origin/epic/X-1
  [ "$status" -eq 0 ]
  for n in feat/one feat/two; do
    [ "$(git -C "$SRC/a" config --get "branch.$n.remote")" = "origin" ]
    [ "$(git -C "$SRC/a" config --get "branch.$n.merge")" = "refs/heads/$n" ]
  done
}

@test "nothing is pushed on creation; a plain git push then creates the branch (any base)" {
  mk_clone a
  run "$SCRIPT" --name feat/one --no-confirm
  [ "$status" -eq 0 ]
  run "$SCRIPT" --name feat/two --branch origin/epic/X-1
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$ORIGIN" branch --list 'feat/*')" ]
  epic_before="$(git -C "$ORIGIN" rev-parse epic/X-1)"
  for n in feat/one feat/two; do
    run git_q -C "$ARNESS_ROOT/worktrees/a/$n" push
    [ "$status" -eq 0 ]
    [ -n "$(git -C "$ORIGIN" branch --list "$n")" ]
  done
  # pushing feat/two must not touch the epic branch it was based on
  [ "$(git -C "$ORIGIN" rev-parse epic/X-1)" = "$epic_before" ]
}

@test "without an origin remote no tracking is configured" {
  mk_repo a
  run "$SCRIPT" --name w --no-confirm
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$SRC/a" config --get branch.w.remote || true)" ]
}
