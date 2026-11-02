#!/usr/bin/env bash
# Add, update, remove and list arness plugins: git repos with an arness-plugin.conf at their root, cloned
# into plugins/<name>, whose skills and agents are linked into skills/ and agents/ and whose Claude Code
# permission rules are rendered into .claude/settings.json. See plugins/README.md.
#
# Usage: plugin-manage.sh add [--ref REF] <url>                       plan only, writes nothing
#        plugin-manage.sh update [--ref REF] [--no-fetch] <name>      plan only (fetches)
#        plugin-manage.sh remove <name>                               plan only
#        plugin-manage.sh apply add --commit SHA [--ref REF] <url>
#        plugin-manage.sh apply update --commit SHA [--ref REF] <name>
#        plugin-manage.sh apply remove [--force] <name>
#        plugin-manage.sh list
#        plugin-manage.sh check <dir>
#        plugin-manage.sh sync
#
# add, update and remove only print the plan. Only `apply` changes anything; it is kept out of the
# permission allowlists on purpose, so the agent's own tool prompt asks the user before it runs.
# What arness uses of an installed plugin (rules, links, uninstall) comes from plugins/.<name>.state,
# written by apply from the validated manifest, never from the clone's files as they are now.
#
# Stdout (machine readable), first word is the status:
#   PLUGIN <name> <version> <commit>      plan header
#   SOURCE <url|-> <ref> <branch|tag|commit>
#   DESCRIPTION <text> | REQUIRES <commands> | PROVIDES <commands>
#   SKILL <name> | AGENT <name>           what the plugin links
#   ALLOW <provider> <rule>               rule rendered (claude) or to add by hand (opencode)
#   NEW_ALLOW <provider> <rule>           update: rule the installed version did not have
#   OPENCODE_AUTO_ALLOW <path>            a plugin skill script OpenCode runs without asking
#                                         (its skills/*/scripts/*.sh rule)
#   OPENCODE_UNGATED <file>               that opencode.json lets OpenCode run `apply` without asking:
#                                         it lacks the "ask" rule of providers/opencode/opencode.json
#   INSTALL <cmd> | UNINSTALL <cmd>       command run in the plugin folder by apply
#   CONFIRM_ADD <name> <commit>           plan printed; nothing written (exit 20)
#   CONFIRM_UPDATE <name> <from> <to> <ref>   plan printed; nothing written (exit 20)
#   CONFIRM_REMOVE <name>                 plan printed; nothing written (exit 20)
#   ADDED <name> <path>                   cloned, linked, rules rendered, install run
#   UPDATED <name> <from> <to>            moved to <to>, links and rules refreshed, install run
#   UP_TO_DATE <name> <commit> <ref>      update: nothing new
#   REMOVED <name>                        uninstall run, links, clone, state and rules gone
#   MANUAL opencode <bash|skill> <entry>  add it to opencode.json yourself: setup never edits that file
#   VALID <name> <version>                check passed
#   INSTALLED <name> <version> <commit> <ref> <state> <skills> <agents>
#                                         list line; state OK|BROKEN_LINK|MODIFIED|INSTALL_FAILED|UNMANAGED,
#                                         skills and agents as linked/declared; "-" for an unknown value
#   NONE                                  list: no plugins
#   SYNCED <name>                         sync restored the plugin's links
#   BAD_MANIFEST <detail>                 manifest syntax or field error (exit 4)
#   INVALID <detail>                      a declared skill or agent is missing or misnamed (exit 4)
#   ARNESS_VERSION <value>                unsupported plugin contract (exit 4)
#   BAD_RULE <provider> <rule>: <why>     rule outside the allowed shapes (exit 4)
#   MISSING_REQUIREMENT <command>         a required command is not installed (exit 5)
#   NAME_CONFLICT <path>                  a skill or agent of that name exists and is not this plugin's (exit 6)
#   ALREADY_INSTALLED <name>              use update (exit 10)
#   DIRTY <path> <why>                    uncommitted-changes or moved (HEAD is not the applied commit) (exit 11)
#   NOT_INSTALLED <name>                  (exit 12)
#   INSTALL_FAILED <name>                 install command failed; clone and links kept (exit 13)
#   MISMATCH <expected> <actual>          --commit is not what the plan resolved to (exit 14)
# Exit codes: 0 ok, 2 invalid usage, 3 clone or fetch failed, 4 invalid plugin, 5 missing requirement,
#   6 name conflict, 10 already installed, 11 dirty, 12 not installed, 13 install failed, 14 mismatch,
#   20 plan printed, confirmation needed.
set -euo pipefail

