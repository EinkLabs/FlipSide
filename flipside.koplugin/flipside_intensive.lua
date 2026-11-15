-- FlipSide cram: no timers and NO direct SRS/database mutations.
-- Persistence is owned by flipside_cram_store; this module is pure Lua.
local Intensive = {}
Intensive.__index = Intensive

local function validCard(card)
    return type(card) == "table" and type(card.word) == "string"
        and card.word ~= ""
end

local function sameCreation(saved, card)
    local original = tonumber(saved)
    local current = tonumber(card.created)
    return not original or not current or original == current
end

function Intensive.new(mode)
    assert(mode == "intensive" or mode == "ultra")
    return setmetatable({
        mode = mode, target = mode == "ultra" and 3 or 2,
        queue = {}, by_word = {}, completed_words = {}, active = nil,
        added = 0, completed = 0, attempts = 0, correct = 0, missed = 0,
    }, Intensive)
end

function Intensive:has(word)
    return self.by_word[word] ~= nil or self.completed_words[word] ~= nil
end

-- An official new miss reopens a previously mastered cram word; simply
-- rebuilding a deck or changing mode must never reset an achieved streak.
function Intensive:add(card, official_miss)
    if not validCard(card) then return false end
    local word = card.word
    local entry = self.by_word[word]
    if entry then
        if official_miss then entry.streak = 0 end
        return false
    end
    if self.completed_words[word] then
        if not official_miss then return false end
        self.completed_words[word] = nil
        self.completed = math.max(0, self.completed - 1)
    end
    entry = { card = card, streak = 0 }
    self.by_word[word] = entry
    self.queue[#self.queue + 1] = entry
    self.added = self.added + 1
    return true
end

function Intensive:pending()
    -- Excludes the card currently displayed (the UI counts it separately).
    return #self.queue
end

-- Number of distinct unfinished words, including a visible unanswered card.
-- Read-only: safe for menu previews and saved-queue inspection.
function Intensive:available()
    return #self.queue + (self.active and 1 or 0)
end

function Intensive:take()
    if self.active or #self.queue == 0 then return nil end
    self.active = table.remove(self.queue, 1)
    return self.active
end

-- Pause when the user leaves/switches mode/undoes a native response.
-- The unfinished word returns to the FRONT (it has not been rated), so it
-- cannot lose its queue position or its earlier correct recalls.
function Intensive:pause()
    if not self.active then return false end
    table.insert(self.queue, 1, self.active)
    self.active = nil
    return true
end

function Intensive:rate(got)
    local entry = self.active
    if not entry then return nil end
    self.active = nil
    self.attempts = self.attempts + 1
    if got then
        self.correct = self.correct + 1
        entry.streak = entry.streak + 1
    else
        self.missed = self.missed + 1
        entry.streak = 0
    end
    if entry.streak >= self.target then
        self.by_word[entry.card.word] = nil
        self.completed_words[entry.card.word] = tonumber(entry.card.created) or true
        self.completed = self.completed + 1
        return true
    end
    self.queue[#self.queue + 1] = entry
    return false
end

-- Capture only this word, not the whole queue: Undo must never rewind
-- successes of OTHER words, even if the user switches cram mode first.
function Intensive:wordState(word)
    local entry = self.by_word[word]
    if entry then
        local position
        for i, candidate in ipairs(self.queue) do
            if candidate == entry then position = i; break end
        end
        return {kind = "queued", streak = entry.streak,
            position = position or 1,
            created = tonumber(entry.card.created)}
    end
    local created = self.completed_words[word]
    if created then
        return {kind = "completed",
            created = type(created) == "number" and created or nil}
    end
    return nil
end

function Intensive:restoreWord(word, previous, card)
    self:remove(word)
    if type(previous) ~= "table" or not validCard(card) then return end
    if not sameCreation(previous.created, card) then return end
    if previous.kind == "completed" then
        self.completed_words[word] = tonumber(card.created) or true
        self.completed = self.completed + 1
    elseif previous.kind == "queued" then
        local entry = {card = card,
            streak = math.max(0, math.min(self.target-1,
                math.floor(tonumber(previous.streak) or 0)))}
        local pos = math.max(1, math.min(#self.queue+1,
            math.floor(tonumber(previous.position) or 1)))
        table.insert(self.queue, pos, entry)
        self.by_word[word] = entry
    end
end

function Intensive:remove(word)
    local entry = self.by_word[word]
    local was_completed = self.completed_words[word] ~= nil
    if not entry and not was_completed then return false end
    self.by_word[word] = nil
    if was_completed then
        self.completed_words[word] = nil
        self.completed = math.max(0, self.completed - 1)
    end
    if self.active == entry then self.active = nil end
    for i = #self.queue, 1, -1 do
        if self.queue[i] == entry then table.remove(self.queue, i) end
    end
    return true
end

local function encode(entry)
    return { word = entry.card.word,
        created = tonumber(entry.card.created), streak = entry.streak }
end

function Intensive:snapshot()
    local result = {version = 1, queue = {}, completed = {},
        attempts = self.attempts, correct = self.correct,
        missed = self.missed}
    -- A just-visible, unanswered card is saved at the head of the queue.
    if self.active then result.queue[#result.queue + 1] = encode(self.active) end
    for _, entry in ipairs(self.queue) do
        result.queue[#result.queue + 1] = encode(entry)
    end
    for word, created in pairs(self.completed_words) do
        result.completed[#result.completed + 1] = {
            word = word, created = type(created) == "number" and created or nil,
        }
    end
    table.sort(result.completed, function(a,b) return a.word < b.word end)
    return result
end

function Intensive.restore(mode, snapshot, cards_by_word)
    local obj = Intensive.new(mode)
    if type(snapshot) ~= "table" or snapshot.version ~= 1
            or type(cards_by_word) ~= "table" then return obj end
    local completed = type(snapshot.completed) == "table" and snapshot.completed or {}
    for _, item in ipairs(completed) do
        local card = type(item) == "table" and cards_by_word[item.word]
        if validCard(card) and sameCreation(item.created, card) then
            obj.completed_words[item.word] = tonumber(card.created) or true
            obj.completed = obj.completed + 1
        end
    end
    local queue = type(snapshot.queue) == "table" and snapshot.queue or {}
    for _, item in ipairs(queue) do
        local card = type(item) == "table" and cards_by_word[item.word]
        if validCard(card) and sameCreation(item.created, card)
                and not obj.by_word[card.word]
                and not obj.completed_words[card.word] then
            local streak = tonumber(item.streak) or 0
            streak = math.max(0, math.min(obj.target - 1, math.floor(streak)))
            local entry = {card = card, streak = streak}
            obj.queue[#obj.queue + 1] = entry
            obj.by_word[card.word] = entry
        end
    end
    obj.added = #obj.queue + obj.completed
    obj.attempts = math.max(0, math.floor(tonumber(snapshot.attempts) or 0))
    obj.correct = math.max(0, math.floor(tonumber(snapshot.correct) or 0))
    obj.missed = math.max(0, math.floor(tonumber(snapshot.missed) or 0))
    return obj
end

return Intensive
