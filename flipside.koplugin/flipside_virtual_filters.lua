--[[
    2-vocabulary-builder-virtual-filters.lua

    Adds four "virtual books" at the top of the Vocabulary builder's
    "Filter words from books" dialog:

        All books        -> reviewed cards EXCEPT those in "Added today" or
                            "Added yesterday". Never-reviewed cards are
                            reserved for "Never Reviewed" and do not also
                            appear in "All books".
        Added today      -> cards added today (00:00 -> 00:00). They stay here
                            all day, reviewed or not. At midnight they leave.
        Added yesterday  -> cards added YESTERDAY that were not reviewed yet.
                            A card that gets its first review today stays here
                            until 00:00 (end of its review day) and then
                            disappears, making room for the next day's cards.
        Never Reviewed   -> all cards that have never been reviewed, regardless
                            of the day or book they were added from. A first
                            Forgot or Got it review removes the card from this
                            filter. This collection removes its matching
                            words from "All books" (but preserves the date
                            categories, including "Added today").

    Daily flow of a card:
        day 1: added -> shows in "Added today" (reviewed or not, until 00:00)
        day 2: if still unreviewed -> shows in "Added yesterday"
               if you review it on day 2 -> stays there until 00:00 of day 2
        day 3: gone from "Added yesterday". Still-unreviewed cards remain in
               "Never Reviewed" only, not in "All books".

    Only ONE of them can be ticked at a time (tap again to untick). While one
    is ticked it behaves like a book of its own: the list shows its cards from
    all books, and the real book ticks are ignored. It stays ticked when you
    leave the Vocabulary builder and open it again, even after a KOReader restart.
    With none ticked, the Vocabulary builder works exactly as before.

    "Added today", "Added yesterday" and "Never Reviewed" ignore the
    "show only reviewable" setting, so their full matching sets are visible.
    "All books" keeps respecting it.

    Does NOT modify the plugin files or the database. It keeps its own small
    file, settings/vocabulary_virtual_filters.lua, with the day of the first
    review of recent cards. It is updated whenever the Vocabulary builder list
    is opened and every time reviews are saved to the database.

    Written for the vocabbuilder.koplugin shipped with KOReader 2026.07.x
    (db schema version 20240905).

    Install: koreader/patches/2-vocabulary-builder-virtual-filters.lua, then restart KOReader.
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local gettext = require("gettext")

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

-- Hour at which "today" starts. 0 = midnight. Use 4 if you want cards from
-- 00:00-03:59 to still count as "yesterday".
local DAY_START_HOUR = 0

local STORE_FILE = DataStorage:getSettingsDir() .. "/flipside/vocabulary_virtual_filters.lua"

-- Start (timestamp) of the "day" that contains ts.
local function dayStartOf(ts)
    local t = os.date("*t", ts)
    local start = os.time{ year = t.year, month = t.month, day = t.day, hour = DAY_START_HOUR, min = 0, sec = 0 }
    if start > ts then
        start = os.time{ year = t.year, month = t.month, day = t.day - 1, hour = DAY_START_HOUR, min = 0, sec = 0 }
    end
    return start
end

local function dayStart()
    return dayStartOf(os.time())
end

-- Start of the day before the day that starts at `start`.
local function prevDayStart(start)
    local t = os.date("*t", start)
    return os.time{ year = t.year, month = t.month, day = t.day - 1, hour = DAY_START_HOUR, min = 0, sec = 0 }
end

-- A card never reviewed: the plugin stores review_time = create_time on
-- insert and only changes it on a review, and review_count/streak stay at 0.
local NEVER_REVIEWED_SQL = "(review_count = 0 AND streak_count = 0 AND ifnull(review_time, 0) <= create_time)"

---------------------------------------------------------------------------
-- Day of the first review of recent cards, persisted in STORE_FILE
---------------------------------------------------------------------------

local DB, SQ3
local store
local store_dirty = false
local first_review = {} -- word -> start of the day in which it was first reviewed

local function loadStore()
    if store ~= nil then return end
    local ok, ls = pcall(function()
        return require("luasettings"):open(STORE_FILE)
    end)
    store = ok and ls or false
    if store then
        local saved = store:readSetting("first_review")
        if type(saved) == "table" then first_review = saved end
        -- the previous version of this patch stored a different list: drop it
        if store:readSetting("words") ~= nil or store:readSetting("day") ~= nil then
            pcall(store.delSetting, store, "words")
            pcall(store.delSetting, store, "day")
            store_dirty = true
        end
    end
end

-- SQL condition: cards whose first review happened in the day starting at `start`.
local function reviewedFirstTodaySQL(start)
    local parts = {}
    for w, d in pairs(first_review) do
        if d == start then
            parts[#parts + 1] = "'" .. (w:gsub("'", "''")) .. "'"
        end
    end
    if #parts == 0 then return "0" end
    return "word IN (" .. table.concat(parts, ",") .. ")"
end

-- "Added yesterday": added yesterday AND (still unreviewed OR first reviewed today).
local function addedYesterdayCond(start)
    return string.format("(create_time >= %d AND create_time < %d AND (%s OR %s))",
        prevDayStart(start), start, NEVER_REVIEWED_SQL, reviewedFirstTodaySQL(start))
end

-- "Added today": added today, reviewed or not.
local function addedTodayCond(start)
    return string.format("create_time >= %d", start)
end

-- Record the day of the first review of every reviewed card added yesterday or
-- today. A word keeps its first day even if it is reviewed again later.
-- Entries older than yesterday are forgotten.
local function observe()
    if not DB then return end
    loadStore()
    local start = dayStart()
    local since = prevDayStart(start)
    local dirty = store_dirty
    store_dirty = false

    for w, d in pairs(first_review) do
        if type(d) ~= "number" or d < since then
            first_review[w] = nil
            dirty = true
        end
    end

    local conn = SQ3.open(DB.path)
    local ok, results = pcall(conn.exec, conn, string.format(
        "SELECT word, review_time FROM vocabulary WHERE create_time >= %d AND NOT %s;",
        since, NEVER_REVIEWED_SQL))
    conn:close()
    if ok and results and results.word then
        for i = 1, #results.word do
            local w = results.word[i]
            if w and first_review[w] == nil then
                local rt = tonumber(results.review_time[i]) or os.time()
                first_review[w] = dayStartOf(rt)
                dirty = true
            end
        end
    end

    if dirty and store then
        store:saveSetting("first_review", first_review)
        pcall(store.flush, store)
    end
end

---------------------------------------------------------------------------
-- Virtual books
---------------------------------------------------------------------------

-- "All books" must not include the NEVER_REVIEWED collection: like the daily
-- queues, it is a separate review pool. Exclude directly in SQL so displayed
-- counts and paginated results use the same definition.
-- label: text shown in the dialog and as list title while ticked.
-- cond: SQL condition (columns of the `vocabulary` table); receives the start of today.
-- ignore_due: ignore the plugin's "show only reviewable" setting.
local MODES = {
    {
        key = "all_books",
        label = "All books",
        ignore_due = false,
        cond = function(start)
            return string.format("NOT (%s OR %s OR %s)",
                addedTodayCond(start), addedYesterdayCond(start), NEVER_REVIEWED_SQL)
        end,
    },
    {
        key = "added_today",
        label = "Added today",
        ignore_due = true,
        cond = function(start)
            return addedTodayCond(start)
        end,
    },
    {
        key = "added_yesterday",
        label = "Added yesterday",
        ignore_due = true,
        cond = function(start)
            return addedYesterdayCond(start)
        end,
    },
    {
        key = "never_reviewed",
        label = "Never Reviewed",
        ignore_due = true,
        cond = function()
            -- Same definition already used by "Added yesterday", but without
            -- a create_time restriction: include all books and all dates.
            return NEVER_REVIEWED_SQL
        end,
    },
}

-- Key of the ticked virtual book, or nil. Like the real book ticks, it is kept
-- when you leave the Vocabulary builder and open it again, and it is saved in
-- STORE_FILE so it also survives a KOReader restart.
local current = nil

local function saveCurrent()
    loadStore()
    if not store then return end
    if current then
        store:saveSetting("current", current)
    else
        pcall(store.delSetting, store, "current")
    end
    pcall(store.flush, store)
end

local function restoreCurrent()
    loadStore()
    local saved = store and store:readSetting("current")
    for _, m in ipairs(MODES) do
        if m.key == saved then
            current = saved
            break
        end
    end
    logger.info("vocabbuilder virtual filters: restored tab:", tostring(current))
end
pcall(restoreCurrent)

local function activeMode()
    if not current then return nil end
    for _, m in ipairs(MODES) do
        if m.key == current then return m end
    end
    return nil
end

local function setListTitle(widget)
    pcall(function()
        local mode = activeMode()
        widget.title_bar:setTitle(mode and mode.label or widget.title)
    end)
end

---------------------------------------------------------------------------
-- Wrap the DB module
---------------------------------------------------------------------------

local function installDB()
    local ok, mod = pcall(require, "flipside_db")
    if ok and type(mod) == "table" and mod.virtual_filters_installed and SQ3 then
        DB = mod
        return DB, SQ3
    end

    if not ok or type(mod) ~= "table"
        or type(mod.path) ~= "string" or not mod.path:find("vocabulary_builder", 1, true)
        or type(mod.selectCount) ~= "function"
        or type(mod._select_items) ~= "function"
        or type(mod.hasFilteredBook) ~= "function"
        or type(mod.batchUpdateItems) ~= "function" then
        logger.warn("vocabbuilder virtual filters: unexpected db module, not installing")
        return nil
    end
    local ok2, sq3 = pcall(require, "lua-ljsqlite3/init")
    if not ok2 then
        logger.warn("vocabbuilder virtual filters: sqlite module not found")
        return nil
    end

    local orig_count = mod.selectCount
    local orig_select = mod._select_items
    local orig_has = mod.hasFilteredBook
    local orig_batch = mod.batchUpdateItems

    -- Every time reviews are saved, note which cards got their first review.
    mod.batchUpdateItems = function(self, ...)
        local ret = orig_batch(self, ...)
        if DB then pcall(observe) end
        return ret
    end

    mod.selectCount = function(self, vocab_widget)
        local mode = not (vocab_widget and vocab_widget.search_text_sql) and activeMode() or nil
        if type(vocab_widget) == "table" then
            vocab_widget.virtual_filter_loaded = mode and mode.key or nil
        end
        if mode then
            local ok, count = pcall(function()
                pcall(observe)
                local where = " WHERE " .. mode.cond(dayStart())
                if not mode.ignore_due and vocab_widget:check_reverse() then
                    where = where .. string.format(" AND due_time <= %d", vocab_widget.reload_time or os.time())
                end
                local conn = sq3.open(self.path)
                local n = tonumber(conn:rowexec(
                    "SELECT count(0) FROM vocabulary INNER JOIN title ON title_id = id" .. where .. ";"))
                conn:close()
                return n
            end)
            if ok and count then return count end
            logger.warn("vocabbuilder virtual filters: count failed:", count)
        end
        return orig_count(self, vocab_widget)
    end

    mod._select_items = function(self, items, start_idx, reload_time, search_text)
        local mode = not search_text and activeMode() or nil
        if not mode then
            return orig_select(self, items, start_idx, reload_time, search_text)
        end
        local ok, err = pcall(function()
            local due_clause = ""
            if reload_time and not mode.ignore_due then
                due_clause = string.format(" AND due_time <= %d", reload_time)
            end
            local sql = string.format(
                "SELECT * FROM vocabulary INNER JOIN title ON title_id = title.id "
                .. "WHERE %s%s ORDER BY due_time%s limit %d OFFSET %d;",
                mode.cond(dayStart()),
                due_clause,
                reload_time and " desc" or "",
                32, start_idx - 1)

            local conn = sq3.open(self.path)
            local results = conn:exec(sql)
            conn:close()
            if not results then return end

            local current_time = os.time()
            for i = 1, #results.word do
                local item = items[start_idx + i - 1]
                if item and not item.word then
                    item.word = results.word[i]
                    item.review_count = math.max(0, tonumber(results.review_count[i]))
                    item.streak_count = math.max(0, tonumber(results.streak_count[i]))
                    item.book_title = results.name[i] or ""
                    item.highlight = results.highlight[i]
                    item.create_time = tonumber(results.create_time[i])
                    item.review_time = nil -- the plugin uses this field to flag changes
                    item.due_time = tonumber(results.due_time[i])
                    item.is_dim = tonumber(results.due_time[i]) > current_time
                    item.prev_context = results.prev_context[i]
                    item.next_context = results.next_context[i]
                    item.got_it_callback = function(item_input)
                        mod:gotOrForgot(item_input, true)
                    end
                    item.forgot_callback = function(item_input)
                        mod:gotOrForgot(item_input, false)
                    end
                    item.remove_callback = function(item_input)
                        mod:remove(item_input)
                    end
                end
            end
        end)
        if not ok then
            logger.warn("vocabbuilder virtual filters: select failed:", err)
            return orig_select(self, items, start_idx, reload_time, search_text)
        end
    end

    -- Empty list with a virtual book ticked => "Filter in effect" instead of "No items"
    -- (except for "All books", where an empty list really means no cards).
    mod.hasFilteredBook = function(self)
        local mode = activeMode()
        if mode then
            return mode.key ~= "all_books"
        end
        return orig_has(self)
    end

    mod.virtual_filters_installed = true
    DB, SQ3 = mod, sq3
    logger.info("vocabbuilder virtual filters: db module wrapped")
    return DB, SQ3
end

local function countWords(mode)
    local conn = SQ3.open(DB.path)
    local ok, n = pcall(conn.rowexec, conn,
        "SELECT count(0) FROM vocabulary INNER JOIN title ON title_id = id WHERE "
        .. mode.cond(dayStart()) .. ";")
    conn:close()
    return ok and tonumber(n) or 0
end

---------------------------------------------------------------------------
-- Record first reviews as soon as the Vocabulary builder list is shown,
-- i.e. before any further card gets reviewed in that session.
---------------------------------------------------------------------------

local function onVocabWidgetShown(widget)
    if not installDB() then return end
    observe()
    if not current then return end
    -- the list was reopened with a virtual book still ticked: show its name
    setListTitle(widget)
    -- if the list was loaded before our filter was active, load it again
    if widget.virtual_filter_loaded ~= current and type(widget.reloadItems) == "function" then
        logger.info("vocabbuilder virtual filters: reloading list for tab", current)
        UIManager:nextTick(function()
            pcall(widget.reloadItems, widget)
            setListTitle(widget)
        end)
    end
end

local orig_show = UIManager.show
UIManager.show = function(self, widget, ...)
    if type(widget) == "table" and widget.vocabbuilder
        and type(widget.item_table) == "table" and type(widget.check_reverse) == "function" then
        local ok, err = pcall(onVocabWidgetShown, widget)
        if not ok then
            logger.warn("vocabbuilder virtual filters:", err)
        end
    end
    return orig_show(self, widget, ...)
end

---------------------------------------------------------------------------
-- Add the entries to the "Filter words from books" dialog
---------------------------------------------------------------------------

-- Returns a function to call with the created SortWidget (used to redraw the
-- checkmarks when another entry gets unticked), or nil if this is not the
-- Vocabulary builder filter dialog.
local function decorateFilterDialog(o)
    if type(o) ~= "table" or not o.sort_disabled or type(o.item_table) ~= "table" then return end
    local widget = o.show_parent
    if type(widget) ~= "table" or not widget.vocabbuilder or type(widget.item_table) ~= "table" then return end
    if o.title ~= gettext("Filter words from books") then return end

    if not installDB() then return end

    -- Save pending reviews so the counts below are up to date
    -- (this also records the first reviews, see batchUpdateItems above).
    pcall(DB.batchUpdateItems, DB, widget.item_table)
    pcall(observe)

    -- Edited copy: only committed when the dialog's own callback runs.
    local pending = { mode = current }
    local dialog -- the SortWidget, set after it is created

    for i, mode in ipairs(MODES) do
        table.insert(o.item_table, i, {
            text = string.format("%s (%d)", mode.label, countWords(mode)),
            callback = function()
                if pending.mode == mode.key then
                    pending.mode = nil
                else
                    pending.mode = mode.key
                end
                -- redraw so the other virtual books show as unticked
                if dialog and type(dialog._populateItems) == "function" then
                    UIManager:nextTick(function()
                        pcall(dialog._populateItems, dialog)
                    end)
                end
            end,
            checked_func = function()
                return pending.mode == mode.key
            end,
            hold_callback = function() end,
        })
    end

    local orig_callback = o.callback
    o.callback = function(...)
        current = pending.mode
        pcall(saveCurrent)
        setListTitle(widget)
        if orig_callback then
            return orig_callback(...)
        end
    end

    return function(sort_widget)
        dialog = sort_widget
    end
end

local ok, SortWidget = pcall(require, "ui/widget/sortwidget")
if ok and type(SortWidget) == "table" and type(SortWidget.new) == "function" then
    local orig_new = SortWidget.new
    SortWidget.new = function(cls, o, ...)
        local ok_dec, after_new = pcall(decorateFilterDialog, o)
        if not ok_dec then
            logger.warn("vocabbuilder virtual filters:", after_new)
            after_new = nil
        end
        local instance = orig_new(cls, o, ...)
        if after_new then
            after_new(instance)
        end
        return instance
    end
else
    logger.warn("vocabbuilder virtual filters: SortWidget not found, patch inactive")
end
