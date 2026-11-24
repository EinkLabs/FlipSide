-- FlipSide saved meanings: uncluttered, theme-aware single-meaning carousel.
-- All controls use the one saved popup font, across all words and settings.
-- The saved-meaning viewer keeps the underlying card frame visible.
-- Other meaning dialogs retain their existing card-covering backdrop.
local Blitbuffer = require('ffi/blitbuffer')
local ButtonDialog = require('ui/widget/buttondialog')
local Button = require('ui/widget/button')
local Menu = require('ui/widget/menu')
local Font = require('ui/font')
local TextWidget = require('ui/widget/textwidget')
local TextBoxWidget = require('ui/widget/textboxwidget')
local ScrollTextWidget = require('ui/widget/scrolltextwidget')
local InputDialog = require('ui/widget/inputdialog')
local VerticalGroup = require('ui/widget/verticalgroup')
local HorizontalGroup = require('ui/widget/horizontalgroup')
local HorizontalSpan = require('ui/widget/horizontalspan')
local VerticalSpan = require('ui/widget/verticalspan')
local CenterContainer = require('ui/widget/container/centercontainer')
local Widget = require('ui/widget/widget')
local Geom = require('ui/geometry')
local GestureRange = require('ui/gesturerange')
local Size = require('ui/size')
local Screen = require('device').screen
local UIManager = require('ui/uimanager')
local ConfirmBox = require('ui/widget/confirmbox')
local FontPicker = require('flipside_font_picker')
local logger = require('logger')
local M = {}

local function gap(px) return VerticalSpan:new{width=math.max(0,math.floor(px))} end
local function snippet(str, limit)
    local s=tostring(str or ''):gsub('%s+', ' ')
    local chars=require('util').splitToChars(s)
    if #chars<=limit then return s end
    local out={}
    for i=1,limit-1 do out[i]=chars[i] end
    return table.concat(out)..'…'
end
local function fontKey(store)
    local id=store.getPopupFont()
    if id and id~='default' then
        return FontPicker.renderable(id) or 'cfont'
    end
    return 'cfont'
end
local function face(store, size)
    local key=fontKey(store)
    local ok, f=pcall(Font.getFace,Font,key,size or store.getPopupFontSize())
    if ok and f then return f end
    return Font:getFace('cfont',size or store.getPopupFontSize())
end

-- Meaning dialogs have a local, non-interactive backing layer. The saved
-- definition viewer leaves the card untouched; its submenus continue to
-- cover the measured card content and ornamental frame as before.
local LocalBackdrop = Widget:extend{}
function LocalBackdrop:getSize() return Screen:getSize() end
-- Cover the *actual* card content area, not only the decorative frame.
-- Flashcards already exposes this measured region for its floating menus;
-- unlike the frame, it also exists for Default cards without a border.
-- During reading (no active flashcard) this returns nil and changes nothing.
local function activeCardContentRect()
    local api = package.loaded['flipside_flashcards_menu_api']
    if type(api) ~= 'table' or type(api.getMenuSafeBounds) ~= 'function' then
        return nil
    end
    local ok, rect = pcall(api.getMenuSafeBounds)
    return ok and rect or nil
end
local function paintClippedBox(bb, x, y, rect, inset)
    if type(rect) ~= 'table' or not rect.x or not rect.y
            or not rect.w or not rect.h then return end
    local sw,sh=Screen:getWidth(),Screen:getHeight()
    local left=math.max(0,math.floor(rect.x)-inset)
    local top=math.max(0,math.floor(rect.y)-inset)
    local right=math.min(sw,math.ceil(rect.x+rect.w)+inset)
    local bottom=math.min(sh,math.ceil(rect.y+rect.h)+inset)
    if right>left and bottom>top then
        bb:paintRect(x+left,y+top,right-left,bottom-top,Blitbuffer.COLOR_WHITE)
    end
