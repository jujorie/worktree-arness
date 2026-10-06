# Code style

Naming and conventions used across the repo. When in doubt, copy the nearest existing file.

## Shell scripts

- `#!/usr/bin/env bash` and `set -euo pipefail`. Bash only: no `sh`, and no Perl or Python in scripts.
- Portable to **bash 3.2 (macOS) and Linux/WSL**: no `mapfile`, `readlink -f`, `sed -i`, associative arrays, `${var,,}`, or GNU-only flags. Use the plain POSIX form of `sed`, `find`, `cp`, `sort`.
- shellcheck clean. A `# shellcheck disable=...` needs a reason on the same line.
- Quote every expansion. Use `[ ]` for tests, `[[ ]]` only for pattern or regex matching. Under `set -e`, write `if cmd; then ...` instead of `cmd && other` when the left side may fail.
- Wrap logic in `main()`, and run it only when executed, so tests can source the file:
  ```bash
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
  fi
  ```

### Names

| What | Convention | Example |
|---|---|---|
| Script file | `kebab-case.sh`, named like its skill | `worktree-create.sh` |
| Function | `snake_case`, verb first | `resolve_base`, `check_dest` |
| Local variable | `lowercase`, declared with `local` | `local repo="$1"` |
| Constant, global, exported variable | `UPPER_SNAKE_CASE` | `EXIT_USAGE`, `NO_FETCH`, `ARNESS_ROOT` |
| Exit code | named constant `EXIT_<NAME>`, never a bare number | `exit "$EXIT_NO_SOURCE"` |
| Status word (stdout) | `UPPER_SNAKE_CASE`, first word of the line | `CREATED`, `NOT_MERGED` |

### Script contract

- **Header comment** at the top: purpose, `Usage:`, every stdout status with its meaning, and the exit codes. `-h` prints it.
- **stdout is machine readable**: one status word first, then arguments. Anything for humans, warnings and errors go to **stderr** (`error: ...`, `warning: ...`).
- Scripts do the deterministic work. A `SKILL.md` only decides what to ask and what to run next from the status.
- Never prompt from a script. Ask through a status (`CHOOSE_SOURCE`, `CONFIRM_BRANCH`) and let the skill ask.
- Be safe by default: validate every name or path that comes from outside, never write outside the folder the script owns, never overwrite or delete without an explicit option, and say what was skipped.
- Network is explicit and bounded: set `GIT_TERMINAL_PROMPT=0`, fetch only what is needed, and offer `--no-fetch`.

### Pitfalls

Each of these has broken a script here that looked fine.

| Pitfall | Do instead |
|---|---|
| `cmd \| head -n N` under `pipefail`: once the output exceeds the pipe buffer (64 KB), `cmd` dies with SIGPIPE (exit 141). Small test data hides it. | `cmd \| awk 'NR <= N'` (awk reads all its input). Test with big data too. |
| A function that prints a status and exits, called as `x="$(f)"`: the status stays in `x` and the `exit` only leaves the subshell. | `x="$(f)" \|\| rc=$?`, then print `$x` and `exit "$rc"`. |
| `v="…$([ "$a" = b ] && echo y)…"`: when the test is false the assignment returns 1 and `set -e` stops the script. | Compute the piece with an `if` before the assignment. |
| A `case … esac` inside `$(…)`: bash 3.2 cannot parse it (`bash -n` does not notice). | Move the `case` into a function and call it. |
| `"$name»"` or any non-ASCII character right after a variable: its bytes are taken as part of the name. | `"${name}»"`. |
| `jq --args a b 'filter' file`: the positional arguments come after the filter, so `a` becomes the filter. | `--argjson ids "$(printf '%s\n' "$@" \| jq -R . \| jq -s .)"`. |
| `awk -v re='\('`: `-v` processes the backslashes away. | `RE='\(' awk '$0 ~ ENVIRON["RE"]'`. |
| Alternation with backslash-pipe in a basic `sed` regex: BSD `sed` does not support it. | `sed -E` (extended regex), where alternation is a plain pipe inside a group. |
| `sed 's/[áé]/x/'`: in the C locale a multibyte class matches single bytes. | One literal substitution per character (`s/á/a/g; s/é/e/g`). |
| `cmd > f.tmp && mv f.tmp f`: when `cmd` fails, `f.tmp` is left behind. | `trap 'rm -f "$tmp"' EXIT`, or remove it in the failure branch. |

## Skills

- Folder `skills/<name>/`, `<name>` in `kebab-case`, `<noun>-<verb>` (`repo-clone`, `worktree-create`). It must equal `name` in `SKILL.md`.
- Layout: `SKILL.md`, `scripts/` (everything the skill runs) and `tests/` (bats).
- `SKILL.md` frontmatter: `name`, `description` (what it does and **when to use it**, one sentence or two) and, if it has a script, `allowed-tools` with that script's exact command.
- Body: what it does, `## Procedure` (a table of status → action) and `## Rules` (what the agent must never do).
- Use the same words for the same thing: **worktree**, **source**, **base branch**, **slug** (`<repo>/<name>`).

## Tests (bats)

- One file per script: `skills/<name>/tests/<script>.bats`. Repo-wide checks live in `tests/`.
- Test names are lowercase sentences that state the behavior: `@test "remove skips DIRTY without --force"`.
- Each test builds its own world in `mktemp -d` (`ARNESS_ROOT`, throwaway git repos) and removes it in `teardown`. No real network, no real remotes, no writes outside the temp dir.
- Cover the failure paths and the unsafe inputs, not only the happy path.
- On macOS, also run them with the system bash 3.2, which `#!/usr/bin/env bash` skips when a newer bash is installed: `PATH=/bin:/usr/bin:$PATH ./scripts/test.sh`.
- Helper functions are `snake_case` and go at the top of the file, or in `tests/helpers.bash` when shared.

## Docs and examples

- English, short, with tables for mappings. Every top-level folder has a `README.md` that says what goes there and how it is used.
- Examples use generic names: `my-repo`, `PROJ-123`, `feat/PROJ-123`. Never real company, customer or internal project names, personal paths or secrets.
- Code identifiers and commands go in backticks; paths are relative to the repo root.

## Commits and branches

See [CONTRIBUTING.md](CONTRIBUTING.md).
