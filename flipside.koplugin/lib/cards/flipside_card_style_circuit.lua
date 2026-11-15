-- FlipSide: Technical / circuit (independent visual skin).
-- KOReader retains all card content, hit areas, gestures, and review logic.
-- No other card style or engine module is modified by this implementation.
local BB = require("ffi/blitbuffer")
local Device = require("device")
local TextWidget = require("ui/widget/textwidget")

local Screen = Device.screen
local M = {}
local BLACK, WHITE = BB.COLOR_BLACK, BB.COLOR_WHITE
-- The e-ink palette is provided by KOReader's own BlitBuffer.  Reusing
-- these ready-made colors avoids FFI allocations during painting.
local GREYS = {
    BLACK, BB.COLOR_GRAY_1 or BLACK, BB.COLOR_GRAY_2 or BLACK,
    BB.COLOR_GRAY_3 or BLACK, BB.COLOR_GRAY_4 or BLACK,
    BB.COLOR_GRAY_5 or BLACK, BB.COLOR_GRAY_6 or BLACK,
    BB.COLOR_GRAY_7 or BLACK, BB.COLOR_DARK_GRAY or BLACK,
    BB.COLOR_GRAY_9 or BLACK, BB.COLOR_GRAY or WHITE,
    BB.COLOR_GRAY_B or WHITE, BB.COLOR_LIGHT_GRAY or WHITE,
    BB.COLOR_GRAY_D or WHITE, BB.COLOR_GRAY_E or WHITE, WHITE,
}
local SUBPIXEL = { 1/6, 1/2, 5/6 }

local function scale(n)
    return math.max(1, Screen:scaleBySize(n))
end
local function iround(n)
    return math.floor(n + 0.5)
end
local function rect(bb, x, y, w, h, color)
    local wi, hi = iround(w), iround(h)
    if wi > 0 and hi > 0 then
        bb:paintRect(iround(x), iround(y), wi, hi, color or BLACK)
    end
end

