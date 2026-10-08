#!/usr/bin/env bats
# Unit tests for skills/worktree-clean/scripts/worktree-clean.sh.
# Each test runs against a throwaway ARNESS_ROOT with local repos in source/.

SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/worktree-clean.sh"

git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

mk_repo() {
  mkdir -p "$SRC/$1"
  git_q init -q "$SRC/$1"
  echo 1 > "$SRC/$1/f.txt"
  git_q -C "$SRC/$1" add f.txt
  git_q -C "$SRC/$1" commit -q -m c1
}

# mk_wt <repo> <name> [commit] : worktree on branch <name> from main, base recorded like worktree-create.
mk_wt() {
  git_q -C "$SRC/$1" worktree add -q -b "$2" "$ARNESS_ROOT/worktrees/$1/$2" main
  git_q -C "$SRC/$1" config "branch.$2.arness-base" main
  if [ "${3:-}" = commit ]; then
    echo "$2" > "$ARNESS_ROOT/worktrees/$1/$2/new.txt"
    git_q -C "$ARNESS_ROOT/worktrees/$1/$2" add new.txt
    git_q -C "$ARNESS_ROOT/worktrees/$1/$2" commit -q -m work
  fi
}

merge_wt() { git_q -C "$SRC/$1" merge -q --no-ff -m merge "$2"; }

# column <n> of the row whose name (col 2) is <name>
col() { printf '%s\n' "$output" | awk -F'\t' -v n="$1" -v c="$2" '$2 == n { print $c }'; }

# source/a is a clone of origin; worktree w is freshly made from origin/epic/X-1 (no commits of its own).
mk_remote_wt_nocommit() {
  ORIGIN="$TMP/origin"
  git_q init -q "$ORIGIN"
  echo 1 > "$ORIGIN/f.txt"; git_q -C "$ORIGIN" add f.txt; git_q -C "$ORIGIN" commit -q -m c1
  git_q -C "$ORIGIN" checkout -q -b epic/X-1
  git clone -q "$ORIGIN" "$SRC/a" 2>/dev/null
  git_q -C "$ORIGIN" checkout -q main
  git_q -C "$SRC/a" worktree add -q -b w "$ARNESS_ROOT/worktrees/a/w" origin/epic/X-1
  git_q -C "$SRC/a" config branch.w.arness-base origin/epic/X-1
}

setup() {
  TMP="$(mktemp -d)"
  TMP="$(cd -P "$TMP" && pwd -P)"   # the script prints physical paths; /var is a symlink on macOS
  export ARNESS_ROOT="$TMP/root"
  SRC="$ARNESS_ROOT/source"
  mkdir -p "$SRC"
  # Fake gh, so no test reaches GitHub: it prints $FAKE_GH_HEADS (one PR head per line) and logs each call.
  # Unset, it fails like an unauthenticated gh.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH_LOG"
[ -n "${FAKE_GH_HEADS:-}" ] || exit 1
printf '%s\n' "$FAKE_GH_HEADS"
EOF
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH" FAKE_GH_LOG="$TMP/gh.log"
  unset FAKE_GH_HEADS
}

teardown() { rm -rf "$TMP"; }

@test "NO_SOURCE when source/ has no repos" {
  run "$SCRIPT" list
  [ "$status" -eq 4 ]
  [ "$output" = "NO_SOURCE" ]
}

@test "list prints NONE when there are no worktrees" {
  mk_repo a
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
}

@test "list ignores worktrees outside worktrees/<repo>/" {
  mk_repo a
  git_q -C "$SRC/a" worktree add -q -b other "$TMP/elsewhere" main
  run "$SCRIPT" list
  [ "$output" = "NONE" ]
}

@test "list reports MERGED, NOT_MERGED and ahead count" {
  mk_repo a
  mk_wt a done commit
  mk_wt a open commit
  merge_wt a done
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ "$(col done 5)" = "MERGED" ]
  [ "$(col done 4)" = "main" ]
  [ "$(col open 5)" = "NOT_MERGED" ]
  [ "$(col open 6)" = "1" ]
}

@test "a worktree with no commits of its own is EMPTY, not MERGED" {
  mk_repo a
  mk_wt a fresh
  run "$SCRIPT" list
  [ "$(col fresh 5)" = "EMPTY" ]
  [ "$(col fresh 6)" = "0" ]
}

