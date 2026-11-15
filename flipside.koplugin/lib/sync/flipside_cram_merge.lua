-- Conservative, pure-Lua, three-way merge of CRAM snapshots.
-- The original SRS and Learning Analysis databases are never modified here.
local M = {}
local MAX_SLOTS, MAX_ENTRIES = 500, 10000

local function integer(value)
    return type(value) == 'number' and value == value and value >= 0
        and value < 1000000000 and value % 1 == 0
end
local function timestamp(value)
    -- Dates in 2026 already exceed one billion seconds. Preserve original
    -- created timestamps, including large millisecond timestamps if present.
    return type(value)=='number' and value==value and value>=0
        and value<10000000000000 and value%1==0
end
local function validKey(key)
    return type(key) == 'string' and #key <= 1500
        and (key:match('^intensive\t') or key:match('^ultra\t'))
end
local function wordEntry(item, completed)
    if type(item) ~= 'table' or type(item.word) ~= 'string'
            or item.word == '' or #item.word > 1024 then error('Invalid CRAM word entry') end
    local created = item.created
    if created ~= nil and not timestamp(created) then error('Invalid CRAM word creation date') end
    if not completed and not integer(item.streak) then error('Invalid CRAM streak value') end
    return {word=item.word, created=created,
        kind=completed and 'completed' or 'queue',
        streak=completed and 0 or item.streak}
