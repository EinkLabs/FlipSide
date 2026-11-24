-- FlipSide CRAM Cloud Sync.
-- Uploads an independent JSON checkpoint, never the native LuaSettings file.
-- Downloaded JSON is data-only: never execute a remote Lua file.
local UIManager = require('ui/uimanager')
local logger = require('logger')
local DataStorage = require('datastorage')
local util = require('util')
local rapidjson = require('rapidjson')
local CramStore = require('flipside_cram_store')
local Merge = require('lib.sync.flipside_cram_merge')
local Diag = require('flipside_diagnostics')
local Compare = require('lib.sync.flipside_sync_utils')
local M = {}
local FILE_NAME = 'flipside_cram_progress.json'
local FORMAT = 'FlipSide-CRAM-Cloud-v1'
local STATS_KEY = 'flipside_intensive_training_stats_v1'
local MAX_BYTES = 4 * 1024 * 1024
local function basename(path) return path:match('[^/]+$') end
local function folderFingerprint(server)
    local input=tostring(server.type or '')..'|'..tostring(server.url or '')
        ..'|'..tostring(server.address or '')
    local h1,h2=0,7
    for i=1,#input do
        local byte=input:byte(i)
        h1=(h1*131+byte)%2147483647
        h2=(h2*257+byte)%2147483629
    end
    return string.format('%08x%08x',h1,h2)
end
local function getCloud(plugin)
    local cs=plugin and plugin.ui and plugin.ui.cloudstorage
    if cs and type(cs.providers)=='table' then return cs end
    local ok,loader=pcall(require,'pluginloader')
    if ok and loader and type(loader.getPluginInstance)=='function' then
        local fine,live=pcall(loader.getPluginInstance,loader,'cloudstorage')
        if fine and live and type(live.providers)=='table' then return live end
    end
    -- KOReader often enables Cloud Storage in the file manager rather than
    -- ReaderUI. Reuse its already-enabled class as a transport adapter; do
    -- not initialize another plugin or alter CRAM's selected cloud folder.
    if ok and type(loader)=='table' then
        for _,module in ipairs(loader.enabled_plugins or {}) do
            if module.name=='cloudstorage' and type(module.getProviders)=='function'
                    and type(module.loadSettings)=='function'
                    and type(module.path)=='string' then
                local adapter=setmetatable({path=module.path},{__index=module})
                local ready=pcall(function()
                    adapter:getProviders()
                    adapter:loadSettings()
                end)
                if ready and type(adapter.providers)=='table' then return adapter end
            end
        end
    end
end
local function missingRemote(status,type_,path)
    if status == 404 or (type_=='ftp' and status==550) then return true end
    if type_=='dropbox' and status==409 then
        local f=io.open(path,'rb'); local data=f and f:read(8192) or ''
        if f then f:close() end
        return data:match('"error_summary"%s*:%s*"path/not_found') ~= nil
    end
    return false
end
local function readFile(path)
    local f,err=io.open(path,'rb')
    if not f then error('Cannot open sync file: '..tostring(err)) end
    local data=f:read(MAX_BYTES + 1)
    f:close()
    if not data or #data == 0 or #data > MAX_BYTES then
        error('CRAM cloud file is empty or too large; no upload attempted')
    end
    return data
end
local function decodeFile(path)
    local data=readFile(path)
    local obj,err=rapidjson.decode(data)
    if type(obj)~='table' or obj.format~=FORMAT or obj.version~=1 then
        error('Remote CRAM format is invalid or unsupported; original cloud file kept: '..tostring(err or 'format'))
    end
    return {format=FORMAT,version=1,
        snapshots=Merge.normalizeSnapshots(obj.snapshots),
        stats=Merge.normalizeStats(obj.stats)}
end
local function encode(data)
    local encoded,err=rapidjson.encode(data)
    if not encoded then error('Cannot encode CRAM cloud data: '..tostring(err)) end
    if #encoded > MAX_BYTES then error('CRAM cloud snapshot exceeds 4 MB; upload stopped') end
    return encoded
