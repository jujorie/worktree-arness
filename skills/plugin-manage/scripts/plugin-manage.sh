#!/usr/bin/env bash
# Add, update, remove and list arness plugins: git repos with an arness-plugin.conf at their root, cloned
# into plugins/<name>, whose skills and agents are linked into skills/ and agents/ and whose Claude Code
# permission rules are rendered into .claude/settings.json. See plugins/README.md.
#
# Usage: plugin-manage.sh add [--ref REF] <url|name>                  plan only, writes nothing
#        plugin-manage.sh update [--ref REF] [--no-fetch] <name>      plan only (fetches)
#        plugin-manage.sh remove <name>                               plan only
#        plugin-manage.sh apply add --commit SHA --adopted 0|1 [--ref REF] [SELECTION] <url>
#        plugin-manage.sh apply update --commit SHA --adopted 0|1 [--ref REF] [SELECTION] <name>
#        plugin-manage.sh apply remove [--force] <name>
#        plugin-manage.sh list
#        plugin-manage.sh check <dir>
#        plugin-manage.sh sync
#        plugin-manage.sh run-hook <event> <args>...
#        plugin-manage.sh catalog
#
# PLUGINS.md at the arness root lists the official plugins in a table (Name | URL | Ref | Description).
# catalog prints them; add takes a name of it instead of a URL: its URL, and its Ref unless --ref is
# given. The plugin's manifest must carry that name (CATALOG_MISMATCH otherwise). apply add then takes the
# URL and ref of the plan's SOURCE line, never the name. Being in the catalog skips no check and no
# confirmation.
# add, update and remove only print the plan. Only `apply` changes anything; it is kept out of the
# permission allowlists on purpose, so the agent's own tool prompt asks the user before it runs.
# What arness uses of an installed plugin (rules, links, uninstall) comes from plugins/.<name>.state,
# written by apply from the validated manifest, never from the clone's files as they are now.
#
# SELECTION: --skills <a,b|-> --agents <a,b|-> --replace <skills/<n>,agents/<n>.md>. Which of the
# plugin's skills and agents to link ("-": none); without --skills (--agents), the SELECT line of the
# plan. A selected name taken by something that is not this plugin's (a CONFLICT line) needs its path in
# --replace, or apply stops with NAME_CONFLICT. Replacing never deletes: a skill or agent of this repo
# (tracked) cannot be replaced (NOT_REPLACEABLE); a local one is moved to plugins/.replaced/<plugin>/;
# one of another plugin leaves that plugin's selection; a dangling link is removed. The state records the
# selection (skills=, agents=), what was left out (skipped.skills=, skipped.agents=) and what was replaced
# (replaced=); update keeps the selection, and remove (or an update that drops a replacing skill) puts
# back what was replaced.
# run-hook runs the hook.<event> command of every installed plugin that declares one, in its folder, with
# <args> appended (events: worktree-remove, run by worktree-clean before it removes a worktree, with
# <repo>/<name>). A plugin whose clone was changed (MODIFIED in list) is not run: it counts as failed.
#
# Stdout (machine readable), first word is the status:
#   PLUGIN <name> <version> <commit>      plan header
#   CATALOG <name>                        plan: the plugin comes from PLUGINS.md
#   OFFICIAL <name> <url> <ref> <description>   catalog: one line per official plugin
#   SOURCE <url|-> <ref> <branch|tag|commit>
#   DESCRIPTION <text> | REQUIRES <commands> | PROVIDES <commands>
#   SKILL <name> | AGENT <name>           what the plugin links (selected by default)
#   NEW_SKILL <name> | NEW_AGENT <name>   update: declared since the installed version (selected by default)
#   SKIPPED_SKILL <name> | SKIPPED_AGENT <name>   update: left out at install or last update (not selected)
#   CONFLICT <path> <tracked|local|dangling|plugin:<name>>   the name is taken by something else: a
#                                         skill or agent of this repo (cannot be replaced), a local one,
#                                         a dangling link or another plugin's link (not selected)
#   SELECT <skills|agents> <a,b|->        the default selection apply takes without --skills / --agents
#   RESTORE <path> <local|plugin:<name>>  remove, update: what the plugin replaced and apply puts back (on
#                                         update, unless it is selected again)
#   RESTORE_IF_UNSELECTED <path> <how>    update: selected by default; apply puts it back if left out
#   RESTORED <path>                       apply: put back what the plugin had replaced
#   RESTORE_SKIPPED <path> <taken|missing> <backup|plugin:<name>|invalid>   apply: could not put it
#                                         back; a backup stays where shown, and update keeps it recorded
#                                         (taken). invalid: a replaced= line of the state that is not an
#                                         item path, ignored (nothing to put back)
#   ALLOW <provider> <rule>               rule rendered (claude) or to add by hand (opencode)
#   NEW_ALLOW <provider> <rule>           update: rule the installed version did not have
#   OPENCODE_AUTO_ALLOW <path>            a plugin skill script OpenCode runs without asking
#                                         (its skills/*/scripts/*.sh rule)
#   OPENCODE_UNGATED <file>               that opencode.json lets OpenCode run `apply` without asking:
#                                         it lacks the "ask" rule of providers/opencode/opencode.json
#   INSTALL <cmd> | UNINSTALL <cmd>       command run in the plugin folder by apply
#   HOOK <event> <cmd>                    plan: command arness runs in the plugin folder on <event>
#   HOOK <name> <line>                    run-hook: a line the plugin's hook printed
#   HOOK_FAILED <name> <exit|modified|missing>  run-hook: that hook failed or was not run (exit 15)
#   ADOPT <command> <path>                a provided command already installed at the path its adopt= line
#                                         declares (e.g. by this plugin from another arness): that path,
#                                         ending in /<command> under a folder named after the plugin, is
#                                         on the command's link chain. It is used as it is; adopting only
#                                         some of the provided commands is BAD_MANIFEST
#   INSTALL_SKIPPED <cmd> | UNINSTALL_SKIPPED <cmd>
#                                         every provided command is adopted: apply does not run install,
#                                         and remove does not run uninstall (the command is not ours)
#   DROPPED_SETTING <line>                a line of .claude/settings.json edited by hand (no template or
#                                         plugin rule gives it): apply renders the file again and loses
#                                         it. Move it to .claude/settings.local.json before apply
#   CONFIRM_ADD <name> <commit> <adopted> plan printed; nothing written (exit 20). <adopted> is 1 when
#                                         install is skipped (ADOPT), else 0: apply takes it as --adopted
#   CONFIRM_UPDATE <name> <from> <to> <ref> <adopted>   plan printed; nothing written (exit 20)
#   CONFIRM_REMOVE <name>                 plan printed; nothing written (exit 20)
#   ADDED <name> <path>                   cloned, linked, rules rendered, install run
#   UPDATED <name> <from> <to>            moved to <to>, links and rules refreshed, install run
#   UP_TO_DATE <name> <commit> <ref>      update: nothing new
#   REMOVED <name>                        uninstall run, links, clone, state and rules gone
#   MANUAL opencode <bash|skill> <entry>  add it to opencode.json yourself: setup never edits that file
#   VALID <name> <version>                check passed
#   INSTALLED <name> <version> <commit> <ref> <state> <skills> <agents>
#                                         list line; state OK|BROKEN_LINK|MODIFIED|INSTALL_FAILED|UNMANAGED,
#                                         skills and agents as linked/selected; "-" for an unknown value
#   NONE                                  list: no plugins; catalog: no official plugin
#   BAD_CATALOG line <n>: <detail>        PLUGINS.md has a row that is not a valid entry (exit 4)
#   NOT_IN_CATALOG <name>                 add: no official plugin of that name (exit 16)
#   CATALOG_MISMATCH <catalog> <manifest> the catalog's repo is a plugin with another name (exit 4)
#   SYNCED <name>                         sync restored the plugin's links
#   BAD_MANIFEST <detail>                 manifest syntax or field error (exit 4)
#   INVALID <detail>                      a declared skill or agent is missing or misnamed (exit 4)
#   ARNESS_VERSION <value>                unsupported plugin contract (exit 4)
#   BAD_RULE <provider> <rule>: <why>     rule outside the allowed shapes (exit 4)
#   MISSING_REQUIREMENT <command>         a required command is not installed (exit 5)
#   NAME_CONFLICT <path>                  apply: a selected skill or agent is taken and not in --replace (exit 6)
#   NOT_REPLACEABLE <path> tracked        apply: --replace names a skill or agent of this repo (exit 6)
#   BACKUP_EXISTS <path>                  apply: the folder a replaced one would move to is taken (exit 6)
#   ALREADY_INSTALLED <name>              use update (exit 10)
#   DIRTY <path> <why>                    uncommitted-changes or moved (HEAD is not the applied commit) (exit 11)
#   NOT_INSTALLED <name>                  (exit 12)
#   INSTALL_FAILED <name>                 install command failed; clone and links kept (exit 13)
#   MISMATCH <expected> <actual>          --commit is not what the plan resolved to (exit 14)
#   ADOPTION_CHANGED <expected> <actual>  --adopted is not what apply finds now: the adopted command
#                                         appeared or went away since the plan; nothing written (exit 14)
# Exit codes: 0 ok, 2 invalid usage, 3 clone or fetch failed, 4 invalid plugin, 5 missing requirement,
#   6 name conflict, 10 already installed, 11 dirty, 12 not installed, 13 install failed, 14 mismatch
#   (MISMATCH, ADOPTION_CHANGED), 15 a hook failed, 16 not in the catalog,
#   20 plan printed, confirmation needed.
set -euo pipefail

