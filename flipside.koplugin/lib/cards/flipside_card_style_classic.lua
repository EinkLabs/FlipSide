-- FlipSide: Classic / black header.
-- Independent card frame inspired by the supplied reference image.
-- Shares EXACTLY the Technical / circuit outer frame geometry, without
-- changing that renderer, review actions, input gestures or other templates.
-- No native drawing/font shaping is performed on a touch callback.
local BB = require("ffi/blitbuffer")
local Device = require("device")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Screen = Device.screen
local M = {}
local BLACK, WHITE = BB.COLOR_BLACK, BB.COLOR_WHITE

local function scale(n)
    return math.max(1, Screen:scaleBySize(n))
end
local function iround(n)
    return math.floor(n + 0.5)
end
local function rect(bb, x, y, w, h, color)
    w, h = math.floor(w + 0.5), math.floor(h + 0.5)
    if w > 0 and h > 0 then
        bb:paintRect(iround(x), iround(y), w, h, color or BLACK)
    end
end

-- Byte-for-byte equivalent bounds formula to Circuit.makeScene().
-- Consequently this card is precisely as wide/high as Technical / circuit
-- for any given screen size, content height and KOReader scale.
local function frameGeometry(width, height, margin, content_height)
    local side = math.max(scale(15), iround(margin * 0.76))
    local fw = width - 2 * side
    local frame_gap = math.min(scale(24), math.max(scale(15), iround(height * 0.04)))
    local avail_h = height - 2 * frame_gap
    if fw < scale(200) or avail_h < scale(260) then return nil end
    local natural_h = iround(fw * 0.93)
    local minimum_h = math.max(natural_h, content_height + scale(116))
    local fh = math.min(avail_h, minimum_h)
    if fh < scale(240) then return nil end
    return {
        x = iround((width - fw) / 2),
        y = iround((height - fh) / 2),
        w = fw,
        h = fh,
    }
end

-- Draw a monochrome rounded outline by small scanline runs. These primitives
-- work on older Kindle BlitBuffers; no SVG, alpha buffers or shaders.
local function roundOutline(bb, x, y, w, h, radius, pen)
    local r = math.max(pen + 1, math.min(radius, math.floor(w / 2), math.floor(h / 2)))
    rect(bb, x+r, y, w-2*r, pen)
    rect(bb, x+r, y+h-pen, w-2*r, pen)
    rect(bb, x, y+r, pen, h-2*r)
    rect(bb, x+w-pen, y+r, pen, h-2*r)
    local inner = math.max(1, r-pen)
    for i=0,r-1 do
        local d = r-i-0.5
        local a = math.ceil(r-math.sqrt(math.max(0,r*r-d*d)))
        local b
        if i < pen then
            b = math.floor(w/2)
        elseif i-pen < inner then
            local di = inner-(i-pen)-0.5
            b = pen+math.ceil(inner-math.sqrt(math.max(0,inner*inner-di*di)))
        else
            b = pen
        end
        local stroke = math.max(0, b-a)
        rect(bb, x+a, y+i, stroke, 1)
        rect(bb, x+w-b, y+i, stroke, 1)
        rect(bb, x+a, y+h-1-i, stroke, 1)
        rect(bb, x+w-b, y+h-1-i, stroke, 1)
    end
end

local function blackHeader(bb, x, y, w, h, radius)
    local r = math.max(1,math.min(radius,math.floor(h/2),math.floor(w/2)))
    rect(bb, x, y+r, w, h-r, BLACK)
    for i=0,r-1 do
        local d=r-i-0.5
        local cut=math.ceil(r-math.sqrt(math.max(0,r*r-d*d)))
        rect(bb,x+cut,y+i,w-2*cut,1,BLACK)
    end
end

-- Original content is never repositioned or restyled by this frame.
function M.decorateCenter(center,width,height,margin,content_height,progress,
        word_widget,sentence_widget,visible_content,content)
    if not center or type(center.paintTo)~="function" then return center end
    local f=frameGeometry(width,height,margin,content_height)
    if not f then return center end
    local pen=math.max(1,scale(2))
    local radius=math.max(scale(11),math.min(scale(22),math.floor(f.w*.023)))
    -- Keep the black title band at its familiar natural height when the
    -- frame grows for a font-40 paragraph. Otherwise the header itself grows
    -- with the text and steals space from that paragraph.
    local header_h=math.max(scale(30),math.floor(f.w*.106))
    header_h=math.min(header_h,math.floor(f.h*.19))
    local counter
    if progress and type(progress.text)=="string" and progress.face then
        -- The ordinary progress label can be a full sentence during review
        -- inspection. Try its existing face first, then smaller built-in
        -- sizes, so it never spills over the black header's rounded corners.
        for attempt=1,5 do
            local face=progress.face
            if attempt>1 then
                local ok,f=pcall(Font.getFace,Font,"cfont",math.max(9,17-2*attempt))
                face=ok and f or nil
            end
            if face then
                local ok,item=pcall(TextWidget.new,TextWidget,{
                    text=progress.text,face=face,fgcolor=WHITE,padding=0,
                })
                if ok and item then
                    local good,sz=pcall(item.getSize,item)
                    if good and sz and sz.w<=f.w-2*radius and sz.h<header_h-2*pen then
                        counter=item
                        break
                    end
                    if type(item.free)=="function" then pcall(item.free,item) end
                end
            end
        end
    end
    if counter then
        -- The original gray counter still reserves its identical natural
        -- height, but is painted only once at the top of the black header.
        progress.paintTo=function() end
        local old_free=center.free
        if type(old_free)=="function" then
            center.free=function(self,...)
                if counter then
                    if type(counter.free)=="function" then pcall(counter.free,counter) end
                    counter=nil
                end
                return old_free(self,...)
            end
        end
    end

    center._flipside_frame_bounds=f
    center._flipside_static_key=table.concat({"classic",f.x,f.y,f.w,f.h,
        header_h,content_height},":")
    if counter then
        center._flipside_counter={
            y=f.y+math.floor((header_h-counter:getSize().h)/2),
            h=counter:getSize().h,w=counter:getSize().w,
        }
    end
    local original=center.paintTo
    center.paintTo=function(widget,bb,x,y)
        -- Paint content first and the immutable outline above it. This
        -- keeps long words from making the rounded border look broken.
        original(widget,bb,x,y)
        roundOutline(bb,x+f.x,y+f.y,f.w,f.h,radius,pen)
        blackHeader(bb,x+f.x+pen,y+f.y+pen,f.w-2*pen,header_h-pen,radius-pen)
        if counter then
            local cs=counter:getSize()
            counter:paintTo(bb,x+f.x+math.floor((f.w-cs.w)/2),
                y+f.y+math.floor((header_h-cs.h)/2))
        end
    end
    return center
end

-- Classic button styling: solid black negative, outlined white positive.
function M.decorateButton(button, negative)
    local frame = button and button.frame
    if not frame then return button end
    frame.background = negative and BLACK or WHITE
    frame.color = BLACK
    button.background = frame.background
    frame.radius = scale(7)
    if button.label_widget then
        button.label_widget.fgcolor = negative and WHITE or BLACK
    end
    return button
end
function M.decorateDelete(button)
    local frame = button and button.frame
    if frame then
        frame.color = BLACK
        frame.radius = scale(7)
        frame.bordersize = math.max(1, scale(1))
    end
    return button
end
return M
