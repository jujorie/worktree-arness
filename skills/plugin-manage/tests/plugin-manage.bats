#!/usr/bin/env bats
# Unit tests for skills/plugin-manage/scripts/plugin-manage.sh.
# Each test runs against a throwaway arness sandbox and a local plugin repo (file://).

load "../../../tests/helpers"
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"   # helpers assume tests/ one level down

SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

# write_conf [extra lines...]: the demo manifest, with extra lines appended.
write_conf() {
  {
    printf '%s\n' 'name=demo' 'version=0.1.0' 'prefix=demo-' 'arness=1' 'description=Demo plugin for tests'
    printf '%s\n' 'skills=demo-hello' 'agents=demo-helper' 'requires=git' 'install=touch installed.flag'
    printf '%s\n' "uninstall=touch $BATS_TEST_TMPDIR/uninstalled.flag"
    printf '%s\n' 'allow.claude=Bash(demo-tool *)' 'allow.opencode=demo-tool *'
    if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi
  } > "$ORIGIN/arness-plugin.conf"
}

commit_origin() { git_q -C "$ORIGIN" add -A; git_q -C "$ORIGIN" commit -q -m "$1"; }

last_line() { printf '%s\n' "$output" | awk 'END { print }'; }

# The status line starting with $1 (stderr is mixed into $output).
status_line() { printf '%s\n' "$output" | grep "^$1 " | awk 'NR == 1'; }

setup() {
  make_sandbox
  cp -R "$SKILL_DIR" "$SANDBOX/skills/"
  SCRIPT="$SANDBOX/skills/plugin-manage/scripts/plugin-manage.sh"
  ORIGIN="$BATS_TEST_TMPDIR/origin/demo-plugin"
  mkdir -p "$ORIGIN/skills/demo-hello" "$ORIGIN/agents"
  printf -- '---\nname: demo-hello\ndescription: Say hello.\n---\n' > "$ORIGIN/skills/demo-hello/SKILL.md"
  printf -- '---\nname: demo-helper\n---\n' > "$ORIGIN/agents/demo-helper.md"
  git_q init -q "$ORIGIN"
  write_conf
  commit_origin "c1"
  URL="file://$ORIGIN"
}

teardown() { cleanup_sandbox; }

add_demo() {
  local c
  c="$(git -C "$ORIGIN" rev-parse HEAD)"
  "$SCRIPT" add --yes --commit "$c" "$@" "$URL" >/dev/null 2>&1
}

# --- add -------------------------------------------------------------------------

@test "add without --yes prints the plan and writes nothing" {
  run "$SCRIPT" add "$URL"
  [ "$status" -eq 20 ]
  [ "$(last_line)" = "CONFIRM_ADD demo $(git -C "$ORIGIN" rev-parse HEAD)" ]
  [[ "$output" == *"PLUGIN demo 0.1.0 "* ]]
  [[ "$output" == *"SKILL demo-hello"* && "$output" == *"AGENT demo-helper"* ]]
  [[ "$output" == *"ALLOW claude Bash(demo-tool *)"* && "$output" == *"ALLOW opencode demo-tool *"* ]]
  [[ "$output" == *"INSTALL touch installed.flag"* ]]
  [ ! -e "$SANDBOX/plugins/demo" ] && [ ! -L "$SANDBOX/skills/demo-hello" ]
  [ -z "$(ls -A "$SANDBOX/plugins")" ]
}

@test "add --yes clones, links skills and agents, runs install" {
  run "$SCRIPT" add --yes "$URL"
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "ADDED demo $SANDBOX/plugins/demo" ]
  [ "$(readlink "$SANDBOX/skills/demo-hello")" = "../plugins/demo/skills/demo-hello" ]
  [ "$(readlink "$SANDBOX/agents/demo-helper.md")" = "../plugins/demo/agents/demo-helper.md" ]
  [ -f "$SANDBOX/skills/demo-hello/SKILL.md" ]
  [ -f "$SANDBOX/plugins/demo/installed.flag" ]
  [[ "$output" == *"MANUAL opencode demo-tool *"* ]]
}