-- A small, bounded set of immutable drawing commands, built ONCE per geometry.
-- All routine e-ink refreshes simply replay rects: no fonts, polygons or sqrt.
local function sceneBuilder()
    local ops = {}
    local function r(x, y, w, h, color)
        w, h = iround(w), iround(h)
        if w > 0 and h > 0 then
            ops[#ops + 1] = {iround(x), iround(y), w, h, color or BLACK}
        end
    end
    -- Supersampled diagonals, quantized to the native 16-tone e-ink palette.
    -- This code runs only while building the immutable scene, never on each
    -- paintTo. Horizontal/vertical rules stay single native rectangles.
    -- No additional FFI objects, offscreen images or global hooks.
    local function line(x0, y0, x1, y1, pen, color)
        pen = math.max(1, pen or 1)
        color = color or BLACK
        x0, y0, x1, y1 = iround(x0), iround(y0), iround(x1), iround(y1)
        local dx, dy = x1-x0, y1-y0
        if dx == 0 then
            r(x0, math.min(y0,y1), pen, math.abs(dy)+pen, color)
            return
        elseif dy == 0 then
            r(math.min(x0,x1), y0, math.abs(dx)+pen, pen, color)
            return
        end
        local radius = pen * 0.5
        local radius_sq = radius * radius
        local length_sq = dx*dx + dy*dy
        local pad = radius + 1
        local left = math.floor(math.min(x0,x1) - pad)
        local right = math.ceil(math.max(x0,x1) + pad)
        local top = math.floor(math.min(y0,y1) - pad)
        local bottom = math.ceil(math.max(y0,y1) + pad)
        for py=top,bottom do
            local run_x, run_color, run_width
            local function flush()
                if run_width then r(run_x,py,run_width,1,run_color) end
                run_x,run_color,run_width=nil,nil,nil
            end
            for px=left,right do
                local covered=0
                for _,sy in ipairs(SUBPIXEL) do
                    local cy=py+sy
                    for _,sx in ipairs(SUBPIXEL) do
                        local cx=px+sx
                        local proj=((cx-x0)*dx+(cy-y0)*dy)/length_sq
                        if proj<0 then proj=0 elseif proj>1 then proj=1 end
                        local ddx=cx-(x0+proj*dx)
                        local ddy=cy-(y0+proj*dy)
                        if ddx*ddx+ddy*ddy<=radius_sq then
                            covered=covered+1
                        end
                    end
                end
                if covered>0 then
                    local shade
                    if color == BLACK then
                        shade=GREYS[16-math.floor(covered*15/9+0.5)]
                    else
                        -- All scene diagonals are black. Preserve a safe
                        -- native-color fallback if a future design adds one.
                        shade=color
                    end
                    if run_width and run_color == shade then
                        run_width=run_width+1
                    else
                        flush()
                        run_x,run_color,run_width=px,shade,1
                    end
                else
                    flush()
                end
            end
            flush()
        end
    end
    local function path(p, pen, color)
        for i=1,#p-1 do
            line(p[i][1],p[i][2],p[i+1][1],p[i+1][2],pen,color)
        end
    end
    local function disk(cx, cy, radius, color)
        radius = iround(radius)
        for dy=-radius,radius do
            local dx=math.floor(math.sqrt(radius*radius-dy*dy))
            r(cx-dx,cy+dy,2*dx+1,1,color)
        end
    end
    -- Four horizontal subsamples give each diagonal polygon edge gradual
    -- coverage instead of alternating hard one-pixel stair steps. Interior
    -- runs are coalesced, keeping the overlay compact and cheap to replay.
    local function poly(points, color)
        local min_y,max_y=points[1][2],points[1][2]
        for i=2,#points do
            min_y=math.min(min_y,points[i][2])
            max_y=math.max(max_y,points[i][2])
        end
        for yi=math.floor(min_y),math.ceil(max_y)-1 do
            local coverage={}
            local min_x,max_x
            for sub=0,3 do
                local scan=yi+(sub+0.5)/4
                local hits={}
                for i=1,#points do
                    local a,b=points[i],points[i % #points+1]
                    if (a[2]<=scan and b[2]>scan)
                            or (b[2]<=scan and a[2]>scan) then
                        hits[#hits+1]=a[1]+(scan-a[2])*(b[1]-a[1])/(b[2]-a[2])
                    end
                end
                table.sort(hits)
                for i=1,#hits-1,2 do
                    local xl,xr=hits[i],hits[i+1]
                    for px=math.floor(xl),math.ceil(xr)-1 do
                        local overlap=math.min(px+1,xr)-math.max(px,xl)
                        if overlap>0 then
                            coverage[px]=(coverage[px] or 0)+overlap/4
                            min_x=math.min(min_x or px,px)
                            max_x=math.max(max_x or px,px)
                        end
                    end
                end
            end
            if min_x then
                local run_x,run_color,run_width
                local function flush()
                    if run_width then r(run_x,yi,run_width,1,run_color) end
                    run_x,run_color,run_width=nil,nil,nil
                end
                for px=min_x,max_x do
                    local area=math.min(1,coverage[px] or 0)
                    if area>0 then
                        local shade
                        if color == BLACK then
                            shade=GREYS[16-math.floor(area*15+0.5)]
                        elseif color == WHITE then
                            shade=GREYS[1+math.floor(area*15+0.5)]
                        else
                            shade=color
                        end
                        if run_width and run_color == shade then
                            run_width=run_width+1
                        else
                            flush()
                            run_x,run_color,run_width=px,shade,1
                        end
                    else
                        flush()
                    end
                end
                flush()
            end
        end
    end
    return ops,r,line,path,disk,poly
end

local function getProgressTextWidth(progress)
    if not progress or not progress.text or not progress.face then return scale(52) end
    -- TextWidget is created & freed on card construction, NEVER in paintTo.
    local ok, widget = pcall(TextWidget.new, TextWidget, {
        text=tostring(progress.text), face=progress.face, padding=0,
    })
    if not ok or not widget then return scale(52) end
    local measured, size = pcall(widget.getSize,widget)
    if type(widget.free)=="function" then pcall(widget.free,widget) end
    if not measured or not size or not size.w then return scale(52) end
    -- Never cap the measured width: longer states such as "Missed cards ·
    -- reinforcement 1/48" otherwise get crossed out by the decorative rails.
    -- When the text is too long, makeScene naturally omits the rails.
    return math.max(scale(26),size.w)
end

local function makeScene(width,height,margin,content_height,count_text_width,count_height,show_count)
    local ops,r,line,path,disk,poly=sceneBuilder()
    local side = math.max(scale(15),iround(margin*0.76))
    local fw = width-2*side
    local frame_gap=math.min(scale(24),math.max(scale(15),iround(height*0.04)))
    local avail_h=height-2*frame_gap
    if fw<scale(200) or avail_h<scale(260) then return nil end
    -- Reference border is nearly square, NOT full-height. Expand only when
    -- long content would otherwise protrude beyond the frame.
    local natural_h=iround(fw*0.93)
    local minimum_h=math.max(natural_h,content_height+scale(116))
    local fh=math.min(avail_h,minimum_h)
    if fh<scale(240) then return nil end
    local fx=iround((width-fw)/2)
    local fy=iround((height-fh)/2)

    local function X(u) return iround(fx+u*fw) end
    local function Y(v) return iround(fy+v*fh) end
    local function normalized(p)
        local out={}
        for i=1,#p do out[i]={X(p[i][1]),Y(p[i][2])} end
        return out
    end
    local function drawPath(p,pen,color)
        path(normalized(p),pen,color)
    end
    local thin=math.max(1,scale(1))
    local heavy=math.max(2,scale(2))

    -- Two precisely independent stepped contours (not parallel rectangles).
    drawPath({
        {.013,.113},{.013,.085},{.063,.014},{.791,.014},
        {.813,.032},{.837,.014},{.951,.014},{.987,.076},
        {.987,.881},{.942,.975},{.094,.975},{.014,.916},{.013,.113}
    },heavy)
    drawPath({
        {.035,.165},{.035,.119},{.095,.071},{.228,.071},
        {.263,.040},{.925,.040},{.968,.086},{.968,.895},
        {.920,.947},{.808,.947},{.777,.960},{.255,.960},
        {.226,.945},{.100,.945},{.036,.890},{.035,.165}
    },thin)

    -- Top-left and bottom-right asymmetric black tabs with WHITE diagonal
    -- cutouts. Their positions match the original art rather than the long
    -- angular bars visible in the previous implementation.
    poly(normalized({
        {.010,.082},{.060,.014},{.249,.014},{.216,.058},
        {.196,.064},{.093,.064},{.042,.116},{.010,.101}
    }),BLACK)
    for i=0,2 do
        local u=.099+i*.026
        poly(normalized({
            {u+.023,.023},{u+.045,.023},{u+.017,.051},{u-.005,.051}
        }),WHITE)
    end
    poly(normalized({
        {.804,.924},{.924,.924},{.988,.851},{.988,.913},
        {.944,.981},{.783,.981}
    }),BLACK)
    for i=0,2 do
        local u=.833+i*.026
        poly(normalized({
            {u+.020,.938},{u+.042,.938},{u+.016,.968},{u-.006,.968}
        }),WHITE)
    end

    -- Circuit border nodes and side terminal marks.
    disk(X(.813),Y(.032),scale(3),BLACK)
    disk(X(.257),Y(.960),scale(3),BLACK)
    for i=0,2 do
        disk(X(.976),Y(.207)+i*scale(15),scale(3),BLACK)
        r(X(.028),Y(.724)+i*scale(15),scale(5),scale(5),BLACK)
    end
    line(X(.037),Y(.385),X(.037),Y(.407),thin)
    line(X(.969),Y(.532),X(.969),Y(.557),thin)

    -- Keep counter visually in the upper frame, with rails no more than
    -- ~12px from the actual rendered numerals, not a wide arbitrary gap.
    local count_y=Y(.145)
    local half_gap=iround(count_text_width/2)+scale(11)
    local mid=iround(width/2)
    local left_end=mid-half_gap
    local right_start=mid+half_gap
    local lstart=X(.105)
    local rend=X(.895)
    if show_count and left_end>lstart+scale(25) and rend>right_start+scale(25) then
        path({
            {lstart,count_y+scale(10)},
            {lstart+scale(16),count_y},
            {left_end,count_y}
        },thin)
        path({
            {right_start,count_y},
            {rend-scale(16),count_y},
            {rend,count_y+scale(10)}
        },thin)
    end

    return {ops=ops, counter_y=count_y, frame={x=fx,y=fy,w=fw,h=fh}}
end

-- Geometries are shared by key, with weak values so obsolete orientations
-- and rebuilt cards do not keep their large buffers alive. Prepaint once into
-- a transparent BB8A. The C alpha compositor replaces thousands of Lua
-- paintRect calls during every e-ink refresh. Fallback replays cached rects.
local scene_cache=setmetatable({}, {__mode="v"})
local function buildOverlay(width,height,scene)
    if type(BB.new)~="function" or not BB.TYPE_BB8A then return nil end
    -- Restrict memory/bandwidth to the actual framed card. A full-height
    -- 710x1090 BB8A is ~1.55MB; the cropped near-square border is ~0.8MB.
    local frame=scene.frame
    if not frame then return nil end
    local margin=scale(7)
    local x=math.max(0,frame.x-margin)
    local y=math.max(0,frame.y-margin)
    local w=math.min(width-x,frame.w+2*margin)
    local h=math.min(height-y,frame.h+2*margin)
    local ok,mask=pcall(BB.new,w,h,BB.TYPE_BB8A)
    if not ok or not mask then return nil end
    -- BB.new() calloc initializes BB8A to transparent black, alpha=0.
    local drawn=pcall(function()
        for i=1,#scene.ops do
            local a=scene.ops[i]
            mask:paintRect(a[1]-x,a[2]-y,a[3],a[4],a[5])
        end
    end)
    if not drawn then
        if type(mask.free)=="function" then mask:free() end
        return nil
    end
    scene.overlay_x=x
    scene.overlay_y=y
    return mask
end
function M.decorateCenter(center,width,height,margin,content_height,progress)
    if not center or type(center.paintTo)~="function" then return center end
    local count_h=progress and progress:getSize().h or 0
    local count_w=getProgressTextWidth(progress)
    local show_count=progress~=nil
        and height>scale(300)
        and content_height+count_h+scale(110)<height
    local key=table.concat({width,height,margin,content_height,count_w,show_count and 1 or 0},":")
    local scene=scene_cache[key]
    if not scene then
        scene=makeScene(width,height,margin,content_height,count_w,count_h,show_count)
        if not scene then return center end
        scene.overlay=buildOverlay(width,height,scene)
        -- Keep lightweight rect commands as a safe fallback if an older
        -- device does not expose alphablitFrom for its target BlitBuffer.
        scene_cache[key]=scene
    end
    -- The frame scene is immutable for a given key.  The parent may update
    -- only the text if the new card uses exactly the same cached frame.
    center._flipside_static_key=key
    -- Exact screen-independent bounds of the ornament, relative to center.
    center._flipside_frame_bounds=scene.frame
    if show_count then
        center._flipside_counter={
            y=scene.counter_y-iround(count_h/2),
            h=count_h, w=count_w,
        }
    end
    local original=center.paintTo
    local count_paint
    local count_box_w=0
    if show_count then
        count_paint=progress.paintTo
        local size=progress:getSize()
        count_box_w=size.w
        progress.paintTo=function() end
    end
    center.paintTo=function(widget,bb,x,y)
        original(widget,bb,x,y)
        if show_count then
            count_paint(progress,bb,
                x+iround((width-count_box_w)/2),
                y+scene.counter_y-iround(count_h/2))
        end
        -- Avoid the slow Lua per-pixel alpha fallback on builds without the
        -- accelerated C blitter: replay cached rectangles there instead.
        if scene.overlay and type(bb.alphablitFrom)=="function"
                and type(bb.canUseCbbTogether)=="function"
                and bb:canUseCbbTogether(scene.overlay) then
            bb:alphablitFrom(scene.overlay,x+scene.overlay_x,y+scene.overlay_y)
        elseif scene.ops then
            for i=1,#scene.ops do
                local op=scene.ops[i]
                bb:paintRect(x+op[1],y+op[2],op[3],op[4],op[5])
            end
        end
    end
    return center
end

-- KOReader Button widgets and callback/hitbox remain untouched. Both sides
-- use the same two bent inlays, with inverse ink on the negative button.
function M.decorateButton(button,negative)
    local frame=button and button.frame
    if not frame then return button end
    frame.background=negative and BLACK or WHITE
    frame.color=BLACK
    button.background=frame.background
    frame.radius=math.max(scale(11),frame.radius or scale(11))
    if button.label_widget then
        button.label_widget.fgcolor=negative and WHITE or BLACK
    end
    local original=frame.paintTo
    local sz=frame:getSize()
    local inset=math.max(scale(7),math.floor(sz.h*.18))
    local arm=math.max(scale(18),math.min(scale(26),math.floor(sz.w*.13)))
    local pen=math.max(1,scale(1))
    local col=negative and WHITE or BLACK
    frame.paintTo=function(widget,bb,x,y)
        original(widget,bb,x,y)
        -- Top-left: short horizontal, 45deg elbow, vertical stem.
        rect(bb,x+inset+scale(5),y+inset,arm-scale(5),pen,col)
        rect(bb,x+inset,y+inset+scale(5),pen,scale(11),col)
        for i=0,scale(5) do rect(bb,x+inset+i,y+inset+scale(5)-i,pen,pen,col) end
        -- Bottom-right: exact mirror of the upper-left inlay.
        local bx=x+sz.w-inset
        local by=y+sz.h-inset
        rect(bb,bx-arm,by-pen,arm-scale(5),pen,col)
        rect(bb,bx-pen,by-scale(16),pen,scale(11),col)
        for i=0,scale(5) do rect(bb,bx-scale(5)+i,by-scale(5)+i,pen,pen,col) end
    end
    return button
end

function M.decorateDelete(button)
    local frame = button and button.frame
    if frame then
        frame.background = WHITE
        frame.color = BLACK
        frame.radius = math.max(scale(10), frame.radius or scale(10))
        frame.bordersize = math.max(1, scale(1))
    end
    return button
end
return M
