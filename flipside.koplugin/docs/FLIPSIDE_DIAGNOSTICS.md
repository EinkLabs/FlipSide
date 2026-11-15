# FlipSide Diagnostics

FlipSide saves a detailed report when it detects a problem. The report is separate from your flashcard data and does not change the review schedule.

## Where to find reports

- `koreader/settings/flipside/diagnostics.log`
- Older reports: `diagnostics.log.1` and `diagnostics.log.2`
- KOReader's normal log: `koreader/crash.log` (when supported by your device)

The diagnostics file is created **only when an error or warning is detected**. Normal card taps do not write a log file.

## What a report contains

- Date and time
- Error level and an error code
- What failed and what data might be affected
- A possible next check (not an invented root cause)
- A sanitized Lua error and stack location
- A short list of recent FlipSide actions (without words or book sentences)

Detected issues include failed CRAM saves, unavailable or inconsistent saved queues, Undo recovery and statistics mismatches, Learning Analysis database errors, cloud sync failures and plugin startup failures.

## Privacy and storage

- No full words, book passages, WebDAV passwords, tokens, remote URLs or account IDs are deliberately collected.
- Error messages and stack locations are filtered, but **read the log before sharing it**. Other plugins and operating systems can include details we cannot fully control.
- When the log reaches about 128 KB, it is rotated. Up to two previous files are kept.
- Normal actions are recorded briefly in memory. Flash storage is used only when there is a warning or error.
- If logging itself fails, FlipSide continues its original operation and reports the log failure to KOReader when possible.

## Limitations

There is no way to automatically detect every bug. Errors with no exception or detectable invalid state may not appear in the log. A sudden power loss may prevent the newest report from reaching storage. A stack trace sometimes points to the error handler, rather than the actual cause. These reports help investigate problems; they do not prevent them or restore deleted data.

Keep the original `settings/flipside` folder and its database files. This diagnostics update does not reset any review data, CRAM progress, or Undo history.

## Kindle screensaver trace (v2)

This version also records the short sequence around sleep and wake, **even when no crash happens**. A normal study tap still does not write a trace.

Recorded events:

- `LIFECYCLE_SUSPEND`, `LIFECYCLE_PAUSED`: suspend signal and the state after review timers are paused.
- `LIFECYCLE_RESUME_SIGNAL`, `LIFECYCLE_OUT_OF_SAVER_SIGNAL`: wake signals (which can arrive before the cover disappears).
- `LIFECYCLE_RESUME_WAITING_FOR_COVER`: wake arrived, but the cover is still active.
- `LIFECYCLE_COVER_CLOSED`, `LIFECYCLE_FOREGROUND_REPAINT`: cover is gone and FlipSide is safe to repaint.
- `FLIPSIDE_DIRTY_WHILE_SLEEP`: a FlipSide caller requested a screen refresh while the cover was active. The trace includes the source filename, line, and call stack when Lua provides them.
- `OTHER_DIRTY_WHILE_SLEEP`: a refresh request from elsewhere in KOReader. This can be **normal** and is not by itself proof of a bug.
- `FLIPSIDE_DRAW_BLOCKED`: FlipSide refused to redraw while it was suspended.
- `FLIPSIDE_WINDOW_SHOWN_DURING_SLEEP` or `WINDOW_SHOWN_DURING_SLEEP`: a window was opened while the cover was active.

Every trace includes the current top window, up to six window types in the stack, number of open FlipSide dialogs, screensaver state, pending timer flags, and a short sanitized source traceback. It does **not** include words or full text from books.

### Reproducing the overlay problem

1. Back up `koreader/settings/flipside` and install this plugin ZIP. Do not delete the settings folder.
2. Open FlipSide on your Kindle, leave a floating popup open, and put the Kindle to sleep.
3. If you see FlipSide over the sleep cover, take a photo. Wake the Kindle normally.
4. Repeat once with the popup closed, if convenient.
5. Copy `koreader/settings/flipside/diagnostics.log`, any `.1` and `.2` files, and `koreader/crash.log` or `verbose.log` (if available). Send them together with the photos.

The trace is intentionally passive: it does not replace KOReader's screen-driver refresh function, suppress screensaver rendering, or change review data. One known popup hazard has been guarded: if CRAM checkpoint saving fails *during suspension*, the error dialog is delayed until FlipSide really returns to the foreground. The failure is still written to the diagnostic log.

### Important limits

Not every screen artifact is caused by a Lua redraw. Native Kindle firmware, a direct hardware screen update, or retained e-ink pixels may leave visible elements without calling the instrumented KOReader functions. In that case the trace can show that no FlipSide redraw was observed, but it cannot prove the hardware cause. A future reproduction with logs is necessary to distinguish these possibilities. Screen-saver diagnostics use a maximum of 14 detailed redraw reports per observation interval to limit e-ink device storage writes. The log rotates as before at about 128 KB with two backups. Review the trace before sharing if privacy is a concern.