EXIT_USAGE=2 EXIT_GIT=3 EXIT_INVALID=4 EXIT_REQUIREMENT=5 EXIT_CONFLICT=6
EXIT_EXISTS=10 EXIT_DIRTY=11 EXIT_NOT_INSTALLED=12 EXIT_INSTALL=13 EXIT_MISMATCH=14 EXIT_CONFIRM=20

CONTRACT=1
MANIFEST=arness-plugin.conf
SLUG_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
# Allowed rule shapes: one command (one the plugin provides), optional literal arguments, optional
# trailing " *".
CLAUDE_RULE_RE='^Bash\(([A-Za-z0-9._+-]+)(( [A-Za-z0-9._/=:@+,-]+)*)( \*)?\)$'
OPENCODE_RULE_RE='^([A-Za-z0-9._+-]+)(( [A-Za-z0-9._/=:@+,-]+)*)( \*)?$'
# Commands that run arbitrary code from their arguments: no rule may name them, even with literal
# arguments. Versioned names (python3.12, node20, gawk) are caught by RUNNER_RE.
RUNNERS=" bash sh zsh dash ksh fish csh tcsh pwsh powershell env sudo su doas xargs eval exec command nohup"
RUNNERS="$RUNNERS time timeout watch nice osascript open find awk sed git make cmake ssh scp rsync tar curl"
RUNNERS="$RUNNERS wget docker podman kubectl gh npx pnpx uvx pipx uv npm pnpm yarn pip cargo go bun deno "
RUNNER_RE='^(python|pypy|node|nodejs|ruby|perl|php|lua|luajit|g?awk|mawk|nawk|gsed|pip)[0-9.]*$'
# The rule OpenCode needs so that its skills/*/scripts/*.sh allow does not cover apply.
OPENCODE_APPLY_RULE='"skills/plugin-manage/scripts/plugin-manage.sh apply *": "ask"'

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

# No plain http: the plugin's code runs on this machine, and --commit cannot detect a tampered clone.
validate_url() {
  local url="$1"
  [ -n "$url" ] || return 1
  case "$url" in
    -*|*[[:space:]]*|*[[:cntrl:]]*|*://-*|*@-*) return 1 ;;
    https://?*|ssh://?*|file://?*|git@?*:?*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_ref() {
  case "$1" in
    ""|-*|*[[:space:]]*|*[[:cntrl:]]*|*..*) return 1 ;;
  esac
}

# apply takes only the full sha the plan printed: a short prefix could be matched by another commit
# the plugin's author crafts after the confirmation.
validate_full_commit() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
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
  M_NAME="" M_VERSION="" M_PREFIX="" M_ARNESS="" M_DESC="" M_SKILLS="" M_AGENTS="" M_REQUIRES="" M_PROVIDES=""
  M_INSTALL="" M_UNINSTALL="" M_ALLOW_CLAUDE="" M_ALLOW_OPENCODE=""
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
      name|version|prefix|arness|description|skills|agents|requires|provides|install|uninstall) ;;
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
      provides)    M_PROVIDES="$value" ;;
      install)     M_INSTALL="$value" ;;
      uninstall)   M_UNINSTALL="$value" ;;
    esac
  done < "$file"
}

is_runner() {
  case "$RUNNERS" in *" $1 "*) return 0 ;; esac
  [[ $1 =~ $RUNNER_RE ]]
}

# check_rule <provider> <rule>: an allowlist. A rule names one command the plugin provides (installed
# by its own install, so it runs the plugin's code anyway), never a system command from requires, and
# never a command runner.
check_rule() {
  local provider="$1" rule="$2" re cmd
  if [ "$provider" = claude ]; then re="$CLAUDE_RULE_RE"; else re="$OPENCODE_RULE_RE"; fi
  if ! [[ $rule =~ $re ]]; then
    if [ "$provider" = claude ]; then
      fail "$EXIT_INVALID" "BAD_RULE claude $rule: not Bash(<command> [args] [*])"
    fi
    fail "$EXIT_INVALID" "BAD_RULE opencode $rule: not <command> [args] [*]"
  fi
  cmd="${BASH_REMATCH[1]}"
  if is_runner "$cmd"; then fail "$EXIT_INVALID" "BAD_RULE $provider $rule: $cmd runs arbitrary code"; fi
  case " $M_PROVIDES " in
    *" $cmd "*) ;;
    *) fail "$EXIT_INVALID" "BAD_RULE $provider $rule: $cmd is not in provides" ;;
  esac
}

