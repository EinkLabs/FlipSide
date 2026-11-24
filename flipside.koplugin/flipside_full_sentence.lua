--[[--
Vocabulary Builder - full sentence + previous-sentence context (v5.8)

Place this file in koreader/patches/ and remove older Full Sentence
versions (including v5.5). Compatible with Flashcards v2.4.13 or later.

Newly saved entries keep at most the previous complete sentence and the
complete sentence containing the selected word. There is no following-sentence
context. Existing larger entries are NOT rewritten in the Vocabulary Builder
SQLite database: their long saved text is cropped when the full context is
shown, including in Flashcards double-tap and the stock WordInfoDialog.
This also works for cards saved earlier today with v5.6.

The normal single-sentence display, inline Show full context / Sentence only
button, scrolling, flashcard double-tap, all stock Vocabulary Builder actions,
and review scheduling remain unchanged. No native database schema changes.
If the original captured excerpt has no full sentence boundary, the plugin
uses only available text and does not invent the missing passage.
Turn on Vocabulary Builder > Save context.
--]]--

local userpatch = require("flipside_compat")
local logger = require("logger")
local CONTEXT_WORDS = 240

-- Periods in titles should not usually terminate the sentence. Other
-- abbreviations are ambiguous and can finish a sentence before a capital.
local titles = {
    ["mr."] = true, ["mrs."] = true, ["ms."] = true,
    ["dr."] = true, ["prof."] = true, ["sr."] = true,
    ["jr."] = true, ["st."] = true, ["sra."] = true,
    ["srta."] = true, ["dra."] = true,
}
local other_abbreviations = {
    ["etc."] = true, ["vs."] = true, ["e.g."] = true,
    ["i.e."] = true, ["u.s."] = true, ["u.k."] = true,
    ["no."] = true, ["fig."] = true, ["inc."] = true,
    ["ltd."] = true, ["co."] = true, ["approx."] = true,
    ["p.ex."] = true, ["ex."] = true, ["pág."] = true,
}
local punctuation = { "...", "…", ".", "!", "?", "。", "！", "？", "؟", "।" }
local closers = { '"', "'", ")", "]", "}", "»", "”", "’", "›", "」", "』", "）" }
-- Quotes around punctuation can be followed by an attached footnote marker.
-- These suffixes belong to the closing sentence: .”* Next sentence.
local footnote_marks = {"*", "†", "‡", "⁎", "⁑", "¹", "²", "³", "⁰", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"}

-- A closing quote followed by a speech attribution is not a terminal
-- sentence boundary: “Stop!” Harry gasped. is ONE studied utterance.
-- Match a small, auditable set of reporting verbs rather than merging any
-- capitalized prose after quotes (e.g., “Stop!” Harry ran. is two clauses).
local speech_verbs = {
    said=true, asked=true, replied=true, answered=true, responded=true,
    shouted=true, yelled=true, cried=true, screamed=true, whispered=true,
    muttered=true, murmured=true, mumbled=true, stammered=true,
    stuttered=true, gasped=true, panted=true, rasped=true, wheezed=true,
    breathed=true, hissed=true, growled=true, snarled=true, snapped=true,
    barked=true, roared=true, bellowed=true, exclaimed=true, called=true,
    pleaded=true, begged=true, demanded=true, protested=true, insisted=true,
    sobbed=true, groaned=true, grunted=true, sighed=true, chuckled=true,
    laughed=true, giggled=true, croaked=true, sneered=true, scoffed=true,
    retorted=true, warned=true, admitted=true, confessed=true, added=true,
    continued=true, interrupted=true, repeated=true, questioned=true,
    quipped=true, sang=true, whimpered=true, spluttered=true, blurted=true,
    squeaked=true, shrieked=true, drawled=true, faltered=true,
}
local function followedBySpeechTag(text, after)
    -- `after` is the byte immediately following a completed closing quote.
    local tail = text:sub(after)
    if not tail:match("^%s+") then return false end
    -- Never cross paragraph or sentence boundaries, even in a long excerpt.
    local candidate = tail:match("^%s+([^%.%!%?;:\n\r]+)")
    if not candidate then return false end
    candidate = candidate:sub(1, 100)
    if candidate:match("^[‘“'\"]") then return false end
    local words = {}
    for token in candidate:gmatch("[%a]+") do
        words[#words + 1] = token
        if #words == 6 then break end
    end
    if #words < 2 then return false end
    local first = words[1]
    local low_first = first:lower()
    -- An ordinary subject (pronoun or a character's name) followed by a
    -- reporting verb, with optional second/third name: Uncle Vernon snarled.
    local subject = low_first == "he" or low_first == "she" or
        low_first == "they" or low_first == "i" or low_first == "we" or
        first:match("^[A-Z]") ~= nil
    if subject then
        for i = 2, math.min(#words, 4) do
            local prev = words[i - 1]
            -- Intermediate words must look like names, not a new sentence.
            if i > 2 and prev:match("^[A-Z]") == nil then break end
            if speech_verbs[words[i]:lower()] then return true end
        end
    end
    -- Inverted attribution: “Stop!” whispered Harry.
    return speech_verbs[low_first] and words[2]:match("^[A-Z]") ~= nil
end


-- Some document formats may hand back an object-replacement or missing-
-- glyph marker as selected_text / highlighted_word. Never display it between
-- brackets when a real Vocabulary Builder word is available as a fallback.
local function validSelected(s)
    if type(s) ~= "string" or s:match("^%s*$") then return false end
    for _, broken in ipairs({ "�", "￼", "​", "‌", "‍", "◊", "▯", "◧", "□", "■" }) do
        if s:find(broken, 1, true) then return false end
    end
    return s:find("[%w]") ~= nil or s:find("[^%z\1-\127]") ~= nil
end
local function chooseSelected(preferred, fallback)
    if validSelected(preferred) then return preferred end
    return type(fallback) == "string" and fallback or ""
end

local function clean(s)
    if type(s) ~= "string" then return "" end
    -- Preserve the spaces on both sides of the selected word. Normalizing
    -- only newlines prevents line breaks from splitting a rendered sentence.
    -- Some EPUB engines return Unicode line/paragraph separators or NBSP
    -- instead of an ASCII newline. Treat all of them as whitespace so a
    -- visually blank paragraph never hides the preceding sentence.
    return (s:gsub(" ", " "):gsub(" ", " "):gsub(" ", " ")
        :gsub("[%c]+", " "):gsub("%s%s+", " "))
end

local function trimLeft(s) return (s:gsub("^%s+", "")) end
local function trimRight(s) return (s:gsub("%s+$", "")) end

-- A word immediately to the left of this period, including dotted initials.
local function periodToken(text, pos)
    local before = text:sub(1, pos)
    -- This is intentionally byte-based: UTF-8 accented letters stay in the
    -- token and are never confused with an ASCII ending such as 'st.'.
    return before:match("([^%s%(%)%[%]{}\"'«»“”]+)$")
end

local function looksLikeInitial(text, pos, following)
    local previous = text:sub(1, pos - 1):match("([A-Za-z])$")
    if not previous or previous == "I" then return false end
    local before = text:sub(pos - 2, pos - 2)
    if before ~= "" and before:match("[%w_]") then return false end
    return following:match("^%s+[A-Z]") ~= nil
end

local function boundaryAt(text, pos)
    local mark
    for _, m in ipairs(punctuation) do
        if text:sub(pos, pos + #m - 1) == m then
            mark = m
            break
        end
    end
    if not mark then return nil end

    local after = pos + #mark
    -- The end punctuation may be followed (with no intervening whitespace)
    -- by closing quotes/parentheses and editorial footnote markers: .”*, .”¹,
    -- .”[12], etc. Preserve them in the studied sentence instead of losing
    -- the boundary and displaying unrelated sentences or an incomplete tail.
    while after <= #text do
        local matched
        for _, closer in ipairs(closers) do
            if text:sub(after, after + #closer - 1) == closer then
                matched = closer
                break
            end
        end
        if not matched then
            for _, note in ipairs(footnote_marks) do
                if text:sub(after, after + #note - 1) == note then
                    matched = note
                    break
                end
            end
        end
        if not matched then
            -- Numbered references appended immediately after punctuation.
            -- Limit to digits so ordinary bracketed prose is not swallowed.
            matched = text:sub(after):match("^%[%d+%]")
                or text:sub(after):match("^%(%d+%)")
        end
        if not matched then break end
        after = after + #matched
    end
    -- East Asian sentence terminators do not require a following space.
    -- ASCII periods do, to avoid splitting decimals and URLs.
    local east_asian = mark == "。" or mark == "！" or mark == "？"
        or mark == "؟" or mark == "।"
    if not east_asian and after <= #text
        and not text:sub(after, after):match("%s") then
        return nil -- decimal, URL, embedded punctuation
    end

    -- A dialogue tag belongs to the quoted utterance, including after !/?
    -- and when the speaker is named (Harry gasped, Uncle Vernon snarled).
    -- Only apply this when the punctuation really has a closing quotation mark.
    local suffix = text:sub(pos + #mark, after - 1)
    if (suffix:find("'", 1, true) or suffix:find('"', 1, true)
            or suffix:find("’", 1, true) or suffix:find("”", 1, true)
            or suffix:find("»", 1, true))
        and followedBySpeechTag(text, after) then
        return nil
    end

    if mark == "." then
        local token = periodToken(text, pos)
        local lowered = token and token:lower() or ""
        if titles[lowered] then return nil end
        local following = text:sub(after)
        if other_abbreviations[lowered] and following:match("^%s+%l") then
            return nil
        end
        if looksLikeInitial(text, pos, following) then return nil end
    end
    return after - 1
end

local function lastBoundary(text, last_position)
    local limit = last_position or #text
    local last, pos = nil, 1
    while pos <= limit do
        local stop = boundaryAt(text, pos)
        -- Closing quotes and footnotes can extend a boundary beyond pos.
        -- In that case it must not count when looking for the boundary
        -- BEFORE a given sentence (otherwise the current sentence may be
        -- mistaken for its own predecessor).
        if stop and stop <= limit then
            last, pos = stop, stop + 1
        else
            pos = pos + 1
        end
    end
    return last
end

local function firstBoundary(text)
    local pos = 1
    while pos <= #text do
        local stop = boundaryAt(text, pos)
        if stop then return stop end
        pos = pos + 1
    end
    return nil
end

-- An existing saved context can have stock-style wrapper ellipses added by
-- a previous patch. Remove them ONLY when they are clearly artificial: the
-- database itself does not normally include these wrappers.
local function stripDisplayWrappers(prev, next)
    if prev:sub(1, 3) == "..." and next:sub(-3) == "..." then
        return prev:sub(4), next:sub(1, -4)
    end
    return prev, next
end

local Sentence = {}
function Sentence.extract(prev, selected, next)
    if prev == nil and next == nil then return nil, nil, { available = false } end
    prev, next = clean(prev), clean(next)
    selected = clean(selected)

    -- Read the ending of the prior sentence, then preserve whitespace right
    -- next to the selected word, e.g. 'a ' + 'word' + ' here.'
    -- Look ahead into the selection when deciding if a period immediately
    -- before it belongs to an initial/abbreviation: "J. Smith" is one sentence.
    local left_stop = lastBoundary(prev .. selected .. next, #prev)
    if left_stop then prev = trimLeft(prev:sub(left_stop + 1)) end

    -- Include the selection when looking for the next period. This is crucial
    -- when the selected text itself ends in punctuation ("word.").
    local combined = selected .. next
    local right_stop = firstBoundary(combined)
    if right_stop then
        -- Never truncate the selected text, even if it spans sentences.
        local wanted_after = math.max(0, right_stop - #selected)
        next = next:sub(1, wanted_after)
    end

    return prev, next, {
        available = true,
        left_complete = left_stop ~= nil,
        right_complete = right_stop ~= nil,
    }
end

-- Keep just one complete neighboring sentence on either side, in addition
-- to the sentence being studied. Uses the *original* full native context.
-- Saving this broader window is necessary: v5.1 discarded it permanently.
function Sentence.surroundingWindow(prev, selected, next)
    if prev == nil and next == nil then return nil, nil, { available = false } end
    local original_prev, original_next = prev, next
    prev, next = clean(prev), clean(next)
    selected = clean(selected)

    -- Most recent sentence boundary before the selected word ends the
    -- preceding sentence; the boundary before that starts it.
    local current_start = lastBoundary(prev .. selected .. next, #prev)
    local prior_start = current_start and lastBoundary(prev, current_start - 1)
    local left = current_start and trimLeft(prev:sub((prior_start or 0) + 1)) or prev

    -- The first boundary after the selection completes the studied sentence;
    -- the next one completes the immediately following sentence.
    local current_end = firstBoundary(selected .. next)
    local after_selected = current_end and math.max(0, current_end - #selected) or #next
    local remainder = next:sub(after_selected + 1)
    local next_end = firstBoundary(remainder)
    local right = next:sub(1, after_selected + (next_end or #remainder))

    return original_prev == nil and nil or left,
        original_next == nil and nil or right, {
            available = true,
            left_complete = current_start ~= nil,
            right_complete = current_end ~= nil,
            previous_complete = prior_start ~= nil,
            following_complete = next_end ~= nil,
        }
end

-- Trim to the COMPLETE sentence immediately before the studied sentence,
-- plus the studied sentence itself. Operates on native prev/selected/next
-- fields without touching the database or any review metadata.
--
-- When a long existing excerpt starts mid-sentence, do not include that
-- incomplete fragment as the "previous" sentence. On newly shortened saved
-- excerpts, the previous sentence begins at the start of the field; the
-- conservative sentence-start check allows it to remain visible on reopen.
-- A complete neighboring sentence can begin with an opening quotation
-- mark. Lua patterns do not reliably classify UTF-8 curly quotes inside
-- byte-based character classes; check whole prefixes explicitly instead.
-- Never accept a lowercase mid-sentence fragment as a complete sentence.
local sentence_openers = {"'", '"', "‘", "“", "«", "(", "[", "—", "–"}
local function startsWithSentenceCapital(s)
    s = trimLeft(s)
    if s:match("^[A-Z]") then return true end
    for _ = 1, 4 do
        local matched = false
        for _, opener in ipairs(sentence_openers) do
            if s:sub(1, #opener) == opener then
                s = trimLeft(s:sub(#opener + 1))
                matched = true
                break
            end
        end
        if not matched then break end
        if s:match("^[A-Z]") then return true end
    end
    return false
end

function Sentence.previousAndCurrentWindow(prev, selected, next)
    if prev == nil and next == nil then return nil, nil, { available = false } end
    local had_prev, had_next = prev ~= nil, next ~= nil
    prev, next, selected = clean(prev), clean(next), clean(selected)
    local boundary = lastBoundary(prev .. selected .. next, #prev)
    local prior_boundary = boundary and lastBoundary(prev, boundary - 1)
    local previous_sentence
    local current_prefix
    if boundary then
        current_prefix = trimLeft(prev:sub(boundary + 1))
        if prior_boundary then
            previous_sentence = trimRight(trimLeft(prev:sub(prior_boundary + 1, boundary)))
        else
            local candidate = trimRight(trimLeft(prev:sub(1, boundary)))
            -- A cropped excerpt can begin mid-sentence. Never present an
            -- obviously incomplete lower-case fragment as a complete prior.
            if candidate ~= '' and not candidate:match('^%.%.%.')
                and startsWithSentenceCapital(candidate) then
                previous_sentence = candidate
            end
        end
    else
        current_prefix = prev
    end
    local remainder = selected .. next
    local target_stop = firstBoundary(remainder)
    local suffix = target_stop and next:sub(1, math.max(0, target_stop - #selected)) or next
    local left = (previous_sentence and previous_sentence ~= '')
        and (previous_sentence .. ' ' .. current_prefix) or current_prefix
    return had_prev and left or nil, had_next and suffix or nil, {
        available = true,
        previous_complete = previous_sentence ~= nil and previous_sentence ~= '',
        current_complete = target_stop ~= nil,
        previous_sentence = previous_sentence,
        current_prefix = current_prefix,
    }
end

local function normalizeForCompare(s)
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Crop expanded context at DISPLAY TIME as well. This is important for
-- old v5.6 cards, including ones added earlier today: they retain their
-- original SQLite fields but no longer display their enormous saved context.
function Sentence.formatSurrounding(prev, selected, next)
    if prev == nil and next == nil then return nil end
    local left, right, info = Sentence.previousAndCurrentWindow(prev, selected, next)
    local word = clean(selected)
    local current = clean(info.current_prefix) .. '【' .. word .. '】' .. clean(right)
    local expanded = info.previous_complete
        and (info.previous_sentence .. '\n' .. current)
        or (clean(left) .. '【' .. word .. '】' .. clean(right))
    local short = Sentence.format(prev, selected, next)
    if normalizeForCompare(expanded) == normalizeForCompare(short) then
        -- An older entry may have extra following sentences that the normal
        -- display no longer needs. Return the cropped value even when it is
        -- just the target sentence, or Flashcards would fall back to the
        -- entire original prev/next when this helper returns nil.
        local original = clean(prev) .. '【' .. word .. '】' .. clean(next)
        if normalizeForCompare(original) == normalizeForCompare(short) then
            return nil
        end
    end
    return expanded
end

-- Expanded context displays the saved sentences without artificial
-- boundary ellipses. The underlying database and native context stay intact.
local function trimExpandedContext(text)
    if type(text) ~= "string" or text == "" then return nil end
    text = trimLeft(trimRight(text))
    return text ~= "" and text or nil
end

function Sentence.formatListContext(prev, selected, next)
    if prev == nil and next == nil then return nil end
    selected = clean(selected)
    local full = Sentence.formatSurrounding(prev, selected, next)
    if type(full) ~= "string" or full == "" then
        -- formatSurrounding returns nil when no extra words are stored; the
        -- list still has a valid full-text view, with the original saved text.
        full = clean(prev) .. "【" .. selected .. "】" .. clean(next)
    end
    return trimExpandedContext(full)
end

function Sentence.format(prev, selected, next)
    if prev == nil and next == nil then return nil end
    prev, next = stripDisplayWrappers(clean(prev), clean(next))
    local left, right, info = Sentence.extract(prev, selected, next)
    selected = clean(selected)
    -- Older saved entries may genuinely end mid-sentence because the book
    -- returned a short excerpt. The missing words cannot be reconstructed.
    -- Mark this honestly as a clipped excerpt instead of silently presenting
    -- the last word as if it ended at a full stop. The expanded full-context
    -- view is unchanged and still renders every saved character.
    if not info.right_complete then
        local visible = trimRight(right)
        if visible:sub(-3) ~= "..." and visible:sub(-#"…") ~= "…" then
            right = visible .. "..."
        end
    end
    return left .. "【" .. selected .. "】" .. right
end

-- Etapa 2: save the native reading selection before the dictionary starts its
-- lookup. KOReader can clear the selected text while a dictionary popup stays
-- open, so relying on it when the user eventually taps Add is not sufficient.
-- Only a per-ReaderUI, in-memory snapshot is kept; nothing is synced or written
-- until FlipSide's existing add-word action runs.
local function normalizeQuery(s)
    if type(s) ~= "string" then return nil end
    s = s:lower():gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

function Sentence.snapshotMatches(snapshot, lookup_word, highlight)
    if type(snapshot) ~= "table" then return false end
    if normalizeQuery(snapshot.lookup_word) ~= nil
        and normalizeQuery(snapshot.lookup_word) == normalizeQuery(lookup_word) then
        return true
    end
    -- Some dictionary results use the lemma (gasp) while the original
    -- selected text is inflected (gasped). This snapshot is scoped to the
    -- actual ReaderHighlight object that initiated the pending lookup.
    -- A new lookup always invalidates the pending snapshot.
    if type(highlight) ~= "table" or highlight ~= snapshot.source_highlight then
        return false
    end
    local selected = highlight.selected_text
    if type(selected) == "table" and type(selected.text) == "string"
        and normalizeQuery(selected.text) == normalizeQuery(snapshot.selected) then
        -- If XPointers exist, require the SAME selected occurrence.
        if snapshot.pos0 and selected.pos0 ~= snapshot.pos0 then return false end
        if snapshot.pos1 and selected.pos1 ~= snapshot.pos1 then return false end
        return true
    end
    -- Selection may be cleared while a dictionary popup is open. Since
    -- pending snapshots are replaced on every lookup, object identity is
    -- sufficient in that case; unlike word stems, this cannot mix entries.
    return selected == nil and snapshot.pos0 ~= nil
end

-- Some EPUBs expose the selected paragraph through getSelectedWordContext()
-- without its preceding block. When that happens, try KOReader/CRengine's
-- public XPointer navigation methods while the original selection is alive.
-- This is a bounded fallback: no searching the book or changing the reading
-- position, and no guesswork when the document cannot supply the text.
local function recoverPreviousAcrossParagraph(highlight, native_prev)
    local selection = highlight and highlight.selected_text
    local doc = highlight and highlight.ui and highlight.ui.document
    if type(selection) ~= "table" or type(selection.pos0) ~= "string"
        or type(selection.pos1) ~= "string" or not doc
        or type(doc.getPrevVisibleWordStart) ~= "function"
        or type(doc.getTextFromXPointers) ~= "function" then
        return nil
    end

    local start = selection.pos0
    local moved = false
    -- Bound the number of native C-engine calls: this runs only if the
    -- default capture could not find a full preceding sentence.
    for _ = 1, 160 do
        local ok, prior = pcall(doc.getPrevVisibleWordStart, doc, start)
        if not ok then break end
        if type(prior) ~= "string" or prior == start then
            -- The previous-word iterator can stop at an EPUB block boundary.
            -- A preceding visible character may cross that boundary safely.
            if type(doc.getPrevVisibleChar) ~= "function" then break end
            ok, prior = pcall(doc.getPrevVisibleChar, doc, start)
            if not ok or type(prior) ~= "string" or prior == start then break end
        end
        start = prior
        moved = true
    end
    if not moved then return nil end

    local ok, raw = pcall(doc.getTextFromXPointers, doc, start, selection.pos0, false)
    -- CRengine may clear a highlighted selection when another text range is
    -- read. Restore the original highlight exactly as KOReader itself does.
    pcall(doc.getTextFromXPointers, doc, selection.pos0, selection.pos1, true)
    if not ok or type(raw) ~= "string" or raw == "" or #raw > 12000 then
        return nil
    end
    local candidate = clean(raw)
    local previous = clean(native_prev)
    if #candidate <= #previous then return nil end
    -- Only accept continuous text immediately preceding this selected word.
    -- In particular, never join a passage from an unrelated chapter/page.
    local tail = trimRight(previous)
    if tail ~= "" and trimRight(candidate):sub(-#tail) ~= tail then
        return nil
    end
    return raw
end

function Sentence.captureAtLookup(highlight, lookup_word)
    if type(highlight) ~= "table" then return nil end
    local selected_text = highlight.selected_text
    if type(selected_text) ~= "table" or not validSelected(selected_text.text) then return nil end
    local selected = selected_text.text
    local get_context = highlight.getSelectedWordContext
    local ok, prev, next = false, nil, nil
    if type(get_context) == "function" then
        ok, prev, next = pcall(get_context, highlight, CONTEXT_WORDS)
        if not ok then
            logger.warn("FlipSide context: extended selection read failed:", prev)
        end
        -- Some document backends cannot supply a very large context window.
        -- Prefer a shorter real excerpt over saving an empty sentence.
        if not ok or (prev == nil and next == nil) then
            for _, limit in ipairs({60, 15}) do
                local retry_ok, p, n = pcall(get_context, highlight, limit)
                if retry_ok and (p ~= nil or n ~= nil) then
                    prev, next, ok = p, n, true
                    break
                end
            end
        end
    end

    -- First retain the ordinary native capture. If there is no previous
    -- complete sentence, attempt a separate bounded XPointer lookbehind
    -- across paragraph breaks, which may be invisible to the native window.
    local _, _, initial = Sentence.previousAndCurrentWindow(prev, selected, next)
    if not initial.previous_complete then
        local recovered = recoverPreviousAcrossParagraph(highlight, prev)
        if recovered then prev = recovered end
    end
    if prev == nil and next == nil then return nil end

    -- Ask for a longer excerpt only when native boundaries are incomplete.
    -- Two capped retries avoid the cost of scanning an entire chapter.
    local _, _, info = Sentence.previousAndCurrentWindow(prev, selected, next)
    if type(get_context) == "function" and (not info.current_complete
        or (prev ~= nil and not info.previous_complete)) then
        for _, limit in ipairs({480, 960}) do
            local more_ok, p, n = pcall(get_context, highlight, limit)
            if not more_ok or (p == nil and n == nil) or (p == prev and n == next) then break end
            -- Don't replace a longer XPointer-recovered previous paragraph
            -- with a shorter native excerpt during these retries.
            local gained = false
            if type(p) == "string" and #p > #(prev or "") then
                prev = p
                gained = true
            end
            if type(n) == "string" and #n > #(next or "") then
                next = n
                gained = true
            end
            if not gained then break end
            local _, _, extra_info = Sentence.previousAndCurrentWindow(prev, selected, next)
            if extra_info.current_complete
                and (prev == nil or extra_info.previous_complete) then break end
        end
    end
    -- Keep the existing two-sentence policy: previous + studied sentence.
    -- Preserve nils instead of manufacturing context or replacing good data
    -- with empty strings. The selected form may differ from the dictionary key.
    local cropped_prev, cropped_next = Sentence.previousAndCurrentWindow(prev, selected, next)
    if cropped_prev == "" then cropped_prev = nil end
    if cropped_next == "" then cropped_next = nil end
    if cropped_prev == nil and cropped_next == nil then return nil end
    return {
        lookup_word = lookup_word,
        selected = selected,
        source_highlight = highlight,
        pos0 = selected_text.pos0,
        pos1 = selected_text.pos1,
        prev_context = cropped_prev,
        next_context = cropped_next,
    }
end

function Sentence.installLookupCapture(plugin, is_enabled)
    local dictionary = plugin and plugin.ui and plugin.ui.dictionary
    if type(dictionary) ~= "table" or dictionary._flipside_capture_installed then return false end
    local original_lookup = dictionary.onLookupWord
    if type(original_lookup) ~= "function" then return false end
    dictionary._flipside_capture_installed = true
    dictionary.onLookupWord = function(dict, word, is_sane, boxes, highlight, link, close_callback)
        -- Every new lookup invalidates the previous pending lookup, including
        -- a query from inside a definition (no book text selected).
        local enabled = true
        if type(is_enabled) == "function" then
            local ok_enabled, result = pcall(is_enabled)
            enabled = ok_enabled and result == true
        end
        local ok, snapshot = true, nil
        if enabled and highlight then
            ok, snapshot = pcall(Sentence.captureAtLookup, highlight, word)
            if not ok then
                logger.warn("FlipSide context: lookup snapshot failed:", snapshot)
            end
        end
        plugin._flipside_pending_context = ok and snapshot or nil
        return original_lookup(dict, word, is_sane, boxes, highlight, link, close_callback)
    end
    return true
end

-- Publish the same formatter for the flashcard patch (no extra file needed).
-- Both patches are loaded on KOReader startup; flashcards use it only when
-- their screen is built, after startup has finished.
package.loaded["flipside_full_sentence_shared"] = Sentence

-- The stock WordInfoDialog owns the popup shown via the "..." button on a
-- vocabulary list row. Show the expanded context INSIDE that original popup;
-- unlike v5.4, never create a second viewer or push another widget on screen.
-- WordInfoDialog:setTitle() is KOReader's native free/init/repaint path, so it
-- can update the text and button without closing the popup or touching the DB.
local function patchDialogClass(dialog_class)
    if type(dialog_class) ~= "table" or type(dialog_class.init) ~= "function" then
        return false
    end
    if dialog_class.__sentence_context_v5 then return true end
    local original_init = dialog_class.init
    dialog_class.init = function(self, ...)
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local ButtonTable = require("ui/widget/buttontable")
        local Screen = require("device").screen
        local original_text_new = TextBoxWidget.new
        local original_buttons_new = ButtonTable.new
        local selected = chooseSelected(self.highlighted_word, self.title or self.word)
        local complete_text = self.vocabbuilder and
            Sentence.formatListContext(self.prev_context, selected, self.next_context) or nil
        local expanded = complete_text and self._sentence_context_expanded
        local building_scroll = false

        TextBoxWidget.new = function(class, args, ...)
            -- A ScrollTextWidget creates its own nested TextBoxWidget. Leave
            -- that nested widget alone, or this override would recurse.
            if not building_scroll and type(args) == "table"
                and type(args.text) == "string"
                and (args.text:find("〖", 1, true) or args.text:find("【", 1, true))
                and (self.prev_context ~= nil or self.next_context ~= nil) then
                local replacement = expanded and complete_text
                    or Sentence.format(self.prev_context, selected, self.next_context)
                if replacement then
                    local new_args = {}
                    for k, v in pairs(args) do new_args[k] = v end
                    new_args.text = replacement
                    if expanded then
                        -- Measure actual line wrapping with the caller's face.
                        -- A fixed-height scroll area is used only when needed,
                        -- avoiding any oversized or clipped popup on Kindle.
                        local text_widget = original_text_new(class, new_args, ...)
                        local max_h = math.max(120, math.floor(Screen:getHeight() * 0.36))
                        local measured_h = text_widget:getSize().h
                        if measured_h <= max_h then return text_widget end
                        text_widget:free()
                        local ok_scroll, scroller = pcall(function()
                            local ScrollTextWidget = require("ui/widget/scrolltextwidget")
                            building_scroll = true
                            return ScrollTextWidget:new{
                                text = replacement,
                                face = new_args.face,
                                width = new_args.width,
                                height = max_h,
                                alignment = new_args.alignment,
                                fgcolor = new_args.fgcolor,
                                dialog = self,
                                scroll_by_pan = true,
                            }
                        end)
                        building_scroll = false
                        if ok_scroll then return scroller end
                        logger.warn("vocab sentence v5.8: inline scroll failed:", scroller)
                        -- Recover gracefully if a device lacks ScrollTextWidget.
                        return original_text_new(class, new_args, ...)
                    end
                    return original_text_new(class, new_args, ...)
                end
            end
            return original_text_new(class, args, ...)
        end

        local added_button = false
        ButtonTable.new = function(class, args, ...)
            if not added_button and complete_text
                and type(args) == "table" and args.show_parent == self
                and type(args.buttons) == "table" then
                local new_args = {}
                for k, v in pairs(args) do new_args[k] = v end
                local rows = {}
                for i, row in ipairs(args.buttons) do rows[i] = row end
                rows[#rows + 1] = {{
                    text = expanded and "Sentence only" or "Show full context",
                    callback = function()
                        -- Rebuild the existing popup in place, using the
                        -- supported KOReader setter (also used by stock UI).
                        self._sentence_context_expanded = not self._sentence_context_expanded
                        if type(self.setTitle) == "function" then
                            self:setTitle(self.title)
                        else
                            -- Avoid a crash on incompatible plugin versions.
                            self._sentence_context_expanded = nil
                        end
                    end,
                }}
                new_args.buttons = rows
                added_button = true
                return original_buttons_new(class, new_args, ...)
            end
            return original_buttons_new(class, args, ...)
        end

        -- Restore the constructors even if a companion user patch raises.
        local ok, err = pcall(original_init, self, ...)
        TextBoxWidget.new = original_text_new
        ButtonTable.new = original_buttons_new
        if not ok then error(err, 0) end
    end
    dialog_class.__sentence_context_v5 = true
    return true
end

local function originalHandler(handler)
    if type(handler) == "function" then return handler end
    if type(handler) == "table" and type(handler.f) == "function" then return handler.f end
    return nil
end

local function patchVocabularyBuilder(plugin)
    if type(plugin) ~= "table" or plugin.__sentence_context_v5 then return end
    local handler = plugin.onWordLookedUp
    local original_lookup = originalHandler(handler)
    if not original_lookup then
        logger.warn("vocab sentence v5.8: onWordLookedUp unavailable")
        return
    end

    -- Dialog is optional: a failure to locate it must never disable saving.
    if type(userpatch.getUpValue) == "function" then
        local ok, cls = pcall(userpatch.getUpValue, original_lookup, "WordInfoDialog")
        if ok and cls then
            local ok_dialog, err = pcall(patchDialogClass, cls)
            if not ok_dialog then logger.warn("vocab sentence v5.8: dialog patch:", err) end
        end
    end

    local replacement = function(self, word, title, is_manual, ...)
        local highlight = self.ui and self.ui.highlight
        local get_context = highlight and highlight.getSelectedWordContext
        local previous = highlight and rawget(highlight, "getSelectedWordContext")
        if highlight and type(get_context) == "function" then
            highlight.getSelectedWordContext = function(target, n, ...)
                -- Request enough native text to find full boundaries. The
                -- result is trimmed before it reaches the stock DB. Never manufacture
                -- extra context or strip the "..." supplied by KOReader.
                local requested = tonumber(n) or 0
                local size = math.max(requested, CONTEXT_WORDS)
                local ok, prev, next = pcall(get_context, target, size, ...)
                if not ok then
                    logger.warn("vocab sentence v5.8: extended capture failed:", prev)
                    return get_context(target, n, ...)
                end
                if prev == nil and next == nil then return prev, next end

                -- Reading context has a finite window. With the new sentence
                -- boundary parser, enlarge that window only for an incomplete
                -- sentence, stopping as soon as the reader supplies a boundary
                -- or stops yielding additional text. Never invent book text.
                local highlighted = target.selected_text and target.selected_text.text
                highlighted = chooseSelected(highlighted, word)
                local _, _, info = Sentence.extract(prev, highlighted, next)
                if not info.right_complete then
                    for _, limit in ipairs({math.max(size, 480), math.max(size, 960)}) do
                        if limit > size then
                            local ok_more, p, nx = pcall(get_context, target, limit, ...)
                            if not ok_more or (p == nil and nx == nil) then break end
                            if p == prev and nx == next then break end
                            prev, next = p, nx
                            size = limit
                            local _, _, next_info = Sentence.extract(prev, highlighted, next)
                            if next_info.right_complete then break end
                        end
                    end
                end
                -- Save only the previous complete sentence and the target
                -- sentence. All already-saved records remain untouched.
                local cropped_prev, cropped_next =
                    Sentence.previousAndCurrentWindow(prev, highlighted, next)
                return cropped_prev, cropped_next
            end
        end
        local ok, a, b, c, d = pcall(original_lookup, self, word, title, is_manual, ...)
        if highlight then highlight.getSelectedWordContext = previous end
        if not ok then error(a, 0) end
        return a, b, c, d
    end

    -- HandlerSandbox wraps KOReader plugin event handlers as tables with .f.
    if type(handler) == "table" and type(handler.f) == "function" then
        handler.f = replacement
    else
        plugin.onWordLookedUp = replacement
    end
    plugin.__sentence_context_v5 = true
    logger.info("vocab sentence v5.8: previous + studied sentence saved; older context shortened for display")
end

userpatch.registerPatchPluginFunc("flipside", patchVocabularyBuilder)
