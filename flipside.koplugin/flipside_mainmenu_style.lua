-- FlipSide main settings panel: compact e-ink design #4.
-- Presentation only: the stock ButtonTable, ToggleSwitch and callbacks still
-- own all keyboard/touch interaction. No review or sync code is modified.
local BB = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Font = require("ui/font")
local Size = require("ui/size")
local Screen = require("device").screen
local _ = require("gettext")

local M = {}
local P = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or ""
local WHITE, BLACK, GRAY = BB.COLOR_WHITE, BB.COLOR_BLACK, BB.COLOR_LIGHT_GRAY
local border = math.max(1, Screen:scaleBySize(1))
local gap = math.max(3, Screen:scaleBySize(5))
local row_height = math.max(32, math.min(Screen:scaleBySize(40),
    math.floor(Screen:getHeight() * 0.057)))
local icon_map = {
    cloud = "cloud", search = "search", filter = "filter", edit = "delete",
    reset = "reset", clean = "clean", audit = "stats", appearance = "settings",
}

-- Draw one rectangle whose center has enough space for the exact text.
-- The previous version drew the native label a second time, but gave it the
-- full button width. This caused text to run across the icon or outside the
-- frame. Here every text widget is measured against the remaining white area.
local function fitText(text, width, height, preferred, smallest)
    width, height = math.max(1, width), math.max(1, height)
    local value = tostring(text or "")
    for size = preferred, smallest, -1 do
        local widget = TextWidget:new{
            text = value,
            face = Font:getFace("cfont", size),
            bold = true,
        }
        local dim = widget:getSize()
        if dim.w <= width and dim.h <= height then
            return widget
        end
        widget:free()
    end
    -- Long translations or a very small display: allow two lines in the
    -- *available* label region rather than crossing into another control.
    return TextBoxWidget:new{
        text = value, width = width, height = height,
        face = Font:getFace("cfont", smallest),
        bold = true, line_height = 0.05,
        alignment = "center", alignment_strict = true,
        height_adjust = true, height_overflow_show_ellipsis = true,
    }
end

local function innerGeometry(w, h)
    -- Keep a smaller icon band on half-width rows. In both cases the black
    -- region and diagonal occupy at most ~one quarter of the button.
    local band = math.min(math.floor(w * 0.18), Screen:scaleBySize(66))
    band = math.max(math.floor(w * 0.15), band)
    local lean = math.max(3, Screen:scaleBySize(6))
    local slash = math.max(4, Screen:scaleBySize(7))
    local inset = math.max(5, Screen:scaleBySize(7))
    local label_x = math.min(w - 12, band + lean + slash + inset)
    return band, lean, slash, label_x, inset
end

-- Coverage antialiasing for diagonal boundaries. KOReader's BlitBuffer
-- supports 8-bit grayscale colors, but paintRect() itself is pixel-aligned.
-- Drawing one hard rectangle per scanline quantizes x to integers and makes
-- the diagonals look like staircases on 300 ppi e-ink screens. A fractional
-- edge pixel, blended with the adjacent color, preserves the same geometry
-- while supplying intermediate gray levels. No scaling/filtering of text or
-- icons is involved; the rest of this menu is unchanged.
local GRAY_LEVEL = GRAY:getColor8().a
local WHITE_LEVEL = WHITE:getColor8().a
local BLACK_LEVEL = BLACK:getColor8().a
local function coverageColor(left, right, fraction)
    return BB.Color8(math.floor(left * fraction + right * (1 - fraction) + 0.5))
end

local function paintButtonGraphic(bb, x, y, w, h, band, lean, slash)
    bb:paintRect(x, y, w, h, WHITE)
    for yy = border, h-border-1 do
        local b0 = math.max(border + 1, band + lean
            - lean * yy / math.max(1, h - 1))
        local b1 = b0 + slash
        local first = math.floor(b0)
        local last = math.floor(b1)
        -- Entirely black pixels before the first boundary.
        bb:paintRect(x + border, y + yy, first - border, 1, BLACK)
        -- Partially covered pixel at the black / gray diagonal.
        local f0 = b0 - first
        if f0 > 0 then
            bb:paintRect(x + first, y + yy, 1, 1,
                coverageColor(BLACK_LEVEL, GRAY_LEVEL, f0))
        end
        -- Solid light-gray stripe between the two smooth boundaries.
        local start_gray = math.ceil(b0)
        if last > start_gray then
            bb:paintRect(x + start_gray, y + yy,
                last - start_gray, 1, GRAY)
        end
        -- Partially covered pixel at the gray / white diagonal.
        local f1 = b1 - last
        if f1 > 0 then
            bb:paintRect(x + last, y + yy, 1, 1,
                coverageColor(GRAY_LEVEL, WHITE_LEVEL, f1))
        end
    end
    bb:paintRect(x, y, w, border, BLACK)
    bb:paintRect(x, y+h-border, w, border, BLACK)
    bb:paintRect(x, y, border, h, BLACK)
    bb:paintRect(x+w-border, y, border, h, BLACK)
