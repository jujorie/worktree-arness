#!/usr/bin/env bats
load helpers

# All shell scripts shipped by the repo, including skill scripts.
all_scripts() {
  ls "$REPO_ROOT"/setup.sh "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/providers/*/setup.sh
  skill_scripts
}

# Scripts of the shared skills (local skills are not checked).
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
  while IFS= read -r d; do
    [ -z "$(find "$d" -name '*.sh' -not -path '*/scripts/*')" ]
  done < <(shared_skill_dirs "$REPO_ROOT")
}

# --- permissions stay in sync with the skills --------------------------------
# A new skill (or script) without its permission entries would make agents ask for confirmation again.

# Print one problem per line for the repo at $1; no output means everything is in sync.
# Plain grep on the JSON files: they are small and kept one rule per line.
permission_problems() {
  local root="$1" claude="$1/providers/claude/settings.json" opencode="$1/providers/opencode/opencode.json"
  local d s f rule name md shared=" "
  while IFS= read -r d; do shared="$shared$(basename "$d") "; done < <(shared_skill_dirs "$root")
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
    case "$shared" in *" $name "*) ;; *) echo "claude: stale Skill($name)" ;; esac
  done
  for f in $(grep -o 'skills/[^/ ]*/scripts/[^ )]*\.sh' "$claude" | sort -u); do
    name="$(printf '%s' "$f" | cut -d/ -f2)"
    case "$shared" in *" $name "*) [ -f "$root/$f" ] || echo "claude: stale Bash($f *)" ;; *) echo "claude: stale Bash($f *)" ;; esac
  done
  for name in $(sed -n '/"skill": {/,/}/p' "$opencode" | grep -o '"[^"]*": "allow"' | sed 's/": "allow"$//; s/^"//'); do
    case "$shared" in *" $name "*) ;; *) echo "opencode: stale skill $name" ;; esac
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

# --- local skills (any skills/<name>/ not listed in the .gitignore allowlist) ----------

# mk_git_root <dir>: a throwaway git checkout with the repo's .gitignore and providers.
mk_git_root() {
  cp "$REPO_ROOT/.gitignore" "$1/"
  cp -R "$REPO_ROOT/providers" "$1/"
  git -C "$1" init -q
}

@test "shared_skill_dirs: in a git checkout only allowlisted skills count" {
  d="$(mktemp -d)"
  mk_git_root "$d"
  mkdir -p "$d/skills/repo-clone" "$d/skills/my-private" "$d/skills/pdf"
  touch "$d/skills/repo-clone/SKILL.md" "$d/skills/my-private/SKILL.md" "$d/skills/pdf/SKILL.md" "$d/skills/README.md"
  run shared_skill_dirs "$d"
  rm -rf "$d"
  [[ "$output" == *"/skills/repo-clone/" ]]
  [[ "$output" != *"my-private"* ]]
  [[ "$output" != *"pdf"* ]]
  [[ "$output" != *"README"* ]]
}

@test "shared_skill_dirs: outside git every folder counts" {
  d="$(mktemp -d)"
  mkdir -p "$d/skills/a" "$d/skills/b"
  run shared_skill_dirs "$d"
  rm -rf "$d"
  [[ "$output" == *"/skills/a/"* ]]
  [[ "$output" == *"/skills/b/"* ]]
}

@test "the permission check ignores local skills (any name, name may differ from the folder)" {
  command -v git >/dev/null || skip "git not installed"
  fake="$(mktemp -d)"
  mk_git_root "$fake"
  cp -R "$REPO_ROOT/skills" "$fake/"
  mkdir -p "$fake/skills/my-private/scripts"
  touch "$fake/skills/my-private/scripts/mine.sh"
  printf -- '---\nname: something-else\n---\n' > "$fake/skills/my-private/SKILL.md"
  run permission_problems "$fake"
  rm -rf "$fake"
  [ -z "$output" ]
}

@test "a skill missing from the allowlist is invisible to the checks, so its permission rules turn stale" {
  command -v git >/dev/null || skip "git not installed"
  fake="$(mktemp -d)"
  mk_git_root "$fake"
  cp -R "$REPO_ROOT/skills" "$fake/"
  rm -rf "$fake/skills/worktree-clean"
  mkdir -p "$fake/skills/worktree-clean"      # present but not what git would commit once unlisted
  sed -i.bak '/worktree-clean/d' "$fake/.gitignore"
  run permission_problems "$fake"
  rm -rf "$fake"
  [[ "$output" == *"claude: stale Skill(worktree-clean)"* ]]
}

@test "unlisted skills are git-ignored and every tracked skill is allowlisted" {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  git -C "$REPO_ROOT" check-ignore -q skills/anything-else/SKILL.md
  git -C "$REPO_ROOT" check-ignore -q skills/anything-else/scripts/x.sh
  ! git -C "$REPO_ROOT" check-ignore -q skills/README.md
  while IFS= read -r name; do
    ! git -C "$REPO_ROOT" check-ignore -q "skills/$name/SKILL.md"
  done < <(git -C "$REPO_ROOT" ls-files skills | cut -d/ -f2 | sort -u | grep -v '^README.md$')
}
