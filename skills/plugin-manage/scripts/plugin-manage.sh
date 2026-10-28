#!/usr/bin/env bash
# Add, update, remove and list arness plugins: git repos with an arness-plugin.conf at their root, cloned
# into plugins/<name>, whose skills and agents are linked into skills/ and agents/ and whose Claude Code
# permission rules are rendered into .claude/settings.json. See plugins/README.md.
#
# Usage: plugin-manage.sh add [--ref REF] [--commit SHA] [--yes] <url>
#        plugin-manage.sh update [--ref REF] [--commit SHA] [--no-fetch] [--yes] <name>
#        plugin-manage.sh remove [--force] [--yes] <name>
#        plugin-manage.sh list
#        plugin-manage.sh check <dir>
#        plugin-manage.sh sync
#
# Without --yes, add, update and remove only print the plan and a CONFIRM_* line; nothing is written.
#
# Stdout (machine readable), first word is the status:
#   PLUGIN <name> <version> <commit>      plan header
#   SKILL <name> | AGENT <name>           what the plugin links
#   ALLOW <provider> <rule>               permission rule the plugin asks for (claude, opencode)
#   NEW_ALLOW <provider> <rule>           update: rule the installed version did not ask for
#   INSTALL <cmd> | UNINSTALL <cmd>       command run in the plugin folder once confirmed
#   CONFIRM_ADD <name> <commit>           rerun with --yes --commit <commit> (exit 20)
#   CONFIRM_UPDATE <name> <from> <to>     rerun with --yes --commit <to> (exit 20)
#   CONFIRM_REMOVE <name>                 rerun with --yes (exit 20)
#   ADDED <name> <path>                   cloned, linked, rules rendered, install run
#   UPDATED <name> <from> <to>            moved to <to>, links and rules refreshed, install run
#   UP_TO_DATE <name> <commit>            update: nothing new
#   REMOVED <name>                        uninstall run, links, clone and rules gone
#   MANUAL opencode <rule>                add it to opencode.json yourself: setup never edits that file
#   VALID <name> <version>                check passed
#   INSTALLED <name> <version> <commit> <state> <skills> <agents>
#                                         list line; state OK|BROKEN_LINK|DIRTY|INSTALL_FAILED,
#                                         skills and agents as linked/declared
#   NONE                                  list: no plugins
#   SYNCED <name>                         sync restored the plugin's links
#   BAD_MANIFEST <detail>                 manifest syntax or field error (exit 4)
#   INVALID <detail>                      a declared skill or agent is missing or misnamed (exit 4)
#   ARNESS_VERSION <value>                unsupported plugin contract (exit 4)
#   BROAD_PERMISSION <provider> <rule>    rule too broad to grant (exit 4)
#   MISSING_REQUIREMENT <command>         a required command is not installed (exit 5)
#   NAME_CONFLICT <path>                  a skill or agent of that name exists and is not this plugin's (exit 6)
#   ALREADY_INSTALLED <name>              use update (exit 10)
#   DIRTY <path> <why>                    uncommitted-changes, unpushed-commits or diverged (exit 11)
#   NOT_INSTALLED <name>                  (exit 12)
#   INSTALL_FAILED <name>                 install command failed; clone and links kept (exit 13)
#   MISMATCH <expected> <actual>          --commit is not what the ref points to now (exit 14)
# Exit codes: 0 ok, 2 invalid usage, 3 clone or fetch failed, 4 invalid plugin, 5 missing requirement,
#   6 name conflict, 10 already installed, 11 dirty, 12 not installed, 13 install failed, 14 mismatch,
#   20 confirmation needed.
set -euo pipefail

EXIT_USAGE=2 EXIT_GIT=3 EXIT_INVALID=4 EXIT_REQUIREMENT=5 EXIT_CONFLICT=6
EXIT_EXISTS=10 EXIT_DIRTY=11 EXIT_NOT_INSTALLED=12 EXIT_INSTALL=13 EXIT_MISMATCH=14 EXIT_CONFIRM=20

CONTRACT=1
MANIFEST=arness-plugin.conf
SLUG_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
CLAUDE_RULE_RE='^[A-Za-z]+\((.+)\)$'