@test "add renders the plugin's Claude rules when claude is set up" {
  bash "$SANDBOX/setup.sh" --provider claude >/dev/null
  ! grep -qF 'demo' "$SANDBOX/.claude/settings.json"
  add_demo
  grep -qF '"Skill(demo-hello)",' "$SANDBOX/.claude/settings.json"
  grep -qF '"Bash(demo-tool *)",' "$SANDBOX/.claude/settings.json"
  json_looks_valid "$SANDBOX/.claude/settings.json"
}

@test "add --ref checks out a tag" {
  git_q -C "$ORIGIN" tag v0.1.0
  write_conf; sed 's/^version=.*/version=0.2.0/' "$ORIGIN/arness-plugin.conf" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$ORIGIN/arness-plugin.conf"
  commit_origin "c2"
  run "$SCRIPT" add --yes --ref v0.1.0 "$URL"
  [ "$status" -eq 0 ]
  grep -qx 'version=0.1.0' "$SANDBOX/plugins/demo/arness-plugin.conf"
}

@test "add --commit that differs from the fetched commit is a MISMATCH" {
  run "$SCRIPT" add --yes --commit 0000000 "$URL"
  [ "$status" -eq 14 ]
  [[ "$(last_line)" == "MISMATCH 0000000 "* ]]
  [ ! -e "$SANDBOX/plugins/demo" ]
}

@test "add twice is ALREADY_INSTALLED" {
  add_demo
  run "$SCRIPT" add --yes "$URL"
  [ "$status" -eq 10 ]
  [ "$(last_line)" = "ALREADY_INSTALLED demo" ]
}

@test "add refuses a skill name taken by a real folder and leaves it intact" {
  mkdir -p "$SANDBOX/skills/demo-hello"
  echo mine > "$SANDBOX/skills/demo-hello/SKILL.md"
  run "$SCRIPT" add --yes "$URL"
  [ "$status" -eq 6 ]
  [ "$(last_line)" = "NAME_CONFLICT skills/demo-hello" ]
  [ "$(cat "$SANDBOX/skills/demo-hello/SKILL.md")" = mine ]
  [ ! -e "$SANDBOX/plugins/demo" ]
}

@test "add refuses an agent name taken by a real file" {
  echo mine > "$SANDBOX/agents/demo-helper.md"
  run "$SCRIPT" add --yes "$URL"
  [ "$status" -eq 6 ]
  [ "$(last_line)" = "NAME_CONFLICT agents/demo-helper.md" ]
}

@test "add with a missing requirement is MISSING_REQUIREMENT" {
  write_conf; sed 's/^requires=.*/requires=git no-such-cmd-xyz/' "$ORIGIN/arness-plugin.conf" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$ORIGIN/arness-plugin.conf"
  commit_origin "req"
  run "$SCRIPT" add --yes "$URL"
  [ "$status" -eq 5 ]
  [ "$(last_line)" = "MISSING_REQUIREMENT no-such-cmd-xyz" ]
  [ ! -e "$SANDBOX/plugins/demo" ]
}

@test "a failing install is INSTALL_FAILED, keeps the links and shows in list" {
  write_conf; sed 's/^install=.*/install=exit 3/' "$ORIGIN/arness-plugin.conf" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$ORIGIN/arness-plugin.conf"
  commit_origin "bad install"
  run "$SCRIPT" add --yes "$URL"
  [ "$status" -eq 13 ]
  [ "$(last_line)" = "INSTALL_FAILED demo" ]
  [ -L "$SANDBOX/skills/demo-hello" ]
  run "$SCRIPT" list
  [[ "$output" == *"INSTALLED demo 0.1.0 "*" INSTALL_FAILED 1/1 1/1"* ]]
}

@test "add rejects invalid URLs" {
  run "$SCRIPT" add --yes "-oops"
  [ "$status" -eq 2 ]
  run "$SCRIPT" add --yes "not a url"
  [ "$status" -eq 2 ]
  [ ! -e "$SANDBOX/plugins/demo" ]
}

@test "a failed clone exits 3 and leaves no temp dir" {
  run "$SCRIPT" add --yes "file://$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 3 ]
  [ -z "$(ls -A "$SANDBOX/plugins")" ]
}

