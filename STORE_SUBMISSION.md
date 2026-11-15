# Publishing FlipSide for KOReader community stores

This checklist is for the GitHub repository maintainer. It does not modify or extend the KOReader plugin.

## GitHub source repository

- Use the standalone repository `EinkLabs/FlipSide`, with the root-level `flipside.koplugin/` directory, English illustrated `README.md`, `docs/`, `tests/`, `COPYING`, `NOTICE.txt`, and `.github/workflows/flip-side-tests.yml`.
- Start **private**, confirm the intended GitHub account and check commit author/committer identity. The initial commit must have no history imported from another account.
- Add a short repository description: `Minimalist e-ink vocabulary flashcards and review for KOReader.`
- On publication, add the GitHub topic **`koreader-plugin`** (also `koreader`, `flashcards`, `vocabulary`, and `e-ink` if useful). AppStore uses the `koreader-plugin` topic to discover independently maintained plugins.
- Do not upload KOReader user settings, cards/databases, live logs, tokens, cloud credentials, or previous Git history.

## Pre-release for AppStore / Storefront

1. After approving a public release, publish the repository, keeping the plugin source and notices intact.
2. Confirm GitHub Actions succeeds; then create tag `v1.0.0-rc.1`, release title `FlipSide 1.0.0-rc.1`, and **mark it as a pre-release**.
3. Attach the **generated installer asset** `FlipSide-1.0.0-rc.1.zip` from `python3 scripts/build_release.py`. Do **not** attach the repository-source ZIP as the installation artifact: the installer must contain only `flipside.koplugin/`.
4. Copy the highlights and limitations from `RELEASE_NOTES.md`, plus installation instructions and AGPL-3.0/NOTICE attribution.
5. In AppStore, search for `FlipSide` or filter by GitHub owner `EinkLabs`; ensure the repository is indexed by the `koreader-plugin` topic and test its installation and updates on a clean KOReader profile.
6. In Storefront, verify discovery and installation using its current curated catalog and/or GitHub discovery mechanisms. If the repository is not indexed, request its addition from the Storefront maintainers according to their current contribution process; visibility is **not automatic or guaranteed**.
7. Optionally propose inclusion in `koreader/contrib`, which is separate from the independent stores and requires upstream review. KOReader's contrib repository asks for working plugins, README/compatibility instructions and normally a submodule pointing at the standalone upstream repository.

## Test status at packaging time

- Python source/SQLite/release checks: 7 passed locally.
- Lua syntax and mocked regression tests: 25 passed locally under LuaHBTeX's Lua interpreter, **not LuaJIT**. The CI workflow runs them with LuaJIT and must still be verified.
- Installation archive: 50 plugin files, matching repository source byte-for-byte, excluding tests and private settings.
- Not verified in a live KOReader environment: Android/Kindle UI, cloud authentication/WebDAV/Dropbox, cross-device sync, actual migrated vocabulary, and physical-device screen interactions.

Always test on a backup or a fresh profile first. The release is a candidate, not a stable hardware-certified build.