ROOT="" PLUGINS=""
TMP_DIR=""   # global: the EXIT trap runs after main() returns
cleanup() { if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi; }

die()  { echo "error: $*" >&2; exit "$EXIT_USAGE"; }
fail() { local code="$1"; shift; echo "$*"; exit "$code"; }

resolve_root() {
  if [ -n "${ARNESS_ROOT:-}" ]; then
    printf '%s\n' "$ARNESS_ROOT"
  else
    # <root>/skills/plugin-manage/scripts -> <root>. -P follows symlinks (.claude/skills, .agents/skills).
    (cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
  fi
}

# --- input validation --------------------------------------------------------

validate_url() {
  local url="$1"
  [ -n "$url" ] || return 1
  case "$url" in
    -*|*[[:space:]]*|*[[:cntrl:]]*|*://-*|*@-*) return 1 ;;
    https://?*|http://?*|ssh://?*|file://?*|git@?*:?*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_ref() {
  case "$1" in
    ""|-*|*[[:space:]]*|*[[:cntrl:]]*|*..*) return 1 ;;
  esac
}

validate_commit() {
  case "$1" in
    ""|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -ge 7 ] && [ "${#1}" -le 40 ]
}

is_slug() { [[ $1 =~ $SLUG_RE ]]; }

# --- manifest ------------------------------------------------------------------

# parse_manifest <file>: fill the M_* globals, or print BAD_MANIFEST and exit.
parse_manifest() {
  local file="$1" line key value n=0 seen=" "
  M_NAME="" M_VERSION="" M_PREFIX="" M_ARNESS="" M_DESC="" M_SKILLS="" M_AGENTS="" M_REQUIRES=""
  M_INSTALL="" M_ALLOW_CLAUDE="" M_ALLOW_OPENCODE=""
  [ -f "$file" ] || fail "$EXIT_INVALID" "BAD_MANIFEST missing $MANIFEST"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      ""|"#"*) continue ;;
      *$'\r'*) fail "$EXIT_INVALID" "BAD_MANIFEST line $n: CRLF line ending" ;;
      *=*) ;;
      *) fail "$EXIT_INVALID" "BAD_MANIFEST line $n: not KEY=value" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      allow.claude)   M_ALLOW_CLAUDE="${M_ALLOW_CLAUDE}${value}"$'\n'; continue ;;
      allow.opencode) M_ALLOW_OPENCODE="${M_ALLOW_OPENCODE}${value}"$'\n'; continue ;;
      name|version|prefix|arness|description|skills|agents|requires|install|uninstall) ;;
      *) fail "$EXIT_INVALID" "BAD_MANIFEST line $n: unknown key $key" ;;
    esac
    case "$seen" in *" $key "*) fail "$EXIT_INVALID" "BAD_MANIFEST line $n: duplicate key $key" ;; esac
    seen="$seen$key "
    case "$key" in
      name)        M_NAME="$value" ;;
      version)     M_VERSION="$value" ;;
      prefix)      M_PREFIX="$value" ;;
      arness)      M_ARNESS="$value" ;;
      description) M_DESC="$value" ;;
      skills)      M_SKILLS="$value" ;;
      agents)      M_AGENTS="$value" ;;
      requires)    M_REQUIRES="$value" ;;
      install)     M_INSTALL="$value" ;;
      uninstall)   ;;   # remove reads it leniently, with conf_value
    esac
  done < "$file"
}

# check_rule <provider> <rule>: BAD_MANIFEST for a rule that would break the JSON, BROAD_PERMISSION for a
# wildcard that grants more than one command.
check_rule() {
  local provider="$1" rule="$2" inner
  case "$rule" in
    *'"'*|*\\*|*[[:cntrl:]]*) fail "$EXIT_INVALID" "BAD_MANIFEST allow.$provider: quote, backslash or control character in $rule" ;;
  esac
  if [ "$provider" = claude ]; then
    if [[ $rule =~ ^[A-Za-z]+$ ]]; then fail "$EXIT_INVALID" "BROAD_PERMISSION claude $rule"; fi
    [[ $rule =~ $CLAUDE_RULE_RE ]] || fail "$EXIT_INVALID" "BAD_MANIFEST allow.claude: not Tool(pattern): $rule"
    inner="${BASH_REMATCH[1]}"
  else
    inner="$rule"
  fi
  case "$inner" in
    ""|"*"*|" "*) fail "$EXIT_INVALID" "BROAD_PERMISSION $provider $rule" ;;
  esac
}