@test "a branch with work that was merged is MERGED, not EMPTY" {
  mk_repo a
  mk_wt a done commit
  merge_wt a done
  run "$SCRIPT" list
  [ "$(col done 5)" = "MERGED" ]
}

@test "a fast-forward merge of real work is MERGED (tip equals base but the branch had commits)" {
  mk_repo a
  mk_wt a ff commit
  git_q -C "$SRC/a" merge -q --ff-only ff
  run "$SCRIPT" list
  [ "$(col ff 5)" = "MERGED" ]
}

@test "EMPTY on a remote base: a fresh worktree of origin/<branch> is EMPTY" {
  mk_remote_wt_nocommit
  run "$SCRIPT" list
  [ "$(col w 5)" = "EMPTY" ]
}

@test "remove deletes an EMPTY worktree without --force (nothing to lose)" {
  mk_repo a
  mk_wt a fresh
  run "$SCRIPT" remove --source a fresh
  [ "$status" -eq 0 ]
  [ ! -e "$ARNESS_ROOT/worktrees/a/fresh" ]
}

@test "list reports DIRTY over MERGED" {
  mk_repo a
  mk_wt a w
  echo y > "$ARNESS_ROOT/worktrees/a/w/untracked.txt"
  run "$SCRIPT" list
  [ "$(col w 5)" = "DIRTY" ]
}

@test "list reports UNKNOWN_BASE without recorded base, --base is the fallback" {
  mk_repo a
  mk_wt a w commit
  git_q -C "$SRC/a" config --unset branch.w.arness-base
  run "$SCRIPT" list
  [ "$(col w 5)" = "UNKNOWN_BASE" ]
  run "$SCRIPT" list --base main
  [ "$(col w 5)" = "NOT_MERGED" ]
  [ "$(col w 4)" = "main" ]
}

@test "list shows nested names and several repos" {
  mk_repo a; mk_repo b
  mk_wt a feat/x
  mk_wt b fix/y
  run "$SCRIPT" list
  [ "$(col feat/x 1)" = "a" ]
  [ "$(col fix/y 1)" = "b" ]
  run "$SCRIPT" list --source b
  [ -z "$(col feat/x 1)" ]
  [ "$(col fix/y 1)" = "b" ]
}

@test "remove deletes a merged worktree and its branch" {
  mk_repo a
  mk_wt a done commit
  merge_wt a done
  run "$SCRIPT" remove --source a done
  [ "$status" -eq 0 ]
  [[ "$output" == REMOVED*/worktrees/a/done ]]
  [ ! -e "$ARNESS_ROOT/worktrees/a/done" ]
  [ -z "$(git -C "$SRC/a" branch --list done)" ]
  [ -z "$(git -C "$SRC/a" worktree list --porcelain | grep 'worktrees/a/done' || true)" ]
}

@test "remove cleans empty parent dirs but keeps worktrees/<repo>" {
  mk_repo a
  mk_wt a feat/x
  run "$SCRIPT" remove --source a feat/x
  [ "$status" -eq 0 ]
  [ ! -e "$ARNESS_ROOT/worktrees/a/feat" ]
  [ -d "$ARNESS_ROOT/worktrees/a" ]
}

@test "remove keeps a parent dir that still has another worktree" {
  mk_repo a
  mk_wt a feat/x
  mk_wt a feat/y
  run "$SCRIPT" remove --source a feat/x
  [ "$status" -eq 0 ]
  [ -d "$ARNESS_ROOT/worktrees/a/feat/y" ]
}

@test "remove several names at once" {
  mk_repo a
  mk_wt a one
  mk_wt a two
  run "$SCRIPT" remove --source a one two
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^REMOVED')" -eq 2 ]
}

@test "remove skips NOT_MERGED without --force and keeps everything" {
  mk_repo a
  mk_wt a open commit
  run "$SCRIPT" remove --source a open
  [ "$status" -eq 13 ]
  [[ "$output" == SKIPPED*/worktrees/a/open\ NOT_MERGED ]]
  [ -d "$ARNESS_ROOT/worktrees/a/open" ]
  [ -n "$(git -C "$SRC/a" branch --list open)" ]
}

@test "remove --force deletes a NOT_MERGED worktree and branch" {
  mk_repo a
  mk_wt a open commit
  run "$SCRIPT" remove --source a --force open
  [ "$status" -eq 0 ]
  [ ! -e "$ARNESS_ROOT/worktrees/a/open" ]
  [ -z "$(git -C "$SRC/a" branch --list open)" ]
}

