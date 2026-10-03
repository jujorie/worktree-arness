#!/usr/bin/env bats
# Unit tests for skills/repo-clone/scripts/repo-clone.sh.
# Each test runs against a throwaway ARNESS_ROOT and a local origin repo (file://).

SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/repo-clone.sh"

git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

setup() {
  TMP="$(mktemp -d)"
  export ARNESS_ROOT="$TMP/root"
  mkdir -p "$ARNESS_ROOT"
  # origin with 3 commits
  ORIGIN="$TMP/origin/my-repo.git"
  mkdir -p "$ORIGIN"
  git_q init -q "$ORIGIN"
  for i in 1 2 3; do
    echo "$i" > "$ORIGIN/f.txt"
    git_q -C "$ORIGIN" add f.txt
    git_q -C "$ORIGIN" commit -q -m "c$i"
  done
  URL="file://$ORIGIN"
  SRC="$ARNESS_ROOT/source"
}

teardown() { rm -rf "$TMP"; }

# --- clone ---------------------------------------------------------------

@test "clones a new repo into source/<derived name>" {
  run "$SCRIPT" "$URL"
  [ "$status" -eq 0 ]
  [ "$output" = "CLONED $SRC/my-repo" ]
  [ -f "$SRC/my-repo/f.txt" ]
}

@test "creates source/ when missing" {
  [ ! -e "$SRC" ]
  run "$SCRIPT" --name x "$URL"
  [ "$status" -eq 0 ]
  [ -d "$SRC/x/.git" ]
}

@test "clone is full by default" {
  run "$SCRIPT" --name x "$URL"
  [ "$status" -eq 0 ]
  [ "$(git -C "$SRC/x" rev-list --count HEAD)" -eq 3 ]
}

@test "--depth makes a shallow clone" {
  run "$SCRIPT" --name x --depth 1 "$URL"
  [ "$status" -eq 0 ]
  [ "$(git -C "$SRC/x" rev-list --count HEAD)" -eq 1 ]
}

@test "leaves no temp dirs behind on success" {
  "$SCRIPT" --name x "$URL"
  [ -z "$(ls -A "$SRC" | grep '^\.repo-clone' || true)" ]
}

# --- validation ----------------------------------------------------------

@test "missing URL is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing repository URL"* ]]
}

@test "invalid URLs are rejected and nothing is created" {
  for bad in "" "plain-text" "/local/path" "ftp://host/repo.git" "ext::sh -c touch /tmp/pwned" \
             "-oops" "--upload-pack=evil" "https://host/a b" "ssh://-oProxyCommand=x/repo" "git@-host:repo"; do
    run "$SCRIPT" "$bad"
    [ "$status" -eq 2 ] || { echo "accepted: '$bad' (status $status)"; return 1; }
  done
  [ -z "$(ls -A "$SRC" 2>/dev/null)" ]
}

@test "two URLs is a usage error" {
  run "$SCRIPT" "$URL" "$URL"
  [ "$status" -eq 2 ]
}

@test "unknown option is a usage error" {
  run "$SCRIPT" --bogus "$URL"
  [ "$status" -eq 2 ]
}

@test "--name rejects path traversal and odd names" {
  for bad in "" "." ".." "../x" "a/b" "/abs" "-x" "a b" 'a\b' "a;b"; do
    run "$SCRIPT" --name "$bad" "$URL"
    [ "$status" -eq 2 ] || { echo "accepted name: '$bad' (status $status)"; return 1; }
  done
  [ -z "$(ls -A "$SRC" 2>/dev/null)" ]
  [ ! -e "$ARNESS_ROOT/x" ]
}

@test "--depth rejects non positive integers" {
  for bad in 0 -1 abc 1.5 ""; do
    run "$SCRIPT" --depth "$bad" --name x "$URL"
    [ "$status" -eq 2 ] || { echo "accepted depth: '$bad' (status $status)"; return 1; }
  done
}

@test "--name without value fails" {
  run "$SCRIPT" "$URL" --name
  [ "$status" -eq 2 ]
}

# --- derive_name (sourced) -----------------------------------------------

@test "derive_name handles common URL shapes" {
  . "$SCRIPT"
  [ "$(derive_name https://github.com/Org/repo.git)" = "repo" ]
  [ "$(derive_name https://github.com/Org/repo)" = "repo" ]
  [ "$(derive_name https://github.com/Org/repo/)" = "repo" ]
  [ "$(derive_name https://github.com/Org/repo.git/)" = "repo" ]
  [ "$(derive_name git@github.com:Org/repo.git)" = "repo" ]
  [ "$(derive_name git@host:repo.git)" = "repo" ]
  [ "$(derive_name ssh://git@host:22/org/sub/repo.git)" = "repo" ]
  [ "$(derive_name file:///tmp/a/b.git)" = "b" ]
}

# --- exists / overwrite / copy -------------------------------------------

@test "existing destination reports EXISTS and changes nothing" {
  "$SCRIPT" --name x "$URL"
  echo keep > "$SRC/x/marker"
  run "$SCRIPT" --name x "$URL"
  [ "$status" -eq 10 ]
  [ "$output" = "EXISTS $SRC/x" ]
  [ -f "$SRC/x/marker" ]
}

