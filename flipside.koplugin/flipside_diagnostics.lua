-- FlipSide Diagnostics v1: lightweight, always-on failure reports.
-- Purely observational. Never modifies review, audit, sync or CRAM data.
-- All disk writes are contained in protected calls and occur ONLY on alerts.
local Diagnostics = {}
local logger = require("logger")
local DataStorage = require("datastorage")
local util = require("util")
local MAX_BYTES = 128 * 1024
local KEEP_BACKUPS = 2
local HISTORY_MAX = 16
local history, recent = {}, {}
local writing, storage_warning_sent = false, false
local file_path

local definitions = {
    PLUGIN_LOAD_FAILED = {"A FlipSide module failed to load.", "The plugin may not open.", "Check the named module and disable incompatible older patches."},
    CRAM_STORE_OPEN_FAILED = {"The saved CRAM progress could not be opened or verified.", "CRAM is unavailable; the previous file must not be overwritten.", "Back up cram_progress.lua and inspect its readable copy and .old backup."},
    CRAM_CHECKPOINT_FAILED = {"The CRAM checkpoint could not be verified after saving.", "Recent training progress may not be durable.", "Keep KOReader open; check storage space and permissions."},
    CRAM_CATALOG_UNAVAILABLE = {"The complete flashcard catalog could not be loaded.", "CRAM is paused to avoid discarding saved words.", "Check database availability and reopen the collection."},
    CRAM_MISS_NOT_SAVED = {"A missed card could not be saved to both CRAM queues.", "The normal review or Practice answer may be saved without CRAM progress.", "Inspect the checkpoint error; do not delete saved settings."},
    CRAM_QUEUE_INCONSISTENT = {"Saved CRAM queue has missing, repeated, or invalid entries.", "Restoring the queue may omit a word or progress.", "Back up the original cram_progress.lua and its .old file before changing anything."},
    CRAM_COUNTER_UNAVAILABLE = {"CRAM counts cannot be calculated from current storage/catalog.", "A dash may appear instead of a number.", "Confirm a full catalog and readable CRAM progress file."},
    CRAM_TRAINING_COUNTER_FAILED = {"Independent CRAM training statistics did not save.", "The training queue may be safe but attempt counts could differ.", "Check settings write permissions."},
    CRAM_UNDO_FAILED = {"Undo could not restore a CRAM queue checkpoint.", "CRAM may contain a stale missed word; the native Undo is independent.", "Retain the checkpoint and logs for recovery."},
    CRAM_PREFERENCE_FAILED = {"CRAM mode or placement could not be saved.", "The new option may not persist after restart.", "Check settings storage and retry."},
    SRS_ANSWER_FAILED = {"The native answer handler did not commit the review.", "This review should not be counted as saved.", "Check the Vocabulary Builder database and native handler error."},
    SRS_COMMIT_UNVERIFIED = {"A submitted review could not be verified for Undo.", "The answer may have committed but Undo metadata is incomplete.", "Inspect the native SQLite review row; do not resubmit blindly."},
    LEARNING_AUDIT_ERROR = {"Learning Analysis did not confirm a review event.", "The SRS review may be saved without matching accuracy history.", "Check the audit event journal and database."},
    LEARNING_AUDIT_DB_FAILED = {"A Learning Analysis database operation raised an error.", "History or statistics may be incomplete until repaired.", "Inspect SQLite error and journal; keep all existing databases."},
    LEARNING_AUDIT_CACHE_FAILED = {"The accuracy cache tracking trigger could not be prepared.", "Accuracy may need a slower fallback query.", "Inspect the SQL engine error; do not clear the database."},
    UNDO_SRS_FAILED = {"Native Undo could not safely restore the review.", "The review is not confirmed restored.", "Inspect the original answer and current SQLite row."},
    UNDO_STATS_PENDING = {"Native Undo completed, but statistics correction did not.", "Learning Analysis or Activity Stats still needs a safe retry.", "Keep undo_statistics_recovery.lua and inspect the exact error."},
    UNDO_JOURNAL_FAILED = {"Protected Undo recovery journal could not be opened or saved.", "Automatic repair of statistics may not be durable.", "Back up the journal and its .old file; check storage."},
    UNDO_REPLAY_INCOMPLETE = {"A pending Undo statistics correction could not be replayed.", "An older accuracy entry may remain pending.", "Inspect Learning Analysis and the recovery journal."},
    UNDO_DUAL_HISTORY_FAILED = {"Adaptive Retrieval statistics did not revert with Undo.", "Model-specific accuracy may be inconsistent.", "Inspect the retrieval-history settings file."},
    CLOUD_SYNC_STAGE_FAILED = {"A Cloud Sync stage failed.", "The related component might not be synchronized.", "Review stage result and retry only after the previous transfer ends."},
    CLOUD_SYNC_TIMEOUT = {"A Cloud Sync stage did not complete before the timeout.", "New transfers are blocked to avoid overlapping writes.", "Restart KOReader before another sync."},
    CLOUD_SYNC_CACHE_FAILED = {"Cloud upload succeeded but the local sync cache copy failed.", "A later sync may need to recompare remote and local files.", "Check free storage, backup and local cache."},
    CLOUD_SYNC_RELOAD_FAILED = {"Sync finished but the visible card list could not refresh.", "The display may show stale words until reopening.", "Reopen the Flashcards view."},
    APP_UI_ERROR = {"A FlipSide UI operation failed.", "This screen might not update correctly.", "Check the recorded function and traceback."},
}

