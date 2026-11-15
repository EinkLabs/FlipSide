-- Shared native e-ink popup header: centered title and an information button.
-- This module is layout-only. It does not read or change any review data.
local Button = require("ui/widget/button")
local TextWidget = require("ui/widget/textwidget")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Screen = require("device").screen

local Header = {}
function Header.new(title, width, showHelp, text_size)
    width = math.max(110, math.floor(width))
    local label = TextWidget:new{
        text = title,
        face = Font:getFace("smalltfont", text_size or 18),
        bold = true,
    }
    local info = Button:new{
        text = "ⓘ",
        text_font_face = "smallinfofont",
        text_font_size = 19,
        text_font_bold = true,
        bordersize = 0,
        padding_h = Screen:scaleBySize(5),
        padding_v = Screen:scaleBySize(3),
        callback = showHelp,
        vsync = true,
    }
    local title_w = label:getSize().w
    local info_w = info:getSize().w
    local inset = math.max(2, Screen:scaleBySize(4))
    local free = math.max(0, width - title_w - info_w - inset)
    local left = math.min(math.max(0, math.floor((width - title_w)/2)), free)
    local right = math.max(0, width - left - title_w - info_w - inset)
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{width=left}, label,
        HorizontalSpan:new{width=right}, info,
        HorizontalSpan:new{width=inset},
    }
    return FrameContainer:new{
        bordersize = 0,
        padding_left = 0, padding_right = 0,
        padding_top = 0, padding_bottom = 0,
        margin = 0,
        row,
    }
end
return Header