@test "--overwrite replaces a clean repo" {
  "$SCRIPT" --name x "$URL"
  run "$SCRIPT" --overwrite --name x "$URL"
  [ "$status" -eq 0 ]
  [ "$output" = "CLONED $SRC/x" ]
}

@test "--overwrite really replaces content" {
  "$SCRIPT" --name x "$URL"
  # origin advances; the clean local copy is behind
  echo 4 > "$ORIGIN/f.txt"; git_q -C "$ORIGIN" commit -qam c4
  [ "$(git -C "$SRC/x" rev-list --count HEAD)" -eq 3 ]
  run "$SCRIPT" --overwrite --name x "$URL"
  [ "$status" -eq 0 ]
  [ "$(git -C "$SRC/x" rev-list --count HEAD)" -eq 4 ]
}

@test "overwrite refused on uncommitted changes, allowed with --force" {
  "$SCRIPT" --name x "$URL"
  echo dirty > "$SRC/x/new-file"
  run "$SCRIPT" --overwrite --name x "$URL"
  [ "$status" -eq 11 ]
  [ "$output" = "DIRTY $SRC/x uncommitted-changes" ]
  [ -f "$SRC/x/new-file" ]
  run "$SCRIPT" --overwrite --force --name x "$URL"
  [ "$status" -eq 0 ]
  [ ! -e "$SRC/x/new-file" ]
}

@test "overwrite refused on unpushed commits" {
  "$SCRIPT" --name x "$URL"
  echo local > "$SRC/x/local.txt"
  git_q -C "$SRC/x" add local.txt
  git_q -C "$SRC/x" commit -q -m local
  run "$SCRIPT" --overwrite --name x "$URL"
  [ "$status" -eq 11 ]
  [ "$output" = "DIRTY $SRC/x unpushed-commits" ]
  [ -f "$SRC/x/local.txt" ]
}

@test "overwrite refused on a non-git dir even inside an enclosing git repo" {
  git_q init -q "$ARNESS_ROOT"          # enclosing repo must not fool the check
  mkdir -p "$SRC/x"; echo mine > "$SRC/x/file"
  run "$SCRIPT" --overwrite --name x "$URL"
  [ "$status" -eq 11 ]
  [ "$output" = "DIRTY $SRC/x not-a-git-repo" ]
  [ -f "$SRC/x/file" ]
  run "$SCRIPT" --overwrite --force --name x "$URL"
  [ "$status" -eq 0 ]
  [ -d "$SRC/x/.git" ]
}

@test "copy under another name keeps the original" {
  "$SCRIPT" --name x "$URL"
  echo keep > "$SRC/x/marker"
  run "$SCRIPT" --name x-copy "$URL"
  [ "$status" -eq 0 ]
  [ -f "$SRC/x/marker" ]
  [ -d "$SRC/x-copy/.git" ]
}

@test "--name pointing at an existing dir reports EXISTS again" {
  "$SCRIPT" --name x "$URL"
  "$SCRIPT" --name y "$URL"
  run "$SCRIPT" --name y "$URL"
  [ "$status" -eq 10 ]
}

@test "destination that is a symlink is refused and its target untouched" {
  mkdir -p "$SRC" "$TMP/elsewhere"
  echo precious > "$TMP/elsewhere/data"
  ln -s "$TMP/elsewhere" "$SRC/x"
  run "$SCRIPT" --overwrite --force --name x "$URL"
  [ "$status" -eq 2 ]
  [ -f "$TMP/elsewhere/data" ]
}

@test "destination that is a regular file is refused" {
  mkdir -p "$SRC"; echo f > "$SRC/x"
  run "$SCRIPT" --overwrite --force --name x "$URL"
  [ "$status" -eq 2 ]
  [ -f "$SRC/x" ]
}

# --- failures ------------------------------------------------------------

@test "clone failure exits 3 and leaves no partial dir" {
  run "$SCRIPT" --name x "file://$TMP/does-not-exist.git"
  [ "$status" -eq 3 ]
  [ ! -e "$SRC/x" ]
  [ -z "$(ls -A "$SRC")" ]
}

@test "failed overwrite keeps the existing copy" {
  "$SCRIPT" --name x "$URL"
  echo keep > "$SRC/x/marker"
  rm -rf "$ORIGIN"
  run "$SCRIPT" --overwrite --force --name x "$URL"
  [ "$status" -eq 3 ]
  [ -f "$SRC/x/marker" ]
}

# --- environment ---------------------------------------------------------

@test "resolves the repo root through the .claude/skills symlink" {
  REAL="$TMP/real repo"                       # space in path on purpose
  mkdir -p "$REAL/skills" "$REAL/.claude"
  cp -R "$SKILL_DIR" "$REAL/skills/repo-clone"
  ln -s ../skills "$REAL/.claude/skills"
  run env -u ARNESS_ROOT "$REAL/.claude/skills/repo-clone/scripts/repo-clone.sh" --name x "$URL"
  [ "$status" -eq 0 ]
  [ -d "$REAL/source/x/.git" ]
  [ ! -e "$REAL/.claude/source" ]
}

@test "works from another working directory" {
  cd /
  run "$SCRIPT" --name x "$URL"
  [ "$status" -eq 0 ]
  [ -d "$SRC/x/.git" ]
}

@test "works with the macOS system bash (3.2) when available" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run /bin/bash "$SCRIPT" --name x "$URL"
  [ "$status" -eq 0 ]
}
