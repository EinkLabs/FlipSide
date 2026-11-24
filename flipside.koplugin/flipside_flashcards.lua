--[[--
KOReader Vocabulary Builder - Flashcards v2.4.67 + native-theme broken-pill menus (protected learning / session-frozen native due queue, Advance Today queue, compact calendar/count popup; Vocabulary-wide e-ink feedback; unanswered-card back navigation; inline review-complete panel, history swipe, original safe Undo, native fine-bar statistics icon)

Install: replace koreader/patches/2-vocabbuilder-flashcards.lua and restart KOReader.
2026-11-08: persistent PER-CARD switch between Contextual Retrieval only
and Meaning Recall only. Unmodified cards retain the global review strategy.
2026-11-07 stability fix: always let the native Vocabulary Builder list be
registered with UIManager before displaying the full-screen flashcards.
Leaving flashcards through X closes the underlying list through the official
onClose() lifecycle. Leaving through List view keeps the list registered.
The original Vocabulary Builder hamburger menu is preserved, including its
List view action. Review accuracy is accessed with a small chart icon in the centered utility
pill, without modifying the native hamburger menu.
Review accuracy also provides a way to open the full Learning analysis menu.
Keeps the original list view, dictionary lookup, study-history actions, menu and
spaced-repetition algorithm. Independently reads all saved words (including
books hidden by the list's filter) with the real Vocabulary Builder DB schema.

Reviews automatically appear at their scheduled time while the screen stays
open (all intervals, including minutes, hours and days), without losing Undo.
Review: only words due now; Forgot / Got it update the Vocabulary Builder's
spaced repetition and persist each answer. Practice: study any saved word,
including words not due; responses never change the review schedule.
Swipe across the card to browse without answering or changing the review date.
Tap anywhere on the card except the word to reveal/hide its saved context;
tap the word for its dictionary entry.
Selected text is preserved inside its complete sentence when the companion
full-sentence v5.3 patch is installed. One tap outside the word toggles the
studied sentence; double tap anywhere except the dictionary word toggles the
ENTIRE saved context, with the same "..." at each boundary as the list view.
Long text scrolls instead of clipping under review keys.
Older v5.1/v5.2 entries cannot regain surrounding text already discarded.
Select multiple collections via the compact selector (Review words from).
Swipe on that selector to cycle through the selected collections; swipe on the
card itself to browse words. Selections and active collection are persisted.
Never Reviewed matches the Virtual Filters patch: cards with zero reviews,
zero streak and no review_time after creation, across every book/date.
All books excludes those untouched cards as well as today's and yesterday's
new words, like the virtual list filters. "Never Reviewed" is not removed from
those daily categories. This collection includes not-yet-due words for their
first actual review; Practice leaves progress unchanged. Undo restores
first-review eligibility.
Use the discreet Aa button next to the collection selector to choose
the font for all Flashcards-owned text: title, headword, card progress,
context, filters, review buttons, and custom settings menus.
Delete card (next to Undo) removes the current Vocabulary Builder word only
after confirmation. The remaining cards, filters, and Undo for other answers
stay available; deletion does not count as a review.
Dictionary lookups made from Flashcards omit Got it/Forgot buttons.
Undo requires confirmation. Forgotten cards receive one immediate, practice-only
reinforcement pass at the end of the review, without changing their already
scheduled native 5-minute review. The finish screen shows actual next due times.
Adaptive Dual Retrieval (off by default) is available in Aa > Review strategy.
It trains Meaning Recall first; after two spaced Got it ratings it alternates
scheduled reviews between Meaning Recall and Contextual Retrieval. Each review
uses ONE mode, not both: Recalled it / Did not recall record the native Got it /
Forgot response and advance to the next word, with the next mode selected on
the word's NEXT due review. Independent per-mode statistics are saved in a
LuaSettings file. Undo restores the native review and the matching statistics.
Meaning Recall only and Contextual Retrieval only are also available.
In contextual cards, one tap reveals or masks only the studied span,
without recomputing the sentence layout or moving its other words. It never
opens a separate word-only face and has no Reveal/Hide buttons. A double tap
expands/collapses complete saved context in either state. When revealed, a
long press in the card area opens the dictionary for the studied word.
Book titles are never displayed on review cards (Meaning Recall, Contextual
Retrieval, regular review, Practice, or missed-card reinforcement);
book metadata and collection filters are preserved. The active book title is
replaced by a generic label in the header while reviewing.
In the masked state, the selected word always remains hidden. Adaptive
eligibility uses ONLY past Meaning Recall answers tracked by this feature,
never a native streak predating activation. Card faces have no mode labels.
The size control (16-40, steps of 1) remains specific to the context sentence; all
other elements retain their proportional sizes. The Aa menu dynamically
lists fonts in the Kindle root fonts folder (/mnt/us/fonts), or KOReader's
fonts directory on other platforms. Settings are saved across restarts.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local ConfirmBox = require("ui/widget/confirmbox")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FontList = require("fontlist")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local IconWidget = require("ui/widget/iconwidget")
local IconButton = require("ui/widget/iconbutton")
local DataStorage = require("datastorage")
local GeneratedIcons = require("lib.ui.flipside_icon_store")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local CardButtonStyles = require("lib.cards.flipside_card_buttons")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Screen = Device.screen

if UIManager._flipside_flashcards_patched then
    return
end
UIManager._flipside_flashcards_patched = true

-- Shared state of the patch.
--   current:  the flashcard widget (nil when closed)
--   depth:    > 0 while the patch itself is touching the list (its own reloads
--             must not make the flashcards rebuild themselves)
--   menu_for: set while the flashcard menu is being opened, so the hook can add
--             the "List view" button to it
local Flash = { current = nil, depth = 0, menu_for = nil, auto_pending = nil }
Flash.saved_meanings = require("flipside_saved_meanings")

---------------------------------------------------------------- setting

-- Adaptive Dual Retrieval is an optional feature. Nothing changes until enabled.
local DUAL_STRATEGY_KEY = "flipside_flashcard_dual_strategy"
local DUAL_CARD_MODES_KEY = "flipside_flashcard_card_modes"
-- Sentence Card only must win over old per-card choices when selected as a
-- global strategy. Keep those old choices intact in their original setting:
-- only new manual taps while Sentence Card is active use this separate map.
local DUAL_SENTENCE_CARD_MODES_KEY = "flipside_flashcard_sentence_mode_overrides"
local DUAL_STATS_FILENAME = "flipside_dual_retrieval.lua"
-- This independent timer file is read by the companion Learning Audit patch.
-- Unlike SRS answers, study seconds include ONLY pending, genuine SRS
-- reviews; no practice, retry reinforcement, historical inspection or menus.
-- No stock Vocabulary DB changes.
local REVIEW_TIME_FILENAME = "flipside_review_time.lua"
local SETTING = "flipside_flashcard_mode"
-- FlipSide has no list mode: persist this invariant as well as enforcing it
-- in flashMode(), so old saved false values cannot re-enable the list later.
local function enforceFlashcardOnly()
    if G_reader_settings:readSetting(SETTING) ~= true then
        G_reader_settings:saveSetting(SETTING, true)
    end
end
enforceFlashcardOnly()
local FILTER_SETTING = "flipside_flashcard_filter"
local PRACTICE_SETTING = "flipside_flashcard_practice"
local SELECTED_FILTERS_SETTING = "flipside_flashcard_selected_filters"

-- v0.1.6 NON-DESTRUCTIVE UI REPAIR. v0.1.5 could restore a zero-card
-- Never Reviewed collection and the independent Practice toggle, making
-- existing cards look deleted. On first launch of this version, restore the
-- previous All books / Due landing screen. Preserve all other selected
-- collections and the private SQLite database, due times and audit history.
-- A versioned marker makes this a ONE-TIME repair: later user selections
-- are respected on every subsequent KOReader restart.
local VIEW_RECOVERY_MARKER = "flipside_view_recovery_v016"
local function restoreDefaultReviewViewOnce()
    if G_reader_settings:isTrue(VIEW_RECOVERY_MARKER) then return end
    local previous = G_reader_settings:readSetting(SELECTED_FILTERS_SETTING)
    local selected = { { kind = "all" } }
    local seen = { all = true }
    if type(previous) == "table" then
        for _, entry in ipairs(previous) do
            if type(entry) == "table" then
                local kind = entry.kind
                local book = entry.book
                local is_valid = kind == "today" or kind == "yesterday"
                    or kind == "never_reviewed"
                    or (kind == "book" and type(book) == "string" and book ~= "")
                if is_valid then
                    local key = kind .. "\0" .. (kind == "book" and book or "")
                    if not seen[key] then
                        seen[key] = true
                        selected[#selected + 1] = { kind = kind,
                            book = kind == "book" and book or nil }
                    end
                end
            end
        end
    end
    G_reader_settings:saveSetting(SELECTED_FILTERS_SETTING, selected)
    G_reader_settings:saveSetting(FILTER_SETTING, { kind = "all" })
    G_reader_settings:saveSetting(PRACTICE_SETTING, false)
    G_reader_settings:saveSetting(VIEW_RECOVERY_MARKER, true)
    G_reader_settings:flush()
    logger.info("FlipSide v0.1.6: restored All books / Due without changing any cards")
end
restoreDefaultReviewViewOnce()
-- Session-safe, day-scoped choice. Do not change SQLite due_time when enabled.
local ADVANCE_TODAY_SETTING = "flipside_flashcards_advance_today"
local INTENSIVE_MODE_SETTING = "flipside_intensive_mode_v1"
local INTENSIVE_TIMING_SETTING = "flipside_intensive_timing_v1"
local INTENSIVE_STATS_SETTING = "flipside_intensive_training_stats_v1"
local Intensive = require("flipside_intensive")
local CramStore = require("flipside_cram_store")
local Diag = require("flipside_diagnostics")
local SleepTrace = require("flipside_sleep_trace")

-- Flashcard typography. Keep the previous preference key so that updates from
-- v2.4.8 preserve the font already selected by the user. Only the text of
-- Flashcards-owned widgets is styled; the reader, external dictionary, stock
-- Vocabulary Builder list and their settings are never changed. The size
-- preference still controls only the expanded context sentence.
local SENTENCE_FONT_SETTING = "flipside_flashcard_sentence_font"
local SENTENCE_SIZE_SETTING = "flipside_flashcard_sentence_size"

-- Four visual-only themes. The sentence words, native bracket glyphs and
-- fixed-cloze renderer do NOT belong to themes. No extra Kindle-sized mode.
Flash.CARD_STYLE_SETTING = "flipside_flashcard_visual_style"
Flash.CARD_STYLES = {
    { id = "default", label = "Default (original)" },
    { id = "circuit", label = "Technical / circuit" },
    { id = "classic", label = "Classic / black header" },
    { id = "angular", label = "Angular / compact" },
}
function Flash.cardStyleLabel(id)
    for _, item in ipairs(Flash.CARD_STYLES) do
        if item.id == id then return item.label end
    end
    return Flash.CARD_STYLES[1].label
end
function Flash.storedCardStyle()
    local id = G_reader_settings:readSetting(Flash.CARD_STYLE_SETTING)
    for _, entry in ipairs(Flash.CARD_STYLES) do
        if entry.id == id then return id end
    end
    -- Obsolete styles map to Default; never touch card data or review times.
    if id ~= nil then
        G_reader_settings:saveSetting(Flash.CARD_STYLE_SETTING, "default")
        G_reader_settings:flush()
    end
    return "default"
end
Flash.Circuit = require("lib.cards.flipside_card_style_circuit")
Flash.Classic = require("lib.cards.flipside_card_style_classic")
Flash.Angular = require("lib.cards.flipside_card_style_angular")

-- The original KOReader text renderer is shared across ALL four styles.
-- This only narrows the text column enough to avoid drawing across a frame;
-- font size, glyph weight and baseline remain exactly as configured in Aa.
function Flash.cardContentWidth(style, width)
    if style == "circuit" then return math.floor(width * 0.86) end
    if style == "classic" or style == "angular" then
        return math.floor(width * 0.91)
    end
    return width
end

-- Default has no ornamental-frame cap; a later screen-bounds safety check
-- prevents exceptionally long text from crossing the top or bottom controls.
-- The three framed cards measure the space *actually available*
-- between their ornaments, and cap only the sentence's displayed font size.
-- No font preference is changed, and none of the cards has a scroll area.
function Flash.cardReadingBounds(style, width, height, margin, content_h)
    if style == "default" then
        return {w = width - 2 * margin,
            h = math.max(1, height - 2 * math.max(4, Size.padding.default))}
    end
    local side = math.max(Screen:scaleBySize(15), math.floor(margin * 0.76 + 0.5))
    local fw = width - 2 * side
    local frame_gap = math.min(Screen:scaleBySize(24),
        math.max(Screen:scaleBySize(15), math.floor(height * 0.04 + 0.5)))
    local avail = math.max(1, height - 2 * frame_gap)
    local natural = math.floor(fw * (style == "angular" and 0.85 or 0.93) + 0.5)
    local reserve = Screen:scaleBySize(style == "angular" and 105 or 116)
    local fh = math.min(avail, math.max(natural, content_h + reserve))
    -- A symmetric inner gutter leaves room for Classic's black title bar,
    -- Circuit's stepped corners, and Angular's double border at any height.
    local vertical_gutter = math.max(Screen:scaleBySize(38), math.floor(fh * 0.155))
    local horizontal_gutter = math.max(Screen:scaleBySize(15),
        math.floor(fw * (style == "circuit" and 0.062 or 0.035)))
    return {
        w = math.max(1, fw - 2 * horizontal_gutter),
        h = math.max(1, fh - 2 * vertical_gutter),
    }
end

-- These reserves track the THREE existing template decorators (which draw
-- their frames over a CenterContainer).  The total text stack is centered;
-- hence both the top and the bottom need at least the largest inset.
-- Classic has a fixed black heading at the top; Circuit has ornament/rails;
-- Angular has a double border and clipped corners.  This is the maximum
-- usable one-page text height, not an arbitrary word-count limit.
function Flash.framedContentBudget(style, screen_w, center_h, margin)
    if style == "default" then return nil end
    if style ~= "circuit" and style ~= "classic" and style ~= "angular" then
        return nil
    end
    local scale = function(n) return Screen:scaleBySize(n) end
    local side = math.max(scale(15), math.floor(margin * 0.76 + 0.5))
    local frame_w = math.max(1, screen_w - 2 * side)
    local frame_gap = math.min(scale(24),
        math.max(scale(15), math.floor(center_h * 0.04 + 0.5)))
    local available_h = math.max(1, center_h - 2 * frame_gap)
    local reserve
    if style == "classic" then
        -- Exact fixed-height formula from classic.decorateCenter() at the
        -- largest possible frame; keep original counter/header visible.
        local header = math.max(scale(30), math.floor(frame_w * 0.106))
        header = math.min(header, math.floor(available_h * 0.19))
        reserve = math.max(scale(116), 2 * (header + scale(12)))
    elseif style == "circuit" then
        reserve = math.max(scale(116), 2 * scale(61))
    else -- angular
        reserve = math.max(scale(105), 2 * scale(55))
    end
    return math.max(1, available_h - reserve)
end

-- Find the largest readable whole-number size, WITHOUT touching Aa. Called
-- for framed cards or a Default that exceeds its screen bounds. The measure
-- function uses real TextBoxWidget dimensions and also checks bracket width.
function Flash.findFramedSentenceSize(selected, minimum, fits)
    selected = math.max(1, math.floor(tonumber(selected) or 1))
    minimum = math.max(1, math.min(selected, math.floor(tonumber(minimum) or 10)))
    if fits(selected) then return selected end
    local lo, hi, best = minimum, selected - 1, minimum
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if fits(mid) then
            best = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return best
end

-- The displayed font names are friendly labels. The IDs remain unchanged to
-- preserve all previously saved selections from older versions of this patch.
-- On a Kindle, fonts may live in the native /mnt/us/fonts folder instead of
-- koreader/fonts. FontList intentionally knows only the folders configured for
-- KOReader; check both locations, without moving or changing users' fonts.
local SENTENCE_DEFAULT_FONT = "palr45w.ttf"
local SENTENCE_DEFAULT_SIZE = 21
local SENTENCE_MIN_SIZE, SENTENCE_MAX_SIZE, SENTENCE_STEP = 16, 40, 1
local SENTENCE_FONTS = {
    { id = "palr45w.ttf", label = "Palatino", aliases = { "palr45w", "palatino", "palatinolinotype" } },
    { id = "EB_Garamond", label = "EB Garamond", aliases = { "ebgaramond" } },
    { id = "Andika", label = "Andika", aliases = { "andika" } },
}

local sentence_fonts_scanned = false
local sentence_font_paths = {}
local function normalizedFontName(name)
    return (name or ""):lower():gsub("[^%w]", "")
end

local function sentenceFontMatchScore(path, option)
    if type(path) ~= "string" then return 0 end
    local name = path:match("([^/\\]+)$") or path
    local filename = normalizedFontName(name)
    local full = normalizedFontName(path)
    local score = 0
    local family_names = FontList.fontinfo[path]
    for _, alias in ipairs(option.aliases) do
        if filename == alias .. "ttf" or filename == alias .. "otf"
            or filename == alias .. "ttc" or filename == alias then
            score = math.max(score, 250)
        elseif filename:sub(1, #alias) == alias then
            score = math.max(score, 185)
        elseif full:find(alias, 1, true) then
            -- The actual font file may be named generically inside a family
            -- folder, e.g. /fonts/font-family/regular.ttf.
            score = math.max(score, 85)
        end
        if type(family_names) == "table" then
            for _, info in ipairs(family_names) do
                local family = normalizedFontName(info.name or "")
                if family == alias then
                    score = math.max(score, 230)
                elseif #alias >= 6 and family:find(alias, 1, true) then
                    score = math.max(score, 145)
                end
            end
        end
    end
    if score == 0 then return 0 end
    local lower = name:lower()
    if lower:find("regular", 1, true) or lower:find("roman", 1, true)
        or lower:find("book", 1, true) or lower:find("medium", 1, true) then
        score = score + 40
    elseif lower:find("bold", 1, true) or lower:find("italic", 1, true)
        or lower:find("oblique", 1, true) or lower:find("black", 1, true)
        or lower:find("semibold", 1, true) then
        score = score - 50
    end
    return score
end

local FONT_EXTENSIONS = {
    ttf = true, otf = true, ttc = true, cff = true, woff = true, woff2 = true,
}
local function scanSentenceFonts()
    if sentence_fonts_scanned then return end
    sentence_fonts_scanned = true
    local candidates, seen = {}, {}
    local function add(path)
        if type(path) == "string" and not seen[path] then
            seen[path] = true
            candidates[#candidates + 1] = path
        end
    end

    -- First: KOReader's own list, including externally registered fonts.
    local ok, paths = pcall(function() return FontList:getFontList() end)
    if ok and type(paths) == "table" then
        for _, path in ipairs(paths) do add(path) end
    else
        logger.warn("vocab flashcards: failed to enumerate KOReader fonts:", paths)
    end

    -- Second: actual Kindle user font folders, which FontList may not index.
    -- Check multiple common layouts; util.findFiles recurses into subfolders.
    local dirs, visited = {}, {}
    local function addDir(dir)
        if type(dir) == "string" and dir ~= "" and not visited[dir] then
            visited[dir] = true
            dirs[#dirs + 1] = dir
        end
    end
    addDir(FontList.fontdir)
    addDir("./fonts")
    addDir("../fonts")
    addDir("/mnt/us/fonts")
    addDir("/mnt/us/koreader/fonts")
    addDir("/mnt/us/koreader/data/fonts")
    local extras = os.getenv("EXT_FONT_DIR") or ""
    for dir in extras:gmatch("[^;]+") do addDir(dir) end
    for _, dir in ipairs(dirs) do
        local present, mode = pcall(lfs.attributes, dir, "mode")
        if present and mode == "directory" then
            local scanned, err = pcall(function()
                util.findFiles(dir, function(path, file)
                    local ext = type(file) == "string" and file:lower():match("%.([^.]+)$")
                    if ext and FONT_EXTENSIONS[ext] then add(path) end
                end)
            end)
            if not scanned then
                logger.warn("vocab flashcards: font folder unreadable:", dir, err)
            end
        end
    end

    for _, option in ipairs(SENTENCE_FONTS) do
        local scores = {}
        for _, path in ipairs(candidates) do
            local score = sentenceFontMatchScore(path, option)
            if score > 0 then scores[#scores + 1] = { path = path, score = score } end
        end
        table.sort(scores, function(a, b)
            if a.score == b.score then return a.path < b.path end
            return a.score > b.score
        end)
        -- A filename match alone doesn't guarantee FreeType can open it.
        -- Validate only matching candidates and prefer a working regular face.
        for _, match in ipairs(scores) do
            local face_ok, face = pcall(Font.getFace, Font, match.path, 18)
            if face_ok and face then
                sentence_font_paths[option.id] = match.path
                break
            end
        end
        if not sentence_font_paths[option.id] then
            logger.warn("vocab flashcards: could not resolve font:", option.label)
        end
    end
end

local function resolveSentenceFont(id)
    local chooser = require("flipside_font_picker")
    -- A path's existence is NOT enough. font.lua may reject it, return nil,
    -- and TextWidget/Button then crash when they getAdjustedFace(nil).
    if chooser.isRootId(id) then return chooser.renderable(id) end
    scanSentenceFonts()
    return sentence_font_paths[id]
end

local function getSentenceFace(id, size)
    local path = resolveSentenceFont(id)
    if path then
        local ok, face = pcall(Font.getFace, Font, path, size)
        if ok and face then return face end
    end
    -- Missing custom fonts must never prevent the flashcards from opening.
    return Font:getFace("cfont", size)
end

local function storedSentenceFont()
    local value = G_reader_settings:readSetting(SENTENCE_FONT_SETTING)
    if require("flipside_font_picker").isRootId(value) then
        if resolveSentenceFont(value) then return value end
        -- Self-healing: a removed/corrupt/incompatible font may have been
        -- persisted before this fix. Reset only this appearance preference;
        -- never modify the vocabulary DB or review records.
        logger.warn("FlipSide: restoring safe font after invalid saved choice", value)
        G_reader_settings:saveSetting(SENTENCE_FONT_SETTING, SENTENCE_DEFAULT_FONT)
        G_reader_settings:flush()
        return SENTENCE_DEFAULT_FONT
    end
    -- Keep legacy selections, so upgrading does not change existing cards.
    for _, option in ipairs(SENTENCE_FONTS) do
        if value == option.id then return value end
    end
    return SENTENCE_DEFAULT_FONT
end

local function storedSentenceSize()
    local value = tonumber(G_reader_settings:readSetting(SENTENCE_SIZE_SETTING))
    if value and value >= SENTENCE_MIN_SIZE and value <= SENTENCE_MAX_SIZE then
        return math.floor(value)
    end
    return SENTENCE_DEFAULT_SIZE
end

local function saveSentenceAppearance(font, size)
    G_reader_settings:saveSetting(SENTENCE_FONT_SETTING, font)
    G_reader_settings:saveSetting(SENTENCE_SIZE_SETTING, size)
    G_reader_settings:flush()
end

-- Text on Flashcards menus comes from KOReader's private MenuItem widget,
-- which does not expose a per-menu typeface argument. Scope the Font:getFace
-- substitution to the synchronous construction/update of OUR menus only.
-- The original method is always restored even if a widget throws an error;
-- no global UI font setting and no permanent monkeypatch are used.
local FLASH_MENU_FACE_ROLES = {
    cfont = true, smallinfofont = true, infont = true,
    smalltfont = true, x_smalltfont = true,
    x_smallinfofont = true, xx_smallinfofont = true,
}

local function withFlashFont(font_id, build)
    local path = resolveSentenceFont(font_id)
    if not path then return build() end
    local saved_get_face = Font.getFace
    Font.getFace = function(font, name, size, faceindex)
        if type(name) == "string" and FLASH_MENU_FACE_ROLES[name] then
            -- Preserve the requested role's default point size; passing an
            -- external filename without size has no entry in Font.sizemap.
            local actual_size = size or Font.sizemap[name] or Font.sizemap.cfont or 17
            local loaded, face = pcall(saved_get_face, font, path, actual_size, faceindex)
            if loaded and face then return face end
            -- Never expose a nil custom face to KOReader UI widgets.
        end
        return saved_get_face(font, name, size, faceindex)
    end
    local ok, result = pcall(build)
    Font.getFace = saved_get_face
    if not ok then error(result, 0) end
    return result
end

-- The three Flashcards-owned settings menus now use the very same *native*
-- FrameContainer stroke, radius and grayscale palette as the filter/Aa/Due
-- pill in Flashcards:_render(). No custom arc drawing, hole erasure, root
-- inversion or global KOReader widget monkey-patching.
--
-- This is presentation only: retain MenuItem, native title/close, KOReader
-- pagination controls, and the original selection/cancel/Done callbacks.
local FlashMenu = Menu:extend{}
-- KOReader's stock Menu:onSwipe sends "full" on diagonal gestures.
-- Keep all normal menu actions, but do not allow menu-local full refresh.
function FlashMenu:onSwipe(arg, ges)
    local direction = ges and ges.direction
    if direction ~= "north" and direction ~= "south"
            and direction ~= "west" and direction ~= "east" then
        return true
    end
    return Menu.onSwipe(self, arg, ges)
end
local FLASH_MENU_BORDER = math.max(1, Size.border.thin)
local FLASH_MENU_COLOR = Blitbuffer.COLOR_DARK_GRAY
local FLASH_MENU_ROW_X = math.max(3, Screen:scaleBySize(7))
local FLASH_MENU_ROW_Y = math.max(2, Screen:scaleBySize(4))

-- This is exactly the FrameContainer construction technique used by the
-- Flashcards header pill. The empty content reserves the *existing* drawing
-- rectangle: these borders do not increase row sizes or touch-target sizes.
-- The native FrameContainer painter handles all curved pixels and e-ink AA.
local function flashNativeCapsule(width, height, background)
    if width < 12 or height < 12 then return nil end
    local stroke = FLASH_MENU_BORDER
    if width <= 2 * stroke or height <= 2 * stroke then return nil end
    local empty = Widget:new{
        dimen = Geom:new{w=width-2*stroke, h=height-2*stroke},
    }
    return FrameContainer:new{
        bordersize=stroke, padding=0, margin=0,
        radius=math.floor((height-2*stroke)/2),
        color=FLASH_MENU_COLOR,
        background=background,
        empty,
    }
end

-- Keep the stock button (including its callback and disabled status) and
-- draw the exact same native Flashcards capsule around it. In particular,
-- the bottom pager's buttons have ZERO border in KOReader; changing their
-- bordersize would invalidate their calculated geometry and clip them.
local function flashStylePagerButton(button, is_arrow, gap)
    if not button or not button.frame then return end
    local frame = button.frame
    if frame._flash_native_pill then return end
    frame._flash_native_pill = true
    local original_paint = frame.paintTo
    local size = frame:getSize()
    local px, py, pw, ph
    if is_arrow then
        -- Circular buttons, centered inside their unchanged hit rectangles.
        local d = math.min(size.w, size.h) - math.max(2, Screen:scaleBySize(3)) * 2
        pw, ph = d, d
        px, py = math.floor((size.w-d)/2), math.floor((size.h-d)/2)
    else
        -- Use the free KOReader spacing between chevrons to give the page
        -- label a wider, true capsule. No more border touching its letters.
        local extra = math.min(math.max(4, Screen:scaleBySize(7)),
            math.max(0, math.floor((gap or Screen:scaleBySize(32)) / 2)))
        px, py = -extra, math.max(2, Screen:scaleBySize(3))
        pw, ph = size.w + 2*extra, size.h - 2*py
    end
    local pill = flashNativeCapsule(pw, ph, nil)
    frame.paintTo = function(container, bb, x, y)
        original_paint(container, bb, x, y)
        if not button.hidden and pill then
            pill:paintTo(bb, x+px, y+py)
        end
    end
end

function FlashMenu:_applyNativeFlashcardsPills()
    -- The stock menus and the real Flashcards pill use KOReader's normal
    -- white canvas. Inverse/night mode is handled by the device, NOT here.
    for _, row in ipairs(self.item_group or {}) do
        local frame = row[1]
        if frame and not frame._flash_native_pill then
            frame._flash_native_pill = true
            local size = frame:getSize()
            local w = size.w-2*FLASH_MENU_ROW_X
            local h = size.h-2*FLASH_MENU_ROW_Y
            -- The filter bar itself uses background=COLOR_WHITE. Paint this
            -- native frame BEFORE the original MenuItem so its text is never
            -- masked, and no leftover hand-painted pixels linger on an e-ink
            -- partial refresh. Selected/unselected text remains KOReader's.
            local pill = flashNativeCapsule(w, h, Blitbuffer.COLOR_WHITE)
            local original_paint = frame.paintTo
            frame.paintTo = function(container, bb, x, y)
                if pill then
                    pill:paintTo(bb, x+FLASH_MENU_ROW_X, y+FLASH_MENU_ROW_Y)
                end
                original_paint(container, bb, x, y)
            end
        end
    end

    flashStylePagerButton(self.page_info_first_chev, true)
    flashStylePagerButton(self.page_info_left_chev, true)
    flashStylePagerButton(self.page_info_text, false,
        self.page_info_spacer and self.page_info_spacer.width)
    flashStylePagerButton(self.page_info_right_chev, true)
    flashStylePagerButton(self.page_info_last_chev, true)

    -- The X is the original TitleBar IconButton. Its hit box and onClose
    -- remain untouched; the outline is a real native FrameContainer circle.
    local close_icon = self.title_bar and self.title_bar.right_button
        and self.title_bar.right_button.image
    if close_icon and not close_icon._flash_native_pill then
        close_icon._flash_native_pill = true
        local original_paint = close_icon.paintTo
        local dim = close_icon:getSize()
        local pad = math.max(2, Screen:scaleBySize(4))
        local d = math.max(dim.w, dim.h)+2*pad
        local circle = flashNativeCapsule(d, d, nil)
        local dx,dy = math.floor((dim.w-d)/2),math.floor((dim.h-d)/2)
        close_icon.paintTo = function(icon, bb, x, y)
            original_paint(icon, bb, x, y)
            if circle then circle:paintTo(bb, x+dx, y+dy) end
        end
    end
end

-- KOReader rebuilds its menu items after selecting fonts, checking books or
-- changing review strategies. Restyle those NEW native widgets after each
-- update, while restoring the font substitution to avoid leaking to menus.
function FlashMenu:updateItems(select_number, no_recalculate_dimen)
    local owner = self.flash_font_owner
    return withFlashFont(owner and owner.sentence_font or storedSentenceFont(), function()
        local result = Menu.updateItems(self, select_number, no_recalculate_dimen)
        require("lib.ui.flipside_pager_bounds").fit(self)
        self:_applyNativeFlashcardsPills()
        return result
    end)
end

local function newFlashMenu(owner, settings)
    settings.flash_font_owner = owner
    settings.items_font_size = 17
    settings.items_mandatory_font_size = 17
    settings.title_face = getSentenceFace(owner.sentence_font, 24)
    -- Hide ONLY the stock row underlines; our native capsule replaces them.
    -- Nothing else is changed in the KOReader theme (light or dark).
    settings.line_color = Blitbuffer.COLOR_WHITE
    return withFlashFont(owner.sentence_font, function()
        return FlashMenu:new(settings)
    end)
end

local function newFlashInfo(owner, settings)
    local font_id = owner and owner.sentence_font or storedSentenceFont()
    return withFlashFont(font_id, function()
        return InfoMessage:new(settings)
    end)
end

-- Publish only a tiny, read-only typography bridge for the companion
-- Learning Audit. Its UI gets the same installed face selected in Flashcards,
-- without changing any KOReader-wide font or overriding the card sentence size.
-- Resolve it on every call so switching the font takes effect on next opening.
package.loaded["flipside_flashcard_typography"] = {
    face = function(size)
        return getSentenceFace(storedSentenceFont(), size or 17)
    end,
    name = function()
        return resolveSentenceFont(storedSentenceFont()) or "cfont"
    end,
}

local function storedFilter()
    local saved = G_reader_settings:readSetting(FILTER_SETTING)
    if type(saved) == "table" then
        local kind = saved.kind
        if kind == "all" or kind == "today" or kind == "yesterday"
                or kind == "never_reviewed" then
            return { kind = kind }
        end
        if kind == "book" and type(saved.book) == "string" then
            return { kind = kind, book = saved.book }
        end
    end
    return { kind = "all" }
end

local function saveFilter(filter)
    G_reader_settings:saveSetting(FILTER_SETTING, {
        kind = filter.kind,
        book = filter.kind == "book" and filter.book or nil,
    })
    G_reader_settings:flush()
end

local function validFilter(filter)
    if type(filter) ~= "table" then return false end
    if filter.kind == "all" or filter.kind == "today" or filter.kind == "yesterday"
            or filter.kind == "never_reviewed" then
        return true
    end
    return filter.kind == "book" and type(filter.book) == "string" and filter.book ~= ""
end

local function saveSelectedFilters(filters)
    local out = {}
    for _, filter in ipairs(filters) do
        out[#out + 1] = {
            kind = filter.kind,
            book = filter.kind == "book" and filter.book or nil,
        }
    end
    G_reader_settings:saveSetting(SELECTED_FILTERS_SETTING, out)
    G_reader_settings:flush()
end

local function storedSelectedFilters()
    local saved = G_reader_settings:readSetting(SELECTED_FILTERS_SETTING)
    if type(saved) ~= "table" then return { storedFilter() } end
    local out = {}
    local seen = {}
    for _, filter in ipairs(saved) do
        if validFilter(filter) then
            local key = filter.kind .. "\0" .. (filter.book or "")
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = { kind = filter.kind, book = filter.book }
            end
        end
    end
    return #out > 0 and out or { storedFilter() }
end

local function storedPractice()
    return G_reader_settings:isTrue(PRACTICE_SETTING)
end

local function savePractice(practice)
    G_reader_settings:saveSetting(PRACTICE_SETTING, practice and true or false)
    G_reader_settings:flush()
end

local function localDayKey()
    return os.date("%Y-%m-%d")
end

-- Preserve the chosen mode and placement across KOReader restarts. The
-- SRS database is never written by these choices or by a training answer.
local function storedIntensiveMode()
    local value = G_reader_settings:readSetting(INTENSIVE_MODE_SETTING)
    return (value == "intensive" or value == "ultra") and value or "off"
end
local function storedIntensiveTiming()
    return G_reader_settings:readSetting(INTENSIVE_TIMING_SETTING) == "during"
        and "during" or "after"
end
local function saveIntensivePreferences(mode, timing)
    G_reader_settings:saveSetting(INTENSIVE_MODE_SETTING, mode)
    G_reader_settings:saveSetting(INTENSIVE_TIMING_SETTING, timing)
    G_reader_settings:flush()
end
local function saveIntensiveAttempt(mode, got)
    local value = G_reader_settings:readSetting(INTENSIVE_STATS_SETTING)
    if type(value) ~= "table" then value = {} end
    local bucket = value[mode]
    if type(bucket) ~= "table" then bucket = {correct=0, missed=0} end
    bucket.correct = math.max(0, tonumber(bucket.correct) or 0) + (got and 1 or 0)
    bucket.missed = math.max(0, tonumber(bucket.missed) or 0) + (got and 0 or 1)
    value[mode] = bucket
    G_reader_settings:saveSetting(INTENSIVE_STATS_SETTING, value)
end

-- Recent repeated errors: use ONLY the independent Learning Audit database.
-- Missing/unreadable history safely means no additional Ultra candidates.
-- Hidden, undone, and archived official reviews must never reappear here.
-- Read the verified merged Learning Analysis events through its own API.
-- This includes synced answers, Undo and reset masks; do NOT recreate a
-- separate SQLite query that quietly skips part of the user's history.
local function recentRecurringErrors()
    local bridge = package.loaded["flipside_learning_audit_bridge"]
    if type(bridge) ~= "table" or
            type(bridge.getRecentCramErrors) ~= "function" then
        logger.warn("FlipSide cram: Learning Analysis history bridge unavailable")
        Diag.report("WARNING", "LEARNING_AUDIT_ERROR", {stage="history_bridge"}, "Learning Analysis bridge unavailable")
        return {}, {unavailable = true, reason = "Learning Analysis history bridge unavailable"}
    end
    local ok, words, meta, err = pcall(bridge.getRecentCramErrors, 7, 2, 40)
    if not ok or type(words) ~= "table" then
        local reason = not ok and tostring(words) or tostring(err or "History unavailable")
        logger.warn("FlipSide cram: cannot retrieve recent error history:", reason)
        Diag.report("WARNING", "LEARNING_AUDIT_DB_FAILED", {stage="recent_errors"}, reason)
        return {}, {unavailable = true, reason = reason}
    end
    if type(meta) ~= "table" then meta = {} end
    return words, meta
end

local function storedAdvanceToday()
    local saved = G_reader_settings:readSetting(ADVANCE_TODAY_SETTING)
    return type(saved) == "table" and saved.enabled == true
        and saved.day == localDayKey()
end

local function saveAdvanceToday(enabled)
    G_reader_settings:saveSetting(ADVANCE_TODAY_SETTING,
        {enabled=enabled == true, day=localDayKey()})
    G_reader_settings:flush()
end

-- The original Vocabulary Builder SQLite database remains untouched. These
-- independent counters do not control the stock due_time calculation.
local DUAL_STRATEGIES = {
    off = "Off (original flashcards)",
    adaptive = "Adaptive Dual Retrieval",
    meaning = "Meaning Recall only",
    contextual = "Contextual Retrieval only",
    sentence = "Sentence Card only",
}
local DUAL_STRATEGY_ORDER = { "off", "adaptive", "meaning", "contextual", "sentence" }
local function storedDualStrategy()
    local strategy = G_reader_settings:readSetting(DUAL_STRATEGY_KEY)
    return DUAL_STRATEGIES[strategy] and strategy or "off"
end
local function saveDualStrategy(strategy)
    if not DUAL_STRATEGIES[strategy] then return false end
    G_reader_settings:saveSetting(DUAL_STRATEGY_KEY, strategy)
    G_reader_settings:flush()
    return true
end

-- Manual choices are stored by the Vocabulary Builder's unique word key.
-- The Aa > Review strategy setting remains the default for untouched cards.
local function storedCardModes(setting_key)
    local saved = G_reader_settings:readSetting(setting_key or DUAL_CARD_MODES_KEY)
    local modes = {}
    if type(saved) == "table" then
        for word, mode in pairs(saved) do
            if type(word) == "string" and word ~= ""
                    and (mode == "meaning" or mode == "contextual"
                        or mode == "sentence") then
                modes[word] = mode
            end
        end
    end
    return modes
end

-- Avoid global hooks, SQLite schema modifications, and filesystem writes on
-- every e-ink redraw. Only completed real reviews save progress here.
local DualStats = { loaded = false, settings = nil, words = {} }
local function loadDualStats()
    if DualStats.loaded then return DualStats.words end
    DualStats.loaded = true
    local ok_require, LuaSettings = pcall(require, "luasettings")
    if ok_require and type(LuaSettings) == "table" then
        local ok, settings = pcall(function()
            local DataStorage = require("datastorage")
            return LuaSettings:open(DataStorage:getSettingsDir() .. "/flipside/" .. DUAL_STATS_FILENAME)
        end)
        if ok and settings then
            DualStats.settings = settings
            local read_ok, words = pcall(settings.readSetting, settings, "words")
            if read_ok and type(words) == "table" then DualStats.words = words end
        else
            logger.warn("vocab flashcards: retrieval history file unavailable:", settings)
        end
    else
        logger.warn("vocab flashcards: LuaSettings unavailable for retrieval history")
    end
    return DualStats.words
end
local function copyDualEntry(entry)
    if type(entry) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(entry) do
        if type(v) == "number" or type(v) == "boolean" then
            out[k] = v
        elseif (k == "recent_meaning" or k == "recent_context") and type(v) == "table" then
            local recent = {}
            for i = 1, math.min(#v, 6) do
                if v[i] == 0 or v[i] == 1 then recent[#recent + 1] = v[i] end
            end
            out[k] = recent
        end
    end
    return out
end
local function dualEntryFor(word)
    return loadDualStats()[word]
end
-- Save failures must be reported as failures, not swallowed by pcall().
-- Keep an in-memory snapshot for undo and restore it on failed writes.
local function persistDualStats()
    if not DualStats.settings then
        logger.warn("vocab flashcards: retrieval history settings unavailable")
        return false
    end
    local ok, result = pcall(function()
        DualStats.settings:saveSetting("adaptive_schema_version", 2)
        DualStats.settings:saveSetting("words", DualStats.words)
        return DualStats.settings:flush()
    end)
    if not ok or result == false then
        logger.warn("vocab flashcards: retrieval stats save failed:", result)
        return false
    end
    return true
end
local function removeDualEntry(word)
    if not word then return true end
    local words = loadDualStats()
    if not words[word] then return true end
    local previous = words[word]
    words[word] = nil
    if persistDualStats() then return true end
    words[word] = previous
    return false
end

local function appendRecent(entry, field, got)
    local recent = entry[field]
    if type(recent) ~= "table" then recent = {} end
    -- Historical totals remain untouched on migration; recent evidence begins
    -- accumulating after the update, avoiding bogus percentages from old data.
    recent[#recent + 1] = got and 1 or 0
    while #recent > 6 do table.remove(recent, 1) end
    entry[field] = recent
end
local function recentAccuracy(entry, field)
    local recent = entry and entry[field]
    if type(recent) ~= "table" or #recent < 3 then return nil end
    local hits = 0
    for _, value in ipairs(recent) do
        if value == 1 then hits = hits + 1 end
    end
    return hits / #recent
end
-- Adaptive targets deliberately remain coarse, bounded and conservative:
-- meaning difficulty => more Meaning checks; good meaning but weak contextual
-- => a contextual check after one fresh Meaning success. Every word starts
-- with TWO successful Meaning reviews, regardless of historical native streak.
local function adaptiveMeaningTarget(entry)
    if not entry or (tonumber(entry.context_total) or 0) == 0 then return 2 end
    local meaning = recentAccuracy(entry, "recent_meaning")
    local context = recentAccuracy(entry, "recent_context")
    if meaning and meaning < 0.70 then return 3 end
    if meaning and meaning >= 0.80 and context and context < 0.60 then return 1 end
    if meaning and meaning >= 0.85 and context and context >= 0.75 then return 3 end
    return 2
end
-- Each native scheduled review produces exactly ONE mode result.
local function updateDualEntry(card, got, mode)
    local words = loadDualStats()
    local previous = copyDualEntry(words[card.word])
    local entry = copyDualEntry(previous) or {}
    if mode == "contextual" then
        entry.context_total = (tonumber(entry.context_total) or 0) + 1
        if got then
            entry.context_correct = (tonumber(entry.context_correct) or 0) + 1
        else
            entry.meaning_streak = 0
        end
        entry.meaning_since_context = 0
        appendRecent(entry, "recent_context", got)
    else
        entry.meaning_total = (tonumber(entry.meaning_total) or 0) + 1
        if got then
            entry.meaning_correct = (tonumber(entry.meaning_correct) or 0) + 1
            entry.meaning_streak = (tonumber(entry.meaning_streak) or 0) + 1
            entry.meaning_since_context = math.min(3,
                (tonumber(entry.meaning_since_context) or 0) + 1)
        else
            entry.meaning_streak = 0
            entry.meaning_since_context = 0
        end
        appendRecent(entry, "recent_meaning", got)
    end
    words[card.word] = entry
    if not persistDualStats() then
        words[card.word] = previous
        return false
    end
    card._dual_before = previous
    return true
end
local function restoreDualEntry(card)
    if card._dual_before == nil and not card._dual_had_update then return true end
    local words = loadDualStats()
    local current = copyDualEntry(words[card.word])
    words[card.word] = copyDualEntry(card._dual_before)
    if not persistDualStats() then
        words[card.word] = current
        return false
    end
    card._dual_before = nil
    card._dual_had_update = nil
    return true
end

-- Study time is recorded by the Flashcards UI and read by Learning Audit.
-- Keep independent daily and lifetime totals so changing statistics filters
-- cannot overwrite or reinterpret the review history. A separate file also
-- makes it possible to upgrade either patch without migrating the other.
local ReviewClock = { settings = nil, data = nil, dirty = false }
local function loadReviewClock()
    if ReviewClock.data then return ReviewClock.data end
    local data = { schema = 1, totals = {}, days = {} }
    local ok, settings_or_error = pcall(function()
        local LuaSettings = require("luasettings")
        local DataStorage = require("datastorage")
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/flipside/" .. REVIEW_TIME_FILENAME)
    end)
    if ok and settings_or_error then
        ReviewClock.settings = settings_or_error
        local read_ok, saved = pcall(ReviewClock.settings.readSetting,
            ReviewClock.settings, "clock_v1")
        if read_ok and type(saved) == "table" then
            data.totals = type(saved.totals) == "table" and saved.totals or {}
            data.days = type(saved.days) == "table" and saved.days or {}
        end
    else
        logger.warn("vocab flashcards: study timer storage unavailable:", settings_or_error)
    end
    ReviewClock.data = data
    return data
end

local function addReviewSeconds(mode, seconds, stamp)
    if seconds <= 0 then return end
    local data = loadReviewClock()
    local day = os.date("%Y-%m-%d", stamp)
    local bucket = data.days[day]
    if type(bucket) ~= "table" then bucket = {}; data.days[day] = bucket end
    local category = mode == "meaning" and "meaning"
        or (mode == "contextual" and "contextual"
        or (mode == "sentence" and "sentence" or "other"))
    data.totals.all = (tonumber(data.totals.all) or 0) + seconds
    data.totals[category] = (tonumber(data.totals[category]) or 0) + seconds
    bucket.all = (tonumber(bucket.all) or 0) + seconds
    bucket[category] = (tonumber(bucket[category]) or 0) + seconds
    ReviewClock.dirty = true
end

local function saveReviewClock()
    if not ReviewClock.dirty then return true end
    if not ReviewClock.settings then
        logger.warn("vocab flashcards: cannot save study time without settings")
        return false
    end
    local ok, result = pcall(function()
        ReviewClock.settings:saveSetting("clock_v1", loadReviewClock())
        return ReviewClock.settings:flush()
    end)
    if not ok or result == false then
        logger.warn("vocab flashcards: failed to persist study time:", result)
        return false
    end
    ReviewClock.dirty = false
    return true
end

local function flashMode()
    -- FlipSide has one and only one main screen: flashcards.
    return true
end

local function setFlashMode(_)
    -- Compatibility guard: no caller may disable FlipSide's flashcards.
    enforceFlashcardOnly()
end

local function flashShown()
    return Flash.current ~= nil and UIManager:isWidgetShown(Flash.current)
end

---------------------------------------------------------------- dictionary popup
-- Do not rewrite the native dictionary's ButtonTable or hide Vocabulary
-- Builder controls. Both plugins register their own independent buttons.
-- In particular, the native Add to vocabulary builder button must retain
-- its own callback even when a FlipSide flashcard opened the dictionary.

---------------------------------------------------------------- helpers

-- Runs fn while marking the list as "being touched by the patch".
local function guarded(fn, ...)
    Flash.depth = Flash.depth + 1
    local ok, a, b = pcall(fn, ...)
    Flash.depth = Flash.depth - 1
    if not ok then
        error(a, 0)
    end
    return a, b
end

-- The running ReaderUI (book open) or FileManager.
local function getUI()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and type(ReaderUI) == "table" and ReaderUI.instance then
        return ReaderUI.instance
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and type(FileManager) == "table" and FileManager.instance then
        return FileManager.instance
    end
    return nil
end

local function getPlugin()
    local ui = getUI()
    -- The registered KOReader plugin is named vocabulary_builder.
    -- Keep the older alias for builds/patches using a different field.
    local plugin = ui and ui.flipside
    if type(plugin) == "table" then
        return plugin
    end
    return nil
end

-- The Vocabulary builder list window.
local function isListWidget(w)
    -- Never hook a list from KOReader's original Vocabulary Builder.
    -- This is a private backing widget inside the FlipSide engine.
    if type(w) ~= "table" then return false end
    local plugin = getPlugin()
    return type(plugin) == "table" and w.vocabbuilder == plugin
        and type(w.reloadItems) == "function"
        and type(w.onShowMenu) == "function"
end


-- Scoped e-ink touch feedback for Vocabulary Builder and its companion dialogs.
-- KOReader v2026.07.2 Button:onTapSelectButton temporarily inverts the entire
-- native button and forces at least one separate hardware refresh.  The
-- unhighlight can be lost when a modal is opened; this is the black rectangle
-- left behind on the Kindle.  Crucially, leave buttons in the READER, file
-- manager, settings etc. completely unchanged, including their input logic.
local native_button_tap = Button.onTapSelectButton
local function vocabHasFocus()
    local top = UIManager:getTopmostVisibleWidget()
    local hops = 0
    while type(top) == "table" and hops < 7 do
        if top._vocab_no_flash_surface or top == Flash.current
            or isListWidget(top)
            or (type(top.vocabbuilder) == "table"
                and isListWidget(top.vocabbuilder)) then
            return true
        end
        top = top.show_parent
        hops = hops + 1
    end
    return false
end

local function noHighlightTap(button)
    -- Mirror the native KOReader Button callback/tap_input/checked_func
    -- contract, omitting ONLY the temporary highlight and forced repaints.
    if button.enabled or button.allow_tap_when_disabled then
        if button.callback then
            button.callback()
            if button.checked_func and not button.no_refresh_checkmark then
                local label = button:getDisplayText()
                if button.label_widget and button.label_widget.setText then
                    button.label_widget:setText(label)
                end
                if button.refresh then button:refresh() end
            end
        elseif button.tap_input then
            button:onInput(button.tap_input)
        elseif button.tap_input_func then
            button:onInput(button.tap_input_func())
        end
    end
    if button.readonly ~= true then return true end
end
Button.onTapSelectButton = function(button, ...)
    if button._vocab_no_feedback or vocabHasFocus() then
        return noHighlightTap(button)
    end
    return native_button_tap(button, ...)
end

-- The title bar's X, menu and other icon-only actions use IconButton,
-- which has a separate inversion/forceRePaint path from Button. Keep its
-- normal callback behavior, but don't flash for active Vocabulary UI.
local native_icon_button_tap = IconButton.onTapIconButton
IconButton.onTapIconButton = function(icon_button, ...)
    if vocabHasFocus() then
        if not icon_button.callback then return end
        icon_button.callback()
        return true
    end
    return native_icon_button_tap(icon_button, ...)
end

-- The native Vocabulary word LIST uses MenuItem, not Button.  Patch only
-- actual Vocabulary Builder / Flashcards / Learning Audit menu instances,
-- and retain their original event propagation and KOReader highlight elsewhere.
local function markVocabMenuItems(menu)
    if type(menu.item_group) ~= "table" then return end
    for _, item in ipairs(menu.item_group) do
        if type(item) == "table" and item.menu == menu
                and not item._vocab_no_feedback_item then
            item._vocab_no_feedback_item = true
            item.onTapSelect = function(row, _arg, ges)
                if not row[1] or not row[1].dimen or not ges or not ges.pos then
                    return
                end
                row.menu:onMenuSelect(row.entry, row:getGesPosition(ges))
                return true
            end
            item.onHoldSelect = function(row, _arg, ges)
                if not row[1] or not row[1].dimen or not ges or not ges.pos then
                    return
                end
                row.menu:onMenuHold(row.entry, row:getGesPosition(ges))
                return true
            end
        end
    end
end
local native_menu_update_items = Menu.updateItems
Menu.updateItems = function(menu, ...)
    local result = native_menu_update_items(menu, ...)
    if isListWidget(menu) or menu.flash_font_owner
            or menu._vocab_no_flash_surface
            or (type(menu.show_parent) == "table"
                and menu.show_parent._vocab_no_flash_surface) then
        markVocabMenuItems(menu)
    end
    return result
end

-- The topmost Vocabulary builder list window currently on screen, if any.
local function findListInStack()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then
        return nil
    end
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if type(w) == "table" and isListWidget(w) then
            return w
        end
    end
    return nil
end

-- Depth-first search for the row widgets (VocabItemWidget) of the list window.
local function collectItemWidgets(node, out, depth)
    if type(node) ~= "table" or depth > 10 then
        return
    end
    if type(node.item) == "table" and type(node.onGotIt) == "function"
            and type(node.onForgot) == "function" then
        table.insert(out, node)
        return
    end
    for i = 1, #node do
        collectItemWidgets(node[i], out, depth + 1)
    end
end

local function getPageCount(w)
    if type(w.pages) == "number" and w.pages >= 1 then
        return w.pages
    end
    local per = w.items_per_page or w.perpage
    if type(per) == "number" and per > 0 and type(w.item_table) == "table" then
        return math.max(1, math.ceil(#w.item_table / per))
    end
    return 1
end

local function setPage(w, page)
    if type(w._populateItems) == "function" then
        w.show_page = page
        w:_populateItems()
    end
end

-- Does the list hold data? And is anything due in it?
--   "missing":  no items at all (data not loaded yet, or nothing saved)
--   "none_due": there are words, but none is due for review
--   "has_due":  at least one word is due
local function tableState(w)
    local t = w.item_table
    if type(t) ~= "table" or #t == 0 then
        return "missing"
    end
    local now = os.time()
    for i = 1, #t do
        local it = t[i]
        if type(it) == "table" and type(it.due_time) == "number" and it.due_time <= now then
            return "has_due"
        end
    end
    return "none_due"
end

-- When the word was added to the Vocabulary builder (seconds), or nil when the
-- item has no such field. The first call logs the field names of an item.
-- Must agree with Virtual Filters' NEVER_REVIEWED_SQL:
-- review_count = 0 AND streak_count = 0 AND IFNULL(review_time,0) <= create_time.
-- An inserted word normally has review_time == create_time, which is NOT a review.
local function isNeverReviewed(review_count, streak_count, review_time, create_time)
    local added_at = tonumber(create_time)
    return added_at ~= nil
        and tonumber(review_count) == 0
        and tonumber(streak_count) == 0
        and (tonumber(review_time) or 0) <= added_at
end

local fields_logged = false
local function itemCreated(it)
    if not fields_logged then
        fields_logged = true
        local keys = {}
        for k, v in pairs(it) do
            if type(k) == "string" then
                if type(v) == "number" or (type(v) == "string" and #v <= 24) then
                    table.insert(keys, k .. "=" .. tostring(v))
                else
                    table.insert(keys, k)
                end
            end
        end
        table.sort(keys)
        logger.info("vocab flashcards: item fields:", table.concat(keys, ", "))
    end
    for _i, key in ipairs({ "create_time", "created_time", "add_time", "time" }) do
        local v = tonumber(it[key])
        if v and v > 0 then
            if v > 1e11 then
                v = v / 1000
            end
            return v
        end
    end
    return nil
end

-- Collect the words that are due for review (same rule the list uses to show
-- the Forgot / Got it buttons), in list order.
local function buildDeck(w)
    local pages = getPageCount(w)
    local original_page = w.show_page
    local now = os.time()
    local deck, seen = {}, {}
    for page = 1, pages do
        setPage(w, page)
        local widgets = {}
        collectItemWidgets(w, widgets, 0)
        local due_on_page = 0
        for i = 1, #widgets do
            local it = widgets[i].item
            if type(it.word) == "string" and it.word ~= ""
                    and type(it.due_time) == "number" and it.due_time <= now
                    and not seen[it.word] then
                seen[it.word] = true
                due_on_page = due_on_page + 1
                table.insert(deck, {
                    word = it.word,
                    page = page,
                    prev = it.prev_context,
                    next = it.next_context,
                    highlight = it.highlight,
                    book = it.book_title,
                    created = itemCreated(it),
                    due = tonumber(it.due_time),
                })
            end
        end
        -- Scan every page: the list can be sorted or filtered in other ways.
    end
    if original_page then
        setPage(w, original_page)
    end
    return deck
end

-- Last resort when the rows of the list cannot be read: take the due words
-- straight from the list data.
local function deckFromTable(w)
    local deck, seen = {}, {}
    local t = w.item_table
    if type(t) ~= "table" then
        return deck
    end
    local now = os.time()
    for i = 1, #t do
        local it = t[i]
        if type(it) == "table" and type(it.word) == "string" and it.word ~= ""
                and type(it.due_time) == "number" and it.due_time <= now
                and not seen[it.word] then
            seen[it.word] = true
            table.insert(deck, {
                word = it.word,
                page = 1,
                prev = it.prev_context,
                next = it.next_context,
                    highlight = it.highlight,
                book = it.book_title,
                created = itemCreated(it),
                due = tonumber(it.due_time),
            })
        end
    end
    return deck
end

local NOT_FOUND = "word not found in the list"

-- Find the list row (VocabItemWidget) of a card, paging through the list.
local function findRow(w, card)
    local pages = getPageCount(w)
    local order = { card.page }
    for page = 1, pages do
        if page ~= card.page then
            table.insert(order, page)
        end
    end
    for _i, page in ipairs(order) do
        setPage(w, page)
        local widgets = {}
        collectItemWidgets(w, widgets, 0)
        for i = 1, #widgets do
            if widgets[i].item.word == card.word then
                card.page = page
                return widgets[i]
            end
        end
    end
    return nil
end

-- DB writes use the same functions as the original Vocabulary Builder. Its
-- onGotIt/onForgot handlers update an item, while batchUpdateItems persists it.
local function vocabDB()
    -- Never use KOReader's native Vocabulary Builder database as a fallback.
    -- Missing FlipSide data must fail closed, not write reviews to another plugin.
    local db = package.loaded["flipside_db"]
    if type(db) ~= "table" then
        local ok, loaded = pcall(require, "flipside_db")
        if ok then db = loaded end
    end
    if type(db) ~= "table" then return nil end
    local expected = DataStorage:getSettingsDir() .. "/flipside/vocabulary_builder.sqlite3"
    if db.path ~= expected then
        logger.warn("FlipSide: refused a database outside its private directory")
        return nil
    end
    return db
end

local function flushToDB(w)
    local db = vocabDB()
    if not db or type(db.batchUpdateItems) ~= "function"
            or type(w) ~= "table" or type(w.item_table) ~= "table" then
        logger.warn("vocab flashcards: Vocabulary Builder database unavailable for list flush")
        return false
    end
    local ok, err = pcall(db.batchUpdateItems, db, w.item_table)
    if not ok then
        logger.warn("vocab flashcards: could not save list items:", err)
    end
    return ok
end

-- The real list can omit books that were disabled in its filter. For those
-- books use the plugin's actual DB handlers rather than missing row widgets.
local function answerCard(w, card, got)
    local db = vocabDB()
    if not db or type(db.gotOrForgot) ~= "function"
            or type(db.batchUpdateItems) ~= "function" then
        return false, "Vocabulary Builder database handlers not available"
    end

    local row = findRow(w, card)
    local old
    if type(db.hasWord) == "function" then
        local ok, item = pcall(db.hasWord, db, card.word)
        if ok then old = item end
    end
    if not old and row and row.item then old = row.item end
    if not old then
        return false, "word no longer exists in the database"
    end
    local previous = {
        review_count = tonumber(old.review_count) or 0,
        streak_count = tonumber(old.streak_count) or 0,
        review_time = tonumber(old.review_time),
        due_time = tonumber(old.due_time),
        never_reviewed = isNeverReviewed(old.review_count, old.streak_count,
            old.review_time, old.create_time or card.created),
    }
    if not previous.due_time then
        return false, "word has no due date"
    end

    if row then
        local ok, err = pcall(guarded, function()
            -- KOReader opens the dictionary as a side effect of onForgot()
            -- unless no_lookup is true. In a flashcard session we only record
            -- the answer; the dictionary remains available by tapping the word.
            if got then row:onGotIt() else row:onForgot(true) end
        end)
        if not ok then return false, tostring(err) end
        if not flushToDB(w) then
            return false, "answer updated in memory but could not be saved"
        end
    else
        local item = {
            word = card.word,
            review_count = previous.review_count,
            streak_count = previous.streak_count,
            due_time = previous.due_time,
            review_time = previous.review_time,
        }
        local ok, err = pcall(guarded, function()
            db:gotOrForgot(item, got)
            db:batchUpdateItems({ item })
        end)
        if not ok then return false, tostring(err) end
    end
    -- Remember the *committed* review timestamp. It identifies the single
    -- Learning Audit / Activity Stats event to reverse on Undo. A prior review
    -- timestamp from _before would identify the WRONG event.
    local ok_after, after = pcall(db.hasWord, db, card.word)
    if ok_after and type(after) == "table" then
        card._answered_at = tonumber(after.review_time)
        card._after = {
            review_count = tonumber(after.review_count),
            streak_count = tonumber(after.streak_count),
            due_time = tonumber(after.due_time),
            review_time = tonumber(after.review_time),
        }
    else
        card._answered_at = nil
        card._after = nil
        logger.warn("vocab flashcards: could not verify committed review for Undo")
        Diag.report("ERROR", "SRS_COMMIT_UNVERIFIED", {native_saved=true}, "Committed review row did not match Undo metadata")
    end
    card._before = previous
    -- After a committed first review it must immediately disappear from the
    -- Never Reviewed collection, even before the next database reload.
    card.never_reviewed = false
    -- The in-session deck must reflect the native scheduler immediately.
    -- Missing this update left the next-due summary using stale timestamps.
    if card._after then
        card.due = card._after.due_time
        card.reviewed = card._after.review_time
        card.review_count = card._after.review_count
        card.streak_count = card._after.streak_count
    end
    return true
end

-- Remove one word through the native Vocabulary Builder API, never via
-- unguarded SQL. The same removal operation is used by the stock list's
-- "Remove word" button. Verify the DB state because the native method
-- returns nil even after a successful DELETE, and other patches may hook it.
local function deleteCardFromDB(card)
    local db = vocabDB()
    if not db or type(db.hasWord) ~= "function" or type(db.remove) ~= "function" then
        return false, "Vocabulary Builder remove handler unavailable"
    end
    if type(card) ~= "table" or type(card.word) ~= "string" or card.word == "" then
        return false, "invalid flashcard"
    end
    local ok_before, before = pcall(db.hasWord, db, card.word)
    if not ok_before then return false, tostring(before) end
    if type(before) ~= "table" then
        return false, "word is no longer in the Vocabulary Builder database"
    end

    local ok_delete, delete_err = pcall(guarded, function()
        db:remove({ word = card.word })
    end)
    local ok_after, after = pcall(db.hasWord, db, card.word)
    if ok_after and after == nil then
        if not ok_delete then
            -- A hooked callback may throw after native deletion committed.
            logger.warn("vocab flashcards: word deleted, but a delete hook failed:", delete_err)
        end
        return true
    end
    if not ok_delete then return false, tostring(delete_err) end
    if not ok_after then return false, "could not verify the deletion: " .. tostring(after) end
    return false, "word still exists after removal"
end

-- The Undo stats recovery journal contains only event identities; it never
-- writes to the stock SRS or to the CRAM training queue.
local UndoRecovery = require("flipside_undo_recovery")
local undo_recovery
local function getUndoRecovery()
    if not undo_recovery then undo_recovery = UndoRecovery.open() end
    return undo_recovery
end

-- Undo statistics integration: the Learning Audit bridge reverses its own
-- event AND forwards the undo to Stats v7.x exactly once. When Learning Audit
-- is not installed, notify Stats directly. Never call both bridges here.
local function notifyUndoStatistics(word, stamped)
    if not tonumber(stamped) or tonumber(stamped) <= 0 then
        return false, "missing committed review timestamp"
    end
    -- Use the FlipSide-owned handler; older Vocabulary Builder patches may
    -- replace the generic bridge later in KOReader startup.
    local audit = package.loaded["flipside_learning_audit_undo_v2"]
    if type(audit) == "table" and type(audit.undoReview) == "function" then
        local ok, accepted, detail = pcall(audit.undoReview, word, stamped)
        if not ok then return false, tostring(accepted) end
        if accepted == false or accepted == nil then
            return false, tostring(detail or "Learning Audit could not reverse the review")
        end
        return true
    end
    local stats = package.loaded["flipside_activity_stats_v7"]
    if type(stats) == "table" and type(stats.undoReview) == "function" then
        local ok, accepted = pcall(stats.undoReview, word, stamped)
        if not ok or accepted == false or accepted == nil then
            return false, tostring(accepted)
        end
        if type(stats.flush) == "function" then
            local flushed, saved = pcall(stats.flush)
            if not flushed or saved == false or saved == nil then
                return false, "Activity Stats could not flush the Undo"
            end
        end
        return true
    end
    -- An absent bridge must not silently mark an Undo stats operation as done.
    return false, "No statistics Undo handler is available"
end

-- Replay only statistics corrections whose native SRS Undo was ALREADY saved.
-- Retry on the next FlipSide launch; never undo the native review a second time.
local function replayPendingUndoStatistics()
    local ok, store = pcall(getUndoRecovery)
    if not ok then
        logger.warn("FlipSide Undo: cannot open protected recovery journal:", store)
        Diag.report("CRITICAL", "UNDO_JOURNAL_FAILED", {stage="replay_open"}, store)
        return false
    end
    local replayed, done, failed = pcall(store.replay, store, notifyUndoStatistics)
    if not replayed then
        logger.warn("FlipSide Undo: could not verify recovery checkpoint:", done)
        Diag.report("ERROR", "UNDO_REPLAY_INCOMPLETE", {stage="replay_checkpoint"}, done)
        return false
    end
    if done > 0 or failed > 0 then
        logger.info("FlipSide Undo: recovered statistics corrections:", done,
            "still pending:", failed)
        if failed > 0 then
            Diag.report("ERROR", "UNDO_REPLAY_INCOMPLETE",
                {pending=failed, count=done}, "Pending statistics corrections remain after retry")
        end
    end
    return failed == 0
end

-- Restore the exact state from before the last answer, on disk as well. This
-- also works for a word hidden by the normal list's per-book filter.
local function undoCard(w, card)
    local previous = card._before
    if not previous then return false, "no previous answer for this card" end

    -- Do not overwrite a later review of the same word (e.g. performed from
    -- the normal list while this flashcard was open). Undo only our own answer.
    local db = vocabDB()
    if not db or type(db.hasWord) ~= "function" then
        return false, "Vocabulary Builder database unavailable for Undo"
    end
    local current_ok, current = pcall(db.hasWord, db, card.word)
    if not current_ok or type(current) ~= "table" then
        return false, "word no longer exists in the database"
    end
    local after = card._after
    if after and (tonumber(current.review_time) ~= after.review_time
            or tonumber(current.due_time) ~= after.due_time
            or tonumber(current.review_count) ~= after.review_count
            or tonumber(current.streak_count) ~= after.streak_count) then
        return false, "the word was reviewed again after this answer"
    end
    local answered_at = card._answered_at or tonumber(current.review_time)
    local ok, err = pcall(function()
        local DataStorage = require("datastorage")
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/flipside/vocabulary_builder.sqlite3")
        local ok_update, update_err = pcall(function()
            local stmt = conn:prepare([[UPDATE vocabulary SET review_count = ?,
                streak_count = ?, review_time = ?, due_time = ? WHERE word = ?;]])
            stmt:bind(previous.review_count, previous.streak_count,
                previous.review_time, previous.due_time, card.word)
            stmt:step()
            stmt:close()
        end)
        conn:close()
        if not ok_update then error(update_err, 0) end
    end)
    if not ok then return false, tostring(err) end
    card.due = previous.due_time
    card.reviewed = previous.review_time
    card.review_count = previous.review_count
    card.streak_count = previous.streak_count
    -- Undo restores the original first-review eligibility as well as the
    -- actual database schedule, without requiring a fresh deck session.
    card.never_reviewed = previous.never_reviewed
    local ok_row, row = pcall(guarded, findRow, w, card)
    if ok_row and row and row.item then
        row.item.review_count = previous.review_count
        row.item.streak_count = previous.streak_count
        row.item.due_time = previous.due_time
        row.item.review_time = nil -- not a pending write: restored directly above
        row.item.is_dim = previous.due_time > os.time()
    end
    card._before = nil
    card._after = nil
    card._answered_at = nil

    -- The native SQLite review was restored. Persist the exact stats Undo
    -- identity before notifying the two statistics stores. If a subsequent
    -- write fails, the journal remains available for safe retry on startup.
    local checkpoint_ok, store = pcall(getUndoRecovery)
    if checkpoint_ok then
        checkpoint_ok, store = pcall(function()
            local journal = store
            local saved, why = journal:add(card.word, tonumber(answered_at))
            if saved ~= true then error(why or "Undo checkpoint not saved", 0) end
            return journal
        end)
    end
    if not checkpoint_ok then
        logger.warn("FlipSide Undo: statistics recovery checkpoint unavailable:", store)
        Diag.report("CRITICAL", "UNDO_JOURNAL_FAILED", {stage="undo_checkpoint", native_saved=true}, store)
    end

    -- The original Flashcards v2.4.2 stopped here. That restored the stock
    -- schedule but left both Learning Audit and Stats counting the answer.
    -- Only notify *after* the database update succeeds; a notification failure
    -- must not claim the restored review was never restored.
    local notified, reason = notifyUndoStatistics(card.word, answered_at)
    if notified and checkpoint_ok then
        local complete, err = pcall(store.complete, store, card.word,
            tonumber(answered_at))
        if not complete or err ~= true then
            logger.warn("FlipSide Undo: statistics updated but recovery checkpoint"
                .. " could not be cleared:", err)
            Diag.report("ERROR", "UNDO_JOURNAL_FAILED",
                {native_saved=true, stats_saved=true, stage="clear"}, err)
            -- Do not show a false failure: replaying an already-undone event
            -- is safe, and the journal will be cleared on the next launch.
        end
    elseif not notified then
        logger.warn("FlipSide Undo: native review restored, statistics correction"
            .. " still pending:", reason)
        Diag.report("ERROR", "UNDO_STATS_PENDING",
            {native_saved=true, stats_saved=false, journal=checkpoint_ok}, reason)
        UIManager:show(newFlashInfo(nil, {
            text = checkpoint_ok
                and "Review restored. Statistics correction is saved for "
                    .. "retry when FlipSide opens again. See KOReader logs."
                or "Review restored, but statistics correction and recovery "
                    .. "could not be verified. Back up your FlipSide settings "
                    .. "and check KOReader logs.",
            timeout = 7,
        }))
    else
        UIManager:show(newFlashInfo(nil, {
            text = "Review and statistics restored, but the protected Undo "
                .. "checkpoint could not be written. Check KOReader logs.",
            timeout = 7,
        }))
    end
    return true
end

-- Reload the words of the list from the database.
local function reloadList(w)
    if type(w) == "table" and type(w.reloadItems) == "function" then
        local ok, err = pcall(guarded, w.reloadItems, w)
        if not ok then
            logger.warn("vocab flashcards: could not reload the list:", err)
        end
        return ok
    end
    return false
end

-- The list window the plugin is using right now (created or reloaded by the
-- plugin's own setupWidget), or `current` if the plugin cannot be found.
local function liveList(current)
    -- Current KOReader has no setupWidget() API: onShowVocabBuilder()
    -- creates a NEW widget and displays it, so calling it from a refresh
    -- would recursively reopen the flashcard interface. Just reuse the
    -- plugin's existing list widget when it has changed.
    local plugin = getPlugin()
    if plugin and type(plugin.widget) == "table" then
        return plugin.widget
    end
    return current
end

-- When something other than this patch reloads the list (filter, reverse order,
-- reset, clean, sync... from the menu) the flashcards must be rebuilt.
local function watchList(w)
    if type(w) ~= "table" or w._flashcards_watched or type(w.reloadItems) ~= "function" then
        return
    end
    w._flashcards_watched = true
    local orig = w.reloadItems
    w.reloadItems = function(self, ...)
        local a, b = orig(self, ...)
        if Flash.depth == 0 and Flash.current then
            Flash.current:onListChanged()
        end
        return a, b
    end
end

-- Builds the deck for a session. `ctx.list` is the list window to use; it can
-- be replaced here when the one we were given turns out to be stale.
-- Returns the deck (possibly empty), or nil + error.
local function acquireDeckRaw(ctx)
    local last_err

    local function attempt()
        local state = tableState(ctx.list)
        if state == "none_due" then
            return {}
        elseif state == "missing" then
            return nil
        end
        local ok, deck = pcall(guarded, buildDeck, ctx.list)
        if not ok then
            last_err = deck
            logger.warn("vocab flashcards: could not read the rows:", deck)
            return nil
        end
        if type(deck) == "table" and #deck > 0 then
            return deck
        end
        return nil
    end

    local deck = attempt()
    if deck then
        return deck
    end

    -- Nothing found. The list may not have its data yet (first opening after
    -- starting KOReader, or after waking up): reload it and try again.
    reloadList(ctx.list)
    deck = attempt()
    if deck then
        return deck
    end

    -- Still nothing: the window may be a stale one. Ask the plugin for the live one.
    local fresh = liveList(ctx.list)
    if fresh ~= ctx.list then
        ctx.list = fresh
        watchList(fresh)
    end
    deck = attempt()
    if deck then
        return deck
    end

    -- Last resort: read the due words straight from the list data.
    local ok, from_table = pcall(deckFromTable, ctx.list)
    if ok and type(from_table) == "table" and #from_table > 0 then
        logger.warn("vocab flashcards: list rows not readable, using the list data")
        return from_table
    end

    if last_err ~= nil then
        return nil, last_err
    end
    return {}
end

-- The callback of the list's hamburger button (opens the real Vocabulary
-- builder menu), found through the list's title bar.
local function findListMenuCallback(w)
    if type(w) ~= "table" then
        return nil
    end
    local function fromBar(tb)
        if type(tb) ~= "table" then
            return nil
        end
        if type(tb.left_icon_tap_callback) == "function" then
            return tb.left_icon_tap_callback
        end
        local lb = tb.left_button
        if type(lb) == "table" and type(lb.callback) == "function" then
            return lb.callback
        end
        return nil
    end
    local cb = fromBar(w.title_bar)
    if cb then
        return cb
    end
    local found
    local function dfs(node, depth)
        if found or type(node) ~= "table" or depth > 8 then
            return
        end
        if type(node.left_icon_tap_callback) == "function" then
            found = node.left_icon_tap_callback
            return
        end
        for i = 1, #node do
            dfs(node[i], depth + 1)
        end
    end
    dfs(w, 0)
    return found
end

local function oneLine(s)
    return (tostring(s or ""):gsub("%s*\n%s*", " "))
end

-- The built-in plugin stores the looked-up dictionary key separately from
-- the highlighted text. Use the exact highlighted word/phrase when available:
-- e.g., card.word = "run", card.highlight = "running".
local function buildSentence(card)
    local shown = (type(card.highlight) == "string" and card.highlight ~= "")
        and card.highlight or card.word
    local helper = package.loaded["flipside_full_sentence_shared"]
    if type(helper) == "table" and type(helper.format) == "function" then
        local ok, sentence = pcall(helper.format, card.prev, shown, card.next)
        if ok and type(sentence) == "string" then
            -- If native context began in the middle of a sentence, the
            -- extracted sentence may start with a lower-case fragment.
            -- Mirror the ellipsis convention of the list, without changing
            -- the complete surrounding-context view or saved database.
            local source = oneLine(card.prev):gsub("^%s+", "")
            local first = sentence:gsub("^%s+", "")
            if source:match("^[a-z]") and first:match("^[a-z]")
                and first:sub(1, 3) ~= "..." then
                sentence = "..." .. sentence
            end
            return sentence
        end
        logger.warn("vocab flashcards: sentence formatting failed:", sentence)
    end
    -- Keep functioning when the companion v5 patch is not installed.
    if not card.prev and not card.next then return nil end
    local fallback = oneLine(card.prev) .. "【" .. oneLine(shown) .. "】" .. oneLine(card.next)
    if oneLine(card.prev):match("^%s*[a-z]") and fallback:sub(1, 3) ~= "..." then
        fallback = "..." .. fallback
    end
    return fallback
end

-- Double-tap full context: show the two sentences without artificial
-- ellipses at either boundary. Do not modify the stored context or remove
-- punctuation that belongs to the text itself.
local function cleanExpandedContext(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end

-- Show the original saved excerpt (or the Full Sentence helper's cropped
-- two-sentence view) without inventing text or adding boundary markers.
local function buildSurrounding(card)
    if card.prev == nil and card.next == nil then return nil end
    local shown = (type(card.highlight) == "string" and card.highlight ~= "")
        and card.highlight or card.word
    local helper = package.loaded["flipside_full_sentence_shared"]
    if type(helper) == "table" and type(helper.formatSurrounding) == "function" then
        local ok, extra = pcall(helper.formatSurrounding, card.prev, shown, card.next)
        if ok and type(extra) == "string" then
            return cleanExpandedContext(extra)
        elseif not ok then
            logger.warn("vocab flashcards: surrounding context failed:", extra)
        end
    end
    -- For older sentence-only records the helper may return nil because
    -- there is no additional context: display the stored sentence as-is.
    local full = oneLine(card.prev) .. "【" .. oneLine(shown) .. "】" .. oneLine(card.next)
    return cleanExpandedContext(full)
end

---------------------------------------------------------------- flashcard widget

---------------------------------------------------------------- filters

-- Start of today (offset 0) / yesterday (offset 1), in seconds.
local function dayStart(offset)
    local t = os.date("*t")
    return os.time{ year = t.year, month = t.month, day = t.day - offset, hour = 0, min = 0, sec = 0 }
end

local function sameFilter(a, b)
    return a ~= nil and b ~= nil and a.kind == b.kind and a.book == b.book
end

local function containsFilter(filters, candidate)
    for _, item in ipairs(filters or {}) do
        if sameFilter(item, candidate) then return true end
    end
    return false
end

local function copyFilter(candidate)
    return { kind = candidate.kind, book = candidate.book }
end

-- "All books" must mean ALL saved words, including cards added today,
-- yesterday, and cards never reviewed. Due-time eligibility is evaluated
-- separately by _isReviewEligible() and is never hidden by a date filter.
-- The Today/Yesterday/Never Reviewed collections remain independent views.
local function inAllBooks(card, today0, yest0)
    return true
end

local function cardMatches(card, filter, today0, yest0, include_answered)
    -- History is hidden in ordinary lists, but the real-due watcher must
    -- examine completed cards: the native 5/30-minute interval can mature
    -- while this same flashcard screen remains open.
    if card.done and not include_answered then
        return false
    end
    local kind = filter.kind
    if kind == "all" then
        return inAllBooks(card, today0, yest0)
    elseif kind == "today" then
        return card.created ~= nil and card.created >= today0
    elseif kind == "yesterday" then
        return card.created ~= nil and card.created >= yest0 and card.created < today0
    elseif kind == "never_reviewed" then
        return card.never_reviewed == true
    elseif kind == "book" then
        return card.book == filter.book
    end
    return true
end

-- Cram used the older All books membership, which excluded freshly
-- added and never-reviewed entries. Keep that old rule only for Cram;
-- it must not hide real SRS reviews in the ordinary All books queue.
local function cramCardMatches(card, filter, today0, yesterday0, include_answered)
    if filter.kind == "all" then
        if card.never_reviewed == true then return false end
        if card.created and card.created >= yesterday0 then return false end
    end
    return cardMatches(card, filter, today0, yesterday0, include_answered)
end

---------------------------------------------------------------- word dates

-- word -> { created = seconds, due = seconds, never_reviewed = boolean }, read straight from the
-- Vocabulary builder database (the same dates its own "Added today / Added
-- yesterday" filters use). Returns nil when the database cannot be read.
local function readWordDates()
    local ok, rows = pcall(function()
        local DataStorage = require("datastorage")
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/flipside/vocabulary_builder.sqlite3")
        local ok_sql, result = pcall(conn.exec, conn,
            "SELECT word, create_time, due_time, review_time, review_count, streak_count FROM vocabulary;")
        conn:close()
        if not ok_sql then error(result, 0) end
        return result
    end)
    if not ok or type(rows) ~= "table" or type(rows.word) ~= "table" then
        logger.warn("vocab flashcards: unable to read dates:", ok and "bad columns" or rows)
        return nil
    end
    local map = {}
    for i, word in ipairs(rows.word) do
        local created = tonumber(rows.create_time and rows.create_time[i])
        if type(word) == "string" and created then
            map[word] = {
                created = created,
                due = tonumber(rows.due_time and rows.due_time[i]),
                never_reviewed = isNeverReviewed(
                    rows.review_count and rows.review_count[i],
                    rows.streak_count and rows.streak_count[i],
                    rows.review_time and rows.review_time[i], created),
            }
        end
    end
    return map
end

-- How many words (all of them, due or not) were added today / yesterday.
local function groupTotal(dates, kind)
    local today0, yest0 = dayStart(0), dayStart(1)
    local n = 0
    for _w, d in pairs(dates) do
        if kind == "today" and d.created >= today0 then
            n = n + 1
        elseif kind == "yesterday" and d.created >= yest0 and d.created < today0 then
            n = n + 1
        end
    end
    return n
end

-- Give every card its real creation date (from the database; the list item is
-- only the fallback) and remember the dates for the whole vocabulary in deck.dates.
local function fillCreated(deck)
    local dates = readWordDates()
    local today0, yest0 = dayStart(0), dayStart(1)
    local differ = 0
    local d_today, d_yest = 0, 0
    for _i, c in ipairs(deck) do
        local d = dates and dates[c.word]
        if d and d.created then
            if c.created and c.created ~= d.created then
                differ = differ + 1
            end
            c.created = d.created
            c.never_reviewed = d.never_reviewed
        end
        if c.created then
            if c.created >= today0 then
                d_today = d_today + 1
            elseif c.created >= yest0 then
                d_yest = d_yest + 1
            end
        end
    end
    deck.dates = dates
    logger.info(string.format(
        "vocab flashcards: due cards %d (today %d, yesterday %d); all words today %s, yesterday %s; dates from %s; item date differs from database in %d",
        #deck, d_today, d_yest,
        dates and tostring(groupTotal(dates, "today")) or "?",
        dates and tostring(groupTotal(dates, "yesterday")) or "?",
        dates and "database" or "list items", differ))
end

-- Words added today / yesterday: how many there are, how many of them are due
-- now, and when the next one is due. `skip` holds words already answered in
-- this session (the database snapshot still has their old due time).
local function groupInfo(dates, kind, skip)
    local today0, yest0 = dayStart(0), dayStart(1)
    local now = os.time()
    local total, due_now, next_due = 0, 0, nil
    for word, d in pairs(dates) do
        local inside = (kind == "today" and d.created >= today0)
            or (kind == "yesterday" and d.created >= yest0 and d.created < today0)
        if inside then
            total = total + 1
            if not (skip and skip[word]) and d.due then
                if d.due <= now then
                    due_now = due_now + 1
                elseif next_due == nil or d.due < next_due then
                    next_due = d.due
                end
            end
        end
    end
    return total, due_now, next_due
end

-- The deck is built by paging through the list rows. Every word the database
-- says is due but that the deck is missing is looked for in the whole list
-- and added, so no due word is left out.
local function completeDeck(w, deck)
    local dates = deck.dates
    if type(dates) ~= "table" then
        return
    end
    local now = os.time()
    local have = {}
    for _i, c in ipairs(deck) do
        have[c.word] = true
    end
    local due_n, missing_n = 0, 0
    for word, d in pairs(dates) do
        if d.due and d.due <= now then
            due_n = due_n + 1
            if not have[word] then
                missing_n = missing_n + 1
            end
        end
    end
    logger.info(string.format(
        "vocab flashcards: due in database %d, in the deck %d, missing from the deck %d",
        due_n, #deck, missing_n))
    if missing_n == 0 then
        return
    end

    local pages = getPageCount(w)
    local original_page = w.show_page
    local added = 0
    for page = 1, pages do
        setPage(w, page)
        local widgets = {}
        collectItemWidgets(w, widgets, 0)
        for i = 1, #widgets do
            local it = widgets[i].item
            local d = type(it.word) == "string" and dates[it.word] or nil
            if d and d.due and d.due <= now and not have[it.word] then
                have[it.word] = true
                added = added + 1
                table.insert(deck, {
                    word = it.word,
                    page = page,
                    prev = it.prev_context,
                    next = it.next_context,
                    highlight = it.highlight,
                    book = it.book_title,
                    created = d.created,
                })
            end
        end
    end
    if original_page then
        setPage(w, original_page)
    end
    logger.info("vocab flashcards: added", added, "due words that the deck was missing")
end

local function readFullCatalog()
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    local SQ3 = require("lua-ljsqlite3/init")
    local path = DataStorage:getSettingsDir() .. "/flipside/vocabulary_builder.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then
        error("Vocabulary Builder database does not exist: " .. path, 0)
    end
    local conn = SQ3.open(path)
    local ok, rows = pcall(conn.exec, conn, [[
        SELECT v.word AS word, v.create_time AS created,
               v.due_time AS due, v.review_time AS reviewed,
               v.review_count AS reviews, v.streak_count AS streak,
               v.prev_context AS prev, v.next_context AS next,
               v.highlight AS selected_text,
               COALESCE(t.name, '') AS book
          FROM vocabulary AS v
          LEFT JOIN title AS t ON v.title_id = t.id
         ORDER BY v.due_time ASC, v.word COLLATE NOCASE ASC;
    ]])
    if not ok then
        conn:close()
        error(rows, 0)
    end
    -- ljsqlite3 may return nil (or a table without columns) when the
    -- SELECT matches zero rows. An untagged {} made the confirmed empty
    -- catalog indistinguishable from a partial Vocabulary Builder list,
    -- so Smart Cram never offered the opt-in recovery dialog.
    -- Never mark a broken or unexpected query result as a verified empty DB.
    if rows == nil or (type(rows) == "table" and
            (rows.word == nil or
                (type(rows.word) == "table" and #rows.word == 0))) then
        local verified, reason = pcall(function()
            if tostring(conn:rowexec("PRAGMA quick_check;")) ~= "ok" or
                    tonumber(conn:rowexec("SELECT COUNT(*) FROM vocabulary;")) ~= 0 then
                error("Empty catalog could not be independently verified")
            end
        end)
        conn:close()
        if not verified then error(reason, 0) end
        local empty = { full_catalog = true }
        logger.info("vocab flashcards: database catalog loaded: 0 words (all books)")
        return empty
    end
    conn:close()
    if type(rows) ~= "table" or type(rows.word) ~= "table" then
        error("Unexpected Vocabulary Builder database result", 0)
    end
    local cards = {}
    for i, word in ipairs(rows.word) do
        if type(word) == "string" and word ~= "" then
            local due = tonumber(rows.due and rows.due[i])
            table.insert(cards, {
                word = word,
                book = rows.book and rows.book[i] or "",
                created = tonumber(rows.created and rows.created[i]),
                due = due,
                reviewed = tonumber(rows.reviewed and rows.reviewed[i]),
                prev = rows.prev and rows.prev[i],
                next = rows.next and rows.next[i],
                highlight = rows.selected_text and rows.selected_text[i],
                review_count = tonumber(rows.reviews and rows.reviews[i]) or 0,
                streak_count = tonumber(rows.streak and rows.streak[i]) or 0,
                never_reviewed = isNeverReviewed(
                    rows.reviews and rows.reviews[i],
                    rows.streak and rows.streak[i],
                    rows.reviewed and rows.reviewed[i],
                    rows.created and rows.created[i]),
            })
        end
    end
    cards.full_catalog = true
    logger.info("vocab flashcards: database catalog loaded:", #cards, "words (all books)")
    return cards
end

local function acquireDeck(ctx)
    -- Always prefer the complete, joined database snapshot. The list can show
    -- only the selected books and loads many items lazily, so it is NOT a
    -- reliable source for book filters or totals.
    local ok, cards = pcall(readFullCatalog)
    if ok and type(cards) == "table" then
        return cards
    end
    logger.warn("vocab flashcards: database catalog failed, trying list fallback:", cards)
    local due_deck, err = acquireDeckRaw(ctx)
    if type(due_deck) == "table" then
        pcall(fillCreated, due_deck)
        return due_deck
    end
    return nil, err
end

local Flashcards = InputContainer:extend{
    name = "vocab_flashcards",
    disable_double_tap = false, -- enable only while this widget owns the screen
    covers_fullscreen = true,
    -- KOReader disables double taps in most UI widgets unless explicitly enabled.
    disable_double_tap = false,
    cards = nil,     -- the cards of the current filter that are still to review
    all_cards = nil, -- every card of the deck (answered ones are marked .done)
    filter = nil,    -- currently displayed group (one of selected_filters)
    selected_filters = nil, -- user-selected groups; swipe on header to cycle
    practice = false, -- practice all words without touching review times
    advance_today = false, -- include later-due reviews before local midnight
    advance_day = nil, -- never carry the day's early-review choice into tomorrow
    advance_today_button = nil, -- independent fourth utility shortcut
    _today_dialog = nil,
    _intensive_dialog = nil,
    intensive_mode = "off",
    intensive_timing = "after",
    training = nil,
    _cram_store = nil,
    _cram_slot = nil,
    _cram_save_failed = false,
    _cram_unavailable = false,
    _training_current = nil,
    _training_extra_cards = nil,
    _ultra_waiting = nil,
    _normal_resume_card = nil,
    _official_since_training = 0,
    intensive_button = nil,
    style_cycle_button = nil,
    immersive = false, -- session-only distraction-free review
    immersion_exit_rect = nil, -- invisible top-right escape target
    dual_strategy = "off", -- global default, configured only in Aa > Review strategy
    card_modes = nil, -- per-word manual overrides, saved independently
    dual_phase = nil, -- meaning | cloze | revealed
    dual_card = nil,
    dual_meaning_total = 0,
    dual_meaning_correct = 0,
    dual_context_total = 0,
    dual_context_correct = 0,
    idx = 1,
    state = "card", -- "card" | "empty" | "done"
    show_ctx = false,
    show_more_ctx = false,
    sentence_font = nil, -- saved font of the context sentence
    sentence_size = nil, -- saved size of the context sentence
    got = 0,
    forgot = 0,
    retry_round = false, -- one immediate reinforcement pass, no DB writes
    retry_total = 0,
    retry_seen = 0,
    retry_got = 0,
    retry_forgot = 0,
    busy = false,
    touched = false, -- true once an answer was given or undone
    history = nil,   -- answers given, newest last: { idx = card index, got = bool }
    _browse_back = nil, -- visited cards, including skipped pending cards (no DB writes)
    _inspection_cursor = nil, -- index into history while viewing an answered card
    _inspection_resume = nil, -- exactly restore pending card or finish screen
    _clock_last = nil,
    _clock_last_mode = nil,
    _clock_action = nil,
    _clock_saved_at = nil,
    _clock_last_touch = nil,
    -- Sleep guard: never repaint flashcards over Kindle/KOReader screensavers.
    -- These flags are runtime only; no SRS data or saved preferences change.
    _sleep_paused = false,
    _resume_action = nil,
    _recover_action = nil,
    word_rect = nil, -- where the word is on screen (tap = dictionary)
    mode_toggle_button = nil, -- fixed-position card button for manual mode switching
    accuracy_button = nil, -- small statistics shortcut in the header
    card_rect = nil, -- central touch area (tap = context, swipe = next/prev)
    filter_rect = nil, -- horizontal swipe here changes the selected group
    answer_func = nil,
    undo_func = nil,
    lookup_func = nil,
    flush_func = nil,
    reload_func = nil,
    list_check = nil,
    menu_func = nil,
    on_close = nil,
    on_list = nil,
}

-- Remove deleted book groups without dropping valid selections. A book with
-- zero due reviews is still a legitimate selection and must be kept.
function Flashcards:_validateFilter()
    local selected = {}
    for _, filter in ipairs(self.selected_filters or {}) do
        local present = filter.kind ~= "book" or not self.all_cards or not self.all_cards.full_catalog
        if filter.kind == "book" and self.all_cards and self.all_cards.full_catalog then
            for _, card in ipairs(self.all_cards) do
                if card.book == filter.book then present = true break end
            end
        end
        if present and not containsFilter(selected, filter) then
            selected[#selected + 1] = copyFilter(filter)
        end
    end
    if #selected == 0 then selected[1] = { kind = "all" } end
    self.selected_filters = selected
    if not containsFilter(selected, self.filter) then
        self.filter = copyFilter(selected[1])
        saveFilter(self.filter)
    end
    saveSelectedFilters(self.selected_filters)
end

function Flashcards:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        -- The same full-screen gesture is routed by its start region below.
        -- Buttons and menus continue to receive their own tap events.
        self.ges_events.TapCard = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
        self.ges_events.DoubleTapCard = {
            GestureRange:new{ ges = "double_tap", range = self.dimen },
        }
        self.ges_events.SwipeCards = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
        self.ges_events.HoldCard = {
            GestureRange:new{ ges = "hold", range = self.dimen },
        }
    end
    self.history = {}
    self._browse_back = {}
    self._inspection_cursor = nil
    self._inspection_resume = nil
    self._clock_last = nil
    self._clock_last_mode = nil
    self._clock_saved_at = os.time()
    self._clock_last_touch = os.time()
    self._sleep_paused = false
    self._resume_action = nil
    self._recover_action = nil
    self.retry_round = false
    self.retry_total = 0
    self.retry_seen = 0
    self.retry_got = 0
    self.retry_forgot = 0
    self.intensive_mode = storedIntensiveMode()
    self.intensive_timing = storedIntensiveTiming()
    self.training = nil
    self._training_current = nil
    self._training_extra_cards = {}
    self._ultra_waiting = {}
    self._normal_resume_card = nil
    self._official_since_training = 0
    self.all_cards = self.cards
    self.filter = storedFilter()
    self.selected_filters = storedSelectedFilters()
    self.practice = storedPractice()
    self.advance_today = storedAdvanceToday()
    self.advance_day = localDayKey()
    self.sentence_font = storedSentenceFont()
    self.sentence_size = storedSentenceSize()
    self.card_style = Flash.storedCardStyle()
    -- Never auto-enter immersion on launch: the normal controls remain
    -- discoverable after a restart, even on a device without a Back key.
    self.immersive = false
    self.dual_strategy = storedDualStrategy()
    self.card_modes = storedCardModes()
    self.sentence_card_modes = storedCardModes(DUAL_SENTENCE_CARD_MODES_KEY)
    self.dual_meaning_total = 0
    self.dual_meaning_correct = 0
    self.dual_context_total = 0
    self.dual_context_correct = 0
    self:_validateFilter()
    self.cards = self:_buildView()
    Diag.event("cram", "open_saved_progress", {mode=self.intensive_mode, practice=self.practice})
    local opened, store = pcall(CramStore.open)
    if opened then
        self._cram_store = store
    else
        self._cram_save_failed = true
        logger.warn("FlipSide cram: cannot open progress file:", store)
        Diag.report("CRITICAL", "CRAM_STORE_OPEN_FAILED",
            {mode=self.intensive_mode, practice=self.practice}, store)
        -- Fail closed: never begin unprotected training when persistence
        -- is unavailable. The native SRS remains fully operational.
        self.intensive_mode = "off"
        self._cram_unavailable = true
    end
    self:_initializeIntensive()
    self.state = (#self.cards == 0) and "empty" or "card"
    if self.state == "empty" then self:_startMissedRound() end
    self:_render()
    self:_armDueWatch()
    -- The reset dialog must be scheduled only AFTER UIManager:show(flash).
    -- At init time the widget is not yet displayed, and the prior deferred
    -- callback could silently abort while suppressing the error notice.
end

-- Offer recovery only when the entire private SQLite catalog is confirmed
-- empty. A zero-card filter, missed DB load or temporary sync view is NOT a
-- deletion. Refusal never changes the saved checkpoint; prompt once per view.
function Flashcards:_offerCramResetForEmptyDeck()
    local catalog = self.all_cards
    local decision_key = "flipside_cram_empty_deck_decision_v1"
    -- Persist the user's choice across KOReader restarts, but never confuse
    -- a filtered/failed catalog with a real empty database. Once new words
    -- have been loaded, allow a new prompt if they are all deleted later.
    if type(catalog) ~= "table" or catalog.full_catalog ~= true then
        return
    end
    if #catalog ~= 0 then
        self._cram_reset_offered = nil
        if G_reader_settings:readSetting(decision_key) ~= nil then
            local cleared, err = pcall(function()
                G_reader_settings:delSetting(decision_key)
                G_reader_settings:flush()
            end)
            if not cleared then
                logger.warn("FlipSide cram: cannot clear old reset decision:", err)
            end
        end
        return
    end
    if self._cram_reset_offered then return end
    local old_stats = G_reader_settings:readSetting(INTENSIVE_STATS_SETTING)
    local any_stats = false
    if type(old_stats) == "table" then
        for _, item in pairs(old_stats) do
            if type(item) == "table"
                    and ((tonumber(item.correct) or 0) > 0
                      or (tonumber(item.missed) or 0) > 0) then
                any_stats = true
                break
            end
        end
    end
    local saved_exists = CramStore.hasSavedState(self._cram_store) or any_stats
    if not saved_exists then return end
    local decision = G_reader_settings:readSetting(decision_key)
    if decision == "keep" then
        -- "Keep progress" is a real choice, not a one-session dismissal.
        return
    elseif decision == "reset" then
        -- A reset was previously confirmed successful, but data is present
        -- again (for example, restored from cloud). Do not silently erase it
        -- or display the same reset question forever. Report the anomaly.
        self._cram_reset_offered = true
        logger.warn("FlipSide cram: old progress reappeared after a confirmed reset")
        UIManager:nextTick(function()
            if not self._closing and UIManager:isWidgetShown(self) then
                UIManager:show(newFlashInfo(self, {
                    text = "Smart Cram progress appeared again after reset. "
                        .. "This may be an older cloud copy. No data was deleted; "
                        .. "check KOReader logs before syncing.",
                    timeout = 9,
                }))
            end
        end)
        return
    end
    self._cram_reset_offered = true
    UIManager:nextTick(function()
        if self._closing or not UIManager:isWidgetShown(self) then return end
        local box = ConfirmBox:new{
            text = "FlipSide has no saved words, but Smart Cram still has old progress.\n\n"
                .. "Reset Smart Cram and its training counters? A copy of the "
                .. "old progress will be saved first.\n\n"
                .. "Learning Analysis and Study Calendar history will NOT be deleted.",
            ok_text = "Reset Smart Cram",
            cancel_text = "Keep progress",
            cancel_callback = function()
                -- The original checkpoint is untouched. Only remember that
                -- the user declined to reset this fully empty deck.
                local remembered, err = pcall(function()
                    G_reader_settings:saveSetting(decision_key, "keep")
                    G_reader_settings:flush()
                end)
                if not remembered then
                    logger.warn("FlipSide cram: could not remember Keep progress:", err)
                    UIManager:show(newFlashInfo(self, {
                        text = "Could not save your choice. No CRAM data was changed.",
                        timeout = 6,
                    }))
                end
            end,
            ok_callback = function()
                if self._closing or not UIManager:isWidgetShown(self) then return end
                -- Re-query the actual DB at the LAST responsible moment. An
                -- external import/sync may have added a new word meanwhile.
                local checked, current = pcall(readFullCatalog)
                if not checked or type(current) ~= "table"
                        or current.full_catalog ~= true or #current ~= 0 then
                    UIManager:show(newFlashInfo(self, {
                        text = "Words changed or the catalog could not be verified. "
                            .. "Nothing was reset.", timeout = 7,
                    }))
                    return
                end
                local success, fresh, backup = pcall(
                    CramStore.resetAfterVerifiedEmptyDeck, true)
                if not success then
                    logger.warn("FlipSide cram: reset refused or failed:", fresh)
                    Diag.report("ERROR", "CRAM_CHECKPOINT_FAILED",
                        {stage="opt_in_reset"}, fresh)
                    UIManager:show(newFlashInfo(self, {
                        text = "Smart Cram could not be safely reset. "
                            .. "Your original progress was kept. Check logs.",
                        timeout = 8,
                    }))
                    return
                end
                self._cram_store = fresh
                self._cram_save_failed = false
                self._cram_unavailable = false
                self.training = nil
                self._cram_slot = nil
                -- Training counters are CRAM-specific; other statistics and
                -- cloud settings remain untouched. Failure is reported rather
                -- than claiming a full reset succeeded.
                local stats_ok, stats_err = pcall(function()
                    G_reader_settings:saveSetting(INTENSIVE_STATS_SETTING, {})
                    G_reader_settings:flush()
                end)
                if not stats_ok then
                    logger.warn("FlipSide cram: reset training counters failed:", stats_err)
                    Diag.report("ERROR", "CRAM_TRAINING_COUNTER_FAILED",
                        {stage="opt_in_reset"}, stats_err)
                else
                    -- Remember success only after both the fresh checkpoint
                    -- and its training counters have been committed. Failed
                    -- resets remain recoverable and are never hidden.
                    local remembered, err = pcall(function()
                        G_reader_settings:saveSetting(decision_key, "reset")
                        G_reader_settings:flush()
                    end)
                    if not remembered then
                        logger.warn("FlipSide cram: reset succeeded but decision save failed:", err)
                    end
                end
                Diag.event("cram", "opt_in_reset", {result=stats_ok and "ok" or "partial"})
                UIManager:show(newFlashInfo(self, {
                    text = stats_ok and
                        "Smart Cram restarted. Original progress was archived "
                            .. "in settings/flipside/cram-reset-backups. "
                            .. "Learning Analysis and calendar were preserved."
                        or "Smart Cram queue restarted, but training counters "
                            .. "could not be cleared. Check KOReader logs.",
                    timeout = 9,
                }))
            end,
        }
        UIManager:show(box)
    end)
end

-- Count only time actually spent looking at a flashcard. Exclude stats,
-- dictionaries, menus, finish screen and screen saver. The foreground test
-- makes modal dialogs pause automatically. A capped delta prevents a Kindle
-- sleep/clock jump or stalled event loop from being counted as study time.
function Flashcards:_clockMode()
    -- Training after the last due review and manual Practice do not produce
    -- recorded native SRS answers, so they must never accrue review time.
    if self.state ~= "card" or self.practice or self.retry_round
            or self._inspection_cursor or self.busy then return nil end
    local card = self.cards and self.cards[self.idx]
    if not card or card.done or card._retry_pending then return nil end
    local strategy = self:_strategyForCard(card)
    if strategy == "off" then return "other" end
    if self.dual_phase == "sentence" then return "sentence" end
    if self.dual_phase == "cloze" or self.dual_phase == "revealed" then
        return "contextual"
    end
    return "meaning"
end

function Flashcards:_clockTouch()
    self._clock_last_touch = os.time()
end

-- Call before presenting any overlay. Finish counting the foreground
-- interval, then force a clean restart after the overlay is dismissed.
function Flashcards:_clockPause()
    self:_clockPulse(true)
    self._clock_last, self._clock_last_mode = nil, nil
end

function Flashcards:_clockPulse(flush)
    local now = os.time()
    -- Pause after five minutes without a user interaction. Leaving the
    -- e-reader on a card all evening should not count as active studying.
    local recently_active = (now - (self._clock_last_touch or now)) <= 300
    local active = recently_active and not self._closing and self.state == "card"
        and not self._sleep_paused and not Device.screen_saver_mode
        and UIManager:isWidgetShown(self)
        and UIManager:getTopmostVisibleWidget() == self
    local mode = active and self:_clockMode() or nil
    local previous = self._clock_last
    if active and mode and previous and now >= previous and now - previous <= 10 then
        local seconds = now - previous
        if seconds > 0 then
            -- Attribute the interval to the model being studied when it began.
            addReviewSeconds(self._clock_last_mode or mode, seconds, previous)
        end
    end
    self._clock_last = (active and mode) and now or nil
    self._clock_last_mode = mode
    if flush or (ReviewClock.dirty
            and now - (self._clock_saved_at or 0) >= 45) then
        if saveReviewClock() then self._clock_saved_at = now end
    end
end

function Flashcards:_stopReviewClock()
    if self._clock_action then
        UIManager:unschedule(self._clock_action)
        self._clock_action = nil
    end
    self:_clockPulse(true)
end

-- Cancel only our own scheduled UI callbacks. In particular, never cancel
-- the KOReader screensaver's or another plugin's tasks.
function Flashcards:_cancelWakeTasks()
    if self._resume_action then
        UIManager:unschedule(self._resume_action)
        self._resume_action = nil
    end
    if self._recover_action then
        UIManager:unschedule(self._recover_action)
        self._recover_action = nil
    end
end

-- The Kindle may display the cover *before* KOReader broadcasts Suspend.
-- Our timer guards also check Device.screen_saver_mode, so the earlier phase
-- cannot race a newly due review or an already queued recovery callback.
function Flashcards:_pauseForSleep()
    if self._closing or self._sleep_paused then return end
    self:_stopReviewClock() -- flush accumulated study time before sleeping
    self._sleep_paused = true
    self._clock_last, self._clock_last_mode = nil, nil
    self:_stopDueWatch()
    self:_cancelWakeTasks()
end

function Flashcards:_armReviewClock()
    if self._closing or self._clock_action or self._sleep_paused then return end
    if Device.screen_saver_mode then
        self:_pauseForSleep()
        return
    end
    self:_clockPulse(false)
    local action
    action = function()
        if self._clock_action ~= action then return end
        self._clock_action = nil
        if self._closing or not UIManager:isWidgetShown(self) then
            self:_clockPulse(true)
            return
        end
        if self._sleep_paused or Device.screen_saver_mode then
            self:_pauseForSleep()
            return
        end
        self:_clockPulse(false)
        self:_armReviewClock()
    end
    self._clock_action = action
    -- No screen repaint is requested by this timer.
    UIManager:scheduleIn(5, action)
end

-- Contextual Retrieval is an ALTERNATIVE presentation for a due review.
-- Recalled it / Did not recall are the actual native SRS responses; the word
-- is not immediately re-tested in Meaning Recall during the same review.
-- Native underscores are ordinary glyphs shaped by KOReader's text renderer.
-- Measure with the active face so the blank grows/shrinks with the word; a
-- count-only fallback is used only when the text geometry is unavailable.
local function maskSelectedWord(sentence, face)
    if type(sentence) ~= "string" then return nil end
    local function nativeUnderscoresForWord(word, face)
    local count = math.max(1, math.min(60, #util.splitToChars(word)))
    if face then
        local word_measure = TextWidget:new{ text = word, face = face }
        local underscore_measure = TextWidget:new{ text = "_", face = face }
        local word_w = word_measure:getSize().w
        local underscore_w = underscore_measure:getSize().w
        word_measure:free()
        underscore_measure:free()
        if word_w > 0 and underscore_w > 0 then
            count = math.max(1, math.min(60,
                math.floor(word_w / underscore_w + 0.35)))
        end
    end
    return string.rep("_", count)
    end
    -- The helper marks only the selected occurrence; do not mask other words
    -- with the same spelling elsewhere in the saved context.
    local masked, count = sentence:gsub("【(.-)】", function(word)
        return nativeUnderscoresForWord(word, face)
    end, 1)
    return count == 1 and masked or nil
end

local function revealSelectedWord(sentence)
    if type(sentence) ~= "string" then return nil end
    -- Keep the ORIGINAL sentence in place. The full-sentence helper marks
    -- only the selected occurrence with 【...】; preserve conjugation and
    -- inflection (e.g. the vocabulary key "vent" is shown as 【vented】).
    local revealed, count = sentence:gsub("【(.-)】", "【%1】", 1)
    return count == 1 and revealed or nil
end

-- U+2060 WORD JOINER is invisible and zero-width.  It prevents a long
-- highlighted inflection from orphaning its closing bracket on a new line.
-- It is presentation-only: saved context, lookup key and SRS data stay intact.
function Flash.protectSelectedBrackets(sentence)
    if type(sentence) ~= "string" then return sentence end
    return (sentence:gsub("【(.-)】", function(word)
        word = word:gsub("\226\129\160", "")
        return "【" .. "\226\129\160" .. word .. "\226\129\160" .. "】"
    end, 1))
end

-- Do not scale a complete paragraph to make one bracketed token fit.  Its
-- selected Aa font size is always honoured.  Unbreakable tokens are protected
-- by the original WORD JOINER logic; as with any text renderer, an unusually
-- long word may have to wrap on a screen narrower than the word itself.
function Flash.fitUnbreakableToken(font_id, size, width, sentence)
    return size
end


-- Native, fixed-layout cloze: NEVER paint the selected letters while masked.
-- The former implementation painted the whole sentence and then covered
-- 【word】 with a white rectangle. That necessarily clipped surrounding
-- descenders and occasionally left ink from the answer visible. Here the
-- sentence is wrapped and measured ONCE, and only the selected glyphs are
-- omitted when producing the masked text bitmap. The original KOReader
-- typography (including the same line breaks and centered positions) stays
-- intact on both sides of the card.
--
-- XText: flag only selected shaped glyphs as no_drawing, a property that
-- KOReader itself honours in TextBoxWidget:_renderText(). Advances and
-- line metrics are untouched. Non-XText: draw the two visible runs with
-- native RenderText into an empty text bitmap at their ORIGINAL pen X.
-- Neither path draws a covering rectangle or the hidden answer's ink.
local function makeFixedClozeBox(marked_sentence, face, width, alignment, owner)
    if type(marked_sentence) ~= "string" then return nil end
    local prefix, inflected, suffix = marked_sentence:match("^(.-)【(.-)】(.*)$")
    if not prefix or inflected == "" or not inflected then return nil end
    local answer = "【" .. inflected .. "】"
    local start_idx = #util.splitToChars(prefix) + 1
    local end_idx = start_idx + #util.splitToChars(answer) - 1
    local box = TextBoxWidget:new{
        text = prefix .. answer .. suffix,
        face = face,
        width = width,
        alignment = alignment,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    if type(box._renderText) ~= "function" or not box._bb then
        if box.free then box:free() end
        return nil
    end
    local line_count = #(box.vertical_string_list or {})
    if line_count == 0 then
        if box.free then box:free() end
        return nil
    end
    -- Must be queried while the complete, revealed glyph list is available:
    -- getXtextHighlightRects deliberately ignores no_drawing glyphs.
    local function highlightRects(first, last)
        local getter = box.use_xtext and box.getXtextHighlightRects
            or box.getNonXtextHighlightRects
        if type(getter) ~= "function" then return nil end
        local ok, regions = pcall(getter, box, first, last, 1, line_count)
        if not ok or type(regions) ~= "table" then return nil end
        if not box.use_xtext then
            -- Legacy KOReader highlight X is relative to each line, unlike
            -- XText. Convert it to the same centered/right-aligned geometry.
            for _, r in ipairs(regions) do
                local line_h = tonumber(box.line_height_px) or 0
                local n = line_h > 0 and math.floor(r.y / line_h) + 1 or 1
                local line = box.vertical_string_list[n]
                if line then
                    if alignment == "center" then
                        r.x = r.x + math.floor((width - line.width) / 2)
                    elseif alignment == "right" then
                        r.x = r.x + math.floor(width - line.width)
                    end
                end
            end
        end
        return regions
    end
    local whole_rects = highlightRects(start_idx, end_idx)
    local word_rects = highlightRects(start_idx + 1, end_idx - 1)
    if not whole_rects or #whole_rects == 0 or
            not word_rects or #word_rects == 0 then
        if box.free then box:free() end
        return nil
    end

    local placeholders, dirty_rects = {}, {}
    local line_h = tonumber(box.line_height_px) or 0
    if line_h <= 0 then
        if box.free then box:free() end
        return nil
    end
    local unit = TextWidget:new{ text = "_", face = box.face }
    local unit_w = math.max(1, unit:getSize().w)
    unit:free()
    for _, r in ipairs(word_rects) do
        if type(r.x) ~= "number" or type(r.y) ~= "number" or
                type(r.w) ~= "number" or type(r.h) ~= "number" or
                r.w <= 0 or r.h <= 0 or r.x < -1 or r.x > width + 1 then
            if box.free then box:free() end
            for _, p in ipairs(placeholders) do p.widget:free() end
            return nil
        end
        -- Each wrapped fragment gets only underscores within its own word
        -- width. No underscores for 【 or 】, and no string replacements that
        -- could change wrapping, sentence centering or punctuation.
        local available = math.min(width - math.max(0, r.x), r.w)
        local count = math.max(1, math.min(80,
            math.floor(available / unit_w + 0.15)))
        local glyph = TextWidget:new{
            text = string.rep("_", count),
            face = box.face, fgcolor = Blitbuffer.COLOR_BLACK,
        }
        while count > 1 and glyph:getSize().w > available do
            glyph:free()
            count = count - 1
            glyph = TextWidget:new{
                text = string.rep("_", count),
                face = box.face, fgcolor = Blitbuffer.COLOR_BLACK,
            }
        end
        local glyph_size = glyph:getSize()
        local glyph_baseline = glyph:getBaseline()
        local row = math.floor(r.y / line_h)
        local gx = math.floor(r.x + (r.w - glyph_size.w) / 2)
        gx = math.max(0, math.min(width - glyph_size.w, gx))
        local gy = row * line_h + box.line_glyph_baseline - glyph_baseline
        placeholders[#placeholders + 1] = { widget = glyph, x = gx, y = gy }
    end
    -- Invalidate complete line-height slots rather than the tight glyph
    -- boxes: when a word has a descender, old eink ink must also refresh.
    for _, r in ipairs(whole_rects) do
        local row = math.floor(r.y / line_h)
        dirty_rects[#dirty_rects + 1] = {
            x = 0, y = math.max(0, row * line_h - 2),
            w = width, h = line_h + (box.line_glyph_extra_height or 0) + 4,
        }
    end
    box._flash_cloze_rects = dirty_rects
    box._flash_fixed_cloze = true
    box._flash_masked = false

    local native_render = box._renderText
    local glyph_flags = {}
    if box.use_xtext then
        -- _renderText has already shaped these lines during init(). Save
        -- their original flags (tabs may already have no_drawing=true).
        for _, line in ipairs(box.vertical_string_list) do
            if type(line.xglyphs) ~= "table" then
                -- Empty lines have no glyphs. A nonempty unshaped line is
                -- unsupported: fall back to pre-render masking instead.
                if line.end_offset and line.end_offset >= line.offset then
                    for _, p in ipairs(placeholders) do p.widget:free() end
                    if box.free then box:free() end
                    return nil
                end
            else
                for _, g in ipairs(line.xglyphs) do
                    if g.text_index and g.text_index >= start_idx
                            and g.text_index <= end_idx then
                        glyph_flags[#glyph_flags + 1] = {
                            glyph = g, original = g.no_drawing,
                        }
                    end
                end
            end
        end
        if #glyph_flags == 0 then
            for _, p in ipairs(placeholders) do p.widget:free() end
            if box.free then box:free() end
            return nil
        end
    else
        if not box.charlist or not box.char_width or not box.idx_pad then
            for _, p in ipairs(placeholders) do p.widget:free() end
            if box.free then box:free() end
            return nil
        end
    end

    local function legacyMaskedRender(self)
        local RenderText = require("ui/rendertext")
        -- Render ONLY the visible runs into a new blank bitmap. These are
        -- drawn by the same KOReader RenderText routine used in TextBoxWidget,
        -- with the original per-character advances and line alignments.
        -- No white overlay and not one pixel of the answer is painted.
        local old = self._bb
        local fresh = Blitbuffer.new(self.width, old:getHeight(), old:getType())
        fresh:fill(self.bgcolor)
        self._bb = fresh
        old:free()
        local chars = self.charlist
        local widths = self.char_width
        local idx_pad = self.idx_pad
        for row, line in ipairs(self.vertical_string_list) do
            if line.end_offset and line.offset and line.end_offset >= line.offset then
                local x = 0
                if alignment == "center" then
                    x = (self.width - line.width) / 2
                elseif alignment == "right" then
                    x = self.width - line.width
                end
                local y = self.line_glyph_baseline + (row - 1) * line_h
                local seg_first, seg_x = nil, x
                local function drawVisible(last)
                    if not seg_first or seg_first > last then return end
                    local pads = {}
                    for j = seg_first, last do
                        pads[#pads + 1] = idx_pad[j] or 0
                    end
                    RenderText:renderUtf8Text(self._bb, seg_x, y,
                        self.face, table.concat(chars, "", seg_first, last),
                        true, self.bold, self.fgcolor, nil, pads)
                end
                for i = line.offset, line.end_offset do
                    local masked = i >= start_idx and i <= end_idx
                    if masked then
                        if seg_first then
                            drawVisible(i - 1)
                            seg_first = nil
                        end
                    elseif not seg_first then
                        seg_first, seg_x = i, x
                    end
                    x = x + (widths[chars[i]] or 0) + (idx_pad[i] or 0)
                end
                if seg_first then drawVisible(line.end_offset) end
            end
        end
    end

    function box:_flash_set_masked(masked)
        masked = masked == true
        if self._flash_masked == masked then return true end
        local ok, err = pcall(function()
            if self.use_xtext then
                for _, item in ipairs(glyph_flags) do
                    item.glyph.no_drawing = masked and true or item.original
                end
                native_render(self, self.virtual_line_num,
                    self.virtual_line_num + self.lines_per_page - 1)
            elseif masked then
                legacyMaskedRender(self)
            else
                native_render(self, self.virtual_line_num,
                    self.virtual_line_num + self.lines_per_page - 1)
            end
        end)
        if not ok then
            logger.warn("flipside: native cloze render failed", err)
            return false
        end
        self._flash_masked = masked
        return true
    end
    local native_paint = box.paintTo
    function box:paintTo(bb, x, y)
        native_paint(self, bb, x, y)
        if self._flash_masked then
            for _, p in ipairs(placeholders) do
                p.widget:paintTo(bb, x + p.x, y + p.y)
            end
        end
    end
    local native_free = box.free
    function box:free(full)
        for _, p in ipairs(placeholders) do
            if p.widget then p.widget:free(); p.widget = nil end
        end
        if native_free then native_free(self, full) end
    end
    -- No visible frame is ever painted with the answer in a masked state.
    if not box:_flash_set_masked(owner.dual_phase == "cloze") then
        box:free()
        return nil
    end
    return box
end

local function makeContextCloze(card)
    local sentence = maskSelectedWord(buildSentence(card))
    if not sentence then return nil end
    -- A word with no useful saved surrounding text is not a cloze exercise.
    local clue = (tostring(card.prev or "") .. tostring(card.next or ""))
        :gsub("%s+", "")
    if #clue < 4 then return nil end
    return sentence
end

function Flashcards:_resetDualCard()
    self.dual_card = nil
    self.dual_phase = nil
end

-- Sentence Card only is a *global* choice, not a fallback behind older
-- overrides saved by the per-card switch. Do not delete those preferences:
-- they become applicable again if the reader returns to another strategy.
-- New per-card switches made in Sentence Card mode use an independent map.
function Flashcards:_strategyForCard(card)
    local modes = self.dual_strategy == "sentence"
        and self.sentence_card_modes or self.card_modes
    local mode = card and modes and modes[card.word]
    if mode == "meaning" or mode == "contextual" or mode == "sentence" then
        return mode
    end
    return self.dual_strategy
end

-- Switch only the card currently on screen. Never write DUAL_STRATEGY_KEY:
-- doing so would change every other card. Explicit overrides survive reloads,
-- navigation, review rounds, and KOReader restarts.
function Flashcards:toggleManualRetrievalMode()
    if self.busy or self.state ~= "card" then return true end
    local card = self.cards and self.cards[self.idx]
    if not card or type(card.word) ~= "string" or card.word == "" then return true end
    self:_clockPulse(false)
    self:_clockTouch()
    -- The switch cycles only this card: word -> cloze -> saved sentence.
    -- Never mutate the global review strategy or other words' overrides.
    local current = self:_strategyForCard(card)
    local next_mode = current == "contextual" and "sentence"
        or current == "sentence" and "meaning" or "contextual"
    local sentence_global = self.dual_strategy == "sentence"
    local active_modes = sentence_global and self.sentence_card_modes or self.card_modes
    local preference_key = sentence_global
        and DUAL_SENTENCE_CARD_MODES_KEY or DUAL_CARD_MODES_KEY
    local updated = {}
    for word, mode in pairs(active_modes or {}) do updated[word] = mode end
    updated[card.word] = next_mode
    local ok, result = pcall(function()
        G_reader_settings:saveSetting(preference_key, updated)
        return G_reader_settings:flush()
    end)
    if not ok or result == false then
        logger.warn("vocab flashcards: could not save per-card review mode:", result)
        UIManager:show(newFlashInfo(self, {
            text = _("Could not save this card's review mode."),
            timeout = 4,
        }))
        return true
    end
    if sentence_global then self.sentence_card_modes = updated
    else self.card_modes = updated end
    self:_resetDualCard()
    self.show_ctx = false
    self.show_more_ctx = false
    self:_render()
    self:_refresh()
    return true
end

function Flashcards:_prepareDualCard(card)
    if self.dual_card == card and self.dual_phase then return end
    self.dual_card = card
    self.dual_phase = "meaning"
    local strategy = self:_strategyForCard(card)
    if strategy == "off" or strategy == "meaning" then return end
    if strategy == "sentence" then
        -- Third display-only style: always show the original saved sentence
        -- with its highlighted occurrence between brackets, never a cloze.
        self.dual_phase = "sentence"
        return
    end
    if not makeContextCloze(card) then return end
    if self.retry_round then
        -- Reinforce a failed Contextual review with the SAME cloze exercise;
        -- no KOReader or Adaptive update occurs during reinforcement.
        if strategy == "contextual"
                or (strategy == "adaptive"
                    and card._dual_answer_mode == "contextual") then
            self.dual_phase = "cloze"
        end
        return
    end
    if strategy == "contextual" then
        self.dual_phase = "cloze"
        return
    end
    -- TWO successful, scheduled Meaning Recall reviews recorded by this
    -- feature are required. Native streak_count may contain years of older
    -- Vocabulary Builder reviews and MUST NOT unlock contextual exercises.
    -- After each contextual review, another two meaning successes are needed.
    local history = dualEntryFor(card.word)
    local streak = tonumber(history and history.meaning_streak) or 0
    local since = tonumber(history and history.meaning_since_context) or 0
    local target = adaptiveMeaningTarget(history)
    -- Two initial Meaning successes are mandatory; later the difficulty
    -- model may choose one, two or three new successes per context attempt.
    if streak >= 2 and since >= target then self.dual_phase = "cloze" end
end

-- Repaint only the fixed word slot and rating-buttons area. UIManager
-- still repaints the registered top-level widget into its framebuffer, but
-- the e-ink controller receives small refresh rectangles. No _render() or
-- new TextBoxWidget is needed on ordinary contextual taps.
function Flashcards:_refreshFixedCloze()
    -- setDirty(nil) bypasses widget painting: keep it out of screensavers.
    if self._closing then return end
    if self._sleep_paused or Device.screen_saver_mode then
        SleepTrace.blocked("cloze_refresh", UIManager, Device, self)
        return
    end
    local box = self.fixed_cloze_box
    if not box then
        self:_render()
        self:_refresh()
        return
    end
    -- Re-render only the shaped glyph bitmap; preserve its original layout.
    -- On failure rebuild safely instead of displaying a stale answer.
    if not box:_flash_set_masked(self.dual_phase == "cloze") then
        self:_render()
        self:_refresh()
        return
    end
    UIManager:setDirty(self, function()
        local dimen = box.dimen
        if not dimen or not dimen.x or not dimen.y then
            return "ui", self.card_rect
        end
        local left, top, right, bottom
        for _, rect in ipairs(box._flash_cloze_rects or {}) do
            local x0, y0 = dimen.x + rect.x, dimen.y + rect.y
            local x1, y1 = x0 + rect.w, y0 + rect.h
            left = math.min(left or x0, x0)
            top = math.min(top or y0, y0)
            right = math.max(right or x1, x1)
            bottom = math.max(bottom or y1, y1)
        end
        if not left then return "ui", self.card_rect end
        local x = math.max(0, math.floor(left - 4))
        local y = math.max(0, math.floor(top - 4))
        return "ui", Geom:new{
            x = x, y = y,
            w = math.max(1, math.min(Screen:getWidth() - x, math.ceil(right - x + 4))),
            h = math.max(1, math.min(Screen:getHeight() - y, math.ceil(bottom - y + 4))),
        }
    end)
    -- Buttons are visually hidden until reveal, but their fixed-height row
    -- always exists; they cannot make the sentence jump vertically.
    if self.fixed_cloze_controls then
        local rating = self.fixed_cloze_controls
        UIManager:setDirty(nil, function()
            return "ui", rating._flash_rect or Geom:new{
                x = 0, y = Screen:getHeight() - 180,
                w = Screen:getWidth(), h = 160,
            }
        end)
    end
end

function Flashcards:revealDualAnswer()
    if self.busy or self.state ~= "card" or self.dual_phase ~= "cloze" then return true end
    self.dual_phase = "revealed"
    -- No relayout: reveal the existing [word] glyphs in place.
    -- Do not change the full-context expansion state or review schedule.
    self:_refreshFixedCloze()
    return true
end

-- Hiding the answer is reversible and does NOT rate or reschedule a card.
-- The masked view restores the blank in the same sentence.
function Flashcards:hideDualAnswer()
    if self.busy or self.state ~= "card" or self.dual_phase ~= "revealed" then return true end
    self.dual_phase = "cloze"
    self:_refreshFixedCloze()
    return true
end

function Flashcards:rateDualContext(recalled)
    if self.busy or self.state ~= "card" or self.dual_phase ~= "revealed" then return true end
    -- Complete this ONE scheduled review, exactly as Forgot / Got it do.
    -- answer() records the official native schedule and moves to the next
    -- pending word. No immediate Meaning Recall step for the same card.
    return self:answer(recalled and true or false)
end

-- Inline completion view shown only when the scheduled review queue is empty.
-- It is part of the existing full-screen Flashcards widget, not a modal and
-- not a second review system. All its actions use existing native handlers.
-- Individual icon and text Buttons are native touch widgets: their normal
-- highlight/unhighlight redraws cannot leave custom ink on the e-ink display.
function Flashcards:_buildReviewCompletePanel(available_width, available_height)
    local panel_font = resolveSentenceFont(self.sentence_font) or "cfont"
    local tiny = available_height < Screen:scaleBySize(535)
    local body_size = tiny and 15 or 17
    local title_size = tiny and 21 or 25
    local line_h = tiny and Screen:scaleBySize(25) or Screen:scaleBySize(30)
    local inset = tiny and Screen:scaleBySize(8) or Screen:scaleBySize(13)
    local space = tiny and Screen:scaleBySize(4) or Screen:scaleBySize(7)
    local border = math.max(1, Size.line.thin)
    local panel_width = math.floor(available_width * 0.94)
    local body_width = panel_width - 2 * (inset + border)
    local icon_col = math.max(Screen:scaleBySize(43), math.floor(body_width * 0.18))
    local separator = math.max(1, Size.line.thin)
    local text_col = body_width - icon_col - separator
    local details = self:_completionDetails()

    -- All SVGs are shipped as tiny, locally generated monochrome icons. We
    -- never paint graphics over a Button: all clickable icons are created by
    -- the native Button -> IconWidget hierarchy (unlike the old stats glyph).
    local glyphs = {
        complete = [[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><circle cx="16" cy="16" r="13" stroke="#000" stroke-width="2.2" fill="none"/><path d="M9 16l5 5L24 11" stroke="#000" stroke-width="2.7" stroke-linecap="round" stroke-linejoin="round" fill="none"/></svg>]],
        stats = [[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><rect x="6" y="20" width="3.5" height="8" fill="#000"/><rect x="14.5" y="14" width="3.5" height="14" fill="#000"/><rect x="23" y="7" width="3.5" height="21" fill="#000"/></svg>]],
        schedule = [[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><rect x="4" y="7" width="24" height="22" rx="2" fill="none" stroke="#000" stroke-width="2"/><path d="M4 13h24M10 3v8M22 3v8" fill="none" stroke="#000" stroke-width="2"/><circle cx="10" cy="19" r="1.7"/><circle cx="17" cy="19" r="1.7"/><circle cx="24" cy="19" r="1.7"/></svg>]],
        practice = [[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><path d="M2 11L16 4l14 7-14 7zM8 15v8c5 4 11 4 16 0v-8M29 12v11" stroke="#000" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" fill="none"/></svg>]],
        back = [[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><path d="M13 5L4 15l9 9M5 15h17c5 0 7 3 7 7s-3 6-8 6" stroke="#000" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round" fill="none"/></svg>]],
    }
    local icon_paths = {}
    for name, source in pairs(glyphs) do
        local path = GeneratedIcons.path("vocab-flashcards-complete-" .. name .. ".svg")
        local existing = io.open(path, "rb")
        local same = false
        if existing then same = existing:read("*a") == source; existing:close() end
        if same then
            icon_paths[name] = path
        else
            local handle = io.open(path, "wb")
            if handle then
                local saved = handle:write(source)
                handle:close()
                if saved then icon_paths[name] = path end
            end
        end
    end
    local fallback_names = {complete="check", stats="statistics", schedule="calendar", practice="school", back="back"}
    local function glyph(name, px)
        -- For stand-alone, non-clickable header icon, use a native IconWidget.
        if icon_paths[name] then
            return IconWidget:new{file=icon_paths[name], width=px, height=px}
        end
        return IconWidget:new{icon=fallback_names[name], width=px, height=px}
    end
    local function textLine(text, size)
        local widget = TextBoxWidget:new{
            text = text,
            face = getSentenceFace(self.sentence_font, size or body_size),
            width = body_width,
            alignment = "center",
            bold = false,
        }
        return widget
    end
    local function deferred(fn)
        return function()
            UIManager:nextTick(function()
                if not self._closing and UIManager:isWidgetShown(self) then fn() end
            end)
        end
    end
    local function iconButton(name, callback)
        local id = "vocab-flashcards-complete-" .. name
        local old_init = IconWidget.init
        -- Scoped exactly like the existing stats/arrow buttons. Restore even
        -- on a constructor error; do not affect any other KOReader widget.
        if icon_paths[name] then
            IconWidget.init = function(widget)
                if widget.icon == id then widget.file = icon_paths[name] end
                return old_init(widget)
            end
        else
            id = fallback_names[name]
        end
        local ok, button = pcall(function()
            return Button:new{
                icon=id, icon_width=line_h - 8, icon_height=line_h - 8,
                width=icon_col, height=line_h,
                padding_h=Size.padding.small, padding_v=space,
                bordersize=0, radius=0, callback=callback, show_parent=self,
            }
        end)
        IconWidget.init = old_init
        if ok and button then return button end
        logger.warn("vocab flashcards: cannot build completion icon:", name, button)
        return Button:new{
            text="·", width=icon_col, height=line_h, bordersize=0,
            padding_h=Size.padding.small, padding_v=space,
            text_font_face=panel_font, text_font_size=body_size,
            text_font_bold=false, callback=callback, show_parent=self,
        }
    end
    local function actionRow(name, label, action)
        local callback = deferred(action)
        local left = iconButton(name, callback)
        local right = Button:new{
            text=label, width=text_col, height=line_h,
            align="left", bordersize=0, radius=0,
            padding_h=Size.padding.default, padding_v=space,
            text_font_face=panel_font, text_font_size=body_size,
            text_font_bold=false, callback=callback, show_parent=self,
        }
        local components = HorizontalGroup:new{
            left,
            LineWidget:new{dimen=Geom:new{w=separator, h=left:getSize().h},
                background=Blitbuffer.COLOR_DARK_GRAY},
            right,
        }
        return FrameContainer:new{
            bordersize=border, padding=0, margin=0,
            radius=Size.radius.button, background=Blitbuffer.COLOR_WHITE,
            color=Blitbuffer.COLOR_DARK_GRAY, components,
        }
    end

    local panel = VerticalGroup:new{align="center"}
    local check_px = tiny and Screen:scaleBySize(30) or Screen:scaleBySize(37)
    table.insert(panel, glyph("complete", check_px))
    table.insert(panel, VerticalSpan:new{width=space})
    table.insert(panel, textLine("Review complete", title_size))
    table.insert(panel, VerticalSpan:new{width=space})
    table.insert(panel, textLine(details.saved .. (details.saved == 1 and " saved word" or " saved words")))
    table.insert(panel, textLine("Still due today: " .. details.due .. (details.due == "1" and " card" or " cards")))
    table.insert(panel, textLine("Next review: " .. details.next_review))
    -- These are display-only summaries of the existing native due dates.
    if details.missed_review then table.insert(panel, textLine(details.missed_review)) end
    if details.correct_review then table.insert(panel, textLine(details.correct_review)) end
    if details.other_review then table.insert(panel, textLine(details.other_review)) end
    if details.due_now then table.insert(panel, textLine(details.due_now)) end
    if details.session_reviews then table.insert(panel, textLine(details.session_reviews)) end
    if self.retry_seen > 0 then
        table.insert(panel, textLine(string.format(
            "%s: %d practice attempts (%d correct, %d missed)",
            self.intensive_mode == "ultra" and "Ultra Intensive" or "Intensive",
            self.retry_seen, self.retry_got, self.retry_forgot), tiny and 13 or 15))
    end
    table.insert(panel, VerticalSpan:new{width=space * 2})
    table.insert(panel, LineWidget:new{
        dimen=Geom:new{w=body_width, h=border},
        background=Blitbuffer.COLOR_DARK_GRAY,
    })
    table.insert(panel, VerticalSpan:new{width=space * 2})

    table.insert(panel, actionRow("stats", "View statistics", function()
        self:openReviewAccuracy()
    end))
    table.insert(panel, VerticalSpan:new{width=space})
    table.insert(panel, actionRow("schedule", "Review schedule", function()
        self:openReviewSchedule()
    end))
    table.insert(panel, VerticalSpan:new{width=space})
    table.insert(panel, actionRow("practice", "Free practice", function()
        self:togglePractice()
    end))
    table.insert(panel, VerticalSpan:new{width=space})
    table.insert(panel, actionRow("back", "Close FlipSide", function()
        self:onClose()
    end))

    local frame = FrameContainer:new{
        bordersize=border, margin=0,
        padding_left=inset, padding_right=inset,
        padding_top=inset, padding_bottom=inset,
        radius=Size.radius.button, color=Blitbuffer.COLOR_DARK_GRAY,
        background=Blitbuffer.COLOR_WHITE,
        panel,
    }
    -- The normal Basic/Kindle screen has ample space. On a smaller screen,
    -- never clip four action buttons: provide a scrollable completion surface.
    if frame:getSize().h > available_height then
        logger.warn("vocab flashcards: completion panel taller than visible card area")
        -- CenterContainer would crop the edges. Place the user actions in a
        -- scrollable vertical view while keeping the original bottom buttons.
        local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
        local scrolling = ScrollableContainer:new{
            dimen=Geom:new{w=math.min(available_width, frame:getSize().w),
                h=math.max(1, available_height)},
            frame,
        }
        self.cropping_widget = scrolling
        return scrolling
    end
    return frame
end

-- Immersion is controlled by holding the TitleBar close X.
-- No extra button or reserved row is rendered on the flashcard screen.

function Flashcards:_render()
    -- Do not replace the active widget tree behind the Kindle sleep cover.
    if self._sleep_paused or Device.screen_saver_mode then
        SleepTrace.blocked("render", UIManager, Device, self)
        return
    end
    -- These refs belong to the current widget tree only.
    self.fixed_cloze_box = nil
    self.fixed_cloze_controls = nil
    self.mode_toggle_button = nil
    self.accuracy_button = nil
    self.calendar_button = nil
    self.advance_today_button = nil
    self.style_cycle_button = nil
    self.immersion_exit_rect = nil
    self.cropping_widget = nil -- no card scrolling; completion panels unchanged
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margin = Size.padding.large * 2
    local gap = Size.padding.large
    local inner_w = screen_w - 2 * margin
    local sentence_w = Flash.cardContentWidth(self.card_style, inner_w)
    -- No scroll gutter and NO per-card font size reduction. The decorators
    -- expand the frame vertically based on the measured paragraph height.
    if self.card_style ~= "default" then
        -- Width is independent of the final frame height.  Avoid a horizontal
        -- scroll bar and keep the text inside the ornamental corner insets.
        local side = math.max(Screen:scaleBySize(15), math.floor(margin * 0.76 + 0.5))
        local frame_w = screen_w - 2 * side
        local horizontal_gutter = math.max(Screen:scaleBySize(15),
            math.floor(frame_w * (self.card_style == "circuit" and 0.062 or 0.035)))
        sentence_w = math.max(1, math.min(sentence_w, frame_w - 2 * horizontal_gutter))
    end

    -- Keep the header clean: no wide framed navigation bar, no arrows.
    local title_bar = TitleBar:new{
        width = screen_w,
        align = "center",
        title = "FlipSide",
        title_face = getSentenceFace(self.sentence_font, 26),
        with_bottom_line = false,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:showMenu() end,
        -- Tapping X retains the original close action. Holding the same
        -- native KOReader X switches to immersion without closing the deck.
        close_callback = function() self:onClose() end,
        close_hold_callback = function()
            if not self.immersive then return self:setImmersion(true) end
            return true
        end,
        show_parent = self,
    }

    local function makeButton(text, width, callback, enabled, subtle)
        local button = Button:new{
            text = text,
            width = width,
            max_width = width,
            radius = Size.radius.button,
            padding_v = subtle and Size.padding.small or Size.padding.default,
            text_font_size = subtle and 17 or 22,
            text_font_face = resolveSentenceFont(self.sentence_font) or "cfont",
            bordersize = subtle and 0 or nil,
            enabled = enabled ~= false,
            callback = callback,
            show_parent = self,
        }
        local negative = text == _("Forgot") or text == "Did not recall"
        local positive = text == _("Got it") or text == "Recalled it"
        if negative or positive then
            if self.card_style == "circuit" then
                pcall(Flash.Circuit.decorateButton, button, negative)
            elseif self.card_style == "classic" then
                pcall(Flash.Classic.decorateButton, button, negative)
            elseif self.card_style == "angular" then
                pcall(Flash.Angular.decorateButton, button, negative)
            end
            -- Prevent the extra black focus blink on Kindle only for answer
            -- buttons; leave enabled checks, callbacks and the review intact.
            if Device:isKindle() and self.card_style ~= "default" then
                button.no_focus = true
                button.onTapSelectButton = function(b)
                    if (b.enabled or b.allow_tap_when_disabled) and b.callback then
                        b.callback()
                    end
                    if b.readonly ~= true then return true end
                end
            end
        elseif text == _("Delete card") and self.card_style ~= "default" then
            -- Same thin under-rule and small rising finish in all THREE
            -- framed templates. Do not style the Default's native Delete.
            -- Keep the underlying native KOReader button/callback and its
            -- touch rectangle; suppress the old rounded/square border.
            if button.frame then
                button.frame.bordersize = 0
                button.frame.radius = 0
                button.frame.background = Blitbuffer.COLOR_WHITE
                button.background = Blitbuffer.COLOR_WHITE
            end
            CardButtonStyles.decorateDelete(button)
        end
        return button
    end

    local half = math.floor((inner_w - gap) / 2)
    local undo_w = math.floor(inner_w * 0.29)
    local delete_w = math.floor(inner_w * 0.34)
    local content = VerticalGroup:new{ align = "center" }
    local progress_widget
    local controls = VerticalGroup:new{ align = "center" }
    local word_widget, word_size, word_text
    local sentence_index, sentence_spec
    -- Only tighten gaps when a large-font paragraph really needs that room.
    -- No font, glyph or line height is changed by this layout adaptation.
    local gap_indices = {}
    local function addCardGap()
        table.insert(content, VerticalSpan:new{ width = gap * 3 })
        gap_indices[#gap_indices + 1] = #content
    end
    local surrounding_text
    local show_review_complete = false

    if self.state == "card" then
        local card = self.cards[self.idx]
        self:_prepareDualCard(card)
        local contextual_step = self.dual_phase == "cloze"
            or self.dual_phase == "revealed"
        local inspecting = self._inspection_cursor ~= nil
        local official_n = #self.cards
        for _, candidate in ipairs(self.cards) do
            if candidate._training_only then official_n = official_n - 1 end
        end
        local progress_text = inspecting
            and T("Previously reviewed · %1/%2", self._inspection_cursor, #self.history)
            or self.retry_round
            and T("%1 · %2 cards left", self.intensive_mode == "ultra"
                and "Ultra Intensive" or "Intensive",
                self.training and (self.training:pending() + 1) or 1)
            or T(_("%1 / %2"), self.idx, official_n)
        progress_widget = TextBoxWidget:new{
            text = progress_text,
            face = getSentenceFace(self.sentence_font, 17),
            width = sentence_w,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(content, progress_widget)
        -- Keep both flashcard faces quiet and focused on the actual prompt.
        -- Mode names remain in settings/statistics, never on the card itself.
        addCardGap()
        if self.dual_phase == "sentence" then
            -- Sentence Card shows its saved sentence immediately, and can
            -- independently expand/collapse the saved surrounding excerpt.
            -- This affects the displayed text only, never answer/SRS state.
            local source_text = self.show_more_ctx
                and (buildSurrounding(card) or buildSentence(card))
                or buildSentence(card)
            local sentence = Flash.protectSelectedBrackets(
                revealSelectedWord(source_text))
            sentence_spec = {
                text = sentence or _("No saved context for this word."),
                font_size = Flash.fitUnbreakableToken(self.sentence_font,
                    self.sentence_size, sentence_w, sentence),
                width = sentence_w,
                alignment = "center",
                fgcolor = sentence and Blitbuffer.COLOR_BLACK
                    or Blitbuffer.COLOR_DARK_GRAY,
            }
            sentence_index = #content + 1
            table.insert(content, TextBoxWidget:new{
                text = sentence_spec.text,
                face = getSentenceFace(self.sentence_font, sentence_spec.font_size),
                width = sentence_spec.width,
                alignment = "center",
                fgcolor = sentence_spec.fgcolor,
            })
        elseif contextual_step then
            -- Both sides of a contextual card occupy the SAME sentence face.
            -- A single tap changes only the selected span: _____ <-> 【word】.
            -- A double tap can independently expand the original context.
            local saved_text = self.show_more_ctx
                and (buildSurrounding(card) or buildSentence(card))
                or buildSentence(card)
            local fixed_text = Flash.protectSelectedBrackets(saved_text)
            local contextual_size = Flash.fitUnbreakableToken(self.sentence_font,
                self.sentence_size, sentence_w, fixed_text)
            local current_face = getSentenceFace(self.sentence_font, contextual_size)
            local sentence_text = self.dual_phase == "revealed"
                and revealSelectedWord(fixed_text)
                or maskSelectedWord(fixed_text, current_face)
            if not sentence_text then
                fixed_text = Flash.protectSelectedBrackets(buildSentence(card))
                contextual_size = Flash.fitUnbreakableToken(self.sentence_font,
                    self.sentence_size, sentence_w, fixed_text)
                current_face = getSentenceFace(self.sentence_font, contextual_size)
                sentence_text = self.dual_phase == "revealed"
                    and revealSelectedWord(fixed_text)
                    or maskSelectedWord(fixed_text, current_face)
            end
            sentence_spec = {
                text = sentence_text or _("No saved context for this word."),
                marked = fixed_text,
                is_contextual = true,
                font_size = contextual_size,
                width = sentence_w,
                alignment = "center",
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            sentence_index = #content + 1
            table.insert(content,
                makeFixedClozeBox(sentence_spec.marked,
                    getSentenceFace(self.sentence_font, sentence_spec.font_size),
                    sentence_spec.width, "center", self)
                or TextBoxWidget:new{
                    text = sentence_spec.text,
                    face = getSentenceFace(self.sentence_font, sentence_spec.font_size),
                    width = sentence_spec.width,
                    alignment = "center",
                })
        else
        -- Longer entries need a slightly smaller type size to avoid crowding.
        word_size = #card.word > 35 and 32 or (#card.word > 20 and 38 or 46)
        word_text = card.word
        -- The Meaning Recall front always shows its one headword in bold.
        -- Context sentences and bracketed terms keep their normal weight.
        local word_face = getSentenceFace(self.sentence_font, word_size)
        while word_size > 13 do
            local measure = TextWidget:new{
                text = card.word, face = word_face, bold = true,
            }
            local fits = measure:getSize().w <= sentence_w
            measure:free()
            if fits then break end
            word_size = word_size - 1
            word_face = getSentenceFace(self.sentence_font, word_size)
        end
        word_widget = TextBoxWidget:new{
            text = card.word,
            face = word_face,
            bold = true,
            width = sentence_w,
            alignment = "center",
        }
        table.insert(content, word_widget)
        if self.show_ctx then
            local sentence = buildSentence(card)
            surrounding_text = buildSurrounding(card)
            if self.show_more_ctx and surrounding_text then
                sentence = surrounding_text
            end
            sentence = Flash.protectSelectedBrackets(sentence)
            addCardGap()
            sentence_spec = {
                text = sentence or _("No saved context for this word."),
                font_size = Flash.fitUnbreakableToken(self.sentence_font,
                    self.sentence_size, sentence_w, sentence),
                width = sentence_w,
                alignment = "center",
                fgcolor = sentence and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            }
            local face = getSentenceFace(self.sentence_font, sentence_spec.font_size)
            sentence_index = #content + 1
            table.insert(content, TextBoxWidget:new{
                text = sentence_spec.text,
                face = face,
                width = sentence_spec.width,
                alignment = sentence_spec.alignment,
                fgcolor = sentence_spec.fgcolor,
            })
        end
        end -- normal Meaning Recall screen

        if inspecting then
            -- No redundant Review saved message. The original Undo is intact:
            -- only the latest confirmed review can be undone.
            local newest = self._inspection_cursor == #self.history
            table.insert(controls, HorizontalGroup:new{
                makeButton(_("Undo"), half,
                    function() self:confirmUndo() end, newest, true),
                HorizontalSpan:new{ width = gap },
                makeButton("Continue", half,
                    function() self:inspectNext() end),
            })
        else
        -- Pending cards have not been answered and therefore have no Undo.
        -- Keep the original Delete card action and answer controls unchanged.
        if not self.immersive then
            table.insert(controls, HorizontalGroup:new{
                makeButton(_("Delete card"), delete_w,
                    function() self:confirmDeleteCard() end, true, true),
                HorizontalSpan:new{ width = inner_w - delete_w },
            })
            table.insert(controls, VerticalSpan:new{ width = gap })
        end
        if contextual_step then
            -- Always reserve the rating row's height, even while the word
            -- is masked. Showing the buttons cannot move the sentence.
            local rating = HorizontalGroup:new{
                makeButton("Did not recall", half,
                    function() self:rateDualContext(false) end),
                HorizontalSpan:new{ width = gap },
                makeButton("Recalled it", half,
                    function() self:rateDualContext(true) end),
            }
            local original_paint = rating.paintTo
            function rating:paintTo(bb, x, y)
                local size = self:getSize()
                self._flash_rect = Geom:new{ x = x, y = y, w = size.w, h = size.h }
                if self._flash_owner.dual_phase == "revealed" then
                    return original_paint(self, bb, x, y)
                end
            end
            rating._flash_owner = self
            self.fixed_cloze_controls = rating
            table.insert(controls, rating)
        else
            table.insert(controls, HorizontalGroup:new{
                makeButton(_("Forgot"), half, function() self:answer(false) end),
                HorizontalSpan:new{ width = gap },
                makeButton(_("Got it"), half, function() self:answer(true) end),
            })
        end
        if self.practice and not self.immersive then
            table.insert(controls, VerticalSpan:new{ width = gap })
            table.insert(controls, TextBoxWidget:new{
                text = _("Practice only · review dates stay unchanged"),
                face = getSentenceFace(self.sentence_font, 13),
                width = inner_w,
                alignment = "center",
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            })
        end
        end -- normal, non-inspection review controls
    else
        if not self.practice and (self._flipside_completion_overlay_depth or 0) > 0 then
            -- An existing modal (Statistics, Study Calendar or the main menu)
            -- owns the foreground. Hide BOTH the completed-review panel and
            -- its bottom buttons until it closes. This avoids overlap at any
            -- resolution, orientation or DPI without guessing popup sizes.
        elseif not self.practice then
            -- Completion appears *in place* of the old empty/finished text,
            -- never as a floating dialog. Bottom controls stay visible.
            show_review_complete = true
            local can_practice = #(self.all_cards or {}) > 0
            table.insert(controls, HorizontalGroup:new{
                makeButton(can_practice and "Practice words" or "Choose collection",
                    half, function()
                        if can_practice then self:togglePractice()
                        else self:showFilterPicker() end
                    end),
                HorizontalSpan:new{width=gap},
                makeButton("Reload", half, function() self:reloadNow() end),
            })
        else
            -- Keep the pre-existing practice-only UI and actions unchanged.
            local msg
            if self.state == "empty" then
                msg = (self.filter.kind == "never_reviewed")
                    and _("No never-reviewed words in this collection.")
                    or (self.practice and _("No words in this collection.")
                        or _("No reviews due right now."))
                local note = self:_emptyNote()
                if note then msg = msg .. "\n" .. note end
            else
                local mode = self.practice and _("Practice finished.") or _("Review finished.")
                msg = T(_("%1\n%2 words: %3 got it, %4 forgot."),
                    mode, self.got + self.forgot, self.got, self.forgot)
                if self.retry_total > 0 then
                    msg = msg .. "\n" .. T(_("Missed cards practiced again: %1 (%2 remembered, %3 missed)."),
                        self.retry_seen, self.retry_got, self.retry_forgot)
                    msg = msg .. "\n" .. _("Retry practice did not change review dates.")
                end
                if not self.practice then
                    local schedule = self:_scheduleSummary()
                    if schedule then msg = msg .. "\n" .. schedule end
                    if self.dual_meaning_total > 0 then
                        msg = msg .. "\n" .. T("Meaning Recall: %1/%2 remembered",
                            self.dual_meaning_correct, self.dual_meaning_total)
                    end
                    if self.dual_context_total > 0 then
                        msg = msg .. "\n" .. T("Contextual Retrieval: %1/%2 recalled",
                            self.dual_context_correct, self.dual_context_total)
                    end
                end
            end
            local today_remaining = self:_remainingTodayLabel()
            if today_remaining then msg = msg .. "\n" .. today_remaining end
            table.insert(content, TextBoxWidget:new{
                text = msg,
                face = getSentenceFace(self.sentence_font, 23),
                width = inner_w,
                alignment = "center",
            })
            if self.state == "empty" then
                local can_practice = not self.practice and #(self.all_cards or {}) > 0
                local action = can_practice and _("Practice words") or _("Choose collection")
                table.insert(controls, HorizontalGroup:new{
                    makeButton(action, half, function()
                        if can_practice then self:togglePractice()
                        else self:showFilterPicker() end
                    end),
                    HorizontalSpan:new{ width = gap },
                    makeButton(_("Reload"), half, function() self:reloadNow() end),
                })
            elseif #self.history > 0 then
                table.insert(controls, HorizontalGroup:new{
                    makeButton("Reviewed cards", half,
                        function() self:inspectPrevious() end),
                    HorizontalSpan:new{ width = gap },
                    makeButton(_("Close"), half, function() self:onClose() end),
                })
            else
                table.insert(controls, makeButton(_("Close"), inner_w, function() self:onClose() end))
            end
        end
    end
    table.insert(controls, VerticalSpan:new{ width = margin })

    -- The header matches the quiet, monochrome, two-tier KOReader design:
    --  * rounded collection/Aa/Due selection bar spanning the card width
    --  * centered pill containing only the mode-switch glyph and a bar chart
    -- Both frames use KOReader's own FrameContainer renderer and Button touch
    -- widgets, so no overlay intercepts the native gesture or hamburger menu.
    local opts = self:_filterOptions()
    local current = opts[1]
    for _i, option in ipairs(opts) do
        if sameFilter(option, self.filter) then current = option break end
    end
    local active_n = 1
    for i, selected in ipairs(self.selected_filters or {}) do
        if sameFilter(selected, self.filter) then active_n = i break end
    end
    local groups_n = #(self.selected_filters or {})
    local visible_collection = current.kind == "book" and _("Selected book") or current.label
    local select_text = visible_collection .. " (" .. current.count .. ")"
        .. (groups_n > 1 and ("  " .. active_n .. "/" .. groups_n) or "") .. "  ▾"
    local mode_text = self.practice and _("Practice")
        or (self.filter.kind == "never_reviewed" and _("First review") or _("Due"))

    local outline = math.max(1, Size.border.thin)
    local horizontal_inset = math.max(2, math.floor(gap * 0.35))
    local vertical_inset = math.max(1, math.floor(gap * 0.22))
    local bar_inner_w = inner_w - 2 * (outline + horizontal_inset)
    local separator_w = math.max(1, Size.line.thin)
    local collection_w = math.floor((bar_inner_w - separator_w) * 0.61)
    local appearance_w = math.floor((bar_inner_w - separator_w) * 0.17)
    local due_w = bar_inner_w - separator_w - collection_w - appearance_w

    local collection_button = makeButton(select_text, collection_w,
        function() self:showFilterPicker() end, true, true)
    local appearance_button = makeButton("Aa", appearance_w,
        function() self:showSentenceAppearance() end, true, true)
    local due_button = makeButton(mode_text, due_w,
        function() self:togglePractice() end, true, true)
    local header_separator_h = math.max(10, math.floor(due_button:getSize().h * 0.66))
    local filter_contents = HorizontalGroup:new{
        collection_button,
        appearance_button,
        LineWidget:new{
            dimen = Geom:new{ w = separator_w, h = header_separator_h },
            background = Blitbuffer.COLOR_DARK_GRAY,
        },
        due_button,
    }
    local filter_bar = FrameContainer:new{
        bordersize = outline,
        padding_left = horizontal_inset, padding_right = horizontal_inset,
        padding_top = vertical_inset, padding_bottom = vertical_inset,
        margin = 0,
        radius = math.floor(filter_contents:getSize().h / 2) + vertical_inset,
        color = Blitbuffer.COLOR_DARK_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        filter_contents,
    }

    -- Both controls remain real, touch-enabled KOReader Buttons. In particular,
    -- the statistics glyph is an IconWidget INSIDE the Button's label container;
    -- never paint graphics over a Button after Button:paintTo(), because KOReader's
    -- temporary touch-feedback repaint would skip those graphics (and leave a
    -- persistent black/inverted region on certain e-ink screens).
    --
    -- The SVG is local and monochrome. Persist it once in the writable KOReader
    -- data directory so it needs no additional installation or network access.
    -- Temporarily resolve only this private icon while the Button is built;
    -- restore IconWidget.init immediately, so no other icon or plugin changes.
    local utility_w = math.max(Screen:scaleBySize(42), math.floor(inner_w * 0.17))
    -- Six equal-height native buttons within the same responsive pill.
    -- Scale to the available width, including separators and frame padding.
    utility_w = math.min(utility_w,
        math.floor((inner_w - 2 * outline - 2 * Size.padding.small
            - 5 * separator_w - 4) / 6))
    local function utilityButton(label, callback, enabled, icon_size)
        local button_opts = {
            width = utility_w,
            bordersize = 0,
            radius = 0,
            padding_h = Size.padding.small,
            padding_v = math.max(Size.padding.small, math.floor(gap * 0.48)),
            text_font_size = 22,
            text_font_face = resolveSentenceFont(self.sentence_font) or "cfont",
            text_font_bold = false,
            enabled = enabled ~= false,
            callback = callback,
            show_parent = self,
        }
        if icon_size then
            button_opts.icon = label
            button_opts.icon_width = icon_size
            button_opts.icon_height = icon_size
            -- Keep the button's height as close as possible to the ⇄ text
            -- button. Both have the same width, padding, and event handlers.
            button_opts.height = self.mode_toggle_button.label_widget:getSize().h
        else
            button_opts.text = label
        end
        return Button:new(button_opts)
    end
    self.mode_toggle_button = utilityButton("⇄",
        function() self:toggleManualRetrievalMode() end, self.state == "card")
    if self.state ~= "card" then
        self.mode_toggle_button:disableWithoutDimming()
    end

    -- Use a second native IconWidget for the mode switch so both icons have
    -- comparable black ink weight and identical rendering on e-ink.
    local arrows_svg = [[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
<path d="M4 11H27M27 11L21 5M27 11L21 17M28 22H5M5 22L11 16M5 22L11 28" fill="none" stroke="#000000" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>
</svg>]]
    local arrows_path = GeneratedIcons.path("vocab-flashcards-switch-bold.svg")
    local mode_icon_px = self.mode_toggle_button.label_widget:getSize().h
    local function ensureArrowsIcon()
        local file = io.open(arrows_path, "rb")
        if file then
            local old = file:read("*a")
            file:close()
            if old == arrows_svg then return true end
        end
        file = io.open(arrows_path, "wb")
        if not file then return false end
        local ok = file:write(arrows_svg)
        file:close()
        return ok ~= nil
    end
    local arrows_ok, arrows_ready = pcall(ensureArrowsIcon)
    if arrows_ok and arrows_ready then
        local old_icon_init = IconWidget.init
        IconWidget.init = function(widget)
            if widget.icon == "vocab-flashcards-switch-bold" then
                widget.file = arrows_path
            end
            return old_icon_init(widget)
        end
        local built, b = pcall(utilityButton, "vocab-flashcards-switch-bold",
            function() self:toggleManualRetrievalMode() end,
            self.state == "card", mode_icon_px)
        IconWidget.init = old_icon_init
        if built and b then
            self.mode_toggle_button = b
            if self.state ~= "card" then self.mode_toggle_button:disableWithoutDimming() end
        else
            logger.warn("vocab flashcards: cannot build bold switch icon:", b)
        end
    end

    local bars_svg = [[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
<rect x="6" y="20" width="3.5" height="8" fill="#000000"/>
<rect x="14.5" y="14" width="3.5" height="14" fill="#000000"/>
<rect x="23" y="7" width="3.5" height="21" fill="#000000"/>
</svg>]]
    local icon_path = GeneratedIcons.path("vocab-flashcards-statistics-bars.svg")
    local function ensureStatisticsIcon()
        local existing = io.open(icon_path, "rb")
        if existing then
            local old = existing:read("*a")
            existing:close()
            if old == bars_svg then return true end
        end
        local file = io.open(icon_path, "wb")
        if not file then return false end
        local ok = file:write(bars_svg)
        file:close()
        return ok ~= nil
    end
    local function statisticsCallback()
        self:openReviewAccuracy()
    end
    local icon_ok, icon_ready = pcall(ensureStatisticsIcon)
    if icon_ok and icon_ready then
        -- The Button constructs an IconWidget in its own native content tree.
        -- Intercept that *single* construction to pass a direct SVG file path,
        -- even when the global user-icons directory was absent on startup.
        local original_icon_init = IconWidget.init
        IconWidget.init = function(widget)
            if widget.icon == "vocab-flashcards-statistics-bars" then
                widget.file = icon_path
            end
            return original_icon_init(widget)
        end
        local icon_px = mode_icon_px
        local built, button = pcall(utilityButton,
            "vocab-flashcards-statistics-bars", statisticsCallback, true, icon_px)
        IconWidget.init = original_icon_init -- never leave a global monkey-patch
        if built and button then
            self.accuracy_button = button
        else
            logger.warn("vocab flashcards: could not create native stats icon:", button)
        end
    else
        logger.warn("vocab flashcards: cannot write stats SVG to:", icon_path)
    end
    if not self.accuracy_button then
        -- Only used on unexpectedly read-only KOReader data directories or
        -- if the native image backend cannot be constructed. Keep Stats usable.
        self.accuracy_button = utilityButton("▂▅▇", statisticsCallback, true)
    end

    -- Native third shortcut: the calendar opens from ANY Flashcards screen,
    -- including Practice. Same touch feedback & stroke weight as adjacent icons.
    local calendar_svg = [[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
<rect x="4.5" y="7.5" width="23" height="21" rx="2" fill="none" stroke="#000000" stroke-width="2.7"/>
<path d="M4.5 14h23M10 4v7M22 4v7M10 21l4 4 8-8" fill="none" stroke="#000000" stroke-width="2.7" stroke-linecap="round" stroke-linejoin="round"/>
</svg>]]
    local calendar_path = GeneratedIcons.path("vocab-flashcards-study-calendar.svg")
    local calendar_file = io.open(calendar_path, "rb")
    local existing_calendar = calendar_file and calendar_file:read("*a") or nil
    if calendar_file then calendar_file:close() end
    local calendar_ready = existing_calendar == calendar_svg
    if not calendar_ready then
        calendar_file = io.open(calendar_path, "wb")
        if calendar_file then
            calendar_ready = calendar_file:write(calendar_svg) ~= nil
            calendar_file:close()
        end
    end
    if calendar_ready then
        local previous_icon_init = IconWidget.init
        IconWidget.init = function(widget)
            if widget.icon == "vocab-flashcards-study-calendar" then
                widget.file = calendar_path
            end
            return previous_icon_init(widget)
        end
        local built, button = pcall(utilityButton, "vocab-flashcards-study-calendar",
            function() self:openStudyCalendar() end, true, mode_icon_px)
        IconWidget.init = previous_icon_init
        if built and button then
            self.calendar_button = button
        else
            logger.warn("vocab flashcards: unable to build calendar icon:", button)
        end
    end
    if not self.calendar_button then
        -- Keep the action discoverable if the data directory is read-only.
        self.calendar_button = utilityButton("Cal",
            function() self:openStudyCalendar() end, true)
    end

    -- Fourth icon: a calendar with the number of later-today reviews and an
    -- arrow. The number is generated from the selected collection (not a
    -- placeholder), capped at 99+ for readability in the tiny button.
    -- Separate count-specific filenames avoid KOReader's SVG image cache
    -- returning a previous count when only the file bytes have changed.
    local advance_count = self:_advanceTodayCount()
    local advance_badge = advance_count > 99 and "99+" or tostring(advance_count)
    local badge_px = advance_count > 99 and "9" or (advance_count > 9 and "11" or "13")
    local advance_svg = string.format([[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
<rect x="3" y="6" width="25" height="23" rx="2.5" fill="none" stroke="#000000" stroke-width="2.5"/>
<path d="M3 12.5h25M9 3.5v6M22 3.5v6" fill="none" stroke="#000000" stroke-width="2.5" stroke-linecap="round"/>
<circle cx="13.5" cy="20.5" r="8.5" fill="#ffffff" stroke="#000000" stroke-width="1.8"/>
<text x="13.5" y="24" text-anchor="middle" font-family="sans-serif" font-size="%s" font-weight="bold" fill="#000000">%s</text>
<path d="M22 22h7m-4-3 4 3-4 3" fill="none" stroke="#000000" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
</svg>]], badge_px, advance_badge)
    local advance_file = GeneratedIcons.path("vocab-flashcards-advance-"
        .. advance_badge:gsub("%+", "plus") .. ".svg")
    local function ensureAdvanceIcon()
        local file = io.open(advance_file, "rb")
        if file then
            local previous = file:read("*a")
            file:close()
            if previous == advance_svg then return true end
        end
        file = io.open(advance_file, "wb")
        if not file then return false end
        local ok = file:write(advance_svg)
        file:close()
        return ok ~= nil
    end
    local advance_icon_ok, advance_icon_ready = pcall(ensureAdvanceIcon)
    if advance_icon_ok and advance_icon_ready then
        local previous_icon_init = IconWidget.init
        IconWidget.init = function(widget)
            if widget.icon == "vocab-flashcards-advance-today" then
                widget.file = advance_file
            end
            return previous_icon_init(widget)
        end
        local built, button = pcall(utilityButton, "vocab-flashcards-advance-today",
            function() self:showAdvanceTodayMenu() end, true, mode_icon_px)
        IconWidget.init = previous_icon_init
        if built and button then
            self.advance_today_button = button
        else
            logger.warn("vocab flashcards: could not build Advance Today icon:", button)
        end
    end
    if not self.advance_today_button then
        -- A readable text fallback on read-only storage or missing SVG support.
        self.advance_today_button = utilityButton("»",
            function() self:showAdvanceTodayMenu() end, true)
    end

    -- Kindle e-ink: a native Button temporarily inverts its frame for touch
    -- feedback (flash_ui).  When this button opens a full-screen calendar on
    -- the next UI tick, its fast unhighlight refresh may be hidden by the
    -- calendar and leave a black/selected rectangle when it closes.
    -- Avoid inversion on THIS icon only; preserve the same native Button,
    -- image, geometry, callback and all other header controls.
    -- In particular, do not change the global flash_ui setting or Button.
    self.calendar_button.no_focus = true
    self.calendar_button.onTapSelectButton = function(button)
        if (button.enabled or button.allow_tap_when_disabled) and button.callback then
            button.callback()
        end
        if button.readonly ~= true then return true end
    end

    -- Keep the other two utility buttons from remaining inverted on e-ink,
    -- using the SAME touch behavior already applied to the calendar icon.
    -- Do not change their SVGs, tap areas, callbacks, enabled state or layout.
    self.mode_toggle_button.no_focus = true
    self.accuracy_button.no_focus = true
    self.mode_toggle_button.onTapSelectButton = self.calendar_button.onTapSelectButton
    self.accuracy_button.onTapSelectButton = self.calendar_button.onTapSelectButton
    self.advance_today_button.no_focus = true
    self.advance_today_button.onTapSelectButton = self.calendar_button.onTapSelectButton
    -- Small independent settings shortcut, matching the existing monochrome
    -- buttons. The selected level is read from preferences, not from a timer.
    local training_symbol = self.intensive_mode == "ultra" and "U"
        or self.intensive_mode == "intensive" and "I" or "R"
    self.intensive_button = utilityButton(training_symbol,
        function() self:showIntensiveMenu() end, true)
    self.intensive_button.no_focus = true
    self.intensive_button.onTapSelectButton = self.calendar_button.onTapSelectButton

    -- The reverse of the first, two-arrow icon cycles the FOUR existing
    -- card frames. This only changes a visual preference: no review answer,
    -- queue, word model, or dictionary setting is touched.
    local reverse_arrows_svg = [[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
<path d="M28 11H5M5 11L11 5M5 11L11 17M4 22H27M27 22L21 16M27 22L21 28" fill="none" stroke="#000000" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>
</svg>]]
    local reverse_arrows_path = GeneratedIcons.path("flipside-cycle-styles-reversed.svg")
    local function ensureReverseArrowsIcon()
        local file = io.open(reverse_arrows_path, "rb")
        if file then
            local previous = file:read("*a")
            file:close()
            if previous == reverse_arrows_svg then return true end
        end
        file = io.open(reverse_arrows_path, "wb")
        if not file then return false end
        local ok = file:write(reverse_arrows_svg)
        file:close()
        return ok ~= nil
    end
    local ready, valid = pcall(ensureReverseArrowsIcon)
    if ready and valid then
        local previous_init = IconWidget.init
        IconWidget.init = function(widget)
            if widget.icon == "flipside-cycle-styles-reversed" then
                widget.file = reverse_arrows_path
            end
            return previous_init(widget)
        end
        local ok, button = pcall(utilityButton,
            "flipside-cycle-styles-reversed",
            function() self:cycleCardStyle() end, true, mode_icon_px)
        IconWidget.init = previous_init
        if ok and button then
            self.style_cycle_button = button
        else
            logger.warn("FlipSide: cannot build frame switch icon:", button)
        end
    end
    if not self.style_cycle_button then
        self.style_cycle_button = utilityButton("⇆",
            function() self:cycleCardStyle() end, true)
    end
    self.style_cycle_button.no_focus = true
    self.style_cycle_button.onTapSelectButton = self.calendar_button.onTapSelectButton

    local pill_separator_h = math.floor(self.mode_toggle_button:getSize().h * 0.60)
    local utility_contents = HorizontalGroup:new{
        self.mode_toggle_button,
        LineWidget:new{
            dimen = Geom:new{ w = separator_w, h = pill_separator_h },
            background = Blitbuffer.COLOR_DARK_GRAY,
        },
        self.accuracy_button,
        LineWidget:new{
            dimen = Geom:new{ w = separator_w, h = pill_separator_h },
            background = Blitbuffer.COLOR_DARK_GRAY,
        },
        self.calendar_button,
        LineWidget:new{
            dimen = Geom:new{ w = separator_w, h = pill_separator_h },
            background = Blitbuffer.COLOR_DARK_GRAY,
        },
        self.advance_today_button,
        LineWidget:new{
            dimen = Geom:new{ w = separator_w, h = pill_separator_h },
            background = Blitbuffer.COLOR_DARK_GRAY,
        },
        self.intensive_button,
        LineWidget:new{
            dimen = Geom:new{ w = separator_w, h = pill_separator_h },
            background = Blitbuffer.COLOR_DARK_GRAY,
        },
        self.style_cycle_button,
    }
    local utility_pill = FrameContainer:new{
        bordersize = outline,
        padding_left = Size.padding.small,
        padding_right = Size.padding.small,
        padding_top = math.max(1, math.floor(vertical_inset * 0.5)),
        padding_bottom = math.max(1, math.floor(vertical_inset * 0.5)),
        margin = 0,
        radius = math.floor(utility_contents:getSize().h / 2) + vertical_inset,
        color = Blitbuffer.COLOR_DARK_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        utility_contents,
    }
    local mode_row = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = math.max(gap, Size.padding.default * 2) },
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = utility_pill:getSize().h },
            utility_pill,
        },
    }
    -- No dedicated immersion icon or extra row. The native header X handles
    -- holding in normal mode; the same (invisible) corner exits immersion.
    local top_h = title_bar:getHeight() + gap + filter_bar:getSize().h
    self.filter_rect = Geom:new{
        x = 0, y = title_bar:getHeight(), w = screen_w,
        h = gap + filter_bar:getSize().h,
    }
    top_h = top_h + mode_row:getSize().h
    if self.immersive then
        top_h = 0
        self.filter_rect = nil
        -- Keep the former X hit area active, even when the titlebar is
        -- hidden. Derive it from the native KOReader close button's actual
        -- measured size, so this works across DPI and screen sizes.
        local native_x = title_bar.right_button
        local native_size = native_x and native_x:getSize()
        local exit_w = native_size and native_size.w
            or math.max(Screen:scaleBySize(48), math.floor(screen_w * 0.15))
        local exit_h = native_size and native_size.h
            or math.max(Screen:scaleBySize(48), math.floor(screen_h * 0.10))
        exit_w = math.min(screen_w, math.max(Screen:scaleBySize(40), exit_w))
        exit_h = math.min(screen_h, math.max(Screen:scaleBySize(40), exit_h))
        self.immersion_exit_rect = Geom:new{
            x = screen_w - exit_w, y = 0, w = exit_w, h = exit_h,
        }
    end
    local center_h = math.max(1, screen_h - top_h - controls:getSize().h)
    if show_review_complete then
        local ok, panel = pcall(self._buildReviewCompletePanel, self, inner_w, center_h)
        if ok and panel then
            table.insert(content, panel)
        else
            logger.warn("vocab flashcards: completion panel unavailable:", panel)
            table.insert(content, TextBoxWidget:new{
                text="Review complete. Use the statistics icon to view your progress.",
                face=getSentenceFace(self.sentence_font, 17),
                width=inner_w, alignment="center",
            })
        end
    end

    -- One-page layout. The THREE framed templates retain their existing
    -- per-card font caps. Default remains free of any arbitrary template cap:
    -- it uses the size selected in Aa until that specific card would exceed
    -- the center region between the upper navigation and review buttons.
    -- Only then cap that card's displayed context sentence to the *largest*
    -- size that physically fits, without changing the user's saved setting.
    -- Neither mode uses scrolling, clipping or changes to the review queue.
    local full_content_h = content:getSize().h
    if self.state == "card" then
        local is_default = self.card_style == "default"
        local budget = is_default
            and math.max(1, center_h - 2 * math.max(gap, Screen:scaleBySize(8)))
            or Flash.framedContentBudget(self.card_style, screen_w, center_h, margin)
        if budget then
            if full_content_h > budget and #gap_indices > 0 then
                for _, idx in ipairs(gap_indices) do
                    content[idx] = VerticalSpan:new{ width = gap }
                end
                -- VerticalGroup caches size AND paint offsets. Recalculate
                -- both after changing any child (fixes stale frame heights).
                content:resetLayout()
                full_content_h = content:getSize().h
            end
            if sentence_index and sentence_spec and sentence_spec.font_size
                    and content[sentence_index] then
                local old_sentence = content[sentence_index]
                local other_h = full_content_h - old_sentence:getSize().h
                -- Measuring the *revealed* sentence also protects the hidden
                -- cloze: both phases keep identical widths, line wraps and
                -- glyph positions. This never draws the secret word early.
                local measure_text = sentence_spec.is_contextual
                    and (sentence_spec.marked or sentence_spec.text)
                    or sentence_spec.text
                local bracket_word = type(measure_text) == "string"
                    and measure_text:match("【(.-)】") or nil
                if bracket_word then
                    bracket_word = bracket_word:gsub("\226\129\160", "")
                end
                local fits_cache = {}
                local function fitsSentence(size)
                    if fits_cache[size] ~= nil then return fits_cache[size] end
                    local face = getSentenceFace(self.sentence_font, size)
                    local measure = TextBoxWidget:new{
                        text = measure_text,
                        face = face,
                        width = sentence_spec.width,
                        alignment = sentence_spec.alignment,
                    }
                    local text_h = measure:getSize().h
                    if type(measure.free) == "function" then measure:free() end
                    local fits = other_h + text_h <= budget
                    if fits and bracket_word and bracket_word ~= "" then
                        local token = TextWidget:new{
                            text = "【" .. bracket_word .. "】", face = face,
                        }
                        -- Avoid splitting the closing bracket onto a new line.
                        fits = token:getSize().w <= sentence_spec.width
                        if type(token.free) == "function" then token:free() end
                    end
                    fits_cache[size] = fits
                    return fits
                end
                local chosen = Flash.findFramedSentenceSize(
                    sentence_spec.font_size, is_default and 6 or 10, fitsSentence)
                if chosen < sentence_spec.font_size then
                    local face = getSentenceFace(self.sentence_font, chosen)
                    local replacement
                    if sentence_spec.is_contextual and sentence_spec.marked then
                        replacement = makeFixedClozeBox(sentence_spec.marked,
                            face, sentence_spec.width,
                            sentence_spec.alignment, self)
                    end
                    if not replacement then
                        local displayed = sentence_spec.text
                        if sentence_spec.is_contextual and sentence_spec.marked then
                            displayed = self.dual_phase == "revealed"
                                and (revealSelectedWord(sentence_spec.marked)
                                    or sentence_spec.marked)
                                or (maskSelectedWord(sentence_spec.marked, face)
                                    or sentence_spec.text)
                        end
                        replacement = TextBoxWidget:new{
                            text = displayed, face = face,
                            width = sentence_spec.width,
                            alignment = sentence_spec.alignment,
                            fgcolor = sentence_spec.fgcolor,
                        }
                    end
                    content[sentence_index] = replacement
                    sentence_spec.font_size = chosen
                    content:resetLayout()
                    full_content_h = content:getSize().h
                    if type(old_sentence.free) == "function" then
                        old_sentence:free()
                    end
                end
            end
        end
    end

    -- The safety cap is local to this render/card/template and NEVER saved.
    -- A short Default card still uses size 40 when 40 is selected in Aa;
    -- only a paragraph too tall for the actual screen is made smaller.
    -- No scroll widget, no repaint mask and no revision to the SRS/database.
    -- The existing fixed-cloze glyph mask still belongs to this exact
    -- textbox, and no opaque rectangle or scroll-cropping surface is added.
    if sentence_index and content[sentence_index]
            and content[sentence_index]._flash_fixed_cloze then
        self.fixed_cloze_box = content[sentence_index]
    end
    self.card_rect = Geom:new{ x = 0, y = top_h, w = screen_w, h = center_h }
    local center = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = center_h },
        content,
    }
    -- Purely visual per-card frame. Neither makeFixedClozeBox nor any
    -- TextBoxWidget is repainted/decorated by these three helpers.
    if self.state == "card" and self.card_style == "circuit" then
        pcall(Flash.Circuit.decorateCenter, center, screen_w, center_h,
            margin, full_content_h, progress_widget)
    elseif self.state == "card" and self.card_style == "classic" then
        pcall(Flash.Classic.decorateCenter, center, screen_w, center_h,
            margin, full_content_h, progress_widget,
            word_widget, sentence_index and content[sentence_index], content, content)
    elseif self.state == "card" and self.card_style == "angular" then
        pcall(Flash.Angular.decorateCenter, center, screen_w, center_h,
            margin, full_content_h, progress_widget)
    end

    -- Reuse the decorator's exact geometry for the saved-meaning popup.
    -- The frame is drawn inside the center container; its location on the
    -- screen also depends on the actual top menu and control heights.
    -- No template geometry is guessed or hard-coded for any device/DPI.
    self._flipside_meaning_frame = nil
    local visible_frame = center._flipside_frame_bounds
    if self.state == "card" and visible_frame then
        self._flipside_meaning_frame = {
            x = visible_frame.x,
            y = top_h + visible_frame.y,
            w = visible_frame.w,
            h = visible_frame.h,
        }
    end

    self._card_word_widget = word_widget
    if word_widget then
        -- The progress text above the word is outside its dictionary tap area.
        local word_offset = 0
        for i = 1, #content do
            if content[i] == word_widget then break end
            word_offset = word_offset + content[i]:getSize().h
        end
        local y0 = top_h + math.floor((center_h - content:getSize().h) / 2)
        -- Do NOT use the full screen width for the dictionary hotspot.
        -- A short centered word has only a short centered hitbox; the
        -- surrounding whitespace is reserved for revealing context.
        local measure = TextWidget:new{
            text = word_text,
            face = getSentenceFace(self.sentence_font, word_size),
            bold = true,
        }
        local hit_w = math.min(inner_w, measure:getSize().w + 2 * gap)
        if type(measure.free) == "function" then measure:free() end
        self.word_rect = Geom:new{
            x = math.floor((screen_w - hit_w) / 2),
            y = y0 + word_offset - gap,
            w = hit_w,
            h = word_widget:getSize().h + 2 * gap,
        }
    else
        self.word_rect = nil
    end

    local root = VerticalGroup:new{ align = "center" }
    if not self.immersive then
        table.insert(root, title_bar)
        table.insert(root, VerticalSpan:new{ width = gap })
        table.insert(root, filter_bar)
        if mode_row then table.insert(root, mode_row) end
    end
    -- Statistics hides ONLY the card center while its modal is open.
    -- Leave the native header, collection controls and review buttons painted.
    -- This is a visual mask; it does not change the card or its review state.
    local paint_card_center = center.paintTo
    center.paintTo = function(widget, bb, x, y)
        if self._flipside_statistics_conceal_center then
            bb:paintRect(x, y, screen_w, center_h, Blitbuffer.COLOR_WHITE)
            return
        end
        return paint_card_center(widget, bb, x, y)
    end
    table.insert(root, center)
    table.insert(root, controls)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        root,
    }
    -- Start the next clock interval in the mode just rendered.
    if self._clock_last and self._clock_last_mode ~= self:_clockMode() then
        self._clock_last = os.time()
        self._clock_last_mode = self:_clockMode()
    end
end

function Flashcards:_refresh()
    if self._closing then return end
    if self._sleep_paused or Device.screen_saver_mode then
        SleepTrace.blocked("refresh", UIManager, Device, self)
        return
    end
    -- No automatic e-ink flash, including style or immersive-mode changes.
    -- The only explicit full refresh is the top-right downward swipe gesture.
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

-- Shortcut beside the CRAM level. Uses the identical list as Aa > Card styles,
-- including Default, and wraps to the first theme after the last one.
function Flashcards:cycleCardStyle()
    if self.busy then return true end
    local current_index = 1
    for i, option in ipairs(Flash.CARD_STYLES) do
        if option.id == self.card_style then
            current_index = i
            break
        end
    end
    local next_index = current_index % #Flash.CARD_STYLES + 1
    self.card_style = Flash.CARD_STYLES[next_index].id
    G_reader_settings:saveSetting(Flash.CARD_STYLE_SETTING, self.card_style)
    G_reader_settings:flush()
    self:_render()
    self:_refresh()
    return true
end

function Flashcards:setImmersion(enabled)
    enabled = not not enabled
    if self.immersive == enabled then return true end
    self.immersive = enabled
    self:_render()
    self:_refresh()
    -- No extra button, toast or other distraction in either state.
    -- Hold the X in normal mode to enter; hold its former corner to exit.
    return true
end

function Flashcards:toggleContext()
    if self.dual_phase == "sentence" then
        -- Always keep the sentence with [word] visible on this card face.
        return true
    end
    if self.dual_phase == "cloze" then
        return self:revealDualAnswer()
    elseif self.dual_phase == "revealed" then
        return self:hideDualAnswer()
    end
    self.show_ctx = not self.show_ctx
    if not self.show_ctx then self.show_more_ctx = false end
    self:_render()
    self:_refresh()
    return true
end

function Flashcards:toggleSurrounding()
    if self.state ~= "card" or self.busy then return true end
    -- All modes can expand the captured context. In contextual cloze mode
    -- the selected word stays masked by _render(), avoiding answer leaks.
    self.show_ctx = true
    self.show_more_ctx = not self.show_more_ctx
    -- If the stored context contains nothing beyond the studied sentence,
    -- still show that sentence. The gesture never invents missing text.
    self:_render()
    self:_refresh()
    return true
end

-- Move to another pending card without answering it or changing its due date.
-- In particular, do not mark the skipped word as done.
function Flashcards:_seekPending(direction)
    local n = #self.cards
    if n == 0 then return false end
    for offset = 1, n do
        local i = ((self.idx - 1 + direction * offset) % n) + 1
        if not self.cards[i].done then
            self.idx = i
            return true
        end
    end
    return false
end

-- Swipe navigation is separate from review/Undo history. These are *card
-- objects*, not indices: removing another card must not redirect an old
-- swipe to the wrong word. Keep a small recent trail for long sessions.
function Flashcards:_rememberBrowse(card)
    if not card then return end
    local trail = self._browse_back or {}
    self._browse_back = trail
    trail[#trail + 1] = card
    if #trail > 512 then table.remove(trail, 1) end
end

-- Inspect the recorded history without clearing .done or invoking Undo.
-- This is deliberately a separate navigation cursor, not a scheduler change.
function Flashcards:inspectPrevious()
    if self.busy or #self.history == 0 then return true end
    -- One-step backward inspection only: the immediately preceding answered
    -- card. Never walk farther back through saved reviews.
    if self._inspection_cursor then return true end
    self:_clockPulse(false)
    self:_clockTouch()
    if not self._inspection_resume then
        self._inspection_resume = {
            idx = self.idx, state = self.state, dual_card = self.dual_card,
            dual_phase = self.dual_phase, show_ctx = self.show_ctx,
            show_more_ctx = self.show_more_ctx,
        }
        self._inspection_cursor = #self.history + 1
    end
    local i = self._inspection_cursor - 1
    while i >= 1 and not self.cards[self.history[i].idx] do i = i - 1 end
    if i < 1 then return true end
    self._inspection_cursor = i
    self.idx = self.history[i].idx
    self.state = "card"
    self.show_ctx, self.show_more_ctx = false, false
    self:_resetDualCard()
    self:_render()
    self:_refresh()
    return true
end

function Flashcards:inspectNext()
    if self.busy or not self._inspection_cursor then return true end
    self:_clockPulse(false)
    self:_clockTouch()
    local i = self._inspection_cursor + 1
    while i <= #self.history and not self.cards[self.history[i].idx] do i = i + 1 end
    if i <= #self.history then
        self._inspection_cursor = i
        self.idx = self.history[i].idx
        self.state = "card"
        self.show_ctx, self.show_more_ctx = false, false
        self:_resetDualCard()
    else
        local resume = self._inspection_resume
        self._inspection_cursor, self._inspection_resume = nil, nil
        if resume then
            self.idx, self.state = resume.idx, resume.state
            self.dual_card, self.dual_phase = resume.dual_card, resume.dual_phase
            self.show_ctx, self.show_more_ctx = resume.show_ctx, resume.show_more_ctx
            -- A card might have become due while an old answer was open.
            if self.state == "done" and self:_seekPending(1) then
                self.state = "card"
                self:_resetDualCard()
                self.show_ctx, self.show_more_ctx = false, false
            end
        end
    end
    self:_render()
    self:_refresh()
    return true
end

function Flashcards:stepCard(direction)
    if self.busy then return true end
    -- While inspecting a saved answer, only a forward swipe returns to the
    -- pending card. Never alter the original one-answer inspection limit.
    if self._inspection_cursor then
        return direction > 0 and self:inspectNext() or true
    end
    -- A practice attempt must be rated on its own card. Swiping to a native
    -- pending card while retry_round=true could misclassify an official review
    -- as practice, silently losing a scheduled SRS answer.
    if self.retry_round then return true end
    if self.state ~= "card" then return true end
    if direction < 0 then
        -- The old implementation called inspectPrevious() unconditionally.
        -- With zero saved answers it did nothing, even after skipping cards.
        -- Walk the independent browse trail first, without a review write.
        local trail = self._browse_back or {}
        while #trail > 0 do
            local card = trail[#trail]
            local index
            for i, candidate in ipairs(self.cards) do
                if candidate == card then index = i; break end
            end
            if not index or index == self.idx then
                table.remove(trail)
            elseif card.done then
                -- The established rule allows inspection of only the most
                -- recently answered card, with the stock Undo unchanged.
                local latest = self.history[#self.history]
                if latest and self.cards[latest.idx] == card then
                    return self:inspectPrevious()
                end
                table.remove(trail)
            else
                table.remove(trail)
                self:_clockPulse(false)
                self:_clockTouch()
                self.idx = index
                self.show_ctx, self.show_more_ctx = false, false
                self:_resetDualCard()
                self:_render()
                self:_refresh()
                return true
            end
        end
        -- No visited card left: allow a reverse swipe through pending cards,
        -- even if the current session has never recorded any answer.
        self:_clockPulse(false)
        self:_clockTouch()
        if self:_seekPending(-1) then
            self.show_ctx, self.show_more_ctx = false, false
            self:_resetDualCard()
            self:_render()
            self:_refresh()
        end
        return true
    end
    -- Right-to-left: continue forward without assigning Got it/Forgot.
    self:_clockPulse(false)
    self:_clockTouch()
    local old_card = self.cards[self.idx]
    if self:_seekPending(1) then
        if self.cards[self.idx] ~= old_card then
            self:_rememberBrowse(old_card)
        end
        self.show_ctx = false
        self.show_more_ctx = false
        self:_resetDualCard()
        self:_render()
        self:_refresh()
    end
    return true
end

-- A time-based due watcher for cards ALREADY present in the catalog.
-- No polling: use a single KOReader timer set for the next real SRS due date
-- or the midnight deadline for Advance Today. Unlike reloadDeck(), this
-- inserts cards without replacing the current card, Undo history, or CRAM.
function Flashcards:_stopDueWatch()
    if self._due_watch_action then
        UIManager:unschedule(self._due_watch_action)
        self._due_watch_action = nil
    end
end

-- Appending is deliberately narrow: a reviewed card is never reintroduced
-- into its own session, which would make the existing Undo index ambiguous.
-- Newly matured unreviewed cards remain eligible and need no SRS writes.
function Flashcards:_appendNewlyDue()
    if self.practice or self._closing or self.retry_round
            or self.busy or self._inspection_cursor then return 0 end
    local now = os.time()
    local t0, y0 = dayStart(0), dayStart(1)
    local seen = {}
    for _, card in ipairs(self.cards or {}) do seen[card] = true end
    local first_new, added = nil, 0
    for _, card in ipairs(self.all_cards or {}) do
        if not card.done and not card._training_only and not card._retry_pending
                and not seen[card]
                and cardMatches(card, self.filter, t0, y0, true)
                and self:_isAvailableInCollection(card, now) then
            self.cards[#self.cards + 1] = card
            seen[card] = true
            first_new = first_new or #self.cards
            added = added + 1
        end
    end
    if added > 0 then
        logger.info("FlipSide due watcher: appended", added, "new due cards")
        -- Never disrupt a live card or a live answer. The header is updated
        -- on the next ordinary _render(); only an empty/finished screen
        -- needs to become a review card immediately.
        if self.state == "empty" or self.state == "done" then
            self.idx = first_new
            self.state = "card"
            self.show_ctx, self.show_more_ctx = false, false
            self:_resetDualCard()
            self:_render()
            self:_refresh()
        end
    end
    return added
end

function Flashcards:_armDueWatch(delay_override)
    self:_stopDueWatch()
    if self._closing or self.practice or self._sleep_paused then return end
    if Device.screen_saver_mode then
        self:_pauseForSleep()
        return
    end
    local now = os.time()
    local today0, yesterday0 = dayStart(0), dayStart(1)
    local in_queue = {}
    for _, c in ipairs(self.cards or {}) do in_queue[c] = true end
    local next_due = nil
    for _, c in ipairs(self.all_cards or {}) do
        if not c.done and not c._training_only and not c._retry_pending
                and not in_queue[c] and type(c.due) == "number"
                and cardMatches(c, self.filter, today0, yesterday0, true) then
            if self:_isAvailableInCollection(c, now) then
                next_due = now
                break
            elseif next_due == nil or c.due < next_due then
                next_due = c.due
            end
        end
    end
    -- Expire Advance Today at midnight even when no card is due. Keep its
    -- original toggle persistence and day-specific behavior unchanged.
    if self.advance_today and self.advance_day == localDayKey() then
        local midnight = dayStart(-1) + 1
        if next_due == nil or midnight < next_due then
            next_due = midnight
        end
    elseif self.advance_today then
        next_due = now
    end
    if next_due == nil and delay_override == nil then return end
    local seconds = math.max(0.25, (next_due or now) - now)
    -- Retry backoff during dialogs/CRAM: never spin on an already-due card.
    if delay_override ~= nil then seconds = math.max(0.25, delay_override) end
    local action
    action = function()
        if self._due_watch_action ~= action then return end
        self._due_watch_action = nil
        if self._closing or not UIManager:isWidgetShown(self) then return end
        if self._sleep_paused or Device.screen_saver_mode then
            self:_pauseForSleep()
            return
        end
        if self.busy or self.retry_round or self._inspection_cursor
                or UIManager:getTopmostVisibleWidget() ~= self then
            self:_armDueWatch(15)
            return
        end
        if self.advance_today and self.advance_day ~= localDayKey() then
            self.advance_today = false
            self.advance_day = localDayKey()
            saveAdvanceToday(false)
            -- Do not rebuild the active/answered cards or erase history.
            -- Newly due cards are appended by the normal watcher below.
            if self.state ~= "card" then
                self:_render()
                self:_refresh()
            end
        end
        self:_appendNewlyDue()
        self:_armDueWatch()
    end
    self._due_watch_action = action
    UIManager:scheduleIn(seconds, action)
end

-- The native 5/30-minute SRS schedule is not consulted by this temporary
-- practice queue. Only the first, normal review writes the native DB.
-- A checkpoint contains the complete queue, partial streaks, finished words,
-- and any unanswered active card (placed back at the head on restoration).
-- Storing it in a separate atomic file avoids rewriting the SRS database.
function Flashcards:_persistIntensiveProgress()
    if not self.training or not self._cram_store or not self._cram_slot then
        return false
    end
    local ok, err = pcall(self._cram_store.put, self._cram_store,
        self._cram_slot, self.training:snapshot())
    if not ok then
        logger.warn("FlipSide cram: could not save the queue:", err)
        Diag.report("CRITICAL", "CRAM_CHECKPOINT_FAILED",
            {mode=self.intensive_mode, timing=self.intensive_timing, retry=self.retry_round,
             queue=self.training and self.training:available() or 0}, err)
        if not self._cram_save_failed then
            self._cram_save_failed = true
            if self._sleep_paused or Device.screen_saver_mode then
                -- Never open an error popup on top of the Kindle cover.
                -- The diagnostic is already written; show the warning only
                -- when this flashcard really returns to the foreground.
                self._cram_save_warning_pending = true
                SleepTrace.blocked("defer_cram_error_popup", UIManager, Device, self)
            else
                UIManager:show(newFlashInfo(self, {
                    text = "CRAM PROGRESS NOT SAVED. Check free storage. "
                        .. "Keep KOReader open and back up your settings.",
                    timeout = 8,
                }))
            end
        end
        return false
    end
    self._cram_save_failed = false
    Diag.event("cram", "checkpoint_saved",
        {mode=self.intensive_mode, queue=self.training:available()})
    return true
end

function Flashcards:_pauseIntensiveAttempt()
    if not self.retry_round then return end
    if self.training then self.training:pause() end
    local current = self.cards and self.cards[self.idx]
    if current then
        current._retry_pending = nil
        current.done = true
    end
    self._training_current = nil
    self.retry_round = false
    self._normal_resume_card = nil
    self:_resetDualCard()
    self:_persistIntensiveProgress()
end

function Flashcards:_initializeIntensive()
    -- Do NOT discard the previous mode or selected-book queue on a reload.
    self:_persistIntensiveProgress()
    self.training = nil
    self._cram_slot = nil
    self._training_current = nil
    self._training_extra_cards = {}
    self._ultra_waiting = {}
    self._normal_resume_card = nil
    self._official_since_training = 0
    -- A Practice answer never updates SRS dates, but Practice can still
    -- review words from the independent, persistent CRAM queue.
    if self.intensive_mode == "off" or not self._cram_store then
        return
    end
    if not (self.all_cards and self.all_cards.full_catalog) then
        -- A fallback/partial database view must never prune persisted cards.
        -- Disable cram for this view instead of overwriting the checkpoint.
        logger.warn("FlipSide cram: full catalog unavailable; saved queues protected")
        Diag.report("WARNING", "CRAM_CATALOG_UNAVAILABLE",
            {mode=self.intensive_mode, has_catalog=false}, "Full catalog flag is missing")
        self._cram_unavailable = true
        return
    end
    self._cram_unavailable = false
    -- No saved words: do not normalize/prune or save stale CRAM queues.
    -- The user will be offered a backup-first reset separately.
    if #self.all_cards == 0 then return end
    local cards_by_word = {}
    for _, card in ipairs(self.all_cards or {}) do
        cards_by_word[card.word] = card
    end
    self._cram_slot = CramStore.key(self.intensive_mode, self.filter)
    self.training = Intensive.restore(self.intensive_mode,
        self._cram_store:get(self._cram_slot), cards_by_word)
    if self.intensive_mode == "ultra" then
        local in_view = {}
        for _, card in ipairs(self.cards or {}) do
        if type(card.word) == "string" then in_view[card.word] = true end
    end
        local today0, yesterday0 = dayStart(0), dayStart(1)
        for _, word in ipairs(recentRecurringErrors()) do
            local card = cards_by_word[word]
            if card and cramCardMatches(card, self.filter, today0, yesterday0, true) then
                if in_view[word] and not card.done then
                    -- Wait for first real review if the word is due now.
                    self._ultra_waiting[word] = true
                else
                    self.training:add(card)
                end
            end
        end
    end
    -- Checkpoint initial Ultra candidates and restored progress immediately.
    self:_persistIntensiveProgress()
end

-- Queue missed words in BOTH modes immediately, even when CRAM is OFF.
-- Native review misses keep their normal KOReader SRS schedule; a missed
-- Practice card only changes the independent CRAM checkpoint, never SRS,
-- Learning Analysis or official accuracy. Undo can restore either snapshot.
function Flashcards:_cramApplicableFilters(card)
    local filters = {}
    local today0, yesterday0 = dayStart(0), dayStart(1)
    local function include(filter)
        if cramCardMatches(card, filter, today0, yesterday0, true) then
            filters[#filters+1] = filter
        end
    end
    include({kind="all"})
    include({kind="today"})
    include({kind="yesterday"})
    include({kind="never_reviewed"})
    if type(card.book) == "string" and card.book ~= "" then
        include({kind="book", book=card.book})
    end
    -- Preserve selected filters even when their membership is unusual
    -- (for example an old collection renamed after the view was built).
    if self.filter then
        local found = false
        local requested = CramStore.key("intensive", self.filter)
        for _, filter in ipairs(filters) do
            if CramStore.key("intensive", filter) == requested then found=true; break end
        end
        if not found and cramCardMatches(card, self.filter, today0, yesterday0, true) then
            filters[#filters+1] = self.filter
        end
    end
    return filters
end

function Flashcards:_addIntensiveAfterOfficial(card, got)
    if got then
        -- An old, recurring Ultra card waiting for its first official answer
        -- may be trained after a correct answer. It is NOT an Intensive error.
        if self.training and self._ultra_waiting[card.word] then
            local added = self.training:add(card)
            self._ultra_waiting[card.word] = nil
            self:_persistIntensiveProgress()
            return added, nil
        end
        return false, nil
    end
    if not self._cram_store or not self.all_cards
            or not self.all_cards.full_catalog then
        logger.warn("FlipSide cram: cannot persist official error without a full catalog")
        Diag.report("ERROR", "CRAM_MISS_NOT_SAVED",
            {mode=self.intensive_mode, has_catalog=false, practice=self.practice},
            "Missing CRAM storage or complete word catalog")
        return false, nil
    end
    local live_snapshot = self.training and self.training:snapshot() or nil
    -- The store changes ONLY a separate cram_progress.lua checkpoint.
    -- Its name predates Practice support; it never writes a native review.
    local ok, before = pcall(self._cram_store.recordOfficialMiss,
        self._cram_store, card, self:_cramApplicableFilters(card),
        self._cram_slot, live_snapshot)
    if not ok then
        logger.warn("FlipSide cram: missed word NOT saved for both modes:", before)
        Diag.report("CRITICAL", "CRAM_MISS_NOT_SAVED",
            {mode=self.intensive_mode, practice=self.practice,
             native_saved=not self.practice}, before)
        self._cram_save_failed = true
        UIManager:show(newFlashInfo(self, {
            text = (self.practice and "Practice answer saved, but "
                or "Official review saved, but ")
                .. "CRAM could not save the missed word. Check storage and KOReader logs.",
            timeout = 8,
        }))
        return false, nil
    end
    self._cram_save_failed = false
    Diag.event("cram", "miss_saved_both_modes",
        {mode=self.intensive_mode, practice=self.practice})
    if self.training then
        local added = self.training:add(card, true)
        self._ultra_waiting[card.word] = nil
        return added, before
    end
    return false, before
end

function Flashcards:_normalPendingIndex()
    for i, card in ipairs(self.cards or {}) do
        if not card.done and not card._training_only and not card._retry_pending then
            return i
        end
    end
    return nil
end

-- Pull the oldest pending practice card. A failed card has been appended to
-- the tail by Intensive:rate and will not jump ahead of other errors.
function Flashcards:_startMissedRound()
    if not self.training or self.retry_round then return false end
    local entry = self.training:take()
    if not entry then return false end
    local card, index = entry.card, nil
    for i, candidate in ipairs(self.cards) do
        if candidate == card then index = i; break end
    end
    if not index then
        self.cards[#self.cards + 1] = card
        index = #self.cards
        self._training_extra_cards[card.word] = card
        card._training_only = true
    end
    self._training_current = entry
    self:_persistIntensiveProgress()
    card._retry_pending = true
    card.done = nil
    self.retry_round = true
    self.retry_total = self.training.added
    self.idx = index
    self.state = "card"
    self.show_ctx, self.show_more_ctx = false, false
    self:_resetDualCard()
    return true
end

-- Cancel only the *temporary* training state, e.g. when Undo needs to restore
-- a native answer. Never touch the original SQLite review dates or history.
function Flashcards:_endMissedRound()
    for _, card in ipairs(self.cards or {}) do
        if card._retry_pending then card._retry_pending = nil; card.done = true end
    end
    if self.training then self.training:pause() end
    self.retry_round = false
    self._training_current = nil
    self._normal_resume_card = nil
    self:_resetDualCard()
    self:_persistIntensiveProgress()
end

function Flashcards:_finishTrainingAttempt(got)
    local entry = self._training_current
    if not entry or not self.training then return false end
    local card = entry.card
    card.done = true
    card._retry_pending = nil
    self.training:rate(got)
    self:_persistIntensiveProgress()
    self.retry_seen = self.retry_seen + 1
    if got then self.retry_got = self.retry_got + 1
    else self.retry_forgot = self.retry_forgot + 1 end
    local saved, err = pcall(function()
        saveIntensiveAttempt(self.intensive_mode, got)
        G_reader_settings:flush()
    end)
    if not saved then
        logger.warn("FlipSide cram: cannot save training counters:", err)
        Diag.report("WARNING", "CRAM_TRAINING_COUNTER_FAILED",
            {mode=self.intensive_mode, answer=got and "correct" or "missed"}, err)
    end
    self._training_current = nil
    self.retry_round = false
    self.show_ctx, self.show_more_ctx = false, false
    self:_resetDualCard()

    local normal_index = self:_normalPendingIndex()
    if normal_index and self.intensive_timing == "during" then
        -- One practice presentation at a time, then back to official cards.
        -- Preserve their order even when an Ultra-only card was appended.
        local resume = self._normal_resume_card
        if resume and not resume.done then
            for i, candidate in ipairs(self.cards) do
                if candidate == resume then normal_index = i; break end
            end
        end
        self.idx = normal_index
        self._normal_resume_card = nil
        self._official_since_training = 0
        self.state = "card"
        return true
    end
    if self:_startMissedRound() then return true end
    self.state = normal_index and "card" or "done"
    if normal_index then self.idx = normal_index end
    if self.state == "done" then self:_flush() end
    return true
end

-- The next review times come from each answer committed by the stock plugin,
-- not from guesses based on the word or elapsed session length.
function Flashcards:_scheduleSummary()
    local next_all, next_forgot, missed_count = nil, nil, 0
    -- A word may have become due and been reviewed again *in this session*.
    -- Only its latest committed answer is relevant to the next-due summary;
    -- older due dates must not keep showing as "due now" after a new review.
    local most_recent = {}
    for _, record in ipairs(self.history or {}) do
        local card = self.cards[record.idx]
        local due = card and card._after and tonumber(card._after.due_time)
        if due then most_recent[card.word] = { due = due, got = record.got } end
    end
    for _, latest in pairs(most_recent) do
        local due = latest.due
        if not next_all or due < next_all then next_all = due end
        if not latest.got then
            missed_count = missed_count + 1
            if not next_forgot or due < next_forgot then next_forgot = due end
        end
    end
    if not next_all then return nil end
    local now = os.time()
    local function timeLabel(when)
        local fmt = os.date("%Y-%m-%d", when) == os.date("%Y-%m-%d", now)
            and "%H:%M" or "%d/%m %H:%M"
        local left = when - now
        local when_text = os.date(fmt, when)
        if left <= 0 then return when_text .. " (" .. _("due now") .. ")" end
        return when_text .. " (" .. T(_("in %1 min"), math.ceil(left / 60)) .. ")"
    end
    local line = T(_("Next scheduled review: %1"), timeLabel(next_all))
    if next_forgot then
        line = line .. "\n" .. T(_("%1 missed card(s): next due %2"),
            missed_count, timeLabel(next_forgot))
    end
    return line
end

function Flashcards:answer(got)
    Diag.event("answer", "rating_requested", {mode=self.intensive_mode,
        practice=self.practice, retry=self.retry_round,
        answer=got and "correct" or "missed"})
    if self.busy or self.state ~= "card" or self._inspection_cursor then
        return true
    end
    self:_clockPulse(false)
    self:_clockTouch()
    self.busy = true
    local card = self.cards[self.idx]
    if not card or card.done then self.busy = false; return true end
    local answer_mode = self.dual_phase == "revealed" and "contextual"
        or self.dual_phase == "sentence" and "sentence" or "meaning"
    if self.retry_round then
        -- If the last checkpoint failed, refuse further cram ratings until
        -- the already-achieved progress can be written successfully.
        if self._cram_save_failed and not self:_persistIntensiveProgress() then
            self.busy = false
            return true
        end
        -- Practice-only attempt: never call answer_func, Learning Audit,
        -- Adaptive Retrieval, or any native due-time mutation.
        self:_finishTrainingAttempt(got)
        self:_render()
        self:_refresh()
        self.busy = false
        -- Restart the official-review timer only if we returned to a native
        -- pending card. No practice seconds are added to SRS review time.
        self:_clockPulse(false)
        return true
    end
    -- In practice mode, answers are local to this session. They must never
    -- modify due_time, even when this word is already due for real review.
    local ok, found, err = true, true, nil
    if not self.practice then
        -- Use the presentation that was ACTUALLY answered, not another card's
        -- choice or the global default. The native SRS behavior is unchanged.
        local audit = package.loaded["flipside_learning_audit_bridge"]
        -- Record the presentation actually answered. Sentence Card gets its
        -- own audit label; original/Off reviews remain unidentified. Do not
        -- reclassify historical events or change the native SRS transaction.
        local audited_mode = self:_strategyForCard(card) == "off"
            and "unknown" or answer_mode
        if type(audit) == "table" and type(audit.beginReviewMode) == "function" then
            pcall(audit.beginReviewMode, card.word, audited_mode)
        end
        ok, found, err = pcall(self.answer_func, card, got)
        if ok and found then
            local problem
            if type(audit) ~= "table"
                or type(audit.confirmCommittedReview) ~= "function" then
                problem = "Learning Audit patch not loaded. Install both patches."
            elseif not card._answered_at then
                problem = "Could not verify the saved review time."
            else
                local called, recorded, detail = pcall(audit.confirmCommittedReview,
                    card.word, got == true, card._answered_at, audited_mode)
                if not called then
                    problem = "Learning Audit error: " .. tostring(recorded)
                elseif recorded ~= true then
                    problem = tostring(detail or "Review mode not saved")
                end
            end
            if problem then
                logger.warn("vocab flashcards: Learning Audit:", card.word, problem)
                Diag.report("ERROR", "LEARNING_AUDIT_ERROR",
                    {stage="confirm_review", native_saved=true}, problem)
                -- The answer itself remains committed; alert the reader rather
                -- than making the stats silently show zero again.
                UIManager:show(newFlashInfo(self, {
                    text = "Card reviewed, but statistics were not verified.\n" .. problem,
                    timeout = 7,
                }))
            end
        end
        if type(audit) == "table" and type(audit.endReviewMode) == "function" then
            pcall(audit.endReviewMode, card.word)
        end
    end
    if not ok or not found then
        self.busy = false
        logger.warn("vocab flashcards: could not record answer:", ok and err or found)
        Diag.report("ERROR", "SRS_ANSWER_FAILED",
            {practice=self.practice, answer=got and "correct" or "missed"}, ok and err or found)
        UIManager:show(newFlashInfo(self, {
            text = _("Could not record this answer. The word was not changed."),
            timeout = 4,
        }))
        return true
    end
    -- Keep both existing retrieval-mode histories untouched by this
    -- third display style; the native review and global totals still update.
    if not self.practice and self:_strategyForCard(card) ~= "off"
            and answer_mode ~= "sentence" then
        local recorded, stats_error = pcall(updateDualEntry,
            card, got, answer_mode)
        if recorded and stats_error == true then
            card._dual_had_update = true
            card._dual_answer_mode = answer_mode
            if answer_mode == "contextual" then
                self.dual_context_total = self.dual_context_total + 1
                if got then self.dual_context_correct = self.dual_context_correct + 1 end
            else
                self.dual_meaning_total = self.dual_meaning_total + 1
                if got then self.dual_meaning_correct = self.dual_meaning_correct + 1 end
            end
        else
            logger.warn("vocab flashcards: retrieval history update failed:", stats_error)
            Diag.report("WARNING", "LEARNING_AUDIT_ERROR",
                {stage="retrieval_history", native_saved=true}, stats_error)
            UIManager:show(newFlashInfo(self, {
                text = "Review saved by KOReader, but Adaptive Retrieval history could not be saved. Check available storage and KOReader logs.",
                timeout = 7,
            }))
        end
    end
    card.done = true
    local cram_before = self.training and self.training:wordState(card.word)
    local cram_slot = self._cram_slot
    local cram_added, cram_before_all = self:_addIntensiveAfterOfficial(card, got)
    self._official_since_training = self._official_since_training + 1
    table.insert(self.history, { idx = self.idx, got = got,
        cram_added = cram_added, cram_slot = cram_slot,
        cram_before = cram_before, cram_before_all = cram_before_all })
    -- Let the next card swipe back to this answered card. This is display-only
    -- history; the SRS/Undo transaction above is completely unchanged.
    self:_rememberBrowse(card)
    if not self.practice then self.touched = true end
    if got then
        self.got = self.got + 1
    else
        self.forgot = self.forgot + 1
    end
    -- Skipped cards remain pending: only finish when every card was answered.
    self.show_ctx = false
    self.show_more_ctx = false
    self:_resetDualCard()
    local normal_pending = self:_seekPending(1)
    if normal_pending then self._normal_resume_card = self.cards[self.idx] end
    if self.training and self.intensive_timing == "during"
            and (not normal_pending or self._official_since_training >= 2)
            and self:_startMissedRound() then
        -- One queue-based training card interleaved after two native answers.
    elseif not normal_pending then
        -- "After reviews" starts only once the first native pass is finished.
        if not self:_startMissedRound() then
            self.state = "done"
            if not self.practice then self:_flush() end
        end
    end
    self:_render()
    self:_refresh()
    self.busy = false
    -- Start a new interval for the next genuine review immediately; the
    -- preceding rating may have changed the model or ended the due queue.
    self:_clockPulse(false)
    -- A native answer may have moved the next maturity earlier. Rearm the
    -- one-shot watcher without touching the committed SRS schedule.
    self:_armDueWatch()
    return true
end

-- Require confirmation: Undo changes the original review record, not merely
-- the screen. This also protects the last answer on the finished screen.
function Flashcards:confirmUndo()
    if self.busy or #self.history == 0
            or (self._inspection_cursor
                and self._inspection_cursor ~= #self.history) then
        return true
    end
    if self._undo_dialog and UIManager:isWidgetShown(self._undo_dialog) then
        return true
    end
    local last = self.history[#self.history]
    local card = last and self.cards[last.idx]
    if not card then return true end
    local inspected = self._inspection_cursor
    -- A recent historic card must be the same saved answer we are undoing.
    if inspected and self.idx ~= last.idx then return true end
    local dialog = ConfirmBox:new{
        text = T(self.practice and 'Undo the last practice answer of "%1"?'
                or 'Undo the last review of "%1"?', card.word)
            .. "\n\n" .. (self.practice
                and "This also removes that practice error from CRAM. "
                    .. "Normal review dates stay unchanged."
                or _("This restores the previous review date and statistics.")),
        ok_text = self.practice and "Undo practice" or _("Undo review"),
        ok_callback = function()
            self._undo_dialog = nil
            if UIManager:isWidgetShown(self) and #self.history > 0
                and self.history[#self.history] == last
                and self._inspection_cursor == inspected
                and (not inspected or self.idx == last.idx) then
                -- Leave read-only inspection only on confirmed reversal.
                -- The original undo() body is preserved byte-for-byte.
                local resume = self._inspection_resume
                self._inspection_cursor, self._inspection_resume = nil, nil
                self:undo()
                -- undo() deliberately leaves the old card marked done if the
                -- native DB update fails. Restore the history overlay in that
                -- case; never expose rating buttons on a saved card.
                if inspected and card.done then
                    self._inspection_cursor = inspected
                    self._inspection_resume = resume
                    self:_render()
                    self:_refresh()
                end
            end
        end,
        cancel_callback = function() self._undo_dialog = nil end,
    }
    self._undo_dialog = dialog
    UIManager:show(dialog)
    return true
end

-- Revert the most recent committed review (confirmed above).
function Flashcards:undo()
    Diag.event("undo", "requested", {practice=self.practice, mode=self.intensive_mode})
    if self.busy or #self.history == 0 then
        return true
    end
    self.busy = true
    local last = self.history[#self.history]
    local card = self.cards[last.idx]
    local ok, done, err = true, true, nil
    if not self.practice then
        ok, done, err = pcall(self.undo_func, card)
    end
    if not ok or not done then
        self.busy = false
        logger.warn("vocab flashcards: could not undo:", ok and err or done)
        Diag.report("ERROR", "UNDO_SRS_FAILED",
            {native_saved=false, practice=self.practice}, ok and err or done)
        UIManager:show(newFlashInfo(self, {
            text = _("Could not undo this answer."),
            timeout = 4,
        }))
        return true
    end
    if self.retry_round then self:_endMissedRound() end
    -- Undo the error from BOTH cram modes and every matching filter.
    -- Preserve the independent streaks of every other word.
    if last.cram_before_all and self._cram_store then
        local live = self.training and self.training:snapshot() or nil
        local ok_cram, err_cram = pcall(self._cram_store.undoOfficialMiss,
            self._cram_store, card.word, last.cram_before_all,
            self._cram_slot, live)
        if ok_cram and err_cram == true then
            if self.training and self._cram_slot then
                local previous = last.cram_before_all[self._cram_slot]
                if previous then
                    self.training:restoreWord(card.word,
                        previous.kind == "absent" and nil or previous, card)
                end
            end
        else
            logger.warn("FlipSide cram: cross-mode Undo checkpoint failed:", err_cram)
            Diag.report("CRITICAL", "CRAM_UNDO_FAILED",
                {mode=self.intensive_mode, stage="cross_mode"}, err_cram)
            self._cram_save_failed = true
            UIManager:show(newFlashInfo(self, {
                text = "Review Undo saved, but CRAM checkpoint could not "
                    .. "be updated. Keep a backup of your settings.",
                timeout = 8,
            }))
        end
    elseif last.cram_slot then
        -- Backward compatibility with in-memory records created before this
        -- version of the plugin was installed.
        if self.training and self._cram_slot == last.cram_slot then
            self.training:restoreWord(card.word, last.cram_before, card)
            self:_persistIntensiveProgress()
        elseif self._cram_store then
            local ok_cram, err_cram = pcall(self._cram_store.restoreWord,
                self._cram_store, last.cram_slot, card.word, last.cram_before)
            if not ok_cram or err_cram == false then
                logger.warn("FlipSide cram: legacy Undo checkpoint failed:", err_cram)
                Diag.report("ERROR", "CRAM_UNDO_FAILED",
                    {mode=self.intensive_mode, stage="legacy"}, err_cram)
            end
        end
    end
    if card._dual_had_update then
        local restored, err = pcall(restoreDualEntry, card)
        if not restored or err == false then
            logger.warn("vocab flashcards: retrieval history Undo failed:", err)
            Diag.report("ERROR", "UNDO_DUAL_HISTORY_FAILED",
                {native_saved=true}, err)
            UIManager:show(newFlashInfo(self, {
                text = "KOReader review was undone, but Adaptive Retrieval history could not be restored.",
                timeout = 7,
            }))
        else
            if card._dual_answer_mode == "contextual" then
                self.dual_context_total = math.max(0, self.dual_context_total - 1)
                if last.got then
                    self.dual_context_correct = math.max(0, self.dual_context_correct - 1)
                end
            else
                self.dual_meaning_total = math.max(0, self.dual_meaning_total - 1)
                if last.got then
                    self.dual_meaning_correct = math.max(0, self.dual_meaning_correct - 1)
                end
            end
        end
        card._dual_answer_mode = nil
    end
    card.done = nil
    table.remove(self.history)
    if last.got then
        self.got = self.got - 1
    else
        self.forgot = self.forgot - 1
    end
    self.idx = last.idx
    self.state = "card"
    -- Native Undo never rebuilds the whole cram queue or zeros other words.
    self:_resetDualCard()
    self.show_ctx = false
    self.show_more_ctx = false
    if not self.practice then
        self.touched = true
        self:_flush()
    end
    self:_render()
    self:_refresh()
    self.busy = false
    self:_armDueWatch()
    return true
end

-- The confirmation targets the *current* card only. When the user accepts,
-- the underlying Vocabulary Builder entry is deleted as well: flashcards are
-- a view over that database, not a separate collection.
function Flashcards:confirmDeleteCard()
    if self.busy or self._inspection_cursor or self.state ~= "card" then return true end
    if self._delete_dialog and UIManager:isWidgetShown(self._delete_dialog) then
        return true
    end
    local target = self.cards and self.cards[self.idx]
    if not target then return true end
    local dialog = ConfirmBox:new{
        text = T(_('Delete "%1" from Vocabulary Builder?'), target.word)
            .. "\n\n" .. _("This permanently removes the word and its flashcard from every collection."),
        ok_text = _("Delete"),
        ok_callback = function()
            self._delete_dialog = nil
            if UIManager:isWidgetShown(self) then
                self:deleteCurrentCard(target)
            end
        end,
        cancel_callback = function() self._delete_dialog = nil end,
    }
    self._delete_dialog = dialog
    UIManager:show(dialog)
    return true
end

function Flashcards:deleteCurrentCard(expected_card)
    if self.busy or self._inspection_cursor or self.state ~= "card" then return true end
    local old_cards = self.cards or {}
    local old_idx = self.idx
    local card = old_cards[old_idx]
    -- Don't delete another word if the deck moved while confirmation was open.
    if not card or card ~= expected_card then return true end
    self.busy = true
    local ok, removed, reason = pcall(self.delete_func, card)
    if not ok or removed ~= true then
        self.busy = false
        logger.warn("vocab flashcards: could not delete word:", ok and reason or removed)
        UIManager:show(newFlashInfo(self, {
            text = _("Could not delete this flashcard. No changes were made to the displayed deck."),
            timeout = 4,
        }))
        return true
    end

    pcall(removeDualEntry, card.word)
    self:_resetDualCard()
    -- Only the deleted word is removed from the session. Avoid reloadDeck(),
    -- which would discard the session's review history and disable Undo.
    local deleting_from_retry = self.retry_round
    if self.training then
        self.training:remove(card.word)
        self.retry_total = self.training.added
        self:_persistIntensiveProgress()
    end
    if self._cram_store then
        local removed_cram, err = pcall(self._cram_store.removeWord,
            self._cram_store, card.word)
        if not removed_cram then
            logger.warn("FlipSide cram: could not purge deleted word:", err)
        end
    end
    if deleting_from_retry then
        self._training_current = nil
        self.retry_round = false
    end
    for i = #self.all_cards, 1, -1 do
        if self.all_cards[i].word == card.word then
            table.remove(self.all_cards, i)
        end
    end
    self:_validateFilter()
    if deleting_from_retry then
        -- _buildView() uses due_time, but forgotten words are scheduled for
        -- later; rebuilding here would lose the immediate retry queue.
        local kept = {}
        for _, existing in ipairs(old_cards) do
            if existing ~= card then kept[#kept + 1] = existing end
        end
        self.cards = kept
    else
        self.cards = self:_buildView()
    end

    -- Answer history stores indices of this view. Remap by card identity so
    -- a deletion never makes Undo restore the wrong word.
    local new_positions = {}
    for i, remaining in ipairs(self.cards) do
        new_positions[remaining] = i
    end
    local mapped_history = {}
    for _, record in ipairs(self.history) do
        local previous_card = old_cards[record.idx]
        local position = previous_card and new_positions[previous_card]
        if position then
            mapped_history[#mapped_history + 1] = {
                idx = position, got = record.got,
                cram_added = record.cram_added,
                cram_slot = record.cram_slot,
                cram_before = record.cram_before,
                cram_before_all = record.cram_before_all,
            }
        end
    end
    self.history = mapped_history
    -- An already answered word can be deleted during the reinforcement pass.
    -- Keep the finished-screen totals aligned with the surviving history.
    self.got, self.forgot = 0, 0
    for _, record in ipairs(mapped_history) do
        if record.got then self.got = self.got + 1
        else self.forgot = self.forgot + 1 end
    end
    self.touched = true -- refresh the original Vocabulary Builder list on exit
    self.show_ctx = false
    self.show_more_ctx = false

    local n = #self.cards
    if n == 0 then
        self.idx = 1
        self.state = "empty"
    else
        -- Prefer the next card at the deleted position, skipping answered
        -- cards while retaining them in the deck for the Undo history.
        local next_pending
        for offset = 0, n - 1 do
            local i = ((old_idx - 1 + offset) % n) + 1
            if not self.cards[i].done then
                next_pending = i
                break
            end
        end
        self.idx = next_pending or 1
        self.state = next_pending and "card" or "done"
        if self.state == "done" then self.retry_round = false end
    end
    if self.state == "done" and self:_startMissedRound() then
        -- Deleting the active training card continues with the next queued
        -- word, instead of discarding the rest of the reinforcement round.
    end
    self:_render()
    self:_refresh()
    self.busy = false
    self:_offerCramResetForEmptyDeck()
    return true
end

function Flashcards:_flush()
    if self.flush_func then
        local ok, err = pcall(self.flush_func)
        if not ok then
            logger.warn("vocab flashcards: flush failed:", err)
        end
    end
end

---------------------------------------------------------------- filter

-- Only mature, not-yet-reviewed-today cards can enter the early batch.
-- Do not change SQLite due_time here. The real KOReader SRS scheduler still
-- decides every future interval after Forgot/Got it.
local function nextLocalMidnight()
    return dayStart(-1) -- local clock date, safe across DST transitions
end

local function isAdvanceCandidate(card, now, today0, midnight)
    local due, created, reviewed = tonumber(card.due), tonumber(card.created),
        tonumber(card.reviewed)
    if not due or due <= now or due >= midnight then return false end
    -- Unknown history, brand-new words and previously unreviewed words stay
    -- protected (fail closed). A word reviewed even ONCE today is also
    -- protected, including words forgotten and subsequently recalled today.
    if not created or created >= today0 or not reviewed
            or reviewed >= today0 or reviewed < created
            or card.never_reviewed == true then
        return false
    end
    -- 0 = forgotten, 1 = 30-minute interval, 2 = 12-hour interval.
    -- Three consecutive successful native reviews are the minimum for early
    -- consolidation; 5/30m/12h learning and relearning stay scheduled.
    return (tonumber(card.streak_count) or 0) >= 3
end

function Flashcards:_isReviewEligible(card, now)
    now = now or os.time()
    if not card.due then return false end
    if card.due <= now then return true end -- native due is NEVER blocked
    return self.advance_today and self.advance_day == localDayKey()
        and isAdvanceCandidate(card, now, dayStart(0), nextLocalMidnight())
        or false
end

-- Initial reviews are available immediately ONLY in the four collection
-- shortcuts. This bypasses the initial 5-minute *visibility* wait, but never
-- writes due_time or changes subsequent native SRS intervals. Book-specific
-- filters still use the existing due-time rules.
local function isImmediateFirstReview(card, filter)
    local kind = filter and filter.kind
    return card.never_reviewed == true
        and (kind == "all" or kind == "today" or kind == "yesterday"
            or kind == "never_reviewed")
end

function Flashcards:_isAvailableInCollection(card, now)
    return self:_isReviewEligible(card, now)
        or isImmediateFirstReview(card, self.filter)
end

-- Count only the additional mature cards advanced in this collection. Also
-- count protected learning cards due later today, for the compact explanation
-- in the same menu. Count and eligibility share one exact predicate.
function Flashcards:_advanceTodayCounts()
    local now, today0, end_today = os.time(), dayStart(0), nextLocalMidnight()
    local yest0 = dayStart(1)
    local advance, scheduled = 0, 0
    for _, card in ipairs(self.all_cards or {}) do
        if cardMatches(card, self.filter, today0, yest0)
                and card.due and card.due > now and card.due < end_today then
            if isAdvanceCandidate(card, now, today0, end_today) then
                advance = advance + 1
            else
                scheduled = scheduled + 1
            end
        end
    end
    return advance, scheduled
end

function Flashcards:_advanceTodayCount()
    local advance = self:_advanceTodayCounts()
    return advance
end

function Flashcards:_buildView()
    local today0, yest0 = dayStart(0), dayStart(1)
    local now = os.time()
    local view = {}
    for _, c in ipairs(self.all_cards or {}) do
        if cardMatches(c, self.filter, today0, yest0)
                and (self.practice or self:_isAvailableInCollection(c, now)) then
            table.insert(view, c)
        end
    end
    return view
end

-- The groups to choose from, with the number of cards still to review in each.
function Flashcards:_filterOptions()
    local today0, yest0 = dayStart(0), dayStart(1)
    local now = os.time()
    local all_n, today_n, yest_n, never_n = 0, 0, 0, 0
    local books, order = {}, {}
    for _i, c in ipairs(self.all_cards or {}) do
        if not c.done and c.never_reviewed then
            -- Virtual Filters ignores the due-only setting for this group.
            never_n = never_n + 1
        end
        -- Reinforcement candidates are practice presentations, not newly
        -- due native reviews. Never inflate the official collection counters.
        local pending = not c.done and not c._retry_pending
            and not c._training_only and (self.practice
                or self:_isReviewEligible(c, now))
        -- The top four collections expose never-reviewed words instantly.
        -- A later, already-reviewed card remains hidden until its SRS due.
        local first = not c.done and not c._retry_pending
            and not c._training_only and c.never_reviewed == true
        if pending or first then
            if inAllBooks(c, today0, yest0) then
                all_n = all_n + 1
            end
            if c.created then
                if c.created >= today0 then
                    today_n = today_n + 1
                elseif c.created >= yest0 then
                    yest_n = yest_n + 1
                end
            end
        end
        local b = c.book
        if type(b) == "string" and b ~= "" then
            if books[b] == nil then
                books[b] = 0
                table.insert(order, b)
            end
            if pending then books[b] = books[b] + 1 end
        end
    end
    table.sort(order)
    local opts = {
        { kind = "all", label = _("All books"), count = all_n },
        { kind = "today", label = _("Added today"), count = today_n },
        { kind = "yesterday", label = _("Added yesterday"), count = yest_n },
        { kind = "never_reviewed", label = _("Never Reviewed"), count = never_n },
    }
    for _i, b in ipairs(order) do
        table.insert(opts, { kind = "book", book = b, label = b, count = books[b] })
    end
    return opts
end

-- After the real review ends, tell the reader how many database cards
-- remain due before local midnight (including overdue cards, regardless of
-- book filters). One SQL read per end-screen render, never per timer tick.
local function todayRemainingReviews()
    local SQ3 = require("lua-ljsqlite3/init")
    local path = DataStorage:getSettingsDir() .. "/flipside/vocabulary_builder.sqlite3"
    local now = os.time()
    local today = os.date("*t", now)
    today.hour, today.min, today.sec = 0, 0, 0
    local tomorrow = os.time{ year = today.year, month = today.month,
        day = today.day + 1, hour = 0, min = 0, sec = 0 }
    local conn = SQ3.open(path)
    local count = conn:rowexec("SELECT COUNT(*) FROM vocabulary WHERE due_time < " .. tomorrow .. ";")
    local next_due = conn:rowexec("SELECT MIN(due_time) FROM vocabulary WHERE due_time >= "
        .. now .. " AND due_time < " .. tomorrow .. ";")
    conn:close()
    return tonumber(count) or 0, tonumber(next_due)
end

function Flashcards:_completionDetails()
    -- Keep the original native vocabulary database as the only schedule
    -- source, and keep the full catalog card count independent of filters.
    local result = {saved=#(self.all_cards or {}), due="—", next_review="Not scheduled"}
    local ok, due, upcoming = pcall(todayRemainingReviews)
    if ok then
        result.due = tostring(due)
    else
        logger.warn("vocab flashcards: completion due count unavailable:", due)
    end
    if not upcoming then
        local success, stamp = pcall(function()
            local SQ3 = require("lua-ljsqlite3/init")
            local conn = SQ3.open(DataStorage:getSettingsDir() .. "/flipside/vocabulary_builder.sqlite3")
            local query_ok, next_value = pcall(conn.rowexec, conn,
                "SELECT MIN(due_time) FROM vocabulary WHERE due_time >= " .. os.time() .. ";")
            pcall(conn.close, conn)
            if not query_ok then error(next_value) end
            return tonumber(next_value)
        end)
        if success then upcoming = stamp end
    end
    local now = os.time()
    local function timeLabel(stamp)
        if not stamp then return nil end
        return (os.date("%Y-%m-%d", stamp) == os.date("%Y-%m-%d", now))
            and os.date("%H:%M", stamp) or os.date("%d %b %H:%M", stamp)
    end
    if upcoming then result.next_review = timeLabel(upcoming) end

    -- The completion panel must distinguish the latest REAL answer for each
    -- word. A retry in Intensive/Practice never changes its native due date,
    -- and an Undo removes the matching entry from this official history.
    local last_answer = {}
    for _, record in ipairs(self.history or {}) do
        local card = self.cards and self.cards[record.idx]
        if card and type(card.word) == "string" then
            last_answer[card.word] = record.got and "correct" or "missed"
        end
    end

    -- Read the entire real schedule, not just MIN(due_time). That aggregate
    -- provides no way to show the separate 5-minute missed-card reviews.
    -- This is a read-only query: no rating, database, or SRS behavior changes.
    local read_ok, rows = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DataStorage:getSettingsDir()
            .. "/flipside/vocabulary_builder.sqlite3")
        local query_ok, values = pcall(conn.exec, conn,
            "SELECT word, due_time FROM vocabulary WHERE due_time IS NOT NULL;")
        pcall(conn.close, conn)
        if not query_ok then error(values) end
        return values
    end)
    if read_ok and type(rows) == "table" and type(rows.word) == "table" then
        local buckets = {
            missed = {count=0, due_now=0},
            correct = {count=0, due_now=0},
            other = {count=0, due_now=0},
        }
        local due_now, next_any = 0, nil
        for i, word in ipairs(rows.word) do
            local due = tonumber(rows.due_time and rows.due_time[i])
            if type(word) == "string" and due then
                local bucket = buckets[last_answer[word] or "other"]
                bucket.count = bucket.count + 1
                if due <= now then
                    bucket.due_now = bucket.due_now + 1
                    due_now = due_now + 1
                else
                    if not bucket.next or due < bucket.next then bucket.next = due end
                    if not next_any or due < next_any then next_any = due end
                end
            end
        end
        -- The nearest review includes EVERY category, irrespective of the
        -- book currently selected or whether its last answer was correct.
        if next_any then result.next_review = timeLabel(next_any) end
        local function categoryLabel(name, bucket, show_count)
            if bucket.count == 0 then return nil end
            local next_text = bucket.due_now > 0 and "due now"
                or timeLabel(bucket.next)
            if not next_text then return nil end
            if show_count then
                return name .. ": " .. bucket.count .. " · next " .. next_text
            end
            return name .. ": next " .. next_text
        end
        result.missed_review = categoryLabel("Missed", buckets.missed, true)
        result.correct_review = categoryLabel("Correct", buckets.correct, true)
        result.other_review = categoryLabel("Other reviews", buckets.other, false)
        if due_now > 0 then
            result.due_now = "Due now: " .. due_now
                .. (due_now == 1 and " card" or " cards")
        end
    elseif not read_ok then
        logger.warn("vocab flashcards: completion schedule breakdown unavailable:", rows)
    end
    local correct, missed = tonumber(self.got) or 0, tonumber(self.forgot) or 0
    if correct + missed > 0 then
        result.session_reviews = string.format("This session: %d correct, %d missed", correct, missed)
    end
    return result
end

function Flashcards:_remainingTodayLabel()
    if self.practice then return nil end
    local ok, count, upcoming = pcall(todayRemainingReviews)
    if not ok then
        logger.warn("vocab flashcards: could not load daily remaining reviews:", count)
        return nil
    end
    local line = string.format("Still to review today: %d cards", count)
    if upcoming then line = line .. " · Next: " .. os.date("%H:%M", upcoming) end
    return line
end

-- For an empty group (including Never Reviewed): say if words exist but
-- are not due yet (the flashcards only hold the words due for review).
function Flashcards:_emptyNote()
    local today0, yest0 = dayStart(0), dayStart(1)
    local total = 0
    local next_due
    local now = os.time()
    for _i, c in ipairs(self.all_cards or {}) do
        if cardMatches(c, self.filter, today0, yest0) then
            total = total + 1
            if c.due and c.due > now and (not next_due or c.due < next_due) then
                next_due = c.due
            end
        end
    end
    if total == 0 then return _("Choose another collection or reload.") end
    if self.practice then return nil end
    if next_due then
        return T(_("%1 saved words. Next review: %2. Use Practice to study now."),
            total, os.date("%Y-%m-%d %H:%M", next_due))
    end
    return T(_("%1 saved words. Use Practice to study them now."), total)
end

-- Show a selected collection. Current group changes never alter the selected
-- group list. A new deck view starts from its first pending word.
function Flashcards:setFilter(opt)
    if self.busy or self.retry_round
            or not containsFilter(self.selected_filters, opt) then return true end
    if self.training and not self:_persistIntensiveProgress() then return true end
    self:_pauseIntensiveAttempt()
    self:_persistIntensiveProgress()
    self.filter = copyFilter(opt)
    saveFilter(self.filter)
    self._inspection_cursor, self._inspection_resume = nil, nil
    self:_resetDualCard()
    self.cards = self:_buildView()
    self.idx = 1
    self.history = {}
    self._browse_back = {}
    self.retry_round = false
    self.retry_total = 0
    self.retry_seen = 0
    self.retry_got = 0
    self.retry_forgot = 0
    self:_initializeIntensive()
    self.show_ctx = false
    self.show_more_ctx = false
    self.state = (#self.cards == 0) and "empty" or "card"
    if self.state == "empty" then self:_startMissedRound() end
    self:_render()
    self:_refresh()
    self:_armDueWatch()
    return true
end

-- Apply checked groups atomically when the user taps Done in the picker.
-- Use the order shown in the picker (All, Today, Yesterday, Never Reviewed, books).
function Flashcards:setFilters(picked)
    if self.busy then return true end
    local ordered = {}
    for _, option in ipairs(self:_filterOptions()) do
        if containsFilter(picked, option) then
            ordered[#ordered + 1] = copyFilter(option)
        end
    end
    if #ordered == 0 then return false end
    self.selected_filters = ordered
    saveSelectedFilters(ordered)
    local active = containsFilter(ordered, self.filter) and self.filter or ordered[1]
    return self:setFilter(active)
end

-- Horizontal gesture over the collection label switches ONLY among the
-- checked groups. Horizontal gesture over the card browses words instead.
function Flashcards:stepFilter(direction)
    if self.retry_round then return true end
    local groups = self.selected_filters or {}
    local count = #groups
    if self.busy or count < 2 then return true end
    local current = 1
    for i, option in ipairs(groups) do
        if sameFilter(option, self.filter) then current = i break end
    end
    local next_i = ((current - 1 + direction) % count) + 1
    return self:setFilter(groups[next_i])
end

-- Rebuild the queue without resetting recorded answers or native Undo.
-- History stores indices into self.cards, so remap after the view changes.
function Flashcards:_rebuildAfterAdvanceToggle()
    local old = self.cards or {}
    local old_current = old[self.idx]
    local fresh = self:_buildView()
    local positions = {}
    for index, card in ipairs(fresh) do positions[card] = index end
    -- Completed cards remain accessible via Undo and history inspection even
    -- if disabling early review removes their original eligibility.
    for _, card in ipairs(old) do
        if card.done and not positions[card] then
            table.insert(fresh, card)
            positions[card] = #fresh
        end
    end
    local new_history = {}
    for _, record in ipairs(self.history or {}) do
        local card = old[record.idx]
        if card and positions[card] then
            table.insert(new_history, {idx=positions[card], got=record.got,
                cram_added=record.cram_added, cram_slot=record.cram_slot,
                cram_before=record.cram_before,
                cram_before_all=record.cram_before_all})
        end
    end
    self.cards = fresh
    self.history = new_history
    self._inspection_cursor, self._inspection_resume = nil, nil
    self:_resetDualCard()
    local wanted = old_current and positions[old_current]
    if wanted and not fresh[wanted].done then
        self.idx = wanted
        self.state = "card"
    else
        self.idx = 1
        local found = false
        for index, card in ipairs(fresh) do
            if not card.done then self.idx = index; found = true; break end
        end
        self.state = found and "card" or (#fresh == 0 and "empty" or "done")
    end
    self.show_ctx, self.show_more_ctx = false, false
    self._browse_back = {}
    self:_render()
    self:_refresh()
    self:_armDueWatch()
    return true
end

function Flashcards:setAdvanceToday(enabled)
    if self.busy or self.retry_round or self._inspection_cursor then return true end
    enabled = enabled == true
    -- Choosing a real early SRS review from Practice enters Due mode, where
    -- Forgot/Got it use the native scheduling and Learning Audit as usual.
    if enabled and self.practice then
        self.advance_today = true
        self.advance_day = localDayKey()
        saveAdvanceToday(true)
        self.practice = false
        savePractice(false)
        return self:reloadDeck()
    end
    if self.advance_today == enabled and self.advance_day == localDayKey() then
        return true
    end
    self.advance_today = enabled
    self.advance_day = localDayKey()
    saveAdvanceToday(enabled)
    return self:_rebuildAfterAdvanceToggle()
end

-- Monochrome Today-only popover. Keep the native KOReader ButtonDialog
-- gesture/focus machinery and the exact pre-existing SRS logic, but compose
-- its header from real non-interactive widgets instead of giant multiline
-- labels or disabled fake buttons. The anchored rectangle has NO pointer.
function Flashcards:showAdvanceTodayMenu()
    if self.busy then return true end
    if self._today_dialog and UIManager:isWidgetShown(self._today_dialog) then
        UIManager:close(self._today_dialog)
        self._today_dialog = nil
        return true
    end
    self:_clockPause()
    local count, protected = self:_advanceTodayCounts()
    local dialog
    local function choose(enabled)
        -- A native button is still dispatching the tap. Close the dialog
        -- BEFORE rebuilding the main screen, on the next UI event tick.
        UIManager:close(dialog)
        if self._today_dialog == dialog then self._today_dialog = nil end
        UIManager:nextTick(function()
            if self._closing or not UIManager:isWidgetShown(self) then return end
            if self.retry_round or self._inspection_cursor then
                UIManager:show(newFlashInfo(self, {
                    text = "Finish the current review/inspection before changing Today's mode.",
                    timeout = 4,
                }))
                return
            end
            if self.advance_today ~= enabled or (enabled and self.practice) then
                self:setAdvanceToday(enabled)
            end
        end)
    end

    -- Information is separate from the action buttons; it never changes
    -- Advance Today, SRS dates, or the active review queue.
    local function showAdvanceHelp()
        UIManager:show(newFlashInfo(self, {
            text = "Advance Today lets you study some cards early.\n\n"
                .. "It only picks cards due later today.\n"
                .. "New cards and cards still learning are not moved.\n\n"
                .. "Normal mode: follow your usual review times.\n"
                .. "Advance today: bring eligible reviews forward.\n\n"
                .. "Your answers still use the normal KOReader review schedule.",
            show_icon = false,
            width = math.floor(math.min(Screen:getWidth() * .82,
                Screen:scaleBySize(570))),
        }))
    end
    local popup_w = math.floor(math.min(Screen:getWidth() * 0.70,
        Screen:scaleBySize(480)))
    -- ButtonDialog allocates this width to its header (see
    -- ButtonDialog:init). Deriving it from the same paddings prevents a
    -- rounded header pill from protruding on narrow Kindle screens.
    local title_padding = math.max(2, Size.padding.small)
    local title_margin = math.max(2, Size.margin.default)
    local header_w = popup_w - 2*Size.border.window - 2*Size.padding.button
        - 2*(title_padding + title_margin)
    header_w = math.max(100, header_w)
    local vspace = math.max(3, Screen:scaleBySize(5))
    local info_size = 18
    local pill_padding = math.max(4, Screen:scaleBySize(7))
    local pill_text = ("»  Advance %d %s"):format(
        count, count == 1 and "card" or "cards")
    local pill_label = TextWidget:new{
        text = pill_text,
        face = Font:getFace("smalltfont", info_size),
        max_width = header_w - pill_padding * 2,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local pill = FrameContainer:new{
        bordersize = 0,
        padding = pill_padding,
        margin = 0,
        radius = Screen:scaleBySize(18),
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = Geom:new{
                w = header_w - 2*pill_padding,
                h = pill_label:getSize().h,
            },
            pill_label,
        },
    }
    pill.not_focusable = true
    local subtitle = TextBoxWidget:new{
        text = ("%d protected %s %s scheduled"):format(
            protected, protected == 1 and "card" or "cards",
            protected == 1 and "stays" or "stay"),
        width = header_w,
        face = Font:getFace("smallinfofont", 15),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        alignment = "center",
    }
    subtitle.not_focusable = true
    local gap = VerticalSpan:new{ width = vspace }
    gap.not_focusable = true
    -- Native selected-row highlighting and two large tap targets. Unlike
    -- the original modal, no information label is an inactive ButtonTable
    -- row; only these mutually exclusive choices can receive taps.
    local selected_normal = not self.advance_today
    local popup_header = require("flipside_popup_header").new(
        "ADVANCE TODAY", header_w, showAdvanceHelp, 18)
    dialog = ButtonDialog:new{
        width = popup_w,
        use_info_style = true,
        info_padding = 0,
        info_margin = 0,
        _added_widgets = {popup_header, gap, pill, gap, subtitle},
        buttons = {
            {{text = (selected_normal and "●  " or "○  ") .. "Normal mode",
                font_size = 18, font_bold = true, align = "left",
                background = selected_normal and Blitbuffer.COLOR_LIGHT_GRAY or nil,
                enabled = true, id = "normal",
                callback = function() choose(false) end}},
            {{text = (selected_normal and "○  " or "●  ") .. "Advance today",
                font_size = 18, font_bold = true, align = "left",
                background = not selected_normal and Blitbuffer.COLOR_LIGHT_GRAY or nil,
                enabled = true, id = "advance",
                callback = function() choose(true) end}},
        },
        -- No triangular pointer: MovableContainer positions a plain rounded
        -- rectangle. Align the right edge below the toolbar's last icon,
        -- with an inset from the screen edge; clamp on small displays.
        anchor = function()
            local icon = self.advance_today_button and self.advance_today_button.dimen
            if not icon then return nil end
            local inset = math.max(3, Screen:scaleBySize(8))
            return Geom:new{
                x = math.max(inset, Screen:getWidth() - popup_w - inset),
                y = icon.y + icon.h + Screen:scaleBySize(3),
                w = 0, h = 0,
            }, true
        end,
        tap_close_callback = function()
            if self._today_dialog == dialog then self._today_dialog = nil end
        end,
    }
    self._today_dialog = dialog
    UIManager:show(dialog)
    return true
end

-- Preview of distinct unfinished words for each cram mode in the current
-- filter. No DB writes and no mutation of active/saved queues. The exact
-- same restore, current-session errors and Ultra historical eligibility
-- rules as _initializeIntensive / applySelection are used here.
-- Unavailable storage/catalog is displayed as a dash, never a false zero.
function Flashcards:_cramAvailableCounts()
    if not self._cram_store or not self.all_cards
            or not self.all_cards.full_catalog then return nil, nil end
    local cards_by_word, in_view, recent_misses = {}, {}, {}
    for _, card in ipairs(self.all_cards) do
        if type(card.word) == "string" then cards_by_word[card.word] = card end
    end
    for _, card in ipairs(self.cards or {}) do in_view[card.word] = true end
    for _, record in ipairs(self.history or {}) do
        if not record.got then
            local card = self.cards and self.cards[record.idx]
            if card and cards_by_word[card.word] then
                recent_misses[card.word] = cards_by_word[card.word]
            end
        end
    end

    -- A pending official review is NOT yet a cram presentation, but it is
    -- a real eligible Ultra candidate. Include it in the menu preview and
    -- let _initializeIntensive keep it in _ultra_waiting until its first
    -- official answer. This fixes historical counts appearing as 0 or 1
    -- when many historical words are also due in today's normal session.
    local recurring, history_meta = recentRecurringErrors()
    local today0, yesterday0 = dayStart(0), dayStart(1)
    local waiting, in_filter = 0, 0
    for _, word in ipairs(recurring) do
        local card = cards_by_word[word]
        if card and cramCardMatches(card, self.filter, today0, yesterday0, true) then
            in_filter = in_filter + 1
            if not self.practice and in_view[word] and not card.done then
                waiting = waiting + 1
            end
        end
    end
    history_meta.in_filter = in_filter
    history_meta.awaiting_official = waiting
    self._cram_history_meta = history_meta

    local function preview(mode)
        local saved
        if self.training and self.intensive_mode == mode then
            saved = self.training:snapshot()
        else
            saved = self._cram_store:get(CramStore.key(mode, self.filter))
        end
        local queue = Intensive.restore(mode, saved, cards_by_word)
        for _, card in pairs(recent_misses) do
            -- Reopening a menu must not erase a completed cram streak.
            if not queue:has(card.word) then queue:add(card) end
        end
        if mode == "ultra" then
            for _, word in ipairs(recurring) do
                local card = cards_by_word[word]
                if card and cramCardMatches(card, self.filter,
                        today0, yesterday0, true) then
                    -- This is a READ-ONLY preview: count the ones waiting
                    -- for an official review too, without adding them to
                    -- the live training queue or modifying saved progress.
                    queue:add(card)
                end
            end
        end
        return queue:available()
    end
    return preview("intensive"), preview("ultra"), history_meta
end

-- This popover uses KOReader's native ButtonDialog, like Advance Today.
-- Mode and placement are independent settings. OFF suppresses ALL extra
-- reinforcement; Practice remains practice-only and cannot add SRS reviews.
function Flashcards:showIntensiveMenu()
    if self.busy then return true end
    if self._intensive_dialog and UIManager:isWidgetShown(self._intensive_dialog) then
        UIManager:close(self._intensive_dialog)
        self._intensive_dialog = nil
        return true
    end
    self:_clockPause()

    local width = math.floor(math.min(Screen:getWidth() * 0.79,
        Screen:scaleBySize(510)))
    local pending_mode = self.intensive_mode
    local pending_timing = self.intensive_timing
    local first_group = nil
    local dialog

    -- The two selections are independent preferences. Commit EACH choice
    -- immediately; an interrupted/dismissed popup must never discard it.
    -- The two-tap gesture controls only when the popup closes, not when
    -- the user's choice is saved. This also avoids a stale UI callback
    -- silently losing a mode/timing combination on Kindle.
    local buildDialog
    local function applySelection(mode, timing, keep_open)
        UIManager:nextTick(function()
            if self._closing or not UIManager:isWidgetShown(self) then return end
            local function reopen()
                if not keep_open then return end
                UIManager:nextTick(function()
                    if not self._closing and UIManager:isWidgetShown(self) then
                        buildDialog()
                    end
                end)
            end
            local function reject(message)
                pending_mode = self.intensive_mode
                pending_timing = self.intensive_timing
                first_group = nil
                reopen()
                if message then
                    UIManager:show(newFlashInfo(self, {
                        text = message, timeout = 7,
                    }))
                end
            end
            if self._inspection_cursor then
                reject("Finish the card inspection before changing reinforcement.")
                return
            end
            if mode ~= "off" and (not self._cram_store
                    or self._cram_unavailable) then
                reject("CRAM MODE cannot start: progress storage unavailable. "
                    .. "Normal SRS reviews remain safe.")
                return
            end
            if mode == self.intensive_mode and timing == self.intensive_timing then
                reopen()
                return
            end
            -- First save the active queue; refusing a change is safer than
            -- overwriting an unsaved streak or an unanswered practice word.
            if self.training and not self:_persistIntensiveProgress() then
                reject("CRAM progress could not be saved; mode not changed.")
                return
            end
            local saved, save_err = pcall(saveIntensivePreferences, mode, timing)
            if not saved then
                logger.warn("FlipSide cram: preference save failed:", save_err)
                Diag.report("ERROR", "CRAM_PREFERENCE_FAILED",
                    {mode=mode, timing=timing}, save_err)
                reject("Cannot save CRAM settings. Check storage and logs.")
                return
            end
            local mode_changed = mode ~= self.intensive_mode
            local timing_changed = timing ~= self.intensive_timing
            if self.retry_round and (mode_changed or timing_changed) then
                -- Return an unanswered training card to its saved queue.
                self:_pauseIntensiveAttempt()
                local pending_index = self:_normalPendingIndex()
                self.idx = pending_index or self.idx
                self.state = pending_index and "card" or "done"
            end
            self.intensive_mode, self.intensive_timing = mode, timing
            if mode_changed then
                -- Rebuild ONLY when changing OFF/Intensive/Ultra. Merely
                -- changing During/After must preserve all cram streaks,
                -- queue order, and the completed-word set in memory.
                for _, card in ipairs(self.cards or {}) do
                    card._retry_pending = nil
                    if card._training_only then card.done = true end
                end
                self.retry_round = false
                self.retry_total, self.retry_seen = 0, 0
                self.retry_got, self.retry_forgot = 0, 0
                self:_initializeIntensive()
                for _, record in ipairs(self.history or {}) do
                    local card = self.cards[record.idx]
                    if card and not record.got and self.training
                            and not self.training:has(card.word) then
                        self.training:add(card)
                    end
                end
                if self.training and not self:_persistIntensiveProgress() then
                    logger.warn("FlipSide cram: restored queue not saved after mode change")
                    Diag.report("CRITICAL", "CRAM_CHECKPOINT_FAILED",
                        {mode=self.intensive_mode, stage="mode_change"},
                        "Queue checkpoint failed after changing modes")
                end
            end
            if (self.state == "done" or self.state == "empty")
                    and self:_startMissedRound() then
                -- Switching on cram after the last native card works too.
            end
            self:_render()
            self:_refresh()
            reopen()
        end)
    end

    -- Keep this popup compact. Explanations, mastery thresholds and the
    -- independent training counters belong in the optional information view.
    local function showHelp()
        local stats = G_reader_settings:readSetting(INTENSIVE_STATS_SETTING)
        if type(stats) ~= "table" then stats = {} end
        local function attemptsText(which)
            local bucket = type(stats[which]) == "table" and stats[which] or {}
            local correct = math.max(0, tonumber(bucket.correct) or 0)
            local missed = math.max(0, tonumber(bucket.missed) or 0)
            return string.format("%d/%d", correct, correct + missed)
        end
        local help = table.concat({
            "OFF: No additional error practice.",
            "",
            "Intensive: Train cards missed in the current review until "
                .. "2 correct recalls in a row.",
            "",
            "Ultra Intensive: Train current missed cards and recurring "
                .. "errors from the last 7 days (2 or more official "
                .. "misses; up to 40 extra words). Each word needs "
                .. "3 correct recalls in a row.",
            "",
            "During normal reviews: Interleave one training attempt "
                .. "after every 2 normal answers. Remaining practice "
                .. "continues when the normal queue ends.",
            "",
            "After normal reviews: Complete the normal review "
                .. "queue before starting error practice.",
            "",
            "Training queue: A wrong answer resets the training streak "
                .. "and moves that word to the END of the queue. "
                .. "A correct answer also goes to the end until its "
                .. "target is reached. There is no timed delay.",
            "",
            "Review dates: Only Due answers change normal review dates "
                .. "and official accuracy. Practice and extra CRAM "
                .. "answers do not change review dates.",
            "",
            "Practice: Forgot adds the word to both saved CRAM queues. "
                .. "Practice never changes normal review dates or official statistics.",
            "",
            "Progress: Each mode keeps its own saved queue. Switching "
                .. "OFF, changing modes or leaving FlipSide does not "
                .. "erase unfinished correct recalls. Back up "
                .. "settings/flipside/cram_progress.lua when migrating.",
            "",
            "Available numbers: Distinct unfinished cram words in this "
                .. "filter, including saved progress. Ultra also counts "
                .. "recurrent errors from dated local AND synced Learning "
                .. "Analysis history. A historical word awaiting its first "
                .. "normal review is shown in this PREVIEW but does not "
                .. "enter training until that normal answer is finished. "
                .. "These numbers never increase official review counts.",
            "",
            (function()
                local _, _, meta = self:_cramAvailableCounts()
                meta = meta or self._cram_history_meta or {}
                if meta.unavailable then
                    return "Last 7 days: history unavailable. Check Learning Analysis and logs."
                end
                return string.format("Last 7 days: %d dated official reviews; "
                    .. "%d wrong answers; %d words with 2+ errors; "
                    .. "%d eligible in current filter (%d awaiting normal review)%s.",
                    tonumber(meta.dated_reviews) or 0,
                    tonumber(meta.error_attempts) or 0,
                    tonumber(meta.recurring_total) or 0,
                    tonumber(meta.in_filter) or 0,
                    tonumber(meta.awaiting_official) or 0,
                    meta.partial and "; imported history partly unavailable" or "")
            end)(),
            "Older statistics without dated answers cannot be assigned to the last 7 days.",
            "",
            "Training correct/attempts: Intensive " .. attemptsText("intensive")
                .. " | Ultra " .. attemptsText("ultra"),
        }, "\n")
        UIManager:show(newFlashInfo(self, {
            text = help,
            show_icon = false,
            width = math.floor(math.min(Screen:getWidth() * 0.83,
                Screen:scaleBySize(580))),
            height = math.floor(Screen:getHeight() * 0.62),
            face = Font:getFace("smallinfofont", 17),
        }))
    end

    local function option(text, selected, callback)
        return {{
            text = (selected and "●  " or "○  ") .. text,
            font_size = 17, font_bold = true, align = "left",
            background = selected and Blitbuffer.COLOR_LIGHT_GRAY or nil,
            callback = callback,
        }}
    end

    local function closeDialog()
        if dialog and UIManager:isWidgetShown(dialog) then
            UIManager:close(dialog)
        end
        if self._intensive_dialog == dialog then self._intensive_dialog = nil end
    end

    local function choose(group, value)
        if self._inspection_cursor then
            UIManager:show(newFlashInfo(self, {
                text = "Finish the card inspection before changing reinforcement.",
                timeout = 4,
            }))
            return
        end
        if group == "mode" then
            pending_mode = value
        else
            pending_timing = value
        end
        local second_group = first_group and first_group ~= group
        if not first_group then first_group = group end
        -- Close the old widget before applying/re-rendering the Flashcards
        -- view; recreate the popup only while the second group is unchosen.
        closeDialog()
        applySelection(pending_mode, pending_timing, not second_group)
    end

    buildDialog = function()
        local intensive_count, ultra_count = self:_cramAvailableCounts()
        if intensive_count == nil or ultra_count == nil then
            Diag.report("WARNING", "CRAM_COUNTER_UNAVAILABLE",
                {mode=self.intensive_mode, practice=self.practice,
                 has_catalog=self.all_cards and self.all_cards.full_catalog == true},
                "Saved progress or full catalog could not be accessed")
        end
        local function countLabel(mode, count)
            local label = mode == "ultra" and "Ultra Intensive" or "Intensive"
            return label .. " (" .. (count ~= nil and tostring(count) or "—") .. ")"
        end
        -- A dedicated native header keeps CRAM MODE centered independently
        -- of the touchable info glyph, which sits in the upper-right corner.
        -- Avoid an icon asset dependency so this also works on older Kindle
        -- KOReader builds that don't ship an identical info SVG.
        local info_button = Button:new{
            text = "ⓘ",
            text_font_face = "smallinfofont",
            text_font_size = 21,
            text_font_bold = true,
            bordersize = 0,
            padding_h = Screen:scaleBySize(6),
            padding_v = Screen:scaleBySize(5),
            callback = showHelp,
            show_parent = self,
            vsync = true,
        }
        local header_title = TextWidget:new{
            text = "CRAM MODE",
            face = Font:getFace("smalltfont", 20),
            bold = true,
        }
        -- ButtonDialog with info_padding/info_margin = 0 uses the full
        -- ButtonTable inner width for _added_widgets, with no title offset.
        local header_width = width - 2 * Size.border.window
            - 2 * Size.padding.button
        local title_width = header_title:getSize().w
        local info_width = info_button:getSize().w
        local right_inset = Screen:scaleBySize(6)
        local left_span = math.floor((header_width - title_width) / 2)
        -- Keep enough space for the information touch target on small screens.
        left_span = math.max(0, math.min(left_span,
            header_width - title_width - info_width - right_inset))
        local middle_span = math.max(0, header_width - left_span
            - title_width - info_width - right_inset)
        local header_row = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = left_span },
            header_title,
            HorizontalSpan:new{ width = middle_span },
            info_button,
            HorizontalSpan:new{ width = right_inset },
        }
        local header = FrameContainer:new{
            bordersize = 0,
            padding_top = Screen:scaleBySize(4),
            padding_bottom = Screen:scaleBySize(4),
            padding_left = 0,
            padding_right = 0,
            header_row,
        }
        dialog = ButtonDialog:new{
            width = width,
            use_info_style = true,
            info_padding = 0,
            info_margin = 0,
            _added_widgets = { header },
            buttons = {
                option("OFF", pending_mode == "off",
                    function() choose("mode", "off") end),
                option(countLabel("intensive", intensive_count),
                    pending_mode == "intensive",
                    function() choose("mode", "intensive") end),
                option(countLabel("ultra", ultra_count),
                    pending_mode == "ultra",
                    function() choose("mode", "ultra") end),
                option("During normal reviews", pending_timing == "during",
                    function() choose("timing", "during") end),
                option("After normal reviews", pending_timing == "after",
                    function() choose("timing", "after") end),
            },
            anchor = function()
                local icon = self.intensive_button and self.intensive_button.dimen
                if not icon then return nil end
                local inset = math.max(3, Screen:scaleBySize(8))
                return Geom:new{
                    x = math.max(inset, Screen:getWidth() - width - inset),
                    y = icon.y + icon.h + Screen:scaleBySize(3),
                    w = 0, h = 0,
                }, true
            end,
            tap_close_callback = function()
                if self._intensive_dialog == dialog then self._intensive_dialog = nil end
            end,
        }
        self._intensive_dialog = dialog
        UIManager:show(dialog)
    end

    buildDialog()
    return true
end

function Flashcards:togglePractice()
    if self.busy then return true end
    self.practice = not self.practice
    savePractice(self.practice)
    return self:reloadDeck()
end

-- Select as many groups as desired; the picker stays open while checking.
-- Closing it with X cancels edits; Done applies and saves them together.
function Flashcards:showFilterPicker()
    if self.busy then return true end
    local picked = {}
    for _, filter in ipairs(self.selected_filters or {}) do
        picked[#picked + 1] = copyFilter(filter)
    end
    local options = self:_filterOptions()
    local menu
    local function populate()
        local items = {}
        for _, option in ipairs(options) do
            local checked = containsFilter(picked, option)
            items[#items + 1] = {
                text = (checked and "☑  " or "☐  ") .. option.label,
                mandatory = tostring(option.count),
                bold = checked,
                filter = option,
            }
        end
        items[#items + 1] = {
            text = _("Done"),
            mandatory = tostring(#picked) .. " " .. _("selected"),
            bold = true,
            is_done = true,
        }
        return items
    end
    local flash = self
    menu = newFlashMenu(self, {
        title = _("Review words from"),
        item_table = populate(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(_menu, item)
            if not item then return true end
            if item.is_done then
                if #picked == 0 then
                    UIManager:show(newFlashInfo(self, {
                        text = _("Select at least one collection."), timeout = 3,
                    }))
                    return true
                end
                UIManager:close(menu)
                flash:setFilters(picked)
                return true
            end
            if item.filter then
                local at
                for i, selected in ipairs(picked) do
                    if sameFilter(selected, item.filter) then at = i break end
                end
                if at then
                    table.remove(picked, at)
                else
                    picked[#picked + 1] = copyFilter(item.filter)
                end
                menu.item_table = populate()
                menu:updateItems(menu.page)
            end
            return true
        end,
    })
    UIManager:show(menu)
    return true
end

---------------------------------------------------------------- sentence appearance

-- The Aa button uses a native KOReader menu with local typography only.
-- No on-card controls steal touches from dictionary lookup or context reveal.
function Flashcards:showSentenceAppearance()
    if self.busy then return true end
    local menu
    local function populate()
        local items = {}
        items[#items + 1] = {
            text = "Choose font",
            mandatory = require("flipside_font_picker").label(self.sentence_font),
            sentence_choose_font = true,
        }
        items[#items + 1] = {
            text = "Card styles",
            mandatory = Flash.cardStyleLabel(self.card_style),
            sentence_card_styles = true,
        }
        items[#items + 1] = {
            text = "Immersion mode",
            mandatory = self.immersive and "ON" or "OFF",
            sentence_immersion = true,
        }
        items[#items + 1] = {
            text = _("Smaller sentence (A−)"),
            mandatory = tostring(self.sentence_size),
            sentence_delta = -SENTENCE_STEP,
        }
        items[#items + 1] = {
            text = _("Larger sentence (A+)"),
            mandatory = tostring(self.sentence_size),
            sentence_delta = SENTENCE_STEP,
        }
        items[#items + 1] = {
            text = _("Restore font and context size"),
            sentence_reset = true,
        }
        items[#items + 1] = {
            text = "Review strategy",
            mandatory = DUAL_STRATEGIES[self.dual_strategy] or DUAL_STRATEGIES.off,
            dual_review_settings = true,
        }
        items[#items + 1] = {
            text = "Sync settings",
            open_sync_settings = true,
        }
        items[#items + 1] = {
            text = "Import from Vocabulary Builder",
            import_official_vocabulary = true,
        }
        items[#items + 1] = {
            text = "Saved meanings",
            open_saved_meanings = true,
        }
        items[#items + 1] = {
            text = _("Done"),
            sentence_done = true,
            bold = true,
        }
        return items
    end
    menu = newFlashMenu(self, {
        title = _("Flashcards appearance"),
        item_table = populate(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(_menu, item)
            if not item then return true end
            if item.sentence_done then
                UIManager:close(menu)
                self:_refresh()
                return true
            end
            if item.sentence_immersion then
                UIManager:close(menu)
                UIManager:nextTick(function()
                    if UIManager:isWidgetShown(self) then
                        self:setImmersion(not self.immersive)
                    end
                end)
                return true
            end
            if item.sentence_card_styles then
                UIManager:close(menu)
                UIManager:nextTick(function()
                    if UIManager:isWidgetShown(self) then self:showCardStyles() end
                end)
                return true
            end
            if item.dual_review_settings then
                UIManager:close(menu)
                UIManager:nextTick(function()
                    if UIManager:isWidgetShown(self) then
                        self:showReviewStrategy()
                    end
                end)
                return true
            end
            if item.open_sync_settings then
                UIManager:close(menu)
                UIManager:nextTick(function()
                    if UIManager:isWidgetShown(self) then
                        self:showSyncSettings()
                    end
                end)
                return true
            end
            if item.import_official_vocabulary then
                -- Keep Aa open as the parent of the modal Yes/No dialog.
                -- Do not close the Aa menu or defer the confirmation: only an
                -- explicit Import response may start the existing importer.
                -- No read/write to the original Vocabulary Builder is
                -- triggered until the user explicitly confirms Import.
                UIManager:show(ConfirmBox:new{
                    text = "Import new words from Vocabulary Builder into FlipSide?\n\nExisting FlipSide cards and review progress will be preserved.",
                    ok_text = "Import",
                    cancel_text = "Cancel",
                    ok_callback = function()
                        UIManager:nextTick(function()
                            if not UIManager:isWidgetShown(self) then return end
                            local loading = newFlashInfo(self, {text = "Importing from Vocabulary Builder..."})
                            UIManager:show(loading)
                            UIManager:forceRePaint()
                            local ok, result = pcall(function()
                                return require("flipside_import").importNew()
                            end)
                            UIManager:close(loading)
                            if not UIManager:isWidgetShown(self) then return end
                            if ok then
                                if result.imported > 0 then self:onListChanged() end
                                UIManager:show(newFlashInfo(self, {
                                    text = string.format(
                                        "Import completed.\n\nNew cards: %d\nAlready in FlipSide: %d\n\nExisting progress was not changed. New cards will appear in the next review session.",
                                        result.imported, result.skipped),
                                }))
                            else
                                UIManager:show(newFlashInfo(self, {
                                    text = "Vocabulary Builder import failed. No existing cards were changed.\n\n" .. tostring(result),
                                }))
                            end
                        end)
                    end,
                })
                return true
            end
            if item.open_saved_meanings then
                UIManager:close(menu)
                UIManager:nextTick(function()
                    if UIManager:isWidgetShown(self) then
                        self:showSavedMeanings()
                    end
                end)
                return true
            end
            if item.sentence_choose_font then
                require("flipside_font_picker").open(
                    self, self.sentence_font,
                    function(opts) return newFlashMenu(self, opts) end,
                    function(font_id)
                        if font_id == self.sentence_font then return end
                        self.sentence_font = font_id
                        saveSentenceAppearance(self.sentence_font, self.sentence_size)
                        -- Keep all existing review/due logic and screen layout.
                        self:_render()
                        self:_refresh()
                        UIManager:close(menu)
                        UIManager:nextTick(function()
                            if UIManager:isWidgetShown(self) then
                                self:showSentenceAppearance()
                            end
                        end)
                    end
                )
                return true
            end
            local changed = false
            local font_changed = false
            if item.sentence_font then
                if not resolveSentenceFont(item.sentence_font) then
                    UIManager:show(newFlashInfo(self, {
                        text = _("Font not found. Copy its .ttf or .otf file to koreader/fonts/ and restart KOReader."),
                        timeout = 4,
                    }))
                    return true
                end
                if self.sentence_font ~= item.sentence_font then
                    self.sentence_font = item.sentence_font
                    changed = true
                    font_changed = true
                end
            elseif item.sentence_delta then
                local target = math.max(SENTENCE_MIN_SIZE,
                    math.min(SENTENCE_MAX_SIZE, self.sentence_size + item.sentence_delta))
                if target ~= self.sentence_size then
                    self.sentence_size = target
                    changed = true
                end
            elseif item.sentence_reset then
                if self.sentence_font ~= SENTENCE_DEFAULT_FONT
                    or self.sentence_size ~= SENTENCE_DEFAULT_SIZE then
                    font_changed = self.sentence_font ~= SENTENCE_DEFAULT_FONT
                    self.sentence_font = SENTENCE_DEFAULT_FONT
                    self.sentence_size = SENTENCE_DEFAULT_SIZE
                    changed = true
                end
            end
            if changed then
                saveSentenceAppearance(self.sentence_font, self.sentence_size)
                self:_render()
                self:_refresh()
                if font_changed then
                    -- Replace the menu so its title, footer and item rows all
                    -- immediately use the newly selected font family.
                    UIManager:close(menu)
                    UIManager:nextTick(function()
                        if UIManager:isWidgetShown(self) then
                            self:showSentenceAppearance()
                        end
                    end)
                    return true
                end
            end
            menu.item_table = populate()
            menu:updateItems(menu.page)
            return true
        end,
    })
    UIManager:show(menu)
    return true
end

function Flashcards:showSavedMeanings()
    if self.busy then return true end
    local card=self.cards and self.cards[self.idx]
    local word=card and card.word
    if card and word==card.word and card.highlight then
        local ok,err=pcall(Flash.saved_meanings.copyFromSelectedForm,
            card.word,card.highlight)
        if not ok then logger.warn('FlipSide saved meaning menu recovery:',err) end
    end
    local current=word and Flash.saved_meanings.get(word)
    local item_table={
        {text='Saved meanings', mandatory=tostring(Flash.saved_meanings.countMeanings())..' definitions / '..tostring(Flash.saved_meanings.count())..' words', saved_info=true},
        {text='Browse current card meanings', mandatory=word and (tostring(Flash.saved_meanings.countForWord(word))..' saved') or 'No card', saved_view=true},
        {text='Add meaning manually', saved_edit=true},
        {text='Delete ALL meanings for current word', saved_delete=true},
        {text='Sync saved meanings now', saved_sync=true},
        {text='Cloud folder (shared with Dictionary)', mandatory=(require('flipside_dictionary_locks').getFolder() or {}).name or 'Dictionary folder', saved_folder=true},
        {text='Back', saved_back=true},
    }
    local menu
    menu=newFlashMenu(self,{title='Saved meanings',item_table=item_table,
        covers_fullscreen=true,is_borderless=true,is_popout=false,
        onMenuSelect=function(_,item)
            if not item then return true end
            UIManager:close(menu)
            if item.saved_back then
                UIManager:nextTick(function() if UIManager:isWidgetShown(self) then self:showSentenceAppearance() end end)
            elseif item.saved_sync then
                local plugin=getPlugin()
                UIManager:nextTick(function()
                    if plugin then require('flipside_sync').start(plugin,'meanings') end
                end)
            elseif item.saved_folder then
                UIManager:nextTick(function()
                    if UIManager:isWidgetShown(self) then self:showSyncComponent('dictionary') end
                end)
            elseif item.saved_view then
                if current then Flash.saved_meanings.showPopup(word,function(on_close) self:lookupWord(true,on_close) end,
                    function() return self._flipside_meaning_frame end)
                else UIManager:show(newFlashInfo(self,{text='No meaning saved for this card.',timeout=3})) end
            elseif item.saved_edit then
                if word then Flash.saved_meanings.edit(word,nil) end
            elseif item.saved_delete then
                if word and current then
                    UIManager:show(ConfirmBox:new{
                        text='Delete ALL saved meanings for '..tostring(word)..'? You can delete one at a time from Browse.',
                        ok_text='Delete',ok_callback=function() Flash.saved_meanings.delete(word) end,
                    })
                end
            elseif item.saved_info then
                UIManager:show(newFlashInfo(self,{text='Open any dictionary, select a definition and tap Save. You can save several meanings per word, even from different dictionaries. Browse groups them by dictionary. During reading, the Popup checkbox is optional.',timeout=5}))
            end
            return true
        end,
    })
    UIManager:show(menu)
    return true
end

-- Sync settings for the existing six cloud stages. Calendar can select its
-- own folder without changing Statistics; no other component is modified.
local SYNC_COMPONENTS = {
    {key = "cards", title = "Flashcards"},
    {key = "cram", title = "CRAM"},
    {key = "audit", title = "Statistics"},
    {key = "calendar", title = "Calendar"},
    {key = "dictionary", title = "Dictionary"},
    {key = "meanings", title = "Saved meanings"},
}

local function syncFolderLabel(kind)
    local plugin = getPlugin()
    local folder
    if kind == "cards" then
        folder = plugin and plugin:getFlipSideSyncServer()
    elseif kind == "cram" then
        folder = plugin and plugin:getFlipSideCramSyncServer()
    elseif kind == "audit" then
        local audit = package.loaded["flipside_learning_audit"]
        if type(audit) == "table" and type(audit.getFolder) == "function" then
            folder = audit.getFolder()
        end
    elseif kind == "calendar" then
        folder = require("flipside_calendar_cloud").getFolder()
        if not folder then
            -- Before a separate folder is chosen, Calendar still uses the
            -- existing Statistics folder so older setups keep working.
            local audit = package.loaded["flipside_learning_audit"]
            if type(audit) == "table" and type(audit.getFolder) == "function" then
                local inherited = audit.getFolder()
                if type(inherited) == "table" and type(inherited.type) == "string"
                        and type(inherited.url) == "string" then
                    return "Statistics: " .. tostring(inherited.name or inherited.type)
                end
            end
        end
    elseif kind == "dictionary" or kind == "meanings" then
        folder = require("flipside_dictionary_locks").getFolder()
    end
    if type(folder) == "table" and type(folder.type) == "string"
            and type(folder.url) == "string" then
        return folder.name or folder.type
    end
    return "Not set"
end

function Flashcards:showSyncSettings()
    if self.busy then return true end
    local menu
    local items = {}
    for _, component in ipairs(SYNC_COMPONENTS) do
        items[#items+1] = {
            text = component.title,
            mandatory = syncFolderLabel(component.key),
            sync_component = component.key,
        }
    end
    items[#items+1] = {text = "Back", sync_back = true}
    menu = newFlashMenu(self, {
        title = "Sync settings", item_table = items,
        covers_fullscreen = true, is_borderless = true, is_popout = false,
        onMenuSelect = function(_, item)
            if not item then return true end
            UIManager:close(menu)
            UIManager:nextTick(function()
                if not UIManager:isWidgetShown(self) then return end
                if item.sync_back then self:showSentenceAppearance()
                elseif item.sync_component then self:showSyncComponent(item.sync_component) end
            end)
            return true
        end,
    })
    UIManager:show(menu)
    return true
end

function Flashcards:showSyncComponent(kind)
    if self.busy then return true end
    local names = {cards = "Flashcards", cram = "CRAM",
        audit = "Statistics", calendar = "Calendar",
        dictionary = "Dictionary", meanings = "Saved meanings"}
    if not names[kind] then return self:showSyncSettings() end
    local menu
    menu = newFlashMenu(self, {
        title = names[kind] .. " sync",
        item_table = {
            {text = "Cloud folder", mandatory = syncFolderLabel(kind), sync_folder = true},
            {text = "Sync now", sync_only = true},
            {text = "Back", sync_back = true},
        },
        covers_fullscreen = true, is_borderless = true, is_popout = false,
        onMenuSelect = function(_, item)
            if not item then return true end
            local plugin = getPlugin()
            local function warn(message)
                UIManager:show(newFlashInfo(self, {text = message, timeout = 4}))
            end
            -- Sync's progress/result messages may be shown above this page.
            -- Keep the component menu underneath instead of dropping the user
            -- back onto the main flashcards when the transfer ends.
            if item.sync_only then
                UIManager:nextTick(function()
                    if plugin then require("flipside_sync").start(plugin, kind)
                    else warn("FlipSide is not available.") end
                end)
                return true
            end
            UIManager:close(menu)
            if item.sync_back then
                UIManager:nextTick(function()
                    if UIManager:isWidgetShown(self) then self:showSyncSettings() end
                end)
                return true
            end
            if item.sync_folder then
                UIManager:nextTick(function()
                    if not UIManager:isWidgetShown(self) then return end
                    if not plugin then warn("FlipSide is not available."); return end
                    local ok, err = pcall(function()
                        local function reopened(success)
                            if not success then warn("No cloud folder saved.") end
                            UIManager:nextTick(function()
                                if UIManager:isWidgetShown(self) then
                                    self:showSyncComponent(kind)
                                end
                            end)
                        end
                        if kind == "dictionary" or kind == "meanings" then
                            local ui = plugin.ui or getUI()
                            return require("flipside_dictionary_locks").chooseFolder(ui,
                                function(success) reopened(success) end)
                        elseif kind == "audit" then
                            local audit = package.loaded["flipside_learning_audit"]
                            if type(audit) ~= "table"
                                    or type(audit.chooseFolder) ~= "function" then
                                error("Learning Analysis is unavailable; check crash.log")
                            end
                            return audit.chooseFolder(plugin,
                                function(success) reopened(success) end)
                        elseif kind == "calendar" then
                            return require("flipside_calendar_cloud").chooseFolder(plugin,
                                function(success) reopened(success) end)
                        end
                        local cs = plugin.ui and plugin.ui.cloudstorage
                        if not cs then
                            local ok_loader, loader = pcall(require, "pluginloader")
                            if ok_loader and loader
                                    and type(loader.getPluginInstance) == "function" then
                                local ok_cs, result = pcall(loader.getPluginInstance,
                                    loader, "cloudstorage")
                                if ok_cs then cs = result end
                            end
                        end
                        if not cs or not cs.onShowCloudStorageList then
                            error("Enable KOReader Cloud storage first")
                        end
                        cs:onShowCloudStorageList(function(server)
                            local saved = false
                            if kind == "cards" then
                                saved = plugin:setFlipSideSyncServer(server)
                            elseif kind == "cram" then
                                saved = plugin:setFlipSideCramSyncServer(server)
                            end
                            reopened(saved)
                        end)
                    end)
                    if not ok then warn("Cloud folder: " .. tostring(err)) end
                end)
            end
            return true
        end,
    })
    UIManager:show(menu)
    return true
end

---------------------------------------------------------------- retrieval strategy settings

-- UI text is English by design. No new top-level global menu or gesture hook.
-- The card style changes ONLY borders and review buttons. No text styling.
function Flashcards:showCardStyles()
    if self.busy then return true end
    local menu
    local function populate()
        local items = {}
        for _, option in ipairs(Flash.CARD_STYLES) do
            items[#items+1] = {
                text = (self.card_style == option.id and "●  " or "○  ") .. option.label,
                visual_style_id = option.id,
                bold = self.card_style == option.id,
            }
        end
        items[#items+1] = {text="Done", visual_style_done=true, bold=true}
        return items
    end
    menu = newFlashMenu(self, {
        title = "Card styles", item_table = populate(),
        covers_fullscreen = true, is_borderless = true, is_popout = false,
        onMenuSelect = function(_, item)
            if not item then return true end
            if item.visual_style_done then
                UIManager:close(menu)
                UIManager:nextTick(function()
                    if UIManager:isWidgetShown(self) then self:showSentenceAppearance() end
                end)
                return true
            end
            if item.visual_style_id then
                if self.card_style ~= item.visual_style_id then
                    self.card_style = item.visual_style_id
                    G_reader_settings:saveSetting(Flash.CARD_STYLE_SETTING, self.card_style)
                    G_reader_settings:flush()
                    self:_render()
                    self:_refresh()
                end
                menu.item_table = populate()
                menu:updateItems(menu.page)
                return true
            end
        end,
    })
    UIManager:show(menu)
    return true
end

function Flashcards:showReviewStrategy()
    if self.busy then return true end
    local menu
    local function populate()
        local items = {}
        for _, strategy in ipairs(DUAL_STRATEGY_ORDER) do
            items[#items + 1] = {
                text = (self.dual_strategy == strategy and "●  " or "○  ")
                    .. DUAL_STRATEGIES[strategy],
                dual_strategy = strategy,
                bold = self.dual_strategy == strategy,
            }
        end
        items[#items + 1] = {
            text = "Retrieval statistics",
            dual_stats = true,
        }
        items[#items + 1] = {
            text = "About Adaptive Dual Retrieval",
            dual_help = true,
        }
        items[#items + 1] = { text = "Done", dual_done = true, bold = true }
        return items
    end
    menu = newFlashMenu(self, {
        title = "Review strategy",
        item_table = populate(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(_menu, item)
            if not item then return true end
            if item.dual_done then
                UIManager:close(menu)
                self:_refresh()
                return true
            end
            if item.dual_stats then
                local words = loadDualStats()
                local mt, mc, ct, cc, count = 0, 0, 0, 0, 0
                for _, entry in pairs(words) do
                    if type(entry) == "table" then
                        count = count + 1
                        mt = mt + (tonumber(entry.meaning_total) or 0)
                        mc = mc + (tonumber(entry.meaning_correct) or 0)
                        ct = ct + (tonumber(entry.context_total) or 0)
                        cc = cc + (tonumber(entry.context_correct) or 0)
                    end
                end
                local current = self.cards and self.cards[self.idx]
                local current_data = current and words[current.word]
                local message = T("Tracked words: %1\nMeaning Recall: %2/%3\nContextual Retrieval: %4/%5",
                    count, mc, mt, cc, ct)
                if current and current_data then
                    message = message .. "\n\n" .. current.word .. "\n"
                        .. T("Meaning Recall: %1/%2\nContextual Retrieval: %3/%4",
                            tonumber(current_data.meaning_correct) or 0,
                            tonumber(current_data.meaning_total) or 0,
                            tonumber(current_data.context_correct) or 0,
                            tonumber(current_data.context_total) or 0)
                end
                UIManager:show(newFlashInfo(self, { text = message }))
                return true
            end
            if item.dual_help then
                UIManager:show(newFlashInfo(self, {
                    text = "Meaning Recall: remember the English word's meaning without clues and rate Forgot / Got it.\n\nContextual Retrieval: a single tap swaps the blank in the sentence for [the revealed word], or hides it again. A double tap shows or hides the full saved context; a long press while revealed opens the dictionary. Rate Did not recall / Recalled it after revealing. The card finishes immediately.\n\nSentence Card: read the saved sentence with [word] already visible, then rate Forgot / Got it. The outcome is tracked separately in Learning Analysis and is included in All models.\n\nAdaptive: two successful scheduled Meaning Recall reviews unlock the first contextual review. After that, one, two or three successful meaning reviews may be needed, based on the last six recorded results in each mode (minimum three samples per mode for difficulty adjustments). A forgotten meaning resets that progress. Earlier native KOReader streaks are not counted.\n\nAll modes keep KOReader's original spaced-repetition schedule. Each real review writes exactly one answer. Practice and immediate missed-card reinforcement never change due dates.",
                }))
                return true
            end
            if item.dual_strategy and item.dual_strategy ~= self.dual_strategy then
                -- Selecting Sentence Card only starts with Sentence Card on
                -- *every* word, even if earlier manual switches chose Meaning
                -- or Contextual. Keep the old per-card choices for other
                -- strategies, and clear only overrides specific to this mode.
                if item.dual_strategy == "sentence" then
                    self.sentence_card_modes = {}
                    G_reader_settings:saveSetting(DUAL_SENTENCE_CARD_MODES_KEY, {})
                end
                self.dual_strategy = item.dual_strategy
                saveDualStrategy(self.dual_strategy)
                self:_resetDualCard()
                self.show_ctx = false
                self.show_more_ctx = false
                self:_render()
                self:_refresh()
            end
            menu.item_table = populate()
            menu:updateItems(menu.page)
            return true
        end,
    })
    UIManager:show(menu)
    return true
end

-- Edit only the human-readable parts of a saved card. `word` is the SRS
-- identifier across the native Vocabulary database, audit and CRAM stores;
-- renaming it from Search would orphan its review history. The SQL below
-- never touches word, review_count, streak_count or due/review timestamps.
function Flashcards:_saveSearchCardContent(word, changes)
    local SQ3 = require("lua-ljsqlite3/init")
    local path = DataStorage:getSettingsDir() .. "/flipside/vocabulary_builder.sqlite3"
    local conn = SQ3.open(path)
    local ok, err = pcall(function()
        conn:exec("BEGIN IMMEDIATE;")
        local check = conn:prepare("SELECT word FROM vocabulary WHERE word = ?;")
        check:bind(word)
        local found = check:step()
        check:close()
        if not found then error("This card no longer exists.", 0) end

        if changes.book ~= nil then
            -- Changing the association does not rename the book for other words.
            local add = conn:prepare("INSERT OR IGNORE INTO title (name) VALUES (?);")
            add:bind(changes.book)
            add:step()
            add:close()
            local update = conn:prepare([[UPDATE vocabulary
                SET title_id = (SELECT id FROM title WHERE name = ?)
                WHERE word = ?;]])
            update:bind(changes.book, word)
            update:step()
            update:close()
        end
        if changes.context then
            local update = conn:prepare([[UPDATE vocabulary
                SET prev_context = ?, next_context = ? WHERE word = ?;]])
            update:bind(changes.context.prev, changes.context.next, word)
            update:step()
            update:close()
        end
        conn:exec("COMMIT;")
    end)
    if not ok then pcall(conn.exec, conn, "ROLLBACK;") end
    conn:close()
    return ok, err
end

-- Keep the already loaded review card in sync without rebuilding its queue.
function Flashcards:_updateSearchCardInMemory(card)
    for _, live in ipairs(self.cards or {}) do
        if live.word == card.word then
            live.book = card.book
            live.prev = card.prev
            live.next = card.next
        end
    end
end

-- Show the word in a unique bracketed slot while editing. The identity of the
-- word is fixed, but both sides of its saved sentence can be freely rewritten.
-- The marker prevents accidental loss/duplication of the studied word.
function Flashcards:_splitSearchEditedContext(input, word)
    local marker = "[[" .. word .. "]]"
    local from, to = input:find(marker, 1, true)
    if not from or input:find(marker, to + 1, true) then
        return nil, nil, "Keep exactly one " .. marker .. " marker in the text."
    end
    local before = input:sub(1, from - 1):gsub("%s+$", "")
    local after = input:sub(to + 1):gsub("^%s+", "")
    return before ~= "" and before or nil, after ~= "" and after or nil
end

---------------------------------------------------------------- word search

-- FlipSide has no public list view. The stock Vocabulary Builder search
-- changes only its hidden backing list, which is why the original Search
-- button appeared to return nothing. Keep search completely separate from
-- the due queue, the native SRS state and the current in-progress flashcard.
function Flashcards:_showWordSearchResults(query)
    local ok, catalog = pcall(readFullCatalog)
    if not ok or type(catalog) ~= "table" then
        logger.warn("FlipSide search: cannot read vocabulary:", catalog)
        UIManager:show(newFlashInfo(self, {
            text = _("Could not search saved words. Check the KOReader log."),
            timeout = 5,
        }))
        return true
    end

    local needle = query:lower()
    local matches = {}
    for _, card in ipairs(catalog) do
        local word = card.word
        if type(word) == "string" and word:lower():find(needle, 1, true) then
            matches[#matches + 1] = card
        end
    end
    -- Most useful results appear first. Match words literally; treating
    -- underscores or percent signs as SQL wildcards made searches ambiguous.
    table.sort(matches, function(a, b)
        local aw, bw = a.word:lower(), b.word:lower()
        local function score(w)
            if w == needle then return 0 end
            if w:sub(1, #needle) == needle then return 1 end
            return 2
        end
        local as, bs = score(aw), score(bw)
        if as ~= bs then return as < bs end
        if aw ~= bw then return aw < bw end
        return a.word < b.word
    end)

    if #matches == 0 then
        UIManager:show(newFlashInfo(self, {
            text = _("No saved words found for:") .. " " .. query,
            timeout = 5,
        }))
        return true
    end

    local items = {}
    for _, card in ipairs(matches) do
        items[#items + 1] = {
            text = card.word,
            mandatory = card.book or "",
            search_card = card,
        }
    end
    local menu
    menu = newFlashMenu(self, {
        title = _("Search results") .. " (" .. tostring(#matches) .. ")",
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(_menu, item)
            local card = item and item.search_card
            if not card then return true end
            local viewer
            local function showDetails()
                local context = {}
                if type(card.prev) == "string" and card.prev ~= "" then
                    context[#context + 1] = card.prev
                end
                -- The saved dictionary key always remains unchanged by edits.
                local shown = type(card.highlight) == "string" and card.highlight ~= ""
                    and card.highlight or card.word
                context[#context + 1] = shown
                if type(card.next) == "string" and card.next ~= "" then
                    context[#context + 1] = card.next
                end
                local body = card.book and card.book ~= "" and
                    (_("Book") .. ": " .. card.book .. "\n\n") or ""
                body = body .. table.concat(context, " ")
                viewer = TextViewer:new{
                    title = card.word,
                    text = body,
                    show_menu = false,
                    buttons_table = {{
                        {
                            text = _("Dictionary"),
                            callback = function()
                                local ui = getUI()
                                if ui then
                                    ui:handleEvent(Event:new("LookupWord", card.word))
                                else
                                    UIManager:show(newFlashInfo(self, {
                                        text = _("Dictionary is unavailable."),
                                        timeout = 3,
                                    }))
                                end
                            end,
                        },
                        {
                            text = _("Edit card"),
                            callback = function()
                                local editor_menu
                                local function afterSave()
                                    self:_updateSearchCardInMemory(card)
                                    -- Update the search result's book subtitle too.
                                    item.mandatory = card.book or ""
                                    UIManager:close(viewer)
                                    if menu and type(menu.updateItems) == "function" then
                                        menu:updateItems(menu.page)
                                    end
                                    UIManager:nextTick(function()
                                        if not self._closing and not self._sleep_paused
                                                and not Device.screen_saver_mode then
                                            showDetails()
                                        end
                                    end)
                                end
                                editor_menu = newFlashMenu(self, {
                                    title = _("Edit card") .. ": " .. card.word,
                                    item_table = {
                                        { text = _("Edit context"), edit_field = "context" },
                                        { text = _("Change book"), edit_field = "book" },
                                    },
                                    onMenuSelect = function(_editor, edit_item)
                                        if not edit_item then return true end
                                        UIManager:close(editor_menu)
                                        if edit_item.edit_field == "context" then
                                            local shown = type(card.highlight) == "string" and card.highlight ~= ""
                                                and card.highlight or card.word
                                            local parts = {}
                                            if card.prev and card.prev ~= "" then
                                                parts[#parts + 1] = card.prev
                                            end
                                            parts[#parts + 1] = "[[" .. shown .. "]]"
                                            if card.next and card.next ~= "" then
                                                parts[#parts + 1] = card.next
                                            end
                                            local edit_dialog
                                            edit_dialog = InputDialog:new{
                                                title = _("Edit context") .. ": " .. card.word,
                                                description = _("Keep [[word]] around the studied word."),
                                                input = table.concat(parts, " "),
                                                fullscreen = true,
                                                condensed = true,
                                                allow_newline = true,
                                                add_scroll_buttons = true,
                                                buttons = {{
                                                    { text = _("Cancel"), id = "close",
                                                      callback = function() UIManager:close(edit_dialog) end },
                                                    { text = _("Save"), callback = function()
                                                        local changed = edit_dialog:getInputText() or ""
                                                        local before, after, invalid = self:_splitSearchEditedContext(changed, shown)
                                                        if invalid then
                                                            UIManager:show(newFlashInfo(self, {text = invalid, timeout = 5}))
                                                            return
                                                        end
                                                        local ok, err = self:_saveSearchCardContent(card.word,
                                                            { context = {prev = before, next = after} })
                                                        if not ok then
                                                            logger.warn("FlipSide Edit card: context write failed:", err)
                                                            UIManager:show(newFlashInfo(self, {
                                                                text = _("Could not save the card:") .. " " .. tostring(err),
                                                                timeout = 5,
                                                            }))
                                                            return
                                                        end
                                                        card.prev, card.next = before, after
                                                        UIManager:close(edit_dialog)
                                                        afterSave()
                                                    end },
                                                }},
                                            }
                                            UIManager:show(edit_dialog)
                                            edit_dialog:onShowKeyboard()
                                        elseif edit_item.edit_field == "book" then
                                            local edit_dialog
                                            edit_dialog = InputDialog:new{
                                                title = _("Change book") .. ": " .. card.word,
                                                input = card.book or "",
                                                input_hint = _("Book title"),
                                                buttons = {{
                                                    { text = _("Cancel"), id = "close",
                                                      callback = function() UIManager:close(edit_dialog) end },
                                                    { text = _("Save"), is_enter_default = true,
                                                      callback = function()
                                                        local book = (edit_dialog:getInputText() or "")
                                                            :match("^%s*(.-)%s*$") or ""
                                                        if book == "" then
                                                            UIManager:show(newFlashInfo(self, {
                                                                text = _("Please enter a book title."), timeout = 4,
                                                            }))
                                                            return
                                                        end
                                                        local ok, err = self:_saveSearchCardContent(card.word, {book = book})
                                                        if not ok then
                                                            logger.warn("FlipSide Edit card: book write failed:", err)
                                                            UIManager:show(newFlashInfo(self, {
                                                                text = _("Could not save the card:") .. " " .. tostring(err),
                                                                timeout = 5,
                                                            }))
                                                            return
                                                        end
                                                        card.book = book
                                                        UIManager:close(edit_dialog)
                                                        afterSave()
                                                    end },
                                                }},
                                            }
                                            UIManager:show(edit_dialog)
                                            edit_dialog:onShowKeyboard()
                                        end
                                        return true
                                    end,
                                })
                                UIManager:show(editor_menu)
                            end,
                        },
                        {
                            text = _("Close"),
                            callback = function() UIManager:close(viewer) end,
                        },
                    }},
                }
                UIManager:show(viewer)
            end
            showDetails()
            return true
        end,
    })
    UIManager:show(menu)
    return true
end

function Flashcards:showWordSearch()
    if self._closing or self._sleep_paused or Device.screen_saver_mode then
        return false
    end
    self:_clockPause()
    local dialog
    dialog = InputDialog:new{
        title = _("Search words"),
        input = self._search_query or "",
        input_hint = _("Enter a saved word"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local entered = dialog:getInputText() or ""
                    local query = entered:match("^%s*(.-)%s*$") or ""
                    UIManager:close(dialog)
                    if query == "" then return end
                    self._search_query = query
                    UIManager:nextTick(function()
                        if not self._closing and not self._sleep_paused
                                and not Device.screen_saver_mode
                                and UIManager:isWidgetShown(self) then
                            self:_showWordSearchResults(query)
                        end
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

---------------------------------------------------------------- dictionary

-- Same as tapping the word in the list view.
function Flashcards:lookupWord(force_dictionary, dictionary_close_callback)
    if self.state ~= "card" or not self.lookup_func then
        return true
    end
    self:_clockPause()
    local card = self.cards[self.idx]
    if card and card.highlight then
        local ok,err=pcall(Flash.saved_meanings.copyFromSelectedForm,
            card.word,card.highlight)
        if not ok then logger.warn('FlipSide saved meaning card recovery:',err) end
    end
    if not force_dictionary and Flash.saved_meanings.get(card.word) then
        return Flash.saved_meanings.showPopup(card.word, function(on_close)
            self:lookupWord(true, on_close)
        end, function() return self._flipside_meaning_frame end)
    end
    -- Idempotent fallback for KOReader builds where the owning plugin's
    -- init ran before ReaderDictionary was available. Do not register during
    -- DictQuickLookup:init, when its button pool is already being assembled.
    local reader = getUI()
    if reader and reader.dictionary then
        Flash.saved_meanings.registerDictionaryButton(reader.dictionary)
    end
    Flash.saved_meanings.arm(card.word)
    local on_close
    if type(dictionary_close_callback) == "function" then
        -- Only the Meaning options -> Dictionary path requests a return.
        -- If the card was closed or changed meanwhile, do not resurrect it.
        local opening_card = card
        on_close = function()
            if self.state == "card" and not self._closing
                    and UIManager:isWidgetShown(self)
                    and self.cards[self.idx] == opening_card then
                dictionary_close_callback()
            end
        end
    end
    local ok, done = pcall(self.lookup_func, card, on_close)
    if not ok or not done then
        Flash.saved_meanings.disarm()
        logger.warn("vocab flashcards: dictionary lookup failed:", ok and "no handler" or done)
        UIManager:show(newFlashInfo(self, {
            text = _("Could not open the dictionary for this word."),
            timeout = 4,
        }))
    end
    return true
end

-- Contextual cards use the same sentence in both phases: a normal tap
-- replaces the blank with [word] and back again. Word-only Meaning Recall
-- retains its direct dictionary hotspot; contextual dictionary lookup is
-- available by long press once the answer has been revealed.
-- Header and answer buttons retain their own gesture handling.
function Flashcards:onTapCard(_arg, ges)
    -- Exit is reserved for a LONG press, not an accidental single tap.
    -- Still swallow simple taps in that corner rather than revealing context.
    if self.immersive and ges and ges.pos and self.immersion_exit_rect
            and ges.pos:intersectWith(self.immersion_exit_rect) then
        return true
    end
    if self.state ~= "card" or self.busy or not ges or not ges.pos then
        return false
    end
    self:_clockTouch()
    -- Normally the native Button consumes its own touch event. This is also
    -- a fallback when a device routes its fullscreen card tap handler first.
    local button = self.mode_toggle_button
    if button and button.dimen and button.dimen.x and button.dimen.y
            and ges.pos:intersectWith(button.dimen) then
        return self:toggleManualRetrievalMode()
    end
    local accuracy = self.accuracy_button
    if accuracy and accuracy.dimen and accuracy.dimen.x and accuracy.dimen.y
            and ges.pos:intersectWith(accuracy.dimen) then
        return self:openReviewAccuracy()
    end
    local advance = self.advance_today_button
    if advance and advance.dimen and advance.dimen.x and advance.dimen.y
            and ges.pos:intersectWith(advance.dimen) then
        return self:showAdvanceTodayMenu()
    end
    local frames = self.style_cycle_button
    if not self.immersive and frames and frames.dimen
            and frames.dimen.x and frames.dimen.y
            and ges.pos:intersectWith(frames.dimen) then
        return self:cycleCardStyle()
    end
    if not self.card_rect or ges.pos:notIntersectWith(self.card_rect) then
        return false
    end
    local hit = self.word_rect
    if self.cropping_widget and self._card_word_widget
            and self._card_word_widget.dimen
            and self._card_word_widget.dimen.x then
        local live = self._card_word_widget.dimen
        local viewport = self.cropping_widget.dimen
        if viewport and viewport.x and viewport.y
                and self.word_rect then
            local top = math.max(viewport.y, live.y - Size.padding.large)
            local bottom = math.min(viewport.y + viewport.h,
                live.y + live.h + Size.padding.large)
            if bottom > top then
                hit = Geom:new{
                    x = self.word_rect.x, y = top,
                    w = self.word_rect.w, h = bottom - top,
                }
            else
                hit = nil
            end
        else
            hit = nil
        end
    end
    if hit and ges.pos:intersectWith(hit) then
        return self:lookupWord()
    end
    return self:toggleContext()
end

-- Since the contextual answer now remains embedded in its sentence, its
-- inline glyph position changes with word wrapping and font selection. Use
-- a deliberate long press for dictionary lookup rather than a fragile
-- guessed hitbox over the bracketed substring. Ordinary taps keep toggling
-- the in-place answer, with no accidental dictionary pop-ups.
function Flashcards:onHoldCard(_arg, ges)
    if self.immersive and ges and ges.pos and self.immersion_exit_rect
            and ges.pos:intersectWith(self.immersion_exit_rect) then
        return self:setImmersion(false)
    end
    if self.state ~= "card" or self.busy
            or (self.dual_phase ~= "revealed" and self.dual_phase ~= "sentence")
            or not ges or not ges.pos or not self.card_rect
            or ges.pos:notIntersectWith(self.card_rect) then
        return false
    end
    self:_clockTouch()
    return self:lookupWord()
end

-- A double tap on the card reveals/hides saved context in ALL models.
-- KOReader defers a single tap while double-tap detection is enabled, so a
-- double tap on the Meaning Recall word must NOT open the dictionary.
-- A single tap on that word still uses the native dictionary hotspot.
function Flashcards:onDoubleTapCard(_arg, ges)
    if self.immersive and ges and ges.pos and self.immersion_exit_rect
            and ges.pos:intersectWith(self.immersion_exit_rect) then
        return true
    end
    if self.state ~= "card" or self.busy or not ges or not ges.pos then
        return false
    end
    self:_clockTouch()
    -- Original v0.1.0 behavior: show/hide the recorded full context.
    -- One deliberate deviation: a double tap on the MRO headword must
    -- also expand context, as explicitly requested for every model.
    return self:toggleSurrounding()
end

-- Two distinct regions for two distinct horizontal swipe actions.
function Flashcards:onSwipeCards(_arg, ges)
    if not ges or not ges.pos then return false end
    self:_clockTouch()
    local pos = ges.start_pos
    if not pos or type(pos.intersectWith) ~= "function" then pos = ges.pos end

    -- Full e-ink flash: one downward swipe that starts in the TOP-RIGHT
    -- corner (rightmost quarter; top 40% of the screen).
    -- Only request the hardware refresh; do not re-render or advance cards.
    -- A dialog/menu on top must not trigger a refresh of the underlying card.
    if ges.direction == "south" then
        local width, height = Screen:getWidth(), Screen:getHeight()
        local refresh_corner = Geom:new{
            x = math.floor(width * 0.75),
            y = 0,
            w = width - math.floor(width * 0.75),
            h = math.floor(height * 0.40),
        }
        if pos:intersectWith(refresh_corner)
                and not self._sleep_paused and not Device.screen_saver_mode
                and UIManager:isWidgetShown(self)
                and UIManager:getTopmostVisibleWidget() == self then
            UIManager:setDirty(nil, "full")
            return true
        end
        return false
    end

    if self.busy then return false end
    if ges.direction ~= "west" and ges.direction ~= "east" then return false end
    local direction = ges.direction == "west" and 1 or -1
    if self.filter_rect and pos:intersectWith(self.filter_rect) then
        return self:stepFilter(direction)
    end
    if self.state == "card" and self.card_rect and pos:intersectWith(self.card_rect) then
        return self:stepCard(direction)
    end
    -- Left-to-right also opens answered cards from the finished screen.
    if self.state == "done" and direction < 0 then
        return self:inspectPrevious()
    end
    return false
end

---------------------------------------------------------------- reloading

-- Rebuild the deck from the database, respecting selected and active groups.
function Flashcards:reloadDeck()
    if not self.reload_func then
        return false
    end
    local ok, deck = pcall(self.reload_func)
    if not ok or type(deck) ~= "table" then
        logger.warn("vocab flashcards: could not reload the deck:", deck)
        return false
    end
    if self.training and not self:_persistIntensiveProgress() then return false end
    self:_pauseIntensiveAttempt()
    self:_persistIntensiveProgress()
    self.all_cards = deck
    self._inspection_cursor, self._inspection_resume = nil, nil
    self:_resetDualCard()
    -- A real zero-due book stays selected. A deleted/renamed title does not.
    self:_validateFilter()
    self.cards = self:_buildView()
    self.idx = 1
    self.history = {}
    self._browse_back = {}
    self.retry_round = false
    self.retry_total = 0
    self.retry_seen = 0
    self.retry_got = 0
    self.retry_forgot = 0
    self:_initializeIntensive()
    self.show_ctx = false
    self.show_more_ctx = false
    self.busy = false
    self.state = (#self.cards == 0) and "empty" or "card"
    self:_render()
    self:_refresh()
    self:_armDueWatch()
    self:_offerCramResetForEmptyDeck()
    return true
end

-- "Reload" button of the empty screen.
function Flashcards:reloadNow()
    if self.busy then
        return true
    end
    self.busy = true
    local loading = newFlashInfo(self, { text = _("Preparing flashcards...") })
    UIManager:show(loading)
    UIManager:forceRePaint()
    self:reloadDeck()
    UIManager:close(loading)
    self.busy = false
    self:_refresh()
    return true
end

-- The list was reloaded by something else (menu filter, reverse order, reset,
-- clean, cloud sync...): rebuild the flashcards from it.
function Flashcards:onListChanged()
    self._external_list_changed = true
    if self._reload_pending then return end
    self._reload_pending = true
    UIManager:nextTick(function()
        self._reload_pending = false
        if not UIManager:isWidgetShown(self) or self.busy or self._sleep_paused
                or Device.screen_saver_mode then return end
        -- A list reload can happen *after* a review was committed, e.g.
        -- when native bookkeeping, a cloud sync, or a menu updates its items.
        -- Replacing cards[] here destroyed the in-progress cloze and Undo
        -- history and looked as if the card had collapsed to its word face.
        -- Only an idle, empty, history-free view is safe to auto-rebuild.
        if self.state == "empty" and #self.history == 0
                and not self._inspection_cursor then
            self._external_list_changed = false
            self:reloadDeck()
        end
        -- During a review the DB is still authoritative at the next answer.
        -- Explicit Reload or leaving/reopening applies a changed list.
    end)
end

-- On Kindle, Resume can be broadcast *before* the KOReader screensaver
-- closes. Moreover OutOfScreenSaver is broadcast before Screensaver:cleanup()
-- clears Device.screen_saver_mode. Never draw from either event immediately.
-- Recover only once the real flashcard widget is again in the foreground.
function Flashcards:_recoverSoon()
    if self._closing or self._sleep_paused or Device.screen_saver_mode
            or self._recover_action then
        if self._sleep_paused or Device.screen_saver_mode then
            Diag.event("sleep", "recover_deferred", {status="saver"})
        end
        return
    end
    local action
    action = function()
        if self._recover_action ~= action then return end
        self._recover_action = nil
        if self._closing or self._sleep_paused or Device.screen_saver_mode
                or not UIManager:isWidgetShown(self) or self.busy
                or UIManager:getTopmostVisibleWidget() ~= self then
            if self._sleep_paused or Device.screen_saver_mode then
                SleepTrace.blocked("recover_callback", UIManager, Device, self)
            end
            return
        end
        SleepTrace.transition("foreground_repaint", UIManager, Device, self)
        local stale = self.state == "empty"
        if not stale and self.list_check then
            local ok, alive = pcall(self.list_check)
            stale = not ok or not alive
        end
        if stale and self.state ~= "card" and #self.history == 0
                and self:reloadDeck() then
            return
        end
        -- A Kindle wake is already repainted by KOReader's own screensaver
        -- and device code. Do NOT queue a second full refresh or rerender
        -- the card: either can cause the visible post-sleep flash/overlay.
        -- The present card, answer phase, due queue and Undo stay unchanged.
        if self._cram_save_warning_pending then
            self._cram_save_warning_pending = nil
            UIManager:show(newFlashInfo(self, {
                text = "CRAM PROGRESS NOT SAVED. Check free storage. "
                    .. "Keep KOReader open and back up your settings.",
                timeout = 8,
            }))
        end
    end
    self._recover_action = action
    UIManager:scheduleIn(0.5, action)
end

function Flashcards:_resumeAfterSleepSoon()
    if self._closing or self._resume_action then return end
    local action
    action = function()
        if self._resume_action ~= action then return end
        self._resume_action = nil
        -- The cover may still be displayed under a delayed lock or gesture.
        -- OutOfScreenSaver triggers us again when it actually closes; avoid
        -- polling during suspension or painting under the cover.
        if self._closing or Device.screen_saver_mode
                or not UIManager:isWidgetShown(self) then
            if Device.screen_saver_mode then
                SleepTrace.transition("resume_waiting_for_cover", UIManager, Device, self)
            end
            return
        end
        SleepTrace.transition("cover_closed", UIManager, Device, self)
        self._sleep_paused = false
        SleepTrace.watch(false)
        self:_clockTouch()
        self._clock_last, self._clock_last_mode = nil, nil
        self:_armReviewClock()
        self:_armDueWatch(1)
        if UIManager:getTopmostVisibleWidget() == self then
            self:_recoverSoon()
        end
    end
    self._resume_action = action
    UIManager:scheduleIn(0.35, action)
end

function Flashcards:onSuspend()
    -- One checkpoint before suspension. Never write study data from tracing.
    SleepTrace.watch(true)
    SleepTrace.transition("suspend", UIManager, Device, self)
    self:_pauseForSleep()
    self:_persistIntensiveProgress()
    SleepTrace.transition("paused", UIManager, Device, self)
end

function Flashcards:onResume()
    -- Kindle may announce Resume while the cover is still visible.
    SleepTrace.transition("resume_signal", UIManager, Device, self)
    self:_resumeAfterSleepSoon()
end

function Flashcards:onOutOfScreenSaver()
    SleepTrace.transition("out_of_saver_signal", UIManager, Device, self)
    self:_resumeAfterSleepSoon()
end

---------------------------------------------------------------- menu

-- The header shortcut uses the Learning Audit pop-up. The audit module owns
-- all SQL and caching; Flashcards never makes a second copy of its statistics.
local function showAccuracyFromFlashcards()
    local audit = package.loaded["flipside_learning_audit_bridge"]
    if type(audit) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = "Review accuracy is not available. Check the Learning Audit patch.",
            timeout = 4,
        })
        return false
    end
    -- Open the SAME original statistics popup on the first graph tap, but
    -- use the graph-only model label. Retain a compatibility fallback for
    -- older Learning Audit installs.
    local show = audit.showFlashcardsReviewAccuracy or audit.showReviewAccuracy
    if type(show) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = "Review accuracy is not available. Check the Learning Audit patch.",
            timeout = 4,
        })
        return false
    end
    local ok, result = pcall(show)
    if not ok or result == false then
        logger.warn("vocab flashcards: Review accuracy could not open:", result)
        UIManager:show(InfoMessage:new{
            text = "Review accuracy could not open. Check crash.log.",
            timeout = 4,
        })
        return false
    end
    return true
end

-- One tap in the header opens the original cached Review accuracy dialog.
-- Defer its construction until after the header button's touch event.
function Flashcards:openReviewSchedule()
    self:_clockPause()
    UIManager:nextTick(function()
        if not UIManager:isWidgetShown(self) or self._closing then return end
        local audit = package.loaded["flipside_learning_audit_bridge"]
        if type(audit) == "table" and type(audit.showReviewSchedule) == "function" then
            local ok, result = pcall(audit.showReviewSchedule)
            if ok and result ~= false then return end
            logger.warn("vocab flashcards: schedule shortcut failed:", result)
        end
        UIManager:show(newFlashInfo(self, {
            text="Review schedule is unavailable. Check the Learning Audit patch.",
            timeout=4,
        }))
    end)
    return true
end

-- Direct SRS calendar shortcut, reachable in both Due and Practice modes.
-- It pauses the review-only timer exactly as the statistics button does.
function Flashcards:openStudyCalendar()
    if self._calendar_open_pending then return true end
    self:_clockPause()
    self._calendar_open_pending = true
    UIManager:nextTick(function()
        self._calendar_open_pending = false
        if not UIManager:isWidgetShown(self) or self._closing then return end
        local audit = package.loaded["flipside_learning_audit_bridge"]
        if type(audit) == "table" and type(audit.showStudyCalendar) == "function" then
            local ok, result = pcall(audit.showStudyCalendar)
            if ok and result ~= false then return end
            logger.warn("vocab flashcards: SRS calendar could not open:", result)
        end
        UIManager:show(newFlashInfo(self, {
            text = "Study calendar is unavailable. Check the Learning Audit patch and crash.log.",
            timeout = 5,
        }))
    end)
    return true
end

function Flashcards:openReviewAccuracy()
    if self._accuracy_open_pending then return true end
    self:_clockPause()
    self._accuracy_open_pending = true
    UIManager:nextTick(function()
        self._accuracy_open_pending = false
        if UIManager:isWidgetShown(self) and not self._closing then
            showAccuracyFromFlashcards()
        end
    end)
    return true
end

-- Restore the ORIGINAL native hamburger menu. It remains responsible for
-- Vocabulary Builder settings, editing and its List view entry.
function Flashcards:showMenu()
    self:_clockPause()
    if self.menu_func then
        Flash.menu_for = self
        local flash = self
        UIManager:scheduleIn(2, function()
            if Flash.menu_for == flash then
                Flash.menu_for = nil
            end
        end)
        local ok, shown = pcall(self.menu_func)
        if ok and shown then
            return true
        end
        Flash.menu_for = nil
        logger.warn("vocab flashcards: could not open the list menu:", ok and "no menu found" or shown)
    end

    UIManager:show(newFlashInfo(self, {
        text = "FlipSide menu unavailable. Close and reopen FlipSide.",
        timeout = 4,
    }))
    return true
end

function Flashcards:onClose()
    if self.immersive and not self._closing then
        return self:setImmersion(false)
    end
    if self._sleep_paused or Device.screen_saver_mode then
        SleepTrace.transition("close_while_suspended", UIManager, Device, self)
    end
    self:_persistIntensiveProgress()
    self:_cancelWakeTasks()
    if self._today_dialog and UIManager:isWidgetShown(self._today_dialog) then
        UIManager:close(self._today_dialog)
        self._today_dialog = nil
    end
    if self._intensive_dialog and UIManager:isWidgetShown(self._intensive_dialog) then
        UIManager:close(self._intensive_dialog)
        self._intensive_dialog = nil
    end
    G_reader_settings:flush() -- only independent training counters
    self:_clockPulse(true)
    self:_stopReviewClock()
    self._closing = true
    self:_stopDueWatch()
    UIManager:close(self)
    if self.touched then
        self:_flush()
    end
    if self.on_close then
        self.on_close(self.touched)
    end
    return true
end

---------------------------------------------------------------- session control

-- w: the Vocabulary builder list window.
-- list_is_shown: true when that window is currently on screen (below us).
-- Returns true when the flashcards were opened.
function Flash.start(w, list_is_shown, auto_opened)
    if flashShown() then
        return true
    end
    -- Repair any statistics Undo that was interrupted after the native SRS
    -- rollback; this is idempotent and never changes review due dates.
    replayPendingUndoStatistics()
    -- Never start in place of a list which has not been registered as a
    -- window: KOReader's plugin stores that widget as self.widget and later
    -- expects its CloseWidget/onClose lifecycle when returning to the reader.
    if type(w) ~= "table" or not UIManager:isWidgetShown(w) then
        logger.warn("vocab flashcards: refusing to start without a live native list")
        return false
    end

    local ctx = { list = w }
    watchList(w)

    local loading = newFlashInfo(nil, { text = _("Preparing flashcards...") })
    UIManager:show(loading)
    UIManager:forceRePaint()
    local ok, deck, err = pcall(acquireDeck, ctx)
    UIManager:close(loading)

    if not ok or type(deck) ~= "table" then
        logger.warn("vocab flashcards: could not read the word list:", ok and err or deck)
        UIManager:nextTick(function()
            UIManager:show(newFlashInfo(nil, {
                text = _("FlipSide could not load the cards. Check the KOReader log."),
                timeout = 5,
            }))
        end)
        return false
    end

    local function useFresh(fresh)
        if type(fresh) == "table" and fresh ~= ctx.list then
            ctx.list = fresh
            watchList(fresh)
        end
    end

    local flash = Flashcards:new{
        cards = deck,
        menu_list = ctx.list,
        answer_func = function(card, got)
            local done, e = answerCard(ctx.list, card, got)
            if done then
                return true
            end
            if e == NOT_FOUND then
                -- the list was rebuilt behind us: get the live one and retry
                useFresh(liveList(ctx.list))
                return answerCard(ctx.list, card, got)
            end
            return false, e
        end,
        delete_func = function(card)
            return deleteCardFromDB(card)
        end,
        undo_func = function(card)
            local done, e = undoCard(ctx.list, card)
            if done then
                return true
            end
            if e == NOT_FOUND then
                useFresh(liveList(ctx.list))
                return undoCard(ctx.list, card)
            end
            return false, e
        end,
        lookup_func = function(card, on_close)
            -- The native KOReader LookupWord event supports a dedicated
            -- dictionary-close callback. Use it only for Meaning options;
            -- ordinary card lookups retain their original list callback.
            if type(on_close) == "function" then
                local ui = getUI()
                if not ui or not ui.dictionary then return false end
                ctx.list.current_lookup_word = card.word
                ui:handleEvent(Event:new("LookupWord", card.word, true,
                    nil, nil, nil, on_close))
                return true
            end
            -- same call the list makes when the word is tapped
            local row = findRow(ctx.list, card)
            if row and type(row.item) == "table" and type(row.item.callback) == "function" then
                guarded(row.item.callback, row.item)
                return true
            end
            local ui = getUI()
            if ui then
                ui:handleEvent(Event:new("LookupWord", card.word))
                return true
            end
            return false
        end,
        flush_func = function()
            flushToDB(ctx.list)
        end,
        reload_func = function()
            useFresh(liveList(ctx.list))
            watchList(ctx.list)
            local new_deck, e = acquireDeck(ctx)
            if type(new_deck) ~= "table" then
                error(e or "could not read the word list", 0)
            end
            return new_deck
        end,
        list_check = function()
            local plugin = getPlugin()
            if plugin and type(plugin.widget) == "table" and plugin.widget ~= ctx.list then
                return false
            end
            return type(ctx.list.item_table) == "table"
        end,
        menu_func = function()
            local cb = findListMenuCallback(ctx.list)
            if not cb then
                return false
            end
            cb()
            return true
        end,
        on_close = function(touched)
            Flash.current = nil
            Flash.menu_for = nil
            -- When we opened the native list only as a backing window for
            -- flashcards, X must return to the READER, not to a hidden or
            -- orphaned Vocabulary Builder widget. Native onClose persists the
            -- list and clears the plugin.widget reference as KOReader expects.
            if auto_opened then
                if UIManager:isWidgetShown(ctx.list) then
                    local ok_close, e = pcall(function()
                        if type(ctx.list.onClose) == "function" then
                            ctx.list:onClose()
                        else
                            UIManager:close(ctx.list, "ui")
                        end
                    end)
                    if not ok_close then
                        logger.warn("vocab flashcards: native list close failed:", e)
                        -- Do not leave a ghost fullscreen list in the stack.
                        if UIManager:isWidgetShown(ctx.list) then
                            pcall(UIManager.close, UIManager, ctx.list, "ui")
                        end
                        local plugin = getPlugin()
                        if plugin and plugin.widget == ctx.list then
                            plugin.widget = nil
                        end
                    end
                end
                UIManager:setDirty("all", "ui")
            elseif UIManager:isWidgetShown(ctx.list) then
                if touched then reloadList(ctx.list) end
                UIManager:setDirty(ctx.list, "ui")
            end
        end,
    }
    Flash.current = flash
    -- Use a normal UI waveform instead of the flashing `full` waveform.
    -- This still triggers an actual hardware repaint on Kindle; the existing
    -- manual corner refresh remains available if ghosting needs clearing.
    UIManager:show(flash, "ui")
    -- With an actual displayed widget, an empty private database can prompt
    -- to archive and restart old CRAM state. Never reset automatically.
    flash:_offerCramResetForEmptyDeck()
    if flash._cram_unavailable and not flash._cram_reset_offered then
        UIManager:nextTick(function()
            if not flash._closing and UIManager:isWidgetShown(flash) then
                UIManager:show(newFlashInfo(flash, {
                    text = "Saved CRAM progress could not be read. "
                        .. "CRAM is disabled to protect your data. "
                        .. "Keep the original file and check KOReader logs.",
                    timeout = 8,
                }))
            end
        end)
    end
    flash:_armReviewClock()
    return true
end

---------------------------------------------------------------- menu compatibility
-- The old optional "Flashcard mode" and "List view" menu buttons are no longer
-- created. FlipSide's opening screen is already the flashcard interface.
-- Do not inject a second navigation mode into the native settings popup.

---------------------------------------------------------------- hook

-- Passive paint observation: if KOReader actually calls the flashcard's
-- painter during a cover, record the stack. We NEVER suppress native paints
-- here: the screensaver may intentionally composite background widgets.
local native_flash_paint = Flashcards.paintTo
if type(native_flash_paint) == "function" then
    Flashcards.paintTo = function(self, ...)
        if Device.screen_saver_mode or self._sleep_paused then
            SleepTrace.blocked("actual_paint", UIManager, Device, self)
        end
        return native_flash_paint(self, ...)
    end
end

-- Old standalone Vocabulary Builder flashcard userpatches may still wrap
-- UIManager.show() and append a full 'List view' row (separator + ButtonTable)
-- to the FlipSide settings popup. Strip the entire row, not just its label,
-- and invalidate the group's measured layout so there is NO empty space.
-- Scope strictly to setupPluginMenu() of FlipSide's own settings window.
local function isRetiredModeButtonTable(candidate)
    if type(candidate) ~= "table" or type(candidate.buttons) ~= "table"
            or #candidate.buttons ~= 1 then return false end
    local row = candidate.buttons[1]
    if type(row) ~= "table" or #row ~= 1 then return false end
    local button = row[1]
    if type(button) ~= "table" then return false end
    local label = button.text
    if type(label) ~= "string" then return false end
    -- Earlier standalone userpatches used both the plain name and this
    -- longer caption. Never remove actual review-strategy/card-model buttons.
    return label == "List view" or label == _("List view")
        or label == "Flashcard mode" or label == _("Flashcard mode")
        or label == "Flashcard mode (Anki style)"
end

local function stripRetiredModeRows(dialog)
    if type(dialog) ~= "table" or not dialog._flipside_settings_popup then
        return false
    end
    local changed = false
    local seen = {}
    local function walk(node, depth)
        if depth > 16 or type(node) ~= "table" or seen[node] then return end
        seen[node] = true
        local node_changed = false
        for index = #node, 1, -1 do
            local child = node[index]
            if isRetiredModeButtonTable(child) then
                -- Drop the old button row AND its immediately preceding
                -- horizontal divider, as inserted by the legacy patch.
                table.remove(node, index)
                if index > 1 and getmetatable(node[index-1]) == LineWidget then
                    table.remove(node, index-1)
                end
                node_changed = true
                changed = true
            elseif type(child) == "table" then
                walk(child, depth + 1)
            end
        end
        if node_changed then
            if type(node.resetLayout) == "function" then
                node:resetLayout()
            else
                node._size = nil
            end
        end
    end
    walk(dialog, 0)
    return changed
end

local orig_show = UIManager.show

-- This is a global KOReader API. Keep the interception deliberately narrow:
-- for every normal widget (including reader gestures, dialogs, notifications)
-- call KOReader's original show unchanged. The Vocabulary Builder owns the
-- list's lifetime; flashcards must NOT substitute their own window for it.
UIManager.show = function(self, widget, ...)
    if (Device.screen_saver_mode or (Flash.current and Flash.current._sleep_paused))
            and type(widget) == "table" then
        SleepTrace.windowShown(self, Device, Flash.current, widget)
    end
    if type(widget) ~= "table" then
        return orig_show(self, widget, ...)
    end
    -- A legacy patch might have already inserted its outdated menu row.
    -- Handle this BEFORE the native popup is displayed.
    stripRetiredModeRows(widget)
    -- Recognize native Vocabulary Builder windows without affecting other
    -- KOReader menus.  Companion Learning Audit windows are tagged at source.
    if isListWidget(widget) then
        widget._vocab_no_flash_surface = true
        widget.skip_paint = true -- internal backing list is NEVER exposed
    elseif type(widget.vocabbuilder) == "table"
            and isListWidget(widget.vocabbuilder) then
        widget._vocab_no_flash_surface = true
        -- KOReader's stock Vocab MenuDialog:onShow() explicitly requests a
        -- flashing `flashui` refresh.  Keep its normal geometry and close
        -- behavior, but request a nonflashing UI update for this menu only.
        if not widget._vocab_eink_onshow and type(widget.onShow) == "function" then
            widget._vocab_eink_onshow = true
            local native_menu_onshow = widget.onShow
            widget.onShow = function(menu, ...)
                local frame = menu[1] and menu[1][1]
                if menu._flipside_settings_popup then
                    -- Paint the flashcard canvas beneath the floating menu,
                    -- then its opaque panel. Do not white-out the whole screen.
                    UIManager:setDirty("all", "ui")
                elseif frame and frame.dimen then
                    UIManager:setDirty(menu, function() return "ui", frame.dimen end)
                else
                    return native_menu_onshow(menu, ...)
                end
            end
        end
    end
    if widget._vocab_no_flash_surface then
        -- Menus built before being shown (e.g. gesture-owned Audit menus)
        -- already have a full page of MenuItems: tag those, too.
        markVocabMenuItems(widget)
    end

    local current = Flash.current
    if current and widget ~= current and not current._closing
            and UIManager:isWidgetShown(current)
            and UIManager:getTopmostVisibleWidget() == current then
        -- The native menu, the statistics dialog, dictionary, Aa popups and
        -- confirmations all pause the timer BEFORE covering the review card.
        current:_clockPause()
    end

    if isListWidget(widget) then
        -- Register the native list *first* so its onShow/onClose handlers and
        -- the plugin.widget reference agree with UIManager._window_stack.
        local ret = orig_show(self, widget, ...)
        if flashMode() and not flashShown() then
            Flash.auto_pending = widget
            UIManager:nextTick(function()
                if Flash.auto_pending ~= widget then return end
                Flash.auto_pending = nil
                -- A gesture can close the list before the next tick, or a
                -- different dialog can have been opened by another plugin.
                if not flashMode() or flashShown() or not UIManager:isWidgetShown(widget)
                    or UIManager:getTopmostVisibleWidget() ~= widget then
                    return
                end
                local ok, started = pcall(Flash.start, widget, true, true)
                if not ok then
                    logger.warn("flipside: automatic opening failed:", started)
                    if widget.onClose then pcall(widget.onClose, widget) end
                elseif not started then
                    logger.warn("flipside: cannot open; closing private backing widget")
                    if widget.onClose then pcall(widget.onClose, widget) end
                end
            end)
        end
        return ret
    end

    -- No "List view" or "Flashcard mode" button is injected:
    -- FlipSide opens directly into its flashcards and has no public list.
    local result = orig_show(self, widget, ...)
    -- Some installations still have an old userpatch which injects the row
    -- *inside* orig_show(). Strip again after that wrapper returns.
    if stripRetiredModeRows(widget) then
        UIManager:setDirty(widget, "ui")
    end
    return result
end

-- Non-destructive bridge for FlipSide's main menu: open the existing Aa
-- appearance menu on the active flashcard screen. No new user setting.
package.loaded["flipside_flashcards_menu_api"] = {
    -- Only Statistics uses this reversible paint-time mask. It never edits
    -- the card, its saved context or any review/scheduling record.
    setStatisticsCenterConcealed = function(conceal)
        local current = Flash.current
        if not current or current._closing or not UIManager:isWidgetShown(current) then
            return false
        end
        local next_state = conceal == true
        if current._flipside_statistics_conceal_center ~= next_state then
            current._flipside_statistics_conceal_center = next_state
            current:_refresh()
        end
        return true
    end,
    -- Scoped to existing modal dialogs; no review, SRS or data mutation.
    -- A depth counter also keeps the background hidden while dialogs are
    -- replaced (for example when changing the Study Calendar view).
    concealCompletionPanel = function(conceal)
        local current = Flash.current
        if not current or current._closing or not UIManager:isWidgetShown(current) then
            return false
        end
        local before = current._flipside_completion_overlay_depth or 0
        if conceal and (current.state == "card" or current.practice) then
            return false
        end
        local after = math.max(0, before + (conceal and 1 or -1))
        if before == after then return false end
        current._flipside_completion_overlay_depth = after
        if (before == 0) ~= (after == 0) then
            current:_render()
            current:_refresh()
        end
        return true
    end,
    -- Measured region between the upper flashcard tools and the bottom
    -- review controls. Used only to position the floating settings menu;
    -- no review state, layout or card contents are modified.
    getMenuSafeBounds = function()
        local current = Flash.current
        if not current or current._closing or not UIManager:isWidgetShown(current) then
            return nil
        end
        return current.card_rect
    end,
    -- Measured decorator bounds, shared with the Saved Meanings popup.
    -- Default style has no ornamental frame, so there is nothing to cover.
    getCardFrame = function()
        local current = Flash.current
        if not current or current._closing or not UIManager:isWidgetShown(current) then
            return nil
        end
        return current._flipside_meaning_frame
    end,
    openSearch = function()
        local current = Flash.current
        if not current or current._closing or not UIManager:isWidgetShown(current) then
            return false
        end
        return current:showWordSearch()
    end,
    openAppearance = function()
        local current = Flash.current
        if not current or current._closing or not UIManager:isWidgetShown(current) then
            return false
        end
        return current:showSentenceAppearance()
    end,
}

---------------------------------------------------------------- gesture / profile action

-- "Vocabulary builder: flashcard review": opens the flashcards directly,
-- whatever the saved mode is. Useful as a second entry point.
-- FlipSide registers its own app menu, event and gesture actions.
-- This integrated component does not register global userpatch hooks.

-- One observational wrapper around UIManager:setDirty. Never modify its
-- arguments or screen refresh decision, even during a Kindle suspend.
SleepTrace.install(UIManager, Device, function() return Flash.current end)
logger.info("FlipSide: Kindle sleep/refresh diagnostics v2 loaded")
logger.info("2-vocabbuilder-flashcards: v2.4.63 (scoped Vocabulary e-ink feedback, native menu typography, nonflashing transitions) loaded")
