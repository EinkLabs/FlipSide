-- FlipSide study-calendar cloud exchange: study-day evidence ONLY.
-- No modifications to activity_events, activity_days, streak observations,
-- review statistics, the SRS database or the existing Learning Analysis exchange.
-- Calendar has its own optional cloud folder setting. Existing installations
-- keep using the Statistics folder until a Calendar folder is selected.
-- Credentials always stay with the official KOReader Cloud storage plugin.
local UIManager=require('ui/uimanager')
local DataStorage=require('datastorage')
local LuaSettings=require('luasettings')
local util=require('util')
local rapidjson=require('rapidjson')
local SQL=require('lua-ljsqlite3/init')
local lfs=require('libs/libkoreader-lfs')
local logger=require('logger')
local Diag=require('flipside_diagnostics')
local Merge=require('lib.sync.flipside_calendar_merge')
local Compare=require('lib.sync.flipside_sync_utils')
local M={}
local DIR=DataStorage:getSettingsDir()..'/flipside'
local ACTIVITY=DIR..'/vocabulary_builder_activity.sqlite3'
local REMOTE_NAME='flipside_calendar_days_v1.json'
local CACHE=DIR..'/flipside_calendar_sync_cache_v1.json'
local IDENTITY=DIR..'/flipside_calendar_sync_identity_v1.lua'
local CLOUD_SETTINGS=DIR..'/flipside_calendar_cloud_settings.lua'
local STAGING=DIR..'/'..REMOTE_NAME
local INCOMING=STAGING..'.incoming'
local MAX_BYTES=2*1024*1024

local function readFile(path)
    local f=io.open(path,'rb')
    if not f then return nil end
    local data=f:read(MAX_BYTES+1)
    f:close()
    if not data or #data==0 or #data>MAX_BYTES then error('Calendar cloud file is empty or too large') end
    return data
end
local function decode(path)
    local bytes=readFile(path)
    if not bytes then return nil end
    local raw,err=rapidjson.decode(bytes)
    if not raw then error('Calendar JSON cannot be parsed: '..tostring(err)) end
    return Merge.normalize(raw)
end
local function encode(data)
    local content,err=rapidjson.encode(Merge.normalize(data))
    if not content or #content>MAX_BYTES then error('Calendar JSON exceeds size limit: '..tostring(err)) end
    return content
end
local function atomicWrite(path,contents)
    local temp=path..'.writing'
    local f,err=io.open(temp,'wb')
    if not f then error('Calendar sync cannot open temporary file: '..tostring(err)) end
    local saved,e=f:write(contents)
    local flushed,fe=f:flush()
    local closed,ce=f:close()
    if not saved or not flushed or not closed then
        os.remove(temp)
        error('Calendar sync write failed: '..tostring(e or fe or ce))
    end
    local ok,reason=os.rename(temp,path)
    if not ok then os.remove(temp);error('Calendar sync atomic rename failed: '..tostring(reason)) end
end

local function deviceId()
    util.makePath(DIR)
    local store=LuaSettings:open(IDENTITY)
    local id=store:readSetting('device_id')
    if type(id)=='string' and #id>=8 and #id<=100 and id:match('^[%w%-]+$') then return id end
    local random=io.open('/dev/urandom','rb')
    local bytes=random and random:read(16)
    if random then random:close() end
    if type(bytes)=='string' and #bytes==16 then
        id='fs-'..bytes:gsub('.',function(c)return string.format('%02x',c:byte()) end)
    else
        -- /dev/urandom is present on Android/Kindle Linux; fail closed if it
        -- is unavailable rather than risk two devices sharing a record ID.
        error('Calendar sync cannot generate a safe device ID')
    end
    store:saveSetting('device_id',id)
    store:flush()
    local verified=LuaSettings:open(IDENTITY):readSetting('device_id')
    if verified~=id then error('Calendar device identity was not saved') end
    return id
end

local function localDays()
    -- Flush pending study activity before making the read-only cloud snapshot.
    local bridge=package.loaded['flipside_stats_bridge']
    if type(bridge)=='table' and type(bridge.flush)=='function' then
        if bridge.flush()==false then error('Pending activity could not be flushed; no upload') end
    end
    if lfs.attributes(ACTIVITY,'mode')~='file' then
        -- Fresh installations may have no activity DB. Never treat a missing
        -- previously-present DB as deletion of a whole device history.
        return nil
    end
    local db,rows
    local ok,err=pcall(function()
        db=SQL.open(ACTIVITY,'ro')
        if not db then error('Cannot open calendar activity database') end
        db:exec('PRAGMA busy_timeout=1000;')
        local schema=db:exec("SELECT name FROM sqlite_master WHERE type='table' AND name='activity_days';")
        if not schema or not schema.name or not schema.name[1] then
            error('Calendar activity_days table is unavailable')
        end
        rows=db:exec('SELECT day_key, source FROM activity_days;')
    end)
    if db then pcall(db.close,db) end
    if not ok then error('Cannot read calendar days: '..tostring(err)) end
    local days={}
    if rows and rows.day_key then
        for i,key in ipairs(rows.day_key) do
            local source=rows.source and rows.source[i]
            if source=='recorded' or source=='estimated_legacy' then
                days[key]=source
            else
                error('Calendar contains unsupported day evidence; upload cancelled')
            end
        end
    end
    return Merge.normalizeDays(days)
