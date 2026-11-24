-- FlipSide: narrowly scoped backdrop for three existing modal panels.
-- The existing Saved Meanings dictionary popup erases the *measured* card
-- frame with a DPI-scaled 9px margin (flipside_meanings_popup.lua).
-- Reuse that same geometry here, without changing the card, the dialog,
-- the menu hitbox, or any database/review/synchronization code.
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local M = {}

local function paintClippedBox(bb, x, y, rect, inset)
    if type(rect) ~= "table" or not rect.x or not rect.y
            or not rect.w or not rect.h then return end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local left = math.max(0, math.floor(rect.x) - inset)
    local top = math.max(0, math.floor(rect.y) - inset)
    local right = math.min(sw, math.ceil(rect.x + rect.w) + inset)
    local bottom = math.min(sh, math.ceil(rect.y + rect.h) + inset)
    if right > left and bottom > top then
        bb:paintRect(x + left, y + top,
            right - left, bottom - top, Blitbuffer.COLOR_WHITE)
    end
end

local function currentFrame()
    local bridge = package.loaded["flipside_flashcards_menu_api"]
    if type(bridge) ~= "table" or type(bridge.getCardFrame) ~= "function" then
        return nil
    end
    local ok, rect = pcall(bridge.getCardFrame)
    return ok and rect or nil
end

local function currentCardContent()
    local bridge = package.loaded["flipside_flashcards_menu_api"]
    if type(bridge) ~= "table" or type(bridge.getMenuSafeBounds) ~= "function" then
        return nil
    end
    local ok, rect = pcall(bridge.getMenuSafeBounds)
    return ok and rect or nil
end

-- Called exclusively on the main settings popup, the top-level statistics
-- popup and the Study Calendar popup; no interception of UIManager.show/close.
-- A modal draws over the pre-existing card as usual. Before it paints,
-- erase the frame rectangle measured by its own decorator on the current card.
function M.attach(dialog, options)
    if type(dialog) ~= "table" or dialog._flipside_frame_cover then return end
    local old_paint = dialog.paintTo
    if type(old_paint) ~= "function" then return end
    dialog._flipside_frame_cover = true
    -- Calendar and Statistics opt into a non-flashing regional refresh. The
    -- main settings popup and any other caller keep their previous behavior.
    local regional_no_flash = options and options.regional_no_flash == true
    local opaque_screen = options and options.opaque_screen == true
    local cover_card_content = options and options.cover_card_content == true
    -- Statistics delegates concealment to Flashcards' center painter, rather
    -- than painting white screen coordinates from the dialog's paintTo().
    local mask_statistics_center = options and options.mask_statistics_center == true
    local pin_popup = options and options.pin_popup == true
    local mask_api = mask_statistics_center and package.loaded["flipside_flashcards_menu_api"]
    local mask_active = false
    if mask_api and type(mask_api.setStatisticsCenterConcealed) == "function" then
        local ok, applied = pcall(mask_api.setStatisticsCenterConcealed, true)
        mask_active = ok and applied == true
    end
    if pin_popup and dialog.movable then
        dialog.movable.unmovable = true
        dialog.movable.is_movable_with_keys = false
        dialog.movable.ges_events = {}
        if dialog.movable.key_events then
            dialog.movable.key_events.MovePositionTop = nil
            dialog.movable.key_events.MovePositionBottom = nil
        end
    end

    local function refreshCoveredArea()
        if opaque_screen then
            -- Only this modal covers the entire underlying Flashcards screen;
            -- use the non-flashing UI waveform for opening and dismissal.
            UIManager:setDirty("all", "ui")
            return
        end
        if not regional_no_flash then
            UIManager:setDirty("all", "ui")
            return
        end
        local panel = dialog.movable and dialog.movable.dimen
        if not panel or not panel.x or not panel.y or not panel.w or not panel.h then
            UIManager:setDirty("all", "ui") -- safe fallback before geometry exists
            return
        end
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local x0, y0 = panel.x, panel.y
        local x1, y1 = panel.x + panel.w, panel.y + panel.h
        local cover = (cover_card_content or mask_statistics_center)
            and currentCardContent() or currentFrame()
        if cover and cover.x and cover.y and cover.w and cover.h then
            local inset = (cover_card_content or mask_statistics_center)
                and 0 or math.max(3, Screen:scaleBySize(9))
            x0 = math.min(x0, cover.x - inset)
            y0 = math.min(y0, cover.y - inset)
            x1 = math.max(x1, cover.x + cover.w + inset)
            y1 = math.max(y1, cover.y + cover.h + inset)
        end
        x0, y0 = math.max(0, math.floor(x0)), math.max(0, math.floor(y0))
        x1, y1 = math.min(sw, math.ceil(x1)), math.min(sh, math.ceil(y1))
        if x1 <= x0 or y1 <= y0 then return end
        -- Redraw everything under the covered card and the modal, but refresh
        -- only their bounding rectangle with the non-flashing "ui" waveform.
        UIManager:setDirty("all", "ui", Geom:new{
            x = x0, y = y0, w = x1 - x0, h = y1 - y0,
        })
    end
    -- These are the three already-covered FlipSide overlays. Temporarily
    -- remove the completion contents underneath instead of painting a fixed
    -- rectangle. It works for every measured screen size and DPI.
    local completion_api = package.loaded["flipside_flashcards_menu_api"]
    local completion_concealed = false
    if completion_api and type(completion_api.concealCompletionPanel) == "function" then
        local ok, hidden = pcall(completion_api.concealCompletionPanel, true)
        completion_concealed = ok and hidden == true
    end
    dialog.paintTo = function(self, bb, x, y)
        if mask_statistics_center then
            -- Flashcards itself masks the measured center, leaving its header
            -- and bottom controls untouched. Draw only the Statistics dialog.
        elseif opaque_screen then
            bb:paintRect(x or 0, y or 0,
                Screen:getWidth(), Screen:getHeight(), Blitbuffer.COLOR_WHITE)
        else
            local rect = cover_card_content and currentCardContent() or currentFrame()
            if rect then
                paintClippedBox(bb, x or 0, y or 0, rect,
                    cover_card_content and 0 or math.max(3, Screen:scaleBySize(9)))
            end
            if cover_card_content then
                local frame = currentFrame()
                if frame then
                    paintClippedBox(bb, x or 0, y or 0, frame,
                        math.max(3, Screen:scaleBySize(9)))
                end
            end
        end
        return old_paint(self, bb, x, y)
    end
    -- Explicit full UI-only repaint on opening and closing ensures the
    -- erased outline never leaves ghost pixels on e-ink outside the dialog.
    -- Keep native lifecycle handlers (tap outside, close, focus) unchanged.
    local old_show = dialog.onShow
    dialog.onShow = function(self, ...)
        if old_show then old_show(self, ...) end
        refreshCoveredArea()
    end
    local old_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(self, ...)
        -- Release only once and only after the modal is removed from the
        -- stack. Native close behavior is otherwise left untouched.
        local result
        if old_close then result = old_close(self, ...) end
        if mask_active then
            mask_active = false
            pcall(mask_api.setStatisticsCenterConcealed, false)
        end
        if completion_concealed then
            completion_concealed = false
            UIManager:nextTick(function()
                if completion_api and type(completion_api.concealCompletionPanel) == "function" then
                    completion_api.concealCompletionPanel(false)
                end
            end)
        end
        refreshCoveredArea()
        return result
    end
end

return M
