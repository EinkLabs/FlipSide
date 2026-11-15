-- FlipSide: identical native rounded-menu rendering used by Flashcards appearance.
-- Extracted from flipside_flashcards.lua without changing stroke, curve, insets,
-- pager decorations, widget paint order, or input callbacks.  Applied only to
-- Learning Analysis and Today's review times, NOT to all KOReader menus.
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local FrameContainer = require("ui/widget/container/framecontainer")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local M = {}
local PagerBounds = require("lib.ui.flipside_pager_bounds")

local FlashMenu = Menu:extend{}
local FLASH_MENU_BORDER = math.max(1, Size.border.thin)
local FLASH_MENU_COLOR = Blitbuffer.COLOR_DARK_GRAY
local FLASH_MENU_ROW_X = math.max(3, Screen:scaleBySize(7))
local FLASH_MENU_ROW_Y = math.max(2, Screen:scaleBySize(4))

-- This is exactly the FrameContainer construction technique used by the
-- Flashcards header pill. The empty content reserves the *existing* drawing
-- rectangle: these borders do not increase row sizes or touch-target sizes.
-- The native FrameContainer painter handles all curved pixels and e-ink AA.
local function flashNativeCapsule(width, height, background)
    if width < 12 or height < 12 then return nil end
    local stroke = FLASH_MENU_BORDER
    if width <= 2 * stroke or height <= 2 * stroke then return nil end
    local empty = Widget:new{
        dimen = Geom:new{w=width-2*stroke, h=height-2*stroke},
    }
    return FrameContainer:new{
        bordersize=stroke, padding=0, margin=0,
        radius=math.floor((height-2*stroke)/2),
        color=FLASH_MENU_COLOR,
        background=background,
        empty,
    }
end

-- Keep the stock button (including its callback and disabled status) and
-- draw the exact same native Flashcards capsule around it. In particular,
-- the bottom pager's buttons have ZERO border in KOReader; changing their
-- bordersize would invalidate their calculated geometry and clip them.
local function flashStylePagerButton(button, is_arrow, gap)
    if not button or not button.frame then return end
    local frame = button.frame
    if frame._flash_native_pill then return end
    frame._flash_native_pill = true
    local original_paint = frame.paintTo
    local size = frame:getSize()
    local px, py, pw, ph
    if is_arrow then
        -- Circular buttons, centered inside their unchanged hit rectangles.
        local d = math.min(size.w, size.h) - math.max(2, Screen:scaleBySize(3)) * 2
        pw, ph = d, d
        px, py = math.floor((size.w-d)/2), math.floor((size.h-d)/2)
    else
        -- Use the free KOReader spacing between chevrons to give the page
        -- label a wider, true capsule. No more border touching its letters.
        local extra = math.min(math.max(4, Screen:scaleBySize(7)),
            math.max(0, math.floor((gap or Screen:scaleBySize(32)) / 2)))
        px, py = -extra, math.max(2, Screen:scaleBySize(3))
        pw, ph = size.w + 2*extra, size.h - 2*py
    end
    local pill = flashNativeCapsule(pw, ph, nil)
    frame.paintTo = function(container, bb, x, y)
        original_paint(container, bb, x, y)
        if not button.hidden and pill then
            pill:paintTo(bb, x+px, y+py)
        end
    end
end

function FlashMenu:_applyNativeFlashcardsPills()
    -- The stock menus and the real Flashcards pill use KOReader's normal
    -- white canvas. Inverse/night mode is handled by the device, NOT here.
    for _, row in ipairs(self.item_group or {}) do
        local frame = row[1]
        if frame and not frame._flash_native_pill then
            frame._flash_native_pill = true
            local size = frame:getSize()
            local w = size.w-2*FLASH_MENU_ROW_X
            local h = size.h-2*FLASH_MENU_ROW_Y
            -- The filter bar itself uses background=COLOR_WHITE. Paint this
            -- native frame BEFORE the original MenuItem so its text is never
            -- masked, and no leftover hand-painted pixels linger on an e-ink
            -- partial refresh. Selected/unselected text remains KOReader's.
            local pill = flashNativeCapsule(w, h, Blitbuffer.COLOR_WHITE)
            local original_paint = frame.paintTo
            frame.paintTo = function(container, bb, x, y)
                if pill then
                    pill:paintTo(bb, x+FLASH_MENU_ROW_X, y+FLASH_MENU_ROW_Y)
                end
                original_paint(container, bb, x, y)
            end
        end
    end

    flashStylePagerButton(self.page_info_first_chev, true)
    flashStylePagerButton(self.page_info_left_chev, true)
    flashStylePagerButton(self.page_info_text, false,
        self.page_info_spacer and self.page_info_spacer.width)
    flashStylePagerButton(self.page_info_right_chev, true)
    flashStylePagerButton(self.page_info_last_chev, true)

    -- The X is the original TitleBar IconButton. Its hit box and onClose
    -- remain untouched; the outline is a real native FrameContainer circle.
    local close_icon = self.title_bar and self.title_bar.right_button
        and self.title_bar.right_button.image
    if close_icon and not close_icon._flash_native_pill then
        close_icon._flash_native_pill = true
        local original_paint = close_icon.paintTo
        local dim = close_icon:getSize()
        local pad = math.max(2, Screen:scaleBySize(4))
        local d = math.max(dim.w, dim.h)+2*pad
        local circle = flashNativeCapsule(d, d, nil)
        local dx,dy = math.floor((dim.w-d)/2),math.floor((dim.h-d)/2)
        close_icon.paintTo = function(icon, bb, x, y)
            original_paint(icon, bb, x, y)
            if circle then circle:paintTo(bb, x+dx, y+dy) end
        end
    end
end

-- KOReader recreates native menu items when data/pages change. Reattach
-- the original Flashcards style to new widgets, without altering their size.
function FlashMenu:updateItems(select_number, no_recalculate_dimen)
    local result = Menu.updateItems(self, select_number, no_recalculate_dimen)
    PagerBounds.fit(self)
    self:_applyNativeFlashcardsPills()
    return result
end

function M.new(settings)
    settings.items_font_size = 17
    settings.items_mandatory_font_size = 17
    settings.line_color = Blitbuffer.COLOR_WHITE
    settings.covers_fullscreen = true
    settings.is_borderless = true
    settings.is_popout = false
    local style = package.loaded["flipside_audit_style"]
    if style and type(style.name) == "function" then
        settings.title_face = Font:getFace(style.name(), 24)
    end
    return FlashMenu:new(settings)
end
return M