end

local function missingRemote(status,type_,path)
    if status==404 or (type_=='ftp' and status==550) then return true end
    if type_=='dropbox' and status==409 then
        local f=io.open(path,'rb')
        local body=f and f:read(8192) or ''
        if f then f:close() end
        return body:match('"error_summary"%s*:%s*"path/not_found')~=nil
    end
    return false
end

-- Calendar reads only this verified local cache; original statistics remain local.
function M.syncedDays()
    local id=deviceId()
    local data=decode(CACHE)
    if not data then return {} end
    return Merge.remoteDays(data,id)
end

-- The dedicated Calendar selection contains only an account reference/path;
-- it never stores cloud passwords or changes the Statistics selection.
function M.getFolder()
    local selection=LuaSettings:open(CLOUD_SETTINGS):readSetting('selected_folder')
    if type(selection)=='table' and type(selection.type)=='string'
        and type(selection.url)=='string' then
        return selection
    end
    return nil
end

function M.chooseFolder(plugin,completion)
    local audit=require('flipside_learning_audit')
    local cs,issue=audit.getCloudService(plugin)
    if not cs then
        if completion then completion(false,issue) end
        return false
    end
    cs:onShowCloudStorageList(function(chosen)
        if type(chosen)~='table' or type(chosen.type)~='string'
            or type(chosen.url)~='string' then
            if completion then completion(false,'No folder selected') end
            return
        end
        local selection={
            type=chosen.type,name=chosen.name,address=chosen.address,
            username=chosen.username,url=chosen.url,
        }
        local ok,err=pcall(function()
            util.makePath(DIR)
            local settings=LuaSettings:open(CLOUD_SETTINGS)
            settings:saveSetting('selected_folder',selection)
            settings:flush()
        end)
        if completion then completion(ok,ok and selection or err) end
    end)
    return true
end

function M.sync(plugin,done)
    local audit=require('flipside_learning_audit')
    local selected=M.getFolder()
    local cs,server,issue
    if selected then
        cs,server,issue=audit.getCloudTransport(plugin,selected,true)
    else
        -- Backward compatible: never invalidate an existing cloud setup.
        cs,server,issue=audit.getCloudTransport(plugin)
    end
    if not server then done(false,issue or 'Calendar cloud folder not configured');return end
    local provider=cs.providers and cs.providers[server.type]
    if not provider or type(provider.run)~='function'
            or type(provider.downloadFile)~='function'
            or type(provider.uploadFile)~='function' then
        done(false,'Calendar cloud provider unavailable');return
    end
    provider.base=util.tableDeepCopy(server)
    local started,reason=pcall(provider.run,function()
        UIManager:nextTick(function()
            local ok,result=pcall(function()
                util.makePath(DIR)
                local id=deviceId()
                local cache=decode(CACHE) or Merge.empty()
                local days=localDays()
                if not days and cache.nodes[id] then
                    error('Local calendar database missing; remote calendar not modified')
                end
                local local_copy=Merge.updateOwn(cache,id,days or {})
                local endpoint=server.url:gsub('/+$','')..'/'..REMOTE_NAME
                for attempt=1,4 do
                    os.remove(INCOMING)
                    local code,etag=provider.downloadFile(endpoint,INCOMING)
                    local remote
                    if code==200 then
                        remote=decode(INCOMING)
                        if not remote then error('Cloud calendar returned empty HTTP 200') end
                    elseif missingRemote(code,server.type,INCOMING) then
                        remote=Merge.empty()
                    else
                        error('Calendar cloud download failed (HTTP '..tostring(code)..')')
                    end
                    os.remove(INCOMING)
                    -- A newer revision on another device can include deletions
                    -- (Undo); never make it permanent merely by unioning dates.
                    local merged=Merge.merge(local_copy,remote)
                    local unchanged=Compare.sameData(merged,remote)
                    if not unchanged then
                        atomicWrite(STAGING,encode(merged))
                        local uploaded=provider.uploadFile(server.url,STAGING,etag,true)
                        if type(uploaded)=='number' and uploaded>=200 and uploaded<300 then
                            atomicWrite(CACHE,encode(merged))
                            return 'Calendar dates sent and received'
                        end
                        if uploaded~=412 then
                            error('Calendar upload failed (HTTP '..tostring(uploaded)..')')
                        end
                    else
                        -- Same remote snapshot: refresh only our private cache.
                        if not Compare.sameData(cache,merged) then atomicWrite(CACHE,encode(merged)) end
                        return 'Calendar dates up to date'
                    end
                    if attempt==4 then error('Calendar changed remotely 4 times; retry') end
                end
            end)
            os.remove(INCOMING)
            os.remove(STAGING)
            if ok then
                Diag.event('sync','calendar_done',{stage='calendar',status='ok'})
                done(true,result)
            else
                logger.warn('FlipSide calendar sync:',tostring(result))
                Diag.report('ERROR','CLOUD_SYNC_STAGE_FAILED',{stage='calendar'},result)
                done(false,tostring(result))
            end
        end)
    end)
    if not started then done(false,'Cannot start calendar provider: '..tostring(reason)) end
end
return M
