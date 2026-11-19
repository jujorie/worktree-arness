#!/usr/bin/env bats
# Unit tests for skills/repo-create/scripts/repo-create.sh.
# gh is a stub in PATH: GitHub is a folder of bare repos ($REMOTES/<owner>/<name>.git), owners are
# folders in $REMOTES, and every call is logged to $GH_LOG. No network.

SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/repo-create.sh"

write_gh_stub() {
  cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_LOG"
printf '%s\n' "${GH_HOST:-}" >> "$GH_LOG.host"
git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
not_found() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case "$1 ${2:-}" in
  "auth status") [ -z "${GH_AUTH_FAIL:-}" ] || exit 1 ;;
  "config get") echo "${GH_PROTOCOL:-}" ;;
  "api "*)
    if [ -n "${GH_NET_FAIL:-}" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
    case "$2" in
      users/*) [ -d "$REMOTES/${2#users/}" ] || not_found; echo "${2#users/}" ;;
      repos/*)
        # GH_REPO_LOOKUP_FAIL: 1 fails every repo lookup, after-create only those after `repo create`.
        case "${GH_REPO_LOOKUP_FAIL:-}" in
          1) echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1 ;;
          after-create) [ ! -e "$GH_LOG.create" ] || { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; } ;;
        esac
        r="$REMOTES/${2#repos/}.git"
        [ -d "$r" ] || not_found
        if [ -n "${GH_BAD_CLONE_URL:-}" ]; then r="$r-missing"; fi
        echo "file://$r file://${r%/*}/./${r##*/}" ;;
    esac ;;
  "repo create")
    : > "$GH_LOG.create"
    [ -z "${GH_CREATE_FAIL:-}" ] || { echo "GraphQL: permission denied" >&2; exit 1; }
    r="$REMOTES/$3.git"
    git_q init -q --bare "$r"
    case " $* " in
      *" --add-readme "*)
        w="$(mktemp -d)"
        git_q clone -q "$r" "$w/c" 2>/dev/null
        echo "# readme" > "$w/c/README.md"
        git_q -C "$w/c" add README.md
        git_q -C "$w/c" commit -q -m init
        git_q -C "$w/c" push -q origin HEAD:main
        rm -rf "$w" ;;
    esac
    [ -z "${GH_BREAK_AFTER_CREATE:-}" ] || rm -rf "$r"
    [ -z "${GH_FAIL_AFTER_CREATE:-}" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    echo "https://github.com/$3" ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$TMP/bin/gh"
}

setup() {
  TMP="$(mktemp -d)"
  export ARNESS_ROOT="$TMP/root" REMOTES="$TMP/remotes" GH_LOG="$TMP/gh.log"
  mkdir -p "$ARNESS_ROOT" "$REMOTES/my-org" "$TMP/bin"
  : > "$GH_LOG"
  write_gh_stub
  export PATH="$TMP/bin:$PATH"
  SRC="$ARNESS_ROOT/source"
}

teardown() { rm -rf "$TMP"; }

# --- plan ----------------------------------------------------------------

@test "plan prints the plan and CONFIRM_CREATE, and writes nothing" {
  run "$SCRIPT" plan --description "My service" my-org/my-repo
  [ "$status" -eq 20 ]
  [ "${lines[0]}" = "REPO my-org/my-repo" ]
  [ "${lines[1]}" = "VISIBILITY private" ]
  [ "${lines[2]}" = "DESCRIPTION My service" ]
  [ "${lines[3]}" = "README yes" ]
  [ "${lines[4]}" = "PROTOCOL https" ]
  [ "${lines[5]}" = "DEST $SRC/my-repo" ]
  [ "${lines[6]}" = "CONFIRM_CREATE my-org/my-repo" ]
  [ ! -e "$REMOTES/my-org/my-repo.git" ]
  [ ! -e "$SRC" ]
  ! grep -q '^repo create' "$GH_LOG" || false
}

@test "plan takes visibility, readme and protocol options" {
  run "$SCRIPT" plan --public --no-readme --protocol ssh my-org/my-repo
  [ "$status" -eq 20 ]
  [[ "$output" == *"VISIBILITY public"* ]] || false
  [[ "$output" == *"README no"* ]] || false
  [[ "$output" == *"PROTOCOL ssh"* ]] || false
}

@test "protocol defaults to gh's git_protocol" {
  GH_PROTOCOL=ssh run "$SCRIPT" plan my-org/my-repo
  [ "$status" -eq 20 ]
  [[ "$output" == *"PROTOCOL ssh"* ]] || false
}

