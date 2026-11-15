--[[--
KOReader - Dictionary Position Lock v5.4 + Cloud Storage sync (HTTP status aware)

One button only: "Lock this position" / "Unlock this position".
Multiple locks per word are supported across dictionaries and results.
The most recently locked result is selected on a *new* dictionary popup,
using already loaded results (no additional dictionary query).

v4/v5 use a stable (word, dictionary, headword, occurrence) identity instead of
hashing the entire definition. Old v3 locks are imported on first lookup when
an entry can be matched unambiguously; unlocked old entries are not imported.

Cloud sync: use KOReader Cloud storage folder chooser, sync an independent
text snapshot with last-writer-wins tombstones; the live SQLite DB is never
uploaded, replaced or copied across devices. Manual sync via Gesture Manager.

File: koreader/patches/2-vocabulary-builder-saved-meanings.lua
Database: Settings/vocabulary_builder_saved_meanings.sqlite3
--]]--

local DictQuickLookup = require('ui/widget/dictquicklookup')
local UIManager = require('ui/uimanager')
local InfoMessage = require('ui/widget/infomessage')
local DataStorage = require('datastorage')
local SQL = require('lua-ljsqlite3/init')
local logger = require('logger')
local LuaSettings = require('luasettings')
local Dispatcher = require('dispatcher')

if DictQuickLookup._flipside_dictionary_position_lock_v5 then return end
DictQuickLookup._flipside_dictionary_position_lock_v5 = true
-- Prevent an older copy of the v4 patch from registering if loaded after us.
DictQuickLookup._flipside_dictionary_position_lock_v4 = true

local PATH = DataStorage:getSettingsDir() .. '/flipside/vocabulary_builder_saved_meanings.sqlite3'
-- Keep v5.3 remote filename so previous successful syncs remain accessible.
-- Both Kindle and Android should run v5.4 for robust error handling.
local SYNC_PATH = DataStorage:getSettingsDir() .. '/flipside/dictionary_position_locks_sync_v2.tsv'
local SYNC_SETTINGS_PATH = DataStorage:getSettingsDir() .. '/flipside/dictionary_position_locks_sync.lua'
local BUTTON_ID = 'dictionary_position_lock_v4'
local schema_ready = false
local legacy_exists = false
local unpack_args = unpack or table.unpack

local function warn(error_message)
    logger.warn('Dictionary Position Lock v5.4:', tostring(error_message))
end
local function notify(s)
    UIManager:show(InfoMessage:new{ text=s, timeout=3 })
end
local function normalize(s)
    return tostring(s or ''):match('^%s*(.-)%s*$'):lower()
end
local function quote(s)
    return "'" .. tostring(s or ''):gsub("'", "''") .. "'"
