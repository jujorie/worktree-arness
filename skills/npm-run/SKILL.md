---
name: npm-run
description: Run an npm script of a worktree in the background, and list or stop the ones started. Use whenever the user asks to run, start, launch, list or stop an npm script in a worktree, e.g. "lanza npm start en el worktree", "arranca el dev server", "ejecuta los tests de X", "para el start". Always use this skill, never `npm run` or its script directly. Fails with NO_COMMAND, UNKNOWN_SCRIPT or NO_PACKAGE_JSON.
allowed-tools: Bash(skills/npm-run/scripts/npm-run.sh *)
---

# npm-run

> Use this skill; do not run `npm run`, `npm install` or the script on your own. The procedure below decides what to ask and when to stop.

Runs `npm run <script> [-- <args>]` in `worktrees/<repo>/<name>`, in the background, with its output in a log and its pid saved, so it can be stopped later (with its child processes).
All checks are done by `scripts/npm-run.sh` (in this skill's folder): the worktree exists, `package.json` is at its root, the script is a key of its `"scripts"`, and `node_modules` is there. Only npm; only the `package.json` at the worktree root.

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
| `STARTED <slug> <script> <pid> <log>` | 0 | Running in the background. Report the pid and log. Read the log only if the user asks or to confirm it came up. |
| `FINISHED <slug> <script> 0 <log>` | 0 | Ended at once with success (a short script). Report it; read the log if the user wants the output. |
| `FINISHED <slug> <script> <code> <log>` | 8 | Failed at start. The last 20 lines are on stderr; show them. Do not retry or change the command. |
| `CHOOSE_WORKTREE <slug>...` | 10 | Ask the user which worktree, listing them. Rerun with `--worktree <slug>` and the same script. |
| `NO_COMMAND <slug>` + `SCRIPT ...` | 5 | **Finish with NO_COMMAND**. Show the available scripts; do not pick one. |
| `UNKNOWN_SCRIPT <slug> <script>` + `SCRIPT ...` | 7 | **Finish with UNKNOWN_SCRIPT**. Show the available scripts; do not run a similar one. |
| `NO_PACKAGE_JSON <path>` / `INVALID_PACKAGE_JSON <path>` | 6 | **Finish with NO_PACKAGE_JSON** (or INVALID_PACKAGE_JSON). |
| `CONFIRM_INSTALL <slug>` | 11 | No `node_modules`. Ask: install the dependencies? Yes: rerun with `--install` (runs `npm ci`, or `npm install` without a lock file; it may take minutes, use a long timeout). No: finish. |
| `INSTALLED <slug> <log>` | — | Comes before `STARTED`/`FINISHED`; report it. |
| `INSTALL_FAILED <code> <log>` | 12 | Show the stderr lines. Do not retry. |
| `ALREADY_RUNNING <slug> <script> <pid>` | 9 | Tell the user. Offer to stop it first; never start a second one. |
| `NO_WORKTREE` / `NOT_FOUND <slug>` | 4 | No such worktree. Suggest the `worktree-create` skill, or check the slug. |
| `NO_NPM` | 3 | npm is not installed. Finish. |
| error on stderr | 2 | Invalid input (slug, script name, options). Show the message. |

### List and stop

```bash
skills/npm-run/scripts/npm-run.sh ps                                   # RUNNING / EXITED lines, or NONE
skills/npm-run/scripts/npm-run.sh stop --worktree <repo>/<name> [<script>]
skills/npm-run/scripts/npm-run.sh stop <script>                        # that script in every worktree
skills/npm-run/scripts/npm-run.sh stop --all
skills/npm-run/scripts/npm-run.sh scripts [--worktree <repo>/<name>]   # SCRIPT lines
```

`stop` prints `STOPPED <slug> <script> <pid>` per process (TERM to its process group, KILL after 5 s), or `NONE`. Ask before `stop --all` if the user did not say it.

## Rules

- "Finish with X" means: stop, report the literal failure code `X` and why. No workaround.
- Never run a script that is not in the worktree's `package.json` `"scripts"`, nor `npm install` without the user's yes.
- Never guess the worktree when there are several: ask.
- Only the processes this skill started are listed and stopped; never kill other processes.
