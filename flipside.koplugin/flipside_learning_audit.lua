--[[
Vocabulary Builder - Learning Audit v2.14.23 (fix actions disabled in FileManager)
Original v2.7 Learning Audit database and all native KOReader data are preserved.
Imported reviews live ONLY in a separate manual-sync SQLite database.
Install as: koreader/patches/2-vocabulary-builder-learning-audit.lua

Only the Vocabulary Builder database is used for reading words and confirming
native Undo. Learning history lives in a separate SQLite file. The old
vocabulary_builder_learning_audit.lua settings file is preserved as a read-only
baseline; it is not removed or overwritten.

Learning categories, deletion/reset, scheduling and native KOReader data
are preserved. Statistics view shows saved answers by day and recorded model.
Accuracy summaries use validated, persistent, automatically invalidated cache.
]]

local userpatch = require("flipside_compat")
local logger = require("logger")
local Diag = require("flipside_diagnostics")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local LineWidget = require("ui/widget/linewidget")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Size = require("ui/size")
local ButtonTable = require("ui/widget/buttontable")
local Font = require("ui/font")
local util = require("util")
local _ = require("gettext")

-- Tag only Audit-owned windows for Flashcards' scoped e-ink feedback.
-- No global reader setting or touch behavior is changed by this patch.
local function showAuditWidget(widget, ...)
    if type(widget) == "table" then
        widget._vocab_no_flash_surface = true
    end
    return UIManager:show(widget, ...)
end

local VERSION = "2.14.23"
local REQUIRED = 5
local GAP = 20 * 60 * 60
local DIR = DataStorage:getSettingsDir() .. "/flipside"
local DB_PATH = DIR .. "/vocabulary_builder_learning_audit.sqlite3"
local JOURNAL_PATH = DIR .. "/vocabulary_builder_learning_audit.pending"
local old_settings = LuaSettings:open(DIR .. "/vocabulary_builder_learning_audit.lua")
local legacy = old_settings:readSetting("records", {})
if type(legacy) ~= "table" then legacy = {} end

local function warn(...)
    logger.warn("[Vocabulary Learning Audit v2]", ...)
end

local function copy(src)
    local out = {}
    if type(src) == "table" then
        for k, v in pairs(src) do
            if type(v) == "table" then
                local t = {}
                for i, x in ipairs(v) do t[i] = x end
                out[k] = t
            else out[k] = v end
        end
    end
    return out
end

local function trimWord(word)
    return type(word) == "string" and word ~= "" and word or nil
end

local function sqlRows(conn, sql)
    local rows = conn:exec(sql)
    return type(rows) == "table" and rows or {}
end