# check_names <kind> <list> <dir>: every name is a slug with the plugin prefix, exists in the plugin and
# carries the same name in its frontmatter (else the provider would load it under another name, or not).
check_names() {
  local kind="$1" list="$2" dir="$3" n file
  case "$list" in *[!a-z0-9\ -]*) fail "$EXIT_INVALID" "BAD_MANIFEST $kind: names must be lowercase slugs" ;; esac
  for n in $list; do
    is_slug "$n" || fail "$EXIT_INVALID" "BAD_MANIFEST $kind: invalid name $n"
    case "$n" in "$M_PREFIX"?*) ;; *) fail "$EXIT_INVALID" "BAD_MANIFEST $kind: $n lacks prefix $M_PREFIX" ;; esac
    if [ "$kind" = skills ]; then file="skills/$n/SKILL.md"; else file="agents/$n.md"; fi
    [ -f "$dir/$file" ] || fail "$EXIT_INVALID" "INVALID $file not found"
    grep -qx "name: $n" "$dir/$file" || fail "$EXIT_INVALID" "INVALID $file lacks 'name: $n'"
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
  case "$M_DESC$M_INSTALL$M_UNINSTALL" in *[[:cntrl:]]*) fail "$EXIT_INVALID" "BAD_MANIFEST control character in a value" ;; esac
  case "$M_REQUIRES$M_PROVIDES" in *[!A-Za-z0-9._\ -]*) fail "$EXIT_INVALID" "BAD_MANIFEST requires, provides: invalid command name" ;; esac
  local c
  for c in $M_PROVIDES; do
    if is_runner "$c"; then fail "$EXIT_INVALID" "BAD_MANIFEST provides: $c runs arbitrary code"; fi
  done
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

# check_provides_free: before a first install, a command the plugin says it provides must not exist
# yet, or its " *" rule would grant a system command (provides=rm).
check_provides_free() {
  local c
  for c in $M_PROVIDES; do
    if command -v "$c" >/dev/null 2>&1; then fail "$EXIT_INVALID" "BAD_MANIFEST provides: $c already exists on this machine"; fi
  done
}

# Warn in the plan when an existing opencode.json (copied once, never updated) lacks the rule that
# makes OpenCode ask before apply.
check_opencode_gate() {
  local f="$ROOT/opencode.json"
  if [ -f "$f" ] && ! grep -qF "$OPENCODE_APPLY_RULE" "$f"; then echo "OPENCODE_UNGATED opencode.json"; fi
}

# Claude Code rules arness grants for the plugin: Skill(<s>) for each skill, then its allow.claude rules.
claude_rules() {
  local n
  for n in $M_SKILLS; do printf 'Skill(%s)\n' "$n"; done
  printf '%s' "$M_ALLOW_CLAUDE"
}

print_rules() {
  local status="$1" provider="$2" rules="$3" rule
  while IFS= read -r rule; do
    if [ -n "$rule" ]; then echo "$status $provider $rule"; fi
  done <<< "$rules"
}

# print_plan <commit> <url> <ref> <kind> <dir>: everything the user consents to.
print_plan() {
  local n f
  echo "PLUGIN $M_NAME $M_VERSION $1"
  echo "SOURCE ${2:--} $3 $4"
  echo "DESCRIPTION $M_DESC"
  if [ -n "$M_REQUIRES" ]; then echo "REQUIRES $M_REQUIRES"; fi
  if [ -n "$M_PROVIDES" ]; then echo "PROVIDES $M_PROVIDES"; fi
  for n in $M_SKILLS; do echo "SKILL $n"; done
  for n in $M_AGENTS; do echo "AGENT $n"; done
  print_rules ALLOW claude "$(claude_rules)"
  print_rules ALLOW opencode "$M_ALLOW_OPENCODE"
  for n in $M_SKILLS; do
    for f in "$5/skills/$n/scripts/"*.sh; do
      if [ -f "$f" ]; then echo "OPENCODE_AUTO_ALLOW skills/$n/scripts/$(basename "$f")"; fi
    done
  done
  if [ -n "$M_INSTALL" ]; then echo "INSTALL $M_INSTALL"; fi
  if [ -n "$M_UNINSTALL" ]; then echo "UNINSTALL $M_UNINSTALL"; fi
  check_opencode_gate
}