@test "remove skips DIRTY without --force" {
  mk_repo a
  mk_wt a w
  echo y > "$ARNESS_ROOT/worktrees/a/w/untracked.txt"
  run "$SCRIPT" remove --source a w
  [ "$status" -eq 13 ]
  [[ "$output" == SKIPPED*/worktrees/a/w\ DIRTY ]]
  [ -d "$ARNESS_ROOT/worktrees/a/w" ]
}

@test "remove skips UNKNOWN_BASE without --force" {
  mk_repo a
  mk_wt a w
  git_q -C "$SRC/a" config --unset branch.w.arness-base
  run "$SCRIPT" remove --source a w
  [ "$status" -eq 13 ]
  [[ "$output" == SKIPPED*/worktrees/a/w\ UNKNOWN_BASE ]]
}

@test "remove reports unknown names and keeps going" {
  mk_repo a
  mk_wt a ok
  run "$SCRIPT" remove --source a nope ok
  [ "$status" -eq 13 ]
  [[ "$output" == *"SKIPPED"*"/worktrees/a/nope not-a-worktree"* ]]
  [[ "$output" == *"REMOVED"*"/worktrees/a/ok"* ]]
  [ ! -e "$ARNESS_ROOT/worktrees/a/ok" ]
}

@test "remove rejects unsafe names without touching anything" {
  mk_repo a
  mk_wt a w
  run "$SCRIPT" remove --source a ../a
  [ "$status" -eq 13 ]
  [ "$output" = "SKIPPED ../a invalid-name" ]
  [ -d "$SRC/a/.git" ]
}

@test "remove needs --source and a valid one" {
  mk_repo a; mk_repo b
  run "$SCRIPT" remove x
  [ "$status" -eq 2 ]
  run "$SCRIPT" remove --source nope x
  [ "$status" -eq 4 ]
  [ "$output" = "NO_SOURCE" ]
}

@test "remove needs at least one name" {
  mk_repo a
  run "$SCRIPT" remove --source a
  [ "$status" -eq 2 ]
}

@test "remove does not touch a worktree of another repo with the same name" {
  mk_repo a; mk_repo b
  mk_wt a w
  mk_wt b w
  run "$SCRIPT" remove --source a w
  [ "$status" -eq 0 ]
  [ -d "$ARNESS_ROOT/worktrees/b/w" ]
}

# --- base in the remote (origin/<branch>) ------------------------------------

# mk_remote_wt: source/a is a clone of origin; worktree w (one commit) is based on origin/epic/X-1,
# which exists only in the remote. Sets ORIGIN.
mk_remote_wt() {
  ORIGIN="$TMP/origin"
  git_q init -q "$ORIGIN"
  echo 1 > "$ORIGIN/f.txt"; git_q -C "$ORIGIN" add f.txt; git_q -C "$ORIGIN" commit -q -m c1
  git_q -C "$ORIGIN" checkout -q -b epic/X-1
  git clone -q "$ORIGIN" "$SRC/a" 2>/dev/null
  git_q -C "$ORIGIN" checkout -q main
  git_q -C "$SRC/a" worktree add -q -b w "$ARNESS_ROOT/worktrees/a/w" origin/epic/X-1
  git_q -C "$SRC/a" config branch.w.arness-base origin/epic/X-1
  echo w > "$ARNESS_ROOT/worktrees/a/w/w.txt"
  git_q -C "$ARNESS_ROOT/worktrees/a/w" add w.txt
  git_q -C "$ARNESS_ROOT/worktrees/a/w" commit -q -m work
}

# The remote epic branch integrates w's commit (as a PR merge would); the local origin/epic/X-1 is now stale.
merge_in_remote() {
  git_q -C "$ORIGIN" checkout -q epic/X-1
  git_q -C "$ORIGIN" fetch -q "$ARNESS_ROOT/worktrees/a/w" w
  git_q -C "$ORIGIN" merge -q --ff-only FETCH_HEAD
  git_q -C "$ORIGIN" checkout -q main
}

@test "a remote base is refreshed before comparing: merged in origin shows MERGED" {
  mk_remote_wt
  merge_in_remote
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ "$(col w 5)" = "MERGED" ]
  [ "$(col w 4)" = "origin/epic/X-1" ]
}