end
function M.normalizeSnapshots(snapshots)
    if type(snapshots) ~= 'table' then error('Invalid CRAM snapshot map') end
    local result, n = {}, 0
    for key, snap in pairs(snapshots) do
        n=n+1
        if n > MAX_SLOTS or not validKey(key) or type(snap) ~= 'table'
                or snap.version ~= 1 or type(snap.queue) ~= 'table'
                or type(snap.completed) ~= 'table' then
            error('Invalid or unsupported CRAM snapshot')
        end
        local copy={version=1,queue={},completed={}}
        for _,field in ipairs({'attempts','correct','missed'}) do
            local value = snap[field] or 0
            if not integer(value) then error('Invalid CRAM counter') end
            copy[field] = value
        end
        local seen, count = {}, 0
        for _,field in ipairs({'queue','completed'}) do
            local done = field == 'completed'
            for _,entry in ipairs(snap[field]) do
                count=count+1
                if count > MAX_ENTRIES then error('CRAM snapshot too large') end
                local item=wordEntry(entry,done)
                if seen[item.word] then error('Duplicate CRAM word in snapshot') end
                seen[item.word]=true
                copy[field][#copy[field]+1] = {word=item.word,created=item.created}
                if not done then copy[field][#copy[field]].streak=item.streak end
            end
        end
        result[key]=copy
    end
    return result
end
function M.normalizeStats(stats)
    if stats == nil then return {} end
    if type(stats) ~= 'table' then error('Invalid CRAM statistics') end
    local result={}
    for _,mode in ipairs({'intensive','ultra'}) do
        local src=stats[mode]
        if src ~= nil then
            if type(src) ~= 'table' then error('Invalid CRAM statistics bucket') end
            local bucket={}
            for _,field in ipairs({'correct','missed'}) do
                local v=src[field] or 0
                if not integer(v) then error('Invalid CRAM statistics count') end
                bucket[field]=v
            end
            result[mode]=bucket
        end
    end
    return result
end
local function states(snap)
    local t={}
    if snap then
        for i,item in ipairs(snap.queue) do
            t[item.word]={kind='queue',created=item.created,streak=item.streak,index=i}
        end
        for _,item in ipairs(snap.completed) do
            t[item.word]={kind='completed',created=item.created,streak=0}
        end
    end
    return t
end
local function equal(a,b)
    if not a or not b then return a==nil and b==nil end
    return a.kind==b.kind and a.created==b.created and a.streak==b.streak
end
local function choose(a,b,base)
    if equal(a,b) then return a, false end
    if equal(a,base) then return b, false end
    if equal(b,base) then return a, false end
    -- With no per-answer cross-device event order, concurrent changes to
    -- the same word cannot safely be resolved. Preserve both checkpoints
    -- instead of silently losing a recent Forgot or a mastered streak.
    if not a or not b then return a or b, true end
    return a, true
end
local function mergeCounter(localCount, remoteCount, baseCount)
    localCount, remoteCount = localCount or 0, remoteCount or 0
    if baseCount==nil then return math.max(localCount,remoteCount) end
    if localCount == baseCount then return remoteCount end
    if remoteCount == baseCount then return localCount end
    -- Counters are cumulative. Each side has incremented relative to the
    -- last jointly acknowledged value; add only the two increments.
    return math.min(999999999,math.max(baseCount,localCount)
        + math.max(0,remoteCount-baseCount))
end
local function mergeOne(localSnap,remoteSnap,baseSnap)
    local L,R,B=states(localSnap),states(remoteSnap),states(baseSnap)
    local merged={version=1,queue={},completed={}}
    for _,field in ipairs({'attempts','correct','missed'}) do
        merged[field]=mergeCounter(localSnap and localSnap[field],
            remoteSnap and remoteSnap[field],baseSnap and baseSnap[field])
    end
    local names, final, conflicts={}, {}, 0
    for name in pairs(L) do names[name]=true end
    for name in pairs(R) do names[name]=true end
    for name in pairs(B) do names[name]=true end
    for name in pairs(names) do
        local selected, conflict=choose(L[name],R[name],B[name])
        if selected then final[name]=selected end
        if conflict then conflicts=conflicts+1 end
    end
    -- Prefer the original local queue ordering. Remote-only words follow in
    -- their original relative order. Never create two copies of a word.
    local seen={}
    local function append(snap)
        if not snap then return end
        for _,item in ipairs(snap.queue) do
            if not seen[item.word] and final[item.word]
                    and final[item.word].kind=='queue' then
                seen[item.word]=true
                local chosen=final[item.word]
                merged.queue[#merged.queue+1]={word=item.word,
                    created=chosen.created,streak=chosen.streak}
            end
        end
    end
    append(localSnap);append(remoteSnap)
    local remaining={}
    for name,state in pairs(final) do
        if state.kind=='completed' then
            merged.completed[#merged.completed+1]={word=name,created=state.created}
        elseif not seen[name] then
            remaining[#remaining+1]=name
        end
    end
    table.sort(remaining)
    for _,name in ipairs(remaining) do
        local item=final[name]
        merged.queue[#merged.queue+1]={word=name,created=item.created,streak=item.streak}
    end
    table.sort(merged.completed,function(a,b) return a.word<b.word end)
    return merged,conflicts
end
function M.merge(localMap,remoteMap,baseMap)
    local L=M.normalizeSnapshots(localMap or {})
    local R=M.normalizeSnapshots(remoteMap or {})
    local B=M.normalizeSnapshots(baseMap or {})
    local keys={}
    for k in pairs(L) do keys[k]=true end
    for k in pairs(R) do keys[k]=true end
    for k in pairs(B) do keys[k]=true end
    local result, conflicts={},0
    for key in pairs(keys) do
        local snapshot, n=mergeOne(L[key],R[key],B[key]);
        result[key]=snapshot;conflicts=conflicts+n
    end
    return result,conflicts
end
function M.mergeStats(localStats,remoteStats,baseStats)
    local L=M.normalizeStats(localStats)
    local R=M.normalizeStats(remoteStats)
    local B=M.normalizeStats(baseStats)
    local out={}
    for _,mode in ipairs({'intensive','ultra'}) do
        local record={}
        for _,field in ipairs({'correct','missed'}) do
            record[field]=mergeCounter(L[mode] and L[mode][field],
                R[mode] and R[mode][field],B[mode] and B[mode][field])
        end
        out[mode]=record
    end
    return out
end
return M
