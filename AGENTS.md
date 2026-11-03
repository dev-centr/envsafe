# envsafe agent notes

Org rules: `dev-centr/agent-rules` (`AGENTS.md`). This file only adds repo facts.

- D / DUB project. `dub test` runs all unit tests; `dub build -b release` writes `bin/envsafe`.
- `tests/smoke.sh bin/envsafe` is the end-to-end secret-pipe check (bash; Git Bash on Windows).
- Never print, log, or echo a value read from a .env file, stdin, or the environment. Errors name keys, lines and codes only.
- Version lives in `source/envsafe/version_.d`; the release workflow fails if the tag disagrees.
- Changelog: root `CHANGELOG.adoc` + `changelog-details/` (no docs site).
