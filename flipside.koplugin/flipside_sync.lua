-- FlipSide: serialized Cloud sync for cards, CRAM, Learning Analysis and dictionary locks.
-- This module neither changes KOReader Cloud Storage nor combines the three
-- independent file formats. Sync All waits for real completion callbacks.
local UIManager = require('ui/uimanager')
local InfoMessage = require('ui/widget/infomessage')
local logger = require('logger')
local Diag = require('flipside_diagnostics')
local util = require('util')
local SQL = require('lua-ljsqlite3/init')
local Device = require('device')
local DB = require('flipside_db')
local Compare = require('lib.sync.flipside_sync_utils')
local M = { running = false, blocked = false }
local STAGE_TIMEOUT = 300 -- abort whole sequence on timeout; never overlap transfers

local names = {cards='Flashcards', cram='CRAM progress', audit='Learning Analysis', calendar='Study calendar', dictionary='Dictionary positions',meanings='Saved meanings'}
local stages = { 'cards', 'cram', 'audit', 'calendar', 'dictionary', 'meanings' }

local function message(msg)
    -- Never open a popup over the Kindle cover/sleep screen.
    if Device.screen_saver_mode then
        logger.info('FlipSide Cloud sync: result available in diagnostics after sleep')
        return
    end
    UIManager:show(InfoMessage:new{ text=msg, timeout=4 })
end

local function getCloud(plugin)
    local cs = plugin and plugin.ui and plugin.ui.cloudstorage
    if cs and type(cs.providers) == 'table' then return cs end
    local ok, loader = pcall(require, 'pluginloader')
    if ok and loader and type(loader.getPluginInstance) == 'function' then
        local good, live = pcall(loader.getPluginInstance, loader, 'cloudstorage')
        if good and live and type(live.providers) == 'table' then return live end
    end
end

local function copyFile(src, dst)
    local input, err = io.open(src, 'rb')
    if not input then return false, err end
    local tmp = dst .. '.copying'
    local output, reason = io.open(tmp, 'wb')
    if not output then input:close(); return false, reason end
    local copied, why = true, nil
    while true do
        local buf = input:read(128 * 1024)
        if not buf then break end
        local ok, e = output:write(buf)
        if not ok then copied, why = false, e; break end
    end
    input:close()
    output:close()
    if not copied then os.remove(tmp); return false, why end
    local ok, e = os.rename(tmp, dst)
    if not ok then os.remove(tmp); return false, e end
    return true
end

local function validRemoteDB(path)
    local ok, valid = pcall(function()
        local conn = SQL.open(path)
        local good, result = pcall(function()
            local check = tostring(conn:rowexec('PRAGMA quick_check;') or '')
            if check ~= 'ok' then return false end
            local tables = tonumber(conn:rowexec([[
                SELECT COUNT(*) FROM sqlite_master
                WHERE type='table' AND name IN ('vocabulary', 'title');
            ]])) or 0
            return tables == 2
        end)
        conn:close()
        return good and result
    end)
    return ok and valid
end

-- SQLite reports checkpoint contention in a RESULT ROW, not necessarily as
-- a Lua error. A successful pcall(exec) alone can therefore export a stale
-- main .sqlite3 file while newer card pages remain in its -wal journal.
-- Only the private FlipSide cards database is checked; no provider settings
-- or Cloud Storage callbacks are changed by this guard.
local function checkpointCards(path)
    local conn = SQL.open(path)
    if not conn then error('Cannot open FlipSide cards database for checkpoint') end
    -- KOReader's rowexec returns busy, WAL frames, checkpointed frames.
    local ok, busy, wal_frames, copied_frames = pcall(conn.rowexec, conn,
        'PRAGMA wal_checkpoint(FULL);')
    local closed, close_err = pcall(conn.close, conn)
    if not ok then error('Cards checkpoint failed: ' .. tostring(busy)) end
    if not closed or close_err == false then
        error('Cannot close checkpoint connection: ' .. tostring(close_err))
    end
    busy = tonumber(busy)
    wal_frames = tonumber(wal_frames)
    copied_frames = tonumber(copied_frames)
    if busy ~= 0 or wal_frames == nil or copied_frames == nil
        or wal_frames < -1 or copied_frames < -1
        or (wal_frames >= 0 and copied_frames ~= wal_frames)
        or (wal_frames == -1 and copied_frames ~= -1) then
        error('Cards checkpoint incomplete or busy; cloud transfer cancelled')
    end