# --- manifest validation (check) ---------------------------------------------------

check_with() {
  write_conf "$@"
  run "$SCRIPT" check "$ORIGIN"
}

@test "check accepts the demo plugin" {
  run "$SCRIPT" check "$ORIGIN"
  [ "$status" -eq 0 ]
  [ "$output" = "VALID demo 0.1.0" ]
}

@test "check rejects an unknown key with its line number" {
  check_with 'colour=blue'
  [ "$status" -eq 4 ]
  [ "$output" = "BAD_MANIFEST line 13: unknown key colour" ]
}

@test "check rejects a repeated single key" {
  check_with 'name=other'
  [ "$status" -eq 4 ]
  [[ "$output" == "BAD_MANIFEST line 13: duplicate key name" ]]
}

@test "check rejects a line that is not KEY=value" {
  check_with 'just words'
  [ "$status" -eq 4 ]
  [[ "$output" == "BAD_MANIFEST line 13: not KEY=value" ]]
}

@test "check rejects a missing manifest" {
  rm "$ORIGIN/arness-plugin.conf"
  run "$SCRIPT" check "$ORIGIN"
  [ "$status" -eq 4 ]
  [ "$output" = "BAD_MANIFEST missing arness-plugin.conf" ]
}

@test "check rejects an unsupported contract version" {
  sed 's/^arness=.*/arness=2/' "$ORIGIN/arness-plugin.conf" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$ORIGIN/arness-plugin.conf"
  run "$SCRIPT" check "$ORIGIN"
  [ "$status" -eq 4 ]
  [ "$output" = "ARNESS_VERSION 2" ]
}

@test "check rejects broad permission rules" {
  for rule in 'allow.claude=Bash(*)' 'allow.claude=Bash' 'allow.claude=Bash( rm)' 'allow.opencode=*'; do
    check_with "$rule"
    [ "$status" -eq 4 ]
    [[ "$output" == "BROAD_PERMISSION "* ]]
  done
}

@test "check rejects a rule that would break the JSON" {
  for rule in 'allow.claude=Bash(x ")' 'allow.claude=Bash(x \\)'; do
    check_with "$rule"
    [ "$status" -eq 4 ]
    [[ "$output" == "BAD_MANIFEST allow.claude: quote"* ]]
  done
}

@test "check rejects a claude rule that is not Tool(pattern)" {
  check_with 'allow.claude=demo-tool *'
  [ "$status" -eq 4 ]
  [[ "$output" == "BAD_MANIFEST allow.claude: not Tool(pattern)"* ]]
}

@test "check rejects a skill without the plugin prefix" {
  mkdir -p "$ORIGIN/skills/hello"
  printf -- '---\nname: hello\n---\n' > "$ORIGIN/skills/hello/SKILL.md"
  write_conf; sed 's/^skills=.*/skills=hello/' "$ORIGIN/arness-plugin.conf" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$ORIGIN/arness-plugin.conf"
  run "$SCRIPT" check "$ORIGIN"
  [ "$status" -eq 4 ]
  [ "$output" = "BAD_MANIFEST skills: hello lacks prefix demo-" ]
}

@test "check rejects a declared skill that is missing or misnamed" {
  rm "$ORIGIN/skills/demo-hello/SKILL.md"
  run "$SCRIPT" check "$ORIGIN"
  [ "$status" -eq 4 ]
  [ "$output" = "INVALID skills/demo-hello/SKILL.md not found" ]
  printf -- '---\nname: other\n---\n' > "$ORIGIN/skills/demo-hello/SKILL.md"
  run "$SCRIPT" check "$ORIGIN"
  [ "$output" = "INVALID skills/demo-hello/SKILL.md lacks 'name: demo-hello'" ]
}

@test "check rejects names with glob or path characters" {
  write_conf; sed 's/^skills=.*/skills=..\/x */' "$ORIGIN/arness-plugin.conf" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$ORIGIN/arness-plugin.conf"
  run "$SCRIPT" check "$ORIGIN"
  [ "$status" -eq 4 ]
  [ "$output" = "BAD_MANIFEST skills: names must be lowercase slugs" ]
}