-- Only non-identifying state fields are accepted. Never accept word, book,
-- sentence, account, URL, filename or cloud credentials from the caller.
local allowed = {
    mode=true, timing=true, stage=true, practice=true, retry=true,
    queue=true, pending=true, count=true, status=true, has_catalog=true,
    journal=true, native_saved=true, stats_saved=true, attempt=true,
    answer=true, version=true, result=true, stage_index=true,
}
local function cleanValue(value)
    if type(value) == "boolean" then return tostring(value) end
    if type(value) == "number" then
        if value ~= value then return "invalid-number" end
        return tostring(value)
    end
    if type(value) == "string" then
        -- Values are deliberately short enumeration-like tokens, not raw data.
        if #value > 40 or not value:match("^[%w_%- ]+$") then return "[private]" end
        return value
    end
    return "[omitted]"
end
local function safeContext(ctx)
    local items = {}
    if type(ctx) ~= "table" then return "none" end
    for key in pairs(allowed) do
        if ctx[key] ~= nil then
            items[#items + 1] = key .. "=" .. cleanValue(ctx[key])
        end
    end
    table.sort(items)
    return #items > 0 and table.concat(items, ", ") or "none"
end
local function scrub(text)
    text = tostring(text or "unspecified error")
    -- Keep function names and line numbers, but not personal paths, URLs,
    -- credentials or content from books/SQLite values.
    text = text:gsub("[%a][%w+.-]*://[^%s]+", "[private-url]")
    text = text:gsub("([Pp]assword%s*[:=]%s*)[^,%s;]+", "%1[redacted]")
    text = text:gsub("([Tt]oken%s*[:=]%s*)[^,%s;]+", "%1[redacted]")
    text = text:gsub("([Aa]uthorization%s*[:=]%s*)[^,%s;]+", "%1[redacted]")
    text = text:gsub("([Uu]sername%s*[:=]%s*)[^,%s;]+", "%1[redacted]")
    text = text:gsub("([Ww]ord%s*[:=]%s*)[^,%s;]+", "%1[private]")
    text = text:gsub("([Bb]ook%s*[:=]%s*)[^,%s;]+", "%1[private]")
    text = text:gsub("'[^'\n]+'", "'[private-text]'")
    text = text:gsub('"[^"\n]+"', '"[private-text]"')
    text = text:gsub("[/\\][%w_ %-%./\\]+[/\\]([%w_.%-]+%.lua)", "[path]/%1")
    -- Keep a bounded amount of diagnostic context on e-ink devices.
    return text:sub(1, 2400)
end
local function addHistory(area, action, ctx)
    history[#history + 1] = string.format("%s %-12s %-23s %s",
        os.date("%H:%M:%S"), tostring(area):sub(1, 12),
        tostring(action):sub(1, 23), safeContext(ctx))
    if #history > HISTORY_MAX then table.remove(history, 1) end
end
function Diagnostics.event(area, action, ctx)
    -- In RAM only: there is no flash write for a normal answer or redraw.
    local ok = pcall(addHistory, area, action, ctx)
    return ok
end
local function logPath()
    if file_path then return file_path end
    local dir = DataStorage:getSettingsDir() .. "/flipside"
    util.makePath(dir)
    file_path = dir .. "/diagnostics.log"
    return file_path
end
local function rotate(path)
    local f = io.open(path, "rb")
    if not f then return end
    local bytes = f:seek("end") or 0
    f:close()
    if bytes < MAX_BYTES then return end
    os.remove(path .. "." .. KEEP_BACKUPS)
    for i = KEEP_BACKUPS - 1, 1, -1 do
        os.rename(path .. "." .. i, path .. "." .. (i + 1))
    end
    local moved, err = os.rename(path, path .. ".1")
    if not moved then error("log rotation failed: " .. tostring(err)) end
end
local function writeRecord(record)
    local path = logPath()
    rotate(path)
    local out, err = io.open(path, "ab")
    if not out then error("diagnostic file cannot be opened: " .. tostring(err)) end
    local wrote, reason = out:write(record)
    local flushed, flusherr = out:flush()
    local closed, closeerr = out:close()
    if not wrote or not flushed or not closed then
        error("diagnostic write failed: " .. tostring(reason or flusherr or closeerr))
    end
end
function Diagnostics.report(level, code, ctx, detail)
    if writing then return false end
    writing = true
    local ok, result = pcall(function()
        local now = os.time()
        local severity = level == "CRITICAL" and "CRITICAL"
            or level == "ERROR" and "ERROR" or "WARNING"
        code = type(code) == "string" and code or "UNKNOWN"
        if not code:match("^[A-Z0-9_]+$") then code = "UNKNOWN" end
        local rate_key = severity .. ":" .. code
        if recent[rate_key] and now - recent[rate_key] < 10 then
            return false -- bound repeated errors and flash writes
        end
        recent[rate_key] = now
        local entry = definitions[code]
            or {"The operation failed; the exact cause is not verified.",
                "A FlipSide function may be unavailable.", "Inspect the error and source line."}
        local lines = {
            "=== FLIPSIDE DIAGNOSTIC v1 ===",
            "Time: " .. os.date("%Y-%m-%d %H:%M:%S", now),
            "Level: " .. severity,
            "Code: " .. code,
            "Observed: " .. entry[1],
            "Impact: " .. entry[2],
            "Suggested check: " .. entry[3],
            "State: " .. safeContext(ctx),
            "Runtime detail (sanitized): " .. scrub(detail),
            "Call location (may be a catch point, not the root cause):",
            scrub(debug and debug.traceback and debug.traceback("", 3) or "No Lua traceback available"),
            "Recent FlipSide operations (no card text):",
        }
        for _, event in ipairs(history) do lines[#lines + 1] = event end
        lines[#lines+1] = "=== END FLIPSIDE DIAGNOSTIC ===\n\n"
        local record = table.concat(lines, "\n")
        writeRecord(record)
        -- Link to the same error code in KOReader crash.log.
        if severity == "CRITICAL" or severity == "ERROR" then
            logger.err("FlipSide diagnostics: " .. code .. " (see settings/flipside/diagnostics.log)")
        else
            logger.warn("FlipSide diagnostics: " .. code .. " (see settings/flipside/diagnostics.log)")
        end
        return true
    end)
    writing = false
    if not ok then
        if not storage_warning_sent then
            storage_warning_sent = true
            pcall(logger.err, "FlipSide diagnostics: log storage unavailable (diagnostic report could not be written)")
        end
        return false
    end
    return result
end
-- Sleep/wake trace: disk writes are limited to lifecycle edges and a bounded
-- number of suspicious redraw requests. Not a per-frame logger.
-- A separate record type avoids claiming that every native screensaver
-- refresh is an error. Records include only code location / window classes.
function Diagnostics.sleepEvent(code, state, detail)
    if writing then return false end
    writing = true
    local ok = pcall(function()
        code = type(code) == "string" and code:upper() or "SLEEP_EVENT"
        if not code:match("^[A-Z0-9_]+$") then code = "SLEEP_EVENT" end
        local record = table.concat({
            "=== FLIPSIDE SLEEP TRACE v2 ===",
            "Time: " .. os.date("%Y-%m-%d %H:%M:%S"),
            "Event: " .. code,
            "State: " .. scrub(state),
            "Origin / detail: " .. scrub(detail),
            "=== END SLEEP TRACE ===\n\n",
        }, "\n")
        writeRecord(record)
        -- In addition to the dedicated trace, make suspicious FlipSide
        -- redraws discoverable in KOReader's own crash/verbose logs.
        if code == "FLIPSIDE_DIRTY_WHILE_SLEEP"
                or code == "FLIPSIDE_DRAW_BLOCKED"
                or code == "FLIPSIDE_WINDOW_SHOWN_DURING_SLEEP" then
            pcall(logger.warn, "FlipSide sleep trace: " .. code
                .. " (see settings/flipside/diagnostics.log)")
        end
    end)
    writing = false
    return ok
end

-- Read-only integrity check. Never repairs a queue, never writes to the
-- CRAM checkpoint, never includes words in the report. Called on startup.
function Diagnostics.inspectCramSnapshots(snapshots)
    if type(snapshots) ~= "table" then return false end
    local bad, inspected = 0, 0
    for key, snapshot in pairs(snapshots) do
        if inspected >= 120 then break end -- hard cap on corrupt files
        inspected = inspected + 1
        local seen = {}
        if type(key) ~= "string" or type(snapshot) ~= "table"
                or snapshot.version ~= 1 or type(snapshot.queue) ~= "table"
                or type(snapshot.completed) ~= "table" then
            bad = bad + 1
        else
            for _, field in ipairs({"queue", "completed"}) do
                local entries = snapshot[field]
                local max = math.min(#entries, 2500)
                for i = 1, max do
                    local entry = entries[i]
                    if type(entry) ~= "table" or type(entry.word) ~= "string"
                            or entry.word == "" or seen[entry.word] then
                        bad = bad + 1
                    else
                        seen[entry.word] = true
                        if field == "queue" and (type(entry.streak) ~= "number"
                                or entry.streak < 0) then bad = bad + 1 end
                    end
                end
            end
        end
    end
    if bad > 0 then
        Diagnostics.report("ERROR", "CRAM_QUEUE_INCONSISTENT",
            {stage="store_open", count=bad},
            "Read-only queue validation found invalid or duplicate entries")
    end
    return bad == 0
end
function Diagnostics.path()
    -- Read-only path helper; no file is created until there is a problem.
    local ok, result = pcall(logPath)
    return ok and result or nil
end
return Diagnostics