print_manual() {
  local n
  print_rules "MANUAL opencode" bash "$M_ALLOW_OPENCODE"
  for n in $M_SKILLS; do echo "MANUAL opencode skill $n"; done
}

# --- state: what apply validated, the only source render, sync, list and remove trust ------------

state_file() { printf '%s/.%s.state\n' "$PLUGINS" "$1"; }

# write_state <name> <commit> <ref> <kind> <status>, from the validated M_* globals.
write_state() {
  local file tmp
  file="$(state_file "$1")"
  tmp="$file.tmp"
  {
    printf 'commit=%s\nref=%s\nkind=%s\nstatus=%s\n' "$2" "$3" "$4" "$5"
    printf 'version=%s\nskills=%s\nagents=%s\nprovides=%s\nuninstall=%s\n' "$M_VERSION" "$M_SKILLS" "$M_AGENTS" "$M_PROVIDES" "$M_UNINSTALL"
    claude_rules | awk 'NF { print "allow.claude=" $0 }'
    printf '%s' "$M_ALLOW_OPENCODE" | awk 'NF { print "allow.opencode=" $0 }'
  } > "$tmp"
  mv "$tmp" "$file"
}

state_value() { conf_value "$(state_file "$1")" "$2" | awk 'NR == 1'; }

set_status() {
  local file tmp
  file="$(state_file "$1")"
  tmp="$file.tmp"
  S="$2" awk '/^status=/ { print "status=" ENVIRON["S"]; next } { print }' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# --- links ---------------------------------------------------------------------

# belongs_to <path> <name>: path is a link that link_plugin made for plugins/<name>: its target starts
# with ../plugins/<name>/ (or the absolute form a Windows junction reports). No substring match: a link
# into any other folder called plugins/<name> is not ours.
belongs_to() {
  local t
  [ -L "$1" ] || return 1
  t="$(readlink "$1")"
  case "$t" in "../plugins/$2/"*|"$ROOT/plugins/$2/"*) return 0 ;; esac
  return 1
}

taken() { [ -e "$1" ] || [ -L "$1" ]; }

