#!/usr/bin/env bats
load helpers

setup()    { make_sandbox; }
teardown() { cleanup_sandbox; }

@test "no args fails and lists available providers" {
  run bash "$SANDBOX/setup.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--provider is required"* ]]
  [[ "$output" == *"claude"* && "$output" == *"codex"* && "$output" == *"opencode"* ]]
  [ ! -e "$SANDBOX/.claude" ] && [ ! -e "$SANDBOX/.agents" ]
}

@test "--help prints usage and exits 0" {
  run bash "$SANDBOX/setup.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "auto with no CLIs installed fails with usage" {
  run env PATH="/usr/bin:/bin" bash "$SANDBOX/setup.sh" --provider auto
  [ "$status" -eq 1 ]
  [[ "$output" == *"no installed provider"* ]]
}

@test "unknown provider is rejected" {
  run bash "$SANDBOX/setup.sh" --provider nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown provider"* && "$output" == *"Usage:"* ]]
}

@test "unknown argument is rejected" {
  run bash "$SANDBOX/setup.sh" --bogus
  [ "$status" -eq 2 ]
}

@test "--provider without value fails" {
  run bash "$SANDBOX/setup.sh" --provider
  [ "$status" -ne 0 ]
}

@test "--provider=claude form works" {
  run bash "$SANDBOX/setup.sh" --provider=claude
  [ "$status" -eq 0 ]
  [ -L "$SANDBOX/.claude/skills" ]
}

@test "claude provider creates skills, agents, settings, CLAUDE.md" {
  run bash "$SANDBOX/setup.sh" --provider claude
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.claude/skills" ] && [ -L "$SANDBOX/.claude/skills" ]
  [ -d "$SANDBOX/.claude/agents" ] && [ -L "$SANDBOX/.claude/agents" ]
  [ -s "$SANDBOX/.claude/settings.json" ]
  [ -s "$SANDBOX/CLAUDE.md" ]
  [ ! -e "$SANDBOX/.agents" ]
}

@test "codex and opencode link .agents/skills" {
  run bash "$SANDBOX/setup.sh" --provider codex,opencode
  [ "$status" -eq 0 ]
  [ -L "$SANDBOX/.agents/skills" ] && [ -d "$SANDBOX/.agents/skills" ]
  [ ! -e "$SANDBOX/.claude" ]
}

@test "all runs every provider" {
  run bash "$SANDBOX/setup.sh" --provider all
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> claude"* && "$output" == *"==> codex"* && "$output" == *"==> opencode"* ]]
}

@test "auto selects only installed CLIs" {
  mkdir "$SANDBOX/fakebin"
  printf '#!/bin/sh\n' > "$SANDBOX/fakebin/codex"; chmod +x "$SANDBOX/fakebin/codex"
  run env PATH="$SANDBOX/fakebin:/usr/bin:/bin" bash "$SANDBOX/setup.sh" --provider auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> codex"* ]]
  [[ "$output" != *"==> claude"* ]]
}

@test "running twice gives identical result" {
  bash "$SANDBOX/setup.sh" --provider all >/dev/null
  snap1=$(cd "$SANDBOX" && find .claude .agents CLAUDE.md -exec ls -ld {} \; | awk '{$6=$7=$8="";print}')
  run bash "$SANDBOX/setup.sh" --provider all
  [ "$status" -eq 0 ]
  snap2=$(cd "$SANDBOX" && find .claude .agents CLAUDE.md -exec ls -ld {} \; | awk '{$6=$7=$8="";print}')
  [ "$snap1" = "$snap2" ]
  [ ! -e "$SANDBOX/.claude/settings.json.bak" ]
}

@test "works when called from another directory" {
  cd /
  run bash "$SANDBOX/setup.sh" --provider claude
  [ "$status" -eq 0 ]
  [ -L "$SANDBOX/.claude/skills" ]
}

@test "works when called through a symlink to the repo" {
  ln -s "$SANDBOX" "$BATS_TEST_TMPDIR/alias"
  run bash "$BATS_TEST_TMPDIR/alias/setup.sh" --provider claude
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.claude/skills" ]
}

@test "provider script runs standalone without ARNESS_ROOT" {
  unset ARNESS_ROOT
  run bash "$SANDBOX/providers/claude/setup.sh"
  [ "$status" -eq 0 ]
  [ -L "$SANDBOX/.claude/skills" ]
}

@test "works with the macOS system bash (3.2) when available" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run /bin/bash "$SANDBOX/setup.sh" --provider all
  [ "$status" -eq 0 ]
}

@test "works in a path with spaces" {
  cleanup_sandbox
  make_sandbox 'my repo'
  run bash "$SANDBOX/setup.sh" --provider all
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.claude/skills" ]
  grep -qF "$SANDBOX/.memory" "$SANDBOX/.claude/settings.json"
}

@test "opencode creates valid opencode.json loading the memory index" {
  run bash "$SANDBOX/setup.sh" --provider opencode
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.memory/MEMORY.md" ]
  grep -qF '".memory/MEMORY.md"' "$SANDBOX/opencode.json"
  json_looks_valid "$SANDBOX/opencode.json"
}

@test "opencode keeps existing opencode.json and memory index" {
  mkdir -p "$SANDBOX/.memory"
  echo '{"model":"x"}' > "$SANDBOX/opencode.json"
  echo '- [A](a.md) — hook' > "$SANDBOX/.memory/MEMORY.md"
  run bash "$SANDBOX/setup.sh" --provider opencode
  [ "$status" -eq 0 ]
  [ "$(cat "$SANDBOX/opencode.json")" = '{"model":"x"}' ]
  [ "$(cat "$SANDBOX/.memory/MEMORY.md")" = '- [A](a.md) — hook' ]
}

@test "on windows, claude settings get the C:/ style root and skills a junction" {
  ln -s "$SANDBOX" "$BATS_TEST_TMPDIR/win-root"
  fake_os MINGW64_NT-10.0 "$BATS_TEST_TMPDIR/win-root"
  run bash "$SANDBOX/setup.sh" --provider claude
  [ "$status" -eq 0 ]
  grep -qF "\"autoMemoryDirectory\": \"$BATS_TEST_TMPDIR/win-root/.memory\"" "$SANDBOX/.claude/settings.json"
  grep -q 'mklink /J .*/.claude/skills ' "$FAKE_CALLS"
  grep -q 'mklink /J .*/.claude/agents ' "$FAKE_CALLS"
}