@test "--no-fetch compares with the local copy of the remote base" {
  mk_remote_wt
  merge_in_remote
  run "$SCRIPT" list --no-fetch
  [ "$(col w 5)" = "NOT_MERGED" ]
}

@test "not merged in origin stays NOT_MERGED after the refresh" {
  mk_remote_wt
  run "$SCRIPT" list
  [ "$(col w 5)" = "NOT_MERGED" ]
}

@test "remove deletes a worktree merged only in the remote" {
  mk_remote_wt
  merge_in_remote
  run "$SCRIPT" remove --source a w
  [ "$status" -eq 0 ]
  [ ! -e "$ARNESS_ROOT/worktrees/a/w" ]
  [ -z "$(git -C "$SRC/a" branch --list w)" ]
}

@test "a failing fetch warns on stderr and still lists with the local copy" {
  mk_remote_wt
  git -C "$SRC/a" remote set-url origin "$TMP/does-not-exist"
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: could not refresh origin/epic/X-1"* ]]
  [ "$(col w 5)" = "NOT_MERGED" ]
}

@test "local bases never trigger a fetch" {
  mk_repo a
  mk_wt a w
  git -C "$SRC/a" remote add origin "$TMP/does-not-exist"
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [[ "$output" != *warning* ]]
}

# --- local base that is behind its remote -------------------------------------

# mk_local_base_wt: source/a is a clone of origin; worktree w (one commit) from the LOCAL main.
mk_local_base_wt() {
  ORIGIN="$TMP/origin"
  git_q init -q "$ORIGIN"
  echo 1 > "$ORIGIN/f.txt"; git_q -C "$ORIGIN" add f.txt; git_q -C "$ORIGIN" commit -q -m c1
  git clone -q "$ORIGIN" "$SRC/a" 2>/dev/null
  mk_wt a w commit
}

# origin/main integrates w's commit (a PR merge); the local main is not updated (no pull).
merge_into_origin_main() {
  git_q -C "$ORIGIN" fetch -q "$ARNESS_ROOT/worktrees/a/w" w
  git_q -C "$ORIGIN" merge -q --ff-only FETCH_HEAD
}

@test "a local base behind its remote: merged in origin/<base> shows MERGED" {
  mk_local_base_wt
  merge_into_origin_main
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ "$(col w 5)" = "MERGED" ]
  [ "$(col w 4)" = "main" ]
  [ "$(col w 6)" = "0" ]
}

@test "--no-fetch does not see the merge in origin/<base>" {
  mk_local_base_wt
  merge_into_origin_main
  run "$SCRIPT" list --no-fetch
  [ "$(col w 5)" = "NOT_MERGED" ]
  [ "$(col w 6)" = "1" ]
}

@test "not merged anywhere stays NOT_MERGED" {
  mk_local_base_wt
  run "$SCRIPT" list
  [ "$(col w 5)" = "NOT_MERGED" ]
}

@test "remove deletes a worktree merged only in origin/<base>" {
  mk_local_base_wt
  merge_into_origin_main
  run "$SCRIPT" remove --source a w
  [ "$status" -eq 0 ]
  [ ! -e "$ARNESS_ROOT/worktrees/a/w" ]
}

@test "an unreachable origin warns for a local base that origin has" {
  mk_local_base_wt
  git -C "$SRC/a" remote set-url origin "$TMP/does-not-exist"
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: could not refresh origin/main"* ]]
  [ "$(col w 5)" = "NOT_MERGED" ]
}

# --- PR_MERGED: the branch of someone else's pull request, checked out to test it ---

# origin has pr/X-2 with a commit; worktree pr/X-2 is made from origin/pr/X-2 like worktree-create does.
# Sets ORIGIN and TIP.
mk_pr_wt() {
  ORIGIN="$TMP/origin"
  git_q init -q "$ORIGIN"
  echo 1 > "$ORIGIN/f.txt"; git_q -C "$ORIGIN" add f.txt; git_q -C "$ORIGIN" commit -q -m c1
  git_q -C "$ORIGIN" checkout -q -b pr/X-2
  echo 2 > "$ORIGIN/g.txt"; git_q -C "$ORIGIN" add g.txt; git_q -C "$ORIGIN" commit -q -m pr
  git_q -C "$ORIGIN" checkout -q main
  git clone -q "$ORIGIN" "$SRC/a" 2>/dev/null
  git_q -C "$SRC/a" worktree add -q -b pr/X-2 "$ARNESS_ROOT/worktrees/a/pr/X-2" origin/pr/X-2
  git_q -C "$SRC/a" config branch.pr/X-2.arness-base origin/pr/X-2
  TIP="$(git -C "$SRC/a" rev-parse pr/X-2)"
}

