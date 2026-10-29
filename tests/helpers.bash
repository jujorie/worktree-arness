# Shared bats helpers. The tests in tests/ run against a throwaway copy of the repo; the skill tests
# (skills/<name>/tests) load this file too, for fake_cygpath. REPO_ROOT is the repo root for both.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# make_sandbox [dirname]: copy tracked-style sources into a temp dir, set ARNESS_ROOT.
make_sandbox() {
  local name="${1:-sandbox}"
  SANDBOX="$(mktemp -d)/$name"
  mkdir -p "$SANDBOX"
  cp -R "$REPO_ROOT/setup.sh" "$REPO_ROOT/scripts" "$REPO_ROOT/providers" "$SANDBOX/"
  mkdir -p "$SANDBOX/skills" "$SANDBOX/agents"
  : > "$SANDBOX/AGENTS.md"
  export ARNESS_ROOT="$SANDBOX"
}

cleanup_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$(dirname "$SANDBOX")"
}

# fake_os <uname> [windows-root]: put stubs first in PATH so the scripts take the Windows (Git Bash)
# path on any machine. `uname -s` prints <uname>; `cygpath -w` echoes its path; `cygpath -m` echoes
# <windows-root> in place of the sandbox (default: no change); `cmd /c mklink /J <link> <target>`
# makes a symlink instead of a junction. Every cygpath and cmd call is logged in $FAKE_CALLS.
fake_os() {
  local bin="$BATS_TEST_TMPDIR/fakebin"
  FAKE_CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$bin"
  : > "$FAKE_CALLS"
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$bin/uname"
  cat > "$bin/cygpath" <<EOF
#!/bin/sh
echo "cygpath \$*" >> "$FAKE_CALLS"
if [ "\$1" = -m ] && [ "\$2" = "$SANDBOX" ]; then echo "${2:-$SANDBOX}"; else echo "\$2"; fi
EOF
  cat > "$bin/cmd" <<EOF
#!/bin/sh
echo "cmd \$*" >> "$FAKE_CALLS"
ln -s "\$5" "\$4"
EOF
  chmod +x "$bin/uname" "$bin/cygpath" "$bin/cmd"
  export PATH="$bin:$PATH"
}

# fake_cygpath ok|fail: a cygpath first in PATH that logs each call to $CYGPATH_LOG. ok passes the call to
# the real cygpath (Git Bash) or prints the path as it is (Linux, macOS: no drive letters); fail exits 1.
fake_cygpath() {
  local real bin="$BATS_TEST_TMPDIR/cygbin"
  real="$(command -v cygpath || true)"
  CYGPATH_LOG="$BATS_TEST_TMPDIR/cygpath.log"
  mkdir -p "$bin"
  cat > "$bin/cygpath" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CYGPATH_LOG"
[ "$1" = ok ] || exit 1
if [ -n "$real" ]; then exec "$real" "\$@"; fi
printf '%s\n' "\${!#}"
EOF
  chmod +x "$bin/cygpath"
  export PATH="$bin:$PATH"
}

# Run a provider-less snippet with lib.sh loaded.
with_lib() {
  bash -c "set -euo pipefail; . '$SANDBOX/scripts/lib.sh'; $1"
}

# Cheap JSON sanity check without extra tools: object start/end and balanced {} and [].
# Enough to catch a rendered path that broke the structure; not a full parser.
json_looks_valid() {
  local f="$1" pair o c
  [ "$(head -c1 "$f")" = "{" ] || return 1
  [ "$(tail -c2 "$f" | tr -d '\n')" = "}" ] || return 1
  for pair in '{}' '[]'; do
    o=$(( $(tr -cd "${pair:0:1}" < "$f" | wc -c) ))
    c=$(( $(tr -cd "${pair:1:1}" < "$f" | wc -c) ))
    [ "$o" -eq "$c" ] || return 1
  done
}

# Skill folders shipped by the repo at root $1, one path per line, each ending in "/".
# In a git checkout that is what git would commit (tracked, or untracked but not ignored): skills/ is
# private by default, so local skills are git-ignored and no repo check applies to them.
# Outside a git checkout (test sandboxes) every folder counts.
shared_skill_dirs() {
  local root="$1" name
  if [ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" = "$(cd -P "$root" && pwd -P)" ]; then
    git -C "$root" ls-files -co --exclude-standard -- skills | cut -d/ -f2 | LC_ALL=C sort -u | while IFS= read -r name; do
      if [ -d "$root/skills/$name" ]; then printf '%s/skills/%s/\n' "$root" "$name"; fi
    done
  else
    local d
    for d in "$root"/skills/*/; do printf '%s\n' "$d"; done
  fi
}
