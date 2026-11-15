-- FlipSide: persistent, idempotent statistics-Undo recovery queue.
-- An official Vocabulary Builder Undo is committed separately. Once that
-- commit succeeds, this journal retains the identity (word + exact timestamp)
-- of the stats event that must be reversed. Replaying never touches SRS.
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local Diag = require("flipside_diagnostics")

local Recovery = {}
Recovery.__index = Recovery

local function valid(entry)
    return type(entry) == "table" and type(entry.word) == "string"
        and entry.word ~= "" and type(entry.timestamp) == "number"
        and entry.timestamp > 0
end

local function copy(entries)
    local output, count = {}, 0
    for key in pairs(entries) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            error("Unexpected key in statistics Undo recovery journal")
        end
        count = count + 1
    end
    -- A damaged/sparse array must not be silently interpreted as empty.
    for i = 1, count do
        local entry = entries[i]
        if not valid(entry) then
            error("Invalid or missing stored statistics Undo recovery record")
        end
        output[i] = { word = entry.word,
            timestamp = math.floor(entry.timestamp) }
    end
    return output
end

function Recovery.open()
    local folder = DataStorage:getSettingsDir() .. "/flipside"
    util.makePath(folder)
    local file = folder .. "/undo_statistics_recovery.lua"
    local settings = LuaSettings:open(file)
    local entries = settings:readSetting("pending")
    local sequence = settings:readSetting("sequence")
    -- Do not replace an existing, unreadable journal with an empty file.
    if lfs.attributes(file, "mode") == "file"
        and (type(entries) ~= "table" or type(sequence) ~= "number") then
        error("The existing Undo recovery file is unreadable; kept untouched")
    end
    if type(entries) ~= "table" then entries = {} end
    entries = copy(entries)
    return setmetatable({path = file, settings = settings,
        pending = entries, sequence = tonumber(sequence) or 0}, Recovery)
end

function Recovery:_commit(entries)
    entries = copy(entries)
    local sequence = self.sequence + 1
    self.settings:saveSetting("pending", entries)
    self.settings:saveSetting("sequence", sequence)
    self.settings:flush()
    local verified = LuaSettings:open(self.path)
    if tonumber(verified:readSetting("sequence")) ~= sequence then
        error("Could not verify Undo statistics recovery checkpoint")
    end
    local saved = verified:readSetting("pending")
    if type(saved) ~= "table" or #saved ~= #entries then
        error("Undo statistics recovery checkpoint contains unexpected data")
    end
    for i, entry in ipairs(entries) do
        if not valid(saved[i]) or saved[i].word ~= entry.word
            or math.floor(saved[i].timestamp) ~= entry.timestamp then
            error("Undo statistics recovery checkpoint does not match")
        end
    end
    self.pending = entries
    self.sequence = sequence
    return true
end

function Recovery:add(word, timestamp)
    if type(word) ~= "string" or word == ""
        or type(timestamp) ~= "number" or timestamp <= 0 then
        return false, "Missing word or exact review timestamp"
    end
    local at = math.floor(timestamp)
    for _, entry in ipairs(self.pending) do
        if entry.word == word and entry.timestamp == at then return true end
    end
    local entries = copy(self.pending)
    entries[#entries + 1] = { word = word, timestamp = at }
    return self:_commit(entries)
end

function Recovery:complete(word, timestamp)
    local at = math.floor(tonumber(timestamp) or 0)
    local entries, found = {}, false
    for _, entry in ipairs(self.pending) do
        if entry.word == word and entry.timestamp == at then
            found = true
        else
            entries[#entries + 1] = entry
        end
    end
    if not found then return true end
    return self:_commit(entries)
end

function Recovery:replay(notify)
    -- notify(word, timestamp) must return true only when both stats bridges
    -- are updated. Missing events are harmless, because replay is idempotent.
    local completed, failed = {}, 0
    for _, entry in ipairs(self.pending) do
        local ok, result = pcall(notify, entry.word, entry.timestamp)
        if ok and result == true then
            completed[#completed + 1] = entry
        else
            failed = failed + 1
            Diag.report("ERROR", "UNDO_REPLAY_INCOMPLETE",
                {stage="replay_event", stats_saved=false},
                ok and "Statistics callback returned false" or result)
        end
    end
    if #completed > 0 then
        local done = {}
        for _, entry in ipairs(completed) do
            done[entry.word .. "\0" .. tostring(entry.timestamp)] = true
        end
        local remaining = {}
        for _, entry in ipairs(self.pending) do
            if not done[entry.word .. "\0" .. tostring(entry.timestamp)] then
                remaining[#remaining + 1] = entry
            end
        end
        self:_commit(remaining)
    end
    return #completed, failed
end

return Recovery