check_conflicts() {
  local name="$1" n p
  for n in $M_SKILLS; do
    p="$ROOT/skills/$n"
    if taken "$p"; then belongs_to "$p" "$name" || fail "$EXIT_CONFLICT" "NAME_CONFLICT skills/$n"; fi
  done
  for n in $M_AGENTS; do
    p="$ROOT/agents/$n.md"
    if taken "$p"; then belongs_to "$p" "$name" || fail "$EXIT_CONFLICT" "NAME_CONFLICT agents/$n.md"; fi
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

# run_cmd <dir> <cmd>: run a plugin's install or uninstall command in its folder, without the git and
# arness settings of this script. There is no time limit: a command that hangs blocks until interrupted.
run_cmd() {
  (cd "$1" && unset ARNESS_ROOT GIT_ALLOW_PROTOCOL GIT_TERMINAL_PROMPT && bash -c "$2") >&2
}

run_install() {
  local name="$1" dir="$2" c
  if [ -n "$M_INSTALL" ] && ! run_cmd "$dir" "$M_INSTALL"; then
    set_status "$name" install-failed
    fail "$EXIT_INSTALL" "INSTALL_FAILED $name"
  fi
  for c in $M_PROVIDES; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "error: install did not provide the command $c" >&2
      set_status "$name" install-failed
      fail "$EXIT_INSTALL" "INSTALL_FAILED $name"
    fi
  done
}

# --- git -----------------------------------------------------------------------

# dirty_reason <dir> <applied-commit>: why the clone must not be touched; empty when clean. Untracked
# files do not count: they are usually what the plugin's install command built in its folder.
dirty_reason() {
  local dir="$1" applied="$2"
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "uncommitted-changes"; return
  fi
  if [ -n "$applied" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$applied" ]; then
    echo "moved"
  fi
}

new_tmp() {
  mkdir -p "$PLUGINS"
  TMP_DIR="$(mktemp -d "$PLUGINS/.plugin-manage.XXXXXX")"
  trap cleanup EXIT
}

# resolve_ref <dir> <ref>: print "<commit> <ref> <kind>". An empty ref means the remote default branch.
resolve_ref() {
  local dir="$1" ref="$2" c
  if [ -z "$ref" ]; then
    ref="$(git -C "$dir" symbolic-ref --short -q refs/remotes/origin/HEAD || true)"
    ref="${ref#origin/}"
    [ -n "$ref" ] || die "the remote has no default branch; pass --ref"
  fi
  if c="$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}")"; then echo "$c $ref branch"; return; fi
  if c="$(git -C "$dir" rev-parse --verify --quiet "refs/tags/$ref^{commit}")"; then echo "$c $ref tag"; return; fi
  if validate_commit "$ref" && c="$(git -C "$dir" rev-parse --verify --quiet "$ref^{commit}")"; then
    echo "$c $c commit"; return
  fi
  die "ref not found: $ref"
}

# newest_tag <dir>: the highest stable version tag, [v]MAJOR.MINOR.PATCH (git's version sort), empty
# when there is none. Pre-releases and other tags (latest, nightly) only through an explicit --ref.
newest_tag() {
  git -C "$1" tag --list --sort=-v:refname | awk '/^v?[0-9]+\.[0-9]+\.[0-9]+$/ { print; exit }'
}

# export_tree <dir> <commit> <out>: the commit's files as checkout writes them (a private index;
# unlike git archive, export-ignore and export-subst do not apply), without touching the clone.
export_tree() {
  mkdir -p "$3"
  GIT_INDEX_FILE="$TMP_DIR/index" git -C "$1" read-tree "$2"
  GIT_INDEX_FILE="$TMP_DIR/index" git -C "$1" --work-tree="$3" checkout-index -a -f
}

# --- add -----------------------------------------------------------------------------

# prepare_add <url> <ref>: clone into a temp folder, check out, validate. Sets ADD_DIR, ADD_COMMIT,
# ADD_REF and ADD_KIND, and the M_* globals.
prepare_add() {
  local url="$1" ref="$2" resolved
  new_tmp
  ADD_DIR="$TMP_DIR/repo"
  git clone --quiet --no-checkout -- "$url" "$ADD_DIR" >&2 || { echo "error: git clone failed for $url" >&2; exit "$EXIT_GIT"; }
  resolved="$(resolve_ref "$ADD_DIR" "$ref")"
  ADD_COMMIT="${resolved%% *}"
  resolved="${resolved#* }"
  ADD_REF="${resolved% *}"
  ADD_KIND="${resolved##* }"
  git -C "$ADD_DIR" checkout --quiet --detach "$ADD_COMMIT" >&2
  validate_plugin "$ADD_DIR"
  check_requirements
  if [ -e "$PLUGINS/$M_NAME" ] || [ -L "$PLUGINS/$M_NAME" ]; then fail "$EXIT_EXISTS" "ALREADY_INSTALLED $M_NAME"; fi
  check_provides_free
  check_conflicts "$M_NAME"
}

parse_add_args() {
  ARG_URL="" ARG_REF="" ARG_COMMIT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref)    [ $# -ge 2 ] || die "--ref needs a value"; ARG_REF="$2"; shift 2 ;;
      --commit) [ $# -ge 2 ] || die "--commit needs a value"; ARG_COMMIT="$2"; shift 2 ;;
      -*)       die "unknown option: $1" ;;
      *)        [ -z "$ARG_URL" ] || die "only one URL allowed"; ARG_URL="$1"; shift ;;
    esac
  done
  [ -n "$ARG_URL" ] || die "missing plugin URL"
  validate_url "$ARG_URL" || die "invalid URL (allowed: https://, ssh://, git@host:path, file://): $ARG_URL"
  if [ -n "$ARG_REF" ]; then validate_ref "$ARG_REF" || die "invalid --ref: $ARG_REF"; fi
  if [ -n "$ARG_COMMIT" ]; then validate_commit "$ARG_COMMIT" || die "invalid --commit: $ARG_COMMIT"; fi
}

cmd_add() {
  parse_add_args "$@"
  [ -z "$ARG_COMMIT" ] || die "--commit belongs to 'apply add'"
  prepare_add "$ARG_URL" "$ARG_REF"
  print_plan "$ADD_COMMIT" "$ARG_URL" "$ADD_REF" "$ADD_KIND" "$ADD_DIR"
  fail "$EXIT_CONFIRM" "CONFIRM_ADD $M_NAME $ADD_COMMIT"
}

