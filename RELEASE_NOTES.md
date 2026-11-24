# FlipSide 1.0.0

This stable release focuses on review reliability, calendar synchronization, and saved dictionary meanings.

## Bug fixes and improvements

- Review queue: improved handling of cards that become due while a session is open, without rebuilding the current card or resetting Undo and Cram progress.
- Calendar sync: added a separate cloud folder setting for the Study Calendar, including WebDAV; the Statistics folder remains the fallback until a Calendar folder is configured.
- Saved meanings: closing the dictionary opened from Meaning Options now returns to that menu.
- Saved meaning popup: keeps the underlying flashcard and its frame visible instead of covering the card; other popups retain their existing behavior.
- Saved definitions: improved recovery of definitions saved under the selected word form, avoiding duplicates and respecting deleted entries.
- Sentence context: improved recognition of complete preceding sentences that begin with quotation marks.

## Installation

Back up your FlipSide settings and vocabulary before updating. Extract the release installer into `koreader/plugins/`, replacing the existing `flipside.koplugin/` directory, then restart KOReader.

Device behavior may vary with KOReader versions. Automated checks do not replace Android and Kindle testing, particularly for cloud synchronization and e-ink rendering.

License: AGPL-3.0; see COPYING and NOTICE.txt.
