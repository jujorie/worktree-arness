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

# Bats files of the repo and of the shared skills (local skills are not checked).
shared_bats_files() {
  local d
  ls "$REPO_ROOT"/tests/*.bats
  while IFS= read -r d; do ls "$d"tests/*.bats 2>/dev/null || true; done < <(shared_skill_dirs "$REPO_ROOT")
}

# Prints file:line of each assertion that cannot fail the test. One rule: a line that
# starts with `[`, `[[`, `((` or `!` is an assertion and must end with `|| false` (or
# a `|| { ...; false; }` block, `return N`/`exit N` with N > 0 also count, on one line
# or several), with only checks joined by `||` before it (`|| echo` in between makes
# it never run); control flow is written as `if`. A `;` outside quotes, `[[ ]]`, `(( ))`,
# `$( )` and that block always flags the line. The only exception is a lone `[ ... ]`
# with no `&&` or `;`, a plain command that fails the test in every bash, alone or
# with each `||` followed by `[ ... ]`, `skip`, `return`, `continue` or `exit`.
# if/elif/while/until conditions do not start with those tokens, so they are never
# matched, and neither is a list that starts with another command
# (`grep -q a f && grep -q b f`), by design. The rule looks at the logical line: lines
# ending in `\`, `&&`, `||` or `|` joined with the next, quoted strings and the
# trailing comment removed line by line, a `|| {` block joined up to its `}`, the
# inside of `${ }`, `[[ ]]`, `(( ))` and `$( )` emptied, heredoc bodies skipped (a
# heredoc or a `|| {` block still open at the end of a file is reported).
# Known limits: an odd number of `"` inside '...' can confuse the quote stripping; a
# `]]`, `))` or `)` nested inside a check (`[[:digit:]]` inside `[[ ]]`) closes it too
# early; and `( ... )` and `{ ... }` other than the final block are not emptied.
silent_assertions() {
  awk '
    # The line without quoted strings and trailing comment; a quoted heredoc
    # delimiter (<<"EOF", or in single quotes) is unquoted first so it survives.
    function clean(s,   w) {
      while (match(s, /<<-?[ \t]*["\047][A-Za-z_][A-Za-z0-9_]*["\047]/)) {
        w = substr(s, RSTART, RLENGTH); gsub(/["\047 \t-]/, "", w)
        s = substr(s, 1, RSTART - 1) w substr(s, RSTART + RLENGTH)
      }
      gsub(/"([^"\\]|\\.)*"/, "\"\"", s); gsub(/\047[^\047]*\047/, "\047\047", s)
      sub(/^#.*$/, "", s); sub(/[ \t]#.*$/, "", s)
      return s
    }
    # s with what is between each open and its close emptied, so a || or && inside
    # [[ ]], (( )) or $( ) is not taken for the list operator.
    function blank(s, op, ed,   i, j, out) {
      out = ""
      while ((i = index(s, op)) > 0) {
        j = index(substr(s, i + length(op)), ed)
        if (j == 0) break
        out = out substr(s, 1, i - 1) op " " ed
        s = substr(s, i + length(op) + j - 1 + length(ed))
      }
      return out s
    }
    # A part of a || list after a lone [ ] that still fails the test: [ ] or a jump.
    function failing_tail(p) {
      return p ~ /^[ \t]*\[[ \t]/ || p ~ /^[ \t]*(skip|return|continue|exit)([ \t]|$)/
    }
    function silent(s,   n, i, p) {
      if (s !~ /^[ \t]*(\[|\(\(|![ \t])/) return 0
      s = blank(blank(blank(blank(s, "${", "}"), "$(", ")"), "[[", "]]"), "((", "))")
      gsub(/\$\{ \}/, "$v", s)
      # A final block counts as || false only when it ends in a command that fails.
      sub(/\|\|[ \t]*\{([^{}]*;)?[ \t]*(false|return[ \t]+[1-9][0-9]*|exit[ \t]+[1-9][0-9]*)[ \t]*;?[ \t]*\}[ \t]*$/, "|| false", s)
      if (s ~ /;/) return 1
      # Before the final || false, every || part must be a check: `|| echo` in between
      # always succeeds, so the || false after it never runs.
      if (s ~ /\|\|[ \t]*false[ \t]*$/) {
        n = split(s, p, /\|\|/)
        for (i = 2; i < n; i++) if (p[i] !~ /^[ \t]*(\[|\(\(|![ \t])/) return 1
        return 0
      }
      if (s !~ /^[ \t]*\[[ \t]/ || s ~ /&&/) return 1
      # A lone [ ], alone or with each || followed by another [ ] or skip/return/continue/exit.
      n = split(s, p, /\|\|/)
      for (i = 2; i <= n; i++) if (!failing_tail(p[i])) return 1
      return 0
    }
    function unterminated() {
      if (tag != "") print file ": unterminated heredoc " tag
      if (block) print file ": unterminated || { block"
    }
    FNR == 1 { unterminated(); tag = ""; line = ""; cl = ""; block = 0; file = FILENAME }
    tag != "" { if ($0 ~ "^[ \t]*" tag "[ \t]*$") tag = ""; next }
    # line is the raw logical line, for the report; cl the same line cleaned line by
    # line, so a comment on one line does not hide the lines joined after it.
    {
      c = clean($0)
      if (c ~ /<<-?[ \t]*[A-Za-z_]/ && c !~ /<<</) {
        tag = c; sub(/.*<<-?[ \t]*/, "", tag); sub(/[^A-Za-z0-9_].*$/, "", tag)
      }
      line = line $0; cl = cl c
    }
    c ~ /\\$/ { sub(/\\$/, "", line); sub(/\\$/, "", cl); next }
    cl ~ /(&&|\|)[ \t]*$/ { next }
    # A `|| {` block written over several lines is joined, with `;`, up to its `}`.
    {
      c = cl
      if ((block || c ~ /\|\|[ \t]*\{/) && gsub(/\{/, "{", c) > gsub(/\}/, "}", c)) {
        block = 1; line = line ";"; cl = cl ";"; next
      }
      block = 0
    }
    {
      if (silent(cl)) print FILENAME ":" FNR ": " line
      line = ""; cl = ""
    }
    END { unterminated() }
  ' "$@"
}

