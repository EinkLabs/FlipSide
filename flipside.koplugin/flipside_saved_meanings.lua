-- FlipSide: multiple saved meanings per word, organized by dictionary.
-- Storage is separate from review and position locks. V1 data are read in place.
-- Cloud sync uses V2 records and imports legacy V1 snapshots on first sync.
local M = {}
local DataStorage = require('datastorage')
local LuaSettings = require('luasettings')
local UIManager = require('ui/uimanager')
local InfoMessage = require('ui/widget/infomessage')
local TextViewer = require('ui/widget/textviewer')
local InputDialog = require('ui/widget/inputdialog')
local ConfirmBox = require('ui/widget/confirmbox')
local logger = require('logger')
local util = require('util')
local PATH = DataStorage:getSettingsDir() .. '/flipside/saved_dictionary_meanings.lua'
local SNAPSHOT = DataStorage:getSettingsDir() .. '/flipside/saved_dictionary_meanings_v3.tsv'
local PREVIOUS_SNAPSHOT = DataStorage:getSettingsDir() .. '/flipside/saved_dictionary_meanings_v2.tsv'
local LEGACY_SNAPSHOT = DataStorage:getSettingsDir() .. '/flipside/saved_dictionary_meanings_v1.tsv'
local HEADER = 'FLIPSIDE_SAVED_MEANINGS_V3'
local PREVIOUS_HEADER = 'FLIPSIDE_SAVED_MEANINGS_V2'
local LEGACY_HEADER = 'FLIPSIDE_SAVED_MEANINGS_V1'
local MAX_TEXT = 10000
local MAX_SNAPSHOT = 16 * 1024 * 1024
local store
local pending_word
local arm_generation=0
local syncing = false

local function cleanWord(word)
    return tostring(word or ''):gsub('^%s+', ''):gsub('%s+$', ''):lower()
end
local function cleanText(text)
    text=tostring(text or ''):gsub('\r\n','\n'):gsub('\r','\n')
    text=text:gsub('^%s+',''):gsub('%s+$','')
    if #text>MAX_TEXT then return nil,'Meaning is too long.' end
    if text=='' then return nil,'Select a meaning first.' end
    return text
end
local function cleanDictionary(name)
    name=tostring(name or ''):gsub('^%s+',''):gsub('%s+$','')
    if name=='' then return 'Unknown dictionary' end
    return name:sub(1,512)
end
local function alert(text)
    UIManager:show(InfoMessage:new{text=tostring(text),timeout=4})
end
local function readStore()
    if store then return store end
    local cfg=LuaSettings:open(PATH)
    local entries=cfg:readSetting('entries')
    if type(entries)~='table' then entries={} end
    store={cfg=cfg,entries=entries}
    return store
end
local function persist()
    local st=readStore()
    st.cfg:saveSetting('entries',st.entries)
    st.cfg:flush()