# check_names <kind> <list> <dir>: every name is a slug with the plugin prefix and exists in the plugin.
check_names() {
  local kind="$1" list="$2" dir="$3" n
  case "$list" in *[!a-z0-9\ -]*) fail "$EXIT_INVALID" "BAD_MANIFEST $kind: names must be lowercase slugs" ;; esac
  for n in $list; do
    is_slug "$n" || fail "$EXIT_INVALID" "BAD_MANIFEST $kind: invalid name $n"
    case "$n" in "$M_PREFIX"?*) ;; *) fail "$EXIT_INVALID" "BAD_MANIFEST $kind: $n lacks prefix $M_PREFIX" ;; esac
    if [ "$kind" = skills ]; then
      [ -f "$dir/skills/$n/SKILL.md" ] || fail "$EXIT_INVALID" "INVALID skills/$n/SKILL.md not found"
      grep -qx "name: $n" "$dir/skills/$n/SKILL.md" || fail "$EXIT_INVALID" "INVALID skills/$n/SKILL.md lacks 'name: $n'"
    else
      [ -f "$dir/agents/$n.md" ] || fail "$EXIT_INVALID" "INVALID agents/$n.md not found"
    fi
  done
}

# validate_plugin <dir>: parse and check the manifest and that what it declares exists.
validate_plugin() {
  local dir="$1" rule
  parse_manifest "$dir/$MANIFEST"
  [ -n "$M_NAME" ]    || fail "$EXIT_INVALID" "BAD_MANIFEST missing key name"
  [ -n "$M_VERSION" ] || fail "$EXIT_INVALID" "BAD_MANIFEST missing key version"
  [ -n "$M_PREFIX" ]  || fail "$EXIT_INVALID" "BAD_MANIFEST missing key prefix"
  [ -n "$M_ARNESS" ]  || fail "$EXIT_INVALID" "BAD_MANIFEST missing key arness"
  [ -n "$M_DESC" ]    || fail "$EXIT_INVALID" "BAD_MANIFEST missing key description"
  [ "$M_ARNESS" = "$CONTRACT" ] || fail "$EXIT_INVALID" "ARNESS_VERSION $M_ARNESS"
  is_slug "$M_NAME" || fail "$EXIT_INVALID" "BAD_MANIFEST name: not a lowercase slug: $M_NAME"
  [[ $M_VERSION =~ $SEMVER_RE ]] || fail "$EXIT_INVALID" "BAD_MANIFEST version: not MAJOR.MINOR.PATCH: $M_VERSION"
  case "$M_PREFIX" in *-) is_slug "${M_PREFIX%-}" ;; *) false ;; esac \
    || fail "$EXIT_INVALID" "BAD_MANIFEST prefix: not a slug ending in -: $M_PREFIX"
  [ "${#M_DESC}" -le 200 ] || fail "$EXIT_INVALID" "BAD_MANIFEST description: longer than 200 characters"
  case "$M_REQUIRES" in *[!A-Za-z0-9._\ -]*) fail "$EXIT_INVALID" "BAD_MANIFEST requires: invalid command name" ;; esac
  check_names skills "$M_SKILLS" "$dir"
  check_names agents "$M_AGENTS" "$dir"
  while IFS= read -r rule; do
    if [ -n "$rule" ]; then check_rule claude "$rule"; fi
  done <<< "$M_ALLOW_CLAUDE"
  while IFS= read -r rule; do
    if [ -n "$rule" ]; then check_rule opencode "$rule"; fi
  done <<< "$M_ALLOW_OPENCODE"
}

check_requirements() {
  local c
  for c in $M_REQUIRES; do
    command -v "$c" >/dev/null 2>&1 || fail "$EXIT_REQUIREMENT" "MISSING_REQUIREMENT $c"
  done
}