@test "every script has a bash shebang and LF endings" {
  # entry points only: scripts/lib.sh is sourced, not executed
  for f in "$REPO_ROOT"/setup.sh "$REPO_ROOT"/providers/*/setup.sh $(skill_scripts); do
    [ "$(head -1 "$f")" = "#!/usr/bin/env bash" ]
    ! grep -q $'\r' "$f" || false
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
  ! grep -E '/(Users|home)/' "$REPO_ROOT/providers/claude/settings.json" || false
}

@test "no GNU-only flags in scripts" {
  ! grep -nE 'readlink -f|sed -i|date -d|grep -P|mapfile|readarray' \
      $(all_scripts) || false
}

@test "no bats assertion is silent in bash 3.2" {
  run silent_assertions $(shared_bats_files)
  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "make each file:line assertion a list of checks ([, [[, ((, !) ending in || false, with no other command between them and no ; outside quotes and checks (write control flow and messages as if), and close each unterminated heredoc or || { block:"
    echo "$output"; false
  }
}

@test "the silent assertion check flags lines starting with [, [[, (( or ! that do not end in || false, and nothing else" {
  d="$(mktemp -d)"
  cat > "$d/x.bats" <<'EOF'
  [[ "$output" == *a* ]]
  ! grep -q a f
  ! grep -q a \
      f
  [ "$status" -eq 0 ] && [[ "$output" == *a* && "$output" == *b* ]]
  [[ "$output" == *a* ]] && [ "$status" -eq 0 ]
  [ -f x ] && [ -d y ]
  [ -f x ] && rm x
  [ -f x ] && [ -d y ] && rm x
  [[ "$output" == *a* ]]  # c
  (( x > 1 ))
  [ -n "$x" ] && (( x > 1 ))
  [[ "$output" == "a # b" ]]
  [ "$x" = 'a ] && [ b' ] && echo "] && ["
  [ "$status" -eq 0 ]
  [ "$x" = "a && b" ]
  [ "$x" = "a # b" ]  # c
  [[ "$output" == *a* ]] || false
  ! grep -q a f || false
  ! grep -q a f || { echo no; false; }
  ! grep -q a f || false  # c
  (( x > 1 )) || false
  ! grep -q a \
      f || false
  if [[ "$output" == *a* ]]; then :; fi
  if [ -f x ] && [ -d y ]; then :
  elif [ -f y ]; then :; fi
  while [[ -n "$x" ]]; do :; done
  until [ -f x ]; do :; done
  [ "$status" -eq 0 ] && [ -z "$output" ] || false
  [ "$status" -eq 4 ] && [[ "$output" == *a* ]] || { echo no; false; }
  [[ "$output" == *a* && "$output" == *b* ]] || false
  grep -q a f && grep -q b f
  [[ "$output" == a || "$output" == b ]]
  (( x > 1 || y > 1 ))
  ! [[ -n "$a" || -n "$b" ]]
  [ -n "$a" ] && [[ -n "$b" || -n "$c" ]]
  [ -n "$a" ] &&
    [ -n "$b" ]
  [[ "$output" == a || "$output" == b ]] || false
  [ -n "$a" ] &&
    [ -n "$b" ] || false
  if [[ -n "$a" ]] &&
     [[ -n "$b" ]]; then :; fi
  [[ "$output" == a ]] || [[ "$output" == b ]]
  ! grep -q a f || ! grep -q b f
  [[ -n "$a" ]] || false && [[ -n "$b" ]]
  [ "$status" -eq 0 ]; [[ "$output" == *a* ]]
  [ -n "$a" ] || [ -n "$b" ]
  [[ -n "$a" ]] || { echo no; false; }
  [ -n "$a" ] || [[ -n "$b" ]]
  [ -n "$a" ] || ! grep -q b f
  [ "$status" -eq 0 ] || echo "$output"
  [[ -n "$a" ]] || { echo no; }
  [[ -n "$a" ]] || { echo; }; [[ -n "$b" ]] || { echo no; false; }
  [[ -z "$output" ]] || {
    echo "$output"
  }
  [ -x /bin/bash ] || skip "no bash"
  [[ -n "$a" ]] || { echo no; return 1; }
  [[ -z "$output" ]] || {
    echo "$output"; false
  }
  [ -n "$a" ] || echo no || [ -n "$b" ]
  [[ -n "$a" ]] || { false; }
  ! grep -q a f || { exit 1; }
  [[ -n "$a" ]] || { echo ${#lines[@]}; false; }
  [[ -z "$output" ]] || {  # c
    echo "$output"; false  # d
  }
  [[ "$output" == *z* ]]
  [[ -n "$a" ]] || { echo no; return 0; }
  ! grep -q a f || { exit 0; }
  [ -f x ] || return
  [ -f x ] || continue
  [ -f x ] || exit 1
  [ "$status" -eq 0 ] || echo "$output" || false
  [[ -n "$a" ]] || echo no || { echo; false; }
  [[ -n "$a" ]] || [[ -n "$b" ]] || false
  run cmd  # x \
  [[ "$output" == *a* ]]
  cat > f <<'IN'
  [[ heredoc text, not an assertion ]]
  ! neither is this
IN
EOF
  run silent_assertions "$d/x.bats"
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | cut -d: -f2 | tr '\n' ' ')" = "1 2 4 5 6 7 8 9 10 11 12 13 14 34 35 36 37 39 45 46 47 48 51 52 53 54 55 58 64 71 72 73 77 78 81 " ]
  [ "${lines[2]}" = "$d/x.bats:4:   ! grep -q a       f" ]
  [ "${lines[8]}" = "$d/x.bats:10:   [[ \"\$output\" == *a* ]]  # c" ]
}

@test "the silent assertion check handles column-0 comments, closed quoted heredocs and continuations across files" {
  d="$(mktemp -d)"
  printf '# cat <<EOF\n  [[ a ]]\n' > "$d/a.bats"
  printf '  cat <<"EOF"\n  [[ in ]]\nEOF\n  cat <<-'\''X'\''\n\t[[ in ]]\n\tX\n  [[ b ]]\n' > "$d/b.bats"
  printf '  ! grep -q a \\\n' > "$d/c.bats"
  printf '  [[ d ]]\n' > "$d/d.bats"
  run silent_assertions "$d/a.bats" "$d/b.bats" "$d/c.bats" "$d/d.bats"
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "$d/a.bats:2:   [[ a ]]" ]
  [ "${lines[1]}" = "$d/b.bats:7:   [[ b ]]" ]
  [ "${lines[2]}" = "$d/d.bats:1:   [[ d ]]" ]
}

@test "the silent assertion check skips no file after a heredoc look-alike and fails on an unterminated one" {
  d="$(mktemp -d)"
  printf '  # cat <<EOF\n  [[ a ]]\n' > "$d/a.bats"
  printf '  [[ b ]]\n' > "$d/b.bats"
  printf '  echo "<<EOF"\n  [[ c ]]\n  cat <<EOF\n' > "$d/c.bats"
  printf '  [[ d ]]\n' > "$d/d.bats"
  run silent_assertions "$d/a.bats" "$d/b.bats" "$d/c.bats" "$d/d.bats"
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
  [ "${lines[0]}" = "$d/a.bats:2:   [[ a ]]" ]
  [ "${lines[1]}" = "$d/b.bats:1:   [[ b ]]" ]
  [ "${lines[2]}" = "$d/c.bats:2:   [[ c ]]" ]
  [ "${lines[3]}" = "$d/c.bats: unterminated heredoc EOF" ]
  [ "${lines[4]}" = "$d/d.bats:1:   [[ d ]]" ]
}

@test "the silent assertion check reports a || { block left open at the end of a file" {
  d="$(mktemp -d)"
  printf '  [[ a ]] || {\n    echo no; false\n' > "$d/a.bats"
  printf '  [[ b ]]\n' > "$d/b.bats"
  run silent_assertions "$d/a.bats" "$d/b.bats"
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$d/a.bats: unterminated || { block" ]
  [ "${lines[1]}" = "$d/b.bats:1:   [[ b ]]" ]
}

@test "the silent assertion check reports a heredoc left open at the end of the last file" {
  d="$(mktemp -d)"
  printf '  cat <<'\''EOF'\''\n  [[ a ]]\n' > "$d/a.bats"
  run silent_assertions "$d/a.bats"
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "$d/a.bats: unterminated heredoc EOF" ]
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
      # Either the whole script ("<script> *") or some of its subcommands ("<script> list"), so a
      # skill can keep a command that writes out of the allowlist and have the agent ask first.
      for rule in "Bash(skills/$s/scripts/$f *)" "Bash({{\$ARNESS_ROOT}}/skills/$s/scripts/$f *)"; do
        grep -qF "\"${rule% \*)} " "$claude" || echo "claude: missing $rule"
      done
      md="$d/SKILL.md"
      if [ ! -f "$md" ]; then echo "skill $s: no SKILL.md"
      elif ! grep '^allowed-tools:' "$md" | grep -qF "Bash(skills/$s/scripts/$f "; then
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
  [[ "$output" == *"claude: missing Skill(zz-new)"* ]] || false
  [[ "$output" == *"claude: missing Bash(skills/zz-new/scripts/zz.sh *)"* ]] || false
  [[ "$output" == *"claude: missing Bash({{\$ARNESS_ROOT}}/skills/zz-new/scripts/zz.sh *)"* ]] || false
  [[ "$output" == *"opencode: skill zz-new is not allowed"* ]] || false
  [[ "$output" == *"skill zz-new: allowed-tools lacks zz.sh"* ]] || false
}

@test "the permission check catches stale entries" {
  fake="$(mktemp -d)"
  cp -R "$REPO_ROOT/providers" "$REPO_ROOT/skills" "$fake/"
  rm -rf "$fake/skills/worktree-clean"
  run permission_problems "$fake"
  rm -rf "$fake"
  [[ "$output" == *"claude: stale Skill(worktree-clean)"* ]] || false
  [[ "$output" == *"claude: stale Bash(skills/worktree-clean/scripts/worktree-clean.sh *)"* ]] || false
  [[ "$output" == *"opencode: stale skill worktree-clean"* ]] || false
}

@test "json_looks_valid accepts well-formed JSON and rejects broken structure" {
  d="$(mktemp -d)"
  printf '{\n  "a": [1, 2],\n  "b": {"c": "x"}\n}\n' > "$d/ok.json"
  printf '{ "a": [1, 2 }\n' > "$d/brackets.json"
  printf '{ "a": 1\n' > "$d/open.json"
  printf '"a": 1\n' > "$d/noobject.json"
  json_looks_valid "$d/ok.json"
  ! json_looks_valid "$d/brackets.json" || false
  ! json_looks_valid "$d/open.json" || false
  ! json_looks_valid "$d/noobject.json" || false
  rm -rf "$d"
}

# --- local skills (any skills/<name>/ not listed in the skills/.gitignore allowlist) ----------

# mk_git_root <dir>: a throwaway git checkout with the repo's providers and skills/.gitignore.
mk_git_root() {
  cp -R "$REPO_ROOT/providers" "$1/"
  mkdir -p "$1/skills"
  cp "$REPO_ROOT/skills/.gitignore" "$1/skills/"
  git -C "$1" init -q
}

@test "shared_skill_dirs: in a git checkout only allowlisted skills count" {
  d="$(mktemp -d)"
  mk_git_root "$d"
  mkdir -p "$d/skills/repo-clone" "$d/skills/my-private" "$d/skills/pdf"
  touch "$d/skills/repo-clone/SKILL.md" "$d/skills/my-private/SKILL.md" "$d/skills/pdf/SKILL.md" "$d/skills/README.md"
  run shared_skill_dirs "$d"
  rm -rf "$d"
  [[ "$output" == *"/skills/repo-clone/" ]] || false
  [[ "$output" != *"my-private"* ]] || false
  [[ "$output" != *"pdf"* ]] || false
  [[ "$output" != *"README"* ]] || false
}

@test "shared_skill_dirs: outside git every folder counts" {
  d="$(mktemp -d)"
  mkdir -p "$d/skills/a" "$d/skills/b"
  run shared_skill_dirs "$d"
  rm -rf "$d"
  [[ "$output" == *"/skills/a/"* ]] || false
  [[ "$output" == *"/skills/b/"* ]] || false
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
  sed -i.bak '/worktree-clean/d' "$fake/skills/.gitignore"
  run permission_problems "$fake"
  rm -rf "$fake"
  [[ "$output" == *"claude: stale Skill(worktree-clean)"* ]] || false
}

@test "unlisted skills are git-ignored and every tracked skill is allowlisted" {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  git -C "$REPO_ROOT" check-ignore -q skills/anything-else/SKILL.md
  git -C "$REPO_ROOT" check-ignore -q skills/anything-else/scripts/x.sh
  ! git -C "$REPO_ROOT" check-ignore -q skills/README.md || false
  while IFS= read -r name; do
    ! git -C "$REPO_ROOT" check-ignore -q "skills/$name/SKILL.md" || false
  done < <(git -C "$REPO_ROOT" ls-files skills | cut -d/ -f2 | sort -u | grep -v '^README.md$')
}

@test "unlisted agents are git-ignored and the agents README is not" {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  git -C "$REPO_ROOT" check-ignore -q agents/anything-else.md
  ! git -C "$REPO_ROOT" check-ignore -q agents/README.md || false
  ! git -C "$REPO_ROOT" check-ignore -q agents/.gitignore || false
}

@test "the plugin rules marker is the first entry of permissions.allow" {
  # Anywhere else the rendered rules would leave a trailing comma before the closing bracket.
  awk '/"allow": \[/ { getline; print; exit }' "$REPO_ROOT/providers/claude/settings.json" | grep -qF '{{$PLUGIN_ALLOW}}'
  [ "$(grep -cF '{{$PLUGIN_ALLOW}}' "$REPO_ROOT/providers/claude/settings.json")" -eq 1 ]
}

@test "plugin-manage apply is never pre-allowed" {
  ! grep -F 'plugin-manage.sh' "$REPO_ROOT/providers/claude/settings.json" | grep -qE 'plugin-manage\.sh (\*|apply)' || false
  ! grep '^allowed-tools:' "$REPO_ROOT/skills/plugin-manage/SKILL.md" | grep -qE 'plugin-manage\.sh (\*|apply)' || false
  grep -qF '"skills/plugin-manage/scripts/plugin-manage.sh apply *": "ask"' "$REPO_ROOT/providers/opencode/opencode.json"
}

@test "repo-create apply is never pre-allowed" {
  ! grep -F 'repo-create.sh' "$REPO_ROOT/providers/claude/settings.json" | grep -qE 'repo-create\.sh (\*|apply)' || false
  ! grep '^allowed-tools:' "$REPO_ROOT/skills/repo-create/SKILL.md" | grep -qE 'repo-create\.sh (\*|apply)' || false
  grep -qF '"skills/repo-create/scripts/repo-create.sh apply *": "ask"' "$REPO_ROOT/providers/opencode/opencode.json"
}
