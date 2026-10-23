#!/usr/bin/env bats
# Unit tests for skills/tmp-clean/scripts/tmp-clean.sh.
# Each test runs against a throwaway ARNESS_ROOT; worktrees are faked with a .git file.

SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/tmp-clean.sh"

# mk_wt <repo>/<name>: a repo in source/ and a folder that looks like its worktree.
mk_wt() {
  local repo="${1%%/*}"
  mkdir -p "$ARNESS_ROOT/source/$repo/.git" "$ARNESS_ROOT/worktrees/$1"
  echo "gitdir: x" > "$ARNESS_ROOT/worktrees/$1/.git"
}

# put <path under tmp> [content]: a file, with its folders.
put() {
  mkdir -p "$(dirname "$ARNESS_ROOT/tmp/$1")"
  echo "${2:-x}" > "$ARNESS_ROOT/tmp/$1"
}

# age <path under tmp>: make everything in it 40 days old.
age() {
  find "$ARNESS_ROOT/tmp/$1" -exec touch -t "$(date -v-40d +%Y%m%d%H%M 2>/dev/null || date --date='40 days ago' +%Y%m%d%H%M)" {} +
}

setup() {
  TMP="$(mktemp -d)"
  TMP="$(cd -P "$TMP" && pwd -P)"
  export ARNESS_ROOT="$TMP/root"
  mkdir -p "$ARNESS_ROOT/source" "$ARNESS_ROOT/worktrees"
}

teardown() { rm -rf "$TMP"; }

@test "list prints NONE when tmp does not exist" {
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
}

@test "list reports ORPHAN for the state of a gone worktree, not for a live one" {
  mk_wt a/feat/live
  mkdir -p "$ARNESS_ROOT/source/a/.git"
  put npm-run/a/feat/live/start.log
  put npm-run/a/feat/gone/start.log
  put worktree-config/a/feat/gone/install.log
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ORPHAN tmp/npm-run/a/feat/gone "* ]]
  [[ "$output" == *"ORPHAN tmp/worktree-config/a/feat/gone "* ]]
  [[ "$output" != *live* ]]
}

@test "a whole folder of gone worktrees is one ORPHAN entry" {
  mkdir -p "$ARNESS_ROOT/source/a/.git"
  put npm-run/a/fix/one/start.log
  put npm-run/a/fix/two/start.log
  run "$SCRIPT" list
  [[ "$output" == "ORPHAN tmp/npm-run/a/fix "* ]]
  [ "${#lines[@]}" -eq 1 ]
}

@test "an old log file next to a live worktree name is ORPHAN" {
  mk_wt a/feat/x
  put worktree-config/a/feat/x-install.log
  run "$SCRIPT" list
  [[ "$output" == "ORPHAN tmp/worktree-config/a/feat/x-install.log "* ]]
}

@test "other keys are STALE only when nothing in them changed in --days" {
  put bob-issue-analyze/PROJ-1/report.md
  put bob-issue-analyze/PROJ-2/report.md
  put pr-review/12.json
  age bob-issue-analyze/PROJ-1
  age pr-review/12.json
  run "$SCRIPT" list
  [[ "$output" == *"STALE tmp/bob-issue-analyze/PROJ-1 "* ]]
  [[ "$output" == *"STALE tmp/pr-review/12.json "* ]]
  [[ "$output" != *PROJ-2* ]]
  run "$SCRIPT" list --days 100
  [ "$output" = "NONE" ]
}

@test "a folder named like a repo is a worktree key only when that repo is in source/" {
  put skill/notarepo/feat/x/f
  run "$SCRIPT" list
  [ "$output" = "NONE" ]
}

@test "an entry with a live pid is never listed" {
  mkdir -p "$ARNESS_ROOT/source/a/.git"
  put npm-run/a/gone/start.pid "$$"
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [[ "$output" == *NONE* ]]
  [[ "$output" == *"still runs"* ]]
}

@test "remove deletes listed paths and prunes empty folders, keeping tmp/<skill>" {
  mk_wt a/feat/live
  put npm-run/a/feat/gone/start.log
  put npm-run/b-key/keep
  run "$SCRIPT" remove tmp/npm-run/a/feat/gone
  [ "$status" -eq 0 ]
  [ "$output" = "REMOVED tmp/npm-run/a/feat/gone" ]
  [ ! -e "$ARNESS_ROOT/tmp/npm-run/a" ]
  [ -f "$ARNESS_ROOT/tmp/npm-run/b-key/keep" ]
}

@test "remove skips what list does not report (live, recent, outside tmp)" {
  mk_wt a/live
  put npm-run/a/live/start.log
  put notes/PROJ-1/n.md
  run "$SCRIPT" remove tmp/npm-run/a/live tmp/notes/PROJ-1 source/a ../x
  [ "$status" -eq 13 ]
  [ "${lines[0]}" = "SKIPPED tmp/npm-run/a/live not-listed" ]
  [ "${lines[1]}" = "SKIPPED tmp/notes/PROJ-1 not-listed" ]
  [ "${lines[2]}" = "SKIPPED source/a not-listed" ]
  [ "${lines[3]}" = "SKIPPED ../x not-listed" ]
  [ -f "$ARNESS_ROOT/tmp/npm-run/a/live/start.log" ]
  [ -d "$ARNESS_ROOT/source/a" ]
}

@test "remove needs a PATH" {
  run "$SCRIPT" remove
  [ "$status" -eq 2 ]
}

@test "purge removes the key and its files in every skill, whatever their age" {
  put bob-issue-analyze/PROJ-1/report.md
  put handoff/PROJ-1.md
  put pr-review/PROJ-1.json
  put bob-issue-analyze/PROJ-10/report.md
  put handoff/PROJ-1-other.md
  run "$SCRIPT" purge PROJ-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PURGED tmp/bob-issue-analyze/PROJ-1"* ]]
  [[ "$output" == *"PURGED tmp/handoff/PROJ-1.md"* ]]
  [[ "$output" == *"PURGED tmp/pr-review/PROJ-1.json"* ]]
  [ -d "$ARNESS_ROOT/tmp/bob-issue-analyze/PROJ-10" ]
  [ -f "$ARNESS_ROOT/tmp/handoff/PROJ-1-other.md" ]
  [ -d "$ARNESS_ROOT/tmp/handoff" ]
}

@test "purge prints NONE when the key has nothing" {
  put a/PROJ-2/x
  run "$SCRIPT" purge PROJ-1
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
}

@test "purge rejects unsafe keys and skips what still runs" {
  put a/PROJ-1/srv.pid "$$"
  run "$SCRIPT" purge .. 'a/b' '*' PROJ-1
  [ "$status" -eq 13 ]
  [[ "$output" == *"SKIPPED .. invalid-key"* ]]
  [[ "$output" == *"SKIPPED a/b invalid-key"* ]]
  [[ "$output" == *"SKIPPED * invalid-key"* ]]
  [[ "$output" == *"SKIPPED tmp/a/PROJ-1 running"* ]]
  [ -d "$ARNESS_ROOT/tmp/a/PROJ-1" ]
}

@test "invalid usage exits 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  run "$SCRIPT" list --days 0
  [ "$status" -eq 2 ]
  run "$SCRIPT" list --days x
  [ "$status" -eq 2 ]
  run "$SCRIPT" list tmp/x
  [ "$status" -eq 2 ]
  run "$SCRIPT" nope
  [ "$status" -eq 2 ]
}