end
local function atomicWrite(path, content)
    local temp=path..'.writing'
    local out,err=io.open(temp,'wb')
    if not out then error('Cannot write CRAM cloud file: '..tostring(err)) end
    local written,werr=out:write(content)
    local flushed,ferr=out:flush()
    local closed,cerr=out:close()
    if not written or not flushed or not closed then
        os.remove(temp)
        error('Cannot flush CRAM cloud file: '..tostring(werr or ferr or cerr))
    end
    local ok,reason=os.rename(temp,path)
    if not ok then os.remove(temp);error('Cannot move CRAM cloud file: '..tostring(reason)) end
end
local function backupFile(src,dst)
    local fin=io.open(src,'rb')
    if not fin then return true end -- fresh installation
    local tmp=dst..'.writing'
    local fout,err=io.open(tmp,'wb')
    if not fout then fin:close();error('Cannot create CRAM backup: '..tostring(err)) end
    while true do
        local chunk=fin:read(64*1024)
        if not chunk then break end
        local wrote,reason=fout:write(chunk)
        if not wrote then
            fin:close();fout:close();os.remove(tmp)
            error('CRAM backup failed: '..tostring(reason))
        end
    end
    fin:close()
    local flushed=fout:flush()
    local closed=fout:close()
    if not flushed or not closed then os.remove(tmp);error('CRAM backup could not be flushed') end
    local ok,reason=os.rename(tmp,dst)
    if not ok then os.remove(tmp);error('Cannot finalize CRAM backup: '..tostring(reason)) end
end
local function settings()
    return rawget(_G,'G_reader_settings')
end
local function currentStats()
    local settings_=settings()
    return Merge.normalizeStats(settings_ and settings_:readSetting(STATS_KEY) or {})
end
local function snapshot(store)
    return {format=FORMAT,version=1,
        snapshots=Merge.normalizeSnapshots(store.snapshots),
        stats=currentStats()}
end
local function mergeData(local_,remote,base)
    remote=remote or {snapshots={},stats={}}
    base=base or {snapshots={},stats={}}
    local snaps,conflicts=Merge.merge(local_.snapshots,remote.snapshots,base.snapshots)
    if conflicts > 0 then
        error('CRAM conflict on '..conflicts..' word(s). Local and cloud progress were NOT replaced. Back up both devices; finish training on one device before retrying.')
    end
    return {format=FORMAT,version=1,snapshots=snaps,
        stats=Merge.mergeStats(local_.stats,remote.stats,base.stats)},conflicts
