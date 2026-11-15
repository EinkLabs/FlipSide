-- Independent durable checkpoints for cram (not the SRS database).
-- LuaSettings backs up and atomically flushes the small snapshot file.
-- Separate slots keep OFF, Intensive, Ultra and filtered books independent.
local LuaSettings = require("luasettings")
local Diag = require("flipside_diagnostics")
local DataStorage = require("datastorage")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local Store = {}
Store.__index = Store

function Store.open()
    local dir = DataStorage:getSettingsDir() .. "/flipside"
    util.makePath(dir)
    local file = dir .. "/cram_progress.lua"
    local settings = LuaSettings:open(file)
    local saved = settings:readSetting("snapshots")
    local sequence = settings:readSetting("sequence")
    -- If the existing file and its .old backup are unreadable, NEVER
    -- overwrite an old snapshot with an empty default state.
    if lfs.attributes(file, "mode") == "file" and
            (type(saved) ~= "table" or type(sequence) ~= "number") then
        error("Cram progress file is unreadable; original kept for recovery")
    end
    if type(saved) ~= "table" then saved = {} end
    Diag.inspectCramSnapshots(saved) -- warnings only; NEVER change saved data
    return setmetatable({file=file, settings=settings, snapshots=saved,
        sequence=tonumber(sequence) or 0}, Store)
end

function Store.key(mode, filter)
    filter = type(filter) == "table" and filter or {}
    local kind = tostring(filter.kind or "all")
    local book = kind == "book" and tostring(filter.book or "") or ""
    -- Stable even across midnight: a partially learned word must not
    -- disappear solely because Today became Yesterday.
    return mode .. "\t" .. kind .. "\t" .. book
end

function Store:get(key)
    return self.snapshots[key]
end

function Store:put(key, snapshot)
    if type(key) ~= "string" or type(snapshot) ~= "table" then return false end
    -- Never alter the in-memory last-known-good checkpoint before disk
    -- verification. An unsuccessful save must not masquerade as durable.
    local updated = {}
    for k,v in pairs(self.snapshots) do updated[k] = v end
    updated[key] = snapshot
    return self:_commitSnapshots(updated)
end