# The pull request is squash-merged (its commits never reach main) and its branch deleted.
squash_merge_pr() {
  git_q -C "$ORIGIN" branch -q -D pr/X-2
  export FAKE_GH_HEADS="$TIP"
}

@test "a pull request branch squash-merged and deleted in origin is PR_MERGED" {
  mk_pr_wt
  squash_merge_pr
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ "$(col pr/X-2 5)" = "PR_MERGED" ]
  [[ "$output" == *"note: origin/pr/X-2 no longer exists in a"* ]]
  [[ "$output" != *"warning:"* ]]
  grep -q -- "pr list --head pr/X-2 --state merged" "$FAKE_GH_LOG"
}

@test "remove deletes a PR_MERGED worktree without --force, with its branch and stale remote ref" {
  mk_pr_wt
  squash_merge_pr
  run "$SCRIPT" remove --source a pr/X-2
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOVED $ARNESS_ROOT/worktrees/a/pr/X-2"* ]]
  [ ! -e "$ARNESS_ROOT/worktrees/a/pr" ]
  [ -z "$(git -C "$SRC/a" branch --list pr/X-2)" ]
  ! git -C "$SRC/a" rev-parse --verify --quiet refs/remotes/origin/pr/X-2
}

@test "own work squash-merged through a pull request is PR_MERGED, not NOT_MERGED" {
  mk_remote_wt
  export FAKE_GH_HEADS="$(git -C "$SRC/a" rev-parse w)"
  run "$SCRIPT" list
  [ "$(col w 5)" = "PR_MERGED" ]
  [ "$(col w 6)" = "1" ]
}

@test "a merged pull request with another head is not PR_MERGED (local commits after it)" {
  mk_pr_wt
  squash_merge_pr
  echo 3 > "$ARNESS_ROOT/worktrees/a/pr/X-2/h.txt"
  git_q -C "$ARNESS_ROOT/worktrees/a/pr/X-2" add h.txt
  git_q -C "$ARNESS_ROOT/worktrees/a/pr/X-2" commit -q -m local
  run "$SCRIPT" list
  [ "$(col pr/X-2 5)" = "NOT_MERGED" ]
}

@test "a branch still in origin is not PR_MERGED and gh is not asked" {
  mk_pr_wt
  export FAKE_GH_HEADS="$TIP"
  run "$SCRIPT" list
  [ "$(col pr/X-2 5)" = "EMPTY" ]
  [ ! -e "$FAKE_GH_LOG" ]
}

@test "a failing gh leaves the status as it was" {
  mk_pr_wt
  squash_merge_pr
  unset FAKE_GH_HEADS
  run "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ "$(col pr/X-2 5)" = "EMPTY" ]
}

@test "an unreachable origin is not taken as a deleted branch" {
  mk_pr_wt
  export FAKE_GH_HEADS="$TIP"
  git -C "$SRC/a" remote set-url origin "$TMP/does-not-exist"
  run "$SCRIPT" list
  [ "$(col pr/X-2 5)" = "EMPTY" ]
  [ ! -e "$FAKE_GH_LOG" ]
}

@test "DIRTY wins over PR_MERGED and remove skips it without --force" {
  mk_pr_wt
  squash_merge_pr
  echo x >> "$ARNESS_ROOT/worktrees/a/pr/X-2/f.txt"
  run "$SCRIPT" list
  [ "$(col pr/X-2 5)" = "DIRTY" ]
  run "$SCRIPT" remove --source a pr/X-2
  [ "$status" -eq 13 ]
  [ -d "$ARNESS_ROOT/worktrees/a/pr/X-2" ]
}

@test "--no-fetch never asks gh" {
  mk_pr_wt
  squash_merge_pr
  run "$SCRIPT" list --no-fetch
  [ "$(col pr/X-2 5)" = "EMPTY" ]
  [ ! -e "$FAKE_GH_LOG" ]
}