@test "EXISTS when source/<name> already exists, before asking GitHub" {
  mkdir -p "$SRC/my-repo"
  run "$SCRIPT" plan my-org/my-repo
  [ "$status" -eq 10 ]
  [ "$output" = "EXISTS $SRC/my-repo" ]
  [ ! -s "$GH_LOG" ]
}

@test "REMOTE_EXISTS when the repo is already on GitHub" {
  git init -q --bare "$REMOTES/my-org/my-repo.git"
  run "$SCRIPT" plan --protocol ssh my-org/my-repo
  [ "$status" -eq 12 ]
  [ "$output" = "REMOTE_EXISTS my-org/my-repo file://$REMOTES/my-org/my-repo.git" ]
}

@test "NO_OWNER when the owner does not exist" {
  run "$SCRIPT" plan nobody/my-repo
  [ "$status" -eq 13 ]
  [ "$output" = "NO_OWNER nobody" ]
}

@test "NO_AUTH when gh is not logged in" {
  GH_AUTH_FAIL=1 run "$SCRIPT" plan my-org/my-repo
  [ "$status" -eq 4 ]
  [ "$output" = "NO_AUTH" ]
}

@test "plan stops with exit 3 when the repo lookup fails with an error other than 404" {
  GH_REPO_LOOKUP_FAIL=1 run "$SCRIPT" plan my-org/my-repo
  [ "$status" -eq 3 ]
  [[ "$output" == *"could not look up my-org/my-repo"* ]] || false
  [[ "$output" != *"REMOTE_EXISTS"* ]] || false
  [[ "$output" != *"CONFIRM_CREATE"* ]] || false
  ! grep -q '^repo create' "$GH_LOG" || false
}

@test "a network error is exit 3, not NO_OWNER" {
  GH_NET_FAIL=1 run "$SCRIPT" plan my-org/my-repo
  [ "$status" -eq 3 ]
  [[ "$output" != *"NO_OWNER"* ]] || false
}

# --- apply ---------------------------------------------------------------

@test "apply creates the repo with a README and clones it into source/" {
  run "$SCRIPT" apply --description "My service" my-org/my-repo
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "CREATED my-org/my-repo $SRC/my-repo" ]
  [ -f "$SRC/my-repo/README.md" ]
  grep -qx 'repo create my-org/my-repo --private --description My service --add-readme' "$GH_LOG" || false
}

@test "apply clones with the URL of the chosen protocol" {
  run "$SCRIPT" apply --protocol https my-org/my-repo
  [ "$status" -eq 0 ]
  [ "$(git -C "$SRC/my-repo" remote get-url origin)" = "file://$REMOTES/my-org/./my-repo.git" ]
  rm -rf "$SRC/my-repo"
  run "$SCRIPT" apply --protocol ssh my-org/other
  [ "$status" -eq 0 ]
  [ "$(git -C "$SRC/other" remote get-url origin)" = "file://$REMOTES/my-org/other.git" ]
}

@test "apply --no-readme --public creates an empty public repo" {
  run "$SCRIPT" apply --no-readme --public my-org/my-repo
  [ "$status" -eq 0 ]
  [ -d "$SRC/my-repo/.git" ]
  grep -qx 'repo create my-org/my-repo --public' "$GH_LOG" || false
}

@test "apply checks again and creates nothing when the repo appeared meanwhile" {
  git init -q --bare "$REMOTES/my-org/my-repo.git"
  run "$SCRIPT" apply my-org/my-repo
  [ "$status" -eq 12 ]
  ! grep -q '^repo create' "$GH_LOG" || false
}

@test "apply does not create the repo when source/<name> exists" {
  mkdir -p "$SRC/my-repo"
  run "$SCRIPT" apply my-org/my-repo
  [ "$status" -eq 10 ]
  [ ! -e "$REMOTES/my-org/my-repo.git" ]
}

@test "a failed gh repo create is exit 3 and clones nothing" {
  GH_CREATE_FAIL=1 run "$SCRIPT" apply my-org/my-repo
  [ "$status" -eq 3 ]
  [[ "$output" == *"gh repo create failed for my-org/my-repo; nothing was created"* ]] || false
  [ ! -e "$SRC/my-repo" ]
}

@test "a failed gh repo create whose repo cannot be looked up says to run plan, not that nothing was created" {
  GH_CREATE_FAIL=1 GH_REPO_LOOKUP_FAIL=after-create run "$SCRIPT" apply my-org/my-repo
  [ "$status" -eq 3 ]
  grep -q '^repo create' "$GH_LOG"
  [[ "$output" == *"run plan"* ]] || false
  [[ "$output" != *"nothing was created"* ]] || false
  [ ! -e "$SRC/my-repo" ]
}

