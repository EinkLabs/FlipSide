-- FlipSide: Angular / compact. Independent new card style.
-- Frame dimensions are derived from Technical / circuit, but the card is
-- shorter (height ~85% of width) to match the supplied compact reference.
-- No changes to the original Technical / circuit or Geometric / bold modules.
-- All temporary text shaping happens while the card is assembled.
local BB = require("ffi/blitbuffer")
local Device = require("device")
local TextWidget = require("ui/widget/textwidget")
local Buttons = require("lib.cards.flipside_card_buttons")
local Screen = Device.screen
local M = {}
local BLACK, WHITE = BB.COLOR_BLACK, BB.COLOR_WHITE

local function scale(v)
    return math.max(1, Screen:scaleBySize(v))
end
local function iround(v)
    return math.floor(v + 0.5)
end
local function paint(bb,x,y,w,h,color)
    if w > 0 and h > 0 then
        bb:paintRect(iround(x),iround(y),iround(w),iround(h),color or BLACK)
    end
end

-- Double border with four clipped corners; unlike the complicated circuit
-- frame this has only basic rectangles and 45-degree strokes. It never uses
-- SVG, alpha compositing or a temporary image buffer on the Kindle.
local function beveledBorder(bb,x,y,w,h,cut,pen)
    cut=math.max(pen+2,math.min(cut,math.floor(w/4),math.floor(h/4)))
    paint(bb,x+cut,y,w-2*cut,pen)
    paint(bb,x+cut,y+h-pen,w-2*cut,pen)
    paint(bb,x,y+cut,pen,h-2*cut)
    paint(bb,x+w-pen,y+cut,pen,h-2*cut)
    for i=0,cut-1 do
        local n=cut-1-i
        paint(bb,x+i,y+n,pen,pen)
        paint(bb,x+w-i-pen,y+n,pen,pen)
        paint(bb,x+i,y+h-n-pen,pen,pen)
        paint(bb,x+w-i-pen,y+h-n-pen,pen,pen)
    end
end

local function cornerTriangles(bb,x,y,w,h,inset,side)
    side=math.max(3,math.min(side,math.floor(w/8),math.floor(h/8)))
    for i=0,side-1 do
        local extent=side-i
        paint(bb,x+inset,y+inset+i,extent,1)
        paint(bb,x+w-inset-extent,y+inset+i,extent,1)
        paint(bb,x+inset,y+h-inset-1-i,extent,1)
        paint(bb,x+w-inset-extent,y+h-inset-1-i,extent,1)
    end
end

-- The Technical / circuit side and available-height calculations are kept;
-- only the natural aspect ratio changes to match the user's reference image
-- (roughly 0.85 height / width). If content grows, the frame can grow as well.
local function frameGeometry(w,h,margin,content_h)
    local side=math.max(scale(15),iround(margin*0.76))
    local fw=w-2*side
    local frame_gap=math.min(scale(24),math.max(scale(15),iround(h*0.04)))
    local available=h-2*frame_gap
    if fw<scale(200) or available<scale(230) then return nil end
    local natural_h=iround(fw*0.85)
    local min_content_h=content_h+scale(105)
    local fh=math.min(available,math.max(natural_h,min_content_h))
    if fh<scale(210) then return nil end
    return {x=iround((w-fw)/2),y=iround((h-fh)/2),w=fw,h=fh}
end

-- Only buttons and the outer frame are styled. Text remains native.
function M.decorateButton(button, is_negative)
    return Buttons.decorateButton(button, is_negative)
end
function M.decorateDelete(button)
    return Buttons.decorateDelete(button)
end

function M.decorateCenter(center,w,h,margin,content_h,progress)
    if not center or type(center.paintTo)~="function" then return center end
    local frame=frameGeometry(w,h,margin,content_h)
    if not frame then return center end
    local pen=math.max(1,scale(2))
    local inset=math.max(scale(4),pen+scale(2))
    local corner=math.max(scale(12),math.min(scale(19),iround(frame.w*0.028)))
    local inner_pen=math.max(1,scale(1))
    local count_y=frame.y+iround(frame.h*0.12)
    local progress_h=progress and progress:getSize().h or 0
    -- Keep native counter when the frame is too small, or the content is long.
    local on_top=progress and frame.h>scale(260)
        and content_h+progress_h+scale(95)<frame.h
    local native_paint
    local counter_width
    if on_top then
        local ok,label=pcall(TextWidget.new,TextWidget,{
            text=progress.text,face=progress.face,padding=0,
        })
        if ok and label then
            local measured,dim=pcall(label.getSize,label)
            if measured and dim and dim.w>0 and dim.w<frame.w*0.6 then
                counter_width=dim.w
            end
            if type(label.free)=="function" then pcall(label.free,label) end
        end
        if not counter_width then on_top=false end
    end
    if on_top then
        native_paint=progress.paintTo
        progress.paintTo=function() end
        center._flipside_counter={
            y=count_y-iround(progress_h/2),h=progress_h,w=counter_width,
        }
    end
    center._flipside_frame_bounds=frame
    center._flipside_static_key=table.concat({
        "angular",w,h,margin,frame.x,frame.y,frame.w,frame.h,
        content_h,on_top and 1 or 0,
    },":")
    local original=center.paintTo
    center.paintTo=function(widget,bb,x,y)
        original(widget,bb,x,y)
        -- Border behind none of the letters; every stroke stays within the
        -- measured frame. Repaint uses simple integer-aligned BlitBuffer ops.
        beveledBorder(bb,x+frame.x,y+frame.y,frame.w,frame.h,corner,pen)
        beveledBorder(bb,x+frame.x+inset,y+frame.y+inset,
            frame.w-2*inset,frame.h-2*inset,
            math.max(scale(7),corner-inset),inner_pen)
        cornerTriangles(bb,x+frame.x,y+frame.y,frame.w,frame.h,
            inset+scale(10),math.max(scale(12),iround(frame.w*0.04)))
        if on_top then
            local counter_size=progress:getSize()
            native_paint(progress,bb,x+iround((w-counter_size.w)/2),
                y+count_y-iround(progress_h/2))
            local middle=x+iround(w/2)
            local break_gap=iround(counter_width/2)+scale(21)
            local rail_left=x+frame.x+iround(frame.w*0.14)
            local rail_right=x+frame.x+iround(frame.w*0.86)
            local thickness=math.max(1,scale(2))
            if middle-break_gap-rail_left>scale(12) then
                paint(bb,rail_left,y+count_y,middle-break_gap-rail_left,thickness)
            end
            if rail_right-(middle+break_gap)>scale(12) then
                paint(bb,middle+break_gap,y+count_y,
                    rail_right-middle-break_gap,thickness)
            end
        end
    end
    return center
end
return M
