#!/usr/bin/env bash
# Shared helpers for setup scripts. Source it, do not execute it.

log()  { printf '  %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*" >&2; }

# is_windows: true under Git Bash, MSYS2 or Cygwin.
is_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  return 1
}

# On Windows, `pwd` gives /c/Users/..., which Windows programs (Claude Code reading the rendered
# settings) do not understand. C:/Users/... works for both them and the shell.
if is_windows; then
  ARNESS_ROOT="$(cygpath -m "$ARNESS_ROOT")"
  export ARNESS_ROOT
fi

# make_link <target> <dest>: create the link, <target> relative to the directory of <dest>.
# On Windows, symlinks need Developer Mode or admin, and without them Git Bash's `ln -s` silently
# copies. A directory gets a junction instead (no privileges needed, absolute target); anything
# else gets a native symlink, which fails loudly when not allowed.
make_link() {
  local target="$1" dest="$2" abs
  if is_windows && [ -d "$(dirname "$dest")/$target" ]; then
    abs="$(cd "$(dirname "$dest")/$target" && pwd)"
    # MSYS_NO_PATHCONV: otherwise Git Bash rewrites /c and /J as paths.
    MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$dest")" "$(cygpath -w "$abs")" >/dev/null
  else
    MSYS=winsymlinks:nativestrict ln -s "$target" "$dest"
  fi
}

# link <target> <link>
# <target> is relative to the link's directory (as `ln -s` expects).
# <link> is relative to ARNESS_ROOT. Idempotent; never overwrites user files.
link() {
  local target="$1" dest="$ARNESS_ROOT/$2"
  mkdir -p "$(dirname "$dest")"
  if [ -L "$dest" ]; then
    rm "$dest" && make_link "$target" "$dest"   # removes the link (or junction) only
  elif [ -e "$dest" ]; then
    if [ -f "$dest" ] && [ ! -s "$dest" ]; then
      rm "$dest" && make_link "$target" "$dest"   # empty placeholder file
    else
      warn "$2 exists and is not a symlink, skipping"
      return 0
    fi
  else
    make_link "$target" "$dest"
  fi
  log "$2 -> $target"
}

# copy_once <src> <dest>: copy src (relative to ARNESS_ROOT) unless dest has content.
copy_once() {
  local src="$ARNESS_ROOT/$1" dest="$ARNESS_ROOT/$2"
  if [ -s "$dest" ]; then
    log "$2 already present, kept"
  else
    cp "$src" "$dest" && log "$2 <- $1"
  fi
}

# conf_value <file> <key>: the values of <key> in a KEY=value file, one per line (none if missing).
conf_value() {
  [ -f "$1" ] || return 0
  K="$2" awk 'index($0, ENVIRON["K"] "=") == 1 { print substr($0, length(ENVIRON["K"]) + 2) }' "$1"
}

# plugin_allow_claude: Claude Code rules of the installed plugins, one per line. Read only from
# plugins/.<name>.state, which plugin-manage writes after validating the manifest, never from a clone's
# arness-plugin.conf (a `git pull` there must not grant anything). A rule that could break out of its
# JSON string (quote, backslash, control character) is dropped with a warning all the same.
plugin_allow_claude() {
  local state rule
  for state in "$ARNESS_ROOT"/plugins/.*.state; do
    [ -f "$state" ] || continue
    conf_value "$state" allow.claude | while IFS= read -r rule; do
      case "$rule" in
        *'"'*|*\\*|*[[:cntrl:]]*) warn "unsafe rule in ${state##*/} skipped: $rule" ;;
        *) printf '%s\n' "$rule" ;;
      esac
    done
  done
}

# render <src> <dest>: write src (relative to ARNESS_ROOT) to dest, replacing
# {{$ARNESS_ROOT}} with the absolute repo path, and a line holding {{$PLUGIN_ALLOW}}
# with one "<rule>", line per plugin rule at its indentation (no line when there are
# none). Regenerated on every run; when the content changes, the previous dest is saved
# as <dest>.bak, replacing any older .bak (each plugin add, update or remove does it).
render() {
  local src="$ARNESS_ROOT/$1" dest="$ARNESS_ROOT/$2" tmp esc rules
  esc=$(printf '%s' "$ARNESS_ROOT" | sed -e 's/[\\&|]/\\&/g')
  rules="$(plugin_allow_claude)"
  tmp=$(mktemp)
  sed "s|{{\$ARNESS_ROOT}}|$esc|g" "$src" | RULES="$rules" awk -v mark='{{$PLUGIN_ALLOW}}' '
    index($0, mark) {
      ind = substr($0, 1, index($0, mark) - 1)
      n = split(ENVIRON["RULES"], r, "\n")
      for (i = 1; i <= n; i++) if (r[i] != "") print ind "\"" r[i] "\","
      next
    }
    { print }' > "$tmp"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && ! cmp -s "$tmp" "$dest"; then
    cp "$dest" "$dest.bak"
    warn "$2 changed, previous saved as $2.bak"
  fi
  mv "$tmp" "$dest"
  log "$2 <- $1 (rendered)"
}
