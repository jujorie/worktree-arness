#!/usr/bin/env bats
# Unit tests for skills/worktree-config/scripts/worktree-config.sh.
# Each test runs against a throwaway ARNESS_ROOT with a local repo in source/.

SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/worktree-config.sh"

git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

mk_repo() {
  mkdir -p "$SRC/$1"
  git_q init -q "$SRC/$1"
  echo 1 > "$SRC/$1/f.txt"
  git_q -C "$SRC/$1" add f.txt
  git_q -C "$SRC/$1" commit -q -m c1
}

# mk_wt <repo> <name>: worktree laid out like worktree-create does.
mk_wt() { git_q -C "$SRC/$1" worktree add -q -b "$2" "$ARNESS_ROOT/worktrees/$1/$2" main; }

# cfg <repo> <rel> <content>: create config/<repo>/<rel>
cfg() {
  mkdir -p "$(dirname "$ARNESS_ROOT/config/$1/$2")"
  printf '%s' "$3" > "$ARNESS_ROOT/config/$1/$2"
}

WT() { echo "$ARNESS_ROOT/worktrees/$1/$2"; }

setup() {
  TMP="$(mktemp -d)"
  export ARNESS_ROOT="$TMP/root"
  SRC="$ARNESS_ROOT/source"
  mkdir -p "$SRC"
  mk_repo a
  mk_wt a feat/x
}

teardown() { rm -rf "$TMP"; }

# --- worktree argument ---------------------------------------------------

@test "NO_WORKTREE without argument" {
  run "$SCRIPT"
  [ "$status" -eq 5 ]
  [ "$output" = "NO_WORKTREE" ]
}

@test "NO_WORKTREE when the slug has no name" {
  run "$SCRIPT" a
  [ "$status" -eq 5 ]
  [ "$output" = "NO_WORKTREE" ]
  run "$SCRIPT" "a/"
  [ "$status" -eq 5 ]
}

@test "--worktree form works" {
  cfg a f.txt hi
  run "$SCRIPT" --worktree a/feat/x
  [ "$status" -eq 0 ]
}

@test "unsafe slugs are rejected" {
  for s in a/../x ../a/x /a/x a/x//y 'a b/x' a/-x; do
    run "$SCRIPT" "$s"
    [ "$status" -eq 2 ]
  done
}

@test "NOT_FOUND for an unknown worktree" {
  run "$SCRIPT" a/nope
  [ "$status" -eq 4 ]
  [[ "$output" == NOT_FOUND*/worktrees/a/nope ]]
}

@test "NOT_FOUND for a plain folder that is not a worktree" {
  mkdir -p "$ARNESS_ROOT/worktrees/a/plain"
  run "$SCRIPT" a/plain
  [ "$status" -eq 4 ]
}

@test "NOT_FOUND for an unknown repo" {
  run "$SCRIPT" zzz/x
  [ "$status" -eq 4 ]
}

# --- copy ----------------------------------------------------------------

@test "NO_CONFIG when config/<repo> does not exist" {
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 0 ]
  [ "$output" = "NO_CONFIG a" ]
}

@test "copies files keeping their relative path" {
  cfg a src/deep/test.js 'console.log(1)'
  cfg a .env.local 'A=1'
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"COPIED src/deep/test.js"* ]]
  [[ "$output" == *"COPIED .env.local"* ]]
  [[ "$output" == *"files=2 install=no" ]]
  [ "$(cat "$(WT a feat/x)/src/deep/test.js")" = "console.log(1)" ]
  [ "$(cat "$(WT a feat/x)/.env.local")" = "A=1" ]
}

@test "overwrites existing files and is idempotent" {
  cfg a f.txt new
  run "$SCRIPT" a/feat/x
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 0 ]
  [ "$(cat "$(WT a feat/x)/f.txt")" = "new" ]
}

@test "keeps the file mode" {
  cfg a bin/run.sh '#!/bin/sh'
  chmod 755 "$ARNESS_ROOT/config/a/bin/run.sh"
  run "$SCRIPT" a/feat/x
  [ -x "$(WT a feat/x)/bin/run.sh" ]
}

@test "does not touch other repos' config or worktrees" {
  mk_repo b; mk_wt b feat/x
  cfg a only-a.txt 1
  cfg b only-b.txt 1
  run "$SCRIPT" a/feat/x
  [ -f "$(WT a feat/x)/only-a.txt" ]
  [ ! -e "$(WT a feat/x)/only-b.txt" ]
  [ ! -e "$(WT b feat/x)/only-a.txt" ]
}

@test "binary files are copied untouched" {
  mkdir -p "$ARNESS_ROOT/config/a"
  printf '\000\001\002\377' > "$ARNESS_ROOT/config/a/blob.bin"
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"COPIED blob.bin"* ]]
  cmp "$ARNESS_ROOT/config/a/blob.bin" "$(WT a feat/x)/blob.bin"
}

# --- content is copied as is ---------------------------------------------