end
local function validRecord(word,id,row)
    if type(word)~='string' or word=='' or #word>2048 or type(id)~='string'
            or id=='' or #id>128 or type(row)~='table' then return nil end
    local deleted=row.deleted==true or row.deleted==1
    if not deleted and (type(row.text)~='string' or row.text==''
            or #row.text>MAX_TEXT) then return nil end
    return {word=word,id=id,text=deleted and '' or row.text,
        dictionary=cleanDictionary(row.dictionary),
        updated_at=tonumber(row.updated_at) or 0,deleted=deleted,
        rank=tonumber(row.rank),rank_updated_at=tonumber(row.rank_updated_at) or 0}
end
-- Old versions stored one meaning directly at entries[word]. Convert it into
-- one stable legacy record, including a deletion tombstone, on first access.
local function bucketFor(word,create)
    local st=readStore()
    local value=st.entries[word]
    if type(value)=='table' and type(value.meanings)=='table' then return value.meanings end
    if type(value)=='table' then
        local legacy=validRecord(word,'legacy',value)
        local meanings=legacy and {legacy={text=legacy.text,
            dictionary=legacy.dictionary,updated_at=legacy.updated_at,
            deleted=legacy.deleted,rank=legacy.rank,
            rank_updated_at=legacy.rank_updated_at}} or {}
        st.entries[word]={meanings=meanings}
        return meanings
    end
    if create then
        local meanings={}
        st.entries[word]={meanings=meanings}
        return meanings
    end
    return nil
end
local function active(word)
    local key=cleanWord(word)
    local b=bucketFor(key,false)
    local result={}
    if b then for id,row in pairs(b) do
        local item=validRecord(key,id,row)
        if item and not item.deleted then result[#result+1]=item end
    end end
    table.sort(result,function(a,b)
        -- Prefer the user's exact per-meaning order, not dictionary priority.
        -- Older V1/V2 saves without a rank retain their former alphabetical order
        -- until the first explicit move.
        if a.rank and b.rank and a.rank~=b.rank then return a.rank<b.rank end
        if a.rank and not b.rank then return true end
        if b.rank and not a.rank then return false end
        local x,y=a.dictionary:lower(),b.dictionary:lower()
        if x~=y then return x<y end
        if a.updated_at~=b.updated_at then return a.updated_at<b.updated_at end
        return a.id<b.id
    end)
    return result
end
function M.list(word) return active(word) end
function M.get(word) return active(word)[1] end
function M.countForWord(word) return #active(word) end
function M.count()
    local n=0
    for word in pairs(readStore().entries) do
        if M.get(word) then n=n+1 end
    end
    return n
end
function M.countMeanings()
    local n=0
    for word in pairs(readStore().entries) do n=n+#active(word) end
    return n
end
local function nextTimestamp()
    local maxstamp=os.time()
    for word in pairs(readStore().entries) do
        local bucket=bucketFor(word,false)
        if bucket then for _,row in pairs(bucket) do
            if type(row)=='table' then
                maxstamp=math.max(maxstamp,tonumber(row.updated_at) or 0)
            end
        end end
    end
    return maxstamp+1
end
-- Stable hash makes saving the same selected text from the same dictionary
-- idempotent, even on two different devices. Different sources remain separate.
local function meaningId(dictionary,text)
    local input=dictionary:lower()..'\0'..text
    local a,b,c,d=1,0,5381,0
    for i=1,#input do
        local byte=input:byte(i)
        a=(a+byte)%65521
        b=(b+a)%65521
        c=(c*33+byte)%4294967296
        d=(d+byte*(i%97+1))%4294967296
    end
    return string.format('m%08x%08x%08x',b*65536+a,c,d)
end
function M.save(word,text,dictionary)
    local key=cleanWord(word)
    if key=='' then return false,'Missing card word.' end
    local selected,err=cleanText(text)
    if not selected then return false,err end
    local source=cleanDictionary(dictionary)
    local b=bucketFor(key,true)
    for id,row in pairs(b) do
        if type(row)=='table' and row.deleted~=true and row.text==selected
                and cleanDictionary(row.dictionary)==source then
            return true,id,false
        end
    end
    local id=meaningId(source,selected)
    -- A (rare) checksum collision must never overwrite another definition.
    if b[id] and (b[id].text~=selected or cleanDictionary(b[id].dictionary)~=source) then
        id=id..'_'..tostring(nextTimestamp())
    end
    local maxrank=0
    for _,row in pairs(b) do
        if type(row)=='table' and row.deleted~=true then
            maxrank=math.max(maxrank,tonumber(row.rank) or 0)
        end
    end
    local stamp=nextTimestamp()
    b[id]={text=selected,dictionary=source,updated_at=stamp,deleted=false,
        rank=maxrank>0 and maxrank+1 or nil,rank_updated_at=maxrank>0 and stamp or 0}
    persist()
    return true,id,true
end
function M.update(word,id,text)
    local key=cleanWord(word)
    local b=bucketFor(key,false)
    local old=b and validRecord(key,id,b[id])
    if not old or old.deleted then return false,'Meaning was not found.' end
    local clean,err=cleanText(text)
    if not clean then return false,err end
    b[id]={text=clean,dictionary=old.dictionary,updated_at=nextTimestamp(),deleted=false,
        rank=old.rank,rank_updated_at=old.rank_updated_at}
    persist()
    return true
end
function M.delete(word,id)
    local key=cleanWord(word)
    if key=='' then return false end
    local b=bucketFor(key,true)
    local stamp=nextTimestamp()
    if id then
        local row=b[id]
        if not row then return false end
        b[id]={text='',dictionary=cleanDictionary(row.dictionary),
            updated_at=stamp,deleted=true,rank=row.rank,rank_updated_at=row.rank_updated_at}
    else
        -- Delete all without losing per-record tombstones (cloud-safe).
        local any=false
        for recordid,row in pairs(b) do
            if type(row)=='table' and row.deleted~=true then
                stamp=stamp+1
                b[recordid]={text='',dictionary=cleanDictionary(row.dictionary),
                    updated_at=stamp,deleted=true,rank=row.rank,rank_updated_at=row.rank_updated_at}
                any=true
            end
        end
        if not any then return false end
    end
    persist()
    return true
end
-- Assign explicit rank only when the reader orders individual meanings.
-- This is deliberately independent of source dictionary; the popup never
-- reveals source names unless requested in edit metadata.
function M.move(word,id,delta)
    local key=cleanWord(word)
    local rows=active(key)
    local pos
    for i,row in ipairs(rows) do if row.id==id then pos=i;break end end
    if not pos then return false end
    local other=pos+(delta<0 and -1 or 1)
    if other<1 or other>#rows then return false end
    rows[pos],rows[other]=rows[other],rows[pos]
    local b=bucketFor(key,false)
    local stamp=nextTimestamp()
    for i,row in ipairs(rows) do
        b[row.id].rank=i
        b[row.id].rank_updated_at=stamp
    end
    persist()
    return true
end
function M.getPopupFont()
    return readStore().cfg:readSetting('popup_font_id') or 'default'
end
function M.setPopupFont(id)
    local st=readStore()
    st.cfg:saveSetting('popup_font_id',id or 'default')
    st.cfg:flush()
end
function M.getPopupFontSize()
    return tonumber(readStore().cfg:readSetting('popup_font_size')) or 21
end
function M.setPopupFontSize(size)
    local n=tonumber(size)
    if not n or n<14 or n>32 then return false end
    local st=readStore()
    st.cfg:saveSetting('popup_font_size',n)
    st.cfg:flush()
    return true
end

function M.arm(word)
    pending_word=cleanWord(word)
    arm_generation=arm_generation+1
    local token=arm_generation
    UIManager:scheduleIn(40,function()
        if token==arm_generation then pending_word=nil end
    end)
end
function M.disarm() pending_word=nil;arm_generation=arm_generation+1 end

local function edit(word,original,after,id,dictionary)
    local dialog
    dialog=InputDialog:new{
        title=(id and 'Edit meaning: ' or 'Add meaning: ')..tostring(word),
        input=original or '', input_hint='Dictionary definition',
        -- Use the same native full-screen multiline editor for the Aa menu
        -- and reading entry points as for the popup gear menu.
        fullscreen=true, condensed=true, allow_newline=true,
        add_nav_bar=true, cursor_at_end=false,
        buttons={{
            {text='Cancel',id='close',callback=function() UIManager:close(dialog) end},
            {text='Save',is_enter_default=true,callback=function()
                local value=dialog:getInputText()
                local ok,err
                if id then ok,err=M.update(word,id,value)
                else ok,err=M.save(word,value,dictionary or 'Manual') end
                if not ok then alert(err);return end
                UIManager:close(dialog)
                alert('Meaning saved.')
                if after then UIManager:nextTick(after) end
            end},
        }},
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end
M.edit=edit

-- Compact, meaning-first visual popup. UI and navigation are isolated in
-- their own module so the dictionary hooks remain unchanged.
function M.showPopup(word,openDictionary,frameProvider)
    if not M.get(word) then return false end
    return require('flipside_meanings_popup').open(M,word,openDictionary,nil,frameProvider)
end

-- Dictionary popups opened from FlipSide cards and books share the same
-- selection controls. The reading popup checkbox is book-only.
-- KOReader's HoldReleaseText ends in lookupDictionaryOrWikipedia(). Intercept
-- that method *on the individual popup*, not the global DictQuickLookup class.
-- Capture first, let the user inspect the selection, then save explicitly.
local BUTTON_ID='flipside_save_selected_meaning'
local MODE_BUTTON_ID='flipside_select_only_toggle'
local LOCK_ROW='dictionary_position_lock_v4'
local READING_POPUP_ID='flipside_reading_popup_toggle'

-- Store this UI preference locally. It must not change the contents of saved
-- definitions. ON captures text instead of starting a nested lookup.
function M.isSelectionOnly()
    return readStore().cfg:readSetting('dictionary_select_only') ~= false
end
function M.setSelectionOnly(enabled)
    local st=readStore()
    st.cfg:saveSetting('dictionary_select_only',enabled == true)
    st.cfg:flush()
end

-- Reading-only preference: keep disabled unless the reader explicitly opts in.
-- A saved meaning remains available in FlipSide regardless of this preference.
function M.isReadingPopupEnabled()
    return readStore().cfg:readSetting('reading_meaning_popup') == true
end
function M.setReadingPopupEnabled(enabled)
    local st=readStore()
    st.cfg:saveSetting('reading_meaning_popup',enabled == true)
    st.cfg:flush()
end

local function isReader(p)
    -- doc_settings distinguishes an open book from file-manager dictionary
    -- lookups; require a native ReaderDictionary for this book.
    return p and p.ui and p.ui.doc_settings and p.ui.dictionary
        and not p.is_wiki
end

local function notify(text)
    local ok,Notification=pcall(require,'ui/widget/notification')
    if ok and Notification then
        UIManager:show(Notification:new{text=text})
    else
        logger.info('FlipSide saved meanings: '..tostring(text))
    end
end

local function modeLabel()
    return M.isSelectionOnly() and 'ON' or 'OFF'
end
local function updateModeButton(p)
    local t=p and p.button_table
    if not t then return end
    local b=(t.getButtonById and t:getButtonById(MODE_BUTTON_ID)) or
            (t.button_by_id and t.button_by_id[MODE_BUTTON_ID])
    if not b then return end
    b:setText(modeLabel(),b.width)
    if b.refresh then pcall(b.refresh,b) end
    if UIManager.setDirty then
        UIManager:setDirty(p,function() return 'ui',t.dimen end)
    end
end

local function readingPopupLabel()
    return (M.isReadingPopupEnabled() and '☑ Popup' or '☐ Popup')
end
local function updateReadingPopupButton(p)
    local t=p and p.button_table
    if not t then return end
    local b=(t.getButtonById and t:getButtonById(READING_POPUP_ID)) or
        (t.button_by_id and t.button_by_id[READING_POPUP_ID])
    if not b then return end
    b:setText(readingPopupLabel(),b.width)
    if b.refresh then pcall(b.refresh,b) end
    if UIManager.setDirty then
        UIManager:setDirty(p,function() return 'ui',t.dimen end)
    end
end

-- Cancel a completed definition selection on the next ordinary tap while
-- selection-only is ON. Clear both the temporary Save candidate and KOReader's
-- native visual highlight. Do not affect swipes, hold selection, stored meanings,
-- or any off-mode interaction. The native clear method works for plain/HTML text.
local function clearPendingDefinitionSelection(p)
    if not p or not p._flipside_meaning_word or not M.isSelectionOnly() then return end
    local _,content
    if type(p._getScrollAndContentWidgets)=='function' then
        _,content=p:_getScrollAndContentWidgets()
    end
    local rectangles=content and content.highlight_rects
    local highlighted=type(rectangles)=='table' and #rectangles>0
    if not p._flipside_selected_meaning and not highlighted then return end
    p._flipside_selected_meaning=nil
    p._flipside_selected_dict=nil
    if type(p.clearDictionaryHighlight)=='function' then
        p:clearDictionaryHighlight()
    elseif content and type(content.scheduleClearHighlightAndRedraw)=='function' then
        content:scheduleClearHighlightAndRedraw()
    end
end

-- In selection-only mode, the *contents* of the dictionary are read-only
-- for taps. KOReader independently handles taps in ScrollTextWidget,
-- ScrollHtmlWidget, HtmlBoxWidget (links), and DictQuickLookup (next result).
-- Cover all three, on the individual popup only. No swipe/hold handlers are
-- replaced, so dragging to navigate and hold-pan-release selection remain native.
-- Never modify dictionary-wide tap preferences or the user's settings.
local function shieldDefinitionTaps(p)
    if not p or not p._flipside_meaning_word then return end
    local scroll, content
    if type(p._getScrollAndContentWidgets)=='function' then
        scroll,content=p:_getScrollAndContentWidgets()
    end
    if not scroll then
        scroll=p.is_html and p.shw_widget or p.stw_widget
    end
    if not content and scroll then
        content=scroll.htmlbox_widget or scroll.text_widget
    end
    if scroll and not scroll._flipside_tap_scroll_shield then
        local original=scroll.onTapScrollText
        if type(original)=='function' then
            scroll.onTapScrollText=function(widget,...)
                if M.isSelectionOnly() and p._flipside_meaning_word then
                    clearPendingDefinitionSelection(p)
                    return true
                end
                return original(widget,...)
            end
            scroll._flipside_tap_scroll_shield=true
        end
    end
    if content and not content._flipside_html_link_shield then
        local original=content.onTapText
        if type(original)=='function' then
            content.onTapText=function(widget,...)
                if M.isSelectionOnly() and p._flipside_meaning_word then
                    clearPendingDefinitionSelection(p)
                    return true  -- links cannot open or change the definition
                end
                return original(widget,...)
            end
            content._flipside_html_link_shield=true
        end
    end
end

local function shieldPopupTaps(p)
    if not p or not p._flipside_meaning_word then return end
    if not p._flipside_tap_fallback_shield then
        local originalTap=p.onTap
        if type(originalTap)=='function' then
            p.onTap=function(widget,arg,ges_ev,...)
                if M.isSelectionOnly() and widget._flipside_meaning_word then
                    -- Preserve KOReader's native outside-tap close for both
                    -- reading and FlipSide-card dictionaries. Inside taps stay
                    -- blocked in ON mode; hold selection and swipes are native.
                    if ges_ev and ges_ev.pos and widget.dict_frame
                            and widget.dict_frame.dimen
                            and ges_ev.pos:notIntersectWith(widget.dict_frame.dimen) then
                        return originalTap(widget,arg,ges_ev,...)
                    end
                    clearPendingDefinitionSelection(widget)
                    return true -- block taps inside the dictionary window
                end
                return originalTap(widget,arg,ges_ev,...)
            end
        end
        -- The native dictionary can replace a text scroll widget when moving
        -- between plain-text and HTML results. Shield newly created widgets.
        local originalUpdate=p.update
        if type(originalUpdate)=='function' then
            p.update=function(widget,...)
                local result=originalUpdate(widget,...)
                shieldDefinitionTaps(widget)
                return result
            end
        end
        p._flipside_tap_fallback_shield=true
    end
    shieldDefinitionTaps(p)
end

local function applySelectionMode(p)
    if not p or not p._flipside_meaning_word then return end
    local original=p._flipside_native_lookup
    if not original then
        original=p.lookupDictionaryOrWikipedia
        if type(original)~='function' then
            logger.warn('FlipSide meaning: no dictionary text selection handler')
            return
        end
        p._flipside_native_lookup=original
    end
    if M.isSelectionOnly() then
        -- There is NO save during selection. A hold/drag/release only stores a
        -- candidate; KOReader's nested dictionary search is not invoked.
        if not p._flipside_select_handler then
            p._flipside_select_handler=function(widget,text,...)
                local selected=cleanText(text)
                if selected then
                    widget._flipside_selected_meaning=selected
                    widget._flipside_selected_dict=tostring(widget.dictionary or '')
                    notify('Meaning selected. Tap Save.')
                end
                -- Even empty selection must not fall through to a lookup.
                return true
            end
        end
        p.lookupDictionaryOrWikipedia=p._flipside_select_handler
    else
        -- Restore standard KOReader selection/lookup, on this popup only.
        p.lookupDictionaryOrWikipedia=original
    end
end

local function saveSelected(p)
    if not p or not p._flipside_meaning_word then return true end
    local selected=p._flipside_selected_meaning
    if not selected then
        notify('Select a definition first, then tap Save.')
        return true
    end
    local ok,err=M.save(p._flipside_meaning_word, selected,
        p._flipside_selected_dict or p.dictionary)
    if not ok then notify(err);return true end
    p._flipside_selected_meaning=nil
    p._flipside_selected_dict=nil
    notify('Meaning saved. '..tostring(M.countForWord(p._flipside_meaning_word))..' total.')
    return true
end

local function attachPopup(p)
    if not p or p.is_wiki then return false end
    if not p._flipside_meaning_word then
        local actual=cleanWord(p.word or p.lookupword)
        if pending_word then
            -- A FlipSide card explicitly armed this lookup.
            if actual~='' and actual~=pending_word then return false end
            p._flipside_meaning_word=pending_word
            p._flipside_meaning_context='card'
            pending_word=nil
            arm_generation=arm_generation+1
        elseif isReader(p) and actual~='' then
            -- Ordinary book reading, including dictionary lookups before the
            -- word has been added to vocabulary. Avoid changing FM lookups.
            p._flipside_meaning_word=actual
            p._flipside_meaning_context='reading'
            -- Nested dictionary windows inherit the original context, so a
            -- card lookup does not suddenly gain reading-only preferences.
            local ok,Dict=pcall(require,'ui/widget/dictquicklookup')
            local windows=ok and Dict.window_list or nil
            if type(windows)=='table' then
                for i=#windows,1,-1 do
                    local parent=windows[i]
                    if parent~=p and parent._flipside_meaning_context then
                        p._flipside_meaning_context=parent._flipside_meaning_context
                        break
                    end
                end
            end
        else
            return false
        end
    end
    applySelectionMode(p)
    shieldPopupTaps(p)
    return true
end

-- The reading popup check is intentionally absent from FlipSide card lookups.
local function attachReadingPopup(p)
    return attachPopup(p) and p._flipside_meaning_context=='reading'
end

-- Route ordinary reading lookups to a saved meaning if opted in. This hook
-- runs *before* the expensive dictionary search, and only for top-level book
-- word lookups. Explicit Dictionary in the popup bypasses the hook once.
local function installReadingLookupRouter(dict)
    if dict._flipside_reading_meaning_router then return end
    local original=dict.onLookupWord
    if type(original)~='function' then return end
    local bypass=false
    local unpack_args=unpack or table.unpack
    dict.onLookupWord=function(reader, word, ...)
        local count=select('#',...)
        local args={...}
        -- No interception in flashcard lookups, file manager, nested lookup
        -- windows, or when the preference is disabled.
        if bypass or pending_word or not M.isReadingPopupEnabled()
                or not reader.ui or not reader.ui.doc_settings then
            return original(reader,word,unpack_args(args,1,count))
        end
        local ok,Dict=pcall(require,'ui/widget/dictquicklookup')
        if ok and Dict and type(Dict.window_list)=='table'
                and #Dict.window_list>0 then
            return original(reader,word,unpack_args(args,1,count))
        end
        local key=cleanWord(word)
        local saved=M.get(key)
        if not saved then
            return original(reader,word,unpack_args(args,1,count))
        end
        local opened=M.showPopup(key,function()
            bypass=true
            local success,err=pcall(original,reader,word,unpack_args(args,1,count))
            bypass=false
            if not success then logger.warn('FlipSide reading dictionary:',err) end
        end)
        if opened then return true end
        return original(reader,word,unpack_args(args,1,count))
    end
    dict._flipside_reading_meaning_router=true
end

function M.registerDictionaryButton(dict)
    if not dict or type(dict.addToDictButtons)~='function' then return false end
    installReadingLookupRouter(dict)
    if dict._flipside_save_meaning_button_registered then return true end
    local specs={
        {
            id=BUTTON_ID,
            conditional=true,
            row_group=LOCK_ROW,
            text='Save',
            show_func=attachPopup,
            callback=saveSelected,
            hold_callback=function(p)
                if p._flipside_meaning_word then
                    M.showPopup(p._flipside_meaning_word)
                end
            end,
        },
        {
            id=MODE_BUTTON_ID,
            conditional=true,
            row_group=LOCK_ROW,
            text_func=modeLabel,
            show_func=attachPopup,
            callback=function(p)
                M.setSelectionOnly(not M.isSelectionOnly())
                applySelectionMode(p)
                shieldPopupTaps(p)
                updateModeButton(p)
            end,
        },
        {
            id=READING_POPUP_ID,
            conditional=true,
            row_group=LOCK_ROW,
            text_func=readingPopupLabel,
            show_func=attachReadingPopup,
            callback=function(p)
                M.setReadingPopupEnabled(not M.isReadingPopupEnabled())
                updateReadingPopupButton(p)
            end,
        },
    }
    for _,spec in ipairs(specs) do
        local ok,err=pcall(dict.addToDictButtons,dict,spec)
        if not ok then
            logger.warn('FlipSide saved meaning: button registration failed:',err)
            return false
        end
    end
    dict._flipside_save_meaning_button_registered=true
    return true
end

-- Cloud snapshots include every saved meaning and individual tombstones.
-- V2 uses a new filename. It can import the old V1 remote file once; both
-- devices must run the updated plugin to exchange multiple meanings.
local function encode(s)
    return (tostring(s or ''):gsub('([^%w%-%._~])',function(c)
        return string.format('%%%02X',c:byte())
    end))
end
local function decode(s)
    if s:gsub('%%[%x][%x]',''):find('%%',1,true) then
        error('Invalid saved meaning encoding')
    end
    return (s:gsub('%%(%x%x)',function(c) return string.char(tonumber(c,16)) end))
end
local function rowLine(r)
    return table.concat({encode(r.word),encode(r.id),encode(r.text),
        encode(r.dictionary),tostring(r.updated_at),r.deleted and '1' or '0',
        r.rank and tostring(r.rank) or '',tostring(r.rank_updated_at or 0)},'\t')
end
local function prefer(a,b)
    if not a then return b end
    local winner
    if b.updated_at~=a.updated_at then
        winner=b.updated_at>a.updated_at and b or a
    elseif b.deleted~=a.deleted then
        winner=b.deleted and b or a
    else
        -- Same content timestamp: deterministic tie breaker.
        local ta=(a.text or '')..'\0'..(a.dictionary or '')
        local tb=(b.text or '')..'\0'..(b.dictionary or '')
        winner=tb>ta and b or a
    end
    -- A change to priority must not undo a newer meaning edit (or vice versa).
    local pa=tonumber(a.rank_updated_at) or 0
    local pb=tonumber(b.rank_updated_at) or 0
    local priority=(pb>pa and b) or (pa>pb and a)
        or ((tonumber(b.rank) or 0) > (tonumber(a.rank) or 0) and b or a)
    winner.rank=priority.rank
    winner.rank_updated_at=priority.rank_updated_at
    return winner
end
local function mapKey(word,id) return word..'\0'..id end
local function localMap()
    local map={}
    for word in pairs(readStore().entries) do
        local b=bucketFor(word,false)
        if b then for id,row in pairs(b) do
            local item=validRecord(word,id,row)
            if item then
                local key=mapKey(word,id)
                map[key]=prefer(map[key],item)
            end
        end end
    end
    return map
end
local function saveMap(map)
    local st=readStore()
    for _,row in pairs(map) do
        local b=bucketFor(row.word,true)
        b[row.id]={text=row.text,dictionary=row.dictionary,
            updated_at=row.updated_at,deleted=row.deleted,
            rank=row.rank,rank_updated_at=row.rank_updated_at}
    end
    persist()
end
local function merge(a,b)
    local result={}
    for key,row in pairs(a) do result[key]=row end
    for key,row in pairs(b) do result[key]=prefer(result[key],row) end
    return result
end
local function writeSnapshot(map)
    local temp=SNAPSHOT..'.writing'
    local f=assert(io.open(temp,'wb'))
    local ok,err=pcall(function()
        assert(f:write(HEADER,'\n'))
        local keys={}
        for key in pairs(map) do keys[#keys+1]=key end
        table.sort(keys)
        for _,key in ipairs(keys) do assert(f:write(rowLine(map[key]),'\n')) end
        assert(f:flush())
    end)
    f:close()
    if not ok then os.remove(temp);error(err) end
    local renamed,reason=os.rename(temp,SNAPSHOT)
    if not renamed then os.remove(temp);error(reason or 'Unable to save meaning snapshot') end
end
local function readSnapshot(path)
    local f=assert(io.open(path,'rb'))
    local data=f:read(MAX_SNAPSHOT+1) or ''
    f:close()
    if #data>MAX_SNAPSHOT then error('Cloud saved meanings snapshot is too large') end
    local header=data:match('^([^\r\n]*)')
    if header~=HEADER and header~=PREVIOUS_HEADER and header~=LEGACY_HEADER then
        error('Invalid FlipSide saved meanings snapshot')
    end
    local map={}
    local linecount=0
    for line in data:gmatch('[^\r\n]+') do
        if line~=header then
            linecount=linecount+1
            if linecount>200000 then error('Too many saved meanings') end
            local cols={}
            for cell in (line..'\t'):gmatch('(.-)\t') do cols[#cols+1]=cell end
            local legacy=header==LEGACY_HEADER
            local previous=header==PREVIOUS_HEADER
            if #cols~=(legacy and 5 or previous and 6 or 8) then
                error('Invalid meaning record columns')
            end
            local word=cleanWord(decode(cols[1]))
            local id=legacy and 'legacy' or decode(cols[2])
            local stamp=tonumber(cols[legacy and 4 or 5])
            local flag=cols[legacy and 5 or 6]
            local savedText=decode(cols[legacy and 2 or 3])
            local dictionary=decode(cols[legacy and 3 or 4])
            if word=='' or #word>2048 or id=='' or #id>128 or not stamp
                    or stamp<0 or (flag~='0' and flag~='1') or
                    #savedText>MAX_TEXT or #dictionary>512 then
                error('Invalid saved meaning record')
            end
            local rank=(not legacy and not previous and cols[7]~='')
                and tonumber(cols[7]) or nil
            local rankstamp=(not legacy and not previous) and tonumber(cols[8]) or 0
            if rank and (rank<1 or rank>200000) then error('Invalid meaning rank') end
            if not rankstamp or rankstamp<0 then error('Invalid rank timestamp') end
            local row=validRecord(word,id,{text=savedText,dictionary=dictionary,
                updated_at=stamp,deleted=flag=='1',rank=rank,
                rank_updated_at=rankstamp})
            if not row then error('Invalid saved meaning data') end
            local key=mapKey(word,id)
            map[key]=prefer(map[key],row)
        end
    end
    return map
end
local function getCloud(ui)
    if ui and ui.cloudstorage and type(ui.cloudstorage.providers)=='table' then
        return ui.cloudstorage
    end
    local ok,loader=pcall(require,'pluginloader')
    if ok and loader and loader.getPluginInstance then
        local found,cloud=pcall(loader.getPluginInstance,loader,'cloudstorage')
        if found and cloud and type(cloud.providers)=='table' then return cloud end
    end
end
function M.getFolder()
    return require('flipside_dictionary_locks').getFolder()
end
function M.syncNow(plugin,done)
    local function fail(err)
        if done then done(false,tostring(err)) else alert(tostring(err)) end
        return true
    end
    if syncing then return fail('Saved meanings sync already in progress') end
    local folder=M.getFolder()
    if type(folder)~='table' or not folder.type or not folder.url then
        return fail('Configure Dictionary cloud folder in Aa > Sync settings first')
    end
    local cloud=getCloud(plugin and plugin.ui)
    local provider=cloud and cloud.providers[folder.type]
    if not provider or type(provider.run)~='function' or
            type(provider.downloadFile)~='function' or type(provider.uploadFile)~='function' then
        return fail('KOReader Cloud Storage provider unavailable')
    end
    local remote=folder.url:gsub('/+$','')..'/'..SNAPSHOT:match('[^/]+$')
    local previousRemote=folder.url:gsub('/+$','')..'/'..PREVIOUS_SNAPSHOT:match('[^/]+$')
    local legacyRemote=folder.url:gsub('/+$','')..'/'..LEGACY_SNAPSHOT:match('[^/]+$')
    syncing=true
    provider.base=util.tableDeepCopy(folder)
    local runok,runerr=pcall(provider.run,function()
        UIManager:nextTick(function()
            local ok,result=pcall(function()
                for attempt=1,4 do
                    local target=SNAPSHOT..'.incoming'
                    os.remove(target)
                    local code,etag=provider.downloadFile(remote,target)
                    local incoming={}
                    if code==200 then
                        incoming=readSnapshot(target)
                    elseif code==404 or (folder.type=='ftp' and code==550) then
                        -- First V3 sync: import V2, or V1 if V2 was absent.
                        local previousFile=PREVIOUS_SNAPSHOT..'.incoming'
                        os.remove(previousFile)
                        local previousCode=provider.downloadFile(previousRemote,previousFile)
                        if previousCode==200 then
                            incoming=readSnapshot(previousFile)
                        elseif previousCode==404 or (folder.type=='ftp' and previousCode==550) then
                            local legacyFile=LEGACY_SNAPSHOT..'.incoming'
                            os.remove(legacyFile)
                            local oldCode=provider.downloadFile(legacyRemote,legacyFile)
                            if oldCode==200 then incoming=readSnapshot(legacyFile)
                            elseif oldCode~=404 and not (folder.type=='ftp' and oldCode==550) then
                                os.remove(legacyFile)
                                error('Legacy meanings download HTTP '..tostring(oldCode))
                            end
                            os.remove(legacyFile)
                        else
                            os.remove(previousFile)
                            error('V2 meanings download HTTP '..tostring(previousCode))
                        end
                        os.remove(previousFile)
                    elseif code==409 and folder.type=='dropbox' then
                        local f=io.open(target,'rb')
                        local body=f and f:read(8192) or ''
                        if f then f:close() end
                        if not body:match('"error_summary"%s*:%s*"path/not_found') then
                            error('Dropbox error 409; upload canceled')
                        end
                    else
                        error('Saved meanings download HTTP '..tostring(code)..'; upload canceled')
                    end
                    os.remove(target)
                    local merged=merge(localMap(),incoming)
                    writeSnapshot(merged)
                    local uploaded=provider.uploadFile(folder.url,SNAPSHOT,etag,true)
                    if type(uploaded)=='number' and uploaded>=200 and uploaded<300 then
                        saveMap(merged)
                        local count=0
                        for _,row in pairs(merged) do if not row.deleted then count=count+1 end end
                        return tostring(count)..' meanings synced'
                    end
                    if uploaded~=412 then
                        error('Saved meanings upload HTTP '..tostring(uploaded))
                    end
                end
                error('Saved meanings changed during sync; try again')
            end)
            syncing=false
            os.remove(SNAPSHOT..'.incoming')
            os.remove(LEGACY_SNAPSHOT..'.incoming')
            os.remove(PREVIOUS_SNAPSHOT..'.incoming')
            if done then done(ok,tostring(result))
            else alert(ok and 'Saved meanings synchronized.' or tostring(result)) end
        end)
    end)
    if not runok then syncing=false;return fail(runerr) end
    return true
end

-- Hide the two manual-add controls only in dictionary popups opened from
-- FlipSide cards. Keep both buttons during ordinary book reading. Do not
-- unregister plugins or rewrite dict_button_config.
do
    local ok,DictQuickLookup=pcall(require,'ui/widget/dictquicklookup')
    if ok and DictQuickLookup and not DictQuickLookup._flipside_selection_tap_shields_v1 then
        DictQuickLookup._flipside_selection_tap_shields_v1=true
        local nativeBuild=DictQuickLookup.buildButtonLayout
        if type(nativeBuild)=='function' then
            DictQuickLookup.buildButtonLayout=function(p,...)
                local rows=nativeBuild(p,...)
                if not p.is_wiki and p._flipside_meaning_context=='card'
                        and type(rows)=='table' then
                    for i=#rows,1,-1 do
                        local row=rows[i]
                        if type(row)=='table' then
                            for j=#row,1,-1 do
                                local button=row[j]
                                local id=type(button)=='table' and button.id
                                if id=='vocabulary' or id=='flipside' then
                                    table.remove(row,j)
                                end
                            end
                            if #row==0 then table.remove(rows,i) end
                        end
                    end
                end
                return rows
            end
        end
        -- onShow is called after the scroll widgets have been initialized.
        -- Other plugins may have already wrapped onShow; preserve their chain.
        local nativeShow=DictQuickLookup.onShow
        DictQuickLookup.onShow=function(p,...)
            local result
            if nativeShow then result=nativeShow(p,...) end
            if p._flipside_meaning_word and not p.is_wiki then
                shieldPopupTaps(p)
            end
            return result
        end
    end
end

return M