end
-- lua-ljsqlite3 conn:exec() defaults to get='hik':
--   columns[0] = header NAMES (not rows)
--   columns[1..n] = numeric aliases for the column arrays
--   columns['name'] = the SAME arrays indexed by column name
-- and the SECOND return value is the number of result records.
-- Iterating `pairs(columns)` and using `#columns[next(columns)]` can count
-- column headings rather than actual rows, creating phantom nil-key records.
-- This matters when exporting all locks for cloud sync.
local function readRows(db, sql)
    local columns, nrow = db:exec(sql)
    if type(columns) ~= 'table' then return {} end
    local names = columns[0]
    if type(names) ~= 'table' then
        -- Compatibility with older mocks or result sets lacking the header.
        names = {}
        for name, values in pairs(columns) do
            if type(name) == 'string' and type(values) == 'table' then
                names[#names + 1] = name
            end
        end
    end
    local count = tonumber(nrow)
    if not count then
        count = 0
        for _, name in ipairs(names) do
            local values = columns[name]
            if type(values) == 'table' then
                count = math.max(count, #values)
            end
        end
    end
    local result = {}
    for i = 1, count do
        local row = {}
        for _, name in ipairs(names) do
            local values = columns[name]
            if values then row[name] = values[i] end
        end
        result[#result + 1] = row
    end
    return result
end

local function execute(db, sql, ...)
    local st = assert(db:prepare(sql), 'SQLite prepare failed')
    local count, args = select('#', ...), {...}
    local ok, err = pcall(function()
        if count > 0 then st:bind(unpack_args(args, 1, count)) end
        local result = st:step()
        if result == false then error('SQLite step returned false') end
    end)
    pcall(st.close, st)
    if not ok then error(err, 0) end
end
local function initialize(db)
    if schema_ready then return end
    local created = db:exec([[
        CREATE TABLE IF NOT EXISTS dictionary_position_locks_v4 (
            word TEXT NOT NULL,
            dictionary TEXT NOT NULL,
            source_word TEXT NOT NULL,
            occurrence INTEGER NOT NULL,
            scroll_kind TEXT NOT NULL,
            scroll_number INTEGER NOT NULL DEFAULT 1,
            scroll_ratio REAL NOT NULL DEFAULT 0,
            locked INTEGER NOT NULL DEFAULT 1,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (word, dictionary, source_word, occurrence)
        );
        CREATE INDEX IF NOT EXISTS dictionary_position_locks_v4_recent
        ON dictionary_position_locks_v4(word, locked, updated_at);
    ]])
    assert(created ~= false, 'Could not initialize dictionary locks')
    legacy_exists = #readRows(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='saved_meanings_spots';") > 0
    schema_ready = true
end
local function withDB(callback)
    local db
    local ok, result = pcall(function()
        db = assert(SQL.open(PATH), 'Could not open database')
        initialize(db)
        return callback(db)
    end)
    if db then pcall(db.close, db) end
    if not ok then
        warn(result)
        return nil, tostring(result)
    end
    return result
end

local function sig(s)
    s = tostring(s or '')
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return string.format('%d:%d:%d', #s, b, a)
end
local function identityAt(popup, index)
    if not popup or popup.is_wiki or not popup.results then return nil end
    local res = popup.results[index]
    if not res then return nil end
    local word = normalize(popup.word or popup.lookupword or popup.displayword)
    if word == '' then return nil end
    local dict = tostring(res.dict or '')
    local source = normalize(res.word or word)
    local occurrence = 1
    -- Relative occurrence is immune to results from *other* dictionaries
    -- changing order, unlike the global result index or a text hash.
    for i = 1, index - 1 do
        local prior = popup.results[i]
        if prior and tostring(prior.dict or '') == dict
           and normalize(prior.word or word) == source then
            occurrence = occurrence + 1
        end
    end
    return {
        word=word, dictionary=dict, source_word=source,
        occurrence=occurrence, signature=sig(res.definition),
        popup_signature=sig(popup.definition),
    }
end
local function current(popup)
    return popup and identityAt(popup, popup.dict_index or 1)
end
local function key(r)
    return table.concat({r.word, r.dictionary, r.source_word, r.occurrence}, '\0')
end
local function whereKey(r)
    return 'word=' .. quote(r.word)
        .. ' AND dictionary=' .. quote(r.dictionary)
        .. ' AND source_word=' .. quote(r.source_word)
        .. ' AND occurrence=' .. tonumber(r.occurrence)
end
local function getRow(db, r)
    return readRows(db, 'SELECT locked, scroll_kind, scroll_number, scroll_ratio, updated_at '
        .. 'FROM dictionary_position_locks_v4 WHERE ' .. whereKey(r) .. ' LIMIT 1;')[1]
end
local function isLocked(row)
    return row and tonumber(row.locked) == 1 or false
end
local function nextLocalTimestamp(db)
    local rows = readRows(db, 'SELECT MAX(updated_at) AS latest FROM dictionary_position_locks_v4;')
    local observed = rows[1] and tonumber(rows[1].latest) or 0
    -- Local changes must outrank previously synchronized remote revisions,
    -- even if this device has a slightly slower clock.
    return math.max(os.time(), observed + 1)
end
local function upsert(db, r, kind, number, ratio, locked, timestamp)
    timestamp = timestamp or nextLocalTimestamp(db)
    execute(db, [[INSERT OR REPLACE INTO dictionary_position_locks_v4
       (word,dictionary,source_word,occurrence,scroll_kind,
        scroll_number,scroll_ratio,locked,updated_at)
        VALUES (?,?,?,?,?,?,?,?,?);]],
        r.word, r.dictionary, r.source_word, r.occurrence, kind or '',
        number or 1, ratio or 0, locked and 1 or 0, timestamp)
end
local function unsetLegacy(db, old)
    execute(db, [[UPDATE saved_meanings_spots SET locked=0
        WHERE word=? AND dictionary=? AND source_word=? AND result_signature=?;]],
        old.word, old.dictionary, old.source_word, old.result_signature)
end
-- Migrate legacy positions ONLY when a result in the current KOReader results
-- has a unique match. Never restore old unlocked positions or resurrect tombstones.
local function importLegacy(popup)
    if not legacy_exists or not popup.results then return end
    local word = normalize(popup.word or popup.lookupword)
    if word == '' then return end
    local imported = false
    local ok, err = withDB(function(db)
        local oldRows = readRows(db,
            'SELECT word,dictionary,source_word,result_signature,scroll_kind,'
            .. 'scroll_number,scroll_ratio,updated_at FROM saved_meanings_spots '
            .. 'WHERE locked=1 AND word=' .. quote(word) .. ';')
        for _, old in ipairs(oldRows) do
            local candidates, matching = {}, {}
            for i = 1, #popup.results do
                local r = identityAt(popup, i)
                if r and r.dictionary == old.dictionary
                   and r.source_word == normalize(old.source_word) then
                    candidates[#candidates + 1] = r
                    if r.signature == old.result_signature then
                        matching[#matching + 1] = r
                    end
                end
            end
            local chosen
            if #matching == 1 then
                chosen = matching[1]
            elseif #candidates == 1 then
                chosen = candidates[1]
            end
            if chosen then
                if not getRow(db, chosen) then
                    upsert(db, chosen, old.scroll_kind, tonumber(old.scroll_number),
                        tonumber(old.scroll_ratio), true, tonumber(old.updated_at))
                end
                unsetLegacy(db, old)
                imported = true
            end
        end
        return true
    end)
    if imported then popup._dict_position_lock_v4_cache = nil end
    if not ok and err then warn('Legacy migration: ' .. err) end
end
local function getStatus(popup)
    local r = current(popup)
    if not r then return false end
    local k = key(r)
    local cache = popup._dict_position_lock_v4_cache
    if cache and cache[k] ~= nil then return cache[k] end
    local row, err = withDB(function(db) return getRow(db, r) or false end)
    if err then return false end
    cache = cache or {}
    popup._dict_position_lock_v4_cache = cache
    cache[k] = row
    return row
end
local function buttonText(popup)
    return isLocked(getStatus(popup)) and '🔓' or '🔒'
end
local function refreshButton(popup)
    if not popup or not popup.button_table then return end
    local t = popup.button_table
    local b = t.getButtonById and t:getButtonById(BUTTON_ID)
    if not b then return end
    -- This is the ONLY button owned by this patch.  Suppress its momentary
    -- inverted e-ink feedback when the Flashcards companion is installed.
    b._vocab_no_feedback = true
    b:setText(buttonText(popup), b.width)
    if b.refresh then pcall(b.refresh, b) end
    if UIManager.setDirty then
        UIManager:setDirty(popup, function() return 'ui', t.dimen end)
    end
end

local function capturePosition(popup)
    local scroll, content
    if popup._getScrollAndContentWidgets then
        scroll, content = popup:_getScrollAndContentWidgets()
    end
    scroll = scroll or popup.text_widget
    content = content or (scroll and (scroll.htmlbox_widget or scroll.text_widget))
    if not scroll or not content then return nil end
    if popup.is_html then
        local n = math.max(1, tonumber(content.page_number) or 1)
        local pages = math.max(1, tonumber(content.page_count) or 1)
        return 'html_page', n, math.min(1, math.max(0, (n-1) / pages))
    end
    local n = math.max(1, tonumber(content.virtual_line_num) or 1)
    local count = content.getAllLineCount and content:getAllLineCount() or n
    local visible = content.getVisLineCount and content:getVisLineCount() or 1
    local last = math.max(1, (tonumber(count) or n) - (tonumber(visible) or 1) + 1)
    return 'text_line', n, math.min(1, math.max(0, (n-1)/math.max(1, last-1)))
end
local function restorePosition(popup, row)
    if not isLocked(row) then return end
    local scroll, content
    if popup._getScrollAndContentWidgets then
        scroll, content = popup:_getScrollAndContentWidgets()
    end
    scroll = scroll or popup.text_widget
    content = content or (scroll and (scroll.htmlbox_widget or scroll.text_widget))
    if not scroll or type(scroll.scrollToRatio) ~= 'function' or not content then return end
    local n = math.max(1, tonumber(row.scroll_number) or 1)
    if row.scroll_kind == 'html_page' and popup.is_html then
        local pages = math.max(1, tonumber(content.page_count) or 1)
        n = math.min(n, pages)
        scroll:scrollToRatio((n-1)/pages)
    elseif row.scroll_kind == 'text_line' and not popup.is_html then
        local count = content.getAllLineCount and content:getAllLineCount() or n
        local visible = content.getVisLineCount and content:getVisLineCount() or 1
        local last = math.max(1, (tonumber(count) or n) - (tonumber(visible) or 1) + 1)
        scroll:scrollToRatio((math.min(n,last)-1)/math.max(1,last-1))
    end
end
local function rememberCurrent(popup)
    local r = current(popup)
    if not r then return end
    local expectedIndex, expectedKey = popup.dict_index, key(r)
    if not UIManager.scheduleIn then return end
    UIManager:scheduleIn(0.05, function()
        if popup._dict_position_lock_v4_closed or popup.dict_index ~= expectedIndex then return end
        local now = current(popup)
        if not now or key(now) ~= expectedKey then return end
        local row = getStatus(popup)
        if isLocked(row) then
            local ok, err = pcall(restorePosition, popup, row)
            if not ok then warn('Scroll restore failed: ' .. tostring(err)) end
        end
        refreshButton(popup)
    end)
end
local function toggle(popup)
    local r = current(popup)
    if not r then notify('No dictionary result selected.'); return end
    local kind, line, ratio = capturePosition(popup)
    local updated, err = withDB(function(db)
        local row = getRow(db, r)
        if isLocked(row) then
            -- A tombstone prevents old v3 locks from resurfacing on reopen.
            upsert(db, r, row.scroll_kind, tonumber(row.scroll_number),
                tonumber(row.scroll_ratio), false)
            return false
        end
        if not kind then error('Could not determine the visible scroll position') end
        upsert(db, r, kind, line, ratio, true)
        return {locked=1,scroll_kind=kind,scroll_number=line,scroll_ratio=ratio}
    end)
    if err then notify('Could not save lock: ' .. err); return end
    popup._dict_position_lock_v4_cache = popup._dict_position_lock_v4_cache or {}
    popup._dict_position_lock_v4_cache[key(r)] = updated
    refreshButton(popup)
    notify(updated and 'Position locked and saved.' or 'Position unlocked and saved.')
end

local function latestLockedIndex(popup)
    local word = normalize(popup.word or popup.lookupword)
    if word == '' then return nil end
    local rows, err = withDB(function(db)
        return readRows(db, 'SELECT word,dictionary,source_word,occurrence,updated_at '
            .. 'FROM dictionary_position_locks_v4 WHERE locked=1 AND word='
            .. quote(word) .. ' ORDER BY updated_at DESC, rowid DESC LIMIT 128;')
    end)
    if err then return nil end
    for _, saved in ipairs(rows or {}) do
        for i = 1, #popup.results do
            local r = identityAt(popup, i)
            if r and r.dictionary == saved.dictionary
                and r.source_word == saved.source_word
                and r.occurrence == tonumber(saved.occurrence) then
                return i
            end
        end
    end
end
local function registerButton(dict)
    if not dict or type(dict.addToDictButtons) ~= 'function' then return end
    if dict._dict_buttons then
        for _, id in ipairs({
            'saved_meanings_menu', 'saved_meanings_save', 'saved_meanings_list',
            'saved_meanings_spot', 'dictionary_pins_v2', 'dictionary_position_lock_v3',
        }) do dict._dict_buttons[id] = nil end
    end
    if dict._flipside_dictionary_position_lock_v4_registered then return end
    dict._flipside_dictionary_position_lock_v4_registered = true
    dict:addToDictButtons{
        id=BUTTON_ID, conditional=true, row_group=BUTTON_ID,
        text='🔒', text_func=buttonText,
        show_func=function(p) return not p.is_wiki end,
        callback=toggle,
    }
end

local nativeInit = DictQuickLookup.init
local nativeShow = DictQuickLookup.onShow
local nativeChange = DictQuickLookup.changeDictionary
local nativeClose = DictQuickLookup.onClose

function DictQuickLookup:init(...)
    if not self.is_wiki and self.ui and self.ui.dictionary then
        local ok, err = pcall(registerButton, self.ui.dictionary)
        if not ok then warn('Button registration failed: ' .. tostring(err)) end
    end
    local result = nativeInit(self, ...)
    if not self.is_wiki then refreshButton(self) end
    return result
end
function DictQuickLookup:onShow(...)
    local result
    if nativeShow then result = nativeShow(self, ...) end
    if self.is_wiki or self._dict_position_lock_v4_started then return result end
    self._dict_position_lock_v4_started = true
    -- Defer until KOReader has completed its own popup initialization.
    UIManager:scheduleIn(0.05, function()
        if self._dict_position_lock_v4_closed then return end
        importLegacy(self)
        local initial = self.dict_index
        -- Honor explicit result selections (e.g. a temporary large window).
        if initial == 1 then
            local index = latestLockedIndex(self)
            if index and index ~= initial then
                self:changeDictionary(index)
                return -- changeDictionary schedules restoration
            end
        end
        refreshButton(self)
        rememberCurrent(self)
    end)
    return result
end
function DictQuickLookup:changeDictionary(index, ...)
    local result = nativeChange(self, index, ...)
    if not self.is_wiki and self.button_table then
        refreshButton(self)
        rememberCurrent(self)
    end
    return result
end
function DictQuickLookup:onClose(...)
    self._dict_position_lock_v4_closed = true
    if nativeClose then return nativeClose(self, ...) end
end


-- CLOUD STORAGE SYNC ---------------------------------------------------------
-- This deliberately syncs a text snapshot, NOT the in-use SQLite database.
-- A locked=0 record is a permanent tombstone: a previously shared lock must
-- not reappear after a different device has removed it.
local SYNC_HEADER = 'KOReader-Dictionary-Position-Lock-Sync\t2'
local sync_settings
local function getSyncSettings()
    if not sync_settings then
        sync_settings = LuaSettings:open(SYNC_SETTINGS_PATH)
    end
    return sync_settings
end
local function percentEncode(value)
    return tostring(value or ''):gsub('%%', '%%25')
        :gsub('\t', '%%09'):gsub('\r', '%%0D'):gsub('\n', '%%0A'):gsub('%z', '%%00')
end
local function percentDecode(value)
    if value:find('%%[^%x]') or value:find('%%$') or value:find('%%[%x][^%x]') then
        error('Invalid escaping in cloud sync file')
    end
    return (value:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end
local function syncKey(r)
    return table.concat({r.word, r.dictionary, r.source_word, tostring(r.occurrence)}, '\0')
end
-- Local records may predate v5 cloud sync. In particular, locks migrated from
-- older Saved Meanings versions can have scroll_kind='', scroll_number=0 or
-- a ratio >1. These are still valid lock/tombstone identities: normalize
-- their *transport representation* without discarding or overwriting the DB.
-- Remote data must remain strict, so a damaged/corrupt cloud file cannot wipe
-- or silently modify local locks.
local function normalizeSyncRecord(r, fromLocal)
    local occurrence = tonumber(r.occurrence)
    local line = tonumber(r.scroll_number)
    local ratio = tonumber(r.scroll_ratio)
    local timestamp = tonumber(r.updated_at)
    local lock = tonumber(r.locked)
    local kind = tostring(r.scroll_kind or '')
    local function fail(field)
        error('Invalid ' .. (fromLocal and 'local' or 'cloud')
            .. ' dictionary sync record (' .. field .. ')', 2)
    end
    if type(r.word) ~= 'string' or r.word == ''
       or type(r.dictionary) ~= 'string' or type(r.source_word) ~= 'string' then
        fail('word/dictionary')
    end
    if not occurrence or occurrence < 1 or occurrence > 100000
       or occurrence % 1 ~= 0 then fail('occurrence') end
    if not timestamp or timestamp < 0 or timestamp > 9999999999999
       or timestamp % 1 ~= 0 then fail('updated_at') end
    if lock ~= 0 and lock ~= 1 then fail('locked') end
    -- The empty kind is a legitimate legacy value, notably when the item was
    -- previously unlocked. It cannot restore a scroll offset but must sync
    -- to propagate a deletion and preserve existing locked meanings.
    if kind ~= '' and kind ~= 'html_page' and kind ~= 'text_line' then
        fail('scroll_kind')
    end
    if fromLocal then
        -- Normalize *only for transfer*. v4 continues using its own original
        -- position data; don't edit it or fabricate a definition type.
        if not line or line ~= line then line = 1 end
        line = math.max(1, math.min(100000000, math.floor(line)))
        if not ratio or ratio ~= ratio then ratio = 0 end
        ratio = math.max(0, math.min(1, ratio))
    else
        if not line or line < 1 or line > 100000000
           or line % 1 ~= 0 then fail('scroll_number') end
        if not ratio or ratio ~= ratio or ratio < 0 or ratio > 1 then
            fail('scroll_ratio')
        end
    end
    return {
        word=r.word, dictionary=r.dictionary, source_word=r.source_word,
        occurrence=occurrence, scroll_kind=kind, scroll_number=line,
        scroll_ratio=ratio, locked=lock, updated_at=timestamp,
    }
end

local function recordText(r)
    return table.concat({
        percentEncode(r.word), percentEncode(r.dictionary), percentEncode(r.source_word),
        tostring(r.occurrence), r.scroll_kind, tostring(r.scroll_number),
        string.format('%.12f', r.scroll_ratio), tostring(r.locked), tostring(r.updated_at),
    }, '\t')
end
local function prefer(a, b)
    if not a then return b end
    if not b then return a end
    if a.updated_at ~= b.updated_at then
        return a.updated_at > b.updated_at and a or b
    end
    -- A deletion wins a same-second conflict. Non-deletion ties are sorted
    -- deterministically so two devices converge even if timestamps tie.
    if a.locked ~= b.locked then return a.locked == 0 and a or b end
    return recordText(a) >= recordText(b) and a or b
end
local function recordsToMap(rows, fromLocal)
    local result = {}
    for _, row in ipairs(rows) do
        local r = normalizeSyncRecord(row, fromLocal)
        local k = syncKey(r)
        result[k] = prefer(result[k], r)
    end
    return result
end
local function readSnapshot(path)
    local file, open_err = io.open(path, 'rb')
    if not file then
        -- The transport confirmed HTTP 200: a missing/unreadable body is a
        -- download failure, NEVER equivalent to an empty remote snapshot.
        error('HTTP 200 but downloaded cloud file is unreadable: ' .. tostring(open_err))
    end
    local content = file:read(16 * 1024 * 1024 + 1) or ''
    file:close()
    if not content or #content > 16 * 1024 * 1024 then error('Cloud snapshot too large') end
    local lines = {}
    for line in (content .. '\n'):gmatch('(.-)\n') do
        lines[#lines + 1] = line
    end
    -- This parser is used ONLY for a confirmed HTTP 200 response. The
    -- transport distinguishes a genuine 404 from 200; never guess from an
    -- error page whether a remote file is absent.
    local header = (lines[1] or ''):gsub('^\239\187\191', ''):gsub('\r$', '')
    if header ~= SYNC_HEADER then
        error('Remote file exists but is not a compatible dictionary snapshot; not overwritten')
    end
    local rows = {}
    for i = 2, #lines do
        local line = lines[i]:gsub('\r$', '')
        if line ~= '' then
            if #line > 40000 then error('Oversized cloud snapshot row') end
            local fields = {}
            for part in (line .. '\t'):gmatch('(.-)\t') do
                fields[#fields + 1] = part
            end
            if #fields ~= 9 then error('Invalid cloud snapshot columns') end
            rows[#rows + 1] = {
                word=percentDecode(fields[1]), dictionary=percentDecode(fields[2]),
                source_word=percentDecode(fields[3]), occurrence=fields[4],
                scroll_kind=fields[5], scroll_number=fields[6],
                scroll_ratio=fields[7], locked=fields[8], updated_at=fields[9],
            }
            if #rows > 100000 then error('Too many cloud snapshot rows') end
        end
    end
    return recordsToMap(rows)
end
local function sortedMapRows(map)
    local keys, rows = {}, {}
    for k in pairs(map) do keys[#keys+1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do rows[#rows+1] = map[k] end
    return rows
end
local function writeSnapshot(path, map)
    local tmp = path .. '.new'
    local out, err = io.open(tmp, 'wb')
    if not out then error(err or 'Cannot write sync snapshot') end
    local ok, write_err = pcall(function()
        assert(out:write(SYNC_HEADER, '\n'))
        for _, row in ipairs(sortedMapRows(map)) do
            assert(out:write(recordText(row), '\n'))
        end
        assert(out:flush())
    end)
    out:close()
    if not ok then
        os.remove(tmp)
        error(write_err, 0)
    end
    local renamed, rename_err = os.rename(tmp, path)
    if not renamed then
        os.remove(tmp)
        error(rename_err or 'Could not commit cloud snapshot')
    end
end
local function readDatabaseMap()
    local rows, err = withDB(function(db)
        return readRows(db, [[SELECT word, dictionary, source_word, occurrence,
            scroll_kind, scroll_number, scroll_ratio, locked, updated_at
            FROM dictionary_position_locks_v4;]])
    end)
    if err then error(err) end
    return recordsToMap(rows, true)
end
local function mergeRecords(local_rows, remote_rows)
    local merged = {}
    for k, r in pairs(local_rows) do merged[k] = r end
    for k, r in pairs(remote_rows) do merged[k] = prefer(merged[k], r) end
    return merged
end
local function importMergedDatabase(map)
    local ok, err = withDB(function(db)
        local begun = db:exec('BEGIN IMMEDIATE;')
        if begun == false then error('Could not start SQLite transaction') end
        local inserted, insert_err = pcall(function()
            for _, r in ipairs(sortedMapRows(map)) do
                local original = getRow(db, r)
                if not original or recordText(normalizeSyncRecord({
                        word=r.word, dictionary=r.dictionary, source_word=r.source_word,
                        occurrence=r.occurrence, scroll_kind=original.scroll_kind,
                        scroll_number=original.scroll_number, scroll_ratio=original.scroll_ratio,
                        locked=original.locked, updated_at=original.updated_at,
                    }, true)) ~= recordText(r) then
                    upsert(db, r, r.scroll_kind, r.scroll_number, r.scroll_ratio,
                        r.locked == 1, r.updated_at)
                end
            end
        end)
        if not inserted then
            db:exec('ROLLBACK;')
            error(insert_err, 0)
        end
        if db:exec('COMMIT;') == false then
            db:exec('ROLLBACK;')
            error('Could not commit synced positions')
        end
        return true
    end)
    if err or not ok then error(err or 'Could not import synced positions') end
end
-- Cloud:sync() hands its callback a temporary file but NOT the HTTP status.
-- On a 404/409, some providers write an arbitrary error body to this temp file.
-- Trying to infer that status from an HTML/JSON error string caused v5.0-v5.3
-- to reject valid first synchronizations. Use the same Cloud Storage provider
-- API directly, and inspect the actual status before opening the downloaded
-- file. Never overwrite a confirmed HTTP 200 remote file with invalid data.
local sync_running = false
local function syncTransport(server, provider)
    local temp = SYNC_PATH .. '.temp'
    local remote_name = SYNC_PATH:match('[^/]+$')
    local remote_url = (server.url or ''):gsub('/+$', '') .. '/' .. remote_name
    local merged, upload_code
    local function cleanTemp() os.remove(temp) end
    for attempt = 1, 4 do
        cleanTemp()
        local status, etag = provider.downloadFile(remote_url, temp)
        local incoming
        if status == 200 then
            incoming = readSnapshot(temp) -- strict check; 200 HTML is NOT a new file
        elseif status == 404 or (server.type == 'ftp' and status == 550) then
            incoming = {} -- verified missing, ignore HTTP error body in .temp
        elseif server.type == 'dropbox' and status == 409 then
            -- Dropbox also uses 409 for other errors. Confirm actual not-found.
            local f = io.open(temp, 'rb')
            local body = f and f:read(8192) or ''
            if f then f:close() end
            if not body:match('"error_summary"%s*:%s*"path/not_found') then
                error('Dropbox 409, but not a file-not-found response; upload canceled')
            end
            incoming = {}
        else
            error('Cloud download failed (HTTP ' .. tostring(status) .. '); upload canceled')
        end
        -- Our local snapshot is already refreshed immediately before sync.
        -- Byte identity means neither device has anything new to exchange.
        if status == 200
                and require("lib.sync.flipside_sync_utils").sameFile(temp, SYNC_PATH) then
            cleanTemp()
            return #sortedMapRows(incoming)
        end
        cleanTemp()
        -- Merge from the live database on EACH retry. A concurrent writer may
        -- have advanced the remote snapshot; do not push a stale copy.
        local local_rows = readDatabaseMap()
        merged = mergeRecords(local_rows, incoming)
        writeSnapshot(SYNC_PATH, merged)
        upload_code = provider.uploadFile(server.url, SYNC_PATH, etag, true)
        if type(upload_code) == 'number' and upload_code >= 200 and upload_code < 300 then
            -- Commit locally ONLY after remote upload has succeeded. Tombstones
            -- in this same map carry remote unlocks back to this device.
            importMergedDatabase(merged)
            return #sortedMapRows(merged)
        end
        if upload_code ~= 412 then
            error('Cloud upload failed (HTTP ' .. tostring(upload_code)
                .. '); local database unchanged')
        end
    end
    error('Cloud file changed repeatedly (HTTP 412); try syncing again')
end
local function startCloudSync(server, provider, completion, silent)
    -- Cloud Storage's own provider runner handles credentials and online state.
    -- Keep its behavior; replace only the download/merge/upload bridge.
    provider.base = require('util').tableDeepCopy(server)
    provider.run(function()
        UIManager:nextTick(function()
            if sync_running then
                if completion then completion(false, 'Dictionary sync already in progress')
                elseif not silent then notify('Dictionary sync already in progress.') end
                return
            end
            sync_running = true
            local ok, result = pcall(syncTransport, server, provider)
            sync_running = false
            os.remove(SYNC_PATH .. '.temp')
            if ok then
                if completion then completion(true, tostring(result) .. ' records')
                elseif not silent then notify('Dictionary positions synchronized (' .. tostring(result) .. ' records).') end
            else
                warn('Cloud sync: ' .. tostring(result))
                local message = tostring(result):gsub('^.-%.lua:%d+:%s*', '')
                if completion then completion(false, message)
                elseif not silent then UIManager:show(InfoMessage:new{
                    text='Dictionary sync stopped:\n' .. message,
                    timeout=7,
                }) end
            end
        end)
    end)
end
local function getCloudService(ui)
    local cloud = ui and ui.cloudstorage
    if cloud and type(cloud.providers) == "table" then return cloud end
    local ok, loader = pcall(require, "pluginloader")
    if ok and loader and type(loader.getPluginInstance) == "function" then
        local found, live = pcall(loader.getPluginInstance, loader, "cloudstorage")
        if found and live and type(live.providers) == "table" then return live end
    end
    return nil
end
local function selectCloudFolder(ui, completion)
    local cloud = getCloudService(ui)
    if not cloud or not cloud.onShowCloudStorageList then
        notify('Enable the KOReader Cloud storage plugin first.')
        return true
    end
    cloud:onShowCloudStorageList(function(server)
        if not server or not server.url or not server.type then return end
        local config = getSyncSettings()
        local previous = config:readSetting('server')
        if previous and (previous.type ~= server.type or previous.address ~= server.address
            or previous.url ~= server.url or previous.username ~= server.username) then
            os.remove(SYNC_PATH .. '.sync') -- cloud transport's former 3-way cache
        end
        config:saveSetting('server', server)
        config:flush()
        if completion then completion(true, server)
        else notify('Dictionary cloud folder saved.') end
    end)
    return true
end
local function syncCloudPositions(ui, completion, silent)
    local function fail(message)
        if completion then completion(false, message)
        elseif not silent then notify(message) end
        return true
    end
    local cloud = getCloudService(ui)
    if not cloud or not cloud.providers then
        return fail('Enable the KOReader Cloud storage plugin first.')
    end
    local server = getSyncSettings():readSetting('server')
    if not server or not server.type or not server.url then
        if completion then
            return fail('Choose the cloud folder for dictionary positions first.')
        end
        notify('Select the cloud folder for dictionary positions.')
        return selectCloudFolder(ui)
    end
    if not cloud.providers or not cloud.providers[server.type] then
        return fail('The selected cloud storage provider is not available.')
    end
    local ok, err = pcall(function()
        writeSnapshot(SYNC_PATH, readDatabaseMap())
    end)
    if not ok then
        warn('Cannot prepare cloud sync: ' .. tostring(err))
        return fail('Could not prepare dictionary sync: ' .. tostring(err))
    end
    local provider = cloud.providers[server.type]
    local started, start_err = pcall(startCloudSync, server, provider, completion, silent)
    if not started then
        warn('Could not start cloud sync: ' .. tostring(start_err))
        return fail('Could not start dictionary sync: ' .. tostring(start_err))
    end
    return true
end
-- Gesture registration moved to the single FlipSide Sync all action.
-- Keep these independent settings and transport functions for the Sync page.
-- End cloud sync -------------------------------------------------------------

logger.info('Dictionary Position Lock v5.4 with HTTP-status-aware cloud sync loaded')

-- Standalone dictionary sync with asynchronous completion.
return { syncNow = syncCloudPositions, chooseFolder = selectCloudFolder,
    getFolder = function() return getSyncSettings():readSetting('server') end }