print_rules() {
  local status="$1" provider="$2" rules="$3" rule
  while IFS= read -r rule; do
    if [ -n "$rule" ]; then echo "$status $provider $rule"; fi
  done <<< "$rules"
}

print_plan() {
  local commit="$1" n
  echo "PLUGIN $M_NAME $M_VERSION $commit"
  for n in $M_SKILLS; do echo "SKILL $n"; done
  for n in $M_AGENTS; do echo "AGENT $n"; done
  print_rules ALLOW claude "$M_ALLOW_CLAUDE"
  print_rules ALLOW opencode "$M_ALLOW_OPENCODE"
  if [ -n "$M_INSTALL" ]; then echo "INSTALL $M_INSTALL"; fi
}

# --- links ---------------------------------------------------------------------

# belongs_to <path> <name>: path is a link into plugins/<name>/.
belongs_to() {
  [ -L "$1" ] || return 1
  case "$(readlink "$1")" in *"plugins/$2/"*) return 0 ;; esac
  return 1
}

check_conflicts() {
  local name="$1" n p
  for n in $M_SKILLS; do
    p="$ROOT/skills/$n"
    if [ -e "$p" ] || [ -L "$p" ]; then belongs_to "$p" "$name" || fail "$EXIT_CONFLICT" "NAME_CONFLICT skills/$n"; fi
  done
  for n in $M_AGENTS; do
    p="$ROOT/agents/$n.md"
    if [ -e "$p" ] || [ -L "$p" ]; then belongs_to "$p" "$name" || fail "$EXIT_CONFLICT" "NAME_CONFLICT agents/$n.md"; fi
  done
}

# relink <target> <path>: (re)create path as a link to target, relative to the path's directory.
relink() {
  if [ -L "$2" ]; then rm "$2"; fi
  make_link "$1" "$2"
}

# link_plugin <name> <skills> <agents>
link_plugin() {
  local name="$1" n
  mkdir -p "$ROOT/skills" "$ROOT/agents"
  for n in $2; do relink "../plugins/$name/skills/$n" "$ROOT/skills/$n"; done
  for n in $3; do relink "../plugins/$name/agents/$n.md" "$ROOT/agents/$n.md"; done
}

