# Config Folder

Local files copied into each new worktree by the `worktree-config` skill (also run by `worktree-create`). This folder is git-ignored except this README.

Layout: `config/<repo>/<path>` is copied to `worktrees/<repo>/<name>/<path>`, overwriting existing files. Content is copied as is.

- `config/<repo>/install.sh` (top level only) is not copied; it runs with `bash`, inside the worktree, after the copy. Use it for installs and builds.
- Symlinks are skipped, and `.git` is never written.
- `config/.configignore` (all repos) and `config/<repo>/.configignore` (one repo) list what not to copy, one glob per line (`.DS_Store`, `._*`, `.vscode/*`); their rules are added together. Without them nothing is ignored. Syntax in `skills/worktree-config/SKILL.md`.