end
function LocalBackdrop:paintTo(bb,x,y)
    local sw,sh=Screen:getWidth(),Screen:getHeight()
    self.dimen=Geom:new{x=x,y=y,w=sw,h=sh}
    -- Only the saved-meaning viewer leaves the underlying card/frame intact.
    -- All other meaning dialogs retain their existing opaque backdrop.
    if not self.show_card_behind then
        local card_rect = activeCardContentRect()
        if card_rect then
            paintClippedBox(bb,x,y,card_rect,0)
        end
        if self.frame_provider then
            local ok,frame=pcall(self.frame_provider)
            if ok and frame then
                paintClippedBox(bb,x,y,frame,math.max(3,Screen:scaleBySize(9)))
            end
        end
        if self.box then paintClippedBox(bb,x,y,self.box,0) end
    end
end
function LocalBackdrop:onShow() UIManager:setDirty('all','ui') end
function LocalBackdrop:onCloseWidget() UIManager:setDirty('all','ui') end

-- Keep the popup fixed: KOReader's ButtonDialog is movable by default.
-- Disable only its own reposition gestures; embedded text scrolling and
-- button gestures remain untouched. For changing definitions, preserve the
-- initial top edge as long as there is physical space on the display.
local function pinDialog(dialog,fixed_top)
    local movable=dialog and dialog.movable
    if not movable then return nil end
    movable.unmovable=true
    movable.is_movable_with_keys=false
    movable.ges_events={}
    if movable.key_events then
        movable.key_events.MovePositionTop=nil
        movable.key_events.MovePositionBottom=nil
    end
    local inner=movable[1]
    local dims=inner and inner:getSize()
    if not dims or not dims.h then return nil end
    local sh=Screen:getHeight()
    local natural_y=math.floor((sh-dims.h)/2)
    local y=math.max(0,math.min(fixed_top or natural_y,sh-dims.h))
    if movable.setMovedOffset then
        movable:setMovedOffset(Geom:new{x=0,y=y-natural_y})
    end
    return y
end