end
local function withProvider(plugin, done)
    local server=plugin and plugin.getFlipSideCramSyncServer and plugin:getFlipSideCramSyncServer()
    if not server or not server.type or not server.url then
        done(false,'Set the FlipSide cloud folder first');return
    end
    local cloud=getCloud(plugin)
    local provider=cloud and cloud.providers[server.type]
    if not provider or type(provider.run)~='function'
            or type(provider.downloadFile)~='function'
            or type(provider.uploadFile)~='function' then
        done(false,'Cloud Storage provider is unavailable');return
    end
    local api=package.loaded["flipside_flashcards_menu_api"]
    local widget=api and api.getActiveFlashcards and api.getActiveFlashcards(plugin)
    if widget and widget.retry_round then
        done(false,'Finish the current CRAM card before syncing; progress was not changed')
        return
    end
    if widget and widget.training and not widget:_persistIntensiveProgress() then
        done(false,'Cannot checkpoint current CRAM progress. No cloud transfer started')
        return
    end
    provider.base=util.tableDeepCopy(server)
    local began,reason=pcall(provider.run,function()
        UIManager:nextTick(function()
            local ok,result=pcall(function()
                local store=(widget and widget._cram_store) or CramStore.open()
                if not store then error('CRAM storage unavailable; nothing was uploaded') end
                local seq=store.sequence
                local function checkDiskSequence()
                    local current=CramStore.open()
                    if current.sequence~=seq then
                        error('CRAM changed in another window during sync; nothing imported. Retry sync.')
                    end
                end
                checkDiskSequence()
                local local_state=snapshot(store)
                local dir=DataStorage:getSettingsDir()..'/flipside'
                util.makePath(dir)
                local staging=dir..'/'..FILE_NAME
                local incoming=staging..'.incoming'
                local base_path=staging..'.base-'..folderFingerprint(server)
                local base
                local bf=io.open(base_path,'rb')
                if bf then
                    bf:close()
                    -- Invalid baseline must not silently cause a destructive merge.
                    base=decodeFile(base_path)
                end
                local remote_url=server.url:gsub('/+$','')..'/'..basename(staging)
                local result_conflicts=0
                local merged
                local upload_skipped = false
                for attempt=1,4 do
                    os.remove(incoming)
                    local status,etag=provider.downloadFile(remote_url,incoming)
                    local remote, effective_base
                    if status==200 then
                        remote=decodeFile(incoming)
                        effective_base=base
                    elseif missingRemote(status,server.type,incoming) then
                        -- A deleted/missing cloud file must NEVER be treated as
                        -- deletion of every previously synced local word.
                        -- Rebuild it from local checkpoints as a new remote.
                        remote={snapshots={},stats={}}
                        effective_base={snapshots={},stats={}}
                    else
                        os.remove(incoming)
                        error('CRAM download failed (HTTP '..tostring(status)..'); no upload attempted')
                    end
                    os.remove(incoming)
                    -- Re-snapshot in case a UI callback advanced a card before
                    -- our network request completed; never upload stale progress.
                    if store.sequence~=seq then
                        error('CRAM changed during cloud transfer; retry to avoid losing progress')
                    end
                    checkDiskSequence()
                    local_state=snapshot(store)
                    merged,result_conflicts=mergeData(local_state,remote,effective_base)
                    -- A download remains necessary to detect changes from
                    -- Android, but an unchanged remote never needs reupload.
                    -- Skip writing a JSON staging file, too.
                    if status == 200 and Compare.sameData(merged,remote) then
                        upload_skipped = true
                        Diag.event('sync','unchanged',{stage='cram'})
                        break
                    end
                    atomicWrite(staging,encode(merged))
                    local code=provider.uploadFile(server.url,staging,etag,true)
                    if type(code)=='number' and code>=200 and code<300 then break end
                    if code~=412 then error('CRAM upload failed (HTTP '..tostring(code)..')') end
                    if attempt==4 then error('CRAM remote file changed repeatedly (HTTP 412); retry') end
                end
                if store.sequence~=seq then
                    error('CRAM changed while uploading. Cloud copy contains prior state; sync again')
                end
                checkDiskSequence()
                -- Remote upload is verified. Preserve a local backup before
                -- importing any remote word, and NEVER touch the SRS database.
                local local_changed = not Compare.sameData(local_state.snapshots,merged.snapshots)
                    or not Compare.sameData(local_state.stats,merged.stats)
                if local_changed then
                    backupFile(store.file,store.file..'.pre-cloud-sync-backup')
                    if not Compare.sameData(local_state.snapshots,merged.snapshots) then
                        store:_commitSnapshots(merged.snapshots)
                    end
                    if not Compare.sameData(local_state.stats,merged.stats) then
                        local g=settings()
                        if g then
                            g:saveSetting(STATS_KEY,merged.stats)
                            g:flush()
                        end
                    end
                end
                -- New common ancestor for the next three-way merge. Do not
                -- needlessly rewrite it for an identical cloud checkpoint.
                local unchanged_base = false
                if base then
                    unchanged_base = Compare.sameData(base.snapshots,merged.snapshots)
                        and Compare.sameData(base.stats,merged.stats)
                end
                if not unchanged_base then atomicWrite(base_path,encode(merged)) end
                -- Rebuild only when actual new CRAM progress was imported.
                if local_changed and widget and widget._cram_store==store then
                    widget.training=nil
                    widget._cram_slot=nil
                    widget:_initializeIntensive()
                end
                if upload_skipped and not local_changed then
                    return 'Already up to date'
                end
                return string.format('%s%s',
                    upload_skipped and 'Progress received' or 'Progress sent and received',
                    result_conflicts>0 and ('; '..result_conflicts..' overlapping changes merged') or '')
            end)
            if ok then
                Diag.event('sync','cram_done',{stage='cram',status='ok'})
                done(true,result)
            else
                logger.warn('FlipSide CRAM cloud sync:',tostring(result))
                Diag.report('ERROR','CLOUD_SYNC_STAGE_FAILED',{stage='cram'},result)
                done(false,tostring(result))
            end
        end)
    end)
    if not began then done(false,'Cannot start CRAM cloud provider: '..tostring(reason)) end
end
function M.sync(plugin,done)
    return withProvider(plugin,done)
end
return M
