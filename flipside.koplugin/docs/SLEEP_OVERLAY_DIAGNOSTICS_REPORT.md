# Sleep overlay / ghosting investigation — diagnostic build

## Observed issue

Two photographs on a Kindle show the FlipSide floating menu, or a rectangular region containing a flashcard, on top of the book-cover screensaver. This is not a typical Lua exception: the existing `crash.log` might contain no cause. At present the screenshots alone cannot distinguish between a delayed software redraw, an incorrectly stacked window, a native Kindle screen refresh, and physical e-ink image retention.

## Verified behavior in KOReader source

KOReader's screensaver marks the device as being in screensaver mode, and on Kindle the power events can precede or lag the final screensaver transition. Consequently `onResume` cannot be treated as the exact moment it is safe to redraw the card.

## Implementation

- Sleep lifecycle trace around `onSuspend`, `onResume`, `onOutOfScreenSaver`, and the delayed foreground recovery.
- Passive `UIManager:setDirty` observer with original return values and parameters unchanged. Suspicious requests include a bounded Lua source traceback and the window stack. Native screensaver requests are separately classified, not called plugin errors without evidence.
- Detect actual `Flashcards:paintTo` calls while asleep, when the inherited widget painter can be safely wrapped.
- Mark FlipSide `_render`, `_refresh`, and contextual cloze refresh attempts that are blocked by existing sleep guards.
- Trace windows shown while the cover is active; do not block native KOReader screensaver windows.
- Correct a potential suspend-time overlay: save failure must **not** open a new CRAM warning popup over the cover. The warning is postponed until the flashcards are foregrounded after waking.
- Keep the existing `diagnostics.log` rotation and sanitization; the CRAM database and all review algorithms are unchanged.

## Validation

- Parse all Lua plugin sources using Lua 5.3 syntax checks.
- Stubbed `UIManager` test verifies normal calls pass through unchanged, suspect calls during sleep are recorded, and wake-up does not log ordinary refreshes.
- Diagnostic-file test verifies event records, suspected redraw traceback, and scrubbed private inputs.
- Original per-answer logger remains RAM-only, while sleep transition logging writes only on lifecycle events.

## Remaining limits

- No actual Kindle/Android device test has been performed here.
- The trace cannot see all lower-level framebuffer operations, native firmware repaints, or physical e-ink ghosting.
- A trace frame may point to a caller rather than the first root cause; events need to be correlated with the user's reproduction time.
- Opening a popup during suspension from a separate plugin is observed but not suppressed.

**What to send after reproduction:** `settings/flipside/diagnostics.log`, possible `.1`/`.2` backups, and KOReader `crash.log`/`verbose.log` when present.