apply_add() {
  parse_add_args "$@"
  validate_full_commit "$ARG_COMMIT" || die "apply add needs --commit <full 40-character sha> from the plan (CONFIRM_ADD)"
  prepare_add "$ARG_URL" "$ARG_REF"
  [ "$ARG_COMMIT" = "$ADD_COMMIT" ] || fail "$EXIT_MISMATCH" "MISMATCH $ARG_COMMIT $ADD_COMMIT"
  local dest="$PLUGINS/$M_NAME"
  mv "$ADD_DIR" "$dest"
  link_plugin "$M_NAME" "$M_SKILLS" "$M_AGENTS"
  write_state "$M_NAME" "$ADD_COMMIT" "$ADD_REF" "$ADD_KIND" ok
  refresh_providers
  run_install "$M_NAME" "$dest"
  print_manual
  echo "ADDED $M_NAME $dest"
}

# --- update ----------------------------------------------------------------------------

# prepare_update <name> <ref> <fetch>: check the clone, resolve the target, validate it from its tree.
# Sets UP_DEST, UP_OLD, UP_TARGET, UP_REF, UP_KIND and the M_* globals of the new version. Prints
# UP_TO_DATE and sets UP_NOOP=1 when there is nothing to do. (Not a return code: a function called
# as `f || ...` runs without set -e.)
prepare_update() {
  local name="$1" ref="$2" fetch="$3" kind resolved why
  UP_NOOP=0
  UP_DEST="$PLUGINS/$name"
  [ -d "$UP_DEST/.git" ] && [ -f "$(state_file "$name")" ] || fail "$EXIT_NOT_INSTALLED" "NOT_INSTALLED $name"
  UP_OLD="$(state_value "$name" commit)"
  why="$(dirty_reason "$UP_DEST" "$UP_OLD")"
  if [ -n "$why" ]; then fail "$EXIT_DIRTY" "DIRTY $UP_DEST $why"; fi
  if [ "$fetch" -eq 1 ]; then
    git -C "$UP_DEST" fetch --quiet --tags --force --prune origin >&2 \
      || { echo "error: git fetch failed in $UP_DEST" >&2; exit "$EXIT_GIT"; }
  fi
  if [ -z "$ref" ]; then
    kind="$(state_value "$name" kind)"
    case "$kind" in
      branch) ref="$(state_value "$name" ref)" ;;
      tag)    ref="$(newest_tag "$UP_DEST")"; [ -n "$ref" ] || die "$name follows tags, but the remote has none" ;;
      *)      die "$name is pinned to a commit; pass --ref" ;;
    esac
  fi
  resolved="$(resolve_ref "$UP_DEST" "$ref")"
  UP_TARGET="${resolved%% *}"
  resolved="${resolved#* }"
  UP_REF="${resolved% *}"
  UP_KIND="${resolved##* }"
  if [ "$UP_TARGET" = "$UP_OLD" ] && [ "$UP_REF" = "$(state_value "$name" ref)" ]; then
    echo "UP_TO_DATE $name $UP_OLD $UP_REF"
    UP_NOOP=1
    return 0
  fi
  new_tmp
  export_tree "$UP_DEST" "$UP_TARGET" "$TMP_DIR/tree"
  validate_plugin "$TMP_DIR/tree"
  [ "$M_NAME" = "$name" ] || fail "$EXIT_INVALID" "BAD_MANIFEST name changed from $name to $M_NAME"
  check_requirements
  # Commands provided since the installed version must not exist yet, like on a first install.
  local c old_provides
  old_provides="$(state_value "$name" provides)"
  for c in $M_PROVIDES; do
    case " $old_provides " in
      *" $c "*) ;;
      *) if command -v "$c" >/dev/null 2>&1; then fail "$EXIT_INVALID" "BAD_MANIFEST provides: $c already exists on this machine"; fi ;;
    esac
  done
  check_conflicts "$name"
}

