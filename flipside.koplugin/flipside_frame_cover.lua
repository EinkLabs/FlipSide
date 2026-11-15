-- FlipSide: narrowly scoped backdrop for three existing modal panels.
-- The existing Saved Meanings dictionary popup erases the *measured* card
-- frame with a DPI-scaled 9px margin (flipside_meanings_popup.lua).
-- Reuse that same geometry here, without changing the card, the dialog,
-- the menu hitbox, or any database/review/synchronization code.
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
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

-- Called exclusively on the main settings popup, the top-level statistics
-- popup and the Study Calendar popup; no interception of UIManager.show/close.
-- A modal draws over the pre-existing card as usual. Before it paints,
-- erase the frame rectangle measured by its own decorator on the current card.
function M.attach(dialog)
    if type(dialog) ~= "table" or dialog._flipside_frame_cover then return end
    local old_paint = dialog.paintTo
    if type(old_paint) ~= "function" then return end
    dialog._flipside_frame_cover = true
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
        local rect = currentFrame()
        if rect then
            paintClippedBox(bb, x or 0, y or 0, rect,
                math.max(3, Screen:scaleBySize(9)))
        end
        return old_paint(self, bb, x, y)
    end
    -- Explicit full UI-only repaint on opening and closing ensures the
    -- erased outline never leaves ghost pixels on e-ink outside the dialog.
    -- Keep native lifecycle handlers (tap outside, close, focus) unchanged.
    local old_show = dialog.onShow
    dialog.onShow = function(self, ...)
        if old_show then old_show(self, ...) end
        UIManager:setDirty("all", "ui")
    end
    local old_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(self, ...)
        -- Release only once and only after the modal is removed from the
        -- stack. Native close behavior is otherwise left untouched.
        local result
        if old_close then result = old_close(self, ...) end
        if completion_concealed then
            completion_concealed = false
            UIManager:nextTick(function()
                if completion_api and type(completion_api.concealCompletionPanel) == "function" then
                    completion_api.concealCompletionPanel(false)
                end
            end)
        end
        UIManager:setDirty("all", "ui")
        return result
    end
end

return M
