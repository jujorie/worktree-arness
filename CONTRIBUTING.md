# Contributing

Thanks for helping. This repo is small and its rules are strict on purpose: it holds the instructions agents follow.

## Workflow

1. Fork the repo (or branch, if you have write access) and create a branch named `<type>/<short-description>`.
2. Make the change, with tests (see below).
3. Open a pull request against `main`.
4. CI must pass (`test (ubuntu-latest)` and `test (macos-latest)`).
5. The maintainer reviews and merges. Nobody pushes to `main` directly, and only the maintainer merges.

`main` is protected by a branch ruleset: pull request required, code-owner review (`.github/CODEOWNERS`), required CI checks, no force-push, no deletion.

Changes under `.github/` (CI workflows, `CODEOWNERS`) are reviewed and merged by the owner only. A pull request that weakens the checks will not be merged.

## Setup

Install `bats-core` and `shellcheck`, then run the whole suite before every PR:

```bash
./scripts/test.sh
```

See the root `README.md` for the other requirements and for how the repo is laid out.

## Branch names

`<type>/<short-description>`, lowercase kebab-case. An issue or ticket id may follow the type: `fix/PROJ-123-clean-empty-dirs`.

| Type | Use for |
|---|---|
| `feat` | a new skill, script option or behavior |
| `fix` | a bug fix |
| `docs` | documentation only |
| `refactor` | a change with no behavior change |
| `test` | tests only |
| `chore` | tooling, CI, housekeeping |

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/): `<type>: <summary>`, with the same types as the branches.

- Summary in the imperative, lowercase, no final period, 72 characters at most (`fix: keep empty parent dirs that still have worktrees`).
- Use the body to explain **why**, not what the diff already shows.
- Breaking changes: `<type>!:` and a `BREAKING CHANGE:` line in the body.

## Pull requests

Before asking for review, check that:

- [ ] `./scripts/test.sh` passes (it includes shellcheck).
- [ ] New behavior has bats tests, including the failure paths.
- [ ] Docs are updated: the skill's `SKILL.md`, the folder README, `README.md` if the layout changed.
- [ ] You edited the sources, not generated files (`.claude/`, `.agents/`, `CLAUDE.md`, `opencode.json`). Providers live in `providers/`.
- [ ] A new skill with a script has its permission entries in `providers/claude/settings.json` and `providers/opencode/opencode.json`. `tests/repo.bats` fails if they are missing.
- [ ] Examples are generic (`PROJ-123`, `my-repo`): no company, customer or internal project names, no secrets, no personal paths.

Keep a PR to one concern; small PRs get merged faster.

## Local skills

A skill that should not be shared goes in `skills/local-<name>/`: it is git-ignored and skipped by the checks. See `skills/README.md`. Never commit one, and do not reference it from committed files.

## Style

Follow [CODESTYLE.md](CODESTYLE.md).

## License

By contributing you agree that your work is released under the [MIT License](LICENSE).
