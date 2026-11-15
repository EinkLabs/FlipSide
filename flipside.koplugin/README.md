# FlipSide for KOReader

A compact, e-ink-friendly vocabulary flashcard plugin with Meaning Recall, Contextual Retrieval, Sentence Card, Smart Cram, saved dictionary definitions, Learning Analysis and optional Dropbox/WebDAV cloud synchronization.

## Install

1. Back up `koreader/settings/flipside/` (if it exists).
2. Copy the extracted `flipside.koplugin/` folder to `koreader/plugins/`.
3. Restart KOReader and open FlipSide in the search/magnifier menu.

To import words from the native Vocabulary Builder, use the manual import option. Do not delete your original database before checking the imported cards.

## Dictionary

In the dictionary, turn **ON** to hold-and-drag over a definition and tap **Save**. Turn **OFF** for standard KOReader dictionary interactions. Saved definitions are managed under **Aa → Saved meanings**. The **Popup** checkbox is optional while reading.

For a visual introduction and the full short dictionary guide, see the project's GitHub README and `docs/DICTIONARY.md`.

## Data and license

User data lives in `koreader/settings/flipside/`, not in the installable code. Sync is not an independent backup. Keep a separate copy before reset, reinstall or provider changes.

Based in part on KOReader Vocabulary Builder. License: AGPL-3.0; see `COPYING` and `NOTICE.txt`.