parse_name_args() {
  ARG_NAME="" ARG_REF="" ARG_COMMIT="" ARG_FETCH=1 ARG_FORCE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref)      [ $# -ge 2 ] || die "--ref needs a value"; ARG_REF="$2"; shift 2 ;;
      --commit)   [ $# -ge 2 ] || die "--commit needs a value"; ARG_COMMIT="$2"; shift 2 ;;
      --no-fetch) ARG_FETCH=0; shift ;;
      --force)    ARG_FORCE=1; shift ;;
      -*)         die "unknown option: $1" ;;
      *)          [ -z "$ARG_NAME" ] || die "only one plugin name allowed"; ARG_NAME="$1"; shift ;;
    esac
  done
  [ -n "$ARG_NAME" ] || die "missing plugin name"
  is_slug "$ARG_NAME" || die "invalid plugin name: $ARG_NAME"
  if [ -n "$ARG_REF" ]; then validate_ref "$ARG_REF" || die "invalid --ref: $ARG_REF"; fi
  if [ -n "$ARG_COMMIT" ]; then validate_commit "$ARG_COMMIT" || die "invalid --commit: $ARG_COMMIT"; fi
}

cmd_update() {
  parse_name_args "$@"
  [ -z "$ARG_COMMIT" ] || die "--commit belongs to 'apply update'"
  [ "$ARG_FORCE" -eq 0 ] || die "unknown option: --force"
  local name="$ARG_NAME" state rule
  prepare_update "$name" "$ARG_REF" "$ARG_FETCH"
  if [ "$UP_NOOP" -eq 1 ]; then return 0; fi
  state="$(state_file "$name")"
  print_plan "$UP_TARGET" "" "$UP_REF" "$UP_KIND" "$TMP_DIR/tree"
  while IFS= read -r rule; do
    if [ -n "$rule" ] && ! conf_value "$state" allow.claude | grep -qxF -- "$rule"; then echo "NEW_ALLOW claude $rule"; fi
  done <<< "$(claude_rules)"
  while IFS= read -r rule; do
    if [ -n "$rule" ] && ! conf_value "$state" allow.opencode | grep -qxF -- "$rule"; then echo "NEW_ALLOW opencode $rule"; fi
  done <<< "$M_ALLOW_OPENCODE"
  fail "$EXIT_CONFIRM" "CONFIRM_UPDATE $name $UP_OLD $UP_TARGET $UP_REF"
}

# No fetch: apply moves to what the plan fetched and showed, or reports MISMATCH.
apply_update() {
  parse_name_args "$@"
  validate_full_commit "$ARG_COMMIT" || die "apply update needs --commit <full 40-character sha> from the plan (CONFIRM_UPDATE)"
  [ "$ARG_FORCE" -eq 0 ] || die "unknown option: --force"
  local name="$ARG_NAME"
  prepare_update "$name" "$ARG_REF" 0
  if [ "$UP_NOOP" -eq 1 ]; then return 0; fi
  [ "$ARG_COMMIT" = "$UP_TARGET" ] || fail "$EXIT_MISMATCH" "MISMATCH $ARG_COMMIT $UP_TARGET"
  # Detached: no local branch is created or reset, so nothing local can be lost.
  git -C "$UP_DEST" checkout --quiet --detach "$UP_TARGET" >&2
  unlink_plugin "$name"
  link_plugin "$name" "$M_SKILLS" "$M_AGENTS"
  write_state "$name" "$UP_TARGET" "$UP_REF" "$UP_KIND" ok
  refresh_providers
  run_install "$name" "$UP_DEST"
  print_manual
  echo "UPDATED $name $UP_OLD $UP_TARGET"
}

# --- remove ----------------------------------------------------------------------------

cmd_remove() {
  parse_name_args "$@"
  [ -z "$ARG_REF$ARG_COMMIT" ] && [ "$ARG_FORCE" -eq 0 ] || die "remove takes only a plugin name"
  local name="$ARG_NAME" n uninstall
  [ -d "$PLUGINS/$name" ] || fail "$EXIT_NOT_INSTALLED" "NOT_INSTALLED $name"
  echo "PLUGIN $name $(state_value "$name" version | sed 's/^$/-/') $(state_value "$name" commit | sed 's/^$/-/')"
  for n in $(state_value "$name" skills); do echo "SKILL $n"; done
  for n in $(state_value "$name" agents); do echo "AGENT $n"; done
  uninstall="$(state_value "$name" uninstall)"
  if [ -n "$uninstall" ]; then echo "UNINSTALL $uninstall"; fi
  fail "$EXIT_CONFIRM" "CONFIRM_REMOVE $name"
}