-- Save each genuine official miss to BOTH cram modes, regardless of which
-- one is currently selected (including OFF). The active queue, if any, is
-- supplied as a snapshot; it is never silently replaced by a stale saved one.
-- All targeted modes/filters are written in ONE verified file checkpoint.
local function copySnapshot(source)
    source = type(source) == "table" and source or {}
    local result = {
        version = 1, queue = {}, completed = {},
        attempts = source.attempts or 0,
        correct = source.correct or 0, missed = source.missed or 0,
    }
    for _, field in ipairs({"queue", "completed"}) do
        for _, item in ipairs(type(source[field]) == "table" and source[field] or {}) do
            if type(item) == "table" then
                local copy = {}
                for k, v in pairs(item) do copy[k] = v end
                result[field][#result[field] + 1] = copy
            end
        end
    end
    return result
end

local function existingWord(snapshot, word)
    for i, item in ipairs(snapshot.queue) do
        if item.word == word then
            return {kind="queued", position=i, streak=item.streak,
                created=item.created}
        end
    end
    for _, item in ipairs(snapshot.completed) do
        if item.word == word then
            return {kind="completed", created=item.created}
        end
    end
    return {kind="absent"}
end

local function discardWord(snapshot, word)
    for _, field in ipairs({"queue", "completed"}) do
        local items = snapshot[field]
        for i=#items,1,-1 do
            if items[i].word == word then table.remove(items,i) end
        end
    end
end

local function requeueOfficialError(snapshot, card)
    -- Keep an existing word's position, reset only that word's temporary
    -- streak. If the word has been recreated, discard the old generation.
    local previous = existingWord(snapshot, card.word)
    if previous.kind == "queued" and
            (not tonumber(previous.created) or not tonumber(card.created)
                or tonumber(previous.created) == tonumber(card.created)) then
        snapshot.queue[previous.position].streak = 0
    else
        discardWord(snapshot, card.word)
        snapshot.queue[#snapshot.queue + 1] = {
            word=card.word, created=tonumber(card.created), streak=0,
        }
    end
    return previous
end

function Store:_commitSnapshots(updated)
    local seq = self.sequence + 1
    self.settings:saveSetting("snapshots", updated)
    self.settings:saveSetting("sequence", seq)
    self.settings:flush()
    local verified = LuaSettings:open(self.file)
    if tonumber(verified:readSetting("sequence")) ~= seq then
        error("Cram mode checkpoint not verified on disk")
    end
    self.snapshots = updated
    self.sequence = seq
    return true
end

function Store:recordOfficialMiss(card, filters, live_slot, live_snapshot)
    assert(type(card) == "table" and type(card.word) == "string"
        and card.word ~= "", "Invalid official miss")
    assert(type(filters) == "table", "Missing filter memberships")
    local updated = {}
    for k,v in pairs(self.snapshots) do updated[k] = v end
    local before, visited = {}, {}
    for _, filter in ipairs(filters) do
        for _, mode in ipairs({"intensive", "ultra"}) do
            local key = Store.key(mode, filter)
            if not visited[key] then
                visited[key] = true
                local original = key == live_slot and live_snapshot
                    or self.snapshots[key]
                local snapshot = copySnapshot(original)
                before[key] = requeueOfficialError(snapshot, card)
                updated[key] = snapshot
            end
        end
    end
    if not next(visited) then error("No eligible cram filters for official miss") end
    self:_commitSnapshots(updated)
    return before
end

-- Undo the official review across both modes and all affected filters.
-- A true absent state is distinguished from nil to avoid leaving phantom
-- cards in the inactive mode after an Undo.
function Store:undoOfficialMiss(word, previous_by_key, live_slot, live_snapshot)
    assert(type(word) == "string" and type(previous_by_key) == "table")
    local updated = {}
    for k,v in pairs(self.snapshots) do updated[k] = v end
    for key, previous in pairs(previous_by_key) do
        local original = key == live_slot and live_snapshot or self.snapshots[key]
        local snapshot = copySnapshot(original)
        discardWord(snapshot, word)
        if type(previous) == "table" then
            if previous.kind == "queued" then
                local pos = math.max(1, math.min(#snapshot.queue+1,
                    math.floor(tonumber(previous.position) or 1)))
                table.insert(snapshot.queue, pos, {word=word,
                    created=tonumber(previous.created),
                    streak=math.max(0, math.floor(tonumber(previous.streak) or 0))})
            elseif previous.kind == "completed" then
                snapshot.completed[#snapshot.completed+1] = {word=word,
                    created=tonumber(previous.created)}
            end
        end
        updated[key] = snapshot
    end
    return self:_commitSnapshots(updated)
end

-- Restore a single word's prior checkpoint for Undo, potentially in a
-- DIFFERENT mode from the one currently displayed. Never reset the queue.
function Store:restoreWord(key, word, previous)
    local original = self.snapshots[key]
    if type(original) ~= "table" then return false end
    -- Work on a private copy. On a failed flush, the last confirmed
    -- in-memory checkpoint must remain exactly as it was on disk.
    local snapshot = copySnapshot(original)
    local queue = type(snapshot.queue) == "table" and snapshot.queue or {}
    local completed = type(snapshot.completed) == "table" and snapshot.completed or {}
    snapshot.queue, snapshot.completed = queue, completed
    for _, field in ipairs({"queue", "completed"}) do
        local entries = snapshot[field]
        for i = #entries, 1, -1 do
            if type(entries[i]) == "table" and entries[i].word == word then
                table.remove(entries, i)
            end
        end
    end
    if type(previous) == "table" then
        if previous.kind == "completed" then
            completed[#completed + 1] = {word=word,
                created=tonumber(previous.created)}
        elseif previous.kind == "queued" then
            local position = math.max(1, math.min(#queue+1,
                math.floor(tonumber(previous.position) or 1)))
            table.insert(queue, position, {word=word,
                created=tonumber(previous.created),
                streak=math.max(0, math.floor(tonumber(previous.streak) or 0))})
        end
    end
    return self:put(key, snapshot)
end

function Store:removeWord(word)
    local updated, changed = {}, false
    for key, snapshot in pairs(self.snapshots) do
        if type(snapshot) == "table" then
            local clone = copySnapshot(snapshot)
            local before = #clone.queue + #clone.completed
            discardWord(clone, word)
            if before ~= #clone.queue + #clone.completed then
                updated[key] = clone
                changed = true
            else
                updated[key] = snapshot
            end
        else
            updated[key] = snapshot
        end
    end
    if changed then self:_commitSnapshots(updated) end
    return changed
end


-- Explicit, opt-in restart for a deck which has truly become empty.
-- Never reset from a filtered/partial view or a missing/unreadable SQLite DB.
-- Keep BOTH the last checkpoint and LuaSettings' .old backup in a dated
-- directory, rather than allowing a new flush to overwrite recovery data.
function Store.hasSavedState(store)
    local file = DataStorage:getSettingsDir() .. "/flipside/cram_progress.lua"
    if lfs.attributes(file, "mode") ~= "file"
            and lfs.attributes(file .. ".old", "mode") ~= "file" then
        return false
    end
    if not store then return true end -- unreadable is recoverable ONLY by consent
    return (type(store.snapshots) == "table" and next(store.snapshots) ~= nil)
        or (tonumber(store.sequence) or 0) > 1
end

function Store.resetAfterVerifiedEmptyDeck(verified_empty)
    if verified_empty ~= true then error("Refusing CRAM reset without verified empty deck") end
    -- Double-check the actual SQLite DB, not the selected/filtered list.
    -- Read-only opening prevents accidentally creating a missing database.
    local dir = DataStorage:getSettingsDir() .. "/flipside"
    local db_path = dir .. "/vocabulary_builder.sqlite3"
    if lfs.attributes(db_path, "mode") ~= "file" then
        error("Cannot confirm empty deck: the private database is missing")
    end
    local sqlite = require("lua-ljsqlite3/init")
    local db
    local ok, integrity, count = pcall(function()
        db = sqlite.open(db_path, "ro")
        return db:rowexec("PRAGMA quick_check;"),
            db:rowexec("SELECT COUNT(*) FROM vocabulary;")
    end)
    if db then pcall(db.close, db) end
    if not ok or tostring(integrity) ~= "ok" or tonumber(count) ~= 0 then
        error("Database is unreadable, inconsistent or no longer empty; CRAM kept")
    end

    util.makePath(dir)
    local file = dir .. "/cram_progress.lua"
    local old = file .. ".old"
    local archive_root = dir .. "/cram-reset-backups"
    util.makePath(archive_root)
    if lfs.attributes(archive_root, "mode") ~= "directory" then
        error("Cannot create CRAM recovery archive")
    end
    local stem = os.date("%Y%m%d-%H%M%S")
    local backup_dir, stage
    for index = 1, 100 do
        local unique = stem .. "-" .. tostring(index)
        local candidate = archive_root .. "/" .. unique
        local staging = dir .. "/.cram-reset-stage-" .. unique .. ".lua"
        if not lfs.attributes(candidate, "mode")
                and not lfs.attributes(staging, "mode")
                and not lfs.attributes(staging .. ".old", "mode") then
            backup_dir, stage = candidate, staging
            break
        end
    end
    if not backup_dir then error("Cannot reserve a unique CRAM recovery archive") end
    -- Prepare and verify the fresh checkpoint BEFORE touching the original.
    local replacement = LuaSettings:open(stage)
    replacement:saveSetting("snapshots", {})
    replacement:saveSetting("sequence", 1)
    replacement:flush()
    local verify_stage = LuaSettings:open(stage)
    local snapshots = verify_stage:readSetting("snapshots")
    if type(snapshots) ~= "table" or next(snapshots)
            or verify_stage:readSetting("sequence") ~= 1
            or lfs.attributes(stage, "mode") ~= "file" then
        error("New CRAM checkpoint failed verification; original untouched")
    end
    util.makePath(backup_dir)
    if lfs.attributes(backup_dir, "mode") ~= "directory" then
        error("Cannot prepare CRAM backup; original untouched")
    end
    local function copyVerified(src, dst)
        local input, reason = io.open(src, "rb")
        if not input then error("Cannot open original CRAM file: " .. tostring(reason)) end
        local output, out_reason = io.open(dst, "wb")
        if not output then input:close(); error("Cannot back up CRAM: " .. tostring(out_reason)) end
        local done, write_err = pcall(function()
            while true do
                local chunk = input:read(32768)
                if not chunk then break end
                local wrote, why = output:write(chunk)
                if not wrote then error("Backup write failed: " .. tostring(why)) end
            end
            assert(output:flush(), "CRAM backup flush failed")
        end)
        input:close()
        output:close()
        if not done then error(write_err) end
        local orig, copied = assert(io.open(src, "rb")), assert(io.open(dst, "rb"))
        local matches = true
        while true do
            local a, b = orig:read(32768), copied:read(32768)
            if a ~= b then matches = false; break end
            if not a then break end
        end
        orig:close(); copied:close()
        if not matches then error("CRAM backup did not match original") end
    end
    local had_main = lfs.attributes(file, "mode") == "file"
    local had_old = lfs.attributes(old, "mode") == "file"
    if had_main then copyVerified(file, backup_dir .. "/cram_progress.lua") end
    if had_old then copyVerified(old, backup_dir .. "/cram_progress.lua.old") end

    -- Android/Kindle use POSIX rename: replacing the main checkpoint in the
    -- SAME directory is atomic. Never remove/move the main file first.
    -- Move .old aside so a later fallback cannot resurrect stale progress.
    local moved_old = false
    if had_old then
        local moved, why = os.rename(old, backup_dir .. "/archived-old-original")
        if not moved then error("Could not isolate old CRAM backup: " .. tostring(why)) end
        moved_old = true
    end
    local moved, why = os.rename(stage, file)
    if not moved then
        if moved_old then os.rename(backup_dir .. "/archived-old-original", old) end
        error("Could not atomically install fresh CRAM checkpoint: " .. tostring(why))
    end
    local opened, result = pcall(Store.open)
    if not opened or next(result.snapshots) or result.sequence ~= 1 then
        -- The verified original copy can replace the new file atomically.
        -- Preserve the failed replacement for diagnosis.
        os.rename(file, backup_dir .. "/failed-replacement.lua")
        local restored = not had_main or os.rename(backup_dir .. "/cram_progress.lua", file)
        if moved_old then os.rename(backup_dir .. "/archived-old-original", old) end
        if not restored then error("Urgent: old CRAM checkpoint is in the backup directory") end
        error("Fresh CRAM checkpoint failed to reopen; original recovered")
    end
    return result, backup_dir
end

return Store
