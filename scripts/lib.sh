#!/usr/bin/env bash
# Shared helpers for setup scripts. Source it, do not execute it.

log()  { printf '  %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*" >&2; }

# link <target> <link>
# <target> is relative to the link's directory (as `ln -s` expects).
# <link> is relative to ARNESS_ROOT. Idempotent; never overwrites user files.
link() {
  local target="$1" dest="$ARNESS_ROOT/$2"
  mkdir -p "$(dirname "$dest")"
  if [ -L "$dest" ]; then
    ln -sfn "$target" "$dest"
  elif [ -e "$dest" ]; then
    if [ -f "$dest" ] && [ ! -s "$dest" ]; then
      rm "$dest" && ln -s "$target" "$dest"   # empty placeholder file
    else
      warn "$2 exists and is not a symlink, skipping"
      return 0
    fi
  else
    ln -s "$target" "$dest"
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

# render <src> <dest>: write src (relative to ARNESS_ROOT) to dest, replacing
# {{$ARNESS_ROOT}} with the absolute repo path. Regenerated on every run; an
# existing different dest is kept once as <dest>.bak.
render() {
  local src="$ARNESS_ROOT/$1" dest="$ARNESS_ROOT/$2" tmp esc
  esc=$(printf '%s' "$ARNESS_ROOT" | sed -e 's/[\\&|]/\\&/g')
  tmp=$(mktemp)
  sed "s|{{\$ARNESS_ROOT}}|$esc|g" "$src" > "$tmp"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && ! cmp -s "$tmp" "$dest"; then
    cp "$dest" "$dest.bak"
    warn "$2 changed, previous saved as $2.bak"
  fi
  mv "$tmp" "$dest"
  log "$2 <- $1 (rendered)"
}