EXIT_USAGE=2 EXIT_GIT=3 EXIT_INVALID=4 EXIT_REQUIREMENT=5 EXIT_CONFLICT=6
EXIT_EXISTS=10 EXIT_DIRTY=11 EXIT_NOT_INSTALLED=12 EXIT_INSTALL=13 EXIT_MISMATCH=14 EXIT_HOOK=15
EXIT_NOT_IN_CATALOG=16
EXIT_CONFIRM=20

CONTRACT=1
MANIFEST=arness-plugin.conf
SLUG_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
# Allowed rule shapes: one command (one the plugin provides), optional literal arguments, optional
# trailing " *".
CLAUDE_RULE_RE='^Bash\(([A-Za-z0-9._+-]+)(( [A-Za-z0-9._/=:@+,-]+)*)( \*)?\)$'
OPENCODE_RULE_RE='^([A-Za-z0-9._+-]+)(( [A-Za-z0-9._/=:@+,-]+)*)( \*)?$'
# Events a plugin may hook (hook.<event>=<command>), each run by one arness script with fixed arguments.
HOOK_EVENTS=" worktree-remove "
# A hook command: a relative path to an executable of the plugin, then literal arguments.
HOOK_RE='^([A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*)(( [A-Za-z0-9._/=:@+,-]+)*)$'
# adopt=<command> <path relative to $HOME>
ADOPT_RE='^([A-Za-z0-9._-]+) ([A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*)$'
# Commands that run arbitrary code from their arguments: no rule may name them, even with literal
# arguments. Versioned names (python3.12, node20, gawk) are caught by RUNNER_RE.
RUNNERS=" bash sh zsh dash ksh fish csh tcsh pwsh powershell env sudo su doas xargs eval exec command nohup"
RUNNERS="$RUNNERS time timeout watch nice osascript open find awk sed git make cmake ssh scp rsync tar curl"
RUNNERS="$RUNNERS wget docker podman kubectl gh npx pnpx uvx pipx uv npm pnpm yarn pip cargo go bun deno "
RUNNER_RE='^(python|pypy|node|nodejs|ruby|perl|php|lua|luajit|g?awk|mawk|nawk|gsed|pip)[0-9.]*$'
# The rule OpenCode needs so that its skills/*/scripts/*.sh allow does not cover apply.
OPENCODE_APPLY_RULE='"skills/plugin-manage/scripts/plugin-manage.sh apply *": "ask"'

ROOT="" PLUGINS=""
ADOPTED=0    # 1: every provided command is adopted, install and uninstall do not run (check_provides)
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
  M_INSTALL="" M_UNINSTALL="" M_ALLOW_CLAUDE="" M_ALLOW_OPENCODE="" M_HOOKS="" M_ADOPT=""
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
      adopt)          M_ADOPT="${M_ADOPT}${value}"$'\n'; continue ;;
      name|version|prefix|arness|description|skills|agents|requires|provides|install|uninstall) ;;
      hook.*)
        case "$HOOK_EVENTS" in
          *" ${key#hook.} "*) ;;
          *) fail "$EXIT_INVALID" "BAD_MANIFEST line $n: unknown hook event ${key#hook.}" ;;
        esac ;;
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
      hook.*)      M_HOOKS="${M_HOOKS}${key#hook.}=${value}"$'\n' ;;
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

# check_hook <event> <cmd> <dir>: the command is a regular executable file of the plugin (no link, no ..),
# followed by literal arguments only, so the state names exactly what runs.
check_hook() {
  local event="$1" cmd="$2" dir="$3" path part rest
  [[ $cmd =~ $HOOK_RE ]] || fail "$EXIT_INVALID" "BAD_MANIFEST hook.$event: not <relative path> [literal args]: $cmd"
  path="${BASH_REMATCH[1]}"
  rest="$path"
  while :; do
    part="${rest%%/*}"
    case "$part" in .|..|-*) fail "$EXIT_INVALID" "BAD_MANIFEST hook.$event: invalid path $path" ;; esac
    [ "$part" != "$rest" ] || break
    rest="${rest#*/}"
  done
  rest="$dir"
  for part in $(printf '%s' "$path" | tr '/' ' '); do
    rest="$rest/$part"
    [ ! -L "$rest" ] || fail "$EXIT_INVALID" "INVALID hook.$event: $path goes through a link"
  done
  [ -f "$dir/$path" ] && [ -x "$dir/$path" ] || fail "$EXIT_INVALID" "INVALID hook.$event: $path is not an executable file"
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