end

-- Use the provider behind Cloud Storage, so the completion callback reflects
-- *actual successful upload* (the stock Cloud:sync() doesn't expose one).
local function syncCards(plugin, done)
    local server = plugin.getFlipSideSyncServer and plugin:getFlipSideSyncServer()
    if not server or not server.type or not server.url then
        done(false, 'Set Flashcards cloud folder in Appearance > Sync settings')
        return
    end
    local cloud = getCloud(plugin)
    local provider = cloud and cloud.providers[server.type]
    if not provider or type(provider.run)~='function'
        or type(provider.downloadFile)~='function' or type(provider.uploadFile)~='function' then
        done(false, 'Enable KOReader Cloud storage and configure this provider')
        return
    end
    local ok, err = pcall(function()
        if plugin.prepareFlipSideSync then plugin:prepareFlipSideSync() end
    end)
    if not ok then
        Diag.report("ERROR", "CLOUD_SYNC_STAGE_FAILED", {stage="cards_prepare"}, err)
        done(false, 'Cannot save pending card edits: ' .. tostring(err)); return
    end

    local db_path = DB.path
    local incoming = db_path .. '.temp'
    -- Separate remote name and sync baseline from the official Vocabulary Builder.
    -- This does not change the configured server, folder or stored credentials.
    local remote_name = 'flipside-cards-v1.sqlite3'
    local cache = db_path .. '.flipside-cards-v1.sync'
    local staged_upload = db_path:match('^(.*/)') .. remote_name
    local remote = server.url:gsub('/+$','') .. '/' .. remote_name
    local backed_up = false
    local function transfer()
        -- KOReader provider calls are synchronous. The UI gets control
        -- BETWEEN stages, never during a provider's blocking network request.
        UIManager:nextTick(function()
            local success, result = pcall(function()
                -- Include pending WAL pages before comparing files. Never
                -- infer equality from only mtime/size or an old local cache.
                checkpointCards(db_path)
                for attempt=1,4 do
                    os.remove(incoming)
                    local status, etag = provider.downloadFile(remote, incoming)
                    local missing = status == 404 or (server.type == 'ftp' and status == 550)
                    if status == 409 and server.type == 'dropbox' then
                        local f = io.open(incoming, 'rb')
                        local body = f and f:read(8192) or ''
                        if f then f:close() end
                        missing = body:match('"error_summary"%s*:%s*"path/not_found') ~= nil
                    end
                    if status ~= 200 and not missing then
                        error('Cloud download failed (HTTP '..tostring(status)..'); no upload attempted')
                    end
                    local remote_same_as_cache = status == 200
                        and Compare.sameFile(incoming, cache)
                    local local_same_as_cache = Compare.sameFile(db_path, cache)
                    -- Record BEFORE DB.onSync: SQLite's merge may modify
                    -- the downloaded income_db, so comparing AFTER the merge
                    -- can falsely claim the cloud has the updated contents.
                    local remote_identical_before_merge = status == 200
                        and Compare.sameFile(db_path, incoming)
                    -- The remote is verified by its previous completed sync
                    -- copy, and the local DB did not change: no merge/upload.
                    -- Even a huge SQLite VACUUM is entirely bypassed.
                    if remote_same_as_cache and local_same_as_cache then
                        os.remove(incoming)
                        Diag.event('sync', 'unchanged', {stage='cards'})
                        return 'Already up to date'
                    end
                    if status == 200 then
                        if not validRemoteDB(incoming) then
                            error('Remote flashcard database is invalid; upload cancelled')
                        end
                        if not remote_identical_before_merge then
                            if not backed_up then
                                local backed, backup_err = copyFile(db_path,
                                    db_path .. '.pre-sync-backup.sqlite3')
                                if not backed then error('Cannot backup local cards before merge: ' .. tostring(backup_err)) end
                                backed_up = true
                            end
                            -- If remote is unchanged and only local changed,
                            -- its data is already in the local DB. Re-running
                            -- the SQLite merge would be wasted work.
                            if not remote_same_as_cache then
                                local merged = DB.onSync(db_path, cache, incoming, {skip_vacuum=true})
                                if not merged then error('Database merge declined; upload cancelled') end
                            end
                        end
                    end
                    -- Merge may have written SQLite WAL pages; checkpoint
                    -- before upload or byte comparison with the remote file.
                    checkpointCards(db_path)
                    -- When local/remote already contain the same bytes, no
                    -- network upload is necessary; still refresh the local
                    -- baseline for future three-way merges.
                    os.remove(incoming)
                    if remote_identical_before_merge then
                        local cached, why = copyFile(db_path, cache)
                        if not cached then error('Cannot refresh sync baseline: '..tostring(why)) end
                        Diag.event('sync', 'unchanged', {stage='cards'})
                        return 'Already up to date'
                    end
                    -- Cloud providers derive the remote basename from the local
                    -- upload path. Stage a private copy: never rename the live DB.
                    local staged, stage_err = copyFile(db_path, staged_upload)
                    if not staged then error('Cannot stage FlipSide cards: ' .. tostring(stage_err)) end
                    local sent, code = pcall(provider.uploadFile, server.url, staged_upload, etag, true)
                    os.remove(staged_upload)
                    if not sent then error('Cloud upload failed: ' .. tostring(code)) end
                    if type(code)=='number' and code>=200 and code<300 then
                        local cache_ok, cache_err = copyFile(db_path, cache)
                        if not cache_ok then
                            logger.warn('FlipSide: sync succeeded but local cache copy failed: ' .. tostring(cache_err))
                            Diag.report('WARNING', 'CLOUD_SYNC_CACHE_FAILED', {stage='cards'}, cache_err)
                        end
                        return status == 200 and 'Changes sent and received' or 'Uploaded'
                    end
                    if code ~= 412 then
                        error('Cloud upload failed (HTTP '..tostring(code)..')')
                    end
                end
                error('Remote changed repeatedly (HTTP 412); retry sync')
            end)
            os.remove(incoming)
            os.remove(staged_upload)
            if success then
                done(true, result)
            else
                logger.warn('FlipSide cloud cards:', tostring(result))
                Diag.report('ERROR', 'CLOUD_SYNC_STAGE_FAILED', {stage='cards'}, result)
                done(false, tostring(result))
            end
        end)
    end
    provider.base = util.tableDeepCopy(server)
    local started, reason = pcall(provider.run, transfer)
    if not started then
        Diag.report("ERROR", "CLOUD_SYNC_STAGE_FAILED", {stage="cloud_provider"}, reason)
        done(false, tostring(reason))
    end
end

local function syncAudit(plugin, done)
    local mod = require('flipside_learning_audit')
    if not mod or type(mod.syncNow) ~= 'function' then
        done(false, 'Learning Analysis synchronizer unavailable')
        return
    end
    mod.syncNow(plugin, done)
end

local function syncDictionary(plugin, done)
    local mod = require('flipside_dictionary_locks')
    if not mod or type(mod.syncNow) ~= 'function' then
        done(false, 'Dictionary positions synchronizer unavailable')
        return
    end
    mod.syncNow(plugin.ui, done, true)
end

local function syncMeanings(plugin, done)
    return require('flipside_saved_meanings').syncNow(plugin, done)
end

local operations={cards=syncCards, cram=function(plugin,done)
    require('flipside_cram_cloud').sync(plugin,done)
end, audit=syncAudit, calendar=function(plugin,done)
    require('flipside_calendar_cloud').sync(plugin,done)
end, dictionary=syncDictionary, meanings=syncMeanings}

function M.start(plugin, requested)
    if M.blocked then
        message('FlipSide: a previous cloud transfer timed out. Restart KOReader before trying again, to avoid overlapping unfinished transfers.')
        return true
    end
    if M.running then
        message('FlipSide: synchronization is already in progress.')
        return true
    end
    if not operations[requested] and requested ~= 'all' then
        message('Unknown FlipSide synchronization action.')
        return true
    end
    local queue = requested == 'all' and stages or {requested}
    M.running = true
    Diag.event("sync", "begin", {stage=requested})
    local statuses = {}
    local index = 0
    local complete = false

    local function finish(aborted)
        if complete then return end
        complete=true
        M.running=false
        -- Notify the actual flashcard screen, not the hidden backing list.
        -- Defer drawing until all stages and the result dialog are finished.
        local api = package.loaded["flipside_flashcards_menu_api"]
        if api and api.refreshAfterSync then
            local ok, err = pcall(api.refreshAfterSync, plugin)
            if not ok then logger.warn("FlipSide: live sync refresh:", err) end
        end
        local passed, failed, broken = 0, 0, {}
        for _, kind in ipairs(queue) do
            local r = statuses[kind]
            if r and r.ok then
                passed = passed + 1
            else
                failed = failed + 1
                local compact = ({audit='Stats',calendar='Calendar',dictionary='Dictionary',meanings='Meanings',cards='Cards',cram='CRAM'})[kind]
                broken[#broken + 1] = compact
                -- Detailed error stays in the diagnostic log, not the UI.
                if not r then
                    Diag.report('WARNING','CLOUD_SYNC_STAGE_NOT_RUN',{stage=kind},'Sync interrupted before this stage')
                end
            end
        end
        local line = string.format('Cloud sync: %d/%d complete', passed, #queue)
        if failed > 0 then line = line .. '\nFailed: ' .. table.concat(broken, ', ') end
        message(line)
    end

    local function nextStage()
        if complete then return end
        if Device.screen_saver_mode then
            -- Complete the current network operation, but do not begin
            -- another potentially blocking stage while Kindle is asleep.
            Diag.event('sync', 'stopped_for_sleep', {stage=requested})
            finish(true)
            return
        end
        index=index+1
        local kind=queue[index]
        if not kind then finish(false); return end
        local completed=false
        Diag.event("sync", "stage_started", {stage=kind, stage_index=index})
        local timeout
        local function done(ok, detail)
            if completed or complete then return end
            completed=true
            if timeout then UIManager:unschedule(timeout) end
            statuses[kind]={ok=ok == true, detail=tostring(detail or (ok and 'Complete' or 'Unknown error'))}
            Diag.event("sync", "stage_finished", {stage=kind, status=ok and "ok" or "failed"})
            if ok ~= true then
                Diag.report("ERROR", "CLOUD_SYNC_STAGE_FAILED", {stage=kind}, detail)
            end
            UIManager:nextTick(nextStage)
        end
        timeout=function()
            if completed or complete then return end
            completed=true
            M.blocked = true
            statuses[kind]={ok=false,detail='Timed out; restart KOReader before retrying'}
            Diag.report("CRITICAL", "CLOUD_SYNC_TIMEOUT", {stage=kind}, "Sync callback exceeded five minutes")
            -- Never start the next transfer when an old one might still run.
            finish(true)
        end
        UIManager:scheduleIn(STAGE_TIMEOUT,timeout)
        local ok, err = pcall(operations[kind], plugin, done)
        if not ok then done(false,tostring(err)) end
    end
    UIManager:nextTick(nextStage)
    return true
end

return M
