# FlipSide – developer-only automated tests

These tests are **not** part of the installed plugin. They do not run in KOReader,
show notifications, or access the user's settings, cards, or cloud accounts.

## Repository layout

- `flipside.koplugin/`: **unchanged** plugin version 904 used as the baseline.
- `tests/run.lua`: regression tests that execute the real pure-Lua merge code,
  isolated in-memory implementations of LuaSettings/LFS for Smart Cram and
  statistics Undo recovery, and a mocked UI sizing helper.
- `tests/test_repository.py`: checks source layout and exercises the actual
  SQL schema extracted from `flipside_db.lua` in an in-memory SQLite database.
- `tests/test_release.py`: ensures the installation archive includes only
  plugin files, unchanged byte-for-byte.
- `.github/workflows/flip-side-tests.yml`: runs these checks on GitHub when
  code is pushed, a pull request is opened, or the workflow is started manually.
- `scripts/build_release.py`: creates `dist/FlipSide-1.0.0-rc.1.zip` with no tests,
  workflows, private data, or development files.

## Run locally (Linux or GitHub Actions)

Install `luajit` and Python 3, then from the repository root run:

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
luajit tests/run.lua
python3 scripts/build_release.py
python3 -m unittest discover -s tests -p 'test_release.py' -v
```

The GitHub workflow runs this automatically and uploads an installation-only ZIP
as a *workflow artifact*. This is **not an automatic public release**.

## Coverage and limits

**Direct functional tests**: CRAM three-way merge and conflicts; CRAM queue
persistence, official miss and Undo; statistics Undo recovery journal; calendar
revisions/conflicts; data comparison in sync; pagination width at simulated DPI;
SQLite schema constraints and transaction rollback on test-only databases.

**Syntax only**: all existing Lua plugin modules are compiled but KOReader UI
modules are not started. Syntax success cannot guarantee hardware behavior.

**Not tested**: live Dropbox/WebDAV exchange, real KOReader UI and popups,
full review scheduling, GUI touch events, real device-specific DPI, cross-device
file locking, and real user database migration/recovery. Verify those on Android
and Kindle before calling a release stable.

The suite does not alter plugin source files or the SRS algorithm. It needs no
network access, credentials, special plugins, or user cards. GitHub Actions logs
are visible to repository maintainers, **not inside FlipSide**.

## Updating for a new plugin version

Replace **only** the `flipside.koplugin/` directory with the new reviewed
version; edit tests if public contracts intentionally change, and update the
release ZIP name in the build script and workflow. Do not copy private files
from `koreader/settings/flipside/` into the repository.

For public publication, separately review copyright notices, complete license,
README instructions, and the actual final plugin version. This test kit does
not assert those publication requirements are fulfilled.
