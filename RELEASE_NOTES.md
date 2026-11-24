# FlipSide 1.0.1

This maintenance release improves live review queue updates while FlipSide remains open.

## Bug fixes

- Scheduled reviews: cards that become due after a completed review session now appear automatically without closing and reopening FlipSide.
- Cloud synchronization: the active flashcard screen now refreshes from the database after synchronization, including changes to cards reviewed on another device. Refreshes wait until the interface is safe to update.
- Review session consistency: unchanged synchronized card data preserves the current session; a changed catalog starts a fresh session rather than reusing stale Undo records.

No changes to the review intervals, scheduling algorithm, visual design, or cloud folder configuration are intended.

## Installation

Back up FlipSide settings and vocabulary before updating. Extract the installation ZIP into `koreader/plugins/`, replacing the existing `flipside.koplugin/` directory, then restart KOReader.

The live scheduled-review refresh was confirmed by the maintainer on Android. A short delay after unlocking a sleeping device may occur. Kindle behavior and full cross-device synchronization still require physical-device verification.

License: AGPL-3.0; see COPYING and NOTICE.txt.