@test "check rejects a bad version, name and prefix" {
  for line in 's/^version=.*/version=1.0/' 's/^name=.*/name=Demo/' 's/^prefix=.*/prefix=demo/'; do
    write_conf; sed "$line" "$ORIGIN/arness-plugin.conf" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$ORIGIN/arness-plugin.conf"
    run "$SCRIPT" check "$ORIGIN"
    [ "$status" -eq 4 ]
    [[ "$output" == "BAD_MANIFEST "* ]]
  done
}

# --- update ----------------------------------------------------------------------------

@test "update with nothing new is UP_TO_DATE" {
  add_demo
  run "$SCRIPT" update demo
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "UP_TO_DATE demo $(git -C "$ORIGIN" rev-parse HEAD)" ]
}

@test "update shows new rules, then relinks and runs install once confirmed" {
  add_demo
  rm -rf "$ORIGIN/agents"
  write_conf 'allow.claude=Bash(demo-other *)'
  sed '/^agents=/d; s/^version=.*/version=0.2.0/' "$ORIGIN/arness-plugin.conf" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$ORIGIN/arness-plugin.conf"
  commit_origin "c2"
  new="$(git -C "$ORIGIN" rev-parse HEAD)"
  run "$SCRIPT" update demo
  [ "$status" -eq 20 ]
  [[ "$(last_line)" == "CONFIRM_UPDATE demo "*" $new" ]]
  [[ "$output" == *"NEW_ALLOW claude Bash(demo-other *)"* ]]
  [[ "$output" != *"NEW_ALLOW claude Bash(demo-tool *)"* ]]
  [ -L "$SANDBOX/agents/demo-helper.md" ]
  run "$SCRIPT" update --yes --commit "$new" demo
  [ "$status" -eq 0 ]
  [[ "$(last_line)" == "UPDATED demo "*" $new" ]]
  [ ! -e "$SANDBOX/agents/demo-helper.md" ] && [ ! -L "$SANDBOX/agents/demo-helper.md" ]
  [ -L "$SANDBOX/skills/demo-hello" ]
  grep -qx 'version=0.2.0' "$SANDBOX/plugins/demo/arness-plugin.conf"
}

@test "update to an invalid version leaves the installed one untouched" {
  add_demo
  write_conf 'colour=blue'
  commit_origin "broken"
  run "$SCRIPT" update --yes demo
  [ "$status" -eq 4 ]
  [ "$(git -C "$SANDBOX/plugins/demo" rev-parse HEAD)" != "$(git -C "$ORIGIN" rev-parse HEAD)" ]
  [ -L "$SANDBOX/skills/demo-hello" ]
}

@test "update --ref moves to a tag" {
  add_demo
  write_conf; sed 's/^version=.*/version=0.3.0/' "$ORIGIN/arness-plugin.conf" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$ORIGIN/arness-plugin.conf"
  commit_origin "c3"
  git_q -C "$ORIGIN" tag v0.3.0
  run "$SCRIPT" update --yes --ref v0.3.0 demo
  [ "$status" -eq 0 ]
  grep -qx 'version=0.3.0' "$SANDBOX/plugins/demo/arness-plugin.conf"
}

@test "update refuses a clone with local changes" {
  add_demo
  echo x >> "$SANDBOX/plugins/demo/arness-plugin.conf"
  run "$SCRIPT" update demo
  [ "$status" -eq 11 ]
  [ "$(last_line)" = "DIRTY $SANDBOX/plugins/demo uncommitted-changes" ]
}

@test "update ignores untracked build output of install" {
  add_demo
  [ -f "$SANDBOX/plugins/demo/installed.flag" ]
  run "$SCRIPT" update demo
  [ "$status" -eq 0 ]
}

@test "update of a plugin that is not installed is NOT_INSTALLED" {
  run "$SCRIPT" update demo
  [ "$status" -eq 12 ]
  [ "$(last_line)" = "NOT_INSTALLED demo" ]
}

@test "update and remove reject invalid names" {
  run "$SCRIPT" update ../x
  [ "$status" -eq 2 ]
  run "$SCRIPT" remove ../x
  [ "$status" -eq 2 ]
}