local function sqlQuote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local schema = [[
CREATE TABLE IF NOT EXISTS audit_events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  event_key TEXT NOT NULL UNIQUE,
  word TEXT NOT NULL,
  review_time INTEGER NOT NULL,
  got INTEGER NOT NULL,
  undone INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  review_mode TEXT NOT NULL DEFAULT 'unknown'
);
CREATE INDEX IF NOT EXISTS audit_events_word ON audit_events(word, seq);
CREATE TABLE IF NOT EXISTS audit_archived_words (word TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS audit_undo_ops (op_key TEXT PRIMARY KEY, event_seq INTEGER NOT NULL);
-- Reset events are masked, not deleted, to avoid losing a recovery trail.
CREATE TABLE IF NOT EXISTS audit_hidden_events (event_seq INTEGER PRIMARY KEY, cleared_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS audit_legacy_excluded (word TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS audit_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
]]

-- Private cache-revision counters. KOReader's ljsqlite3 exec splits
-- statements on semicolons; CREATE TRIGGER contains a semicolon inside BEGIN
-- ... END, and therefore fails with "incomplete input" when sent through
-- conn:exec(schema). Prepare each complete trigger individually instead.
-- Existing history tables and contents are never rebuilt or cleared here.
local function ensureAccuracyRevisionTriggers(db, remote)
    local prefix = remote and "synced" or "audit"
    local revision = prefix .. "_accuracy_revision"
    db:exec("CREATE TABLE IF NOT EXISTS " .. revision
        .. " (id INTEGER PRIMARY KEY CHECK(id=1),"
        .. " revision INTEGER NOT NULL DEFAULT 0);")
    db:exec("INSERT OR IGNORE INTO " .. revision
        .. " (id, revision) VALUES(1, 0);")
    local tables = remote and { "synced_events" } or {
        "audit_events", "audit_hidden_events", "audit_archived_words",
        "audit_legacy_excluded", "audit_meta",
    }
    local table_suffix = {
        audit_events = "events", audit_hidden_events = "hidden",
        audit_archived_words = "archive", audit_legacy_excluded = "legacy",
        audit_meta = "meta", synced_events = "events",
    }
    for _, table_name in ipairs(tables) do
        local base = prefix .. "_accuracy_" .. table_suffix[table_name]
        for _, action in ipairs({{"i", "INSERT"}, {"u", "UPDATE"}, {"d", "DELETE"}}) do
            local sql = "CREATE TRIGGER IF NOT EXISTS " .. base .. "_" .. action[1]
                .. " AFTER " .. action[2] .. " ON " .. table_name
                .. " BEGIN UPDATE " .. revision
                .. " SET revision=revision+1 WHERE id=1; END;"
            local stmt = db:prepare(sql)
            if not stmt then error("Cannot prepare accuracy revision trigger: " .. base) end
            local ok, err = pcall(function() stmt:step() end)
            pcall(stmt.close, stmt)
            if not ok then error(err, 0) end
        end
    end
end

-- Add a nullable-by-history column once, preserving all previously saved events.
-- Existing rows have no trustworthy review-mode information.
local function ensureReviewModeColumn(db, table_name)
    assert(table_name == "audit_events" or table_name == "synced_events")
    local rows = sqlRows(db, "PRAGMA table_info(" .. table_name .. ");")
    for _, name in ipairs(rows.name or {}) do
        if name == "review_mode" then return end
    end
    db:exec("ALTER TABLE " .. table_name
        .. " ADD COLUMN review_mode TEXT NOT NULL DEFAULT 'unknown';")
end

local schema_ready = false
local function withDB(fn)
    local conn
    local ok, result = pcall(function()
        conn = SQ3.open(DB_PATH)
        if not schema_ready then
            conn:exec(schema)
            ensureReviewModeColumn(conn, "audit_events")
            local tracked, tracking_err = pcall(ensureAccuracyRevisionTriggers, conn, false)
            if not tracked then
                warn("Accuracy cache tracking unavailable (local):", tracking_err)
                Diag.report("WARNING", "LEARNING_AUDIT_CACHE_FAILED", {stage="local"}, tracking_err)
            end
            schema_ready = true
        end
        return fn(conn)
    end)
    if conn then pcall(conn.close, conn) end
    if not ok then
        Diag.report("ERROR", "LEARNING_AUDIT_DB_FAILED", {stage="local"}, result)
        return nil, tostring(result)
    end
    return result, nil
end

local function execute(conn, sql, ...)
    local stmt = conn:prepare(sql)
    if not stmt then error("SQLite prepare failed") end
    local nparams = select("#", ...)
    local params = { ... }
    local ok, err = pcall(function()
        if nparams > 0 then stmt:bind(unpack(params, 1, nparams)) end
        stmt:step()
    end)
    pcall(stmt.close, stmt)
    if not ok then error(err, 0) end
end

--[[ MANUAL SYNC -- independent extension to the ORIGINAL v2.7.
This is deliberately NOT a migration of the abandoned v2.8 sync patch.
The original Learning Audit DB is never modified by import. Its locally
recorded reviews, resets, Undo and legacy baseline retain their own tables.
Foreign review events and visibility overlays live in a separate database.
Only the Learning Analysis VIEW merges both sources by immutable event_key.
The stock vocabulary_builder.sqlite3 DB is never opened by this module.
]]
local SYNC_DIR = DIR .. "/learning_audit_manual_exchange_v1"
local SYNC_DB_PATH = DIR .. "/vocabulary_builder_learning_audit_remote_v1.sqlite3"
local SYNC_EXPORT = SYNC_DIR .. "/export.laex1"
local SYNC_IMPORT = SYNC_DIR .. "/import.laex1"
-- Read both exchange generations; v2 carries the answer mode of each event.
-- The existing .laex1 filenames and cloud path remain unchanged.
local SYNC_MAGIC_V1 = "LEARNING_AUDIT_MANUAL_EXCHANGE_V1"
local SYNC_MAGIC = "LEARNING_AUDIT_MANUAL_EXCHANGE_V2"
local function normalizeReviewMode(mode)
    return (mode == "meaning" or mode == "contextual" or mode == "sentence")
        and mode or "unknown"
end
local function encodeReviewMode(mode)
    mode = normalizeReviewMode(mode)
    return mode == "meaning" and "M" or mode == "contextual" and "C"
        or mode == "sentence" and "S" or "U"
end
local function decodeReviewMode(code)
    return code == "M" and "meaning" or code == "C" and "contextual"
        or code == "S" and "sentence" or "unknown"
end
local SYNC_LIMIT = 16 * 1024 * 1024  -- protect small Kindle memory
local SYNC_EVENT_LIMIT = 90000
local sync_schema = [[
CREATE TABLE IF NOT EXISTS synced_events (
  event_key TEXT PRIMARY KEY,
  word TEXT NOT NULL,
  review_time INTEGER NOT NULL,
  got INTEGER NOT NULL,
  undone INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  hidden INTEGER NOT NULL DEFAULT 0,
  review_mode TEXT NOT NULL DEFAULT 'unknown'
);
CREATE INDEX IF NOT EXISTS synced_events_word ON synced_events(word, review_time);
]]
local sync_schema_ready = false
local function withSyncDB(fn)
    local conn
    local ok, result = pcall(function()
        conn = SQ3.open(SYNC_DB_PATH)
        if not sync_schema_ready then
            conn:exec(sync_schema)
            ensureReviewModeColumn(conn, "synced_events")
            local tracked, tracking_err = pcall(ensureAccuracyRevisionTriggers, conn, true)
            if not tracked then
                warn("Accuracy cache tracking unavailable (sync):", tracking_err)
                Diag.report("WARNING", "LEARNING_AUDIT_CACHE_FAILED", {stage="sync"}, tracking_err)
            end
            sync_schema_ready = true
        end
        return fn(conn)
    end)
    if conn then pcall(conn.close, conn) end
    if not ok then
        Diag.report("ERROR", "LEARNING_AUDIT_DB_FAILED", {stage="sync"}, result)
        return nil, tostring(result)
    end
    return result, nil
end

local function syncEncode(s)
    return (tostring(s):gsub("[^%w%-_%.]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end
local function syncDecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
local function syncFlag(x)
    return tonumber(x) == 1 and 1 or 0
end
local function syncAdler32(data)
    -- Change-detection checksum, not a cryptographic authentication code.
    local a, b = 1, 0
    for i = 1, #data do
        a = (a + data:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%08X", b * 65536 + a)
end
local function syncEventRows(rows)
    local events = {}
    for i, key in ipairs(rows.event_key or {}) do
        events[#events + 1] = {
            event_key = tostring(key),
            word = tostring((rows.word or {})[i] or ""),
            review_time = tonumber((rows.review_time or {})[i]) or 0,
            got = syncFlag((rows.got or {})[i]),
            undone = syncFlag((rows.undone or {})[i]),
            archived = syncFlag((rows.archived or {})[i]),
            hidden = syncFlag((rows.hidden or {})[i]),
            review_mode = normalizeReviewMode((rows.review_mode or {})[i]),
            seq = tonumber((rows.seq or {})[i]),
        }
    end
    return events
end
local function syncLocalEvents(word)
    return withDB(function(db)
        local query = [[SELECT e.seq AS seq, e.event_key AS event_key,
            e.word AS word, e.review_time AS review_time, e.got AS got,
            e.undone AS undone, e.archived AS archived,
            CASE WHEN h.event_seq IS NULL THEN 0 ELSE 1 END AS hidden,
            e.review_mode AS review_mode
            FROM audit_events e LEFT JOIN audit_hidden_events h ON h.event_seq=e.seq]]
        if word then query = query .. " WHERE e.word=" .. sqlQuote(word) end
        return syncEventRows(sqlRows(db, query .. ";"))
    end)
end
local function syncRemoteEvents(word)
    return withSyncDB(function(db)
        local query = [[SELECT event_key, word, review_time, got, undone,
            archived, hidden, review_mode FROM synced_events]]
        if word then query = query .. " WHERE word=" .. sqlQuote(word) end
        return syncEventRows(sqlRows(db, query .. ";"))
    end)
end
local function syncSameIdentity(a, b)
    return a.word == b.word and a.review_time == b.review_time
        and a.got == b.got
end
local function syncMergeLists(local_events, remote_events)
    local map, combined = {}, {}
    for _, event in ipairs(local_events) do
        map[event.event_key] = event
        combined[#combined + 1] = event
    end
    for _, event in ipairs(remote_events) do
        local old = map[event.event_key]
        if old then
            if not syncSameIdentity(old, event) then
                return nil, "conflicting event identity: " .. event.event_key
            end
            old.undone = math.max(old.undone, event.undone)
            old.archived = math.max(old.archived, event.archived)
            old.hidden = math.max(old.hidden, event.hidden)
            if old.review_mode ~= "unknown" and event.review_mode ~= "unknown"
                and old.review_mode ~= event.review_mode then
                return nil, "conflicting recorded review mode: " .. event.event_key
            end
            if old.review_mode == "unknown" then
                old.review_mode = event.review_mode
            end
        else
            map[event.event_key] = event
            combined[#combined + 1] = event
        end
    end
    table.sort(combined, function(a, b)
        if a.review_time ~= b.review_time then return a.review_time < b.review_time end
        if a.seq and b.seq then return a.seq < b.seq end
        return a.event_key < b.event_key
    end)
    return combined
end
local function syncCollect(word, strict)
    local local_events, err = syncLocalEvents(word)
    if not local_events then return nil, err end
    local remote_events, sync_err = syncRemoteEvents(word)
    if not remote_events then
        if strict then return nil, sync_err end
        warn("Manual sync store not accessible; local history remains readable:", sync_err)
        return local_events
    end
    if #remote_events == 0 then
        -- With no imported events, retain the exact original v2.7 order:
        -- local SQLite insertion sequence, not wall-clock timestamps.
        table.sort(local_events, function(a, b)
            return (a.seq or 0) < (b.seq or 0)
        end)
        return local_events
    end
    local combined, conflict = syncMergeLists(local_events, remote_events)
    if not combined then
        if strict then return nil, conflict end
        warn("Manual sync collision; showing local history only:", conflict)
        return local_events
    end
    return combined
end
local function syncIsVisible(e)
    return e.undone == 0 and e.archived == 0 and e.hidden == 0
end
-- Local resets/word deletion must also suppress imported foreign events.
-- This operation touches only the separately owned sync database.
local function syncMark(word, from_time, before_time, column)
    assert(column == "hidden" or column == "archived")
    return withSyncDB(function(db)
        local q = "UPDATE synced_events SET " .. column .. "=1 WHERE 1=1"
        if word then q = q .. " AND word=" .. sqlQuote(word) end
        if from_time then q = q .. " AND review_time >= " .. math.floor(from_time) end
        if before_time then q = q .. " AND review_time < " .. math.floor(before_time) end
        db:exec(q .. ";")
        return true
    end)
end
local function syncRemotePreviewCount(word, from_time, before_time)
    local rows, err = syncCollect(word, true)
    if not rows then return nil, err end
    local n = 0
    for _, e in ipairs(rows) do
        if syncIsVisible(e) and (not from_time or e.review_time >= from_time)
            and (not before_time or e.review_time < before_time) then
            n = n + 1
        end
    end
    return n
end
-- The exchange folder NEVER reuses the old v2.8 import.lasync files.
local function syncEnsureFolder()
    local attr = lfs.attributes(SYNC_DIR)
    if attr then
        if attr.mode == "directory" then return true end
        return nil, "sync path is not a directory"
    end
    local ok, err = lfs.mkdir(SYNC_DIR)
    if not ok then return nil, tostring(err) end
    return true
end
local function syncSerialize(events)
    if #events > SYNC_EVENT_LIMIT then return nil, "too many review events" end
    local parts = {SYNC_MAGIC .. "\n"}
    for _, e in ipairs(events) do
        if #e.event_key > 400 or #e.word > 1200 or e.word == "" then
            return nil, "invalid or oversized word / event identifier"
        end
        parts[#parts + 1] = table.concat({"E", syncEncode(e.event_key),
            syncEncode(e.word), tostring(math.floor(e.review_time)),
            tostring(e.got), tostring(e.undone), tostring(e.archived),
            tostring(e.hidden), encodeReviewMode(e.review_mode)}, "\t") .. "\n"
    end
    local content = table.concat(parts)
    local text = content .. "END\t" .. tostring(#events) .. "\t"
        .. syncAdler32(content) .. "\n"
    if #text > SYNC_LIMIT then return nil, "export exceeds the 16 MB safety limit" end
    return text
end
local function syncParse(data)
    if type(data) ~= "string" or #data > SYNC_LIMIT then
        return nil, "file too large or unreadable"
    end
    local payload, footer = data:match("^(.-)(END\t%d+\t%x%x%x%x%x%x%x%x\n)$")
    if not payload or not footer then return nil, "incomplete sync file" end
    local count, digest = footer:match("^END\t(%d+)\t(%x+)\n$")
    count = tonumber(count)
    if not count or count > SYNC_EVENT_LIMIT then return nil, "event count exceeds limit" end
    if digest ~= syncAdler32(payload) then return nil, "checksum mismatch" end
    local old_format = payload:sub(1, #SYNC_MAGIC_V1 + 1) == SYNC_MAGIC_V1 .. "\n"
    if not old_format and payload:sub(1, #SYNC_MAGIC + 1) ~= SYNC_MAGIC .. "\n" then
        return nil, "unsupported learning-audit sync format"
    end
    local events, seen = {}, {}
    local body = payload:sub((old_format and #SYNC_MAGIC_V1 or #SYNC_MAGIC) + 2)
    for line in body:gmatch("([^\n]*)\n") do
        if line == "" then return nil, "blank review row" end
        local raw_key, raw_word, at, got, undone, archived, hidden, mode_code
        if old_format then
            raw_key, raw_word, at, got, undone, archived, hidden =
                line:match("^E\t([^\t]+)\t([^\t]+)\t(%d+)\t([01])\t([01])\t([01])\t([01])$")
            mode_code = "U"
        else
            raw_key, raw_word, at, got, undone, archived, hidden, mode_code =
                line:match("^E\t([^\t]+)\t([^\t]+)\t(%d+)\t([01])\t([01])\t([01])\t([01])\t([MCUS])$")
        end
        if not raw_key then return nil, "invalid review row" end
        local function validEncoded(part)
            if not part:match("^[%w%%%.%-%_]+$") then return false end
            return not part:gsub("%%%x%x", ""):find("%", 1, true)
        end
        if not validEncoded(raw_key) or not validEncoded(raw_word) then
            return nil, "invalid encoded word / identifier"
        end
        local event = {
            event_key = syncDecode(raw_key), word = syncDecode(raw_word),
            review_time = tonumber(at), got = tonumber(got),
            undone = tonumber(undone), archived = tonumber(archived),
            hidden = tonumber(hidden),
            review_mode = decodeReviewMode(mode_code),
        }
        if #event.event_key > 400 or event.event_key == ""
            or #event.word > 1200 or event.word == ""
            or not event.review_time or event.review_time > 10000000000 then
            return nil, "invalid event data"
        end
        if seen[event.event_key] then return nil, "duplicated event identifier in file" end
        seen[event.event_key] = true
        events[#events + 1] = event
    end
    if #events ~= count then return nil, "incomplete event list" end
    return events
end
local function syncReadFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, tostring(err) end
    local data = f:read(SYNC_LIMIT + 1)
    f:close()
    if not data then return nil, "could not read sync file" end
    local events, err = syncParse(data)
    if not events then return nil, err end
    return events, nil, syncAdler32(data)
end
local function syncWriteFile(path, data)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, tostring(err) end
    local written = f:write(data)
    local flushed = f:flush()
    local closed = f:close()
    if not written or not flushed or not closed then
        os.remove(tmp)
        return nil, "could not finish writing export"
    end
    local ok, rename_err = os.rename(tmp, path)
    if not ok then os.remove(tmp); return nil, tostring(rename_err) end
    return true
end
local function syncBackupStore()
    local f, err = io.open(SYNC_DB_PATH, "rb")
    if not f then return nil, "cannot read sync store: " .. tostring(err) end
    local target
    for i = 1, 999 do
        local name = SYNC_DIR .. "/remote-before-import-"
            .. os.date("%Y%m%d-%H%M%S") .. "-" .. i .. ".sqlite3.bak"
        local check = io.open(name, "rb")
        if check then check:close() else target = name; break end
    end
    if not target then f:close(); return nil, "backup directory is full" end
    local g, err2 = io.open(target, "wb")
    if not g then f:close(); return nil, tostring(err2) end
    local good = true
    while true do
        local chunk = f:read(32768)
        if not chunk then break end
        if not g:write(chunk) then good = false; break end
    end
    local flush = g:flush()
    local close = g:close()
    f:close()
    if not good or not flush or not close then
        os.remove(target)
        return nil, "could not copy sync-store backup"
    end
    -- Verify bytes from disk, not just the values in the write buffers.
    local original = io.open(SYNC_DB_PATH, "rb")
    local copy_file = io.open(target, "rb")
    if not original or not copy_file then
        if original then original:close() end
        if copy_file then copy_file:close() end
        os.remove(target)
        return nil, "cannot verify sync-store backup"
    end
    while true do
        local a = original:read(32768)
        local b = copy_file:read(32768)
        if a ~= b then good = false; break end
        if not a then break end
    end
    original:close()
    copy_file:close()
    if not good then
        os.remove(target)
        return nil, "sync-store backup verification failed"
    end
    return target
end
local function syncPreview(events)
    local current, err = syncCollect(nil, true)
    if not current then return nil, err end
    local map = {}
    for _, e in ipairs(current) do map[e.event_key] = e end
    local new, flags, existing = 0, 0, 0
    for _, e in ipairs(events) do
        local old = map[e.event_key]
        if old then
            if not syncSameIdentity(e, old) then
                return nil, "event ID collision (different review): " .. e.event_key
            end
            existing = existing + 1
            if e.review_mode ~= "unknown" and old.review_mode ~= "unknown"
                and e.review_mode ~= old.review_mode then
                return nil, "conflicting recorded review mode: " .. e.event_key
            end
            if e.undone > old.undone or e.archived > old.archived
                or e.hidden > old.hidden
                or (old.review_mode == "unknown" and e.review_mode ~= "unknown") then
                flags = flags + 1
            end
        else
            new = new + 1
        end
    end
    return {new = new, updated = flags, existing = existing, total = #events}
end
local function syncApply(events)
    -- Import only writes synced_events, never audit_events, Vocabulary Builder,
    -- the legacy v1 settings or the previous v2.8 exchange directory.
    return withSyncDB(function(db)
        db:exec("BEGIN IMMEDIATE;")
        local ok, result = pcall(function()
            for _, e in ipairs(events) do
                local old = sqlRows(db, "SELECT word, review_time, got, undone, archived, hidden, review_mode "
                    .. "FROM synced_events WHERE event_key=" .. sqlQuote(e.event_key) .. ";")
                local old_word = (old.word or {})[1]
                if old_word then
                    local old_event = {
                        word = tostring(old_word), review_time = tonumber((old.review_time or {})[1]),
                        got = syncFlag((old.got or {})[1]),
                    }
                    if not syncSameIdentity(old_event, e) then
                        error("conflicting event ID during import")
                    end
                    local old_mode = normalizeReviewMode((old.review_mode or {})[1])
                    if old_mode ~= "unknown" and e.review_mode ~= "unknown"
                        and old_mode ~= e.review_mode then
                        error("conflicting recorded review mode during import")
                    end
                    local merged_mode = old_mode == "unknown" and e.review_mode or old_mode
                    execute(db, [[UPDATE synced_events SET
                        undone=MAX(undone,?), archived=MAX(archived,?),
                        hidden=MAX(hidden,?), review_mode=? WHERE event_key=?;]],
                        e.undone, e.archived, e.hidden, merged_mode, e.event_key)
                else
                    execute(db, [[INSERT INTO synced_events
                        (event_key,word,review_time,got,undone,archived,hidden,review_mode)
                        VALUES (?,?,?,?,?,?,?,?);]], e.event_key, e.word,
                        e.review_time, e.got, e.undone, e.archived, e.hidden,
                        e.review_mode)
                end
            end
            return true
        end)
        if not ok then db:exec("ROLLBACK;"); error(result, 0) end
        db:exec("COMMIT;")
        return true
    end)
end
-- End of isolated storage and exchange format helpers.

local archived = {}
local legacy_hidden = {}
local legacy_disabled = false
local function loadMetadata()
    local result, err = withDB(function(db)
        local words = sqlRows(db, "SELECT word FROM audit_archived_words;")
        local excluded = {}
        for _index, word in ipairs(words.word or {}) do excluded[word] = true end
        local hidden_rows = sqlRows(db, "SELECT word FROM audit_legacy_excluded;")
        local hidden_legacy = {}
        for index, word in ipairs(hidden_rows.word or {}) do hidden_legacy[word] = true end
        local meta = sqlRows(db, "SELECT value FROM audit_meta WHERE key='legacy_disabled';")
        return { excluded = excluded, legacy_hidden = hidden_legacy,
            disabled = (meta.value or {})[1] == "1" }
    end)
    if result then archived, legacy_hidden, legacy_disabled =
        result.excluded, result.legacy_hidden, result.disabled
    else warn("Could not open the learning database:", err) end
end
loadMetadata()

local function newRecord()
    return {
        total = 0, correct = 0, wrong = 0, success_streak = 0,
        recent = {}, mastery_streak_timestamps = {}, spaced_progress = 0,
        ever_mastered = false, demoted = false,
        needs_spaced_revalidation = false,
    }
end

local function startRecord(word)
    local r
    if not legacy_disabled and not archived[word] and not legacy_hidden[word] then
        r = copy(legacy[word])
    end
    if not r or not next(r) then return newRecord() end
    r.recent = type(r.recent) == "table" and r.recent or {}
    r.mastery_streak_timestamps = type(r.mastery_streak_timestamps) == "table"
        and r.mastery_streak_timestamps or {}
    if r.ever_mastered and not r.demoted and legacy[word]
        and legacy[word].mastery_streak_timestamps == nil then
        r.needs_spaced_revalidation = true
    end
    -- Previous v1 releases stored every correct tap, not only genuinely spaced
    -- attempts. Rebuild its progress from the timestamps without mutating legacy.
    local count, previous = 0, nil
    for i = 1, #r.mastery_streak_timestamps do
        local at = tonumber(r.mastery_streak_timestamps[i])
        if at and (not previous or (at - previous >= GAP
            and os.date("%Y-%m-%d", at) ~= os.date("%Y-%m-%d", previous))) then
            count = count + 1
            previous = at
        end
    end
    r.spaced_progress = math.min(REQUIRED, count)
    return r
end

local function recentWrong(r, amount)
    local recent = r.recent or {}
    local count = 0
    for i = math.max(1, #recent - amount + 1), #recent do
        if recent[i] == false then count = count + 1 end
    end
    return count
end

local function trailingWrong(r)
    local n = 0
    for i = #(r.recent or {}), 1, -1 do
        if r.recent[i] == false then n = n + 1 else break end
    end
    return n
end

local function updateRecord(r, at, got)
    r.total = (tonumber(r.total) or 0) + 1
    r.recent = type(r.recent) == "table" and r.recent or {}
    r.mastery_streak_timestamps = type(r.mastery_streak_timestamps) == "table"
        and r.mastery_streak_timestamps or {}
    r.last_review = at
    if got then
        r.correct = (tonumber(r.correct) or 0) + 1
        r.success_streak = (tonumber(r.success_streak) or 0) + 1
        table.insert(r.recent, true)
        -- Extra answers in the same study session do not undo existing spaced
        -- progress. Only a qualifying new day advances the mastery chain.
        local last = tonumber(r.mastery_streak_timestamps[#r.mastery_streak_timestamps])
        if not last or (at - last >= GAP
            and os.date("%Y-%m-%d", at) ~= os.date("%Y-%m-%d", last)) then
            table.insert(r.mastery_streak_timestamps, at)
            r.spaced_progress = math.min(REQUIRED, (tonumber(r.spaced_progress) or 0) + 1)
        end
        while #r.mastery_streak_timestamps > REQUIRED do
            table.remove(r.mastery_streak_timestamps, 1)
        end
    else
        r.wrong = (tonumber(r.wrong) or 0) + 1
        r.success_streak = 0
        r.mastery_streak_timestamps = {}
        r.spaced_progress = 0
        table.insert(r.recent, false)
    end
    while #r.recent > 10 do table.remove(r.recent, 1) end

    local total = r.total
    local recent_size = math.min(10, #r.recent)
    local recent_correct = recent_size - recentWrong(r, recent_size)
    -- The overall percentage is always shown, but recent retention allows a
    -- recovering card to reach Learned without old mistakes blocking forever.
    local recent_rate = recent_size > 0 and recent_correct / recent_size or 0
    local overall_rate = (tonumber(r.correct) or 0) / math.max(1, total)
    local strong_recent = (recent_size >= 5 and recent_rate >= .80)
    local good_rate = overall_rate >= .80 or strong_recent
    local spaced = (tonumber(r.spaced_progress) or 0) >= REQUIRED
    if r.ever_mastered and not r.demoted then
        if trailingWrong(r) >= 2 or recentWrong(r, 5) >= 3 then
            r.demoted = true
        end
    end
    if total >= 8 and spaced and good_rate then
        r.ever_mastered = true
        r.demoted = false
        r.needs_spaced_revalidation = false
    end
end

local function classify(r)
    if type(r) ~= "table" or (tonumber(r.total) or 0) <= 0 then return "untracked" end
    if r.ever_mastered and r.demoted then return "demoted" end
    if r.ever_mastered and not r.needs_spaced_revalidation then return "mastered" end
    local total, wrong = tonumber(r.total) or 0, tonumber(r.wrong) or 0
    if total >= 5 and ((wrong >= 3 and wrong / total >= .60) or recentWrong(r, 5) >= 3) then
        return "problematic"
    end
    return "learning"
end

local state = {}
local function rebuildWord(word)
    local r = startRecord(word)
    local events, err = syncCollect(word)
    if not events then warn("Cannot rebuild word", word, err) end
    for _, ev in ipairs(events or {}) do
        if syncIsVisible(ev) then updateRecord(r, ev.review_time, ev.got == 1) end
    end
    state[word] = r
    return r
end

local function rebuildAll()
    state = {}
    if not legacy_disabled then
        for word in pairs(legacy) do
            if not archived[word] then state[word] = startRecord(word) end
        end
    end
    local events, err = syncCollect()
    if not events then warn("Could not read recorded reviews:", err); return end
    for _, ev in ipairs(events) do
        if syncIsVisible(ev) then
            local r = state[ev.word]
            if not r then r = startRecord(ev.word); state[ev.word] = r end
            updateRecord(r, ev.review_time, ev.got == 1)
        end
    end
end

-- Pending journal is used ONLY if SQLite cannot accept an event. It is not
-- allowed to prevent the normal Vocabulary Builder action from completing.
local function encode(s)
    return (s:gsub("[^%w%-_%.]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
local seq = 0
local session = tostring(os.time()) .. "-" .. tostring({}):gsub("table: ", "")
local function nextKey()
    seq = seq + 1
    return "learning-v2:" .. session .. ":" .. tostring(seq)
end
local function insertEvent(ev)
    return withDB(function(db)
        execute(db, [[INSERT OR IGNORE INTO audit_events
          (event_key,word,review_time,got,review_mode) VALUES (?,?,?,?,?);]],
          ev.key, ev.word, ev.time, ev.got and 1 or 0,
          normalizeReviewMode(ev.review_mode))
        return true
    end)
end
local function persistUndo(key, word, at)
    return withDB(function(db)
        db:exec("BEGIN IMMEDIATE;")
        local good, result = pcall(function()
            local old = sqlRows(db, "SELECT event_seq FROM audit_undo_ops WHERE op_key="
                .. sqlQuote(key) .. ";")
            if tonumber((old.event_seq or {})[1]) then return true end
            -- Older FlipSide versions generated a fresh operation ID on retry.
            -- Recognize their already-committed Undo by the *exact* event
            -- identity, so recovery cannot mark a second same-second entry.
            if at and at > 0 then
                local previously_undone = sqlRows(db, [[SELECT o.event_seq AS seq
                    FROM audit_undo_ops o JOIN audit_events e ON e.seq=o.event_seq
                    WHERE e.word=]] .. sqlQuote(word)
                    .. " AND e.review_time=" .. math.floor(at)
                    .. " AND e.undone=1 LIMIT 1;")
                if tonumber((previously_undone.seq or {})[1]) then return true end
            end
            local query = "SELECT seq FROM audit_events WHERE word=" .. sqlQuote(word)
                .. " AND undone=0 AND archived=0"
                .. " AND seq NOT IN (SELECT event_seq FROM audit_hidden_events)"
            if at and at > 0 then query = query .. " AND review_time=" .. math.floor(at) end
            query = query .. " ORDER BY seq DESC LIMIT 1;"
            local selected = sqlRows(db, query)
            local id = tonumber((selected.seq or {})[1])
            if not id then return false end
            execute(db, "UPDATE audit_events SET undone=1 WHERE seq=?;", id)
            execute(db, "INSERT OR IGNORE INTO audit_undo_ops(op_key,event_seq) VALUES(?,?);", key, id)
            return true
        end)
        if not good then db:exec("ROLLBACK;"); error(result, 0) end
        db:exec("COMMIT;")
        return result
    end)
end
local function writeJournal(ev)
    local file = io.open(JOURNAL_PATH, "ab")
    if not file then return false end
    local code = ev.undo and "U" or (ev.got and "1" or "0")
    local success = file:write(ev.key .. "|" .. encode(ev.word) .. "|"
        .. tostring(ev.time or 0) .. "|" .. code .. "|"
        .. encodeReviewMode(ev.review_mode) .. "\n")
    local flushed = file:flush()
    local closed = file:close()
    return success ~= nil and flushed ~= nil and closed ~= nil
end
local function readJournal()
    local f = io.open(JOURNAL_PATH, "rb")
    if not f then return {} end
    local rows = {}
    for line in f:lines() do
        local key, word, at, code, mode_code =
            line:match("^([^|]+)|([^|]+)|(%d+)|([01U])|([MCU])$")
        if not key then
            -- Journals left by earlier versions had no mode field.
            key, word, at, code = line:match("^([^|]+)|([^|]+)|(%d+)|([01U])$")
            mode_code = "U"
        end
        if key then
            rows[#rows + 1] = {key = key, word = decode(word),
                time = tonumber(at), got = code == "1", undo = code == "U",
                review_mode = decodeReviewMode(mode_code)}
        end
    end
    f:close()
    return rows
end
local function replayJournal()
    local rows = readJournal()
    if #rows == 0 then return true end
    for _index, ev in ipairs(rows) do
        local ok, err
        if ev.undo then ok, err = persistUndo(ev.key, ev.word, ev.time)
        else ok, err = insertEvent(ev) end
        if ok == nil then warn("Journal needs retry:", err); return false end
    end
    local ok, err = os.remove(JOURNAL_PATH)
    if not ok then warn("Could not remove replayed journal:", err) end
    return true
end
replayJournal()
rebuildAll()

local function reportSaveFailure(err)
    warn("Learning event not written to SQLite:", err)
    -- Do not block native Vocabulary Builder review with a modal popup.
end
local function storeAttempt(word, got, at, review_mode)
    if not trimWord(word) then return end
    -- Older pending events must be replayed before newer ones are recorded.
    replayJournal()
    local ev = {key = nextKey(), word = word, got = got, time = at or os.time(),
        review_mode = normalizeReviewMode(review_mode)}
    local ok, err = insertEvent(ev)
    if ok == nil and not writeJournal(ev) then
        reportSaveFailure("SQLite and recovery journal unavailable: " .. tostring(err))
    end
    local r = state[word]
    if not r then r = startRecord(word); state[word] = r end
    updateRecord(r, ev.time, got)
end

-- Check a flashcard answer *after* the native database says it is committed.
-- This is an idempotent fallback for KOReader versions or third-party patches
-- where the gotOrForgot/batchUpdateItems hook does not see the same item.
-- Never manufacture a mode for an old review: the caller supplies the exact
-- timestamp of the just-committed native answer, not the card's current mode.
-- Used only after the native KOReader review was committed successfully.
-- Verify the exact word, time, result and recorded mode in SQLite before
-- telling Flashcards that the review has been captured. Native hooks may have
-- saved the event first: those are enriched, not duplicated.
local function confirmCommittedReview(word, got, review_time, review_mode)
    if not trimWord(word) or type(got) ~= "boolean" then
        return false, "Invalid review data"
    end
    local at = tonumber(review_time)
    if not at or at <= 0 then return false, "No saved review timestamp" end
    at = math.floor(at)
    local mode = normalizeReviewMode(review_mode)

    -- The old version silently accepted a pending UNKNOWN journal entry as
    -- "recorded", even if SQLite was inaccessible. Replay and verify instead.
    if not replayJournal() then
        return false, "Could not replay saved review history"
    end

    local function matchingEvent()
        return withDB(function(db)
            local rows = sqlRows(db, [[SELECT e.seq AS seq, e.review_mode AS review_mode
                FROM audit_events e
                LEFT JOIN audit_hidden_events h ON h.event_seq=e.seq
                WHERE e.word=]] .. sqlQuote(word)
                .. " AND e.review_time=" .. at
                .. " AND e.got=" .. (got and 1 or 0)
                .. " AND e.undone=0 AND e.archived=0 AND h.event_seq IS NULL"
                .. " ORDER BY e.seq DESC LIMIT 1;")
            local seq_id = tonumber((rows.seq or {})[1])
            if not seq_id then return false end
            local saved_mode = normalizeReviewMode((rows.review_mode or {})[1])
            if mode ~= "unknown" and saved_mode == "unknown" then
                execute(db, "UPDATE audit_events SET review_mode=? WHERE seq=?;",
                    mode, seq_id)
                saved_mode = mode
            end
            if mode ~= "unknown" and saved_mode ~= mode then
                return "conflict"
            end
            return true
        end)
    end

    local found, read_err = matchingEvent()
    if found == nil then return false, "Cannot read review history: " .. tostring(read_err) end
    if found == "conflict" then
        return false, "The saved review has a different retrieval model"
    end
    if found then return true end

    -- The stock hook did not capture this answer. Save a NEW event with its
    -- exact, already committed timestamp and the mode used on that card.
    local ev = {key = nextKey(), word = word, time = at, got = got,
        review_mode = mode}
    local saved, write_err = insertEvent(ev)
    if not saved then
        -- Retain the answer for later recovery, but do not falsely claim that
        -- the requested accuracy statistics are already available.
        if not writeJournal(ev) then
            reportSaveFailure(write_err or "recovery journal unavailable")
            return false, "Cannot write review history or recovery journal"
        end
        return false, "Review queued; statistics database was unavailable"
    end
    -- Keep the Learning dashboard's in-memory record in sync with the event.
    local r = state[word]
    if not r then r = startRecord(word); state[word] = r end
    updateRecord(r, at, got)
    local verified, verify_err = matchingEvent()
    if verified ~= true then
        return false, "Cannot verify recorded retrieval model: "
            .. tostring(verify_err or verified)
    end
    return true
end

local function undoAttempt(word, review_time)
    if not trimWord(word) then return false end
    replayJournal()
    local at = tonumber(review_time) or 0
    -- Stable ID across restarts: an interrupted recovery is the *same* Undo,
    -- not a new request that might remove another review in that second.
    local key = at > 0 and ("learning-undo-v3:" .. encode(word) .. ":"
        .. tostring(math.floor(at))) or nextKey()
    local ev = {key = key, word = word, time = at, undo = true}
    local changed, err = persistUndo(ev.key, word, at)
    if changed then rebuildWord(word)
    elseif changed == nil then
        if not writeJournal(ev) then
            reportSaveFailure("Undo journal unavailable: " .. tostring(err))
        end
    end
    return changed
end

-- A reset only changes what Learning Analysis counts. It never touches the
-- stock Vocabulary Builder DB, review scheduling, or the Activity Stats DB.
-- Old v1 records generally contain aggregates rather than individual events.
-- For an aggregate with precisely ONE review, its last_review timestamp is the
-- timestamp of that review, so it is safe to apply the period filter to it.
-- For two or more reviews, last_review does NOT tell us the dates of the
-- earlier ones. Never attribute those undated aggregates to a chosen period.
-- Hidden events remain on disk for backup; stock Vocabulary Builder and the
-- independent Activity Stats database are never modified by this reset.
local function legacyReviewCount(word)
    if legacy_disabled or archived[word] or legacy_hidden[word] then return 0 end
    local r = legacy[word]
    if type(r) ~= "table" then return 0 end
    return math.max(0, math.floor(tonumber(r.total) or 0))
end

local function singletonLegacyTimestamp(word)
    if legacyReviewCount(word) ~= 1 then return nil end
    local r = legacy[word]
    local at = tonumber(r.last_review)
    -- Older variants may have saved the one correct answer only in this array.
    if not at and tonumber(r.correct) == 1 and tonumber(r.wrong) == 0 then
        local stamps = r.mastery_streak_timestamps
        if type(stamps) == "table" and #stamps == 1 then
            at = tonumber(stamps[1])
        end
    end
    -- Exclude empty and obviously invalid timestamps. Never invent a date.
    if at and at >= 946684800 and at <= os.time() + 300 then
        return math.floor(at)
    end
    return nil
end

local function legacyCountInPeriod(word, from_time, before_time, all_history)
    local count = legacyReviewCount(word)
    if count == 0 then return 0 end
    if all_history then return count end
    local at = singletonLegacyTimestamp(word)
    if at and (not from_time or at >= from_time)
        and (not before_time or at < before_time) then
        return 1
    end
    return 0
end

local function startDay(days_ago)
    local today = os.date("*t")
    return os.time({year=today.year, month=today.month,
        day=today.day-(days_ago or 0), hour=0, min=0, sec=0})
end

local function parseCalendarDate(s)
    local y,m,d = tostring(s or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    y,m,d = tonumber(y),tonumber(m),tonumber(d)
    if not y or not m or not d or y < 1970 or y > 2100 then return nil end
    local noon = os.time({year=y,month=m,day=d,hour=12,min=0,sec=0})
    if not noon or os.date("%Y-%m-%d",noon) ~= s then return nil end
    local from = os.time({year=y,month=m,day=d,hour=0,min=0,sec=0})
    local to = os.time({year=y,month=m,day=d+1,hour=0,min=0,sec=0})
    return from, to
end

local function resetWhere(word, from_time, before_time)
    local clause = "word=" .. sqlQuote(word) .. " AND undone=0 AND archived=0"
        .. " AND seq NOT IN (SELECT event_seq FROM audit_hidden_events)"
    if from_time then clause = clause .. " AND review_time >= " .. math.floor(from_time) end
    if before_time then clause = clause .. " AND review_time < " .. math.floor(before_time) end
    return clause
end

local function resetPreview(word, from_time, before_time, all_history)
    return withDB(function(db)
        local result = sqlRows(db, "SELECT COUNT(*) AS n FROM audit_events WHERE "
            .. resetWhere(word, from_time, before_time) .. ";")
        local count = tonumber((result.n or {})[1]) or 0
        -- Include imported reviews without adding them to the original DB.
        local merged_count, merge_error = syncRemotePreviewCount(word, from_time, before_time)
        if not merged_count then error(merge_error or "cannot read sync history") end
        count = merged_count
        local legacy_count = legacyCountInPeriod(word, from_time, before_time, all_history)
        return {
            count = count,
            legacy_count = legacy_count,
            older_total = legacyReviewCount(word),
            singleton_time = singletonLegacyTimestamp(word),
        }
    end)
end

local function resetReviews(word, from_time, before_time, all_history)
    if not trimWord(word) then return nil, "missing word" end
    -- Do not replay a pre-reset attempt after the reset. Pending writes must be
    -- reconciled first or the reset is aborted without changing anything.
    if not replayJournal() then return nil, "pending reviews could not be saved" end
    local legacy_in_period = legacyCountInPeriod(word, from_time, before_time, all_history)
    local before_count, count_error = syncRemotePreviewCount(word, from_time, before_time)
    if not before_count then return nil, count_error end
    local hide_legacy = all_history or legacy_in_period > 0
    local result, err = withDB(function(db)
        db:exec("BEGIN IMMEDIATE;")
        local good, outcome = pcall(function()
            local where = resetWhere(word, from_time, before_time)
            local existing = sqlRows(db, "SELECT COUNT(*) AS n FROM audit_events WHERE " .. where .. ";")
            local count = tonumber((existing.n or {})[1]) or 0
            -- Keep all old data intact; a per-word exclusion prevents the
            -- read-only legacy baseline from being counted again.
            if hide_legacy then
                execute(db, "INSERT OR IGNORE INTO audit_legacy_excluded(word) VALUES (?);", word)
            end
            if count > 0 then
                db:exec("INSERT OR IGNORE INTO audit_hidden_events(event_seq,cleared_at) "
                    .. "SELECT seq, " .. math.floor(os.time())
                    .. " FROM audit_events WHERE " .. where .. ";")
            end
            return count + legacy_in_period
        end)
        if not good then db:exec("ROLLBACK;"); error(outcome, 0) end
        db:exec("COMMIT;")
        return outcome
    end)
    if result == nil then return nil, err end
    if hide_legacy then legacy_hidden[word] = true end
    local marked, mark_err = syncMark(word, from_time, before_time, "hidden")
    if not marked then
        rebuildWord(word)
        warn("Could not hide imported reviews after local reset:", mark_err)
        return nil, "local reset saved, but remote sync reset failed: " .. tostring(mark_err)
    end
    rebuildWord(word)
    return before_count + legacy_in_period
end

-- Archiving is deliberately non-destructive. Deleted cards disappear from the
-- analysis, but their event rows remain available for recovery. Re-adding the
-- same spelling starts a fresh history instead of reviving old attempts.
local function archiveWord(word)
    if not trimWord(word) then return end
    local ok, err = withDB(function(db)
        db:exec("BEGIN IMMEDIATE;")
        local done, problem = pcall(function()
            execute(db, "INSERT OR IGNORE INTO audit_archived_words(word) VALUES (?);", word)
            execute(db, "UPDATE audit_events SET archived=1 WHERE word=?;", word)
        end)
        if not done then db:exec("ROLLBACK;"); error(problem, 0) end
        db:exec("COMMIT;")
        return true
    end)
    if ok then
        local marked, mark_err = syncMark(word, nil, nil, "archived")
        if not marked then warn("Could not archive imported word events:", mark_err) end
        archived[word] = true
        state[word] = newRecord()
    else warn("Could not archive deleted word:", err) end
end

local function archiveAll()
    local ok, err = withDB(function(db)
        db:exec("BEGIN IMMEDIATE;")
        local done, problem = pcall(function()
            db:exec("UPDATE audit_events SET archived=1 WHERE archived=0;")
            execute(db, "INSERT OR REPLACE INTO audit_meta(key,value) VALUES ('legacy_disabled','1');")
        end)
        if not done then db:exec("ROLLBACK;"); error(problem, 0) end
        db:exec("COMMIT;")
        return true
    end)
    if ok then
        local marked, mark_err = syncMark(nil, nil, nil, "archived")
        if not marked then warn("Could not archive imported history:", mark_err) end
        legacy_disabled = true
        state = {}
        -- Pending events from before an explicit full purge must not reappear.
        local f = io.open(JOURNAL_PATH, "wb")
        if f then f:close() end
    else warn("Could not archive learning history after purge:", err) end
end

local categories = {
    problematic = _("Difficult"),
    demoted = _("Needs relearning"),
    mastered = _("Learned"),
    learning = _("Learning"),
    untracked = _("Not reviewed"),
}
-- Fixed order requested by the user. Do not read old saved custom orders.
local CATEGORY_ORDER = {"mastered", "learning", "demoted", "problematic", "untracked"}
local function orderLabel(key)
    if key == "help" then return _("About these categories") end
    return categories[key] or tostring(key)
end
-- Keep UI callback failures from propagating into KOReader's main event loop.
-- Kindle diagnostic build: independently persist caught UI exceptions because
-- the ordinary launcher's crash.log may be missing or inaccessible.
-- This does not write to the review databases or modify any review state.
local function writeAuditDiagnostic(name, traceback)
    local target = DIR .. "/vocabulary_builder_audit_diagnostic.log"
    local ok, failure = pcall(function()
        local file, error_message = io.open(target, "a")
        if not file then error(error_message or "Cannot open diagnostic file") end
        file:write("\n--- Learning Audit UI error ",
            os.date("%Y-%m-%d %H:%M:%S"), " ---\n",
            tostring(name), "\n", tostring(traceback), "\n")
        file:close()
    end)
    return ok, (ok and target or tostring(failure))
end

local function safeUI(name, fn)
    local ok, err = xpcall(fn, function(e)
        return debug.traceback(tostring(e), 2)
    end)
    if not ok then
        warn("Learning Audit UI / " .. name .. ":", err)
        local saved, location_or_error = writeAuditDiagnostic(name, err)
        pcall(function()
            local first_line = tostring(err):match("^[^\r\n]+") or "Unknown error"
            if #first_line > 180 then first_line = first_line:sub(1, 180) .. "..." end
            local message = "Learning Audit error: " .. first_line
            if saved then
                message = message .. "\nDiagnostic: vocabulary_builder_audit_diagnostic.log (settings)"
            else
                message = message .. "\nCould not save diagnostic: " .. tostring(location_or_error)
            end
            showAuditWidget(InfoMessage:new{
                text = message,
                timeout = 15,
            })
        end)
    end
    return ok
end

-- One shared 17pt, regular-weight UI style for patch-owned statistics,
-- Learning Audit menus, and supporting dialogs. The selected font from
-- Flashcards is used when that patch is loaded; KOReader's reader, native
-- Vocabulary Builder, and external dictionary fonts are never modified.
package.loaded["flipside_audit_style"] = {
    name = function()
        local bridge = package.loaded["flipside_flashcard_typography"]
        if type(bridge) == "table" and type(bridge.name) == "function" then
            local ok, name = pcall(bridge.name)
            if ok and type(name) == "string" and name ~= "" then return name end
        end
        return "cfont"
    end,
    face = function()
        local bridge = package.loaded["flipside_flashcard_typography"]
        if type(bridge) == "table" and type(bridge.face) == "function" then
            local ok, face = pcall(bridge.face, 17)
            if ok and face then return face end
        end
        return Font:getFace("cfont", 17)
    end,
}

local function minimalText(text)
    local screen = Device.screen
    local dialog_width = math.floor(math.min(screen:getWidth(), screen:getHeight()) * .92)
    local width = dialog_width
        - 2 * (Size.border.window + Size.padding.button)
        - 2 * math.max(Size.padding.default + Size.margin.default,
            Size.padding.large + Size.margin.title) - 8
    local widget = TextBoxWidget:new{
        text = text, width = math.max(150, width),
        face = package.loaded["flipside_audit_style"].face(), bold = false, alignment = "left",
    }
    widget.not_focusable = true
    return widget
end

local function minimalDialog(title, widgets, buttons, cover_card_frame)
    -- The native ButtonTable allows exact control of face, size and weight
    -- for each row. This avoids changing the global KOReader Button class.
    for _, row in ipairs(buttons or {}) do
        for _, button in ipairs(row) do
            button.font_face = package.loaded["flipside_audit_style"].name()
            button.font_size = 17
            button.font_bold = false
        end
    end
    local dialog = ButtonDialog:new{
        title = title, use_info_style = false,
        title_face = package.loaded["flipside_audit_style"].face(), title_align = "center",
        width_factor = .92, _added_widgets = widgets, buttons = buttons,
    }
    if cover_card_frame then
        require("flipside_frame_cover").attach(dialog)
    end
    showAuditWidget(dialog)
    return dialog
end

local function minimalInfo(text, timeout)
    showAuditWidget(InfoMessage:new{
        text = text, timeout = timeout, show_icon = false,
        width_factor = .88,
    })
end

local function detailText(card)
    local r = card.record or newRecord()
    local total = tonumber(r.total) or 0
    local correct = tonumber(r.correct) or 0
    local wrong = tonumber(r.wrong) or 0
    local percent = total > 0 and math.floor(correct / total * 100 + .5) or 0
    local last = tonumber(r.last_review)
    local when = last and os.date("%d/%m/%Y", last) or _("Never")
    local history = {}
    for _, got in ipairs(r.recent or {}) do
        history[#history + 1] = got and "✓" or "×"
    end
    return {
        minimalText(string.upper(categories[card.category] or "Learning"), "smallinfofont", 15),
        minimalText(total > 0 and (tostring(percent) .. "% correct") or "No reviews yet", "infofont", 23),
        minimalText(string.format("%d correct  ·  %d wrong   (%d reviews)",
            correct, wrong, total), "smallinfofont", 17),
        minimalText(string.format("Streak %d  ·  Mastery %d/%d",
            tonumber(r.success_streak) or 0,
            math.min(REQUIRED, tonumber(r.spaced_progress) or 0), REQUIRED), "smallinfofont", 17),
        minimalText("Last review: " .. when, "smallinfofont", 16),
        minimalText(#history > 0 and ("Recent: " .. table.concat(history, "  "))
            or "No recent answers", "smallinfofont", 16),
    }
end

local function readAllCards(DB)
    local conn = SQ3.open(DB.path)
    local ok, rows = pcall(sqlRows, conn, "SELECT word FROM vocabulary ORDER BY word COLLATE NOCASE;")
    pcall(conn.close, conn)
    if not ok then error(rows) end
    local cards = {}
    for _index, word in ipairs(rows.word or {}) do
        local r = state[word] or newRecord()
        cards[#cards + 1] = {word = word, record = r, category = classify(r)}
    end
    -- Do not delete invisible/missing history: cloud sync may restore it later.
    return cards
end


-- Daily and all-time accuracy use committed, visible dated events. Old v1
-- aggregates have no event-level mode/dates and are counted only as unknown
-- in the all-time denominator. Never infer their mode from today's card setting.
local REVIEW_MODE_LABELS = {
    all = "All models", meaning = "Meaning Recall only",
    contextual = "Contextual Retrieval only", sentence = "Sentence Card",
    unknown = "Unidentified model",
}
local REVIEW_MODE_ORDER = {"all", "meaning", "contextual", "sentence"}
-- The previous implementation made one "seen words" dictionary for every
-- model and period (up to sixteen dictionaries). A 16-bit per-word presence
-- mask gives exactly the same unique/first-try results with far less memory
-- on small e-ink devices. No review data is removed or approximated.
local function blankAccuracy()
    return {total = 0, correct = 0, wrong = 0, unique = 0,
        first_total = 0, first_correct = 0}
end
local function newAccuracyGroup()
    return {
        today = blankAccuracy(), week = blankAccuracy(),
        month = blankAccuracy(), overall = blankAccuracy(),
        unknown = 0, undated_legacy = 0,
    }
end
local ACCURACY_ALL_MODES = {"all", "meaning", "contextual", "sentence", "unknown"}
local ACCURACY_FLAGS = {
    all = {overall = 1, today = 2, week = 4, month = 8},
    meaning = {overall = 16, today = 32, week = 64, month = 128},
    contextual = {overall = 256, today = 512, week = 1024, month = 2048},
    unknown = {overall = 4096, today = 8192, week = 16384, month = 32768},
    sentence = {overall = 65536, today = 131072, week = 262144, month = 524288},
}
local function unseenFlag(mask, flag)
    return math.floor(mask / flag) % 2 == 0
end
local function addAccuracyEvent(bucket, mask, flag, got, first)
    bucket.total = bucket.total + 1
    if got then bucket.correct = bucket.correct + 1
    else bucket.wrong = bucket.wrong + 1 end
    if unseenFlag(mask, flag) then
        mask = mask + flag
        bucket.unique = bucket.unique + 1
        if first then
            bucket.first_total = bucket.first_total + 1
            if got then bucket.first_correct = bucket.first_correct + 1 end
        end
    end
    return mask
end

-- Calculate every filter in ONE chronological pass. Identical totals, correct,
-- wrong, unique words and first-today results for each of the 4 models.
local function calculateAllAccuracy(events, word_filter)
    local stats = {}
    for _, mode in ipairs(ACCURACY_ALL_MODES) do stats[mode] = newAccuracyGroup() end
    local next_day = startDay(-1)
    local today = startDay(0)
    local week = startDay(6)
    local month = startDay(29)
    local seen_mask = {}
    local function add(mode, ev, got, at)
        local group = stats[mode]
        local flags = ACCURACY_FLAGS[mode]
        local mask = seen_mask[ev.word] or 0
        mask = addAccuracyEvent(group.overall, mask, flags.overall, got, false)
        if at >= today and at < next_day then
            mask = addAccuracyEvent(group.today, mask, flags.today, got, true)
        end
        if at >= week and at < next_day then
            mask = addAccuracyEvent(group.week, mask, flags.week, got, false)
        end
        if at >= month and at < next_day then
            mask = addAccuracyEvent(group.month, mask, flags.month, got, false)
        end
        seen_mask[ev.word] = mask
    end
    -- Events are sorted once by timestamp, then key, by getAccuracySummary.
    for _, ev in ipairs(events or {}) do
        if syncIsVisible(ev) and (not word_filter or ev.word == word_filter) then
            local mode = normalizeReviewMode(ev.review_mode)
            local at = tonumber(ev.review_time) or 0
            local got = ev.got == 1
            add("all", ev, got, at)
            add(mode, ev, got, at)
            if mode == "unknown" then
                stats.all.unknown = stats.all.unknown + 1
                stats.unknown.unknown = stats.unknown.unknown + 1
            end
        end
    end
    for word, r in pairs(legacy) do
        if (not word_filter or word == word_filter)
            and not legacy_disabled and not archived[word] and not legacy_hidden[word]
            and type(r) == "table" then
            local total = math.max(0, math.floor(tonumber(r.total) or 0))
            local correct = math.max(0, math.min(total,
                math.floor(tonumber(r.correct) or 0)))
            if total > 0 then
                local mask = seen_mask[word] or 0
                for _, mode in ipairs({"all", "unknown"}) do
                    local group = stats[mode]
                    local overall = group.overall
                    overall.total = overall.total + total
                    overall.correct = overall.correct + correct
                    overall.wrong = overall.wrong + total - correct
                    local flag = ACCURACY_FLAGS[mode].overall
                    if unseenFlag(mask, flag) then
                        overall.unique = overall.unique + 1
                        mask = mask + flag
                    end
                    group.undated_legacy = group.undated_legacy + total
                end
                seen_mask[word] = mask
            end
        end
    end
    return stats
end

-- A small versioned snapshot, separate from BOTH the native Vocabulary Builder
-- database and the review-history databases. The original events stay the
-- sole source of truth. A failed cache write cannot affect reviews or sync.
local ACCURACY_CACHE_VERSION = "accuracy-v2.14.0-sentence-v1"
local ACCURACY_CACHE_PATH = DIR .. "/vocabulary_builder_learning_audit_accuracy_cache.lua"
local accuracy_settings = LuaSettings:open(ACCURACY_CACHE_PATH)
local accuracy_memory = {}
local accuracy_memory_order = {}
local ACCURACY_WORD_CACHE_LIMIT = 16
local LEGACY_PATH = DIR .. "/vocabulary_builder_learning_audit.lua"
local legacy_file_stat, legacy_file_hash

local function fileStat(path)
    local a = lfs.attributes(path)
    if not a then return "missing" end
    return tostring(a.size) .. ":" .. tostring(a.modification)
        .. ":" .. tostring(a.change)
end

local function legacyFileSignature()
    local current = fileStat(LEGACY_PATH)
    if legacy_file_stat == current and legacy_file_hash then return legacy_file_hash end
    local f = io.open(LEGACY_PATH, "rb")
    if not f then
        legacy_file_stat, legacy_file_hash = current, "missing"
        return legacy_file_hash
    end
    -- Streamed fingerprint: never place a potentially large legacy file in
    -- Kindle memory just to validate a small cached result.
    local a, b, size = 1, 0, 0
    while true do
        local chunk = f:read(65536)
        if not chunk then break end
        size = size + #chunk
        for i = 1, #chunk do
            a = (a + chunk:byte(i)) % 65521
            b = (b + a) % 65521
        end
    end
    f:close()
    legacy_file_stat = current
    legacy_file_hash = string.format("%08X:%d", b * 65536 + a, size)
    return legacy_file_hash
end

local function currentAccuracyToken()
    local local_revision, local_err = withDB(function(db)
        local rows = sqlRows(db, "SELECT revision FROM audit_accuracy_revision WHERE id=1;")
        return tonumber((rows.revision or {})[1])
    end)
    if not local_revision then return nil, local_err or "local revision counter not available" end
    local remote_revision, remote_err = withSyncDB(function(db)
        local rows = sqlRows(db, "SELECT revision FROM synced_accuracy_revision WHERE id=1;")
        return tonumber((rows.revision or {})[1])
    end)
    if not remote_revision then return nil, remote_err or "sync revision counter not available" end
    -- Calendar boundaries, not elapsed 24-hour windows: midnight and timezone
    -- changes must invalidate the daily/weekly/monthly statistics.
    return table.concat({ACCURACY_CACHE_VERSION, tostring(local_revision),
        tostring(remote_revision), tostring(startDay(0)), tostring(startDay(-1)),
        tostring(startDay(6)), tostring(startDay(29)), legacyFileSignature(),
        fileStat(DB_PATH), fileStat(SYNC_DB_PATH)}, "|")
end

local function validAccuracySnapshot(snapshot)
    if type(snapshot) ~= "table" then return false end
    for _, mode in ipairs(ACCURACY_ALL_MODES) do
        local group = snapshot[mode]
        if type(group) ~= "table" or type(group.unknown) ~= "number"
            or type(group.undated_legacy) ~= "number" then return false end
        for _, period in ipairs({"today", "week", "month", "overall"}) do
            local t = group[period]
            if type(t) ~= "table" or type(t.total) ~= "number"
                or type(t.correct) ~= "number" or type(t.wrong) ~= "number"
                or t.total < 0 or t.correct + t.wrong ~= t.total
                or type(t.unique) ~= "number" or type(t.first_total) ~= "number"
                or type(t.first_correct) ~= "number" then return false end
        end
    end
    return true
end

local function memorizeAccuracy(key, token, snapshot)
    if key ~= "__global__" and not accuracy_memory[key] then
        accuracy_memory_order[#accuracy_memory_order + 1] = key
        if #accuracy_memory_order > ACCURACY_WORD_CACHE_LIMIT then
            local evicted = table.remove(accuracy_memory_order, 1)
            accuracy_memory[evicted] = nil
        end
    end
    accuracy_memory[key] = {token = token, stats = snapshot}
end

local function getAccuracySummary(word_filter)
    -- A missing/unwritable revision counter only disables caching; original
    -- history calculation still works (never show stale cached results).
    local key = word_filter and ("word:" .. word_filter) or "__global__"
    for attempt = 1, 2 do
        local token, token_err = currentAccuracyToken()
        if token then
            local memory = accuracy_memory[key]
            if memory and memory.token == token and validAccuracySnapshot(memory.stats) then
                return memory.stats
            end
            if not word_filter then
                local saved = accuracy_settings:readSetting("global_snapshot")
                if type(saved) == "table" and saved.token == token
                    and validAccuracySnapshot(saved.stats) then
                    memorizeAccuracy(key, token, saved.stats)
                    return saved.stats
                end
            end
        elseif attempt == 1 then
            warn("Accuracy cache disabled; calculating from source:", token_err)
        end
        -- Refresh metadata before rebuilding: another patch or a prior sync
        -- may have changed the SQLite exclusions while this screen was closed.
        loadMetadata()
        local events, err = syncCollect(word_filter, true)
        if not events then return nil, err end
        table.sort(events, function(a, b)
            if a.review_time ~= b.review_time then return a.review_time < b.review_time end
            return tostring(a.event_key) < tostring(b.event_key)
        end)
        local snapshot = calculateAllAccuracy(events, word_filter)
        if not token then return snapshot end
        local after_token = currentAccuracyToken()
        if after_token == token then
            memorizeAccuracy(key, token, snapshot)
            if not word_filter then
                local saved, save_err = pcall(function()
                    accuracy_settings:saveSetting("global_snapshot", {token=token, stats=snapshot})
                    accuracy_settings:flush()
                end)
                if not saved then warn("Accuracy cache not saved:", save_err) end
            end
            return snapshot
        end
        -- An external edit occurred during the scan; retry once. Never
        -- cache potentially inconsistent data against the wrong revision.
    end
    return nil, "Review history changed while calculating; open the screen again."
end
-- Read a separate on-device foreground-study clock from the flashcards
-- patch. This is elapsed *study time*, not elapsed time since a review was
-- scheduled, and it is not derived from the answer count. It includes local
-- practice/reinforcement but excludes menus, dictionary and idle finish UI.
-- This small LuaSettings file is intentionally independent of audit SQLite
-- and the cloud-sync review history; per-word time cannot be inferred.
-- Only genuine rated SRS study time is counted in new Flashcards versions.
local REVIEW_TIME_PATH = DIR .. "/flipside_review_time.lua"
local function readStudyTime(mode)
    local zero = { today = 0, week = 0, month = 0, overall = 0 }
    local ok, saved = pcall(function()
        local settings = LuaSettings:open(REVIEW_TIME_PATH)
        return settings:readSetting("clock_v1")
    end)
    if not ok or type(saved) ~= "table" then return zero end
    local totals = type(saved.totals) == "table" and saved.totals or {}
    local days = type(saved.days) == "table" and saved.days or {}
    local key = (mode == "meaning" or mode == "contextual" or mode == "sentence")
        and mode or "all"
    local now = os.time()
    local result = { today = 0, week = 0, month = 0,
        overall = math.max(0, math.floor(tonumber(totals[key]) or 0)) }
    for ago = 0, 29 do
        -- Use calendar-day labels; they remain stable over restarts and DST.
        local stamp = os.date("%Y-%m-%d", now - ago * 86400)
        local bucket = days[stamp]
        local seconds = type(bucket) == "table"
            and math.max(0, math.floor(tonumber(bucket[key]) or 0)) or 0
        if ago == 0 then result.today = seconds end
        if ago < 7 then result.week = result.week + seconds end
        result.month = result.month + seconds
    end
    return result
end

local function studyTimeLabel(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then return string.format("%dh %02dm %02ds", hours, minutes, secs) end
    return string.format("%dm %02ds", minutes, secs)
end

-- Compact e-ink report: large primary percentage, small supporting counts,
-- and one button for each filter. Modes with unknown historical labels appear
-- only in All models, never as a separate tab.
local function accuracyText(value)
    return minimalText(value)
end

local function accuracyWidgets(label, stats, study_seconds)
    local widgets = {accuracyText(label)}
    if stats.total == 0 then
        widgets[#widgets + 1] = accuracyText("No reviews yet")
    else
        widgets[#widgets + 1] = accuracyText(string.format("%.1f%% correct",
            100 * stats.correct / stats.total))
        widgets[#widgets + 1] = accuracyText(string.format(
            "%.1f%% wrong  ·  %d reviews", 100 * stats.wrong / stats.total,
            stats.total))
        widgets[#widgets + 1] = accuracyText(string.format(
            "%d correct  ·  %d wrong", stats.correct, stats.wrong))
    end
    if study_seconds ~= nil then
        widgets[#widgets + 1] = accuracyText(
            "Study time  ·  " .. studyTimeLabel(study_seconds))
    end
    return widgets
end

-- Today's schedule is taken from the native Vocabulary Builder due_time,
-- never from the Learning Audit event log. Group future reviews by EXACT
-- minute, with overdue ones grouped into "Due now". This is all books,
-- independent of the currently selected accuracy model.
local function readTodaySchedule()
    local result = { total = 0, saved_total = 0, overdue = 0, sections = {
        morning = {title = "MORNING", total = 0, slots = {}},
        afternoon = {title = "AFTERNOON", total = 0, slots = {}},
        night = {title = "NIGHT", total = 0, slots = {}},
    } }
    local now = os.time()
    local date = os.date("*t", now)
    date.hour, date.min, date.sec = 0, 0, 0
    local midnight = os.time{ year=date.year, month=date.month, day=date.day + 1,
        hour=0, min=0, sec=0 }
    local conn = SQ3.open(DIR .. "/vocabulary_builder.sqlite3")
    local ok_total, count = pcall(conn.rowexec, conn, "SELECT COUNT(*) FROM vocabulary;")
    if ok_total then result.saved_total = tonumber(count) or 0 end
    local ok, rows = pcall(sqlRows, conn,
        "SELECT due_time FROM vocabulary WHERE due_time < " .. midnight ..
        " ORDER BY due_time ASC;")
    pcall(conn.close, conn)
    if not ok then error(rows) end
    for _, stamp in ipairs((rows and rows.due_time) or {}) do
        local due = tonumber(stamp)
        if due then
            result.total = result.total + 1
            if due <= now then
                result.overdue = result.overdue + 1
            else
                local h = tonumber(os.date("%H", due)) or 0
                local section = result.sections[h >= 6 and h < 12 and "morning"
                    or h >= 12 and h < 18 and "afternoon" or "night"]
                section.total = section.total + 1
                local label = os.date("%H:%M", due)
                local last = section.slots[#section.slots]
                if last and last.time == label then
                    last.count = last.count + 1
                else
                    section.slots[#section.slots+1] = {time=label, count=1}
                end
            end
        end
    end
    return result
end

-- The selected design: three stacked compact information cards. All text
-- (captions, values, period labels and optional historical note) is regular
-- 17pt and uses the Flashcards-selected UI face. Only decorative symbols
-- use icons. Native FrameContainer/IconWidget handle e-ink refresh normally.
local function accuracyStackedCards(mode_label, period1, period2, stats1, stats2,
        study1, study2, older, schedule, popup_width, font_size, compactness)
local AUDIT_CARD_ICONS = {
    today = [[<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><g fill="none" stroke="#000" stroke-width="4" stroke-linejoin="round" stroke-linecap="round"><rect x="8" y="13" width="48" height="43" rx="4"/><path d="M8 25h48M20 7v12M44 7v12"/></g><g fill="#000"><circle cx="20" cy="35" r="2.8"/><circle cx="32" cy="35" r="2.8"/><circle cx="44" cy="35" r="2.8"/><circle cx="20" cy="46" r="2.8"/><circle cx="32" cy="46" r="2.8"/></g></svg>]],
    overall = [[<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><g fill="#000"><rect x="10" y="40" width="10" height="16" rx="1"/><rect x="27" y="28" width="10" height="28" rx="1"/><rect x="44" y="13" width="10" height="43" rx="1"/></g></svg>]],
    schedule = [[<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><g fill="none" stroke="#000" stroke-width="3.8" stroke-linejoin="round" stroke-linecap="round"><rect x="5" y="11" width="45" height="41" rx="4"/><path d="M5 23h45M17 6v11M39 6v11"/><circle cx="45" cy="44" r="14" fill="#fff"/><path d="M45 35v9l6 4"/></g><g fill="#000"><circle cx="17" cy="33" r="2.3"/><circle cx="29" cy="33" r="2.3"/></g></svg>]],
}
local audit_icon_files = {}
local function reportIconPath(kind)
    if audit_icon_files[kind] then return audit_icon_files[kind] end
    local content = AUDIT_CARD_ICONS[kind]
    if not content then return nil end
    local path = require("lib.ui.flipside_icon_store").path("vocab-audit-panel-" .. kind .. ".svg")
    -- Always compare with desired bytes so a patch update replaces a stale
    -- icon, but never writes on ordinary dialog refreshes.
    local existing = io.open(path, "rb")
    local old = existing and existing:read("*a")
    if existing then existing:close() end
    if old ~= content then
        local file = io.open(path, "wb")
        if file then
            local ok = file:write(content)
            file:close()
            if not ok then path = nil end
        else path = nil end
    end
    audit_icon_files[kind] = path
    return path
end

    local small = math.min(Device.screen:getWidth(), Device.screen:getHeight())
    local dialog_width = popup_width or math.floor(small * .80)
    -- Matches ButtonDialog with info_padding=0 and info_margin=0.
    -- Keep 4 pixels on each side for the popup's card corners.
    local width = math.max(180, dialog_width
        - 2 * (Size.border.window + Size.padding.button) - 8)
    font_size = font_size or 17
    compactness = compactness or 1
    local border = math.max(1, Size.line.thin)
    local padding = math.max(2, Size.padding.small)
    local inner_width = width - 2 * (border + padding)
    local icon_col = math.max(35, math.floor(inner_width * .16))
    local gap = math.max(4, Size.padding.small)
    local separator = math.max(1, Size.line.thin)
    local text_width = math.max(120, inner_width - icon_col - 2 * gap - separator)
    local function textLine(str)
        local w = TextBoxWidget:new{
            text = str, face = Font:getFace(package.loaded["flipside_audit_style"].name(), font_size), bold = false,
            width = text_width, alignment = "left",
        }
        w.not_focusable = true
        return w
    end
    local function reportCard(kind, lines)
        local text_group = VerticalGroup:new{}
        for _, line in ipairs(lines) do table.insert(text_group, textLine(line)) end
        local text_h = text_group:getSize().h
        local icon_size = math.min(icon_col - 4, math.max(35, math.floor(small * .09)))
        local icon_file = reportIconPath(kind)
        local icon = icon_file and require("ui/widget/iconwidget"):new{
            file = icon_file, width = icon_size, height = icon_size,
        } or TextBoxWidget:new{
            text = kind == "overall" and "▂▅▇" or "□",
            face = package.loaded["flipside_audit_style"].face(), width = icon_col, alignment = "center",
        }
        local icon_cell = require("ui/widget/container/centercontainer"):new{
            dimen = Geom:new{w = icon_col, h = math.max(text_h, icon_size)},
            icon,
        }
        local height = math.max(text_h, icon_size)
        local layout = HorizontalGroup:new{
            icon_cell,
            HorizontalSpan:new{width=gap},
            LineWidget:new{dimen=Geom:new{w=separator,h=height},
                background=Blitbuffer.COLOR_GRAY},
            HorizontalSpan:new{width=gap},
            text_group,
        }
        local frame = require("ui/widget/container/framecontainer"):new{
            bordersize = border, padding = padding,
            radius = Size.radius.window,
            color = Blitbuffer.COLOR_GRAY, layout,
        }
        frame.not_focusable = true
        return frame
    end
    local function statsLines(heading, stats, seconds, note)
        local lines = {heading}
        if not stats or stats.total == 0 then
            lines[#lines+1] = "No reviews yet"
        elseif compactness >= 5 then
            -- Emergency screen-size fallback, without losing actual totals.
            lines[#lines+1] = string.format("%.1f%% correct · %.1f%% wrong",
                100*stats.correct/stats.total, 100*stats.wrong/stats.total)
            lines[#lines+1] = string.format("%d reviews · %d correct · %d wrong",
                stats.total, stats.correct, stats.wrong)
        else
            lines[#lines+1] = string.format("%.1f%% correct", 100*stats.correct/stats.total)
            lines[#lines+1] = string.format("%.1f%% wrong", 100*stats.wrong/stats.total)
            lines[#lines+1] = string.format("%d reviews", stats.total)
            lines[#lines+1] = string.format("%d correct · %d wrong", stats.correct, stats.wrong)
        end
        if seconds then lines[#lines+1] = "Study time · " .. studyTimeLabel(seconds) end
        if note and note > 0 then
            lines[#lines+1] = string.format("+%d unlabeled older reviews", note)
        end
        return lines
    end
    local schedule_lines = {"TODAY'S SCHEDULE"}
    if not schedule then
        schedule_lines[#schedule_lines+1] = "Schedule unavailable"
    else
        schedule_lines[#schedule_lines+1] = string.format("%d saved cards", schedule.saved_total)
        schedule_lines[#schedule_lines+1] = string.format("%d due today", schedule.total)
        if schedule.overdue > 0 then
            schedule_lines[#schedule_lines+1] = "Due now · " .. schedule.overdue
        end
        for _, key in ipairs({"morning", "afternoon", "night"}) do
            local group = schedule.sections[key]
            schedule_lines[#schedule_lines+1] = group.title .. " · " .. group.total
            for i=1, (compactness >= 4 and 0 or math.min(1, #group.slots)) do
                local slot = group.slots[i]
                schedule_lines[#schedule_lines+1] = string.format(
                    "%s · %d %s", slot.time, slot.count,
                    slot.count == 1 and "card" or "cards")
            end
            if compactness == 1 and #group.slots > 1 then
                schedule_lines[#schedule_lines+1] =
                    string.format("+%d more times · see list", #group.slots-1)
            end
        end
    end
    local stack = VerticalGroup:new{}
    local function insertCard(kind, lines)
        if #stack > 0 then
            table.insert(stack, VerticalSpan:new{width=math.max(3, Size.padding.small)})
        end
        table.insert(stack, reportCard(kind, lines))
    end
    insertCard("today", statsLines(period1, stats1, study1))
    insertCard("overall", statsLines(period2, stats2, study2, older))
    insertCard("schedule", schedule_lines)
    stack.not_focusable = true
    return {stack}
end

local function showExactSchedule(schedule)
    if not schedule then
        minimalInfo("Schedule unavailable")
        return
    end
    local items = {}
    if schedule.overdue > 0 then
        table.insert(items, {text="DUE NOW / OVERDUE · " .. schedule.overdue})
    end
    for _, key in ipairs({"morning", "afternoon", "night"}) do
        local group = schedule.sections[key]
        table.insert(items, {text=group.title .. " · " .. group.total .. " cards", bold=true})
        for _, slot in ipairs(group.slots) do
            table.insert(items, {text=slot.time .. "    " .. slot.count .. " card(s)"})
        end
    end
    if #items == 0 then items = {{text="No reviews remaining today"}} end
    local menu
    -- Exactly the same capsule, circular X and pager styling as Aa >
    -- Flashcards appearance, with unchanged schedule rows and callbacks.
    menu = require("flipside_rounded_menu").new{
        title = "Today's review times",
        item_table = items,
        onMenuSelect = function() return true end,
    }
    showAuditWidget(menu)
end

-- A compact, truly native KOReader pop-up rather than a full-screen patch.
-- ButtonDialog already implements tap-outside-to-close, centering and e-ink
-- repaint on dismissal; keep those event paths intact. The only new UI here
-- is the information cards and a small pager made from native ButtonTable.
-- We deliberately avoid ScrollableContainer and tall off-screen dialogs.
local function showAccuracyStats(word_filter, from_flashcards)
    -- The footer chart has its own model-picker label. Keep the original
    -- Learning analysis / Review accuracy wording and behavior unchanged.
    local function modelLabel(mode)
        if from_flashcards and mode == "sentence" then
            return "Sentence Card only"
        end
        return REVIEW_MODE_LABELS[mode]
    end
    local selected_mode = "all"
    local selected_page = 1
    local show_trends = false
    local dialog
    -- The global popup stays alive while the user moves between the two
    -- submenu shortcuts. Use in-place native button labels for their pager:
    -- there is no reason to query SQLite or rebuild three report cards.
    local navigator_label, navigator_dots, navigator_dots_box, navigator_row
    local popup_closed = false
    local redraw_pending = false
    local summary_snapshot, schedule_snapshot
    local time_snapshots = {}
    local preferred_pass
    local function pageLabel()
        if selected_page == 1 then
            return "Model: " .. modelLabel(selected_mode)
        end
        return ({"Model", "Last 7 + 30 days", "All review times", "Learning analysis"})[selected_page]
    end
    local function pageDots()
        local dots = {}
        for i = 1, 4 do dots[i] = i == selected_page and "●" or "○" end
        return table.concat(dots, "  ")
    end
    local function updatePagerOnly()
        if not dialog or not navigator_label or not navigator_dots then return end
        -- Button:setText(text, same_width) preserves its hitbox and native
        -- parent widget when possible. TextWidget:setText keeps the dots row.
        navigator_label:setText(pageLabel(), navigator_label.width)
        navigator_dots:setText(pageDots())
        -- Queue one repaint on the original dialog. Prefer only the two pager
        -- rows when the native geometry is available after first paint.
        UIManager:setDirty(dialog, function()
            local row = navigator_row and navigator_row.dimen
            local dots = navigator_dots_box and navigator_dots_box.dimen
            if row and dots and row.y and dots.y and row.y > 0 and dots.y >= row.y then
                return "ui", Geom:new{
                    x=math.min(row.x, dots.x), y=row.y,
                    w=math.max(row.x+row.w, dots.x+dots.w)-math.min(row.x,dots.x),
                    h=math.max(row.y+row.h, dots.y+dots.h)-row.y,
                }
            end
            return "ui", dialog.movable and dialog.movable.dimen
        end)
    end
    -- Make the model explicit instead of cycling through an invisible list
    -- one tap at a time. This also makes Sentence Card selectable with ZERO
    -- existing reviews; only the displayed filter changes, never review data.
    local function showModelPicker(on_change)
        local picker
        local items = {}
        for _, mode in ipairs(REVIEW_MODE_ORDER) do
            local checked = selected_mode == mode
            items[#items+1] = {
                text = (checked and "●  " or "○  ") .. modelLabel(mode),
                bold = checked,
                audit_model_choice = mode,
            }
        end
        items[#items+1] = {text="Done", audit_model_done=true, bold=true}
        picker = require("flipside_rounded_menu").new{
            title = "Review model",
            item_table = items,
            onMenuSelect = function(_, item)
                if not item then return true end
                if item.audit_model_done then
                    UIManager:close(picker)
                    return true
                end
                local mode = item.audit_model_choice
                if mode then
                    UIManager:close(picker)
                    if selected_mode ~= mode then
                        selected_mode = mode
                        on_change()
                    end
                end
                return true
            end,
        }
        showAuditWidget(picker)
    end

    -- Keep word-specific audits as their original minimal native dialog.
    -- The compact three-card popup is only for the global statistics view.
    if word_filter ~= nil then
        local function showWord()
            local data, err = getAccuracySummary(word_filter)
            if not data then minimalInfo("Cannot refresh reviews: " .. tostring(err)); return end
            local stats = data[selected_mode]
            local widgets = {accuracyText(modelLabel(selected_mode))}
            local a = accuracyWidgets(show_trends and "LAST 7 DAYS" or "TODAY",
                show_trends and stats.week or stats.today)
            local b = accuracyWidgets(show_trends and "LAST 30 DAYS" or "ALL TIME",
                show_trends and stats.month or stats.overall)
            for _, widget in ipairs(a) do widgets[#widgets+1] = widget end
            for _, widget in ipairs(b) do widgets[#widgets+1] = widget end
            local buttons = {
                {{text="Model: " .. modelLabel(selected_mode),callback=function()
                    showModelPicker(function()
                        UIManager:nextTick(function() safeUI("word model",showWord) end)
                    end)
                end}},
                {{text=show_trends and "Today + all time" or "Last 7 + 30 days",
                    callback=function()
                        show_trends=not show_trends
                        UIManager:nextTick(function() safeUI("word period",showWord) end)
                    end}},
                {{text="Close",callback=function()
                    if dialog then UIManager:close(dialog); dialog=nil end
                end}},
            }
            if dialog then UIManager:close(dialog) end
            dialog=minimalDialog(nil,widgets,buttons)
        end
        showWord()
        return
    end
    local pages = {"Model", "Last 7 + 30 days",
        "All review times", "Learning analysis"}
    local openDialog
    local function requestRedraw()
        -- Multiple quick taps update the selected page synchronously, but
        -- queue at most one expensive redraw. A dismissed popup is never
        -- resurrected by a pending nextTick callback.
        if redraw_pending or popup_closed then return end
        redraw_pending = true
        UIManager:nextTick(function()
            redraw_pending = false
            if popup_closed then return end
            if dialog and type(UIManager.isWidgetShown)=="function"
                and not UIManager:isWidgetShown(dialog) then return end
            safeUI("refresh popup statistics", openDialog)
        end)
    end
    openDialog = function()
        if not summary_snapshot then
            local fresh, fresh_err = getAccuracySummary(word_filter)
            if not fresh then
                minimalInfo("Cannot refresh reviews: " .. tostring(fresh_err))
                return
            end
            summary_snapshot = fresh
        end
        local stats = summary_snapshot[selected_mode]
        if not time_snapshots[selected_mode] then
            time_snapshots[selected_mode] = readStudyTime(selected_mode)
        end
        local times = time_snapshots[selected_mode]
        local unknown_stats = summary_snapshot.unknown
        if schedule_snapshot == nil then
            local ok_schedule, loaded_schedule = pcall(readTodaySchedule)
            if ok_schedule then schedule_snapshot = loaded_schedule or false
            else
                warn("Could not load today's schedule:", loaded_schedule)
                schedule_snapshot = false
            end
        end
        local schedule = schedule_snapshot or nil
        local small = math.min(Device.screen:getWidth(), Device.screen:getHeight())
        local height = Device.screen:getHeight()
        -- 80% leaves a large reliable tap-outside target on both sides.
        local popup_width = math.floor(small * .80)
        local inner_width = popup_width - 2*(Size.border.window + Size.padding.button) - 8
        local style = package.loaded["flipside_audit_style"]
        local current_label = pageLabel()
        local function changePage(delta)
            if popup_closed then return end
            selected_page = (selected_page - 1 + delta) % #pages + 1
            -- Switching between Today/All time and Last 7/30 changes card
            -- data and requires a single redraw. Moving over the two action
            -- pages changes ONLY the native pager's label and dots.
            local old_trends = show_trends
            if selected_page == 1 then show_trends = false end
            if selected_page == 2 then show_trends = true end
            updatePagerOnly()
            if old_trends ~= show_trends then requestRedraw() end
        end
        local function activatePage()
            if selected_page == 1 then
                if from_flashcards then
                    -- The footer chart's model label cycles in one tap, just
                    -- like the flashcard model carousel: no second menu.
                    -- This is deliberately scoped to the chart shortcut;
                    -- Learning Analysis keeps its original model picker.
                    local next_index = 1
                    for i, mode in ipairs(REVIEW_MODE_ORDER) do
                        if mode == selected_mode then
                            next_index = i % #REVIEW_MODE_ORDER + 1
                            break
                        end
                    end
                    selected_mode = REVIEW_MODE_ORDER[next_index]
                    updatePagerOnly()
                    requestRedraw()
                else
                    showModelPicker(function()
                        updatePagerOnly()
                        requestRedraw()
                    end)
                end
                return
            end
            if selected_page == 2 then
                show_trends = not show_trends
                requestRedraw()
                return
            end
            -- Keep the native statistics popup in UIManager's window stack.
            -- The selected submenu (All review times / Learning analysis)
            -- is displayed ABOVE it. Closing that submenu with its X only
            -- removes the submenu and reveals this same statistics popup,
            -- with its active page and review model unchanged. This also
            -- delegates restoration of the e-ink content to UIManager.
            UIManager:nextTick(function()
                safeUI("open statistics section", function()
                    local bridge = package.loaded["flipside_learning_audit_bridge"]
                    if selected_page == 3 then
                        local ok, schedule_now = pcall(readTodaySchedule)
                        showExactSchedule(ok and schedule_now or nil)
                    elseif selected_page == 4 and bridge and bridge.showLearningAnalysis then
                        bridge.showLearningAnalysis()
                    else
                        minimalInfo("This section is unavailable.", 3)
                    end
                end)
            end)
        end
        -- We build once, then compact only if the real measured widget height
        -- would exceed 87% of the screen. Unlike an estimate, this also handles
        -- user-selected UI fonts and different Kindle screen resolutions.
        local popup
        -- KOReader ButtonDialog may try to scroll its OUTER ButtonTable when
        -- the _added_widgets (our three report cards) use all available
        -- vertical space. This dialog has buttons={}, so the outer table has
        -- ZERO rows. Its getStepScrollGrid() then dereferences a missing
        -- row offset (seen on Kindle in buttontable.lua:230).
        --
        -- Do NOT construct ButtonDialog until the actual text/card widgets
        -- fit. Merely measuring candidate.movable after ButtonDialog:new is
        -- too late, because that constructor can already have crashed.
        local safe_content_height = math.max(1, math.floor(math.min(
            height * .82,
            height - 2 * Size.padding.buttontable
                - 2 * Size.margin.default
                - Size.line.medium
                - 2 * (Size.border.window + Size.padding.button) - 6)))
        for pass = preferred_pass or 1, 8 do
            local font_size = ({17,17,16,15,14,14,13,12})[pass]
            local compactness = ({1,2,2,3,4,5,5,5})[pass]
            local content = VerticalGroup:new{}
            local function statsHelp()
                showAuditWidget(InfoMessage:new{
                    text = "Statistics shows your real reviews.\n\n"
                        .. "Today: answers from today.\n"
                        .. "All time: answers from all days.\n"
                        .. "Use the arrows to see recent days, review times "
                        .. "or Learning Analysis.\n\n"
                        .. "CRAM practice does not change these review scores.",
                    show_icon = false,
                    width_factor = .82,
                })
            end
            local stats_header_width = popup_width
                - 2 * (Size.border.window + Size.padding.button) - 8
            content[#content+1] = require("flipside_popup_header").new(
                "STATISTICS", stats_header_width, statsHelp, 17)
            -- Included in the existing height preflight, before the native
            -- ButtonDialog constructor, to avoid the Kindle empty-table crash.
            if word_filter == nil then
                local block = accuracyStackedCards(
                    modelLabel(selected_mode),
                    show_trends and "LAST 7 DAYS" or "TODAY",
                    show_trends and "LAST 30 DAYS" or "ALL TIME",
                    show_trends and stats.week or stats.today,
                    show_trends and stats.month or stats.overall,
                    times and (show_trends and times.week or times.today),
                    times and (show_trends and times.month or times.overall),
                    selected_mode == "all" and unknown_stats.overall.total or 0,
                    schedule, popup_width, font_size, compactness)
                for _, w in ipairs(block) do content[#content+1] = w end
            else
                for _, w in ipairs(accuracyWidgets("TODAY",stats.today,nil)) do
                    content[#content+1] = w
                end
                for _, w in ipairs(accuracyWidgets("ALL TIME",stats.overall,nil)) do
                    content[#content+1] = w
                end
            end
            content[#content+1] = VerticalSpan:new{width=math.max(2,Size.padding.small)}
            local row_width = popup_width - 2*(Size.border.window + Size.padding.button) - 8
            local rule = LineWidget:new{dimen=Geom:new{
                w=row_width,h=math.max(1,Size.line.thin)},
                background=Blitbuffer.COLOR_GRAY}
            content[#content+1] = rule
            -- A larger INVISIBLE target improves reliability on Kindle:
            -- the arrow glyph stays at 22pt while touch area is >=48px high.
            local arrow_w = math.max(48, math.floor(row_width * .15))
            local arrow_h = math.max(48, Device.screen:scaleBySize(44))
            local controls = ButtonTable:new{
                width = row_width,
                buttons = {{
                    {text="‹",width=arrow_w,height=arrow_h,
                        font_face=style.name(),font_size=22,
                        font_bold=false,callback=function()changePage(-1)end},
                    {text=current_label,id="audit_current_section",
                        height=arrow_h,font_face=style.name(),font_size=font_size,
                        font_bold=false,callback=activatePage},
                    {text="›",width=arrow_w,height=arrow_h,
                        font_face=style.name(),font_size=22,
                        font_bold=false,callback=function()changePage(1)end},
                }},
            }
            content[#content+1] = controls
            -- Use a native TextWidget with setText: no TextBoxWidget reflow
            -- or construction of a new dialog when the active dot changes.
            local dots_widget = require("ui/widget/textwidget"):new{
                text=pageDots(),
                face=Font:getFace(style.name(), math.max(13, font_size-2)),
                bold=false,
            }
            dots_widget.not_focusable = true
            local dots_box = require("ui/widget/container/centercontainer"):new{
                dimen=Geom:new{w=row_width,h=dots_widget:getSize().h},
                dots_widget,
            }
            content[#content+1] = dots_box
            content.not_focusable = true
            -- Measure BEFORE ButtonDialog:new.  With buttons={} the native
            -- dialog cannot scroll a tall title/_added_widgets area safely.
            -- This is what failed on the user's Kindle, not the SQLite data.
            local content_height = content:getSize().h
            if content_height > safe_content_height then
                -- Keep trying a smaller version without constructing the
                -- oversized native dialog (the constructor is the crash).
                if content.free then content:free() end
            else
            local candidate = ButtonDialog:new{
                width=popup_width,buttons={},_added_widgets={content},
                -- Keep native touch-outside dismissal and background repaint.
                dismissable=true,use_info_style=true,
                info_padding=0,info_margin=0,
                tap_close_callback=function() popup_closed=true end,
            }
            local measured = candidate.movable[1]:getSize().h
            if measured <= height * .87 then
                if popup and popup.widget ~= candidate and popup.widget.free then
                    popup.widget:free()
                end
                popup = {widget=candidate,height=measured,pass=pass,
                    controls=controls,dots=dots_widget,dots_box=dots_box}
                break
            elseif not popup or measured < popup.height then
                if popup and popup.widget.free then popup.widget:free() end
                popup = {widget=candidate,height=measured,pass=pass,
                    controls=controls,dots=dots_widget,dots_box=dots_box}
            elseif candidate.free then
                candidate:free()
            end
            end -- passed preflight: the outer zero-row ButtonTable cannot overflow
        end
        if not popup then
            -- Fail gracefully if even the compact report cannot fit. Never
            -- trigger native empty-table scrolling or alter review data.
            warn("Stats popup too tall for Kindle screen", safe_content_height)
            minimalInfo("This screen is too small for the statistics panel. Try a smaller UI font.", 8)
            return
        end
        if dialog then UIManager:close(dialog) end
        dialog = popup.widget
        preferred_pass = popup.pass
        navigator_row = popup.controls
        navigator_label = navigator_row:getButtonById("audit_current_section")
        navigator_dots = popup.dots
        navigator_dots_box = popup.dots_box
        -- The three-card statistics panel alone covers the measured card
        -- frame, just as the dictionary's Saved Meanings panel already does.
        require("flipside_frame_cover").attach(dialog)
        showAuditWidget(dialog)
    end
    openDialog()
end

local function minimalMenu(title, items, on_select, on_hold)
    local opts = {
        title = title,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = on_select,
    }
    if on_hold then opts.onMenuHold = on_hold end
    -- Preserve onMenuSelect/onMenuHold, selection and counters. Replace
    -- only the native menu style; no global patches or changed data paths.
    return require("flipside_rounded_menu").new(opts)
end

local showDashboard
local active_dashboard
local active_dashboard_refresh
local active_category_refresh
-- The dashboard/category menus cache their displayed rows while open. After a
-- confirmed FlipSide deletion, refresh only those UI rows from the live private
-- vocabulary database; do not change review history or SRS scheduling.
local function refreshOpenLearningMenus()
    -- A visible category can outlive its parent dashboard's foreground state.
    -- Refresh each open menu independently without navigating away from it.
    if active_dashboard and UIManager:isWidgetShown(active_dashboard)
            and type(active_dashboard_refresh) == "function" then
        local ok, err = pcall(active_dashboard_refresh)
        if not ok then warn("Could not refresh Learning analysis after deletion:", err) end
    end
    if type(active_category_refresh) == "function" then
        local list_ok, list_err = pcall(active_category_refresh)
        if not list_ok then warn("Could not refresh Learning category after deletion:", list_err) end
    end
end

local function scheduleLearningMenuRefresh()
    -- Defer repaint until the DB.remove / DB.purge callback and any deletion
    -- confirmation have finished, avoiding mutations during touch dispatch.
    UIManager:nextTick(refreshOpenLearningMenus)
end

local function showCategory(plugin, DB, kind, cards, dashboard, on_data_changed)
    if type(cards) ~= "table" or #cards == 0 then
        showAuditWidget(InfoMessage:new{text = _("No words in this category."), timeout = 3})
        return
    end
    local list
    local selected = {}
    local can_delete = kind == "problematic" or kind == "demoted"
    -- Assigned after the row builders; the word details callback uses it.
    local refreshCategoryAfterReset

    local function removeWord(word)
        local ok, result = pcall(DB.remove, DB, {word = word})
        if not ok or result == false then
            warn("Could not delete", word, result)
            showAuditWidget(InfoMessage:new{text = _("Could not delete this word.")})
            return false
        end
        return true
    end

    local function showDetails(card)
        local dialog

        local function confirmReset(label, from_time, before_time, all_history)
            local preview, read_err = resetPreview(card.word, from_time, before_time, all_history)
            if not preview then
                showAuditWidget(InfoMessage:new{text = "Could not read review history: " .. tostring(read_err)})
                return
            end
            if preview.count == 0 and preview.legacy_count == 0 then
                if not all_history and preview.older_total > 0
                    and preview.singleton_time == nil then
                    -- Several old attempts were saved only as totals. Do not
                    -- attribute them to any arbitrary day. Offer a safe,
                    -- explicitly confirmed whole-history reset instead.
                    showAuditWidget(ConfirmBox:new{
                        text = string.format(
                            "No dated reviews found for '%s' in %s.\n\n"
                            .. "%d older review(s) do not have individual dates, "
                            .. "so they cannot be cleared by period.\n\n"
                            .. "Open All history instead?",
                            card.word, label, preview.older_total),
                        ok_text = "All history",
                        ok_callback = function()
                            confirmReset("All history", nil, nil, true)
                        end,
                    })
                else
                    showAuditWidget(InfoMessage:new{
                        text = all_history and "This word already has no review history."
                            or "No reviews found in the selected period.",
                        timeout = 4,
                    })
                end
                return
            end
            local prompt = string.format(
                "Reset reviews for '%s'?\n\nPeriod: %s\nReviews: %d",
                card.word, label, preview.count)
            if preview.legacy_count > 0 then
                prompt = prompt .. string.format(
                    all_history and "\nOlder review(s): %d"
                        or "\nDated older single review: %d", preview.legacy_count)
            end
            prompt = prompt .. "\n\nOnly Learning Audit history changes. Words, review dates and Activity Stats stay unchanged."
            showAuditWidget(ConfirmBox:new{
                text = prompt,
                ok_text = "Reset reviews",
                ok_callback = function()
                    safeUI("reset word reviews", function()
                        local n, reset_err = resetReviews(card.word, from_time, before_time, all_history)
                        if n == nil then
                            showAuditWidget(InfoMessage:new{
                                text = "Reset failed: " .. tostring(reset_err), timeout = 5})
                            return
                        end
                        -- Keep both the category and the user's current page.
                        -- Update the existing list and dashboard rather than
                        -- closing both menus and reopening Learning analysis.
                        UIManager:close(dialog)
                        refreshCategoryAfterReset(card)
                        -- Stay in the word details with the freshly calculated
                        -- totals. Closing it returns to the same category page.
                        showDetails(card)
                        showAuditWidget(InfoMessage:new{
                            text = string.format("Cleared %d review(s) for '%s'.",
                                n, card.word),
                            timeout = 4,
                        })
                    end)
                end,
            })
        end

        local function customReset()
            local input_dialog
            input_dialog = InputDialog:new{
                title = "Custom review period",
                input = os.date("%Y-%m-%d") .. " to " .. os.date("%Y-%m-%d"),
                hint = "YYYY-MM-DD to YYYY-MM-DD",
                buttons = {{
                    {text = "Cancel", id = "close", callback = function()
                        UIManager:close(input_dialog)
                    end},
                    {text = "Continue", is_enter_default = true, callback = function()
                        local entry = (input_dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                        local first, last = entry:match("^(%d%d%d%d%-%d%d%-%d%d)%s+to%s+(%d%d%d%d%-%d%d%-%d%d)$")
                        if not first then first, last = entry:match("^(%d%d%d%d%-%d%d%-%d%d)%s*%.%.%s*(%d%d%d%d%-%d%d%-%d%d)$") end
                        local from_time = first and parseCalendarDate(first) or nil
                        local end_from, end_before = last and parseCalendarDate(last) or nil
                        if not from_time or not end_from or from_time > end_from then
                            showAuditWidget(InfoMessage:new{
                                text = "Use valid dates, earliest first: YYYY-MM-DD to YYYY-MM-DD",
                                timeout = 5,
                            })
                            return
                        end
                        UIManager:close(input_dialog)
                        confirmReset(first .. " – " .. last, from_time, end_before, false)
                    end},
                }},
            }
            showAuditWidget(input_dialog)
            if input_dialog.onShowKeyboard then input_dialog:onShowKeyboard() end
        end

        local function showResetOptions()
            local choices
            local next_day = startDay(-1)
            local options = {
                {text = "Today", label = "Today", start = startDay(0), finish = next_day},
                {text = "Yesterday", label = "Yesterday", start = startDay(1), finish = startDay(0)},
                {text = "Last 7 days", label = "Last 7 days", start = startDay(6), finish = next_day},
                {text = "Last 30 days", label = "Last 30 days", start = startDay(29), finish = next_day},
                {text = "Custom period…", action = "custom"},
                {text = "All history", label = "All history", all_history = true},
            }
            choices = minimalMenu("Reset reviews · " .. card.word, options,
                function(_, item)
                    safeUI("select reset period", function()
                        if not item then return end
                        UIManager:close(choices)
                        if item.action == "custom" then
                            customReset()
                        else
                            confirmReset(item.label, item.start, item.finish,
                                item.all_history == true)
                        end
                    end)
                    return true
                end)
            showAuditWidget(choices)
        end
        local buttons = {
            {{text = _("Close"), callback = function() UIManager:close(dialog) end}},
        }
        if can_delete then
            table.insert(buttons, 1, {{
                text = selected[card.word] and _("Deselect") or _("Select"),
                callback = function()
                    safeUI("toggle selection", function()
                        selected[card.word] = not selected[card.word] or nil
                        UIManager:close(dialog)
                        if list then list:updateItems() end
                    end)
                end,
            }})
        end
        table.insert(buttons, 1, {{text = "Review accuracy", callback = function()
            safeUI("word review statistics", function() showAccuracyStats(card.word) end)
        end}})
        table.insert(buttons, 1, {{text = "Reset reviews", callback = function()
            safeUI("reset options", showResetOptions)
        end}})
        table.insert(buttons, {{text = _("Delete word…"), callback = function()
            safeUI("delete confirmation", function()
                UIManager:close(dialog)
                showAuditWidget(ConfirmBox:new{
                    text = string.format(_("Delete '%s' from Vocabulary Builder?"), card.word),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        safeUI("delete word", function()
                            -- DB.remove schedules a refresh of the same open
                            -- category and dashboard after its confirmed write.
                            removeWord(card.word)
                        end)
                    end,
                })
            end)
        end}})
        dialog = minimalDialog(card.word, detailText(card), buttons)
    end

    -- SortWidget is for rearranging items, not opening vocabulary entries.
    -- A normal Menu avoids its moving/checkbox state machine and uses the
    -- same native list presentation as the dashboard.
    local function selectedCount()
        local n = 0
        for _, checked in pairs(selected) do if checked then n = n + 1 end end
        return n
    end
    local function buildRows()
        local rows = {}
        for _, card in ipairs(cards) do
            local r = card.record or {}
            local total = tonumber(r.total) or 0
            rows[#rows + 1] = {
                text = card.word,
                mandatory = total > 0 and string.format("%d/%d", tonumber(r.correct) or 0, total) or nil,
                audit_card = card,
                checked_func = can_delete and function() return selected[card.word] == true end or nil,
            }
        end
        if #cards == 0 then
            -- Keep the category open even when resetting its last word moves
            -- that word to Not reviewed (or to another category).
            rows[#rows + 1] = {
                text = _("No words in this category."), select_enabled = false,
            }
        end
        if can_delete and selectedCount() > 0 then
            rows[#rows + 1] = {
                text = string.format("Delete selected (%d)…", selectedCount()),
                action = "delete_selected",
            }
        end
        return rows
    end
    local function updateList()
        if list and type(list.updateItems) == "function" then
            -- Menu:updateItems() preserves the page and clamps it when the
            -- number of pages shrinks, avoiding a jump back to page 1.
            local current_page = list.page or 1
            list.item_table = buildRows()
            local new_title = categories[kind] .. "  ·  " .. #cards
            list.title = new_title
            if list.title_bar and type(list.title_bar.setTitle) == "function" then
                list.title_bar:setTitle(new_title, true)
            end
            list.page = current_page
            list:updateItems()
        end
    end
    active_category_refresh = function()
        if not list or not UIManager:isWidgetShown(list) then return end
        -- The dashboard replaces its bucket tables on refresh, so the category
        -- cannot keep using the old `cards` array after a deletion. Re-read
        -- the existing private word database and rebuild the displayed category.
        local ok, current_cards = pcall(readAllCards, DB)
        if not ok then
            warn("Could not refresh open Learning category:", current_cards)
            return
        end
        local remaining = {}
        local present = {}
        for _, current in ipairs(current_cards) do
            if current.category == kind then
                remaining[#remaining + 1] = current
                present[current.word] = true
            end
        end
        table.sort(remaining, function(a, b)
            return a.word:lower() < b.word:lower()
        end)
        cards = remaining
        for word in pairs(selected) do
            if not present[word] then selected[word] = nil end
        end
        updateList()
    end
    refreshCategoryAfterReset = function(card)
        local updated = state[card.word] or newRecord()
        local new_kind = classify(updated)
        card.record = updated
        card.category = new_kind
        if new_kind ~= kind then
            -- This word no longer belongs to the open category. Keep the
            -- surrounding list, page, and selection of other words intact.
            for i = #cards, 1, -1 do
                if cards[i].word == card.word then
                    table.remove(cards, i)
                    break
                end
            end
            selected[card.word] = nil
        end
        updateList()
        -- Refresh counters behind this menu. Do not close/reopen that menu.
        if on_data_changed then on_data_changed() end
    end
    local function deleteSelected()
        local chosen = {}
        for word, checked in pairs(selected) do
            if checked then chosen[#chosen + 1] = word end
        end
        if #chosen == 0 then return end
        table.sort(chosen)
        showAuditWidget(ConfirmBox:new{
            text = string.format(_("Delete %d selected words?"), #chosen),
            ok_text = _("Delete"),
            ok_callback = function()
                safeUI("delete selected", function()
                    local removed = 0
                    for _, word in ipairs(chosen) do
                        if removeWord(word) then removed = removed + 1 end
                    end
                    if plugin and plugin.widget and type(plugin.widget.reloadItems) == "function" then
                        pcall(plugin.widget.reloadItems, plugin.widget)
                    end
                    showAuditWidget(InfoMessage:new{
                        text = string.format(_("Deleted %d of %d words."), removed, #chosen),
                    })
                    -- Keep this category and its current page open; the
                    -- deletion hooks update both visible lists on next tick.
                end)
            end,
        })
    end

    list = minimalMenu(categories[kind] .. "  ·  " .. #cards, buildRows(),
        function(menu_widget, item)
            safeUI("category entry", function()
                if type(item) ~= "table" then return end
                if item.action == "delete_selected" then
                    deleteSelected()
                elseif item.audit_card then
                    showDetails(item.audit_card)
                end
            end)
            return true
        end,
        function(menu_widget, item)
            if not can_delete or type(item) ~= "table" or not item.audit_card then
                return false
            end
            safeUI("category selection", function()
                local word = item.audit_card.word
                selected[word] = not selected[word] or nil
                updateList()
            end)
            return true
        end)
    showAuditWidget(list)
end

local function showRules()
    local tips = {
        {text = "Learned", detail = "5 successful reviews on different days (20h apart), at least 8 reviews total, and 80% success overall or in the last 10 reviews."},
        {text = "Learning", detail = "Reviewed words that have not yet reached the Learned criteria."},
        {text = "Needs relearning", detail = "A previously learned word with 2 consecutive misses, or 3 misses in the last 5 attempts."},
        {text = "Difficult", detail = "At least 5 reviews with frequent misses."},
        {text = "Not reviewed", detail = "Words without recorded Learning Audit attempts."},
        {text = "Review rules", detail = "Skipped Practice cards do not count. Undo cancels the corresponding recorded attempt. Resetting Learning Audit history does not change Vocabulary Builder due dates or Activity Stats."},
    }
    local menu = minimalMenu("Learning categories", tips, function(_, item)
        if item and item.detail then minimalInfo(item.text .. "\n\n" .. item.detail) end
        return true
    end)
    showAuditWidget(menu)
end

-- A manual, two-way exchange using a NEW isolated format, independent of
-- any prior attempt. This menu never edits the stock Vocabulary Builder DB.
local function showManualSync(refresh_dashboard)
    local dlg
    local function closeDialog()
        if dlg then UIManager:close(dlg); dlg = nil end
    end
    local function showInstructions()
        local sections = {
            {
                text = "Transfer steps",
                detail = "1. Kindle: Export sync data.\n"
                    .. "2. Copy export.laex1 to Android as import.laex1.\n"
                    .. "3. Android: Preview & import, then Export sync data.\n"
                    .. "4. Copy Android export.laex1 to Kindle as import.laex1.\n"
                    .. "5. Kindle: Preview & import.",
            },
            {
                text = "File location",
                detail = "Place import.laex1 inside:\n"
                    .. "koreader/settings/learning_audit_manual_exchange_v1/\n\n"
                    .. "An export creates export.laex1 in the same directory.",
            },
            {
                text = "What sync includes",
                detail = "Dated answers, their recorded modes, Undo, reset markers "
                    .. "and archived flags. Imports go into a separate Learning Audit "
                    .. "SQLite database; they never replace Vocabulary Builder "
                    .. "words, schedules or due dates. Older undated totals are not transferred.",
            },
            {
                text = "Before syncing",
                detail = "Install this updated patch on both devices, correct both "
                    .. "device clocks and keep backups. Sync both devices before "
                    .. "resetting or deleting a word. Earlier abandoned sync formats "
                    .. "are not compatible with this exchange file.",
            },
        }
        local help = minimalMenu("Manual sync help", sections, function(_, item)
            if item and item.detail then minimalInfo(item.text .. "\n\n" .. item.detail) end
            return true
        end)
        showAuditWidget(help)
    end
    local function exportData()
        if not replayJournal() then
            showAuditWidget(InfoMessage:new{
                text = "Export cancelled: pending local reviews could not be saved."})
            return
        end
        local folder, folder_err = syncEnsureFolder()
        if not folder then error(folder_err) end
        local events, err = syncCollect(nil, true)
        if not events then error(err) end
        table.sort(events, function(a, b) return a.event_key < b.event_key end)
        local content, ser_err = syncSerialize(events)
        if not content then error(ser_err) end
        local saved, save_err = syncWriteFile(SYNC_EXPORT, content)
        if not saved then error(save_err) end
        showAuditWidget(InfoMessage:new{
            text = string.format("Export complete: %d dated events.\n\n%s\n\n"
                .. "Transfer this file manually and rename it to import.laex1 on the other device.",
                #events, SYNC_EXPORT),
        })
    end
    local function importData()
        if not replayJournal() then
            showAuditWidget(InfoMessage:new{
                text = "Import cancelled: pending local reviews could not be saved."})
            return
        end
        local folder, folder_err = syncEnsureFolder()
        if not folder then error(folder_err) end
        local events, read_err, file_fingerprint = syncReadFile(SYNC_IMPORT)
        if not events then
            showAuditWidget(InfoMessage:new{
                text = "Cannot open import.laex1: " .. tostring(read_err)
                    .. "\n\nCopy the file into:\n" .. SYNC_DIR,
            })
            return
        end
        local preview, prev_err = syncPreview(events)
        if not preview then
            showAuditWidget(InfoMessage:new{text = "Import rejected: " .. tostring(prev_err)})
            return
        end
        if preview.new == 0 and preview.updated == 0 then
            showAuditWidget(InfoMessage:new{
                text = string.format("Already synchronized.\n%d events checked; no changes needed.",
                    preview.total),
            })
            return
        end
        showAuditWidget(ConfirmBox:new{
            text = string.format("PREVIEW - MANUAL SYNC\n\n"
                .. "Incoming events: %d\nNew events: %d\n"
                .. "Visibility / Undo updates: %d\nAlready known: %d\n\n"
                .. "Only the separate remote-sync database will change. "
                .. "The original local Learning Audit database and Vocabulary Builder "
                .. "will NOT be overwritten. A backup is required before import.\n\n"
                .. "Import these changes?",
                preview.total, preview.new, preview.updated, preview.existing),
            ok_text = "Import & merge",
            ok_callback = function()
                safeUI("manual sync confirmed import", function()
                    -- Re-validate the exact source after confirmation to avoid
                    -- importing a file swapped between Preview and Import.
                    local fresh, fresh_err, new_fingerprint = syncReadFile(SYNC_IMPORT)
                    if not fresh then error(fresh_err) end
                    if new_fingerprint ~= file_fingerprint then
                        error("import file changed since preview; please preview again")
                    end
                    local recheck, recheck_err = syncPreview(fresh)
                    if not recheck then error(recheck_err) end
                    if recheck.new ~= preview.new or recheck.updated ~= preview.updated
                        or recheck.total ~= preview.total then
                        error("import file changed since preview; please preview again")
                    end
                    -- Establish the schema and close all handles before backup.
                    local ready, open_err = withSyncDB(function(db) return true end)
                    if not ready then error(open_err) end
                    local backup, backup_err = syncBackupStore()
                    if not backup then error(backup_err) end
                    local ok, apply_err = syncApply(fresh)
                    if not ok then error(apply_err) end
                    rebuildAll()
                    if type(refresh_dashboard) == "function" then refresh_dashboard() end
                    showAuditWidget(InfoMessage:new{
                        text = string.format("Manual sync complete.\n"
                            .. "Imported %d new events; applied %d history updates.\n\n"
                            .. "Remote store backup:\n%s",
                            recheck.new, recheck.updated, backup),
                    })
                end)
            end,
        })
    end
    local function guarded(action, fn)
        local ok, err = pcall(fn)
        if not ok then
            warn("Manual sync / " .. action .. ":", err)
            showAuditWidget(InfoMessage:new{
                text = "Manual sync " .. action .. " failed:\n" .. tostring(err),
            })
        end
    end
    dlg = minimalMenu("Manual sync", {
        {text = "Export sync data", action = "export"},
        {text = "Preview & import", action = "import"},
        {text = "How manual sync works", action = "help"},
    }, function(_, item)
        if not item then return true end
        if item.action == "export" then guarded("export", exportData)
        elseif item.action == "import" then guarded("preview", importData)
        elseif item.action == "help" then showInstructions() end
        return true
    end)
    showAuditWidget(dlg)
end

-- CLOUD SYNC v1 -- Transport layer around the *existing* isolated audit merge.
-- The native KOReader Cloud storage plugin owns network access, credentials,
-- conditional HTTP upload and conflict retries. No custom HTTP requests, no
-- changes to the Vocabulary Builder DB or to the v2.7 local audit database.
-- The cloud file has its own basename and is not the manual import/export file.
local CLOUD_FILE = DIR .. "/learning_audit_cloud_exchange_v1.laex1"
local CLOUD_SETTINGS_PATH = DIR .. "/learning_audit_cloud_sync.lua"
local cloud_settings = LuaSettings:open(CLOUD_SETTINGS_PATH)
local cloud_sync_started

-- The KOReader PluginLoader wraps on* handlers in callable HandlerSandbox
-- tables. Checking type(onShowCloudStorageList) == "function" incorrectly
-- rejects a working cloud plugin; registered plugins may also live in a
-- different UI context (e.g. the file manager rather than ReaderUI).
-- Resolve the official cloud service without touching KOReader plugin files,
-- settings or cloud account credentials.
local cloud_service_adapter
local function cloudHandlerCallable(handler)
    if type(handler) == "function" then return true end
    if type(handler) ~= "table" then return false end
    local mt = getmetatable(handler)
    return type(mt) == "table" and type(mt.__call) == "function"
end

local function cloudUsable(cs)
    return cs and type(cs.sync) == "function"
        and cloudHandlerCallable(cs.onShowCloudStorageList)
        and type(cs.loadSettings) == "function"
        and type(cs.providers) == "table"
end

local function cloudGetPlugin(plugin)
    -- Preferred: use the fully initialized, enabled KOReader plugin.
    local cs = plugin and plugin.ui and plugin.ui.cloudstorage
    if cloudUsable(cs) then return cs end

    local loaded, loader = pcall(require, "pluginloader")
    if not loaded or type(loader) ~= "table" then
        return nil, "KOReader PluginLoader is not available."
    end
    if type(loader.getPluginInstance) == "function" then
        local ok, live = pcall(loader.getPluginInstance, loader, "cloudstorage")
        if ok and cloudUsable(live) then return live end
    end

    -- ReaderUI can have no cloudstorage property even if the service is
    -- enabled in the file manager. Make a small, detached transport adapter
    -- from the *already loaded and enabled* official plugin class instead of
    -- initializing a second plugin (which would register duplicate menus).
    if cloudUsable(cloud_service_adapter) then return cloud_service_adapter end
    for _, module in ipairs(loader.enabled_plugins or {}) do
        if module.name == "cloudstorage" and type(module.getProviders) == "function"
                and type(module.loadSettings) == "function"
                and type(module.path) == "string" then
            local adapter = setmetatable({path = module.path}, {__index = module})
            local ok, reason = pcall(function()
                adapter:getProviders()
                adapter:loadSettings()
                assert(type(adapter.servers) == "table", "No cloud accounts loaded")
            end)
            if ok and cloudUsable(adapter) then
                cloud_service_adapter = adapter
                return adapter
            end
            warn("Could not access enabled Cloud storage service:", reason)
        end
    end
    return nil, "Cloud storage service could not be accessed. Check the KOReader plugin manager."
end

local function cloudServer(plugin)
    local cs, issue = cloudGetPlugin(plugin)
    if not cs then return nil, nil, issue end
    local selection = cloud_settings:readSetting("selected_folder")
    if type(selection) ~= "table" or type(selection.type) ~= "string"
        or type(selection.url) ~= "string" then
        return cs, nil, "Choose a cloud folder first on this device."
    end
    -- Read the credentials only from the existing KOReader Cloud storage
    -- configuration. Never duplicate or export passwords in our patch files.
    if type(cs.loadSettings) == "function" then cs:loadSettings() end
    for _, server in ipairs(cs.servers or {}) do
        if server.type == selection.type
            and tostring(server.address or "") == tostring(selection.address or "")
            and tostring(server.username or "") == tostring(selection.username or "") then
            local configured = {}
            for k, v in pairs(server) do configured[k] = v end
            configured.url = selection.url
            return cs, configured
        end
    end
    return cs, nil, "Cloud account is no longer configured. Choose its folder again."
end

local function cloudMakeSnapshot(destination)
    if not replayJournal() then
        return nil, "Pending local review entries could not be persisted."
    end
    local events, err = syncCollect(nil, true)
    if not events then return nil, err end
    table.sort(events, function(a, b) return a.event_key < b.event_key end)
    local data, serialize_err = syncSerialize(events)
    if not data then return nil, serialize_err end
    local written, write_err = syncWriteFile(destination, data)
    if not written then return nil, write_err end
    return #events
end

local function cloudMergeDownloaded(incoming)
    -- Cloud storage uses HTTP 404 to mean the first device has no cloud file.
    -- Its native service will simply upload our snapshot in that case.
    local f = io.open(incoming, "rb")
    if not f then return 0, 0 end
    f:close()
    local events, err = syncReadFile(incoming)
    if not events then return nil, nil, "Cloud data rejected: " .. tostring(err) end
    local preview, preview_err = syncPreview(events)
    if not preview then return nil, nil, "Cloud merge rejected: " .. tostring(preview_err) end
    if preview.new == 0 and preview.updated == 0 then return 0, 0 end

    local folder, folder_err = syncEnsureFolder()
    if not folder then return nil, nil, folder_err end
    -- Do not touch even the separate import store unless a verified on-disk
    -- backup has been created. An import never touches the local v2.7 database.
    local ready, store_err = withSyncDB(function(_) return true end)
    if not ready then return nil, nil, store_err end
    local backup, backup_err = syncBackupStore()
    if not backup then return nil, nil, backup_err end
    local applied, apply_err = syncApply(events)
    if not applied then return nil, nil, apply_err end
    rebuildAll()
    return preview.new, preview.updated
end

-- KOReader's native Cloud:sync passes *only the downloaded filename* to
-- its merge callback, not the HTTP status. WebDAV and Dropbox both create
-- the destination file BEFORE performing a GET; on HTTP 404 the destination
-- therefore often contains a 404 HTML/JSON body. Checking if the file exists
-- mistakenly treats that error body as valid review data.
--
-- Use KOReader's EXISTING cloud provider and credentials with a tiny guarded
-- download/merge/upload transaction. We never replace or patch the native
-- Cloud storage plugin, and we distinguish HTTP 404 from HTTP 200 before
-- even parsing a remote file. A malformed HTTP 200 is rejected without upload.
-- Retain KOReader's ETag collision handling with a bounded retry loop.
local function cloudSyncNow(plugin, refresh_dashboard, silent, completion)
    -- One-shot callback: the coordinator only advances when upload has
    -- actually finished, never merely when the provider was started.
    local completion_called = false
    local function complete(ok, detail)
        if completion_called then return end
        completion_called = true
        if completion then
            local success, reason = pcall(completion, ok, detail)
            if not success then warn("Cloud sync completion callback:", reason) end
        end
    end
    local cs, server, server_err = cloudServer(plugin)
    if not server then
        if not silent then
            showAuditWidget(InfoMessage:new{text=server_err or "Cloud storage is unavailable."})
        end
        complete(false, server_err or "Cloud storage is unavailable")
        return false
    end
    local provider = cs.providers and cs.providers[server.type]
    if not provider or type(provider.run) ~= "function"
        or type(provider.downloadFile) ~= "function"
        or type(provider.uploadFile) ~= "function" then
        if not silent then showAuditWidget(InfoMessage:new{
            text="This cloud account does not support review-history synchronization."
        }) end
        complete(false, "Provider does not support Learning Analysis cloud sync")
        return false
    end
    local started_at = os.time()
    if cloud_sync_started and started_at - cloud_sync_started < 120 then
        if not silent then showAuditWidget(InfoMessage:new{
            text="Cloud sync is already in progress."
        }) end
        complete(false, "Learning Analysis cloud sync already in progress")
        return false
    end
    local count, err = cloudMakeSnapshot(CLOUD_FILE)
    if not count then
        if not silent then showAuditWidget(InfoMessage:new{
            text="Cloud sync cancelled: " .. tostring(err)
        }) end
        complete(false, "Could not prepare Learning Analysis: " .. tostring(err))
        return false
    end
    cloud_sync_started = started_at
    local incoming_path = CLOUD_FILE .. ".temp"
    local basename = CLOUD_FILE:match("([^/]+)$")

    local function reportFailure(msg)
        cloud_sync_started = nil
        os.remove(incoming_path)
        warn("Learning Audit cloud sync:", msg)
        complete(false, tostring(msg))
        if not silent then showAuditWidget(InfoMessage:new{
            text="Cloud sync stopped safely: " .. tostring(msg),
        }) end
    end

    local function perform()
        -- The official Cloud:sync does exactly this setup. Providers retain
        -- the KOReader account data, including any existing authentication.
        provider.base = util.tableDeepCopy(server)
        local imported, changed = 0, 0
        for attempt = 1, 4 do
            os.remove(incoming_path)
            local code, etag = provider.downloadFile(
                server.url:gsub("/+$", "") .. "/" .. basename, incoming_path)
            local missing = code == 404
                or (server.type == "dropbox" and code == 409)
                or (server.type == "ftp" and code == 550)
            if code ~= 200 and not missing then
                return false, "Download failed (HTTP " .. tostring(code)
                    .. "). Check the cloud account and folder."
            end
            if code == 200 then
                -- Both sides contain the exact same verified history: avoid
                -- re-importing SQL rows and uploading the same file.
                local same = require("lib.sync.flipside_sync_utils").sameFile(
                    incoming_path, CLOUD_FILE)
                if same then
                    os.remove(incoming_path)
                    return true, imported, changed
                end
                local incoming_file = io.open(incoming_path, "rb")
                if not incoming_file then
                    return false, "Cloud returned HTTP 200 without a downloaded file."
                end
                local size = incoming_file:seek("end")
                incoming_file:close()
                if not size or size == 0 then
                    return false, "Cloud returned an empty review-history file."
                end
                -- A 200 response MUST be a complete, checksummed .laex1.
                -- Never turn an invalid remote file into an empty snapshot.
                local added, updated, merge_err = cloudMergeDownloaded(incoming_path)
                if added == nil then
                    return false, tostring(merge_err)
                end
                imported = imported + added
                changed = changed + updated
            end
            os.remove(incoming_path)
            -- Rebuild from BOTH stores only after a verified merge, including
            -- on retry after ETag 412. Never upload a partially built file.
            local fresh, snapshot_err = cloudMakeSnapshot(CLOUD_FILE)
            if not fresh then return false, tostring(snapshot_err) end
            local upload_code = provider.uploadFile(
                server.url, CLOUD_FILE, etag, true)
            if type(upload_code) == "number"
                and upload_code >= 200 and upload_code < 300 then
                return true, imported, changed
            end
            if upload_code ~= 412 then
                return false, "Upload failed (HTTP " .. tostring(upload_code) .. ")."
            end
            -- HTTP 412: another device uploaded meanwhile; download again
            -- and merge its latest events before retrying.
        end
        return false, "The cloud file changed repeatedly. Please retry synchronization."
    end

    local function executeTransfer()
        -- Keep I/O outside the current input handler, as KOReader itself does.
        UIManager:nextTick(function()
            local ok, success, added, updated = pcall(perform)
            if not ok then
                reportFailure(success)
                return
            end
            if not success then
                reportFailure(added)
                return
            end
            cloud_sync_started = nil
            os.remove(incoming_path)
            complete(true, string.format("%d new, %d updated", added, updated))
            if (added > 0 or updated > 0) and refresh_dashboard then
                local refreshed, refresh_err = pcall(refresh_dashboard)
                if not refreshed then warn("Cloud sync dashboard refresh:", refresh_err) end
            end
            if not silent then showAuditWidget(InfoMessage:new{
                text=string.format(
                    "Learning Audit synchronized.\nNew reviews: %d\nUpdated review flags: %d",
                    added, updated),
                timeout=4,
            }) end
        end)
    end
    local ok, call_err = pcall(function()
        -- Provider.run handles the KOReader network manager (including
        -- Wi-Fi availability) and Dropbox token renewal when relevant.
        provider.base = util.tableDeepCopy(server)
        provider.run(executeTransfer)
    end)
    if not ok then
        reportFailure(call_err)
        return false
    end
    -- Started or queued; the actual result is reported by executeTransfer.
    return true
end
local function showCloudSync(plugin, refresh_dashboard)
    local dialog
    local function close()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function chooseFolder()
        local cs, err = cloudGetPlugin(plugin)
        if not cs then
            showAuditWidget(InfoMessage:new{text=err}); return
        end
        close()
        cs:onShowCloudStorageList(function(chosen)
            if type(chosen) ~= "table" or type(chosen.url) ~= "string" then
                showAuditWidget(InfoMessage:new{text="No cloud folder selected."})
                return
            end
            -- Keep only a reference to a KOReader-configured cloud account.
            -- No password or token is copied to Learning Audit settings.
            cloud_settings:saveSetting("selected_folder", {
                type=chosen.type, name=chosen.name, address=chosen.address,
                username=chosen.username, url=chosen.url,
            })
            cloud_settings:flush()
            showAuditWidget(InfoMessage:new{
                text="Cloud folder saved. Choose the same folder on the other device. "
                    .. "Then use Sync now to transfer your Learning Audit history."
            })
        end)
    end
    local auto = cloud_settings:readSetting("sync_on_open", true) ~= false
    local _, selected, note = cloudServer(plugin)
    local function cloudItems()
        return {
            {text = "STATUS", select_enabled = false},
            {text = "Cloud folder", mandatory = selected and "Configured" or "Not set", action = "status"},
            {text = "Sync now", action = "sync"},
            {text = "Choose cloud folder", action = "folder"},
            {text = "Auto-sync on opening", mandatory = auto and "On" or "Off", action = "auto"},
        }
    end
    dialog = minimalMenu("Cloud sync", cloudItems(), function(_, item)
        if not item or not item.action then return true end
        safeUI("cloud sync menu", function()
            if item.action == "sync" then
                close()
                cloudSyncNow(plugin, refresh_dashboard, false)
            elseif item.action == "folder" then
                chooseFolder()
            elseif item.action == "status" then
                minimalInfo(selected and ("Selected folder:\n" .. tostring(selected.url))
                    or (note or "No cloud folder selected."))
            elseif item.action == "auto" then
                auto = not auto
                cloud_settings:saveSetting("sync_on_open", auto)
                cloud_settings:flush()
                dialog.item_table = cloudItems()
                dialog:updateItems()
            end
        end)
        return true
    end)
    showAuditWidget(dialog)
end

showDashboard = function(plugin, DB)
    local ok, cards = pcall(readAllCards, DB)
    if not ok then
        warn("Could not read vocabulary:", cards)
        showAuditWidget(InfoMessage:new{text = _("Cannot read Vocabulary Builder words.")})
        return
    end
    -- Buckets are always keyed by category, independent of presentation order.
    local buckets = {}
    for key in pairs(categories) do buckets[key] = {} end
    for _, card in ipairs(cards) do
        if buckets[card.category] then
            buckets[card.category][#buckets[card.category] + 1] = card
        end
    end
    for _, list in pairs(buckets) do
        table.sort(list, function(a, b) return a.word:lower() < b.word:lower() end)
    end

    local function dashboardItems()
        local rows = {{text = "Review accuracy", category = "review_stats"},
            {text = "Study calendar", category = "streak_calendar"}}
        for _, key in ipairs(CATEGORY_ORDER) do
            rows[#rows + 1] = {
                text = orderLabel(key),
                mandatory = tostring(#buckets[key]),
                category = key,
            }
        end
        return rows
    end
    local screen
    local function refreshDashboardCounters()
        -- The parent dashboard stays alive behind the current category.
        -- Rebuild its counters in place, so Back shows accurate totals.
        local current_ok, updated_cards = pcall(readAllCards, DB)
        if not current_ok then
            warn("Could not refresh category counts:", updated_cards)
            return
        end
        for key in pairs(buckets) do buckets[key] = {} end
        for _, updated_card in ipairs(updated_cards) do
            local bucket = buckets[updated_card.category]
            if bucket then bucket[#bucket + 1] = updated_card end
        end
        for _, bucket in pairs(buckets) do
            table.sort(bucket, function(a, b)
                return a.word:lower() < b.word:lower()
            end)
        end
        if screen and type(screen.updateItems) == "function" then
            local current_page = screen.page or 1
            screen.item_table = dashboardItems()
            screen.page = current_page
            screen:updateItems()
        end
    end
    active_dashboard_refresh = refreshDashboardCounters
    screen = minimalMenu(_("Learning analysis"), dashboardItems(),
        function(menu_widget, item)
            safeUI("dashboard category", function()
                if type(item) ~= "table" or item.select_enabled == false
                    or not item.category then return end
                if item.category == "review_stats" then
                    showAccuracyStats(nil)
                    return
                end
                if item.category == "streak_calendar" then
                    local bridge = package.loaded["flipside_learning_audit_bridge"]
                    if bridge and bridge.showStudyCalendar then bridge.showStudyCalendar() end
                    return
                end
                local bucket = buckets[item.category]
                if type(bucket) ~= "table" or #bucket == 0 then
                    showAuditWidget(InfoMessage:new{
                        text = _("No words in this category."), timeout = 3,
                    })
                    return
                end
                showCategory(plugin, DB, item.category, bucket, screen, refreshDashboardCounters)
            end)
            return true
        end)
    active_dashboard = screen
    showAuditWidget(screen)
    -- Cloud transfers are now triggered explicitly in Appearance > Sync settings
    -- or from the single Sync all action. Opening statistics does not start I/O.

end

-- Hooking is intentionally limited to real Vocabulary Builder DB operations.
-- No direct interception of the Flashcards UI or their gesture handlers.
local pending = setmetatable({}, {__mode = "k"})
-- Flashcards explicitly mark the current answer phase for the duration of a
-- synchronous committed review. Native list reviews remain unidentified.
local activeAnswerModes = {}
local function markAnswerMode(word, mode)
    if trimWord(word) then
        activeAnswerModes[word] = normalizeReviewMode(mode)
    end
end
local function clearAnswerMode(word)
    if trimWord(word) then activeAnswerModes[word] = nil end
end
-- A single Undo must affect both the Learning Audit history and the optional
-- Activity Stats recorder. In particular, Flashcards v2.4.2 restored the stock
-- SQLite row directly, bypassing VocabItemWidget:undo and this patch's hooks.
-- Explicitly expose a small bridge so Flashcards can report that restoration.
local suppressStatsAuditUndo = false
local statsUndoOriginal
local statsUndoWrapper
local function wrapStatsUndo()
    local bridge = package.loaded["flipside_stats_bridge"]
    if type(bridge) ~= "table" or type(bridge.undoReview) ~= "function" then return end
    -- Re-wrap safely if Stats replaced its function after Learning Audit loaded.
    if bridge.undoReview == statsUndoWrapper then return end
    local original = bridge.undoReview
    statsUndoOriginal = original
    statsUndoWrapper = function(word, stamp, ...)
        local results = {original(word, stamp, ...)}
        -- External callers of Stats.undoReview still correct Learning Audit.
        -- Our own bridge sets the guard to avoid undoing two matching events.
        if not suppressStatsAuditUndo and results[1] ~= false and results[1] ~= nil then
            local reverted = undoAttempt(word, stamp)
            if not reverted then
                warn("Stats Undo did not find a matching Learning Audit event:", word, stamp)
            end
        end
        return unpack(results)
    end
    bridge.undoReview = statsUndoWrapper
    bridge._learning_audit_undo_wrapped = true
end
wrapStatsUndo()

local function notifyBothUndoHistories(word, stamped)
    -- Undo affects only a committed attempt. We do not accept an absent stamp
    -- because guessing would accidentally remove an older review.
    if not trimWord(word) or not tonumber(stamped) then
        return false, "missing word or committed timestamp"
    end
    local corrected = undoAttempt(word, stamped)
    -- The user may still have an older Vocabulary Builder Activity Stats patch
    -- installed. That patch can overwrite vocabulary_builder_stats (v7 -> v6)
    -- after FlipSide loads. Never trust that shared bridge for FlipSide Undo:
    -- the dedicated v7 snapshot keeps the same database and idempotent Undo
    -- marker even if other patches replace shared functions later.
    local stats = package.loaded["flipside_activity_stats_v7"]
    if type(stats) ~= "table" or type(stats.undoReview) ~= "function" then
        return false, "FlipSide Activity Stats v7 handler is unavailable"
    end
    local called, result, detail = pcall(stats.undoReview, word, stamped)
    local stats_ok = called and result == true
    if stats_ok and type(stats.flush) == "function" then
        local flushed, saved = pcall(stats.flush)
        stats_ok = flushed and saved == true
        if not stats_ok then
            detail = flushed and "v7 Activity Stats event queue is not empty"
                or tostring(saved)
        end
    end
    if not stats_ok then
        warn("FlipSide Activity Stats v7 Undo failed:", word, stamped,
            called and tostring(detail or result) or tostring(result))
    end
    if corrected == nil or not stats_ok then
        return false, corrected == nil and "Learning Analysis SQLite Undo unavailable"
            or "FlipSide Activity Stats v7 Undo could not be verified"
    end
    -- A false return means the attempt was never registered in Learning Audit
    -- (e.g. it predates the patch); it can still exist in Stats and is handled.
    return true
end

local auditBridge = package.loaded["flipside_learning_audit_bridge"]
if type(auditBridge) ~= "table" then auditBridge = {} end
auditBridge.undoReview = notifyBothUndoHistories
-- Stable private bridge: outside patches must not replace FlipSide's
-- verified Undo/accuracy handler by reusing the generic module name.
package.loaded["flipside_learning_audit_undo_v2"] = {
    undoReview = notifyBothUndoHistories,
}
auditBridge.beginReviewMode = markAnswerMode
auditBridge.endReviewMode = clearAnswerMode
auditBridge.confirmCommittedReview = confirmCommittedReview
-- Shared, read-only entry point. Both the Learning analysis menu and the
-- Flashcards shortcut display the SAME cached review events and filters.
-- Safe to call from native menus, from a flashcard, or from a Dispatcher gesture.
auditBridge.showReviewAccuracy = function()
    if auditBridge.recordStreakScheduleSnapshot then
        auditBridge.recordStreakScheduleSnapshot()
    end
    -- Keep errors inside the audit plugin, and propagate failure to callers.
    -- The pop-up and all filters use exactly the same verified cached data as
    -- Learning analysis > Review accuracy.
    return safeUI("Review accuracy shortcut", function()
        showAccuracyStats(nil)
    end)
end
-- Only the FlipSide footer-chart shortcut asks for this scoped label.
-- The underlying sentence filter, totals, review history and menu layout are
-- identical to Review accuracy; no changes to Learning analysis are needed.
auditBridge.showFlashcardsReviewAccuracy = function()
    if auditBridge.recordStreakScheduleSnapshot then
        auditBridge.recordStreakScheduleSnapshot()
    end
    return safeUI("Flashcards footer review accuracy", function()
        showAccuracyStats(nil, true)
    end)
end
-- Open the exact same native review schedule already displayed by the
-- Learning Audit statistics menu. This is read-only: neither the review
-- database nor the scheduling algorithm is modified by the shortcut.
auditBridge.showReviewSchedule = function()
    return safeUI("Review schedule shortcut", function()
        showExactSchedule(readTodaySchedule())
    end)
end
-- Public read-only bridge for CRAM's seven-day recurring-error selection.
-- Use the SAME merged/visible dated events as Learning Analysis (local +
-- imported/synced, with Undo/reset/archive flags), not a second SQL reader
-- that silently ignores imported history. No SRS update occurs here.
auditBridge.getRecentCramErrors = function(days, minimum_errors, limit)
    days = math.max(1, math.min(30, math.floor(tonumber(days) or 7)))
    minimum_errors = math.max(1, math.min(20, math.floor(tonumber(minimum_errors) or 2)))
    limit = math.max(1, math.min(200, math.floor(tonumber(limit) or 40)))
    local cutoff = os.time() - days * 86400
    local events, err = syncCollect(nil, true)
    local partial = false
    if not events then
        -- Imported events may be temporarily unreadable (e.g. storage
        -- permission failure). Still use safe local history, but tell the UI
        -- that the historical count is only partial, never silently complete.
        events, err = syncCollect(nil, false)
        partial = events ~= nil
    end
    if not events then return nil, nil, tostring(err or "Learning Analysis unavailable") end
    local counts, last_seen = {}, {}
    local reviews, errors = 0, 0
    for _, event in ipairs(events) do
        local when = tonumber(event.review_time)
        local word = event.word
        if type(word) == "string" and word ~= ""
                and when and when >= cutoff and when <= os.time()
                and syncIsVisible(event) and not archived[word]
                and not legacy_hidden[word] then
            reviews = reviews + 1
            if tonumber(event.got) == 0 then
                errors = errors + 1
                counts[word] = (counts[word] or 0) + 1
                last_seen[word] = math.max(last_seen[word] or 0, when)
            end
        end
    end
    local ranked = {}
    for word, count in pairs(counts) do
        if count >= minimum_errors then
            ranked[#ranked + 1] = {word = word, count = count,
                last = last_seen[word] or 0}
        end
    end
    table.sort(ranked, function(a,b)
        if a.count ~= b.count then return a.count > b.count end
        if a.last ~= b.last then return a.last > b.last end
        return a.word < b.word
    end)
    local result = {}
    for i = 1, math.min(limit, #ranked) do result[i] = ranked[i].word end
    return result, {
        dated_reviews = reviews,
        error_attempts = errors,
        recurring_total = #ranked,
        selected = #result,
        partial = partial,
        days = days,
        minimum_errors = minimum_errors,
        -- Legacy undated totals are intentionally NOT assumed to be recent.
    }
end

package.loaded["flipside_learning_audit_bridge"] = auditBridge

-- A read-only SRS study calendar over the Activity Stats patch's existing days.
-- No data migration is needed or performed. We record only lightweight daily
-- due-schedule observations in separate LuaSettings to classify future missed
-- and genuine no-review days. Unknown historical days remain unknown.
-- The statement separator is crucial: otherwise Lua treats the preceding
-- auditBridge table as a callable value when it sees this IIFE.
;(function()
    local activity_file = DIR .. "/vocabulary_builder_activity.sqlite3"
    local native_file = DIR .. "/vocabulary_builder.sqlite3"
    local checkpoints = LuaSettings:open(DIR .. "/vocabulary_builder_streak_observations.lua")
    local calendar = { view = "Month", date = os.time(), dialog = nil }
    local function dateKey(ts) return os.date("%Y-%m-%d", ts) end
    local function dayAt(y, m, d)
        return os.time{year=y, month=m, day=d, hour=12, min=0, sec=0}
    end
    local function moveDays(ts, delta)
        local t = os.date("*t", ts)
        return dayAt(t.year, t.month, t.day + delta)
    end
    local function monthLength(y, m)
        return tonumber(os.date("%d", dayAt(y, m+1, 0))) or 30
    end
    local function mondayOrSundayWeek(ts)
        -- Weekly UI is Monday-first; the monthly grid remains Sunday-first.
        local dt = os.date("*t", ts)
        return dayAt(dt.year, dt.month, dt.day - ((dt.wday + 5) % 7))
    end
    local function sqlRead(path, query)
        if lfs.attributes(path, "mode") ~= "file" then return nil end
        local db, result
        local ok, err = pcall(function()
            db = SQ3.open(path, "ro")
            db:exec("PRAGMA busy_timeout=500;")
            result = sqlRows(db, query)
        end)
        if db then pcall(db.close, db) end
        if not ok then warn("Streak calendar read failed:", err); return nil end
        return result
    end
    -- Streak evidence model v2.14.21:
    -- Studied   = confirmed rated review/day in Activity Stats (Undo-aware).
    -- Missed    = an observed outstanding review on a finished day, or an
    --             overdue review independently verified after an earlier due forecast.
    -- Rest      = no pending reviews near the day's close OR a still-valid
    --             forecast of a gap before the next due date.
    -- Unknown   = insufficient evidence; never a fabricated missed day.
    -- Forecasts are invalidated by review, addition, cloud sync, or a
    -- conflicting later observation. Activity data and SRS due times remain
    -- in the same original stores; no rewriting of review history.
    local function saveObservationRecords(records)
        checkpoints:saveSetting("observations", records)
        checkpoints:flush()
    end
    local function snapshotNow()
        if lfs.attributes(native_file, "mode") ~= "file" then return end
        local now = os.time()
        local t = os.date("*t", now)
        local midnight = os.time{year=t.year, month=t.month, day=t.day+1,
            hour=0, min=0, sec=0}
        local rows = sqlRead(native_file,
            "SELECT COUNT(*) AS n, MIN(due_time) AS oldest FROM vocabulary WHERE "
            .. "due_time IS NOT NULL AND due_time < " .. midnight .. ";")
        local count = rows and rows.n and tonumber(rows.n[1])
        if not count then return end
        local oldest = rows.oldest and tonumber(rows.oldest[1])
        local upcoming = sqlRead(native_file,
            "SELECT MIN(due_time) AS first_due FROM vocabulary WHERE due_time >= "
            .. midnight .. ";")
        local first_due = upcoming and upcoming.first_due
            and tonumber(upcoming.first_due[1])
        local records = checkpoints:readSetting("observations", {})
        if type(records) ~= "table" then records = {} end
        local key = dateKey(now)
        local prev = type(records[key]) == "table" and records[key] or {}
        -- "due" is the MAX seen on this date, not the current total. This
        -- remembers a morning obligation even if later cleared by an answer.
        local max_due = math.max(tonumber(prev.due) or 0, count)
        local oldest_due = tonumber(prev.oldest_due)
        if oldest and (not oldest_due or oldest < oldest_due) then
            oldest_due = oldest
        end
        records[key] = {
            due = max_due,
            -- This is the count *after* the latest review/sync. If it is
            -- zero, the day may legitimately forecast a gap even when it had
            -- due cards earlier (due>0 is still retained for Missed checks).
            remaining_due = count,
            oldest_due = oldest_due,
            -- A zero observed at 23:xx establishes a rest day only if NO
            -- outstanding review was previously observed on that date.
            late_zero = (prev.late_zero == true or (count == 0 and t.hour == 23))
                and max_due == 0,
            first_future_due = count == 0 and first_due or nil,
            seen_at = now,
        }
        saveObservationRecords(records)
    end
    local function validKey(key)
        if type(key) ~= "string" or not key:match("^%d%d%d%d%-%d%d%-%d%d$") then
            return false
        end
        local y,m,d=key:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
        y,m,d=tonumber(y),tonumber(m),tonumber(d)
        return y and y>=2000 and y<=2200 and m>=1 and m<=12
            and d>=1 and d<=monthLength(y,m)
    end
    local function prepareForecasts(history)
        if history._prepared then return end
        history._prepared=true
        history.forecast_rest={}
        history.forecast_missed={}
        local today=dateKey(os.time())
        local snapshots={}
        local blockers={}
        for key in pairs(history.days) do blockers[key]=true end
        for key in pairs(history.additions or {}) do blockers[key]=true end
        for key in pairs(history.sync_days or {}) do blockers[key]=true end
        for key,item in pairs(history.checkpoints) do
            if validKey(key) and type(item)=="table" then
                snapshots[#snapshots+1]={key=key, row=item}
                -- Every newer observation supersedes older projections,
                -- even when it has zero due cards (next due may have moved).
                blockers[key]=true
            end
        end
        table.sort(snapshots,function(a,b)return a.key<b.key end)
        -- One dated forecast can cover days while the Kindle is off, but
        -- stops immediately on the first local sign of a changed schedule.
        -- An unrecorded remote change cannot be known until that device syncs.
        for _,item in ipairs(snapshots) do
            local row=item.row
            local remaining=tonumber(row.remaining_due)
            -- Old checkpoints have no remaining_due field: honor those only
            -- if their historic peak due count was zero (safe fallback).
            local schedule_cleared = remaining==0
                or (remaining==nil and (tonumber(row.due) or 0)==0)
            if schedule_cleared then
                local due_ts=tonumber(row.first_future_due)
                local sy,sm,sd=item.key:match("^(%d+)%-(%d+)%-(%d+)$")
                local from=dayAt(tonumber(sy),tonumber(sm),tonumber(sd))
                local future_key=due_ts and dateKey(due_ts) or nil
                if future_key==nil or future_key>item.key then
                    local cursor=moveDays(from,1)
                    -- Cap the CPU cost of extremely long SRS schedules.
                    for _=1,3660 do
                        local k=dateKey(cursor)
                        if k>=today or (future_key and k>=future_key) then break end
                        if blockers[k] then break end
                        history.forecast_rest[k]=true
                        cursor=moveDays(cursor,1)
                    end
                    -- Only infer missed days during an OFFLINE GAP when a
                    -- later observation proves that the forecast due card
                    -- remained outstanding. Forecast alone never proves Missed.
                    if future_key and future_key<today then
                        local verifying
                        for _,candidate in ipairs(snapshots) do
                            if candidate.key>future_key and candidate.key>item.key then
                                local oldest=tonumber(candidate.row.oldest_due)
                                if oldest and dateKey(oldest)<=future_key
                                    and (tonumber(candidate.row.due) or 0)>0 then
                                    verifying=candidate.key
                                    break
                                end
                            end
                        end
                        if verifying then
                            cursor=moveDays(from,1)
                            local clean=true
                            for _=1,3660 do
                                local k=dateKey(cursor)
                                if k>=verifying or k>=today then break end
                                if blockers[k] then
                                    -- Any newer checkpoint or native change
                                    -- defeats an old offline forecast; trust
                                    -- only the gap with no contradictory data.
                                    clean=false
                                end
                                if not clean then break end
                                if k>=future_key then history.forecast_missed[k]=true end
                                cursor=moveDays(cursor,1)
                            end
                        end
                    end
                end
            end
        end
    end
    local function readHistory()
        local history={days={},count={},evidence={},checkpoints={},additions={},sync_days={}}
        local stats=package.loaded["flipside_stats_bridge"]
        -- Flush FIRST; otherwise a new review is absent from the first SQL
        -- query and can make the current streak appear to break temporarily.
        if type(stats)=="table" and type(stats.flush)=="function" then
            pcall(stats.flush)
        end
        local today=dateKey(os.time())
        local rows=sqlRead(activity_file,
            "SELECT day_key, source FROM activity_days ORDER BY day_key;")
        if rows and rows.day_key then
            for i,key in ipairs(rows.day_key) do
                if validKey(key) and key<=today then
                    history.days[key]=true
                    history.evidence[key]=rows.source and rows.source[i] or "recorded"
                end
            end
        end
        rows=sqlRead(activity_file,
            "SELECT day_key, event_type, COUNT(*) AS n FROM activity_events "
            .. "WHERE event_type IN ('review','add') GROUP BY day_key,event_type;")
        if rows and rows.day_key then
            for i,key in ipairs(rows.day_key) do
                if validKey(key) and key<=today then
                    if rows.event_type and rows.event_type[i]=="review" then
                        history.count[key]=tonumber(rows.n and rows.n[i]) or 0
                        history.days[key]=true
                    elseif rows.event_type and rows.event_type[i]=="add" then
                        history.additions[key]=true
                    end
                end
            end
        end
        -- Native word creations are extra invalidation evidence. Activity
        -- events may have been pruned, but current native words still expose
        -- their creation timestamps (which do NOT count as study).
        rows=sqlRead(native_file,
            "SELECT DISTINCT date(create_time, 'unixepoch', 'localtime') AS day_key "
            .. "FROM vocabulary WHERE create_time IS NOT NULL;")
        if rows and rows.day_key then
            for _,key in ipairs(rows.day_key) do
                if validKey(key) then history.additions[key]=true end
            end
        end
        local saved=checkpoints:readSetting("observations", {})
        history.checkpoints=type(saved)=="table" and saved or {}
        local syncs=checkpoints:readSetting("sync_days", {})
        history.sync_days=type(syncs)=="table" and syncs or {}
        -- Display verified calendar days received from other devices without
        -- writing to activity_days, activity_events or existing observations.
        local synced_ok, synced=pcall(function()
            return require("flipside_calendar_cloud").syncedDays()
        end)
        if synced_ok and type(synced)=="table" then
            for key,source in pairs(synced) do
                if validKey(key) and key<=today then
                    history.days[key]=true
                    if not history.evidence[key] or (source=="recorded"
                            and history.evidence[key]=="estimated_legacy") then
                        history.evidence[key]=source
                    end
                end
            end
        elseif not synced_ok then
            warn("Calendar cloud cache could not be read:", synced)
        end
        local best=0
        if type(stats)=="table" and type(stats.getBestStreak)=="function" then
            local ok,value=pcall(stats.getBestStreak)
            if ok then best=tonumber(value) or 0 end
        end
        if best==0 then
            local known=sqlRead(native_file,
                "SELECT value FROM vocabulary_stats_meta WHERE key='best_streak' LIMIT 1;")
            best=known and known.value and tonumber(known.value[1]) or 0
        end
        history.best=math.max(0,math.floor(best))
        prepareForecasts(history)
        return history
    end
    local function dayState(history,ts)
        local key=dateKey(ts)
        local now_key=dateKey(os.time())
        if key>now_key then return "upcoming" end
        if history.days[key] then return "studied" end
        if key==now_key then return "upcoming" end
        prepareForecasts(history)
        local record=history.checkpoints[key]
        if type(record)=="table" then
            if (tonumber(record.due) or 0)>0 then
                -- A sync on this date may have satisfied that obligation
                -- on another device without importing its activity history.
                if history.sync_days[key] then return "unknown" end
                return "missed"
            end
            if record.late_zero==true
                and not history.additions[key] and not history.sync_days[key] then
                return "rest"
            end
        end
        if history.forecast_missed[key] then return "missed" end
        if history.forecast_rest[key] then return "rest" end
        return "unknown" -- No observation is not proof of a missed review.
    end
    local function streakTotals(history)
        local now=os.time()
        local dt=os.date("*t",now)
        local today=dayAt(dt.year,dt.month,dt.day)
        local cursor=today
        if dayState(history,cursor)~="studied" then cursor=moveDays(cursor,-1) end
        local current=0
        for _=1,12000 do
            local state=dayState(history,cursor)
            if state=="studied" then current=current+1
            elseif state~="rest" then break end
            cursor=moveDays(cursor,-1)
        end
        -- Unknown days delimit the VERIFIED run, but are NEVER shown as ×.
        -- This is a conservative count, not an invented historical break.
        local first
        for key in pairs(history.days) do
            if not first or key<first then first=key end
        end
        for key in pairs(history.checkpoints) do
            if validKey(key) and (not first or key<first) then first=key end
        end
        local longest,longest_finalized,run=0,0,0
        if first then
            local y,m,d=first:match("^(%d+)%-(%d+)%-(%d+)$")
            local tick=dayAt(tonumber(y),tonumber(m),tonumber(d))
            for _=1,12000 do
                if tick>now then break end
                local state=dayState(history,tick)
                if state=="studied" then run=run+1
                elseif state~="rest" then run=0 end
                if run>longest then longest=run end
                if dateKey(tick)<dateKey(today) and run>longest_finalized then
                    longest_finalized=run
                end
                tick=moveDays(tick,1)
            end
        end
        local best=math.max(longest,current,history.best or 0)
        -- Persist only COMPLETED days. If today's sole review is Undone,
        -- its temporary streak must not become an irreversible record.
        local persistent_best=math.max(longest_finalized,history.best or 0)
        if persistent_best>(history.best or 0) then
            local stats=package.loaded["flipside_stats_bridge"]
            if type(stats)=="table" and type(stats.setBestStreak)=="function" then
                local ok,value=pcall(stats.setBestStreak,persistent_best)
                if ok then
                    history.best=math.max(persistent_best,tonumber(value) or persistent_best)
                    best=math.max(best,history.best)
                else
                    warn("Could not persist new longest streak:",value)
                end
            end
        end
        return current,best
    end
    local function monthlyPerformance(history,y,m)
        local studied,missed,unknown=0,0,0
        for d=1,monthLength(y,m) do
            local state=dayState(history,dayAt(y,m,d))
            if state=="studied" then studied=studied+1
            elseif state=="missed" then missed=missed+1
            elseif state=="unknown" then unknown=unknown+1 end
        end
        if studied+missed==0 then return "—" end
        -- A month with incomplete historical evidence is NOT known to be
        -- 100% consistent: flag the conditional rate as approximate.
        return string.format("%s%d%%",unknown>0 and "~" or "",
            math.floor(100*studied/(studied+missed)+.5))
    end
    -- Exposed to the embedded stats sync hook below. Synchronizing native
    -- vocabulary can replace its due schedule without a corresponding local
    -- review event, so it invalidates pre-sync rest forecasts from that day.
    auditBridge.captureStreakScheduleQuietly=function()
        local ok,err=pcall(snapshotNow)
        if not ok then warn("Streak schedule snapshot:",err) end
        return ok
    end
    auditBridge.noteStreakSync = function()
        local syncs=checkpoints:readSetting("sync_days", {})
        if type(syncs)~="table" then syncs={} end
        syncs[dateKey(os.time())]=true
        checkpoints:saveSetting("sync_days",syncs)
        checkpoints:flush()
    end
    -- E-ink calendar design v2: use native KOReader Button/FrameContainer
    -- widgets instead of a borderless ButtonTable. Every view shares the
    -- same native geometry, font, monochrome palette, and touch feedback.
    -- The SRS schedule/historical streak logic above is unchanged.
    local CalendarButton = require("ui/widget/button")
    local CalendarFrame = require("ui/widget/container/framecontainer")
    local CalendarCenter = require("ui/widget/container/centercontainer")
    local calendar_width = function()
        local short = math.min(Device.screen:getWidth(),Device.screen:getHeight())
        return math.max(254, math.floor(short*.92)
            - 2*(Size.border.window+Size.padding.button)
            - 2*math.max(Size.padding.default+Size.margin.default,
                         Size.padding.large+Size.margin.title)-16)
    end
    local function cFace(size)
        local style = package.loaded["flipside_audit_style"]
        return Font:getFace(style.name(), size or 17)
    end
    local function cText(text, width, size, bold, align)
        local widget = TextBoxWidget:new{
            text = text, width = width, face = cFace(size), bold = bold == true,
            alignment = align or "center", fgcolor = Blitbuffer.COLOR_BLACK,
        }
        widget.not_focusable = true
        return widget
    end
    local function cButton(text, width, callback, opts)
        opts = opts or {}
        return CalendarButton:new{
            text = text, width = width, callback = callback or function() end,
            enabled = opts.enabled ~= false,
            height = opts.height or Device.screen:scaleBySize(24),
            text_font_face = package.loaded["flipside_audit_style"].name(),
            text_font_size = opts.size or 15,
            text_font_bold = opts.bold ~= false,
            bordersize = opts.border == false and 0 or (Size.border.button or Size.border.window),
            radius = Size.radius.button,
            background = opts.background,
            padding_h = Size.padding.small,
            padding_v = Size.padding.small,
            avoid_text_truncation = true,
        }
    end
    local function cBox(widget, padding)
        return CalendarFrame:new{
            radius = Size.radius.window,
            bordersize = Size.border.window,
            background = Blitbuffer.COLOR_WHITE,
            margin = 0,
            padding = padding or Size.padding.default,
            widget,
        }
    end
    local function cGap()
        return math.max(2, Device.screen:scaleBySize(2))
    end
    local function cSpace()
        return VerticalSpan:new{width = cGap()}
    end
    local function cRow(items, gap)
        local group = HorizontalGroup:new{align="center"}
        for i, widget in ipairs(items) do
            if i > 1 then
                group[#group+1] = HorizontalSpan:new{width=gap or cGap()}
            end
            group[#group+1] = widget
        end
        return group
    end
    local function cColumns(total, count, gap)
        -- Distribute remainder without overflowing on 600px e-ink screens.
        local widths, used = {}, 0
        gap = gap or cGap()
        local content = total - gap*(count-1)
        for i=1,count do
            local next_width = math.floor(content*i/count)
            widths[i] = next_width-used
            used = next_width
        end
        return widths
    end
    local function cStat(label, n, width)
        local inside = width - 2*(Size.border.window + Size.padding.default)
        local group = VerticalGroup:new{}
        group[#group+1] = cText(n .. " days", inside, 21, true, "center")
        group[#group+1] = cText(label, inside, 13, true, "center")
        return cBox(group, Size.padding.default)
    end
    local function cCell(state, number, width, callback, compact)
        local mark = ({studied="✓",missed="×",rest="—"})[state] or ""
        -- A fill distinguishes studied dates even when text has poor contrast.
        -- Missing (×), rest (—), and unknown/upcoming (blank) remain white.
        local label = number .. (mark ~= "" and "\n"..mark or "")
        return cButton(label, width, callback, {
            size = compact and 12 or 14,
            background = state=="studied" and Blitbuffer.COLOR_LIGHT_GRAY or nil,
            height = Device.screen:scaleBySize(compact and 29 or 31),
        })
    end
    local function cLegend(inner)
        return cText("✓ Studied     × Missed     — Rest     □ Future",
            inner, 12, false, "center")
    end
    local function cPeriodHeading(inner, period, prev, following)
        local arrow = math.max(34, Device.screen:scaleBySize(38))
        return cRow({
            cButton("‹",arrow,prev,{size=20,border=false}),
            cText(period,inner-arrow*2-2*cGap(),17,true,"center"),
            cButton("›",arrow,following,{size=20,border=false}),
        })
    end
    local render
    local function defer(action)
        UIManager:nextTick(function()
            if calendar.dialog then UIManager:close(calendar.dialog); calendar.dialog=nil end
            action()
        end)
    end
    local function btn(label, fn, enabled)
        return {text=label, callback=fn or function() end,
            enabled=enabled~=false, font_face=package.loaded["flipside_audit_style"].name(),
            font_size=17, font_bold=false}
    end
    local function showDetails(history, ts)
        -- Keep the calendar mounted below this modal. Closing and rebuilding
        -- the calendar here exposed the underlying flashcard on some devices.
        -- A native ButtonDialog with no buttons closes when tapped OUTSIDE it.
        -- Its onCloseWidget requests an e-ink refresh of just the modal area.
        if calendar.day_dialog then return end
        local key=dateKey(ts)
        local status=dayState(history,ts)
        local labels={studied="Studied ✓",missed="Missed ×",rest="Rest day —",
            upcoming="Upcoming",unknown="No reliable record"}
        if key == dateKey(os.time()) and status == "upcoming" then
            labels.upcoming = "Not finished yet"
        end
        local small=math.min(Device.screen:getWidth(), Device.screen:getHeight())
        local modal_width=math.floor(small*.76)
        local text_width=math.max(150,modal_width
            -2*(Size.border.window+Size.padding.button)
            -2*(Size.padding.default+Size.margin.default)-12)
        local lines=VerticalGroup:new{}
        lines[#lines+1]=cText(os.date("%B %d, %Y",ts),text_width,17,true,"left")
        lines[#lines+1]=cSpace()
        lines[#lines+1]=cText("Status: "..(labels[status] or "Unknown"),
            text_width,17,false,"left")
        local n=history.count[key]
        if n and n>0 then
            lines[#lines+1]=cSpace()
            lines[#lines+1]=cText(string.format("Recorded reviews: %d",n),
                text_width,17,false,"left")
        elseif status=="studied" then
            lines[#lines+1]=cSpace()
            lines[#lines+1]=cText("Older review details may be unavailable.",
                text_width,15,false,"left")
        end
        if history.evidence[key]=="estimated_legacy" then
            lines[#lines+1]=cSpace()
            lines[#lines+1]=cText("Historical study day (estimated from native data).",
                text_width,15,false,"left")
        end
        local detail
        detail=ButtonDialog:new{
            width=modal_width,
            use_info_style=true,
            -- Empty button grid: no X, Back, or Close. Native TapClose
            -- consumes outside taps so the underlying calendar stays open.
            buttons={},
            _added_widgets={lines},
            dismissable=true,
            tap_close_callback=function()
                if calendar.day_dialog==detail then
                    calendar.day_dialog=nil
                end
            end,
        }
        calendar.day_dialog=detail
        showAuditWidget(detail)
    end
    local function movePeriod(direction)
        local t=os.date("*t",calendar.date)
        if calendar.view=="Week" then
            calendar.date=moveDays(calendar.date,7*direction)
        elseif calendar.view=="Month" then
            calendar.date=dayAt(t.year,t.month+direction,math.min(t.day,28))
        else
            calendar.date=dayAt(t.year+direction,t.month,math.min(t.day,28))
        end
        calendar.return_to_year = false
    end
    local function openMonth(y, m)
        calendar.date=dayAt(y,m,1)
        calendar.view="Month"
        calendar.return_to_year=true
        render()
    end
    local function calendarHeader(content_width, history)
        local current,best=streakTotals(history)
        local gap=cGap()
        local widths=cColumns(content_width,2,gap)
        return cRow({cStat("Current streak",tostring(current),widths[1]),
                     cStat("Longest streak",tostring(best),widths[2])},gap)
    end
    local function calendarTabs(content_width)
        local gap=cGap()
        local widths=cColumns(content_width,3,gap)
        local items={}
        for i, name in ipairs({"Week","Month","Year"}) do
            local selected=calendar.view==name
            items[#items+1]=cButton(name,widths[i],function()
                defer(function()
                    calendar.view=name
                    calendar.return_to_year=false
                    render()
                end)
            end,{size=16,height=Device.screen:scaleBySize(20),
                background=selected and Blitbuffer.COLOR_LIGHT_GRAY or nil})
        end
        return cRow(items,gap)
    end
    local function calendarWeekMonth(content_width, history)
        local inside = content_width-2*(Size.border.window+Size.padding.default)
        local t=os.date("*t",calendar.date)
        local weekStart=mondayOrSundayWeek(calendar.date)
        local first = calendar.view=="Week" and weekStart or dayAt(t.year,t.month,1)
        local period = calendar.view=="Week"
            and (os.date("%b %d",first) .. " – " .. os.date("%b %d, %Y",moveDays(first,6)))
            or os.date("%B %Y",calendar.date)
        local group=VerticalGroup:new{}
        group[#group+1]=cPeriodHeading(inside, period,
            function() defer(function() movePeriod(-1);render() end) end,
            function() defer(function() movePeriod(1);render() end) end)
        group[#group+1]=cSpace()
        local days={}
        if calendar.view=="Week" then
            for i=0,6 do days[#days+1]=moveDays(weekStart,i) end
        else
            local weekday=tonumber(os.date("%w",first))
            for _=1,weekday do days[#days+1]=false end
            for d=1,monthLength(t.year,t.month) do
                days[#days+1]=dayAt(t.year,t.month,d)
            end
            while #days%7~=0 do days[#days+1]=false end
        end
        local gap=cGap()
        local widths=cColumns(inside,7,gap)
        local headers={}
        local day_names=calendar.view=="Week"
            and {"Mon","Tue","Wed","Thu","Fri","Sat","Sun"}
            or {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"}
        for i, label in ipairs(day_names) do
            headers[i]=cText(label,widths[i],11,true,"center")
        end
        group[#group+1]=cRow(headers,gap)
        group[#group+1]=cSpace()
        for index=1,#days,7 do
            local row={}
            for col=1,7 do
                local ts=days[index+col-1]
                if ts then
                    local status=dayState(history,ts)
                    row[col]=cCell(status,tostring(tonumber(os.date("%d",ts))),
                        widths[col],function()
                            -- Open ON TOP of the calendar; do not call defer(),
                            -- whose old behavior closes calendar.dialog first.
                            UIManager:nextTick(function()showDetails(history,ts)end)
                        end,calendar.view=="Month")
                else
                    row[col]=HorizontalSpan:new{width=widths[col]}
                end
            end
            group[#group+1]=cRow(row,gap)
            if index+7<=#days then group[#group+1]=cSpace() end
        end
        return cBox(group,Size.padding.default)
    end
    local function calendarYear(content_width,history)
        local inside = content_width-2*(Size.border.window+Size.padding.default)
        local t=os.date("*t",calendar.date)
        local group=VerticalGroup:new{}
        group[#group+1]=cPeriodHeading(inside,tostring(t.year),
            function()defer(function()movePeriod(-1);render()end)end,
            function()defer(function()movePeriod(1);render()end)end)
        group[#group+1]=cSpace()
        local gap=cGap()
        local widths=cColumns(inside,4,gap)
        local names={"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
        for rowIndex=0,2 do
            local row={}
            for col=1,4 do
                local month=rowIndex*4+col
                local percentage=monthlyPerformance(history,t.year,month)
                local value=tonumber(percentage:match("^(%d+)%%$"))
                local blocks={}
                for b=1,5 do
                    blocks[#blocks+1]=value and (b<=math.ceil(value/20) and "■" or "□") or "□"
                end
                local text=names[month].."\n"..table.concat(blocks).."\n"..percentage
                row[col]=cButton(text,widths[col],function()
                    defer(function()openMonth(t.year,month)end)
                end,{size=11,height=Device.screen:scaleBySize(42),
                    background=(t.year==os.date("*t").year and month==os.date("*t").month)
                        and Blitbuffer.COLOR_LIGHT_GRAY or nil})
            end
            group[#group+1]=cRow(row,gap)
            if rowIndex<2 then group[#group+1]=cSpace() end
        end
        group[#group+1]=cSpace()
        group[#group+1]=cText("Tap a month to open it",inside,12,false,"center")
        return cBox(group,Size.padding.default)
    end
    local function calendarWeekSummary(content_width,history)
        local start=mondayOrSundayWeek(calendar.date)
        local studied,missed=0,0
        for i=0,6 do
            local status=dayState(history,moveDays(start,i))
            if status=="studied" then studied=studied+1
            elseif status=="missed" then missed=missed+1 end
        end
        local denom=studied+missed
        local percent=denom>0 and tostring(math.floor(100*studied/denom+0.5)).."%" or "—"
        local inside=content_width-2*(Size.border.window+Size.padding.default)
        local text=string.format("%d / %d studied days     %s consistency",studied,denom,percent)
        return cBox(cText(text,inside,15,true,"center"),Size.padding.default)
    end
    render=function()
        local history=calendar.history or readHistory()
        local w=calendar_width()
        local widgets={}
        local function calendarHelp()
            showAuditWidget(InfoMessage:new{
                text = "Study Calendar shows the days you studied.\n\n"
                    .. "✓ Studied: you reviewed cards.\n"
                    .. "× Missed: a review was due but not done.\n"
                    .. "— Rest: no review was due.\n"
                    .. "Blank: not enough data, or a future day.\n\n"
                    .. "Choose Week, Month or Year. Tap a day for details. "
                    .. "Your review dates will not change.",
                show_icon = false,
                width_factor = .82,
            })
        end
        widgets[#widgets+1] = require("flipside_popup_header").new(
            "STUDY CALENDAR", w, calendarHelp, 17)
        widgets[#widgets+1]=calendarHeader(w,history)
        widgets[#widgets+1]=cSpace()
        widgets[#widgets+1]=calendarTabs(w)
        widgets[#widgets+1]=cSpace()
        if calendar.view=="Year" then
            widgets[#widgets+1]=calendarYear(w,history)
        else
            widgets[#widgets+1]=calendarWeekMonth(w,history)
            if calendar.view=="Week" then
                widgets[#widgets+1]=cSpace()
                widgets[#widgets+1]=calendarWeekSummary(w,history)
            end
        end
        widgets[#widgets+1]=cSpace()
        widgets[#widgets+1]=cLegend(w)
        -- No Back row in Week, Month or Year. Native tap-outside dismissal
        -- remains active. Dates still open their separate overlay as before.
        calendar.dialog=minimalDialog(nil,widgets,{},true)
    end
    auditBridge.showStudyCalendar=function()
        return safeUI("SRS calendar",function()
            snapshotNow()
            calendar.history=readHistory() -- one DB scan per opening, not per swipe
            calendar.date=os.time()
            calendar.view="Month"
            calendar.return_to_year=false
            if calendar.dialog then UIManager:close(calendar.dialog);calendar.dialog=nil end
            render()
        end)
    end
    auditBridge.recordStreakScheduleSnapshot=function()
        return safeUI("record SRS schedule",snapshotNow)
    end
end)()

-- Register the Dispatcher action during patch loading, not only after
-- Vocabulary Builder's instance is attached. This mirrors the working
-- Flashcards gesture registration and makes the action visible to gestures.
local function registerAccuracyAction()
    local ok, err = pcall(function()
        require("dispatcher"):registerAction("learning_audit_streak_calendar", {
            category = "none", event = "ShowLearningAuditStreakCalendar",
            title = "Study Calendar", general = true,
            -- General actions work in BOTH ReaderUI and FileManager.
            -- reader=true would disable the action in the file browser.
        })
    end)
    if not ok then warn("Could not register Study calendar gesture:", err) end
    ok, err = pcall(function()
        require("dispatcher"):registerAction("learning_audit_review_accuracy", {
            category = "none", event = "ShowLearningAuditReviewAccuracy",
            title = "Review Stats", general = true,
            -- General actions work in BOTH ReaderUI and FileManager.
            -- reader=true would disable the action in the file browser.
        })
    end)
    if not ok then warn("Could not register Review accuracy action:", err) end
    -- User-selectable gesture action in BOTH contexts. Gesture Manager uses
    -- separate configurations for an open book and the file browser. It is
    -- important to register this as general only, and to
    -- reuse the exact same statistics popup as the Flashcards stats icon.
    -- Keep the older action above so existing user gesture bindings survive.
    ok, err = pcall(function()
        require("dispatcher"):registerAction("learning_audit_stats_popup", {
            category = "none", event = "ShowLearningAuditStatsPopup",
            title = "Stats Popup",
            general = true, -- General actions work in BOTH ReaderUI and FileManager.
            -- reader=true would disable the action in the file browser.
        })
    end)
    if not ok then warn("Could not register statistics popup gesture:", err) end
end
registerAccuracyAction()

local function registerAccuracyGesture(plugin)
    if type(plugin) ~= "table" then return end
    if plugin.onShowLearningAuditReviewAccuracy == nil then
        plugin.onShowLearningAuditReviewAccuracy = function(self)
            -- Defer the dialog until after the gesture's current UI event;
            -- never add/remove widgets while it is being dispatched.
            UIManager:nextTick(function()
                auditBridge.showReviewAccuracy()
            end)
            return true
        end
    end
    if plugin.onShowLearningAuditStreakCalendar == nil then
        plugin.onShowLearningAuditStreakCalendar = function(self)
            UIManager:nextTick(function()
                auditBridge.showStudyCalendar()
            end)
            return true
        end
    end
    -- Separate event name to make the popup easy to find under Gestures,
    -- without changing the existing Review accuracy action or the popup UI.
    -- Events are handled by Vocabulary Builder's active plugin instance in
    -- both ReaderUI and FileManager, just like the existing gesture handlers.
    -- Coalesce rapid consecutive invocations until the next UI cycle.
    if plugin.onShowLearningAuditStatsPopup == nil then
        plugin.onShowLearningAuditStatsPopup = function(self)
            if self._learning_audit_stats_popup_pending then return true end
            self._learning_audit_stats_popup_pending = true
            UIManager:nextTick(function()
                self._learning_audit_stats_popup_pending = false
                auditBridge.showReviewAccuracy()
            end)
            return true
        end
    end
    -- Also cover builds loading Dispatcher after this userpatch ran.
    registerAccuracyAction()
end

local function attach(plugin)
    registerAccuracyGesture(plugin)
    UIManager:scheduleIn(5, function()
        if auditBridge.recordStreakScheduleSnapshot then
            auditBridge.recordStreakScheduleSnapshot()
        end
    end)
    -- The FlipSide engine returns its own live DB and UI classes directly.
    -- Keep the interface explicit so closure refactors cannot disable Undo
    -- or the Learning Analysis menu without a visible warning.
    local DB, Widget, Row, MenuDialog
    local getInternals = plugin and plugin.getFlipSideAuditInternals
    if type(getInternals) == "table" and type(getInternals.f) == "function" then
        getInternals = getInternals.f -- KOReader's HandlerSandbox wrapper
    end
    if type(getInternals) == "function" then
        local ok, private_db, private_widget, private_row, private_menu =
            pcall(getInternals, plugin)
        if ok then
            DB, Widget, Row, MenuDialog =
                private_db, private_widget, private_row, private_menu
        end
    end
    if type(DB) ~= "table" or type(Widget) ~= "table" then
        warn("Could not locate FlipSide audit internals")
        if type(plugin) == "table" then plugin._flipside_audit_load_failed = true end
        return
    end
    -- A KOReader API change must not silently disable audit recording.
    -- Normal review and Undo methods are unchanged; this is a read-only check.
    if type(DB.gotOrForgot) ~= "function"
            or type(DB.batchUpdateItems) ~= "function" then
        warn("FlipSide audit: required review recording API unavailable")
        if type(plugin) == "table" then plugin._flipside_audit_load_failed = true end
    end
    -- The compact statistics dialog can open the exact same Learning analysis
    -- dashboard used by the native Vocabulary Builder menu. Never create a
    -- second database, statistics engine or detached copy of the records.
    auditBridge.showLearningAnalysis = function()
        return safeUI("Learning analysis shortcut", function()
            if active_dashboard and UIManager:isWidgetShown(active_dashboard) then
                -- A previous dashboard can remain behind the flashcards popup.
                -- Update cached counts before returning to that same menu.
                refreshOpenLearningMenus()
                return
            end
            showDashboard(plugin, DB)
        end)
    end

    if not DB._learning_audit_v2_hooks then
        if type(DB.gotOrForgot) == "function" then
            local orig = DB.gotOrForgot
            DB.gotOrForgot = function(self, item, got, ...)
                local result = {orig(self, item, got, ...)}
                if type(item) == "table" and trimWord(item.word) then
                    pending[item] = {word = item.word, time = tonumber(item.review_time),
                        got = got == true,
                        review_mode = normalizeReviewMode(activeAnswerModes[item.word])}
                end
                return unpack(result)
            end
        end
        if type(DB.batchUpdateItems) == "function" then
            local orig = DB.batchUpdateItems
            DB.batchUpdateItems = function(self, items, ...)
                local candidates = {}
                for _index, item in ipairs(type(items) == "table" and items or {}) do
                    local p = pending[item]
                    if p and p.time and p.time == tonumber(item.review_time) then
                        candidates[#candidates+1] = {item = item, op = p}
                    end
                end
                local result = {orig(self, items, ...)}
                if result[1] ~= false then
                    -- Refresh due-time evidence AFTER the native SRS write.
                    -- Defer work to avoid blocking touch/review feedback.
                    if #candidates>0 then
                        -- Debounce avoids one SQLite read/settings write for
                        -- every touch on slow Kindle e-ink hardware. The
                        -- final SRS schedule is captured after the last card.
                        if not plugin._audit_streak_snapshot_debounced then
                            plugin._audit_streak_snapshot_debounced=UIManager:debounce(
                                4,false,function()
                                    if auditBridge.captureStreakScheduleQuietly then
                                        auditBridge.captureStreakScheduleQuietly()
                                    end
                                end)
                        end
                        plugin._audit_streak_snapshot_debounced()
                    end
                    for _index, c in ipairs(candidates) do
                        if c.item.review_time == nil then
                            pending[c.item] = nil
                            local ok, err = pcall(storeAttempt, c.op.word, c.op.got,
                                c.op.time, c.op.review_mode)
                            if not ok then warn("Could not record committed review:", err) end
                        end
                    end
                end
                return unpack(result)
            end
        end
        if type(DB.remove) == "function" then
            local orig = DB.remove
            DB.remove = function(self, item, ...)
                local result = {orig(self, item, ...)}
                if result[1] ~= false and item and trimWord(item.word) then
                    archiveWord(item.word)
                    scheduleLearningMenuRefresh()
                end
                return unpack(result)
            end
        end
        if type(DB.purge) == "function" then
            local orig = DB.purge
            DB.purge = function(self, ...)
                local result = {orig(self, ...)}
                if result[1] ~= false then
                    archiveAll()
                    scheduleLearningMenuRefresh()
                end
                return unpack(result)
            end
        end
        DB._learning_audit_v2_hooks = true
    end

    if type(Row) ~= "table" or type(Row.undo) ~= "function" then
        warn("FlipSide audit: native Undo hook API unavailable")
        if type(plugin) == "table" then plugin._flipside_audit_load_failed = true end
    end
    if type(Row) == "table" and not Row._learning_audit_v2_undo
            and type(Row.undo) == "function" then
        local orig = Row.undo
        Row.undo = function(self, ...)
            local item = self.item
            if not item or not item.last_due_time then return orig(self, ...) end
            local word = item.word
            local had_pending = pending[item] ~= nil
            local old_due = tonumber(item.last_due_time)
            local old_review_time = tonumber(item.last_review_time)
            local old_count = tonumber(item.last_review_count) or 0
            local old_streak = tonumber(item.last_streak_count) or 0
            local stamped = nil
            local db_ok, db_time = pcall(function()
                local conn = SQ3.open(DB.path)
                local results = sqlRows(conn, "SELECT review_time FROM vocabulary WHERE word=" .. sqlQuote(word) .. ";")
                conn:close()
                return tonumber((results.review_time or {})[1])
            end)
            if db_ok then stamped = db_time end
            local result = {orig(self, ...)}
            -- Native Undo changes memory only and may leave review_time=nil,
            -- in which case the stock batch writer would skip the row.
            local persisted, err = pcall(function()
                local conn = SQ3.open(DB.path)
                local done, problem = pcall(function()
                    execute(conn, [[UPDATE vocabulary SET review_count=?, streak_count=?,
                        review_time=?, due_time=? WHERE word=?;]],
                        old_count, old_streak, old_review_time, old_due, word)
                end)
                conn:close()
                if not done then error(problem, 0) end
            end)
            if persisted then
                pending[item] = nil
                if not had_pending then
                    local notified, reason = notifyBothUndoHistories(word, stamped)
                    if not notified then
                        warn("Could not synchronize native Undo statistics:", reason)
                    end
                end
            else warn("Could not persist native Undo:", err) end
            return unpack(result)
        end
        Row._learning_audit_v2_undo = true
    end
    wrapStatsUndo()

    if type(MenuDialog) ~= "table"
            or type(MenuDialog.setupPluginMenu) ~= "function" then
        warn("Cannot add Learning analysis to the menu")
        if type(plugin) == "table" then plugin._flipside_audit_load_failed = true end
        return
    end
    if MenuDialog._learning_audit_v2_menu then return end
    local original_setup = MenuDialog.setupPluginMenu
    MenuDialog.setupPluginMenu = function(menu, ...)
        local original_new = ButtonTable.new
        local previous_raw = rawget(ButtonTable, "new")
        local function isVocabActionButtons(rows)
            if type(rows) ~= "table" then return false end
            for _index, row in ipairs(rows) do
                if type(row) == "table" then
                    for _index, button in ipairs(row) do
                        if type(button) == "table" and
                            (button.text == _("Clean all words")
                                or button.text == _("Reset all progress")) then
                            return true
                        end
                    end
                end
            end
            return false
        end
        ButtonTable.new = function(class, args, ...)
            if args and args.show_parent == menu and isVocabActionButtons(args.buttons)
                and not args._learning_audit_added then
                args._learning_audit_added = true
                table.insert(args.buttons, {{
                    text = _("Learning analysis"),
                    callback = function()
                        local widget = menu.vocabbuilder
                        local owner = widget and widget.vocabbuilder
                        menu:onClose()
                        showDashboard(owner, DB)
                    end,
                }})
            end
            return original_new(class, args, ...)
        end
        local ok, result = pcall(original_setup, menu, ...)
        rawset(ButtonTable, "new", previous_raw)
        if not ok then error(result, 0) end
        return result
    end
    MenuDialog._learning_audit_v2_menu = true
    logger.info("[Vocabulary Learning Audit] v" .. VERSION .. " ready")
end

userpatch.registerPatchPluginFunc("flipside", attach, "learning_audit")
logger.info("[Vocabulary Learning Audit] v" .. VERSION .. " loaded")


--[[ Integrated Activity Statistics recorder (former standalone v7).
     It is intentionally scoped to its own Lua function so there is no collision
     with Learning Audit locals or Lua's per-function register/local limits.
     NO MIGRATION: retains the same activity SQLite file, review events, daily
     streak records, original cloud best-streak table, and public bridge.
     Do not install the standalone 2-vocabulary-builder-stats.lua alongside it.
]]
do
    local function initializeEmbeddedActivityRecorder()
--[[-
Vocabulary Builder Stats -- KOReader user patch (v7)

Records Vocabulary Builder activity (new words and reviews) in a separate
database -- koreader/settings/vocabulary_builder_activity.sqlite3 -- so the stock
Vocabulary Builder schema is never touched. Install in koreader/patches/ and
restart KOReader. The Bookshelf micro-module "vocabulary_stats.lua" reads it.

What changed in v7: integrate Activity Stats Undo with Learning Audit, without touching native review state.

What changed in v5 (bug fixes)
  * "Reviews today" no longer counts a word's creation moment as a review. The v4
    snapshot treated review_time == create_time (a word that was only looked up)
    as a review, so every sync/startup inflated the counter by the number of
    words added that day and could turn a day with no review into a streak day.
    A one-time cleanup removes those fake events and the streak days they made.
  * Events are idempotent. The key is now word + time + review count (instead of
    a per-session serial), so a batch that Vocabulary Builder reports twice (page
    change + close, retry after a failed flush) counts once. Live events and
    sync snapshots are matched inside a +-60 s window, so the same review is never
    counted once live and once more as "synced". Existing duplicates are removed
    once.
  * Timestamps in the future (clock ahead, data synced from another device) are
    ignored. They used to create a "tomorrow" streak day, which zeroed the
    current streak.

What changed in v4
  * Sync-aware reconciliation recovers today's identifiable review/addition
    timestamps from the stock Vocabulary Builder database after cloud sync.
  * Hooks DB.onSync and refreshes totals, daily activity, and deleted-word events.
  * Event keys allow two genuine reviews of the same word in the same second
    without collapsing them, while keeping sync backfill idempotent.

What changed in v3
  * Built for large vocabularies (20 000+ words):
      - writes are queued and flushed in ONE transaction (the old version opened
        a connection, ran three CREATE TABLEs and committed every row on its own);
      - no full scan of the vocabulary table on every Bookshelf refresh: legacy
        review days are seeded once per day with a single SQL statement;
      - indexes for every lookup, duplicate-proof inserts;
      - old review events are pruned (streak days are kept forever).
  * Deleting a word in Vocabulary Builder also deletes its activity here
    (exact hook on the stock remove method + a reconcile pass that removes the
    activity of any word that no longer exists, e.g. after "delete all").
    Your streak is NOT lost when a word is deleted: streak days live in their own
    table.
  * Exposes a tiny bridge (package.loaded["flipside_stats_bridge"]) so the
    micro-module can flush pending writes, invalidate its cache and run a full
    reconciliation/snapshot recovery from its settings menu.

New daily activity tracking starts when this patch is installed. On first
activation the patch also estimates some pre-patch review days from the latest
review_time stored for each existing word (partial by nature: older timestamps
are overwritten by later reviews).
--]]

local userpatch = require("flipside_compat")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

----------------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------------
local VERSION = 7
local MATCH_WINDOW = 60         -- seconds; a live event and a synced snapshot this close are the same event
local FUTURE_TOLERANCE = 300    -- seconds; timestamps further ahead than this are clock errors, not activity
local RETENTION_DAYS = 730      -- review/add events older than this are pruned
local FLUSH_DELAY = 0.4         -- seconds; coalesces bursts (imports, review sessions)
local FLUSH_NOW_ROWS = 400      -- flush immediately when this many events are queued
local RETRY_DELAY = 30          -- seconds before retrying a failed flush
local MAX_FLUSH_FAILURES = 5    -- drop a batch after this many failed attempts
local STARTUP_DELAY = 6         -- seconds after plugin load before maintenance runs
local RECONCILE_DELAY = 2       -- seconds after a delete/purge before reconciling

local settings_dir = DataStorage:getSettingsDir() .. "/flipside"
local activity_path = settings_dir .. "/vocabulary_builder_activity.sqlite3"
local vocabulary_path = settings_dir .. "/vocabulary_builder.sqlite3"

local bridge = package.loaded["flipside_stats_bridge"]
if type(bridge) ~= "table" then
    bridge = {}
    package.loaded["flipside_stats_bridge"] = bridge
end
bridge.version = VERSION
bridge.generation = bridge.generation or 0
local function touch() bridge.generation = bridge.generation + 1 end

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------
local function fileExists(path)
    return type(path) == "string" and path ~= "" and lfs.attributes(path, "mode") == "file"
end

-- Best streak metadata lives in the stock Vocabulary Builder database so the
-- regular Vocabulary Builder cloud sync can carry it between devices. The stock
-- app ignores this additional table; our onSync wrapper merges its one record.
local function readBestStreakFromPath(path)
    if not fileExists(path) then return 0 end
    local conn
    local ok, value = pcall(function()
        conn = SQ3.open(path, "ro")
        conn:exec("PRAGMA busy_timeout=1000;")
        local table_stmt = conn:prepare(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='vocabulary_stats_meta';")
        local table_row = table_stmt:step()
        table_stmt:close()
        if not table_row then return 0 end
        local stmt = conn:prepare(
            "SELECT value FROM vocabulary_stats_meta WHERE key='best_streak' LIMIT 1;")
        local row = stmt:step()
        stmt:close()
        return row and tonumber(row[1]) or 0
    end)
    if conn then pcall(conn.close, conn) end
    if not ok then return 0 end
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function writeBestStreakToPath(path, value)
    if not fileExists(path) then return nil, "Vocabulary Builder database not found" end
    value = math.max(0, math.floor(tonumber(value) or 0))
    local conn
    local ok, result = pcall(function()
        conn = SQ3.open(path)
        conn:exec("PRAGMA busy_timeout=2000;")
        conn:exec([[
            CREATE TABLE IF NOT EXISTS vocabulary_stats_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
        ]])
        local stmt = conn:prepare(
            "SELECT value FROM vocabulary_stats_meta WHERE key='best_streak' LIMIT 1;")
        local row = stmt:step()
        stmt:close()
        local existing = math.max(0, tonumber(row and row[1]) or 0)
        local best = math.max(existing, value)
        stmt = conn:prepare(
            "INSERT OR REPLACE INTO vocabulary_stats_meta (key, value) VALUES ('best_streak', ?);")
        stmt:bind(tostring(best))
        stmt:step()
        stmt:close()
        return best
    end)
    if conn then pcall(conn.close, conn) end
    if not ok then return nil, result end
    return result
end

local function openActivity()
    local conn = SQ3.open(activity_path)
    conn:exec("PRAGMA busy_timeout=500;")
    return conn
end

local function runStatement(conn, sql, ...)
    local stmt = conn:prepare(sql)
    if select("#", ...) > 0 then stmt:bind(...) end
    local row = stmt:step()
    stmt:close()
    return row
end

local function scalar(conn, sql, ...)
    local row = runStatement(conn, sql, ...)
    return tonumber(row and row[1]) or 0
end

local function getMeta(conn, key)
    local row = runStatement(conn, "SELECT value FROM activity_meta WHERE key = ?;", key)
    return row and row[1] or nil
end

local function setMeta(conn, key, value)
    runStatement(conn, "INSERT OR REPLACE INTO activity_meta (key, value) VALUES (?, ?);",
        key, tostring(value))
end

local function inTransaction(conn, fn)
    conn:exec("BEGIN IMMEDIATE;")
    local ok, err = pcall(fn)
    if ok then
        conn:exec("COMMIT;")
    else
        pcall(conn.exec, conn, "ROLLBACK;")
        error(err, 0)
    end
end

local function hasColumn(conn, table_name, column_name)
    -- table_name is a fixed internal identifier, never user input.
    local stmt = conn:prepare("PRAGMA table_info(" .. table_name .. ");")
    local found = false
    while true do
        local row = stmt:step()
        if not row then break end
        if row[2] == column_name then
            found = true
            break
        end
    end
    stmt:close()
    return found
end

local function ensureSchema(conn)
    conn:exec([[
        CREATE TABLE IF NOT EXISTS activity_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_time INTEGER NOT NULL,
            day_key TEXT NOT NULL,
            event_type TEXT NOT NULL CHECK (event_type IN ('review', 'add')),
            word TEXT,
            outcome TEXT,
            event_key TEXT
        );
        CREATE INDEX IF NOT EXISTS activity_time_index
            ON activity_events(event_time);
        CREATE INDEX IF NOT EXISTS activity_day_index
            ON activity_events(day_key, event_type);
        CREATE INDEX IF NOT EXISTS activity_word_index
            ON activity_events(word);
        CREATE TABLE IF NOT EXISTS activity_days (
            day_key TEXT PRIMARY KEY,
            source TEXT NOT NULL DEFAULT 'estimated_legacy'
        );
        CREATE TABLE IF NOT EXISTS activity_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        -- Each official Undo is applied at most once, even when a pending
        -- recovery operation is replayed after the app closes unexpectedly.
        CREATE TABLE IF NOT EXISTS activity_undo_events (
            word TEXT NOT NULL,
            review_time INTEGER NOT NULL,
            PRIMARY KEY (word, review_time)
        );
    ]])

    -- Upgrade activity databases created by v3 without touching the stock DB.
    if not hasColumn(conn, "activity_events", "event_key") then
        conn:exec("ALTER TABLE activity_events ADD COLUMN event_key TEXT;")
    end
    -- Give legacy rows stable unique keys before changing the old uniqueness rule.
    conn:exec([[UPDATE activity_events
        SET event_key = 'legacy:' || id
        WHERE event_key IS NULL OR event_key = '';]])
    -- v3's (event_type, word, event_time) index accidentally collapsed two reviews
    -- of the same word in the same second. Idempotency is now based on event_key.
    conn:exec("DROP INDEX IF EXISTS activity_event_unique;")
    conn:exec([[CREATE UNIQUE INDEX IF NOT EXISTS activity_event_key_unique
        ON activity_events(event_key);]])
end

-- Attach the stock vocabulary database (read-only use) as "vb".
local function attachVocabulary(conn)
    if not fileExists(vocabulary_path) then return false end
    runStatement(conn, "ATTACH DATABASE ? AS vb;", vocabulary_path)
    local has_table = scalar(conn,
        "SELECT COUNT(*) FROM vb.sqlite_master WHERE type='table' AND name='vocabulary';")
    return has_table > 0
end

-- Pass-through helper: run `post` after the original call returned, keep its results.
local function after(post, ...)
    local ok, err = pcall(post)
    if not ok then logger.warn("[vocabulary stats] post-hook failed:", err) end
    return ...
end

----------------------------------------------------------------------------
-- Stock vocabulary lookups (canonical spelling of a word)
----------------------------------------------------------------------------
-- Returns the word exactly as the stock database stores it, or nil if the word is
-- not there. `false` is returned when the stock database cannot be read at all.
local function canonicalWord(word)
    if type(word) ~= "string" or word == "" then return nil end
    local conn
    local ok, result = pcall(function()
        conn = SQ3.open(vocabulary_path, "ro")
        conn:exec("PRAGMA busy_timeout=200;")
        local row = runStatement(conn, "SELECT word FROM vocabulary WHERE word = ? LIMIT 1;", word)
        if not row then
            row = runStatement(conn,
                "SELECT word FROM vocabulary WHERE word = ? COLLATE NOCASE LIMIT 1;", word)
        end
        return row and row[1] or nil
    end)
    if conn then pcall(conn.close, conn) end
    if not ok then return false end
    return result
end

----------------------------------------------------------------------------
-- Write queue
----------------------------------------------------------------------------
local queue = {}
local flush_scheduled = false
local flush_failures = 0
local flush

local function scheduleIn(delay, fn)
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager and UIManager.scheduleIn then
        UIManager:scheduleIn(delay, fn)
        return true
    end
    return false
end

local function scheduleFlush(delay)
    if flush_scheduled then return end
    flush_scheduled = true
    if not scheduleIn(delay or FLUSH_DELAY, function()
        flush_scheduled = false
        flush()
    end) then
        flush_scheduled = false
        flush()
    end
end

local schema_ready = false

flush = function()
    if #queue == 0 then return end
    local batch = queue
    queue = {}

    local conn
    local ok, err = pcall(function()
        conn = openActivity()
        if not schema_ready then
            ensureSchema(conn)
            schema_ready = true
        end
        inTransaction(conn, function()
            -- Skips the row when a snapshot already recovered this very event
            -- (same word, timestamps within MATCH_WINDOW): no double counting.
            local insert_event = conn:prepare([[
                INSERT OR IGNORE INTO activity_events
                    (event_time, day_key, event_type, word, outcome, event_key)
                SELECT ?1, ?2, ?3, ?4, ?5, ?6
                WHERE NOT EXISTS (
                    SELECT 1 FROM activity_events
                    WHERE event_type = ?3 AND word = ?4
                      AND event_key LIKE 'snapshot:%'
                      AND event_time BETWEEN ?1 - ]] .. MATCH_WINDOW .. [[ AND ?1 + ]] .. MATCH_WINDOW .. [[
                );
            ]])
            local insert_day = conn:prepare([[
                INSERT OR IGNORE INTO activity_days (day_key, source)
                VALUES (?, 'recorded');
            ]])
            local delete_word = conn:prepare("DELETE FROM activity_events WHERE word = ?;")
            for _, event in ipairs(batch) do
                if event.type == "delete" then
                    delete_word:bind(event.word)
                    delete_word:step()
                    delete_word:clearbind():reset()
                else
                    local timestamp = math.floor(event.time)
                    local day_key = os.date("%Y-%m-%d", timestamp)
                    insert_event:bind(timestamp, day_key, event.type, event.word,
                        event.outcome or "", event.key)
                    insert_event:step()
                    insert_event:clearbind():reset()
                    if event.type == "review" then
                        insert_day:bind(day_key)
                        insert_day:step()
                        insert_day:clearbind():reset()
                    end
                end
            end
            insert_event:close()
            insert_day:close()
            delete_word:close()
        end)
    end)
    if conn then pcall(conn.close, conn) end

    if ok then
        flush_failures = 0
        touch()
        return
    end

    logger.warn("[vocabulary stats] Could not record activity:", err)
    flush_failures = flush_failures + 1
    if flush_failures >= MAX_FLUSH_FAILURES then
        logger.warn("[vocabulary stats] Dropping", #batch, "events after repeated failures")
        flush_failures = 0
        return
    end
    -- keep the batch (and its order) for the next attempt
    for _, event in ipairs(queue) do batch[#batch + 1] = event end
    queue = batch
    scheduleFlush(RETRY_DELAY)
end

-- Deterministic key: the same review/addition reported twice produces the same
-- key, so INSERT OR IGNORE keeps repeated batches and flush retries idempotent.
-- The review count keeps two genuinely different reviews of one word apart.
local function liveEventKey(event)
    return table.concat({
        "live", event.type, event.word,
        tostring(math.floor(event.time)), tostring(event.count or 0),
    }, ":")
end

local function enqueue(event)
    if event.type ~= "delete" and not event.key then
        event.key = liveEventKey(event)
    end
    queue[#queue + 1] = event
    if #queue >= FLUSH_NOW_ROWS then
        flush()
    else
        scheduleFlush()
    end
end

----------------------------------------------------------------------------
-- Current-day snapshot recovery
----------------------------------------------------------------------------
local function dayBounds(timestamp)
    local t = os.date("*t", timestamp)
    local first = os.time {
        year = t.year, month = t.month, day = t.day,
        hour = 0, min = 0, sec = 0,
    }
    local next_day = os.time {
        year = t.year, month = t.month, day = t.day + 1,
        hour = 0, min = 0, sec = 0,
    }
    return first, next_day, os.date("%Y-%m-%d", timestamp)
end

-- The stock Vocabulary Builder DB has only one review_time per word. This
-- recovers any identifiable latest reviews/additions for today after cloud sync
-- or while the patch was not loaded. Existing live events win, so sync won't
-- inflate the counters with a duplicate snapshot of the same timestamp.
local function backfillTodayFromVocabulary(conn, timestamp)
    local first, next_day = dayBounds(timestamp)
    local reviews, additions = 0, 0

    runStatement(conn, [[
        INSERT OR IGNORE INTO main.activity_events
            (event_time, day_key, event_type, word, outcome, event_key)
        SELECT CAST(v.review_time AS INTEGER),
               strftime('%Y-%m-%d', v.review_time, 'unixepoch', 'localtime'),
               'review', v.word, 'synced',
               'snapshot:review:' || v.word || ':' || CAST(v.review_time AS TEXT)
        FROM vb.vocabulary AS v
        WHERE v.review_time IS NOT NULL
          AND v.review_time >= ? AND v.review_time < ? AND v.review_time <= ?
          -- A real review: the word was reviewed before, or review_time moved past
          -- create_time. A word that was only looked up has review_time == create_time.
          AND (v.review_count > 0 OR v.review_time > v.create_time)
          AND NOT EXISTS (
              SELECT 1 FROM main.activity_events AS e
              WHERE e.event_type = 'review'
                AND e.word = v.word
                AND e.event_time BETWEEN CAST(v.review_time AS INTEGER) - ]] .. MATCH_WINDOW .. [[
                                     AND CAST(v.review_time AS INTEGER) + ]] .. MATCH_WINDOW .. [[
          );
    ]], first, next_day, timestamp)
    reviews = scalar(conn, "SELECT changes();")

    runStatement(conn, [[
        INSERT OR IGNORE INTO main.activity_days (day_key, source)
        SELECT DISTINCT day_key, 'recorded'
        FROM main.activity_events
        WHERE event_type = 'review' AND event_time >= ? AND event_time < ?;
    ]], first, next_day)

    runStatement(conn, [[
        INSERT OR IGNORE INTO main.activity_events
            (event_time, day_key, event_type, word, outcome, event_key)
        SELECT CAST(v.create_time AS INTEGER),
               strftime('%Y-%m-%d', v.create_time, 'unixepoch', 'localtime'),
               'add', v.word, 'synced',
               'snapshot:add:' || v.word || ':' || CAST(v.create_time AS TEXT)
        FROM vb.vocabulary AS v
        WHERE v.create_time IS NOT NULL
          AND v.create_time >= ? AND v.create_time < ? AND v.create_time <= ?
          AND NOT EXISTS (
              SELECT 1 FROM main.activity_events AS e
              WHERE e.event_type = 'add'
                AND e.word = v.word
                AND e.event_time BETWEEN CAST(v.create_time AS INTEGER) - ]] .. MATCH_WINDOW .. [[
                                     AND CAST(v.create_time AS INTEGER) + ]] .. MATCH_WINDOW .. [[
          );
    ]], first, next_day, timestamp)
    additions = scalar(conn, "SELECT changes();")
    return reviews, additions
end

----------------------------------------------------------------------------
-- Reconcile: drop the activity of words that no longer exist
----------------------------------------------------------------------------
local function reconcileNow()
    if not fileExists(activity_path) or not fileExists(vocabulary_path) then return 0 end
    local conn
    local removed = 0
    local ok, err = pcall(function()
        conn = openActivity()
        ensureSchema(conn)
        if not attachVocabulary(conn) then return end
        -- An uncorrelated NOT IN is evaluated once into a temporary index, so this is
        -- a single pass even with tens of thousands of words.
        conn:exec([[
            DELETE FROM main.activity_events
            WHERE word <> '' AND word NOT IN (SELECT word FROM vb.vocabulary);
        ]])
        removed = scalar(conn, "SELECT changes();")
    end)
    if conn then pcall(conn.close, conn) end
    if not ok then
        logger.warn("[vocabulary stats] Reconcile failed:", err)
        return 0
    end
    if removed > 0 then
        logger.info("[vocabulary stats] Removed activity of", removed, "deleted-word events")
        touch()
    end
    return removed
end

local maintenance
local reconcile_scheduled = false
local function scheduleReconcile()
    if reconcile_scheduled then return end
    reconcile_scheduled = true
    if not scheduleIn(RECONCILE_DELAY, function()
        reconcile_scheduled = false
        if maintenance then
            maintenance()
        else
            flush()
            reconcileNow()
        end
    end) then
        reconcile_scheduled = false
        if maintenance then maintenance() end
    end
end

----------------------------------------------------------------------------
-- Maintenance (once per KOReader session, shortly after start)
----------------------------------------------------------------------------
local last_sync_summary = { removed = 0, reviews = 0, additions = 0 }

maintenance = function()
    flush()
    last_sync_summary = { removed = 0, reviews = 0, additions = 0 }
    local conn
    local ok, err = pcall(function()
        conn = openActivity()
        ensureSchema(conn)
        schema_ready = true

        local function step(name, fn)
            local step_ok, step_err = pcall(fn)
            if not step_ok then
                logger.warn("[vocabulary stats] Maintenance step failed:", name, step_err)
            end
        end

        local today = os.date("%Y-%m-%d")

        -- 1. De-duplicate once, then enforce uniqueness so re-flushed items never
        --    count twice.
        step("dedupe", function()
            if getMeta(conn, "dedupe_v3") ~= "done" then
                inTransaction(conn, function()
                    conn:exec([[
                        DELETE FROM activity_events
                    WHERE event_key LIKE 'legacy:%'
                      AND id NOT IN (
                          SELECT MIN(id) FROM activity_events
                          WHERE event_key LIKE 'legacy:%'
                          GROUP BY event_type, word, event_time
                      );
                    ]])
                end)
                setMeta(conn, "dedupe_v3", "done")
            end
            -- event_key provides retry idempotency without collapsing two real
            -- reviews of the same word that happened within one second.
            conn:exec("DROP INDEX IF EXISTS activity_event_unique;")
            conn:exec([[
                CREATE UNIQUE INDEX IF NOT EXISTS activity_event_key_unique
                    ON activity_events(event_key);
            ]])
        end)

        -- 1b. One-time (v5): remove duplicates that v4 could write. v4 keyed live
        --     events with a per-session serial, so the same review reported twice by
        --     Vocabulary Builder was counted twice, and a live event could sit next to
        --     a "synced" snapshot of the very same review.
        step("dedupe-live", function()
            if getMeta(conn, "dedupe_live_v5") == "done" then return end
            inTransaction(conn, function()
                conn:exec([[
                    DELETE FROM activity_events
                    WHERE event_key LIKE 'live:%'
                      AND id NOT IN (
                          SELECT MIN(id) FROM activity_events
                          WHERE event_key LIKE 'live:%'
                          GROUP BY event_type, word, event_time
                      );
                ]])
                conn:exec([[
                    DELETE FROM activity_events
                    WHERE event_key LIKE 'snapshot:%'
                      AND EXISTS (
                          SELECT 1 FROM activity_events AS l
                          WHERE l.event_key LIKE 'live:%'
                            AND l.event_type = activity_events.event_type
                            AND l.word = activity_events.word
                            AND l.event_time BETWEEN activity_events.event_time - ]] .. MATCH_WINDOW .. [[
                                                 AND activity_events.event_time + ]] .. MATCH_WINDOW .. [[
                      );
                ]])
            end)
            setMeta(conn, "dedupe_live_v5", "done")
        end)

        -- 1c. Streak days dated in the future can only come from a clock that was
        --     ahead. They are re-derivable from the stock data if they were real.
        step("future-days", function()
            runStatement(conn,
                "DELETE FROM activity_days WHERE source = 'estimated_legacy' AND day_key > ?;", today)
        end)

        -- 2. Streak days that only exist as events (data written by older versions).
        step("days-from-events", function()
            if getMeta(conn, "days_from_events_v3") ~= "done" then
                conn:exec([[
                    INSERT OR IGNORE INTO activity_days (day_key, source)
                    SELECT DISTINCT day_key, 'recorded' FROM activity_events
                    WHERE event_type = 'review';
                ]])
                setMeta(conn, "days_from_events_v3", "done")
            end
        end)

        local vocabulary_ready = false
        step("attach", function() vocabulary_ready = attachVocabulary(conn) end)

        if vocabulary_ready then
            -- 2b. One-time (v5): v4 recovered a word's creation time as if it were a
            -- review (review_time == create_time for a word that was only looked up).
            -- Drop those fake events, and the streak days that only they created.
            -- Days with genuine evidence are re-seeded by the next step.
            step("cleanup-creation-reviews", function()
                if getMeta(conn, "creation_reviews_cleanup_v5") == "done" then return end
                local fake_where = [[
                    e.event_type = 'review'
                    AND e.event_key LIKE 'snapshot:review:%'
                    AND e.event_time = CAST(v.create_time AS INTEGER)
                ]]
                local fake_days = {}
                local stmt = conn:prepare([[
                    SELECT DISTINCT e.day_key
                    FROM main.activity_events AS e
                    JOIN vb.vocabulary AS v ON v.word = e.word
                    WHERE ]] .. fake_where .. ";")
                while true do
                    local row = stmt:step()
                    if not row then break end
                    fake_days[#fake_days + 1] = row[1]
                end
                stmt:close()

                conn:exec([[
                    DELETE FROM main.activity_events
                    WHERE id IN (
                        SELECT e.id
                        FROM main.activity_events AS e
                        JOIN vb.vocabulary AS v ON v.word = e.word
                        WHERE ]] .. fake_where .. [[
                    );
                ]])
                for _, day in ipairs(fake_days) do
                    local left = scalar(conn, [[
                        SELECT COUNT(*) FROM main.activity_events
                        WHERE event_type = 'review' AND day_key = ?;
                    ]], day)
                    if left == 0 then
                        runStatement(conn, "DELETE FROM main.activity_days WHERE day_key = ?;", day)
                    end
                end
                setMeta(conn, "creation_reviews_cleanup_v5", "done")
            end)

            -- 3. Idempotently seed all days represented by current stock records.
            -- Run this again after sync so newly imported review dates are included;
            -- this is still one set-based SQL statement, never a per-word Lua loop.
            -- Timestamps in the future (clock errors) never become streak days.
            step("legacy-days", function()
                runStatement(conn, [[
                    INSERT OR IGNORE INTO activity_days (day_key, source)
                    SELECT DISTINCT
                        strftime('%Y-%m-%d', review_time, 'unixepoch', 'localtime'),
                        'estimated_legacy'
                    FROM vb.vocabulary
                    WHERE review_time IS NOT NULL AND review_time > 0
                      AND review_time <= ?
                      AND (review_count > 0 OR review_time > create_time);
                ]], os.time() + FUTURE_TOLERANCE)
                setMeta(conn, "legacy_seed_day", today)
            end)

            -- 4. Recover same-day additions and latest review timestamps that arrived
            -- through the stock sync path (which doesn't call batchUpdateItems).
            step("snapshot-today", function()
                local reviews, additions = backfillTodayFromVocabulary(conn, os.time())
                last_sync_summary.reviews = reviews or 0
                last_sync_summary.additions = additions or 0
            end)

            -- 5. Words deleted while the patch was not running, including cloud sync.
            step("reconcile", function()
                conn:exec([[
                    DELETE FROM main.activity_events
                    WHERE word <> '' AND word NOT IN (SELECT word FROM vb.vocabulary);
                ]])
                last_sync_summary.removed = scalar(conn, "SELECT changes();")
            end)
        end

        -- 6. Prune old events, once per day. activity_days is kept forever.
        step("prune", function()
            if getMeta(conn, "prune_day") ~= today then
                local cutoff = os.time() - RETENTION_DAYS * 86400
                runStatement(conn, "DELETE FROM activity_events WHERE event_time < ?;", cutoff)
                setMeta(conn, "prune_day", today)
            end
        end)

        -- The micro-module may rely on activity_days alone once this is set.
        step("mark", function() setMeta(conn, "days_synced_v3", "done") end)
    end)
    if conn then pcall(conn.close, conn) end
    if not ok then
        logger.warn("[vocabulary stats] Maintenance failed:", err)
    else
        logger.info("[vocabulary stats] Maintenance finished")
    end
    touch()
end

----------------------------------------------------------------------------
-- Bridge for the micro-module
----------------------------------------------------------------------------
bridge.flush = function() flush(); return #queue == 0 end
bridge.getBestStreak = function()
    return readBestStreakFromPath(vocabulary_path)
end
bridge.setBestStreak = function(value)
    local best, err = writeBestStreakToPath(vocabulary_path, value)
    if best == nil then error(err or "could not save best streak", 0) end
    touch()
    return best
end
-- A confirmed native Flashcards Undo is relayed by Learning Audit with its
-- exact committed timestamp. Correct only the corresponding Activity event;
-- never reverse a review in the stock Vocabulary Builder here.
bridge.undoReview = function(word, stamped)
    if type(word) ~= "string" or not tonumber(stamped) then return false end
    flush()
    -- Never mark Undo as complete while the matching original attempt could
    -- still be queued for writing. Recovery will retry after a successful flush.
    if #queue > 0 then
        logger.warn("[vocabulary stats] Undo deferred: activity event queue not flushed")
        return false
    end
    if not fileExists(activity_path) then return true end
    local conn, removed = nil, 0
    local ok, err = pcall(function()
        conn = openActivity()
        ensureSchema(conn)
        local ts = math.floor(tonumber(stamped))
        inTransaction(conn, function()
            local applied = scalar(conn, [[SELECT COUNT(*) FROM activity_undo_events
                WHERE word=? AND review_time=?;]], word, ts)
            if applied > 0 then return end
            -- Delete at most ONE attempt. The previous +/-2-second DELETE
            -- could remove several real reviews of the same word, and a
            -- second call after a partial failure could delete yet another.
            local row = runStatement(conn, [[SELECT id, day_key
                FROM activity_events
                WHERE event_type='review' AND word=?
                    AND event_time BETWEEN ? AND ?
                ORDER BY ABS(event_time-?) ASC, id DESC LIMIT 1;]],
                word, ts-2, ts+2, ts)
            if row then
                local id, key = tonumber(row[1]), row[2]
                if id then
                    runStatement(conn, "DELETE FROM activity_events WHERE id=?;", id)
                    removed = scalar(conn, "SELECT changes();")
                    if removed > 0 and type(key) == "string" then
                        local remaining = scalar(conn, [[SELECT COUNT(*) FROM activity_events
                            WHERE event_type='review' AND day_key=?;]], key)
                        if remaining == 0 then
                            runStatement(conn, [[DELETE FROM activity_days
                                WHERE day_key=? AND source='recorded';]], key)
                        end
                    end
                end
            end
            -- Write the idempotency marker in the SAME transaction as the
            -- deletion, so a crash cannot leave one without the other.
            runStatement(conn, [[INSERT OR IGNORE INTO activity_undo_events
                (word, review_time) VALUES(?,?);]], word, ts)
        end)
    end)
    if conn then pcall(conn.close,conn) end
    if not ok then
        logger.warn("[vocabulary stats] Undo event correction failed:", err)
        return false
    end
    if removed > 0 then touch() end
    -- Absence of a matching event is not a native Undo failure: this device
    -- might never have recorded that exact attempt (older history/sync).
    return true
end

-- Keep direct references to the embedded v7 implementation. Legacy v6
-- patches may redefine the shared "vocabulary_builder_stats" functions on
-- startup, even when FlipSide loaded v7 first.
package.loaded["flipside_activity_stats_v7"] = {
    version = VERSION,
    undoReview = bridge.undoReview,
    flush = bridge.flush,
}

bridge.sync = function()
    -- Run the same full reconciliation/backfill used after cloud sync and at startup.
    maintenance()
    return last_sync_summary.removed or 0,
        last_sync_summary.reviews or 0,
        last_sync_summary.additions or 0
end

----------------------------------------------------------------------------
-- Hooks
----------------------------------------------------------------------------
local REMOVE_METHODS = { "remove", "removeWord", "deleteWord", "delete", "deleteItem", "removeItem" }
local PURGE_METHODS = { "purge", "clear", "clearAll", "deleteAll", "removeAll", "wipe" }

local function collectWords(arg, out)
    out = out or {}
    if type(arg) == "string" then
        out[#out + 1] = arg
    elseif type(arg) == "table" then
        if type(arg.word) == "string" then
            out[#out + 1] = arg.word
        elseif type(arg.item) == "table" and type(arg.item.word) == "string" then
            out[#out + 1] = arg.item.word
        else
            for _, value in ipairs(arg) do
                if type(value) == "table" or type(value) == "string" then
                    collectWords(value, out)
                end
            end
        end
    end
    return out
end

userpatch.registerPatchPluginFunc("flipside", function(_plugin)
    -- The Vocabulary Builder has already required its local db.lua module when
    -- this callback runs, so require("db") should return that same module table.
    local ok, DB = pcall(require, "flipside_db")
    if not ok or type(DB) ~= "table" then
        logger.warn("[vocabulary stats] Could not access Vocabulary Builder database module")
        if type(_plugin) == "table" then _plugin._flipside_audit_load_failed = true end
        return
    end
    if DB._vocabulary_stats_patch_applied then return end

    local patched = false

    -- Reviews: queue each reviewed word only after the stock update succeeded.
    if type(DB.batchUpdateItems) == "function" then
        local originalBatchUpdateItems = DB.batchUpdateItems
        DB.batchUpdateItems = function(self, items, ...)
            local pending = {}
            local now = os.time()
            for _, item in ipairs(items or {}) do
                local reviewed = item and tonumber(item.review_time)
                if item and item.word and reviewed and reviewed > 0
                    and reviewed <= now + FUTURE_TOLERANCE then
                    local count = tonumber(item.review_count) or 0
                    local created = tonumber(item.create_time)
                    -- review_time == create_time with no reviews is a word that was
                    -- only looked up: an addition, not a review.
                    if count > 0 or not created or reviewed > created then
                        pending[#pending + 1] = {
                            type = "review",
                            time = reviewed,
                            word = item.word,
                            count = count,
                            outcome = (tonumber(item.streak_count) or 0) > 0 and "got" or "forgot",
                        }
                    end
                end
            end
            return after(function()
                for _, event in ipairs(pending) do enqueue(event) end
            end, originalBatchUpdateItems(self, items, ...))
        end
        patched = true
    else
        logger.warn("[vocabulary stats] DB.batchUpdateItems was not found; review tracking is disabled")
        if type(_plugin) == "table" then _plugin._flipside_audit_load_failed = true end
    end

    -- New words: counted only if the word was absent before the stock insert.
    if type(DB.insertOrUpdate) == "function" then
        local originalInsertOrUpdate = DB.insertOrUpdate
        DB.insertOrUpdate = function(self, entry, ...)
            local word = type(entry) == "table" and entry.word or nil
            local existed = true
            if type(word) == "string" then
                local found = canonicalWord(word)
                if found ~= false then existed = found ~= nil end
            end
            return after(function()
                if type(word) ~= "string" or existed then return end
                local stored = canonicalWord(word)
                if type(stored) == "string" then
                    enqueue({
                        type = "add",
                        time = tonumber(entry.time) or os.time(),
                        word = stored,
                        outcome = "new",
                    })
                end
            end, originalInsertOrUpdate(self, entry, ...))
        end
        patched = true
    else
        logger.warn("[vocabulary stats] DB.insertOrUpdate was not found; new-word tracking is disabled")
        if type(_plugin) == "table" then _plugin._flipside_audit_load_failed = true end
    end

    -- Deleting a word: remove its activity too.
    for _, name in ipairs(REMOVE_METHODS) do
        local original = DB[name]
        if type(original) == "function" then
            DB[name] = function(self, arg, ...)
                local words = collectWords(arg)
                return after(function()
                    for _, word in ipairs(words) do
                        enqueue({ type = "delete", word = word })
                    end
                    scheduleReconcile()
                end, original(self, arg, ...))
            end
            patched = true
        end
    end

    -- Cloud sync merges databases through DB.onSync rather than batchUpdateItems.
    -- The callback replaces/merges the stock data but never emits review events.
    if type(DB.onSync) == "function" then
        local originalOnSync = DB.onSync
        local function packReturns(...)
            return { n = select("#", ...), ... }
        end
        DB.onSync = function(local_path, cached_path, income_path, ...)
            -- This field is a historical record, so merge it with max(): a sync
            -- from either device must not erase the larger Best streak value.
            local shared_best = math.max(
                readBestStreakFromPath(local_path),
                readBestStreakFromPath(cached_path),
                readBestStreakFromPath(income_path))
            local results = packReturns(originalOnSync(local_path, cached_path, income_path, ...))
            if results[1] then
                local ok, value, err = pcall(writeBestStreakToPath, local_path, shared_best)
                if not ok or value == nil then
                    logger.warn("[vocabulary stats] Could not merge shared best streak:", ok and err or value)
                end
            end
            if results[1] and type(auditBridge)=="table" then
                if type(auditBridge.noteStreakSync)=="function" then
                    local ok,err=pcall(auditBridge.noteStreakSync)
                    if not ok then logger.warn("[vocabulary stats] Streak sync marker:",err) end
                end
                if type(auditBridge.captureStreakScheduleQuietly)=="function" then
                    scheduleIn(2,auditBridge.captureStreakScheduleQuietly)
                end
            end
            scheduleReconcile()
            return unpack(results, 1, results.n)
        end
        patched = true
    end

    -- Bulk operations whose exact scope we cannot know: reconcile afterwards.
    for _, name in ipairs(PURGE_METHODS) do
        local original = DB[name]
        if type(original) == "function" then
            DB[name] = function(self, ...)
                return after(scheduleReconcile, original(self, ...))
            end
            patched = true
        end
    end

    if patched then
        DB._vocabulary_stats_patch_applied = true
        if not scheduleIn(STARTUP_DELAY, maintenance) then
            maintenance()
        end
        logger.info("[vocabulary stats] Activity tracking enabled (v" .. VERSION .. ")")
    end
end, "activity_stats")

    end
    initializeEmbeddedActivityRecorder()
end

-- One-folder chooser used exclusively from Appearance > Sync settings.
-- No account secrets are copied: only an account reference and chosen path.
local function chooseAuditFolder(plugin, completion)
    local cs, err = cloudGetPlugin(plugin)
    if not cs then
        if completion then completion(false, err) end
        return false
    end
    cs:onShowCloudStorageList(function(chosen)
        if type(chosen) ~= "table" or type(chosen.type) ~= "string"
                or type(chosen.url) ~= "string" then
            if completion then completion(false, "No folder selected") end
            return
        end
        local selection = {
            type = chosen.type, name = chosen.name, address = chosen.address,
            username = chosen.username, url = chosen.url,
        }
        local ok, err = pcall(function()
            cloud_settings:saveSetting("selected_folder", selection)
            cloud_settings:flush()
        end)
        if completion then completion(ok, ok and selection or err) end
    end)
    return true
end
local function selectedAuditFolder()
    return cloud_settings:readSetting("selected_folder")
end
return {
    syncNow = function(plugin, completion)
        return cloudSyncNow(plugin, nil, true, completion)
    end,
    chooseFolder = chooseAuditFolder,
    getFolder = selectedAuditFolder,
    -- Read-only access to the existing Learning Analysis cloud transport.
    -- Calendar exchange reuses this server; no new settings or credentials.
    getCloudTransport = cloudServer,
}
