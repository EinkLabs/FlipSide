-- Read-only calendar evidence exchange. Never writes Learning Analysis or SRS databases.
-- Each device publishes a replaceable, revisioned set of its observed study days.
-- A removed day (e.g. Undo) can therefore disappear after its device next syncs.
local M = {}
local MAX_DEVICES, MAX_DAYS = 40, 12000
local FORMAT = 'FlipSide-Calendar-Days-v1'
M.FORMAT = FORMAT

local function validDay(key)
    if type(key) ~= 'string' or not key:match('^%d%d%d%d%-%d%d%-%d%d$') then return false end
    local y,m,d = key:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    y,m,d=tonumber(y),tonumber(m),tonumber(d)
    if not y or y<2000 or y>2200 or m<1 or m>12 or d<1 or d>31 then return false end
    local stamp = os.time{year=y,month=m,day=d,hour=12}
    return stamp and os.date('%Y-%m-%d',stamp)==key
end
M.validDay = validDay

function M.normalizeDays(days)
    if type(days)~='table' then error('Invalid calendar day map') end
    local out,n={},0
    for key,source in pairs(days) do
        n=n+1
        if n>MAX_DAYS or not validDay(key)
                or (source~='recorded' and source~='estimated_legacy') then
            error('Invalid calendar study day')
        end
        out[key]=source
    end
    return out
end

function M.empty()
    return {format=FORMAT,version=1,nodes={}}
end

function M.normalize(input)
    if type(input)~='table' or input.format~=FORMAT or input.version~=1
            or type(input.nodes)~='table' then error('Invalid calendar cloud format') end
    local out,n=M.empty(),0
    for id,record in pairs(input.nodes) do
        n=n+1
        if n>MAX_DEVICES or type(id)~='string' or not id:match('^[%w%-]+$')
                or #id<8 or #id>100 or type(record)~='table'
                or type(record.revision)~='number' or record.revision<1
                or record.revision>1000000000 or record.revision%1~=0 then
            error('Invalid calendar device record')
        end
        out.nodes[id]={revision=record.revision,days=M.normalizeDays(record.days)}
    end
    return out
end

local function sameDays(a,b)
    for key,v in pairs(a) do if b[key]~=v then return false end end
    for key,v in pairs(b) do if a[key]~=v then return false end end
    return true
end

function M.merge(a,b)
    a,b=M.normalize(a),M.normalize(b)
    local out=M.empty()
    for id,rec in pairs(a.nodes) do out.nodes[id]=rec end
    for id,rec in pairs(b.nodes) do
        local prev=out.nodes[id]
        if not prev or rec.revision>prev.revision then
            out.nodes[id]=rec
        elseif rec.revision==prev.revision and not sameDays(prev.days,rec.days) then
            error('Calendar device ID collision: matching revisions with different data; no overwrite')
        end
    end
    return M.normalize(out)
end

function M.updateOwn(current,id,localDays)
    local out=M.normalize(current)
    local days=M.normalizeDays(localDays)
    local prev=out.nodes[id]
    if not prev or not sameDays(prev.days,days) then
        local rev=prev and prev.revision+1 or 1
        if rev>1000000000 then error('Calendar revision limit reached') end
        out.nodes[id]={revision=rev,days=days}
    end
    return out
end

function M.remoteDays(snapshot,own_id)
    local data=M.normalize(snapshot)
    local days={}
    for id,record in pairs(data.nodes) do
        if id~=own_id then
            for date,source in pairs(record.days) do
                if not days[date] or source=='recorded' then days[date]=source end
            end
        end
    end
    return days
end
return M