end

local StyledButtonTable = ButtonTable:extend{}
function StyledButtonTable:addVerticalSeparator()
    table.insert(self.container,
        VerticalSpan:new{width=self._flipside_row_gap or gap})
end
function StyledButtonTable:addVerticalSpan()
    -- Respect the free height between the flashcard toolbars at high DPI.
    local vgap = self._flipside_row_gap or gap
    table.insert(self.container, VerticalSpan:new{width=math.max(1, math.floor(vgap/4))})
end

local function styleActionButton(button, key, shown_text, two_col)
    if not button or not button.frame then return end
    local frame = button.frame
    if frame._flipside_design4 then return end
    frame._flipside_design4 = true
    local sz = frame:getSize()
    local w, h = sz.w, sz.h
    local band, lean, slash, label_x, inset = innerGeometry(w, h)
    local label_w = math.max(12, w-label_x-inset-border)
    local label_h = math.max(12, h-2*border-math.max(4, Screen:scaleBySize(6)))
    local label = fitText(shown_text, label_w, label_h,
        two_col and 17 or 20, 10)
    local label_size = label:getSize()
    local icon = nil
    local icon_name = icon_map[key]
    if icon_name then
        local d = math.max(13, math.min(Screen:scaleBySize(23),
            math.floor(h*0.47), math.floor(band*0.59)))
        icon = IconWidget:new{
            -- Render directly from SVG at the target size instead of scaling
            -- a pre-rasterized PNG. This keeps the white strokes smoother on
            -- e-ink devices and avoids the serrated look reported on Kindle.
            file = P .. "assets/icons/" .. icon_name .. ".svg",
            width = d, height = d, alpha = true,
        }
    end
    local native_paint = frame.paintTo
    frame.paintTo = function(f, bb, x, y)
        -- KOReader's frame keeps the original dimension and touch hitbox.
        native_paint(f, bb, x, y)
        paintButtonGraphic(bb, x, y, w, h, band, lean, slash)
        if icon then
            local is = icon:getSize()
            icon:paintTo(bb, x+math.floor((band-is.w)/2),
                y+math.floor((h-is.h)/2))
        end
        label.fgcolor = button.enabled and BLACK or BB.COLOR_DARK_GRAY
        local lx = label_x + math.max(0, math.floor((label_w-label_size.w)/2))
        local ly = math.max(border, math.floor((h-label_size.h)/2))
        label:paintTo(bb, x+lx, y+ly)
        if f.invert then
            bb:invertRect(x+border, y+border,
                math.max(1, w-2*border), math.max(1, h-2*border))
        end
    end
end

local function openAppearance(menu)
    menu:onClose()
    UIManager:nextTick(function()
        local api = package.loaded["flipside_flashcards_menu_api"]
        local ok, opened = pcall(function()
            return api and api.openAppearance and api.openAppearance()
        end)
        if not ok or not opened then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Open FlipSide flashcards to change the appearance."),
                timeout = 4,
            })
        end
    end)
end

-- Identify every command semantically rather than by row index. Learning
-- Analysis is inserted by the audit module in ButtonTable.new(), so row
-- indexes depend on patch loading and cannot be relied upon.
local function actionKind(entry)
    local text = entry.text
    if entry._flipside_key then return entry._flipside_key end
    if text == _("Cloud sync") then return "cloud" end
    if text == _("Search") then return "search" end
    if text == _("Filter books") then return "filter" end
    if text == _("Quick deletion") or text == _("Resume") then return "edit" end
    if text == _("Reset all progress") then return "reset" end
    if text == _("Clean all words") then return "clean" end
    if text == _("Learning analysis") then return "audit" end
    if text == _("Appearance & sizes") then return "appearance" end
    return nil
end