unlink_plugin() {
  local name="$1" p
  for p in "$ROOT"/skills/* "$ROOT"/agents/*; do
    if belongs_to "$p" "$name"; then rm "$p"; fi
  done
}

# Re-render the Claude Code settings when that provider is set up, so plugin rules follow the plugins.
# Codex has no permission file here, and opencode.json belongs to the user (MANUAL lines instead).
refresh_providers() {
  if [ -e "$ROOT/.claude/settings.json" ]; then
    ARNESS_ROOT="$ROOT" bash "$ROOT/providers/claude/setup.sh" >&2
  fi
}

run_install() {
  local name="$1" dir="$2" marker="$PLUGINS/.$1.install-failed"
  if [ -n "$M_INSTALL" ]; then
    if ! (cd "$dir" && bash -c "$M_INSTALL") >&2; then
      : > "$marker"
      fail "$EXIT_INSTALL" "INSTALL_FAILED $name"
    fi
  fi
  rm -f "$marker"
}

# --- git -----------------------------------------------------------------------

# Echo why the clone must not be touched; empty when clean. Untracked files do not count: they are
# usually what the plugin's install command built in its folder.
dirty_reason() {
  local dir="$1"
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "uncommitted-changes"; return
  fi
  if git -C "$dir" rev-parse --verify --quiet '@{u}' >/dev/null 2>&1 \
     && [ -n "$(git -C "$dir" log --oneline '@{u}..HEAD' 2>/dev/null)" ]; then
    echo "unpushed-commits"
  fi
}

check_commit() {
  local expect="$1" actual="$2"
  case "$actual" in "$expect"*) ;; *) fail "$EXIT_MISMATCH" "MISMATCH $expect $actual" ;; esac
}

new_tmp() {
  mkdir -p "$PLUGINS"
  TMP_DIR="$(mktemp -d "$PLUGINS/.plugin-manage.XXXXXX")"
  trap cleanup EXIT
}

# --- commands --------------------------------------------------------------------

cmd_add() {
  local url="" ref="" expect="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref)    [ $# -ge 2 ] || die "--ref needs a value"; ref="$2"; shift 2 ;;
      --commit) [ $# -ge 2 ] || die "--commit needs a value"; expect="$2"; shift 2 ;;
      --yes)    yes=1; shift ;;
      -*)       die "unknown option: $1" ;;
      *)        [ -z "$url" ] || die "only one URL allowed"; url="$1"; shift ;;
    esac
  done
  [ -n "$url" ] || die "missing plugin URL"
  validate_url "$url" || die "invalid URL (allowed: https://, http://, ssh://, git@host:path, file://): $url"
  if [ -n "$ref" ]; then validate_ref "$ref" || die "invalid --ref: $ref"; fi
  if [ -n "$expect" ]; then validate_commit "$expect" || die "invalid --commit: $expect"; fi

  new_tmp
  local dir="$TMP_DIR/repo" commit dest
  git clone --quiet -- "$url" "$dir" >&2 || { echo "error: git clone failed for $url" >&2; exit "$EXIT_GIT"; }
  if [ -n "$ref" ]; then
    git -C "$dir" checkout --quiet "$ref" >&2 || die "ref not found: $ref"
  fi
  commit="$(git -C "$dir" rev-parse HEAD)"
  if [ -n "$expect" ]; then check_commit "$expect" "$commit"; fi

  validate_plugin "$dir"
  check_requirements
  dest="$PLUGINS/$M_NAME"
  if [ -e "$dest" ] || [ -L "$dest" ]; then fail "$EXIT_EXISTS" "ALREADY_INSTALLED $M_NAME"; fi
  check_conflicts "$M_NAME"

  if [ "$yes" -eq 0 ]; then
    print_plan "$commit"
    fail "$EXIT_CONFIRM" "CONFIRM_ADD $M_NAME $commit"
  fi

  mv "$dir" "$dest"
  link_plugin "$M_NAME" "$M_SKILLS" "$M_AGENTS"
  refresh_providers
  run_install "$M_NAME" "$dest"
  print_rules MANUAL opencode "$M_ALLOW_OPENCODE"
  echo "ADDED $M_NAME $dest"
}

# resolve_target <dir> <ref>: the commit to update to: origin/<ref>, then <ref> (a tag), else the upstream.
resolve_target() {
  local dir="$1" ref="$2" c
  if [ -n "$ref" ]; then
    if c="$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}")"; then echo "$c"; return; fi
    if c="$(git -C "$dir" rev-parse --verify --quiet "$ref^{commit}")"; then echo "$c"; return; fi
    die "ref not found: $ref"
  fi
  c="$(git -C "$dir" rev-parse --verify --quiet '@{u}^{commit}')" || die "no upstream to update from (installed at a tag?); pass --ref"
  echo "$c"
}

cmd_update() {
  local name="" ref="" expect="" yes=0 fetch=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref)      [ $# -ge 2 ] || die "--ref needs a value"; ref="$2"; shift 2 ;;
      --commit)   [ $# -ge 2 ] || die "--commit needs a value"; expect="$2"; shift 2 ;;
      --no-fetch) fetch=0; shift ;;
      --yes)      yes=1; shift ;;
      -*)         die "unknown option: $1" ;;
      *)          [ -z "$name" ] || die "only one plugin name allowed"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "missing plugin name"
  is_slug "$name" || die "invalid plugin name: $name"
  if [ -n "$ref" ]; then validate_ref "$ref" || die "invalid --ref: $ref"; fi
  if [ -n "$expect" ]; then validate_commit "$expect" || die "invalid --commit: $expect"; fi

  local dest="$PLUGINS/$name" why old target old_claude old_opencode rule
  [ -d "$dest/.git" ] || fail "$EXIT_NOT_INSTALLED" "NOT_INSTALLED $name"
  why="$(dirty_reason "$dest")"
  if [ -n "$why" ]; then fail "$EXIT_DIRTY" "DIRTY $dest $why"; fi
  if [ "$fetch" -eq 1 ]; then
    git -C "$dest" fetch --quiet --tags origin >&2 || { echo "error: git fetch failed in $dest" >&2; exit "$EXIT_GIT"; }
  fi
  old="$(git -C "$dest" rev-parse HEAD)"
  target="$(resolve_target "$dest" "$ref")"
  if [ -n "$expect" ]; then check_commit "$expect" "$target"; fi
  if [ "$target" = "$old" ]; then echo "UP_TO_DATE $name $old"; return; fi

  parse_manifest "$dest/$MANIFEST"
  old_claude="$M_ALLOW_CLAUDE" old_opencode="$M_ALLOW_OPENCODE"
  # Validate the new version from its tree before touching the clone.
  new_tmp
  git -C "$dest" archive "$target" | tar -x -C "$TMP_DIR"
  validate_plugin "$TMP_DIR"
  [ "$M_NAME" = "$name" ] || fail "$EXIT_INVALID" "BAD_MANIFEST name changed from $name to $M_NAME"
  check_requirements
  check_conflicts "$name"

  if [ "$yes" -eq 0 ]; then
    print_plan "$target"
    while IFS= read -r rule; do
      if [ -n "$rule" ] && ! grep -qxF -- "$rule" <<< "$old_claude"; then echo "NEW_ALLOW claude $rule"; fi
    done <<< "$M_ALLOW_CLAUDE"
    while IFS= read -r rule; do
      if [ -n "$rule" ] && ! grep -qxF -- "$rule" <<< "$old_opencode"; then echo "NEW_ALLOW opencode $rule"; fi
    done <<< "$M_ALLOW_OPENCODE"
    fail "$EXIT_CONFIRM" "CONFIRM_UPDATE $name $old $target"
  fi

  if [ -n "$ref" ] && git -C "$dest" rev-parse --verify --quiet "refs/remotes/origin/$ref" >/dev/null; then
    git -C "$dest" checkout --quiet -B "$ref" "origin/$ref" >&2
  elif [ -n "$ref" ]; then
    git -C "$dest" checkout --quiet --detach "$target" >&2
  elif ! git -C "$dest" merge --quiet --ff-only '@{u}' >&2; then
    fail "$EXIT_DIRTY" "DIRTY $dest diverged"
  fi
  unlink_plugin "$name"
  link_plugin "$name" "$M_SKILLS" "$M_AGENTS"
  refresh_providers
  run_install "$name" "$dest"
  print_rules MANUAL opencode "$M_ALLOW_OPENCODE"
  echo "UPDATED $name $old $target"
}

cmd_remove() {
  local name="" yes=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes)   yes=1; shift ;;
      --force) force=1; shift ;;
      -*)      die "unknown option: $1" ;;
      *)       [ -z "$name" ] || die "only one plugin name allowed"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "missing plugin name"
  is_slug "$name" || die "invalid plugin name: $name"

  local dest="$PLUGINS/$name" conf why n uninstall
  [ -d "$dest" ] || fail "$EXIT_NOT_INSTALLED" "NOT_INSTALLED $name"
  why="$(dirty_reason "$dest")"
  if [ -n "$why" ] && [ "$force" -eq 0 ]; then fail "$EXIT_DIRTY" "DIRTY $dest $why"; fi
  # Read the manifest leniently: a broken one must not keep the plugin from being removed.
  conf="$dest/$MANIFEST"
  uninstall="$(conf_value "$conf" uninstall | awk 'NR == 1')"

  if [ "$yes" -eq 0 ]; then
    echo "PLUGIN $name $(conf_value "$conf" version | awk 'NR == 1') $(git -C "$dest" rev-parse HEAD 2>/dev/null || echo unknown)"
    for n in $(conf_value "$conf" skills); do echo "SKILL $n"; done
    for n in $(conf_value "$conf" agents); do echo "AGENT $n"; done
    if [ -n "$uninstall" ]; then echo "UNINSTALL $uninstall"; fi
    fail "$EXIT_CONFIRM" "CONFIRM_REMOVE $name"
  fi

  if [ -n "$uninstall" ]; then
    (cd "$dest" && bash -c "$uninstall") >&2 || echo "warning: uninstall failed, removing anyway: $uninstall" >&2
  fi
  unlink_plugin "$name"
  rm -rf "$dest"
  rm -f "$PLUGINS/.$name.install-failed"
  refresh_providers
  echo "REMOVED $name"
}

# count_linked <name> <kind> <list>: "<linked>/<declared>".
count_linked() {
  local name="$1" kind="$2" n linked=0 total=0 p
  for n in $3; do
    total=$((total + 1))
    if [ "$kind" = skills ]; then p="$ROOT/skills/$n"; else p="$ROOT/agents/$n.md"; fi
    if belongs_to "$p" "$name" && [ -e "$p" ]; then linked=$((linked + 1)); fi
  done
  echo "$linked/$total"
}

cmd_list() {
  [ $# -eq 0 ] || die "list takes no arguments"
  local dir name conf skills agents s a state commit any=0
  for dir in "$PLUGINS"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    conf="$dir$MANIFEST"
    any=1
    skills="$(conf_value "$conf" skills)"
    agents="$(conf_value "$conf" agents)"
    s="$(count_linked "$name" skills "$skills")"
    a="$(count_linked "$name" agents "$agents")"
    if [ -e "$PLUGINS/.$name.install-failed" ]; then state=INSTALL_FAILED
    elif [ -n "$(dirty_reason "$dir")" ]; then state=DIRTY
    elif [ "${s%/*}" != "${s#*/}" ] || [ "${a%/*}" != "${a#*/}" ]; then state=BROKEN_LINK
    else state=OK
    fi
    commit="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "INSTALLED $name $(conf_value "$conf" version) $commit $state $s $a"
  done
  if [ "$any" -eq 0 ]; then echo "NONE"; fi
}