@test "NOT_CLONED when the repo was created but the clone fails" {
  GH_BAD_CLONE_URL=1 run "$SCRIPT" apply --protocol ssh my-org/my-repo
  [ "$status" -eq 14 ]
  [ "${lines[${#lines[@]}-1]}" = "NOT_CLONED my-org/my-repo file://$REMOTES/my-org/my-repo.git-missing" ]
  [[ "$output" == *"git clone failed"* ]] || false
  [ -d "$REMOTES/my-org/my-repo.git" ]
  [ ! -e "$SRC/my-repo" ]
}

@test "NOT_CLONED with the URL of the chosen protocol when the repo cannot be looked up after creating it" {
  GH_BREAK_AFTER_CREATE=1 run "$SCRIPT" apply --protocol ssh my-org/my-repo
  [ "$status" -eq 14 ]
  [ "${lines[${#lines[@]}-1]}" = "NOT_CLONED my-org/my-repo git@github.com:my-org/my-repo.git" ]
  GH_BREAK_AFTER_CREATE=1 run "$SCRIPT" apply --protocol https my-org/other
  [ "${lines[${#lines[@]}-1]}" = "NOT_CLONED my-org/other https://github.com/my-org/other.git" ]
}

@test "a gh repo create that fails after creating the repo still clones it" {
  GH_FAIL_AFTER_CREATE=1 run "$SCRIPT" apply my-org/my-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: gh repo create failed, but my-org/my-repo exists"* ]] || false
  [ "${lines[${#lines[@]}-1]}" = "CREATED my-org/my-repo $SRC/my-repo" ]
  [ -f "$SRC/my-repo/README.md" ]
}

@test "every gh call goes to github.com, whatever gh's default host" {
  GH_HOST=ghe.example.com run "$SCRIPT" apply my-org/my-repo
  [ "$status" -eq 0 ]
  [ "$(sort -u "$GH_LOG.host")" = "github.com" ]
}

@test "apply stops at NO_AUTH and NO_OWNER without creating anything" {
  GH_AUTH_FAIL=1 run "$SCRIPT" apply my-org/my-repo
  [ "$status" -eq 4 ]
  run "$SCRIPT" apply nobody/my-repo
  [ "$status" -eq 13 ]
  ! grep -q '^repo create' "$GH_LOG" || false
}

@test "a symlink at source/<name> is refused" {
  mkdir -p "$SRC" "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$SRC/my-repo"
  run "$SCRIPT" apply my-org/my-repo
  [ "$status" -eq 2 ]
  [[ "$output" == *"symlink"* ]] || false
  ! grep -q '^repo create' "$GH_LOG" || false
}

# --- validation ----------------------------------------------------------

@test "missing or unknown command is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  run "$SCRIPT" create my-org/my-repo
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]] || false
}

@test "invalid repositories are rejected before calling gh" {
  for bad in "" "my-repo" "my-org/" "/my-repo" "a/b/c" "-org/x" "org-/x" "my--org/x" "my_org/x" \
             "my-org/.." "my-org/." "my-org/-x" "my-org/x.git" "my-org/a b" "my-org/a;b" "my-org/../x"; do
    run "$SCRIPT" plan "$bad"
    [ "$status" -eq 2 ] || { echo "accepted: '$bad' (status $status)"; return 1; }
  done
  [ ! -s "$GH_LOG" ]
}

@test "a description with control characters is rejected" {
  run "$SCRIPT" plan --description "$(printf 'a\nb')" my-org/my-repo
  [ "$status" -eq 2 ]
}

@test "--protocol only takes ssh or https" {
  run "$SCRIPT" plan --protocol git my-org/my-repo
  [ "$status" -eq 2 ]
}

@test "unknown options and a second repository are usage errors" {
  run "$SCRIPT" plan --template x my-org/my-repo
  [ "$status" -eq 2 ]
  run "$SCRIPT" plan my-org/a my-org/b
  [ "$status" -eq 2 ]
}

@test "-h prints the header" {
  run "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: repo-create.sh plan"* ]] || false
  [[ "$output" == *"--private"* ]] || false
  [[ "$output" != *"set -euo"* ]] || false
  run "$SCRIPT" plan -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exit codes:"* && "$output" != *"set -euo"* ]] || false
}
