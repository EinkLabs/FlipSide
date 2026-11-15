# FlipSide for KOReader

**Vocabulary flashcards designed for e-ink.** Save words while reading, review them in different ways, and continue studying on another device.

<table><tr><td width="50%"><img src="docs/images/main-menu.jpg" alt="FlipSide review menu" width="290"><br><sub>Everything in one menu</sub></td><td width="50%"><img src="docs/images/smart-cram.jpg" alt="FlipSide Smart Cram options" width="290"><br><sub>Optional Smart Cram</sub></td></tr></table>

## Features at a glance

| Feature | What it does |
| --- | --- |
| **Three card styles** | Recall a meaning, retrieve a missing word from context, or review a sentence. |
| **Smart Cram** | Give extra practice to eligible words. Choose an intensity and when to cram. |
| **Learning Analysis** | View review accuracy, word categories and your study calendar. |
| **Dictionary meanings** | Select and save definitions, even from different dictionaries. |
| **Books & dates** | Choose which books or newly added words to review. |
| **Free practice** | Practise without changing your normal review dates. |
| **Sync** | Transfer supported data through Dropbox or WebDAV. |
| **Appearance** | Pick fonts, card borders and sentence sizes. |

## Install in 3 steps

1. Download the release ZIP. Back up `koreader/settings/flipside/` if updating.
2. Extract **`flipside.koplugin/`** into **`koreader/plugins/`**.
3. Restart KOReader and open **FlipSide** in the search (magnifier) menu. To bring in native Vocabulary Builder words, use **Aa → Import from Vocabulary Builder**.

## Save a dictionary meaning

Open a dictionary from a word, then switch **ON**, select the definition by holding and dragging, and tap **Save**. With **OFF**, the dictionary returns to normal KOReader interactions. Tap outside the dictionary to close it.

Use **Aa → Saved meanings** to manage definitions. The optional **Popup** setting during reading lets you see saved meanings before opening the regular dictionary. **Lock this position** is a separate feature.

**On a card:** tap the word for its dictionary in Meaning Recall; in Contextual Retrieval, first reveal the word, then long-press it. [Full short dictionary guide](docs/DICTIONARY.md).

## Quick tour

<details>
<summary><strong>Show more screenshots: filters, styles, calendar and study tools</strong></summary>

<table>
<tr><td><img src="docs/images/review-collections.jpg" alt="Select books and recently added words" width="280"><br><sub>Choose books and dates</sub></td><td><img src="docs/images/appearance-options.jpg" alt="Flashcard font and style options" width="280"><br><sub>Adjust fonts and card styles</sub></td></tr>
<tr><td><img src="docs/images/learning-analysis.jpg" alt="Learning Analysis categories" width="280"><br><sub>See learning progress</sub></td><td><img src="docs/images/advance-today.jpg" alt="Advance Today controls" width="280"><br><sub>Optionally advance eligible reviews</sub></td></tr>
<tr><td><img src="docs/images/study-calendar-month.jpg" alt="Monthly study calendar" width="280"><br><sub>Monthly study calendar</sub></td><td><img src="docs/images/study-calendar-week.jpg" alt="Weekly study calendar" width="280"><br><sub>Weekly study calendar</sub></td></tr>
</table>

</details>

## Before syncing or resetting

Sync one device at a time, and keep a separate backup: cloud synchronization is **not** a replacement for backup. **Advance Today** may move eligible reviews earlier; **Free practice** does not change due dates. Use **Undo** for a supported recent answer.

**Compatibility:** KOReader; behaviour may depend on device and KOReader version. For bugs, share your device type, KOReader version and *sanitized* logs — never credentials or personal databases.

**License:** [AGPL-3.0](COPYING). Based in part on KOReader's Vocabulary Builder; see [NOTICE](NOTICE.txt) and [upstream KOReader](https://github.com/koreader/koreader).