cmd_check() {
  [ $# -eq 1 ] || die "check takes one plugin folder"
  [ -d "$1" ] || die "not a folder: $1"
  validate_plugin "$1"
  check_requirements
  echo "VALID $M_NAME $M_VERSION"
}

# Restore the links of every plugin in plugins/ (setup.sh runs it). A path taken by something else is
# reported and left alone.
cmd_sync() {
  [ $# -eq 0 ] || die "sync takes no arguments"
  local dir name conf n p
  for dir in "$PLUGINS"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    conf="$dir$MANIFEST"
    [ -f "$conf" ] || { echo "warning: $name has no $MANIFEST, skipped" >&2; continue; }
    mkdir -p "$ROOT/skills" "$ROOT/agents"
    for n in $(conf_value "$conf" skills); do
      p="$ROOT/skills/$n"
      if [ -e "$p" ] && ! belongs_to "$p" "$name"; then echo "warning: skills/$n exists, not linked" >&2; continue; fi
      relink "../plugins/$name/skills/$n" "$p"
    done
    for n in $(conf_value "$conf" agents); do
      p="$ROOT/agents/$n.md"
      if [ -e "$p" ] && ! belongs_to "$p" "$name"; then echo "warning: agents/$n.md exists, not linked" >&2; continue; fi
      relink "../plugins/$name/agents/$n.md" "$p"
    done
    echo "SYNCED $name"
  done
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

main() {
  local cmd="${1:-}"
  case "$cmd" in
    -h|--help) usage; exit 0 ;;
    "") usage >&2; exit "$EXIT_USAGE" ;;
  esac
  shift
  command -v git >/dev/null 2>&1 || die "git not found"
  ROOT="$(resolve_root)"
  PLUGINS="$ROOT/plugins"
  export ARNESS_ROOT="$ROOT" GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL="https:http:ssh:file"
  # shellcheck source=SCRIPTDIR/../../../scripts/lib.sh
  . "$ROOT/scripts/lib.sh"
  case "$cmd" in
    add)    cmd_add "$@" ;;
    update) cmd_update "$@" ;;
    remove) cmd_remove "$@" ;;
    list)   cmd_list "$@" ;;
    check)  cmd_check "$@" ;;
    sync)   cmd_sync "$@" ;;
    *)      die "unknown command: $cmd (add, update, remove, list, check, sync)" ;;
  esac
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