function M.open(store, word, openDictionary, startInOptions, frame_provider)
    local state={position=1,popup=nil,shield=nil,dialog=nil,closed=false,
                 selected=nil,list_offset=nil,fixed_top=nil,navigating=false}
    local render,options,prioritize,editList,fontPicker,fontSizeMenu

    local function removePopup()
        if state.popup then
            local old=state.popup
            state.popup=nil
            UIManager:close(old)
        end
    end
    local function removeDialog()
        if state.dialog then
            local old=state.dialog
            state.dialog=nil
            UIManager:close(old)
        end
    end
    local function finish()
        if state.closed then return end
        state.closed=true
        removeDialog()
        removePopup()
        if state.shield then
            UIManager:close(state.shield)
            state.shield=nil
        end
        UIManager:setDirty('all','ui')
    end
    local function currentId()
        local row=store.list(word)[state.position]
        return row and row.id
    end
    local function focusId(id)
        if not id then return end
        for i,row in ipairs(store.list(word)) do
            if row.id==id then state.position=i;return end
        end
    end
    local function refresh(id)
        if state.closed then return end
        if id then focusId(id) end
        if #store.list(word)==0 then finish();return end
        UIManager:nextTick(render)
    end
    local function ensureShield()
        if not state.shield then
            state.shield=LocalBackdrop:new{
                dimen=Screen:getSize(),frame_provider=frame_provider,
            }
            UIManager:show(state.shield)
        end
    end
    local function shieldFor(dialog)
        ensureShield()
        local widget=dialog and dialog.movable and dialog.movable[1]
        local sz=widget and widget:getSize()
        if not sz or not sz.w or not sz.h then
            state.shield.box=nil -- Native fullscreen editors paint their own backing.
            return
        end
        local sw,sh=Screen:getWidth(),Screen:getHeight()
        local pad=math.max(0,Screen:scaleBySize(2))
        local offset=dialog.movable and dialog.movable._moved_offset_y or 0
        local w=math.min(sw,sz.w+2*pad)
        local h=math.min(sh,sz.h+2*pad)
        local previous_box=state.shield.box
        local next_box={x=math.floor((sw-w)/2),
            y=math.floor((sh-sz.h)/2)+offset-pad,w=w,h=h}
        state.shield.box=next_box
        if state.navigating and previous_box then
            -- The close & reopen cycle should touch only the union of both
            -- meaning rectangles, not repaint the entire Kindle screen.
            -- The underlying card and shield are repainted inside this small
            -- region, cleaning up ink from a longer previous definition.
            local x=math.max(0,math.min(previous_box.x,next_box.x))
            local y=math.max(0,math.min(previous_box.y,next_box.y))
            local r=math.min(sw,math.max(previous_box.x+previous_box.w,next_box.x+next_box.w))
            local b=math.min(sh,math.max(previous_box.y+previous_box.h,next_box.y+next_box.h))
            if r>x and b>y then
                UIManager:setDirty('all','ui',Geom:new{x=x,y=y,w=r-x,h=b-y})
            end
        else
            UIManager:setDirty('all','ui')
        end
    end
    -- Compact menu using ButtonDialog rows instead of the fullscreen Menu.
    -- ButtonTable exposes per-item font_face: unlike Menu's internal
    -- smallinfofont, this respects the user's global saved popup font.
    local function showRows(title, entries, onChoose, onBack, opts)
        if state.closed then return end
        removeDialog()
        removePopup()
        ensureShield()
        state.shield.show_card_behind=false
        local rows={}
        local size=math.min(26,math.max(16,store.getPopupFontSize()))
        local key=fontKey(store)
        if onBack then
            rows[#rows+1]={{
                text='‹  Back',font_face=key,font_size=size,
                font_bold=true,align='left',
                callback=function()
                    removeDialog()
                    UIManager:nextTick(onBack)
                end,
            }}
        end
        for _,entry in ipairs(entries) do
            local e=entry
            rows[#rows+1]={{
                text=e.text or '', font_face=key,font_size=size,
                font_bold=e.bold==true, align='left',
                enabled=e.enabled~=false,
                callback=function()
                    if opts and opts.remember_scroll and state.dialog and state.dialog.getScrolledOffset then
                        local ok,offset=pcall(state.dialog.getScrolledOffset,state.dialog)
                        if ok and offset then state.list_offset=offset end
                    end
                    local old=state.dialog
                    -- Closing the old dialog explicitly does NOT invoke its
                    -- outside-tap handler (which is reserved for backing out).
                    state.dialog=nil
                    if old then UIManager:close(old) end
                    if onChoose then onChoose(e) end
                end,
            }}
        end
        -- Native bold heading, using the same global meaning font as rows.
        -- ButtonDialog's built-in title only accepts a face, not a bold flag.
        -- The supported _added_widgets title slot lets us use TextBoxWidget
        -- with bold=true without changing the user's chosen font family.
        local dialog_width=math.floor(Screen:getWidth()*.91)
        local heading_width=math.max(1,dialog_width
            -2*Size.border.window-2*Size.padding.button
            -2*(Size.padding.default+Size.margin.default))
        local heading=TextBoxWidget:new{
            text=title,width=heading_width,
            face=face(store,math.min(25,size)),
            bold=true,alignment='left',not_focusable=true,
        }
        local dlg
        dlg=ButtonDialog:new{
            width=dialog_width,
            _added_widgets={heading},
            info_face=face(store,math.min(25,size)),
            buttons=rows, use_info_style=true,
            dismissable=true,
            tap_close_callback=function()
                if state.dialog==dlg then state.dialog=nil end
                if onBack then UIManager:nextTick(onBack) else finish() end
            end,
        }
        -- Native ButtonDialog:close requests flashui. Keep the meaning
        -- picker/priority/options transitions nonflashing as well.
        dlg.onCloseWidget=function(self)
            UIManager:setDirty(nil,function() return 'ui',self.movable.dimen end)
        end
        state.dialog=dlg
        pinDialog(dlg)
        shieldFor(dlg)
        UIManager:show(dlg)
        if opts and opts.offset and dlg.setScrolledOffset then
            pcall(dlg.setScrolledOffset,dlg,opts.offset)
        end
    end
    local function dictionary()
        finish()
        if not openDictionary then return end
        -- KOReader's dictionary close callback runs after its window closes.
        -- Reopen only the Meaning options screen that launched this lookup.
        -- This does not affect other dictionary windows or the card itself.
        UIManager:nextTick(function()
            local returned=false
            openDictionary(function()
                if returned then return end
                returned=true
                UIManager:nextTick(function()
                    if store.get(word) then
                        M.open(store,word,openDictionary,true,frame_provider)
                    end
                end)
            end)
        end)
    end
    local function navigate(step)
        if state.closed then return end
        local list=store.list(word)
        if #list==0 then finish();return end
        if #list==1 then return end
        local next_position=state.position+step
        if next_position<1 or next_position>#list then return end
        state.position=next_position
        -- Only this meaning-to-meaning transition suppresses KOReader's
        -- ButtonDialog flashui close. Exiting/other dialogs behave normally.
        state.navigating=true
        local ok,err=pcall(render)
        state.navigating=false
        if not ok then error(err) end
    end

    -- A multiline native editor, not a one-line/compact input popup.
    local function editor(row,returnTo)
        if state.closed then return end
        removeDialog()
        removePopup()
        ensureShield()
        state.shield.box=nil
        local dlg
        local returned=false
        local function returnScreen(id)
            if returned then return end
            returned=true
            UIManager:nextTick(function()
                if state.closed then return end
                if id then focusId(id) end
                if returnTo then returnTo() else refresh(id) end
            end)
        end
        local buttons={{
            {text='Cancel',id='close',callback=function()
                UIManager:close(dlg)
                returnScreen(row and row.id)
            end},
            {text='Save',is_enter_default=true,callback=function()
                local text=dlg:getInputText()
                local ok,err,id
                if row then
                    ok,err=store.update(word,row.id,text)
                    id=row.id
                else
                    ok,id=store.save(word,text,'Manual')
                    if not ok then err=id end
                end
                if not ok then
                    UIManager:show(require('ui/widget/infomessage'):new{text=tostring(err),timeout=4})
                    return
                end
                UIManager:close(dlg)
                returnScreen(id)
            end},
        }}
        if row then
            -- Individual deletion belongs to the edit workflow, not to the
            -- clean carousel's primary menu.
            table.insert(buttons[1],2,{text='Delete',callback=function()
                UIManager:show(ConfirmBox:new{
                    text='Delete this saved meaning?',ok_text='Delete',
                    ok_callback=function()
                        store.delete(word,row.id)
                        UIManager:close(dlg)
                        returnScreen(nil)
                    end,
                })
            end})
        end
        dlg=InputDialog:new{
            title=(row and 'Edit meaning' or 'Add meaning')..' — '..tostring(word),
            input=row and row.text or '',
            input_hint='Definition',
            fullscreen=true,condensed=true,allow_newline=true,
            add_nav_bar=true,cursor_at_end=false,
            buttons=buttons,
            -- This screen is a native fullscreen editor. No extra blanking.
            close_callback=function()
                if not state.closed then returnScreen(row and row.id) end
            end,
        }
        -- KOReader's fullscreen InputDialog:onCloseWidget explicitly asks
        -- for a full-screen flash. Match its cleanup/onClose behavior, but
        -- redraw as ordinary UI for this one FlipSide meaning editor only.
        dlg.onCloseWidget=function(self)
            self:onClose()
            UIManager:setDirty(nil,'ui')
        end
        UIManager:show(dlg)
        if dlg.onShowKeyboard then dlg:onShowKeyboard() end
    end

    -- Direct selection, with controls always accessible. Small pages avoid
    -- having to scroll through 31 dictionaries just to reach Move up/down.
    -- Every row is one saved meaning, never a dictionary/source.
    prioritize=function()
        local rows=store.list(word)
        if #rows==0 then finish();return end
        local position
        for i,row in ipairs(rows) do
            if row.id==state.selected then position=i;break end
        end
        if not position then
            state.selected=rows[1].id
            position=1
        end
        local perpage=(Screen:getHeight()<900) and 3 or 5
        local pages=math.ceil(#rows/perpage)
        if not state.priority_page then state.priority_page=math.ceil(position/perpage) end
        state.priority_page=math.max(1,math.min(pages,state.priority_page))
        local page=state.priority_page
        local items={
            {text='↑  Move selected up',action='up',bold=true,enabled=position>1},
            {text='↓  Move selected down',action='down',bold=true,enabled=position<#rows},
        }
        local first=(page-1)*perpage+1
        for index=first,math.min(#rows,first+perpage-1) do
            local row=rows[index]
            items[#items+1]={
                text=(row.id==state.selected and '●  ' or '○  ')..
                    tostring(index)..'. '..snippet(row.text,75),
                id=row.id,bold=row.id==state.selected,
            }
        end
        if pages>1 then
            items[#items+1]={text='‹  Previous ('..page..'/'..pages..')',action='prev',enabled=page>1}
            items[#items+1]={text='Next ('..page..'/'..pages..')  ›',action='next',enabled=page<pages}
        end
        items[#items+1]={text='Done',action='done',bold=true}
        showRows('Prioritize meanings',items,function(choice)
            if choice.action=='done' then state.priority_page=nil;options();return end
            if choice.id then
                state.selected=choice.id
            elseif choice.action=='prev' then
                state.priority_page=math.max(1,page-1)
            elseif choice.action=='next' then
                state.priority_page=math.min(pages,page+1)
            elseif choice.action=='up' or choice.action=='down' then
                store.move(word,state.selected,choice.action=='up' and -1 or 1)
                local ordered=store.list(word)
                for i,row in ipairs(ordered) do
                    if row.id==state.selected then
                        state.priority_page=math.ceil(i/perpage)
                        break
                    end
                end
            end
            prioritize()
        end,function()state.priority_page=nil;options() end)
    end

    editList=function()
        local rows=store.list(word)
        if #rows==0 then refresh(nil);return end
        local entries={}
        for i,row in ipairs(rows) do
            entries[#entries+1]={text=tostring(i)..'. '..snippet(row.text,90),id=row.id}
        end
        entries[#entries+1]={text='Delete ALL',action='delete_all',bold=true}
        showRows('Edit meanings',entries,function(item)
            if item.action=='back' then options();return end
            if item.action=='delete_all' then
                UIManager:show(ConfirmBox:new{
                    text='Permanently delete ALL saved meanings for '..tostring(word)..'?',
                    ok_text='Delete ALL',
                    ok_callback=function() store.delete(word);finish() end,
                })
                return
            end
            if item.id then
                for _,row in ipairs(store.list(word)) do
                    if row.id==item.id then editor(row,editList);return end
                end
            end
        end,options)
    end

    fontPicker=function()
        -- This is a global preference, persisted by the meanings store and
        -- used for every word's popup, the options, priority, and edit lists.
        -- Reuse the plugin's original font picker under koreader/fonts.
        showRows('Font',{
            {text='KOReader default',action='default'},
            {text='Choose from my fonts',action='picker'},
        },function(item)
            if item.action=='default' then
                store.setPopupFont('default')
                options()
            elseif item.action=='picker' then
                -- Unlike an ordinary menu, FontPicker creates its own menu
                -- and may be dismissed without choosing a font. Release our
                -- backing layer before handing UI control over to it.
                finish()
                local ok,result=pcall(function()
                    return FontPicker.open(nil,store.getPopupFont(),function(opts)
                        -- The font chooser has its own Done button, and the
                        -- Android/Kindle Back key can also dismiss it. In both
                        -- cases return to the meaning settings, not the book.
                        local handled=false
                        local old_select=opts.onMenuSelect
                        opts.onMenuSelect=function(menu,item)
                            if item and (item.font_id or item.is_done) then
                                handled=true
                            end
                            local response=old_select(menu,item)
                            if item and item.is_done then
                                UIManager:nextTick(function()
                                    M.open(store,word,openDictionary,true,frame_provider)
                                end)
                            end
                            return response
                        end
                        local menu=Menu:new(opts)
                        local native_swipe=menu.onSwipe
                        menu.onSwipe=function(self,arg,ges)
                            local direction=ges and ges.direction
                            if direction~='north' and direction~='south'
                                    and direction~='west' and direction~='east' then
                                return true -- Never invoke stock Menu's diagonal full refresh.
                            end
                            return native_swipe(self,arg,ges)
                        end
                        local onCloseWidget=menu.onCloseWidget
                        menu.onCloseWidget=function(self,...)
                            if onCloseWidget then onCloseWidget(self,...) end
                            if not handled then
                                handled=true
                                UIManager:nextTick(function()
                                    M.open(store,word,openDictionary,true,frame_provider)
                                end)
                            end
                        end
                        return menu
                    end,function(id)
                        store.setPopupFont(id)
                        M.open(store,word,openDictionary,true,frame_provider)
                    end)
                end)
                if not ok then
                    logger.warn('FlipSide popup font picker:',result)
                    M.open(store,word,openDictionary,true,frame_provider)
                elseif result==false then
                    M.open(store,word,openDictionary,true,frame_provider)
                end
            end
        end,options)
    end
    fontSizeMenu=function()
        local sizes={16,18,20,21,22,24,26,28,30}
        local entries={}
        for _,n in ipairs(sizes) do
            entries[#entries+1]={text=(store.getPopupFontSize()==n and '●  ' or '○  ')..n,value=n}
        end
        showRows('Font size',entries,function(item)
            if item.value then
                store.setPopupFontSize(item.value)
                options()
            end
        end,options)
    end
    options=function()
        if not store.get(word) then finish();return end
        showRows('Meaning options',{
            {text='Prioritize meanings',action='priority'},
            {text='Dictionary',action='dictionary',enabled=openDictionary~=nil},
            {text='Add meaning',action='add'},
            {text='Edit meanings',action='edit'},
            {text=FontPicker.label(store.getPopupFont()),action='font'},
            {text='Font size: '..tostring(store.getPopupFontSize()),action='size'},
        },function(item)
            local a=item.action
            if a=='priority' then prioritize()
            elseif a=='dictionary' then dictionary()
            elseif a=='add' then editor(nil,options)
            elseif a=='edit' then editList()
            elseif a=='font' then fontPicker()
            elseif a=='size' then fontSizeMenu()
            end
        end,render)
    end

    render=function()
        if state.closed then return false end
        local list=store.list(word)
        if #list==0 then finish();return false end
        state.position=math.max(1,math.min(#list,state.position))
        local row=list[state.position]
        removeDialog()
        removePopup()
        ensureShield()
        state.shield.show_card_behind=true
        local sw,sh=Screen:getWidth(),Screen:getHeight()
        local total_w=math.floor(math.min(sw*.90,Screen:scaleBySize(650)))
        local inner_w=math.max(120,total_w-2*(Size.border.window+Size.padding.button)-14)
        -- Keep definition text evenly inset from both popup borders.
        local body_side_margin=math.max(Screen:scaleBySize(14), math.floor(inner_w*.05))
        local text_w=math.max(80,inner_w-2*body_side_margin)
        local body_face=face(store)
        local body=TextBoxWidget:new{
            text=row.text,face=body_face,width=text_w,
            alignment='center',justified=false,
        }
        local max_body_h=math.floor(sh*.53)
        if body:getSize().h>max_body_h then
            if body.free then body:free() end
            body=ScrollTextWidget:new{
                text=row.text,face=body_face,width=text_w,height=max_body_h,
                alignment='center',justified=false,
            }
        end
        local gear=Button:new{
            text='⚙',text_font_face='smallinfofont',text_font_size=22,
            bordersize=0,padding_h=Screen:scaleBySize(6),
            padding_v=Screen:scaleBySize(3),callback=options,
        }
        local title=TextWidget:new{
            text=tostring(word),face=face(store,math.min(25,store.getPopupFontSize())),
            bold=true,max_width=math.max(60,inner_w-gear:getSize().w-6),
        }
        local title_w=title:getSize().w
        local gear_w=gear:getSize().w
        local before=math.max(0,math.min(math.floor((inner_w-title_w)/2),inner_w-title_w-gear_w))
        local after=math.max(0,inner_w-before-title_w-gear_w)
        local header=HorizontalGroup:new{
            align='center',HorizontalSpan:new{width=before},title,
            HorizontalSpan:new{width=after},gear,
        }
        -- Navigate meanings by horizontal swipes; keep the existing native
        -- ScrollTextWidget for long definitions and its vertical scrolling.
        -- No arrow buttons or transparent touch targets remain on either side.
        -- Restore the original filled/empty meaning-position dots.
        -- Keep a nine-dot viewport for unusually long meaning lists so the
        -- footer never overflows the e-ink dialog; never show a numeric count.
        local dots={}
        local first=math.max(1,math.min(state.position-4,#list-8))
        local last=math.min(#list,first+8)
        for n=first,last do
            dots[#dots+1]=(n==state.position and '●' or '○')
        end
        local progress=table.concat(dots,'  ')
        local footer_text=TextWidget:new{text=progress,face=face(store,14)}
        local footer=CenterContainer:new{dimen=Geom:new{w=inner_w,h=footer_text:getSize().h},footer_text}
        local spacing=math.max(4,Screen:scaleBySize(8))
        local content=VerticalGroup:new{align='center',header,gap(spacing),body,gap(spacing),footer}
        if content:getSize().h>sh*.83 then
            logger.warn('FlipSide meaning popup exceeds safe screen height')
            finish()
            return false
        end
        local dialog
        dialog=ButtonDialog:new{
            width=total_w,buttons={},_added_widgets={content},
            dismissable=true,use_info_style=true,info_padding=0,info_margin=0,
            -- Use FlipSide's existing no-inversion button handler only here;
            -- the reader's normal buttons and dictionary are untouched.
            _vocab_no_flash_surface=true,
            tap_close_callback=function()
                -- ButtonDialog:onClose itself removes the window after this
                -- callback. Release the background on the following UI tick
                -- to keep the stack order safe on Kindle as well as Android.
                if state.popup==dialog then state.popup=nil end
                UIManager:nextTick(finish)
            end,
        }
        -- Only this dialog owns the swipe event. KOReader's ScrollTextWidget
        -- handles north/south first, and deliberately propagates west/east
        -- gestures up to this ButtonDialog. The gesture zone follows the actual
        -- pinned popup bounds: no swipes on the card/background are captured.
        dialog.ges_events.SwipeMeaning={GestureRange:new{
            ges='swipe',
            range=function()
                return dialog.movable and dialog.movable.dimen
            end,
        }}
        dialog.onSwipeMeaning=function(_,_,ges)
            local direction=ges and ges.direction
            if direction=='west' then
                navigate(1)   -- finger to the left: next meaning
            elseif direction=='east' then
                navigate(-1)  -- finger to the right: previous meaning
            end
            -- Consume gestures in the popup at boundaries and on diagonals;
            -- vertical scroll has already been handled by ScrollTextWidget.
            return true
        end
        -- This popup must never request a flashing update, not even on
        -- Done/outside-tap. Navigation and close use the same regional UI mode.
        -- Scope the override to this FlipSide dialog instance only.
        dialog.onCloseWidget=function(self)
            UIManager:setDirty(nil,function() return 'ui',self.movable.dimen end)
        end
        state.popup=dialog
        local actual_top=pinDialog(dialog,state.fixed_top)
        -- Keep the *first* placement for later meanings. A longer meaning
        -- may need a temporary screen-bound clamp, but must not shift the
        -- anchor for subsequent shorter meanings.
        if state.fixed_top==nil then state.fixed_top=actual_top end
        shieldFor(dialog)
        if body.dialog==nil then body.dialog=dialog end
        if body.text_widget and body.text_widget.dialog==nil then
            body.text_widget.dialog=dialog
        end
        UIManager:show(dialog)
        return true
    end
    if startInOptions then
        UIManager:nextTick(options)
        return true
    end
    return render()
end
return M
