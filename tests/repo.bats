#!/usr/bin/env bats
load helpers

# All shell scripts shipped by the repo, including skill scripts.
all_scripts() {
  ls "$REPO_ROOT"/setup.sh "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/providers/*/setup.sh
  skill_scripts
}

# Scripts of the shared skills (local-* skills are not checked).
skill_scripts() {
  local d
  while IFS= read -r d; do ls "$d"scripts/*.sh 2>/dev/null || true; done < <(shared_skill_dirs "$REPO_ROOT")
}

@test "every script has a bash shebang and LF endings" {
  # entry points only: scripts/lib.sh is sourced, not executed
  for f in "$REPO_ROOT"/setup.sh "$REPO_ROOT"/providers/*/setup.sh $(skill_scripts); do
    [ "$(head -1 "$f")" = "#!/usr/bin/env bash" ]
    ! grep -q $'\r' "$f"
  done
}

@test "entry scripts are executable" {
  # entry points only: scripts/lib.sh is sourced, not executed
  for f in "$REPO_ROOT"/setup.sh "$REPO_ROOT"/providers/*/setup.sh $(skill_scripts); do
    [ -x "$f" ]
  done
}

@test "every provider named by setup.sh has a setup script" {
  for p in claude codex opencode; do
    [ -f "$REPO_ROOT/providers/$p/setup.sh" ]
  done
}

@test "settings template has no machine-specific absolute paths" {
  ! grep -E '/(Users|home)/' "$REPO_ROOT/providers/claude/settings.json"
}

@test "no GNU-only flags in scripts" {
  ! grep -nE 'readlink -f|sed -i|date -d|grep -P|mapfile|readarray' \
      $(all_scripts)
}

@test "shellcheck passes" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  run shellcheck -x -P SCRIPTDIR $(all_scripts)
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "AGENTS.md documents the memory contract" {
  grep -q '^## Memory' "$REPO_ROOT/AGENTS.md"
  grep -qF '.memory/MEMORY.md' "$REPO_ROOT/AGENTS.md"
}

@test "every skill has SKILL.md with name matching its directory" {
  while IFS= read -r d; do
    n="$(basename "$d")"
    [ -f "$d/SKILL.md" ]
    grep -qx "name: $n" "$d/SKILL.md"
    grep -q '^description: .' "$d/SKILL.md"
  done < <(shared_skill_dirs "$REPO_ROOT")
}

@test "skill scripts live under <skill>/scripts" {
  # no loose shell scripts directly in a skill folder or elsewhere in skills/
  [ -z "$(find "$REPO_ROOT/skills" -name '*.sh' -not -path '*/scripts/*' -not -path '*/skills/local-*')" ]
}

# --- permissions stay in sync with the skills --------------------------------
# A new skill (or script) without its permission entries would make agents ask for confirmation again.

# Print one problem per line for the repo at $1; no output means everything is in sync.
# Plain grep on the JSON files: they are small and kept one rule per line.
permission_problems() {
  local root="$1" claude="$1/providers/claude/settings.json" opencode="$1/providers/opencode/opencode.json"
  local d s f rule name md
  while IFS= read -r d; do
    s="$(basename "$d")"
    grep -qF "\"Skill($s)\"" "$claude" || echo "claude: missing Skill($s)"
    grep -qF "\"$s\": \"allow\"" "$opencode" || echo "opencode: skill $s is not allowed"
    for f in "$d"scripts/*.sh; do
      [ -e "$f" ] || continue
      f="$(basename "$f")"
      for rule in "Bash(skills/$s/scripts/$f *)" "Bash({{\$ARNESS_ROOT}}/skills/$s/scripts/$f *)"; do
        grep -qF "\"$rule\"" "$claude" || echo "claude: missing $rule"
      done
      md="$d/SKILL.md"
      if [ ! -f "$md" ]; then echo "skill $s: no SKILL.md"
      elif ! grep '^allowed-tools:' "$md" | grep -qF "Bash(skills/$s/scripts/$f *)"; then
        echo "skill $s: allowed-tools lacks $f"
      fi
    done
  done < <(shared_skill_dirs "$root")
  # stale rules: skills or scripts that no longer exist
  for name in $(grep -o '"Skill([^)]*)"' "$claude" | sed 's/^"Skill(//; s/)"$//'); do
    [ -d "$root/skills/$name" ] || echo "claude: stale Skill($name)"
  done
  for f in $(grep -o 'skills/[^/ ]*/scripts/[^ )]*\.sh' "$claude" | sort -u); do
    [ -f "$root/$f" ] || echo "claude: stale Bash($f *)"
  done
  for name in $(sed -n '/"skill": {/,/}/p' "$opencode" | grep -o '"[^"]*": "allow"' | sed 's/": "allow"$//; s/^"//'); do
    [ -d "$root/skills/$name" ] || echo "opencode: stale skill $name"
  done
  for rule in 'skills/*/scripts/*.sh' 'skills/*/scripts/*.sh *'; do
    grep -qF "\"$rule\": \"allow\"" "$opencode" || echo "opencode: bash rule '$rule' is not allow"
  done
}

