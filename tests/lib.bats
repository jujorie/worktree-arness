#!/usr/bin/env bats
load helpers

setup()    { make_sandbox; }
teardown() { cleanup_sandbox; }

@test "link creates relative symlink that resolves" {
  run with_lib 'link ../skills .claude/skills'
  [ "$status" -eq 0 ]
  [ -L "$SANDBOX/.claude/skills" ]
  [ "$(readlink "$SANDBOX/.claude/skills")" = "../skills" ]
  [ -d "$SANDBOX/.claude/skills" ]
}

@test "link is idempotent" {
  with_lib 'link ../skills .claude/skills'
  run with_lib 'link ../skills .claude/skills'
  [ "$status" -eq 0 ]
  [ "$(readlink "$SANDBOX/.claude/skills")" = "../skills" ]
}

@test "link repoints an existing symlink" {
  mkdir "$SANDBOX/other"
  mkdir -p "$SANDBOX/.claude"
  ln -s ../other "$SANDBOX/.claude/skills"
  run with_lib 'link ../skills .claude/skills'
  [ "$status" -eq 0 ]
  [ "$(readlink "$SANDBOX/.claude/skills")" = "../skills" ]
}

@test "link does not overwrite a real file and warns" {
  mkdir -p "$SANDBOX/.claude"
  echo keep > "$SANDBOX/.claude/skills"
  run with_lib 'link ../skills .claude/skills'
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]]
  [ ! -L "$SANDBOX/.claude/skills" ]
  [ "$(cat "$SANDBOX/.claude/skills")" = "keep" ]
}

@test "link does not overwrite a real directory" {
  mkdir -p "$SANDBOX/.claude/skills"
  touch "$SANDBOX/.claude/skills/mine"
  run with_lib 'link ../skills .claude/skills'
  [ "$status" -eq 0 ]
  [ ! -L "$SANDBOX/.claude/skills" ]
  [ -e "$SANDBOX/.claude/skills/mine" ]
}

@test "link replaces an empty placeholder file" {
  : > "$SANDBOX/CLAUDE.md"
  run with_lib 'link providers/claude/CLAUDE.md CLAUDE.md'
  [ "$status" -eq 0 ]
  [ -L "$SANDBOX/CLAUDE.md" ]
}

@test "copy_once copies when missing" {
  run with_lib 'copy_once providers/claude/CLAUDE.md CLAUDE.md'
  [ "$status" -eq 0 ]
  cmp "$SANDBOX/providers/claude/CLAUDE.md" "$SANDBOX/CLAUDE.md"
}

@test "copy_once keeps existing content" {
  echo mine > "$SANDBOX/CLAUDE.md"
  run with_lib 'copy_once providers/claude/CLAUDE.md CLAUDE.md'
  [ "$status" -eq 0 ]
  [ "$(cat "$SANDBOX/CLAUDE.md")" = "mine" ]
}

@test "render substitutes ARNESS_ROOT" {
  run with_lib 'render providers/claude/settings.json .claude/settings.json'
  [ "$status" -eq 0 ]
  grep -qF "\"$SANDBOX/.memory\"" "$SANDBOX/.claude/settings.json"
  ! grep -qF '{{' "$SANDBOX/.claude/settings.json"
}

@test "render output keeps the JSON structure" {
  with_lib 'render providers/claude/settings.json .claude/settings.json'
  json_looks_valid "$SANDBOX/.claude/settings.json"
  grep -qF "\"autoMemoryDirectory\": \"$SANDBOX/.memory\"" "$SANDBOX/.claude/settings.json"
}

@test "render handles spaces and sed-special chars in path" {
  cleanup_sandbox
  make_sandbox 'my repo & a|b\c'
  run with_lib 'render providers/claude/settings.json .claude/settings.json'
  [ "$status" -eq 0 ]
  grep -qF "$SANDBOX/.memory" "$SANDBOX/.claude/settings.json"
}

@test "render creates .bak only when content changes" {
  with_lib 'render providers/claude/settings.json .claude/settings.json'
  with_lib 'render providers/claude/settings.json .claude/settings.json'
  [ ! -e "$SANDBOX/.claude/settings.json.bak" ]
  echo '{}' > "$SANDBOX/.claude/settings.json"
  run with_lib 'render providers/claude/settings.json .claude/settings.json'
  [ -e "$SANDBOX/.claude/settings.json.bak" ]
  [ "$(cat "$SANDBOX/.claude/settings.json.bak")" = "{}" ]
}

@test "render leaves no temp files behind" {
  before=$(ls "${TMPDIR:-/tmp}" | wc -l)
  with_lib 'render providers/claude/settings.json .claude/settings.json'
  after=$(ls "${TMPDIR:-/tmp}" | wc -l)
  [ "$after" -le "$before" ]
}

@test "on windows, lib turns ARNESS_ROOT into a C:/ style path" {
  ln -s "$SANDBOX" "$BATS_TEST_TMPDIR/win-root"
  fake_os MINGW64_NT-10.0 "$BATS_TEST_TMPDIR/win-root"
  run with_lib 'echo "$ARNESS_ROOT"'
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/win-root" ]
}

@test "on windows, link makes a junction to the absolute directory" {
  fake_os MINGW64_NT-10.0
  run with_lib 'link ../skills .claude/skills'
  [ "$status" -eq 0 ]
  grep -qxF "cmd /c mklink /J $SANDBOX/.claude/skills $SANDBOX/skills" "$FAKE_CALLS"
  [ -d "$SANDBOX/.claude/skills" ]
}

@test "on windows, link repoints an existing junction" {
  fake_os MSYS_NT-10.0
  with_lib 'link ../skills .claude/skills'
  run with_lib 'link ../skills .claude/skills'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'mklink /J' "$FAKE_CALLS")" -eq 2 ]
  [ -L "$SANDBOX/.claude/skills" ] && [ -d "$SANDBOX/.claude/skills" ]
}

@test "on windows, link to a file makes a symlink, not a junction" {
  fake_os CYGWIN_NT-10.0
  run with_lib 'link providers/claude/CLAUDE.md CLAUDE.md'
  [ "$status" -eq 0 ]
  ! grep -q mklink "$FAKE_CALLS"
  [ -L "$SANDBOX/CLAUDE.md" ]
}

@test "outside windows, lib never calls cygpath or cmd" {
  fake_os Linux
  run with_lib 'link ../skills .claude/skills'
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_CALLS" ]
  [ "$(readlink "$SANDBOX/.claude/skills")" = "../skills" ]
}