function StyledButtonTable:init()
    if self._flipside_actions and self.show_parent then
        table.insert(self.buttons, {{
            text = _("Appearance & sizes"),
            callback = function() openAppearance(self.show_parent) end,
            _flipside_key = "appearance",
        }})
    end
    local keys = {}
    for i, row in ipairs(self.buttons) do
        keys[i] = {}
        for j, entry in ipairs(row) do
            keys[i][j] = actionKind(entry)
            entry.id = "flipside_design4_" .. i .. "_" .. j
            entry.no_vertical_sep = true
            entry.font_face = "cfont"
            entry.font_size = #row > 1 and 14 or 19
            entry.font_bold = true
            entry.height = self._flipside_row_height or row_height
            entry.avoid_text_truncation = false
        end
    end
    ButtonTable.init(self)
    for i, row in ipairs(self.buttons) do
        for j, entry in ipairs(row) do
            styleActionButton(self.button_by_id[entry.id], keys[i][j],
                entry.text, #row > 1)
        end
    end
end

function M.makeActions(width, rows, menu, metrics)
    return StyledButtonTable:new{
        width = width, sep_width = metrics and metrics.gap or gap,
        buttons = rows, show_parent = menu,
        _flipside_actions = true,
        _flipside_row_height = metrics and metrics.button_height,
        _flipside_row_gap = metrics and metrics.gap,
    }
end

local panel_padding = math.max(2, Screen:scaleBySize(3))
function M.panelSizing(width, metrics)
    local horizontal_gap = metrics and metrics.gap or math.max(2, Screen:scaleBySize(4))
    local available = width - 2*panel_padding - 2*border
    local guide = math.floor((available-horizontal_gap) * 0.56)
    local switch_width = available-horizontal_gap-guide
    return guide, switch_width
end

-- Keep the settings panel strictly between the actual, measured upper tools
-- and lower review controls. Never assume the usable vertical area is the
-- full screen: this is particularly important when KOReader's DPI is raised.
function M.menuSafeBounds(screen_size)
    local api = package.loaded["flipside_flashcards_menu_api"]
    local bounds
    if api and type(api.getMenuSafeBounds) == "function" then
        local ok, rect = pcall(api.getMenuSafeBounds)
        if ok then bounds = rect end
    end
    local w, h = screen_size.w, screen_size.h
    local x, y, bw, bh = 0, 0, w, h
    if type(bounds) == "table" and type(bounds.x) == "number"
            and type(bounds.y) == "number" and type(bounds.w) == "number"
            and type(bounds.h) == "number" and bounds.w > 0 and bounds.h > 0 then
        x, y, bw, bh = bounds.x, bounds.y, bounds.w, bounds.h
    end
    local inset = math.max(2, math.min(Screen:scaleBySize(5), math.floor(h * .008)))
    local left = math.max(0, math.min(w, math.ceil(x + inset)))
    local top = math.max(0, math.min(h, math.ceil(y + inset)))
    local right = math.max(left, math.min(w, math.floor(x + bw - inset)))
    local bottom = math.max(top, math.min(h, math.floor(y + bh - inset)))
    return {x=left, y=top, w=right-left, h=bottom-top}
end

-- Only the main settings panel uses these DPI-constrained measurements.
-- Leave all buttons' callbacks, wording, SRS and data handling unchanged.
function M.menuMetrics(screen_size, available_height)
    local scaled_gap = math.min(gap, math.max(2, math.floor(available_height * .014)))
    local between = math.min(math.max(4, Screen:scaleBySize(7)),
        math.max(2, math.floor(available_height * .016)))
    local normal_switch = math.max(28,
        math.min(Screen:scaleBySize(38), math.floor(screen_size.h * .051)))
    -- ButtonTable inserts TWO vertical spans per row and FOUR separators;
    -- KOReader's Button/ToggleSwitch also add native DPI-scaled padding.
    -- Measure that overhead before allocating heights to the seven controls.
    local vspan = math.max(1, math.floor(scaled_gap / 4))
    local button_padding = 2 * Size.padding.buttontable
    local switch_padding = 2 * (Size.border.thin + Size.padding.small
        + Size.border.thin)
    local rim = math.max(0, math.min(Screen:scaleBySize(12),
        math.floor(screen_size.w * .05) - 1))
    local fixed = 2 * panel_padding + 2 * border + scaled_gap
        + 10 * vspan + 4 * scaled_gap + between
        + 5 * button_padding + 2 * switch_padding + 2 * rim
    local row_budget = math.max(7, available_height - fixed)
    local unit = math.max(1, math.floor(row_budget / 7))
    local switch_height = math.min(normal_switch, math.max(24, unit))
    local button_height = math.min(row_height,
        math.max(25, math.floor((row_budget - 2*switch_height)/5)))
    return {gap=scaled_gap, between=between,
        switch_height=switch_height, button_height=button_height}
end

local function makeTab(text, width, height)
    local inset = math.max(4, Screen:scaleBySize(7))
    local right_lean = math.max(6, Screen:scaleBySize(10))
    local label = fitText(text, width-inset*2-right_lean,
        height-math.max(4, Screen:scaleBySize(5)), 18, 10)
    local ls = label:getSize()
    local custom = Widget:new{dimen=Geom:new{w=width,h=height}}
    function custom:paintTo(bb,x,y)
        for yy = 0, height-1 do
            -- Use a fractional boundary here too: the upper two setting tabs
            -- previously used the same quantized 1-pixel staircase.
            local edge = width - right_lean * yy / math.max(1, height - 1)
            local full = math.floor(edge)
            if full > 0 then bb:paintRect(x, y+yy, full, 1, GRAY) end
            local fraction = edge - full
            if fraction > 0 and full < width then
                bb:paintRect(x + full, y+yy, 1, 1,
                    coverageColor(GRAY_LEVEL, WHITE_LEVEL, fraction))
            end
        end
        label:paintTo(bb,x+inset, y+math.floor((height-ls.h)/2))
    end
    return custom
end

function M.makeSwitchPanel(width, guide_width, switch, context_switch, metrics)
    local h = switch:getSize().h
    local local_gap = metrics and metrics.gap or gap
    local row1 = HorizontalGroup:new{
        makeTab(_("Auto add new words"), guide_width, h),
        HorizontalSpan:new{width=local_gap}, switch,
    }
    local row2 = HorizontalGroup:new{
        makeTab(_("Save context"), guide_width, h),
        HorizontalSpan:new{width=local_gap}, context_switch,
    }
    return FrameContainer:new{
        padding=panel_padding, margin=0, bordersize=border,
        color=BLACK, radius=0, background=WHITE,
        VerticalGroup:new{
            row1,
            VerticalSpan:new{width=local_gap},
            row2,
        },
    }
end

function M.makeRoot(screen_size, switch_panel, buttons, safe, metrics)
    local between = metrics and metrics.between
        or math.max(4, Screen:scaleBySize(7))
    local content = VerticalGroup:new{
        align="center", switch_panel,
        VerticalSpan:new{width=between}, buttons,
    }
    -- Erase only the flashcard frame behind the floating panel, preserving
    -- the original monochrome design and its native button hitboxes.
    local content_width=content:getSize().w
    local rim=math.max(0, math.min(Screen:scaleBySize(12),
        math.floor((screen_size.w-content_width)/2)-1))
    local panel = FrameContainer:new{
        padding=rim, margin=0, bordersize=0,
        background=WHITE, content,
    }
    safe = safe or {x=0, y=0, w=screen_size.w, h=screen_size.h}
    -- At unusually high DPI, native button padding alone can exceed the
    -- available height. Use KOReader's own scrollable crop as a fallback,
    -- rather than drawing ANY menu content over the adjacent toolbars.
    local visible = panel
    local crop
    if panel:getSize().h > safe.h and safe.h > 0 then
        local scrollbar = math.max(2, math.min(Screen:scaleBySize(6),
            math.floor(safe.w * .012)))
        -- Leave room for KOReader's vertical scroll bar, so the menu buttons
        -- still fit horizontally without causing a second scroll direction.
        local crop_width = math.min(safe.w,
            panel:getSize().w + 3 * scrollbar)
        crop = ScrollableContainer:new{
            dimen=Geom:new{w=crop_width, h=safe.h},
            scroll_bar_width=scrollbar,
            panel,
        }
        visible = crop
    end
    local visible_height = visible:getSize().h
    local top = math.floor(safe.y + (safe.h - visible_height)/2)
    -- Spacer layout retains the full-screen parent, so tapping outside the
    -- visible window still closes it; the scrollbar is only shown if needed.
    top = math.max(safe.y, math.min(top, safe.y + math.max(0, safe.h-visible_height)))
    local bottom = math.max(0, screen_size.h - top - visible_height)
    return VerticalGroup:new{
        VerticalSpan:new{width=top},
        CenterContainer:new{
            dimen=Geom:new{w=screen_size.w, h=visible_height},
            visible,
        },
        VerticalSpan:new{width=bottom},
    }, visible, crop
end

return M