@test "every skill and script has its permission entries (claude, opencode, allowed-tools)" {
  run permission_problems "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output" >&2; false; }
}

@test "the permission check catches a skill without entries" {
  fake="$(mktemp -d)"
  cp -R "$REPO_ROOT/providers" "$REPO_ROOT/skills" "$fake/"
  mkdir -p "$fake/skills/zz-new/scripts"
  touch "$fake/skills/zz-new/scripts/zz.sh"
  printf -- '---\nname: zz-new\n---\n' > "$fake/skills/zz-new/SKILL.md"
  run permission_problems "$fake"
  rm -rf "$fake"
  [[ "$output" == *"claude: missing Skill(zz-new)"* ]]
  [[ "$output" == *"claude: missing Bash(skills/zz-new/scripts/zz.sh *)"* ]]
  [[ "$output" == *"claude: missing Bash({{\$ARNESS_ROOT}}/skills/zz-new/scripts/zz.sh *)"* ]]
  [[ "$output" == *"opencode: skill zz-new is not allowed"* ]]
  [[ "$output" == *"skill zz-new: allowed-tools lacks zz.sh"* ]]
}

@test "the permission check catches stale entries" {
  fake="$(mktemp -d)"
  cp -R "$REPO_ROOT/providers" "$REPO_ROOT/skills" "$fake/"
  rm -rf "$fake/skills/worktree-clean"
  run permission_problems "$fake"
  rm -rf "$fake"
  [[ "$output" == *"claude: stale Skill(worktree-clean)"* ]]
  [[ "$output" == *"claude: stale Bash(skills/worktree-clean/scripts/worktree-clean.sh *)"* ]]
  [[ "$output" == *"opencode: stale skill worktree-clean"* ]]
}

@test "json_looks_valid accepts well-formed JSON and rejects broken structure" {
  d="$(mktemp -d)"
  printf '{\n  "a": [1, 2],\n  "b": {"c": "x"}\n}\n' > "$d/ok.json"
  printf '{ "a": [1, 2 }\n' > "$d/brackets.json"
  printf '{ "a": 1\n' > "$d/open.json"
  printf '"a": 1\n' > "$d/noobject.json"
  json_looks_valid "$d/ok.json"
  ! json_looks_valid "$d/brackets.json"
  ! json_looks_valid "$d/open.json"
  ! json_looks_valid "$d/noobject.json"
  rm -rf "$d"
}

# --- local skills (skills/local-*) -----------------------------------------------

@test "shared_skill_dirs leaves out local-* skills" {
  d="$(mktemp -d)"
  mkdir -p "$d/skills/a" "$d/skills/local-b" "$d/skills/c-local"
  run shared_skill_dirs "$d"
  rm -rf "$d"
  [[ "$output" == *"/skills/a/"* ]]
  [[ "$output" == *"/skills/c-local/"* ]]
  [[ "$output" != *"local-b"* ]]
}

@test "the permission check ignores local skills" {
  fake="$(mktemp -d)"
  cp -R "$REPO_ROOT/providers" "$REPO_ROOT/skills" "$fake/"
  mkdir -p "$fake/skills/local-mine/scripts"
  touch "$fake/skills/local-mine/scripts/mine.sh"
  printf -- '---\nname: something-else\n---\n' > "$fake/skills/local-mine/SKILL.md"
  run permission_problems "$fake"
  rm -rf "$fake"
  [ -z "$output" ]
}

@test "skills/local-* is git-ignored and none is tracked" {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  git -C "$REPO_ROOT" check-ignore -q skills/local-demo/SKILL.md
  git -C "$REPO_ROOT" check-ignore -q skills/local-demo/scripts/x.sh
  [ -z "$(git -C "$REPO_ROOT" ls-files 'skills/local-*')" ]
}
