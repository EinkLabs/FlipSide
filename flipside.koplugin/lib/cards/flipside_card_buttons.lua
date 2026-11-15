-- FlipSide: button shapes shared by Angular / compact.
-- Does not alter any word, sentence, bracket or review callback.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local M = {}
local function scale(n) return math.max(1, Screen:scaleBySize(n)) end
local function rect(bb,x,y,w,h,color)
    if w>0 and h>0 then
        bb:paintRect(math.floor(x), math.floor(y), math.floor(w), math.floor(h), color)
    end
end
function M.decorateButton(button,inverted)
    local frame=button and button.frame
    if not frame then return button end
    if inverted then
        button.background=BLACK
        frame.background=BLACK
        frame.color=BLACK
        if button.label_widget then button.label_widget.fgcolor=WHITE end
    else
        frame.background=WHITE
        frame.color=BLACK
    end
    frame.radius=0
    local original=frame.paintTo
    frame.paintTo=function(self,bb,x,y)
        original(self,bb,x,y)
        local dim=self:getSize()
        local w,h=dim.w,dim.h
        local bevel=math.max(scale(5),math.min(scale(9),math.floor(h*.13)))
        -- Clear square corners and trace 45 degree diagonal seams.
        for k=0,bevel-1 do
            local n=bevel-k
            rect(bb,x,y+k,n,1,WHITE)
            rect(bb,x+w-n,y+k,n,1,WHITE)
            rect(bb,x,y+h-k-1,n,1,WHITE)
            rect(bb,x+w-n,y+h-k-1,n,1,WHITE)
        end
        for k=0,bevel-1 do
            local xx=k
            local yy=bevel-1-k
            rect(bb,x+xx,y+yy,scale(1),scale(1),BLACK)
            rect(bb,x+w-xx-scale(1),y+yy,scale(1),scale(1),BLACK)
            rect(bb,x+xx,y+h-yy-scale(1),scale(1),scale(1),BLACK)
            rect(bb,x+w-xx-scale(1),y+h-yy-scale(1),scale(1),scale(1),BLACK)
        end
    end
    return button
end

-- The Delete card action is intentionally still a real KOReader Button.
-- Draw only the thin under-rule and rising diagonal from the reference.
-- This does not change the button's text, callback, position or hit rectangle.
function M.decorateDelete(button)
    if not button or type(button.paintTo)~="function" then return button end
    local original=button.paintTo
    button.paintTo=function(self,bb,x,y)
        original(self,bb,x,y)
        local size=self:getSize()
        local w,h=size.w,size.h
        if w<scale(80) or h<scale(12) then return end
        local pen=math.max(1,scale(1))
        local baseline=y+h-pen
        local left=x+scale(3)
        -- The diagonal must not rise into large ascenders/descenders from
        -- fonts with unusual line metrics. Keep it in a bottom-right notch,
        -- away from KOReader's native label and within the button hitbox.
        local rise=math.max(2,math.min(scale(6),math.floor(h*0.12)))
        local slash_x=x+w-scale(9)
        local flat=math.max(0,slash_x-left)
        rect(bb,left,baseline,flat,pen,BLACK)
        for i=0,rise-1 do
            rect(bb,slash_x+math.floor(i*0.5),baseline-i,pen,pen,BLACK)
        end
    end
    return button
end
return M
