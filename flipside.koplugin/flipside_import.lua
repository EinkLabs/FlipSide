-- FlipSide: safe, repeatable, one-tap import from KOReader's official Vocabulary Builder.
-- Read the official database only; never modify its rows or user settings.
-- Existing FlipSide words (and all of their review progress) are left unchanged.
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local M = {}
local settings = DataStorage:getSettingsDir()
local source_path = settings .. "/vocabulary_builder.sqlite3"
local target_path = settings .. "/flipside/vocabulary_builder.sqlite3"
local backup_path = settings .. "/flipside/vocabulary_builder_before_import.sqlite3"

local function sqlQuote(s)
    return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function field(columns, column, fallback)
    if columns[column] then return "v." .. column end
    return fallback
end

local function readColumns(conn, schema, tbl)
    local rows = conn:exec("PRAGMA " .. schema .. ".table_info(" .. tbl .. ");")
    local names = {}
    if type(rows) == "table" and type(rows.name) == "table" then
        for _, name in ipairs(rows.name) do names[tostring(name)] = true end
    end
    return names
end

local function assertColumns(columns, required, source)
    for _, name in ipairs(required) do
        if not columns[name] then
            error(source .. " lacks the required column '" .. name .. "'. No cards were changed.")
        end
    end
end

function M.importNew()
    if lfs.attributes(source_path, "mode") ~= "file" then
        error("Official Vocabulary Builder database not found. Open Vocabulary Builder first; its database should be in koreader/settings/vocabulary_builder.sqlite3.")
    end
    if lfs.attributes(target_path, "mode") ~= "file" then
        error("FlipSide database is missing. Open FlipSide once before importing.")
    end
    local conn = SQ3.open(target_path)
    if not conn then error("Could not open FlipSide database.") end
    local attached, transaction = false, false
    local function work()
        -- Do not modify the source database; attach it solely to SELECT its rows.
        -- Attaching a live WAL database reads a consistent SQLite snapshot.
        conn:exec("ATTACH DATABASE " .. sqlQuote(source_path) .. " AS vb_source;")
        attached = true
        local src = readColumns(conn, "vb_source", "vocabulary")
        local dst = readColumns(conn, "main", "vocabulary")
        assertColumns(src, {"word", "create_time", "due_time"}, "Official database")
        assertColumns(dst, {"word", "title_id", "create_time", "due_time", "review_time", "review_count", "prev_context", "next_context", "streak_count", "highlight"}, "FlipSide database")
        local title_columns = readColumns(conn, "vb_source", "title")
        local has_titles = title_columns.name and title_columns.id and src.title_id
        local from = " FROM vb_source.vocabulary AS v "
        local title_expr
        if has_titles then
            from = from .. " LEFT JOIN vb_source.title AS st ON st.id = v.title_id "
            title_expr = "COALESCE(NULLIF(TRIM(st.name), ''), 'Unknown book')"
        elseif src.book_title then
            title_expr = "COALESCE(NULLIF(TRIM(v.book_title), ''), 'Unknown book')"
        else
            title_expr = "'Unknown book'"
        end
        local valid = " WHERE v.word IS NOT NULL AND LENGTH(TRIM(v.word)) > 0 "
        local new_only = valid .. " AND NOT EXISTS (SELECT 1 FROM main.vocabulary AS existing WHERE existing.word = v.word) "
        local total = tonumber(conn:rowexec("SELECT COUNT(*)" .. from .. valid)) or 0
        local pending = tonumber(conn:rowexec("SELECT COUNT(*)" .. from .. new_only)) or 0
        local result = { total = total, skipped = total - pending, imported = 0, backup = false }
        if pending == 0 then return result end

        -- A real SQLite snapshot, not a file copy of a live WAL database.
        -- Created only on the first import; never overwrites a prior backup.
        if lfs.attributes(backup_path, "mode") ~= "file" then
            local ok, err = pcall(conn.exec, conn, "VACUUM main INTO " .. sqlQuote(backup_path) .. ";")
            if not ok then
                os.remove(backup_path) -- VACUUM can leave an incomplete file.
                error("Could not create the pre-import backup (" .. tostring(err) .. "). Nothing was imported.")
            end
            result.backup = true
        end

        local now = tostring(os.time())
        local create_time = "COALESCE(" .. field(src, "create_time", "NULL") .. ", " .. now .. ")"
        local due_time = "COALESCE(" .. field(src, "due_time", "NULL") .. ", " .. create_time .. " + 300)"
        local titles_sql = "INSERT OR IGNORE INTO main.title (name) SELECT DISTINCT " .. title_expr .. from .. new_only .. ";"
        local data_sql = [[INSERT OR IGNORE INTO main.vocabulary
            (word, title_id, create_time, review_time, due_time, review_count,
             prev_context, next_context, streak_count, highlight)
            SELECT v.word, (SELECT id FROM main.title WHERE name = ]] .. title_expr .. [[),
                   ]] .. create_time .. ", " .. field(src, "review_time", "NULL") .. ", " .. due_time .. ", " ..
                   "COALESCE(" .. field(src, "review_count", "0") .. ", 0), " ..
                   field(src, "prev_context", "NULL") .. ", " .. field(src, "next_context", "NULL") .. ", " ..
                   "COALESCE(" .. field(src, "streak_count", "0") .. ", 0), " .. field(src, "highlight", "NULL") ..
                   from .. new_only .. ";"
        conn:exec("BEGIN IMMEDIATE;")
        transaction = true
        conn:exec(titles_sql)
        conn:exec(data_sql)
        result.imported = tonumber(conn:rowexec("SELECT changes();")) or 0
        if result.imported ~= pending then
            -- IGNORE hides invalid rows: fail safely rather than silently dropping them.
            error("The import count did not match the source. Changes were rolled back.")
        end
        conn:exec("COMMIT;")
        transaction = false
        return result
    end
    local ok, value = pcall(work)
    if transaction then pcall(conn.exec, conn, "ROLLBACK;") end
    if attached then pcall(conn.exec, conn, "DETACH DATABASE vb_source;") end
    pcall(conn.close, conn)
    if not ok then
        logger.warn("FlipSide: Vocabulary Builder import failed:", value)
        error(value, 0)
    end
    logger.info("FlipSide: imported", value.imported, "new official cards; skipped", value.skipped)
    return value
end

return M