@test "{{\$VAR}} is not expanded, the file is copied literally" {
  cfg a .env 'T={{$MY_TOKEN}}'
  MY_TOKEN=abc run "$SCRIPT" a/feat/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"COPIED .env"* ]]
  [ "$(cat "$(WT a feat/x)/.env")" = 'T={{$MY_TOKEN}}' ]
}

@test "text without a trailing newline keeps that" {
  cfg a n.txt 'abc'
  run "$SCRIPT" a/feat/x
  [ "$(wc -c < "$(WT a feat/x)/n.txt")" -eq 3 ]
}

# --- install.sh ----------------------------------------------------------

@test "install.sh is not copied, it runs inside the worktree" {
  cfg a install.sh 'pwd -P > ran-in.txt'
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"files=0 install=yes" ]]
  [ ! -e "$(WT a feat/x)/install.sh" ]
  [ "$(cat "$(WT a feat/x)/ran-in.txt")" = "$(cd -P "$(WT a feat/x)" && pwd -P)" ]
}

@test "install.sh runs after the files are copied" {
  cfg a data.txt 'copied-first'
  cfg a install.sh 'cp data.txt seen.txt'
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 0 ]
  [ "$(cat "$(WT a feat/x)/seen.txt")" = "copied-first" ]
}

@test "install.sh needs no exec bit; its output goes to the log, not to us" {
  cfg a install.sh 'echo noisy-install-output; echo noisy-err >&2'
  chmod 644 "$ARNESS_ROOT/config/a/install.sh"
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 0 ]
  [[ "$output" != *noisy* ]]
  [[ "$output" == *DONE* ]]
  log="$ARNESS_ROOT/tmp/worktree-config/a/feat/x-install.log"
  grep -q noisy-install-output "$log"
  grep -q noisy-err "$log"
}

@test "no log is created when there is no install.sh" {
  cfg a f.txt 1
  run "$SCRIPT" a/feat/x
  [ ! -e "$ARNESS_ROOT/tmp" ]
}

@test "failing install.sh gives INSTALL_FAILED with exit code and log path" {
  cfg a keep.txt 1
  cfg a install.sh 'echo boom; exit 3'
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 7 ]
  [[ "$output" == *"INSTALL_FAILED 3 "*"/tmp/worktree-config/a/feat/x-install.log"* ]]
  [[ "$output" == *boom* ]]
  [ -f "$(WT a feat/x)/keep.txt" ]
}

@test "on failure only the last 20 lines of the log are shown" {
  cfg a install.sh 'for i in $(seq 1 100); do echo "line $i"; done; exit 1'
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 7 ]
  [[ "$output" == *"line 100"* ]]
  [[ "$output" == *"line 81"* ]]
  [[ "$output" != *"line 80"* ]]
  [ "$(grep -c '^line' "$ARNESS_ROOT/tmp/worktree-config/a/feat/x-install.log")" -eq 100 ]
}

@test "an install.sh in a subfolder is a normal file" {
  cfg a sub/install.sh 'touch SHOULD_NOT_RUN'
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 0 ]
  [ -f "$(WT a feat/x)/sub/install.sh" ]
  [ ! -e "$(WT a feat/x)/SHOULD_NOT_RUN" ]
}

# --- safety --------------------------------------------------------------

@test "config symlinks are skipped" {
  cfg a real.txt 1
  ln -s /etc/hosts "$ARNESS_ROOT/config/a/link.txt"
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 13 ]
  [[ "$output" == *"SKIPPED link.txt symlink"* ]]
  [ ! -e "$(WT a feat/x)/link.txt" ]
  [ -f "$(WT a feat/x)/real.txt" ]
}

@test "does not write through a symlinked dir in the worktree" {
  cfg a out/x.txt secret
  mkdir -p "$TMP/outside"
  ln -s "$TMP/outside" "$(WT a feat/x)/out"
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 13 ]
  [[ "$output" == *"SKIPPED out/x.txt symlink"* ]]
  [ -z "$(ls -A "$TMP/outside")" ]
}

@test "does not overwrite a symlink file in the worktree" {
  cfg a l.txt secret
  echo keep > "$TMP/target.txt"
  ln -s "$TMP/target.txt" "$(WT a feat/x)/l.txt"
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 13 ]
  [ "$(cat "$TMP/target.txt")" = "keep" ]
}

@test ".git in the config is never copied" {
  cfg a .git/config evil
  cfg a ok.txt 1
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 13 ]
  [[ "$output" == *"SKIPPED .git/config reserved-path"* ]]
  [ -f "$(WT a feat/x)/ok.txt" ]
  ! grep -q evil "$(WT a feat/x)/.git"
}

@test "a directory in the worktree where a file should go is a conflict" {
  cfg a f.txt/inner 1
  run "$SCRIPT" a/feat/x
  [ "$status" -eq 13 ]
  [[ "$output" == *"SKIPPED f.txt/inner conflict"* ]]
}
