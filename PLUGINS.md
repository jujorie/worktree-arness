# Official plugins

Plugins maintained for arness: public repos with CI, a protected `main` and version tags. Install one by
name with the `plugin-manage` skill ("instala el plugin worktree-arness-npm-run"): it takes the URL and the
tag from this table, shows the plan and asks before installing, as for any plugin. Any other plugin is
installed by its URL. To add one here, see `CONTRIBUTING.md` (*Official plugins*).

`plugin-manage.sh catalog` reads the table below; keep its header and its four columns. `Ref` is the tag
to install; once installed, the plugin updates to its newest stable tag.

| Name | URL | Ref | Description |
|---|---|---|---|
| worktree-arness-npm-run | https://github.com/jujorie/worktree-arness-npm-run.git | v0.1.0 | Run npm scripts of a worktree in the background, wait for their exit code, and stop them before the worktree is removed |