# check_adopt: each adopt line is "<command> <path>", once per command, for a command in provides,
# with a plain relative path (no "..", ".", empty segments or leading /) that is read under $HOME,
# ends in /<command> and has a folder named after the plugin (as uv tool's <tool dir>/<plugin>/bin/<cmd>),
# so it cannot name the install folder of another tool (mise, cargo, go) for a command the user has.
check_adopt() {
  local line c p seen=" " seg
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ $line =~ $ADOPT_RE ]] || fail "$EXIT_INVALID" "BAD_MANIFEST adopt: not <command> <path under \$HOME>: $line"
    c="${BASH_REMATCH[1]}" p="${BASH_REMATCH[2]}"
    case " $M_PROVIDES " in *" $c "*) ;; *) fail "$EXIT_INVALID" "BAD_MANIFEST adopt: $c is not in provides" ;; esac
    case "$seen" in *" $c "*) fail "$EXIT_INVALID" "BAD_MANIFEST adopt: duplicate command $c" ;; esac
    seen="$seen$c "
    for seg in ${p//\// }; do
      case "$seg" in .|..) fail "$EXIT_INVALID" "BAD_MANIFEST adopt: $p has a . or .. segment" ;; esac
    done
    case "$p" in */"$c") ;; *) fail "$EXIT_INVALID" "BAD_MANIFEST adopt: $p does not end in /$c" ;; esac
    case "/$p" in */"$M_NAME"/*) ;; *) fail "$EXIT_INVALID" "BAD_MANIFEST adopt: $p has no folder named $M_NAME" ;; esac
  done <<< "$M_ADOPT"
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
  case "$M_DESC$M_INSTALL$M_UNINSTALL$(printf '%s' "$M_HOOKS" | tr '\n' ' ')" in *[[:cntrl:]]*) fail "$EXIT_INVALID" "BAD_MANIFEST control character in a value" ;; esac
  case "$M_REQUIRES$M_PROVIDES" in *[!A-Za-z0-9._\ -]*) fail "$EXIT_INVALID" "BAD_MANIFEST requires, provides: invalid command name" ;; esac
  local c
  for c in $M_PROVIDES; do
    if is_runner "$c"; then fail "$EXIT_INVALID" "BAD_MANIFEST provides: $c runs arbitrary code"; fi
  done
  check_names skills "$M_SKILLS" "$dir"
  check_names agents "$M_AGENTS" "$dir"
  local hook
  while IFS= read -r hook; do
    if [ -n "$hook" ]; then check_hook "${hook%%=*}" "${hook#*=}" "$dir"; fi
  done <<< "$M_HOOKS"
  check_adopt
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

# physical_path <path>: the path with its folder resolved physically (cd -P) and its last component
# kept as it is, so a link is named, not followed; fails when the folder does not exist.
physical_path() {
  local d
  d="$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "${d%/}" "$(basename "$1")"
}

# adopted_path <command>: the declared path ($HOME/<path> of its adopt= line) when it is one of the
# paths on the command's link chain, from `command -v` to the file, each named physically; empty
# otherwise. Only the chain counts, not the file at its end: commands that share one binary (mise
# shims) do not match each other's path. An empty $HOME, or one that is /, adopts nothing. Nothing of
# the plugin runs: the paths are only compared (one readlink per hop: portable to BSD readlink).
adopted_path() {
  local c="$1" rel home want p t n=0
  rel="$(printf '%s' "$M_ADOPT" | awk -v c="$c" '$1 == c { print $2; exit }')"
  [ -n "$rel" ] && [ -n "${HOME:-}" ] || return 0
  home="$(cd -P "$HOME" 2>/dev/null && pwd -P)" || return 0
  [ -n "$home" ] && [ "$home" != / ] || return 0
  want="$(physical_path "$home/$rel")" || return 0
  p="$(command -v "$c" 2>/dev/null)" || return 0
  case "$p" in /*) ;; *) return 0 ;; esac
  while [ "$n" -le 40 ]; do
    if [ "$(physical_path "$p")" = "$want" ]; then
      if [ -e "$p" ]; then printf '%s\n' "$want"; fi
      return 0
    fi
    [ -L "$p" ] || return 0
    t="$(readlink "$p")"
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    n=$((n + 1))
  done
}

# check_provides <old provides> <old adopted>: a command the plugin provides must not exist yet (or
# its " *" rule would grant a system command, provides=rm) unless the installed version already
# provided it or it is adopted: installed at its adopt= path. Sets ADOPTED=1 when install is not to
# run: every provided command is adopted, on a first install or when the installed version was
# adopted too (one this arness installed keeps being updated by it). Adopting only some of them is
# refused there: install would run over the shared ones and a later remove would uninstall them.
check_provides() {
  local old="$1" old_adopted="$2" c n=0 a=0 first_a="" first_not=""
  for c in $M_PROVIDES; do
    n=$((n + 1))
    if [ -n "$(adopted_path "$c")" ]; then
      a=$((a + 1))
      if [ -z "$first_a" ]; then first_a="$c"; fi
      continue
    fi
    if [ -z "$first_not" ]; then first_not="$c"; fi
    case " $old " in *" $c "*) continue ;; esac
    if command -v "$c" >/dev/null 2>&1; then fail "$EXIT_INVALID" "BAD_MANIFEST provides: $c already exists on this machine"; fi
  done
  if [ "$old_adopted" = 1 ] && [ -n "$first_a" ] && [ -n "$first_not" ]; then
    fail "$EXIT_INVALID" "BAD_MANIFEST adopt: $first_a is adopted but $first_not is not installed"
  fi
  ADOPTED=0
  if [ "$n" -gt 0 ] && [ "$a" -eq "$n" ] && [ "$old_adopted" = 1 ]; then ADOPTED=1; fi
}

# Warn in the plan when an existing opencode.json (copied once, never updated) lacks the rule that
# makes OpenCode ask before apply.
check_opencode_gate() {
  local f="$ROOT/opencode.json"
  if [ -f "$f" ] && ! grep -qF "$OPENCODE_APPLY_RULE" "$f"; then echo "OPENCODE_UNGATED opencode.json"; fi
}

# claude_rules [skills]: Claude Code rules arness grants for the plugin: Skill(<s>) for each skill (by
# default every declared one, as the plan shows them; apply passes the selection), then its allow.claude
# rules.
claude_rules() {
  local n
  for n in ${1-$M_SKILLS}; do printf 'Skill(%s)\n' "$n"; done
  printf '%s' "$M_ALLOW_CLAUDE"
}

print_rules() {
  local status="$1" provider="$2" rules="$3" rule
  while IFS= read -r rule; do
    if [ -n "$rule" ]; then echo "$status $provider $rule"; fi
  done <<< "$rules"
}

# print_plan <commit> <url> <ref> <kind> <dir> <update 0|1>: everything the user consents to. The rules
# and scripts are those of every declared skill: apply grants those of the selection only.
print_plan() {
  local n f
  echo "PLUGIN $M_NAME $M_VERSION $1"
  echo "SOURCE ${2:--} $3 $4"
  echo "DESCRIPTION $M_DESC"
  if [ -n "$M_REQUIRES" ]; then echo "REQUIRES $M_REQUIRES"; fi
  if [ -n "$M_PROVIDES" ]; then echo "PROVIDES $M_PROVIDES"; fi
  print_items skills "$M_NAME" "$6"
  print_items agents "$M_NAME" "$6"
  print_rules ALLOW claude "$(claude_rules)"
  print_rules ALLOW opencode "$M_ALLOW_OPENCODE"
  for n in $M_SKILLS; do
    for f in "$5/skills/$n/scripts/"*.sh; do
      if [ -f "$f" ]; then echo "OPENCODE_AUTO_ALLOW skills/$n/scripts/$(basename "$f")"; fi
    done
  done
  if [ "$ADOPTED" = 1 ]; then
    for n in $M_PROVIDES; do echo "ADOPT $n $(adopted_path "$n")"; done
    if [ -n "$M_INSTALL" ]; then echo "INSTALL_SKIPPED $M_INSTALL"; fi
    if [ -n "$M_UNINSTALL" ]; then echo "UNINSTALL_SKIPPED $M_UNINSTALL"; fi
  else
    if [ -n "$M_INSTALL" ]; then echo "INSTALL $M_INSTALL"; fi
    if [ -n "$M_UNINSTALL" ]; then echo "UNINSTALL $M_UNINSTALL"; fi
  fi
  printf '%s' "$M_HOOKS" | awk 'NF { i = index($0, "="); print "HOOK " substr($0, 1, i - 1) " " substr($0, i + 1) }'
  check_opencode_gate
  print_dropped
}

print_manual() {
  local n
  print_rules "MANUAL opencode" bash "$M_ALLOW_OPENCODE"
  for n in $SEL_SKILLS; do echo "MANUAL opencode skill $n"; done
}

# --- state: what apply validated, the only source render, sync, list and remove trust ------------

state_file() { printf '%s/.%s.state\n' "$PLUGINS" "$1"; }

# write_state <name> <commit> <ref> <kind> <status>, from the validated M_* globals and the selection
# (SEL_*, SKIP_*, STATE_REPLACED).
write_state() {
  local file tmp
  file="$(state_file "$1")"
  tmp="$file.tmp"
  {
    printf 'commit=%s\nref=%s\nkind=%s\nstatus=%s\nadopted=%s\n' "$2" "$3" "$4" "$5" "$ADOPTED"
    printf 'version=%s\nskills=%s\nagents=%s\nprovides=%s\nuninstall=%s\n' "$M_VERSION" "$SEL_SKILLS" "$SEL_AGENTS" "$M_PROVIDES" "$M_UNINSTALL"
    printf 'skipped.skills=%s\nskipped.agents=%s\n' "$SKIP_SKILLS" "$SKIP_AGENTS"
    printf '%s' "$STATE_REPLACED" | awk 'NF { print "replaced=" $0 }'
    claude_rules "$SEL_SKILLS" | awk 'NF { print "allow.claude=" $0 }'
    printf '%s' "$M_ALLOW_OPENCODE" | awk 'NF { print "allow.opencode=" $0 }'
    printf '%s' "$M_HOOKS" | awk 'NF { print "hook." $0 }'
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

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# --- selection: which declared skills and agents apply links ------------------------------------

# item_rel <skills|agents> <n>: the item's path under the arness root.
item_rel() { if [ "$1" = skills ]; then printf 'skills/%s\n' "$2"; else printf 'agents/%s.md\n' "$2"; fi; }

# item_kind_name <path>: "<skills|agents> <n>" of an item path (item_rel reversed).
item_kind_name() {
  local n
  case "$1" in
    skills/*) printf 'skills %s\n' "${1#skills/}" ;;
    agents/*.md) n="${1#agents/}"; printf 'agents %s\n' "${n%.md}" ;;
  esac
}

# link_owner <path>: the plugin a link points into (../plugins/<p>/... or the absolute form a Windows
# junction reports); empty for anything else.
link_owner() {
  local t p
  [ -L "$1" ] || return 0
  t="$(readlink "$1")"
  case "$t" in
    "../plugins/"*/*) p="${t#../plugins/}" ;;
    "$ROOT/plugins/"*/*) p="${t#"$ROOT"/plugins/}" ;;
    *) return 0 ;;
  esac
  p="${p%%/*}"
  if is_slug "$p"; then printf '%s\n' "$p"; fi
}

# conflict_kind <skills|agents> <n> <plugin>: empty when the item's path is free or is this plugin's
# link; else what takes it: tracked (a skill or agent of this repo, never replaced), plugin:<other> (the
# link of another installed plugin), dangling (any other broken link) or local (anything else: a private
# skill, a link elsewhere).
conflict_kind() {
  local rel p other
  rel="$(item_rel "$1" "$2")"
  p="$ROOT/$rel"
  taken "$p" || return 0
  if belongs_to "$p" "$3"; then return 0; fi
  if [ -n "$(git -C "$ROOT" ls-files -- "$rel" 2>/dev/null)" ]; then echo tracked; return 0; fi
  other="$(link_owner "$p")"
  if [ -n "$other" ] && [ -f "$(state_file "$other")" ]; then echo "plugin:$other"; return 0; fi
  if [ -L "$p" ] && [ ! -e "$p" ]; then echo dangling; return 0; fi
  echo local
}

# classify_items <skills|agents> <plugin> <update 0|1>: one line "<n> <status> <conflict|->" per
# declared item, status conflict (its path is taken), skipped (left out by the installed version), new
# (not in the installed version) or ok.
classify_items() {
  local kind="$1" name="$2" update="$3" list n c old_sel="" old_skip=""
  if [ "$kind" = skills ]; then list="$M_SKILLS"; else list="$M_AGENTS"; fi
  if [ "$update" = 1 ]; then
    old_sel="$(state_value "$name" "$kind")"
    old_skip="$(state_value "$name" "skipped.$kind")"
  fi
  for n in $list; do
    c="$(conflict_kind "$kind" "$n" "$name")"
    if [ -n "$c" ]; then echo "$n conflict $c"
    elif [ "$update" = 1 ] && in_list "$n" "$old_skip"; then echo "$n skipped -"
    elif [ "$update" = 1 ] && ! in_list "$n" "$old_sel"; then echo "$n new -"
    else echo "$n ok -"
    fi
  done
}

# default_selection <classify_items output>: what apply links without --skills / --agents: neither a
# conflict nor what was left out before.
default_selection() { printf '%s\n' "$1" | awk '$2 == "ok" || $2 == "new" { printf "%s%s", sep, $1; sep = " " }'; }

csv() { if [ -n "$1" ]; then printf '%s\n' "${1// /,}"; else echo "-"; fi; }

# print_items <skills|agents> <plugin> <update 0|1>: the plan lines of each declared item, then SELECT.
print_items() {
  local kind="$1" word lines n st c
  if [ "$kind" = skills ]; then word=SKILL; else word=AGENT; fi
  lines="$(classify_items "$kind" "$2" "$3")"
  while read -r n st c; do
    case "$st" in
      ok)       echo "$word $n" ;;
      new)      echo "NEW_$word $n" ;;
      skipped)  echo "SKIPPED_$word $n" ;;
      conflict) echo "CONFLICT $(item_rel "$kind" "$n") $c" ;;
    esac
  done <<< "$lines"
  echo "SELECT $kind $(csv "$(default_selection "$lines")")"
}

# resolve_selection <plugin> <update 0|1>: what apply links, from --skills / --agents or the plan's
# defaults, checked against what takes each path now. Sets SEL_SKILLS and SEL_AGENTS (in declared
# order), SKIP_SKILLS and SKIP_AGENTS (the rest) and REPLACE ("<path> <conflict>" lines). Writes nothing.
resolve_selection() {
  local name="$1" update="$2" kind list given lines sel skip n c rel r
  REPLACE=""
  for kind in skills agents; do
    if [ "$kind" = skills ]; then list="$M_SKILLS" given="$ARG_SKILLS"; else list="$M_AGENTS" given="$ARG_AGENTS"; fi
    lines="$(classify_items "$kind" "$name" "$update")"
    if [ "$given" = "@default" ]; then given="$(default_selection "$lines")"; fi
    for n in $given; do in_list "$n" "$list" || die "--$kind: $n is not one of the plugin's $kind (${list:-none})"; done
    sel="" skip=""
    for n in $list; do
      if ! in_list "$n" "$given"; then skip="${skip:+$skip }$n"; continue; fi
      sel="${sel:+$sel }$n"
      c="$(printf '%s\n' "$lines" | awk -v n="$n" '$1 == n && $2 == "conflict" { print $3; exit }')"
      [ -n "$c" ] || continue
      rel="$(item_rel "$kind" "$n")"
      in_list "$rel" "$ARG_REPLACE" || fail "$EXIT_CONFLICT" "NAME_CONFLICT $rel"
      [ "$c" != tracked ] || fail "$EXIT_CONFLICT" "NOT_REPLACEABLE $rel tracked"
      if [ "$c" = local ] && taken "$PLUGINS/.replaced/$name/$rel"; then
        fail "$EXIT_CONFLICT" "BACKUP_EXISTS $PLUGINS/.replaced/$name/$rel"
      fi
      REPLACE="$REPLACE$rel $c"$'\n'
    done
    if [ "$kind" = skills ]; then SEL_SKILLS="$sel" SKIP_SKILLS="$skip"; else SEL_AGENTS="$sel" SKIP_AGENTS="$skip"; fi
  done
  for r in $ARG_REPLACE; do
    # shellcheck disable=SC2046
    set -- $(item_kind_name "$r")
    if [ "$1" = skills ]; then sel="$SEL_SKILLS"; else sel="$SEL_AGENTS"; fi
    in_list "$2" "$sel" || die "--replace $r: not a selected skill or agent"
  done
}

# state_move <plugin> <skills|agents> <n> <out|in>: take n out of an installed plugin's selection (into
# its skipped.<kind>, without its Skill rule) or put it back.
state_move() {
  local file tmp
  file="$(state_file "$1")"
  tmp="$file.tmp"
  K="$2" N="$3" D="$4" awk '
    function drop(list, n,   a, i, k, out) {
      k = split(list, a, " "); out = ""
      for (i = 1; i <= k; i++) if (a[i] != n) out = out (out == "" ? "" : " ") a[i]
      return out
    }
    function add(list, n,   l) { l = drop(list, n); return l (l == "" ? "" : " ") n }
    BEGIN { K = ENVIRON["K"]; N = ENVIRON["N"]; D = ENVIRON["D"]; rule = "allow.claude=Skill(" N ")" }
    index($0, K "=") == 1 { v = substr($0, length(K) + 2); print K "=" (D == "out" ? drop(v, N) : add(v, N)); next }
    index($0, "skipped." K "=") == 1 {
      seen = 1; v = substr($0, length(K) + 10)
      print "skipped." K "=" (D == "out" ? add(v, N) : drop(v, N)); next
    }
    K == "skills" && $0 == rule { next }
    { print }
    END {
      if (!seen && D == "out") print "skipped." K "=" N
      if (D == "in" && K == "skills") print rule
    }' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# record_replacements: add to STATE_REPLACED what REPLACE will move away and remove puts back (a dangling
# link is just removed). apply writes the state with it before do_replacements moves anything, so an
# apply stopped half-way still knows what to put back.
record_replacements() {
  local rel c
  while read -r rel c; do
    case "$c" in local|plugin:*) STATE_REPLACED="$STATE_REPLACED$rel $c"$'\n' ;; esac
  done <<< "$REPLACE"
}

# do_replacements <plugin>: move away what takes the paths of REPLACE, so the plugin links there.
do_replacements() {
  local name="$1" rel c b
  while read -r rel c; do
    [ -n "$rel" ] || continue
    case "$c" in
      dangling) rm "$ROOT/$rel" ;;
      local)
        b="$PLUGINS/.replaced/$name/$rel"
        mkdir -p "$(dirname "$b")"
        mv "$ROOT/$rel" "$b" ;;
      plugin:*)
        # shellcheck disable=SC2046
        state_move "${c#plugin:}" $(item_kind_name "$rel") out
        rm "$ROOT/$rel" ;;
    esac
  done <<< "$REPLACE"
}

# restore_replaced <plugin>: put back what the plugin replaced and does not link any more (SEL_SKILLS and
# SEL_AGENTS; empty on remove), after its links are gone. Sets STATE_REPLACED to the entries still in
# force: the selected ones, and those that could not be put back, so a later update or remove tries
# again. Never overwrites: a path taken since keeps its backup (RESTORE_SKIPPED, with where it is).
restore_replaced() {
  local name="$1" line rel c kind n src
  STATE_REPLACED=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rel="${line%% *}" c="${line#* }"
    # shellcheck disable=SC2046
    set -- $(item_kind_name "$rel") "" ""
    kind="$1" n="$2"
    if [ -z "$n" ] || ! is_slug "$n"; then echo "RESTORE_SKIPPED $rel missing invalid"; continue; fi
    if { [ "$kind" = skills ] && in_list "$n" "$SEL_SKILLS"; } || { [ "$kind" = agents ] && in_list "$n" "$SEL_AGENTS"; }; then
      STATE_REPLACED="$STATE_REPLACED$line"$'\n'
      continue
    fi
    if taken "$ROOT/$rel"; then
      if [ "$c" = local ]; then echo "RESTORE_SKIPPED $rel taken $PLUGINS/.replaced/$name/$rel"; else echo "RESTORE_SKIPPED $rel taken $c"; fi
      STATE_REPLACED="$STATE_REPLACED$line"$'\n'
      continue
    fi
    case "$c" in
      local)
        if ! taken "$PLUGINS/.replaced/$name/$rel"; then
          echo "RESTORE_SKIPPED $rel missing $PLUGINS/.replaced/$name/$rel"
          prune_backup_parents "$name" "$rel"
          continue
        fi
        mkdir -p "$ROOT/$kind"
        mv "$PLUGINS/.replaced/$name/$rel" "$ROOT/$rel"
        prune_backup_parents "$name" "$rel" ;;
      plugin:*)
        if [ "$kind" = skills ]; then src="../plugins/${c#plugin:}/skills/$n"; else src="../plugins/${c#plugin:}/agents/$n.md"; fi
        # Only what that plugin's state lists as left out: a version that no longer declares it was
        # validated without it, so it gets neither the link nor the Skill rule back.
        if [ ! -f "$(state_file "${c#plugin:}")" ] || [ ! -e "$ROOT/$kind/$src" ] \
          || ! in_list "$n" "$(state_value "${c#plugin:}" "skipped.$kind")"; then
          echo "RESTORE_SKIPPED $rel missing $c"; continue
        fi
        state_move "${c#plugin:}" "$kind" "$n" in
        make_link "$src" "$ROOT/$rel" ;;
      *) continue ;;
    esac
    echo "RESTORED $rel"
  done <<< "$(conf_value "$(state_file "$name")" replaced)"
}

# prune_backup_parents <plugin> <path>: after a backup moved back, remove the folders it leaves empty on
# its way up to plugins/.replaced, and stop at the first one that is not empty. Never walks into a
# backup: an empty folder inside one (a .git/refs/tags) is its content.
prune_backup_parents() {
  local d
  d="$(dirname "$PLUGINS/.replaced/$1/$2")"
  while [ "$d" != "$PLUGINS" ]; do
    rmdir "$d" 2>/dev/null || return 0
    d="$(dirname "$d")"
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

# settings_lines: each line of a settings file trimmed and without its trailing comma; blank ones dropped.
settings_lines() { awk '{ sub(/^[ \t]+/, ""); sub(/[ \t]*,?[ \t]*$/, ""); if ($0 != "") print }'; }

# Lines of the Claude Code settings added by hand to the generated file, which every apply loses when
# it renders it again (the .bak that keeps them is replaced by the next render): a diff against what
# the template and the installed plugins' rules render today, so position counts and a template rule
# moved into another block (e.g. a hand-made "ask": [ ... ]) is listed with it. Compared trimmed and
# without a trailing comma, so indentation and the last item of a list do not count. Prints one
# DROPPED_SETTING line each; what belongs to the user goes in .claude/settings.local.json, which is
# never rendered. Lines removed by hand are not listed: the render brings them back.
print_dropped() {
  local dest="$ROOT/.claude/settings.json"
  [ -f "$dest" ] || return 0
  # diff exits 1 when the files differ: that is the case to report, not an error.
  { diff <(render_text providers/claude/settings.json "$(plugin_allow_claude)" | settings_lines) \
      <(settings_lines < "$dest") || true; } | sed -n 's/^> /DROPPED_SETTING /p'
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

# run_install <name> <dir>: run install unless every provided command is adopted, then check that
# each provided command is on the PATH.
run_install() {
  local name="$1" dir="$2" c
  if [ "$ADOPTED" != 1 ] && [ -n "$M_INSTALL" ] && ! run_cmd "$dir" "$M_INSTALL"; then
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

# git_lf <args>: git for the commands that write a plugin's files (checkout, checkout-index), with LF
# line endings whatever the user's core.autocrlf and core.eol. Otherwise Git for Windows (core.eol native)
# or core.autocrlf=true writes CRLF: the manifest is refused (BAD_MANIFEST ... CRLF line ending) and the
# plugin's scripts do not run. core.eol alone is not enough: core.autocrlf=true overrides it. The plugin's
# own eol attributes still apply.
git_lf() { git -c core.autocrlf=false -c core.eol=lf "$@"; }

# export_tree <dir> <commit> <out>: the commit's files as checkout writes them (a private index;
# unlike git archive, export-ignore and export-subst do not apply), without touching the clone.
export_tree() {
  mkdir -p "$3"
  GIT_INDEX_FILE="$TMP_DIR/index" git -C "$1" read-tree "$2"
  GIT_INDEX_FILE="$TMP_DIR/index" git_lf -C "$1" --work-tree="$3" checkout-index -a -f
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
  git_lf -C "$ADD_DIR" checkout --quiet --detach "$ADD_COMMIT" >&2
  validate_plugin "$ADD_DIR"
  if [ -n "${ARG_CATALOG:-}" ] && [ "$M_NAME" != "$ARG_CATALOG" ]; then
    fail "$EXIT_INVALID" "CATALOG_MISMATCH $ARG_CATALOG $M_NAME"
  fi
  check_requirements
  if [ -e "$PLUGINS/$M_NAME" ] || [ -L "$PLUGINS/$M_NAME" ]; then fail "$EXIT_EXISTS" "ALREADY_INSTALLED $M_NAME"; fi
  check_provides "" 1
}

# --- catalog: PLUGINS.md -------------------------------------------------------------

CATALOG_FILE=PLUGINS.md
CATALOG_HEADER='| Name | URL | Ref | Description |'
US=$'\037'   # field separator of catalog rows: never in a valid cell, and not IFS whitespace

# catalog_rows: one line per row of the table under the header, fields separated by $US: line number,
# name, url, ref, description. A bad row prints BAD_CATALOG and exits 4. Nothing without the file or the
# table; the table ends at the first line that does not start with |. A trailing CR is dropped first: a
# Windows checkout (core.autocrlf) has the same table.
catalog_rows() {
  local file="$ROOT/$CATALOG_FILE" n row name url ref desc seen=" " cells
  [ -f "$file" ] || return 0
  while IFS= read -r n && IFS= read -r row; do
    [ "$row" != SEPARATOR_MISSING ] || fail "$EXIT_INVALID" "BAD_CATALOG line $n: the header is not followed by |---|"
    case "$row" in *"$US"*|*$'\t'*) fail "$EXIT_INVALID" "BAD_CATALOG line $n: control character" ;; esac
    cells="$(printf '%s' "$row" | tr -cd '|' | wc -c | tr -d ' ')"
    [ "$cells" -eq 5 ] || fail "$EXIT_INVALID" "BAD_CATALOG line $n: not 4 cells (Name | URL | Ref | Description)"
    IFS="$US" read -r name url ref desc <<< "$(printf '%s' "$row" | awk -F'|' -v us="$US" '{
      for (i = 2; i <= 5; i++) gsub(/^[ ]+|[ ]+$/, "", $i)
      printf "%s%s%s%s%s%s%s", $2, us, $3, us, $4, us, $5 }')"
    is_slug "$name" || fail "$EXIT_INVALID" "BAD_CATALOG line $n: invalid name '$name'"
    case "$seen" in *" $name "*) fail "$EXIT_INVALID" "BAD_CATALOG line $n: duplicate name $name" ;; esac
    seen="$seen$name "
    validate_url "$url" || fail "$EXIT_INVALID" "BAD_CATALOG line $n: invalid URL '$url'"
    validate_ref "$ref" || fail "$EXIT_INVALID" "BAD_CATALOG line $n: invalid ref '$ref'"
    [ -n "$desc" ] || fail "$EXIT_INVALID" "BAD_CATALOG line $n: empty description"
    case "$desc" in *[[:cntrl:]]*) fail "$EXIT_INVALID" "BAD_CATALOG line $n: control character" ;; esac
    printf '%s\n' "$n$US$name$US$url$US$ref$US$desc"
  done < <(awk -v h="$CATALOG_HEADER" '
    { sub(/\r$/, "") }
    !table { if ($0 == h) { table = 1; sep = 1 }; next }
    sep { sep = 0; if ($0 !~ /^\|[-: |]+\|$/) { print NR; print "SEPARATOR_MISSING"; exit }; next }
    /^\|/ { print NR; print; next }
    { exit }' "$file")
}

# load_catalog: CATALOG_ROWS from catalog_rows, or its BAD_CATALOG line and exit code.
load_catalog() {
  local rc=0
  CATALOG_ROWS="$(catalog_rows)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$CATALOG_ROWS" | tail -n 1
    exit "$rc"
  fi
}

cmd_catalog() {
  [ $# -eq 0 ] || die "catalog takes no arguments"
  load_catalog
  if [ -z "$CATALOG_ROWS" ]; then echo "NONE"; return 0; fi
  printf '%s\n' "$CATALOG_ROWS" | awk -F"$US" '{ print "OFFICIAL " $2 " " $3 " " $4 " " $5 }'
}

# catalog_entry <name>: CAT_URL and CAT_REF of that official plugin, or NOT_IN_CATALOG.
catalog_entry() {
  local line
  load_catalog
  line="$(awk -F"$US" -v n="$1" '$2 == n && !found { print; found = 1 }' <<< "$CATALOG_ROWS")"
  [ -n "$line" ] || fail "$EXIT_NOT_IN_CATALOG" "NOT_IN_CATALOG $1"
  CAT_URL="$(printf '%s' "$line" | awk -F"$US" '{ print $3 }')"
  CAT_REF="$(printf '%s' "$line" | awk -F"$US" '{ print $4 }')"
}

# parse_list <option> <value>: PARSED = the comma-separated items of the value, space-separated ("-": none).
parse_list() {
  local item
  PARSED=""
  [ "$2" != "-" ] || return 0
  case "$2" in ""|,*|*,|*,,*|*[[:space:]]*) die "$1 needs items separated by commas, or -: $2" ;; esac
  for item in ${2//,/ }; do
    case "$1" in
      --replace)
        case "$item" in skills/*|agents/*.md) ;; *) die "--replace takes skills/<name> or agents/<name>.md: $item" ;; esac
        is_slug "$(item_kind_name "$item" | awk '{ print $2 }')" || die "--replace: invalid path $item" ;;
      *) is_slug "$item" || die "$1: invalid name $item" ;;
    esac
    PARSED="${PARSED:+$PARSED }$item"
  done
}

# parse_selection <option> <value>: one of --skills, --agents, --replace (apply only).
parse_selection() {
  parse_list "$1" "$2"
  case "$1" in
    --skills)  ARG_SKILLS="$PARSED" ;;
    --agents)  ARG_AGENTS="$PARSED" ;;
    --replace) ARG_REPLACE="$PARSED" ;;
  esac
  ARG_SEL=1
}

# parse_add_args <plan|apply> <args>...: a bare name (plan only) is an official plugin of PLUGINS.md.
parse_add_args() {
  local mode="$1"
  shift
  ARG_URL="" ARG_REF="" ARG_COMMIT="" ARG_ADOPTED="" ARG_CATALOG=""
  ARG_SKILLS="@default" ARG_AGENTS="@default" ARG_REPLACE="" ARG_SEL=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref)    [ $# -ge 2 ] || die "--ref needs a value"; ARG_REF="$2"; shift 2 ;;
      --skills|--agents|--replace) [ $# -ge 2 ] || die "$1 needs a value"; parse_selection "$1" "$2"; shift 2 ;;
      --commit) [ $# -ge 2 ] || die "--commit needs a value"; ARG_COMMIT="$2"; shift 2 ;;
      --adopted) [ $# -ge 2 ] || die "--adopted needs a value"; ARG_ADOPTED="$2"; shift 2 ;;
      -*)       die "unknown option: $1" ;;
      *)        [ -z "$ARG_URL" ] || die "only one URL allowed"; ARG_URL="$1"; shift ;;
    esac
  done
  [ -n "$ARG_URL" ] || die "missing plugin URL or name"
  # A bare name is an official plugin: its URL, and its ref unless --ref is given, come from PLUGINS.md.
  if is_slug "$ARG_URL"; then
    # apply re-reads nothing: a catalog row changed after the plan must not change what installs.
    [ "$mode" = plan ] || die "apply add takes the URL and --ref of the plan's SOURCE line, not a name: $ARG_URL"
    ARG_CATALOG="$ARG_URL"
    catalog_entry "$ARG_CATALOG"
    ARG_URL="$CAT_URL"
    if [ -z "$ARG_REF" ]; then ARG_REF="$CAT_REF"; fi
  fi
  validate_url "$ARG_URL" || die "invalid URL (allowed: https://, ssh://, git@host:path, file://): $ARG_URL"
  if [ -n "$ARG_REF" ]; then validate_ref "$ARG_REF" || die "invalid --ref: $ARG_REF"; fi
  if [ -n "$ARG_COMMIT" ]; then validate_commit "$ARG_COMMIT" || die "invalid --commit: $ARG_COMMIT"; fi
  case "$ARG_ADOPTED" in ""|0|1) ;; *) die "invalid --adopted (0 or 1): $ARG_ADOPTED" ;; esac
}

cmd_add() {
  parse_add_args plan "$@"
  [ -z "$ARG_COMMIT$ARG_ADOPTED$ARG_SEL" ] || die "--commit, --adopted, --skills, --agents and --replace belong to 'apply add'"
  prepare_add "$ARG_URL" "$ARG_REF"
  if [ -n "$ARG_CATALOG" ]; then echo "CATALOG $ARG_CATALOG"; fi
  print_plan "$ADD_COMMIT" "$ARG_URL" "$ADD_REF" "$ADD_KIND" "$ADD_DIR" 0
  fail "$EXIT_CONFIRM" "CONFIRM_ADD $M_NAME $ADD_COMMIT $ADOPTED"
}

apply_add() {
  parse_add_args apply "$@"
  validate_full_commit "$ARG_COMMIT" || die "apply add needs --commit <full 40-character sha> from the plan (CONFIRM_ADD)"
  [ -n "$ARG_ADOPTED" ] || die "apply add needs --adopted 0|1 from the plan (CONFIRM_ADD)"
  prepare_add "$ARG_URL" "$ARG_REF"
  [ "$ARG_COMMIT" = "$ADD_COMMIT" ] || fail "$EXIT_MISMATCH" "MISMATCH $ARG_COMMIT $ADD_COMMIT"
  # What runs is what the plan showed: install skipped (ADOPT) or not.
  [ "$ARG_ADOPTED" = "$ADOPTED" ] || fail "$EXIT_MISMATCH" "ADOPTION_CHANGED $ARG_ADOPTED $ADOPTED"
  resolve_selection "$M_NAME" 0
  local dest="$PLUGINS/$M_NAME"
  mv "$ADD_DIR" "$dest"
  STATE_REPLACED=""
  record_replacements
  write_state "$M_NAME" "$ADD_COMMIT" "$ADD_REF" "$ADD_KIND" ok
  do_replacements "$M_NAME"
  link_plugin "$M_NAME" "$SEL_SKILLS" "$SEL_AGENTS"
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
  # Commands provided since the installed version must not exist yet, like on a first install. A state
  # written before adopt existed has no adopted line: install ran, so it is ours.
  check_provides "$(state_value "$name" provides)" "$(state_value "$name" adopted)"
}

parse_name_args() {
  ARG_NAME="" ARG_REF="" ARG_COMMIT="" ARG_ADOPTED="" ARG_FETCH=1 ARG_FORCE=0
  ARG_SKILLS="@default" ARG_AGENTS="@default" ARG_REPLACE="" ARG_SEL=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --skills|--agents|--replace) [ $# -ge 2 ] || die "$1 needs a value"; parse_selection "$1" "$2"; shift 2 ;;
      --ref)      [ $# -ge 2 ] || die "--ref needs a value"; ARG_REF="$2"; shift 2 ;;
      --commit)   [ $# -ge 2 ] || die "--commit needs a value"; ARG_COMMIT="$2"; shift 2 ;;
      --adopted)  [ $# -ge 2 ] || die "--adopted needs a value"; ARG_ADOPTED="$2"; shift 2 ;;
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
  case "$ARG_ADOPTED" in ""|0|1) ;; *) die "invalid --adopted (0 or 1): $ARG_ADOPTED" ;; esac
}

# print_update_restores <plugin>: for each replacement, RESTORE when the default selection leaves its
# item out (no longer declared, or taken), else RESTORE_IF_UNSELECTED: apply puts back whatever the
# selection it is given leaves out.
print_update_restores() {
  local name="$1" line rel kind n dsel
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rel="${line%% *}"
    # shellcheck disable=SC2046
    set -- $(item_kind_name "$rel") "" ""
    kind="$1" n="$2"
    [ -n "$n" ] || continue
    dsel="$(default_selection "$(classify_items "$kind" "$name" 1)")"
    if in_list "$n" "$dsel"; then echo "RESTORE_IF_UNSELECTED $line"; else echo "RESTORE $line"; fi
  done <<< "$(conf_value "$(state_file "$name")" replaced)"
}

cmd_update() {
  parse_name_args "$@"
  [ -z "$ARG_COMMIT$ARG_ADOPTED$ARG_SEL" ] || die "--commit, --adopted, --skills, --agents and --replace belong to 'apply update'"
  [ "$ARG_FORCE" -eq 0 ] || die "unknown option: --force"
  local name="$ARG_NAME" state rule
  prepare_update "$name" "$ARG_REF" "$ARG_FETCH"
  if [ "$UP_NOOP" -eq 1 ]; then return 0; fi
  state="$(state_file "$name")"
  print_plan "$UP_TARGET" "" "$UP_REF" "$UP_KIND" "$TMP_DIR/tree" 1
  # The Skill rule of a skill left out before is not new: it was offered and declined.
  local skipped s
  skipped="$(state_value "$name" skipped.skills)"
  while IFS= read -r rule; do
    case "$rule" in "Skill("*")") s="${rule#Skill(}"; if in_list "${s%)}" "$skipped"; then continue; fi ;; esac
    if [ -n "$rule" ] && ! conf_value "$state" allow.claude | grep -qxF -- "$rule"; then echo "NEW_ALLOW claude $rule"; fi
  done <<< "$(claude_rules)"
  while IFS= read -r rule; do
    if [ -n "$rule" ] && ! conf_value "$state" allow.opencode | grep -qxF -- "$rule"; then echo "NEW_ALLOW opencode $rule"; fi
  done <<< "$M_ALLOW_OPENCODE"
  print_update_restores "$name"
  fail "$EXIT_CONFIRM" "CONFIRM_UPDATE $name $UP_OLD $UP_TARGET $UP_REF $ADOPTED"
}

# No fetch: apply moves to what the plan fetched and showed, or reports MISMATCH.
apply_update() {
  parse_name_args "$@"
  validate_full_commit "$ARG_COMMIT" || die "apply update needs --commit <full 40-character sha> from the plan (CONFIRM_UPDATE)"
  [ -n "$ARG_ADOPTED" ] || die "apply update needs --adopted 0|1 from the plan (CONFIRM_UPDATE)"
  [ "$ARG_FORCE" -eq 0 ] || die "unknown option: --force"
  local name="$ARG_NAME"
  prepare_update "$name" "$ARG_REF" 0
  if [ "$UP_NOOP" -eq 1 ]; then return 0; fi
  [ "$ARG_COMMIT" = "$UP_TARGET" ] || fail "$EXIT_MISMATCH" "MISMATCH $ARG_COMMIT $UP_TARGET"
  [ "$ARG_ADOPTED" = "$ADOPTED" ] || fail "$EXIT_MISMATCH" "ADOPTION_CHANGED $ARG_ADOPTED $ADOPTED"
  resolve_selection "$name" 1
  # Detached: no local branch is created or reset, so nothing local can be lost.
  git_lf -C "$UP_DEST" checkout --quiet --detach "$UP_TARGET" >&2
  unlink_plugin "$name"
  restore_replaced "$name"
  record_replacements
  write_state "$name" "$UP_TARGET" "$UP_REF" "$UP_KIND" ok
  do_replacements "$name"
  link_plugin "$name" "$SEL_SKILLS" "$SEL_AGENTS"
  refresh_providers
  run_install "$name" "$UP_DEST"
  print_manual
  echo "UPDATED $name $UP_OLD $UP_TARGET"
}

# --- remove ----------------------------------------------------------------------------

cmd_remove() {
  parse_name_args "$@"
  [ -z "$ARG_REF$ARG_COMMIT$ARG_ADOPTED$ARG_SEL" ] && [ "$ARG_FORCE" -eq 0 ] || die "remove takes only a plugin name"
  local name="$ARG_NAME" n uninstall
  [ -d "$PLUGINS/$name" ] || fail "$EXIT_NOT_INSTALLED" "NOT_INSTALLED $name"
  echo "PLUGIN $name $(state_value "$name" version | sed 's/^$/-/') $(state_value "$name" commit | sed 's/^$/-/')"
  for n in $(state_value "$name" skills); do echo "SKILL $n"; done
  for n in $(state_value "$name" agents); do echo "AGENT $n"; done
  conf_value "$(state_file "$name")" replaced | awk 'NF { print "RESTORE " $0 }'
  uninstall="$(state_value "$name" uninstall)"
  if [ -n "$uninstall" ]; then
    if [ "$(state_value "$name" adopted)" = 1 ]; then echo "UNINSTALL_SKIPPED $uninstall"; else echo "UNINSTALL $uninstall"; fi
  fi
  print_dropped
  fail "$EXIT_CONFIRM" "CONFIRM_REMOVE $name"
}

apply_remove() {
  parse_name_args "$@"
  [ -z "$ARG_REF$ARG_COMMIT$ARG_ADOPTED$ARG_SEL" ] || die "apply remove takes only --force and a plugin name"
  local name="$ARG_NAME" dest="$PLUGINS/$ARG_NAME" why uninstall
  [ -d "$dest" ] || fail "$EXIT_NOT_INSTALLED" "NOT_INSTALLED $name"
  why="$(dirty_reason "$dest" "$(state_value "$name" commit)")"
  if [ -n "$why" ] && [ "$ARG_FORCE" -eq 0 ]; then fail "$EXIT_DIRTY" "DIRTY $dest $why"; fi
  # From the state, not the clone: a manifest changed since apply must not choose what runs here.
  # An adopted command was installed by someone else (this plugin in another arness): left in place.
  uninstall="$(state_value "$name" uninstall)"
  if [ -n "$uninstall" ] && [ "$(state_value "$name" adopted)" != 1 ]; then
    run_cmd "$dest" "$uninstall" || echo "warning: uninstall failed, removing anyway: $uninstall" >&2
  fi
  unlink_plugin "$name"
  SEL_SKILLS="" SEL_AGENTS=""
  restore_replaced "$name"
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

# run-hook <event> <args>...: run the hook.<event> of each installed plugin, from its state, in its folder,
# with <args> appended. Each stdout line of a hook goes out as HOOK <name> <line>; its stderr passes as it
# is. Every hook runs even after one fails; then exit 15.
cmd_run_hook() {
  [ $# -ge 1 ] || die "run-hook needs an event"
  local event="$1" state name dir cmd path args rc failed=0 out
  shift
  case "$HOOK_EVENTS" in *" $event "*) ;; *) die "unknown hook event: $event" ;; esac
  for state in "$PLUGINS"/.*.state; do
    [ -f "$state" ] || continue
    name="${state##*/.}"
    name="${name%.state}"
    cmd="$(conf_value "$state" "hook.$event" | awk 'NR == 1')"
    [ -n "$cmd" ] || continue
    dir="$PLUGINS/$name"
    path="${cmd%% *}"
    if [ ! -x "$dir/$path" ]; then echo "HOOK_FAILED $name missing"; failed=1; continue; fi
    if [ -n "$(dirty_reason "$dir" "$(state_value "$name" commit)")" ]; then
      echo "HOOK_FAILED $name modified"; failed=1; continue
    fi
    args="${cmd#"$path"}"
    rc=0
    # The arguments in the state are literal words (check_hook), so splitting them is safe.
    # shellcheck disable=SC2086
    out="$(cd "$dir" && "./$path" $args "$@")" || rc=$?
    if [ -n "$out" ]; then printf '%s\n' "$out" | awk -v n="$name" 'NF { print "HOOK " n " " $0 }'; fi
    if [ "$rc" -ne 0 ]; then echo "HOOK_FAILED $name $rc"; failed=1; fi
  done
  if [ "$failed" -eq 1 ]; then exit "$EXIT_HOOK"; fi
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
    run-hook) cmd_run_hook "$@" ;;
    catalog) cmd_catalog "$@" ;;
    *)      die "unknown command: $cmd (add, update, remove, apply, list, check, sync, run-hook, catalog)" ;;
  esac
}

# Run only when executed, so tests can source this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