# --- remove ------------------------------------------------------------------------------

@test "remove asks first, then restores skills, agents and settings exactly" {
  bash "$SANDBOX/setup.sh" --provider claude >/dev/null 2>&1
  before="$(cat "$SANDBOX/.claude/settings.json")"
  add_demo
  run "$SCRIPT" remove demo
  [ "$status" -eq 20 ]
  [ "$(last_line)" = "CONFIRM_REMOVE demo" ]
  [[ "$output" == *"UNINSTALL touch "* ]]
  [ -d "$SANDBOX/plugins/demo" ]
  run "$SCRIPT" remove --yes demo
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "REMOVED demo" ]
  [ -f "$BATS_TEST_TMPDIR/uninstalled.flag" ]
  [ ! -e "$SANDBOX/plugins/demo" ]
  [ -z "$(ls -A "$SANDBOX/skills" | grep -v plugin-manage || true)" ]
  [ -z "$(ls -A "$SANDBOX/agents")" ]
  [ "$(cat "$SANDBOX/.claude/settings.json")" = "$before" ]
}

@test "remove refuses a dirty clone without --force" {
  add_demo
  echo x >> "$SANDBOX/plugins/demo/arness-plugin.conf"
  run "$SCRIPT" remove --yes demo
  [ "$status" -eq 11 ]
  [ -d "$SANDBOX/plugins/demo" ]
  run "$SCRIPT" remove --yes --force demo
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/plugins/demo" ]
}

@test "remove never deletes a real file that shares a plugin skill name" {
  add_demo
  rm "$SANDBOX/skills/demo-hello"
  mkdir "$SANDBOX/skills/demo-hello"
  run "$SCRIPT" remove --yes demo
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/skills/demo-hello" ]
}

# --- list and sync -------------------------------------------------------------------------

@test "list says NONE without plugins" {
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
}

@test "list shows OK, then BROKEN_LINK when a link is gone" {
  add_demo
  short="$(git -C "$ORIGIN" rev-parse --short HEAD)"
  run "$SCRIPT" list
  [ "$output" = "INSTALLED demo 0.1.0 $short OK 1/1 1/1" ]
  rm "$SANDBOX/skills/demo-hello"
  run "$SCRIPT" list
  [ "$output" = "INSTALLED demo 0.1.0 $short BROKEN_LINK 0/1 1/1" ]
}

@test "sync restores missing links and skips paths taken by something else" {
  add_demo
  rm "$SANDBOX/skills/demo-hello" "$SANDBOX/agents/demo-helper.md"
  echo mine > "$SANDBOX/agents/demo-helper.md"
  run "$SCRIPT" sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYNCED demo"* ]]
  [[ "$output" == *"warning: agents/demo-helper.md exists, not linked"* ]]
  [ -L "$SANDBOX/skills/demo-hello" ]
  [ "$(cat "$SANDBOX/agents/demo-helper.md")" = mine ]
}

@test "setup.sh restores plugin links" {
  add_demo
  rm "$SANDBOX/skills/demo-hello"
  run bash "$SANDBOX/setup.sh" --provider claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> plugins"* ]]
  [ -L "$SANDBOX/skills/demo-hello" ]
  grep -qF '"Skill(demo-hello)",' "$SANDBOX/.claude/settings.json"
}

@test "plugin clones and links are git-ignored" {
  cp "$REPO_ROOT/skills/.gitignore" "$SANDBOX/skills/"
  cp "$REPO_ROOT/agents/.gitignore" "$SANDBOX/agents/"
  mkdir -p "$SANDBOX/plugins"
  cp "$REPO_ROOT/plugins/.gitignore" "$SANDBOX/plugins/"
  git_q init -q "$SANDBOX"
  git_q -C "$SANDBOX" add -A
  git_q -C "$SANDBOX" commit -q -m base
  add_demo
  [ -z "$(git -C "$SANDBOX" status --porcelain)" ]
}

@test "unknown command and no command are usage errors" {
  run "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: plugin-manage.sh add"* ]]
}
