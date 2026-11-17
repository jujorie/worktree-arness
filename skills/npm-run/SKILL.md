---
name: npm-run
description: Run an npm script of a worktree in the background, wait for it to end with its exit code, and list, stop or clean up the ones started. Use whenever the user asks to run, start, launch, wait for, list, stop or clean up an npm script in a worktree, or needs to know whether tests, checks or a build passed, e.g. "lanza npm start en el worktree", "arranca el dev server", "ejecuta los tests de X", "espera a que terminen los tests", "para el start", "limpia los logs de npm". Always use this skill, never `npm run` or its script directly. Fails with NO_COMMAND, UNKNOWN_SCRIPT, NO_PACKAGE_JSON or NO_NODE_VERSION.
allowed-tools: Bash(skills/npm-run/scripts/npm-run.sh *)
---

# npm-run

> Use this skill; do not run `npm run`, `npm install` or the script on your own. The procedure below decides what to ask and when to stop.

Runs `npm run <script> [-- <args>]` in `worktrees/<repo>/<name>`, in the background, with its output in a log and its pid saved, so it can be stopped later (with its child processes).
All checks are done by `scripts/npm-run.sh` (in this skill's folder): the worktree exists, `package.json` is at its root, the script is a key of its `"scripts"`, and `node_modules` is there. Only npm; only the `package.json` at the worktree root.
With an `.nvmrc` at the worktree root, the install and the script run with that node version from nvm (`NVM_DIR`, else `~/.nvm` or `${XDG_CONFIG_HOME:-~/.config}/nvm`) or nvm-windows (`NVM_HOME`). It goes first in their PATH only, so the global node is left alone; `22` and `22.x` pick the highest `22.x` installed. Only a `NODE` line guarantees that version; an alias (`lts/*`, `node`) is not resolved and gives `NODE_UNRESOLVED`.
Policy for a version that is missing: with nvm installed (`NVM_HOME` set, or `nvm.sh` or `versions/node` in its folder) the script stops with `NO_NODE_VERSION` (exit 13); without nvm (node from a package manager, fnm, volta) it only gives a `warning:` on stderr and runs with the current node; relay it.

## Procedure

1. From the user's message, extract:
   - **script**: the npm script name (`start`, `test`, `build:prod`). Never invent it or pick a similar one.
   - **worktree**: `<repo>/<name>`, optional (the script picks the only one there is).
   - **args**: extra arguments for the script, only if the user gives them; they go after `--`.
2. Run from the repo root, passing only what you have:
   ```bash
   skills/npm-run/scripts/npm-run.sh run [--worktree <repo>/<name>] <script> [-- <args>...]
   ```
3. Read the first word of stdout:

| Output | Exit | What to do |
|---|---|---|
| `STARTED <slug> <script> <pid> <log>` | 0 | Running in the background. A script that ends by itself (tests, checks, builds): `wait` for it (below). A server or watcher: report the pid and log; read the log only if the user asks or to confirm it came up. |
| `FINISHED <slug> <script> 0 <log>` | 0 | Ended at once with success (a short script). Report it; read the log if the user wants the output. |
| `FINISHED <slug> <script> <code> <log>` | 8 | Failed at start. The last 20 lines are on stderr; show them. Do not retry or change the command. |
| `CHOOSE_WORKTREE <slug>...` | 10 | Ask the user which worktree, listing them. Rerun with `--worktree <slug>` and the same script. |
| `NO_COMMAND <slug>` + `SCRIPT ...` | 5 | **Finish with NO_COMMAND**. Show the available scripts; do not pick one. |
| `UNKNOWN_SCRIPT <slug> <script>` + `SCRIPT ...` | 7 | **Finish with UNKNOWN_SCRIPT**. Show the available scripts; do not run a similar one. |
| `NO_PACKAGE_JSON <path>` / `INVALID_PACKAGE_JSON <path>` | 6 | **Finish with NO_PACKAGE_JSON** (or INVALID_PACKAGE_JSON). |
| `CONFIRM_INSTALL <slug>` | 11 | No `node_modules`. Ask: install the dependencies? If a `NODE_UNRESOLVED` line came first, say in the question that the node version is not checked. Yes: rerun with `--install` (runs `npm ci`, or `npm install` without a lock file; it may take minutes, use a long timeout). No: finish. |
| `NODE <slug> <version>` | — | The `.nvmrc` node is used; comes before `CONFIRM_INSTALL`/`INSTALLED`/`STARTED`/`FINISHED`. Report it. |
| `NODE_UNRESOLVED <slug> <alias>` | — | The `.nvmrc` alias was not checked and the current node runs; same place as `NODE`. Tell the user. |
| `NO_NODE_VERSION <slug> <version>` | 13 | **Finish with NO_NODE_VERSION**: nvm is installed, but neither it nor the current node has the `.nvmrc` version. Nothing ran. Suggest `nvm install <version>`; do not run it with another node. |
| `INSTALLED <slug> <log>` | — | Comes before `STARTED`/`FINISHED`; report it. |
| `INSTALL_FAILED <code> <log>` | 12 | Show the stderr lines. Do not retry. |
| `ALREADY_RUNNING <slug> <script> <pid>` | 9 | Tell the user. Offer to stop it first; never start a second one. |
| `NO_WORKTREE` / `NOT_FOUND <slug>` | 4 | No such worktree. Suggest the `worktree-create` skill, or check the slug. A `warning: cygpath cannot convert …; <repo> not listed` on stderr means that repo's worktrees were left out, not that there are none: tell the user. |
| `NO_NPM` | 3 | npm is not installed (`run` also looks for it with the `.nvmrc` node; `ps`, `stop` and `clean` never need it). Finish. |
| error on stderr | 2 | Invalid input (slug, script name, options). Show the message. |

### Wait for a script to end

For tests, checks and builds: `run` and then `wait`. It blocks until the script ends and gives its exit code, also when it ended before `wait` was called (it answers at once then).

```bash
skills/npm-run/scripts/npm-run.sh wait [--worktree <repo>/<name>] <script> [--timeout <seconds>]
```

Give the shell tool a timeout longer than `--timeout` (default 540 s, under the 10 minutes it allows; `0` waits forever). Polls once a second.

| Output | Exit | What to do |
|---|---|---|
| `FINISHED <slug> <script> 0 <log>` | 0 | It passed. Read the log if the user wants the output. |
| `FINISHED <slug> <script> <code> <log>` | 8 | It failed with `<code>`. The last 20 lines are on stderr; show them. Read the log for more. |
| `TIMEOUT <slug> <script> <pid> <log>` | 15 | Still running after `--timeout`; it keeps running. Call `wait` again, or ask the user whether to `stop` it. |
| `NOT_STARTED <slug> <script>` | 16 | Not started in that worktree, or stopped or cleaned since. Check the script and worktree; do not start it unless that was the task. |
| `NO_CODE <slug> <script> <log>` | 17 | It ended without saving its code (killed outside `stop`, or started by an older npm-run). Read the log to tell what happened. |
| `NOT_FOUND <slug>` / `CHOOSE_WORKTREE` / error on stderr | 4 / 10 / 2 | As in the table above. |

The code is saved in `tmp/npm-run/<repo>/<name>/<script>.code` when the script ends, also after npm-run returned. A new `run` of that script removes the old one first. A script ended with `stop` saves no code (`stop` removes any it finds), so `wait` then says `NOT_STARTED`.

### List, stop and clean up

```bash
skills/npm-run/scripts/npm-run.sh ps                                   # RUNNING / EXITED lines (EXITED ends with the code when saved), or NONE
skills/npm-run/scripts/npm-run.sh stop --worktree <repo>/<name> [<script>]
skills/npm-run/scripts/npm-run.sh stop <script>                        # that script in every worktree
skills/npm-run/scripts/npm-run.sh stop --all
skills/npm-run/scripts/npm-run.sh clean [--worktree <repo>/<name>]     # CLEANED lines, or NONE
skills/npm-run/scripts/npm-run.sh scripts [--worktree <repo>/<name>]   # SCRIPT lines
```

`stop` prints `STOPPED <slug> <script> <pid>` per process (TERM to its process group, KILL after 5 s; in Git Bash, first `taskkill /T /F` on its Windows process tree), or `NONE`. `STOP_FAILED <slug> <script> <pid>` (exit 14): taskkill could not end that tree and part of it may still run; its pid file is kept, so `stop` can be retried. Show the `warning:` from stderr; do not retry in a loop. Ask before `stop --all` if the user did not say it.

Files live in `tmp/npm-run/<repo>/<name>/`. `stop` removes the pid, log and code of what it stops, plus the `install.log` and folders left empty. A script that ended by itself (`FINISHED`, `EXITED`) keeps its log and code, the only record of what happened. Read them first if they matter, then `clean` removes the logs, codes and pids of everything that no longer runs and the empty folders (`CLEANED <slug> <file>` per file). It never touches what still runs.

## Rules

- "Finish with X" means: stop, report the literal failure code `X` and why. No workaround.
- Never run a script that is not in the worktree's `package.json` `"scripts"`, nor `npm install` without the user's yes.
- Never guess the worktree when there are several: ask.
- Never wait for a script with a loop of your own, `sleep`, or by reading its pid or log by hand: use `wait`.
- Only the processes this skill started are listed and stopped; never kill other processes.