apply_remove() {
  parse_name_args "$@"
  [ -z "$ARG_REF$ARG_COMMIT" ] || die "apply remove takes only --force and a plugin name"
  local name="$ARG_NAME" dest="$PLUGINS/$ARG_NAME" why uninstall
  [ -d "$dest" ] || fail "$EXIT_NOT_INSTALLED" "NOT_INSTALLED $name"
  why="$(dirty_reason "$dest" "$(state_value "$name" commit)")"
  if [ -n "$why" ] && [ "$ARG_FORCE" -eq 0 ]; then fail "$EXIT_DIRTY" "DIRTY $dest $why"; fi
  # From the state, not the clone: a manifest changed since apply must not choose what runs here.
  uninstall="$(state_value "$name" uninstall)"
  if [ -n "$uninstall" ]; then
    run_cmd "$dest" "$uninstall" || echo "warning: uninstall failed, removing anyway: $uninstall" >&2
  fi
  unlink_plugin "$name"
  rm -rf "$dest"
  rm -f "$(state_file "$name")"
  refresh_providers
  echo "REMOVED $name"
}

# --- list, check, sync -------------------------------------------------------------------

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

or_dash() { if [ -n "$1" ]; then printf '%s\n' "$1"; else echo "-"; fi; }

cmd_list() {
  [ $# -eq 0 ] || die "list takes no arguments"
  local dir name s a state commit any=0
  for dir in "$PLUGINS"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    any=1
    commit="$(state_value "$name" commit)"
    s="$(count_linked "$name" skills "$(state_value "$name" skills)")"
    a="$(count_linked "$name" agents "$(state_value "$name" agents)")"
    if [ ! -f "$(state_file "$name")" ]; then state=UNMANAGED
    elif [ "$(state_value "$name" status)" = install-failed ]; then state=INSTALL_FAILED
    elif [ -n "$(dirty_reason "$dir" "$commit")" ]; then state=MODIFIED
    elif [ "${s%/*}" != "${s#*/}" ] || [ "${a%/*}" != "${a#*/}" ]; then state=BROKEN_LINK
    else state=OK
    fi
    echo "INSTALLED $name $(or_dash "$(state_value "$name" version)") $(or_dash "$(printf '%s' "$commit" | cut -c1-7)") $(or_dash "$(state_value "$name" ref)") $state $s $a"
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

# Restore the links of every installed plugin, from its state (setup.sh runs it). A path taken by
# something else, a dangling link included, is reported and left alone.
cmd_sync() {
  [ $# -eq 0 ] || die "sync takes no arguments"
  local dir name n p
  for dir in "$PLUGINS"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    [ -f "$(state_file "$name")" ] || { echo "warning: $name was not installed with plugin-manage, skipped" >&2; continue; }
    mkdir -p "$ROOT/skills" "$ROOT/agents"
    for n in $(state_value "$name" skills); do
      p="$ROOT/skills/$n"
      if taken "$p" && ! belongs_to "$p" "$name"; then echo "warning: skills/$n exists, not linked" >&2; continue; fi
      relink "../plugins/$name/skills/$n" "$p"
    done
    for n in $(state_value "$name" agents); do
      p="$ROOT/agents/$n.md"
      if taken "$p" && ! belongs_to "$p" "$name"; then echo "warning: agents/$n.md exists, not linked" >&2; continue; fi
      relink "../plugins/$name/agents/$n.md" "$p"
    done
    echo "SYNCED $name"
  done
}

cmd_apply() {
  local what="${1:-}"
  [ $# -gt 0 ] && shift
  case "$what" in
    add)    apply_add "$@" ;;
    update) apply_update "$@" ;;
    remove) apply_remove "$@" ;;
    *)      die "apply needs add, update or remove" ;;
  esac
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
  export ARNESS_ROOT="$ROOT" GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL="https:ssh:file"
  # shellcheck source=SCRIPTDIR/../../../scripts/lib.sh
  . "$ROOT/scripts/lib.sh"
  case "$cmd" in
    add)    cmd_add "$@" ;;
    update) cmd_update "$@" ;;
    remove) cmd_remove "$@" ;;
    apply)  cmd_apply "$@" ;;
    list)   cmd_list "$@" ;;
    check)  cmd_check "$@" ;;
    sync)   cmd_sync "$@" ;;
    *)      die "unknown command: $cmd (add, update, remove, apply, list, check, sync)" ;;
  esac
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
